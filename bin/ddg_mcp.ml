open Eio.Std
open Mcp
open Mcp_sdk
open Cohttp_eio

let whitespace_re = Re.compile (Re.str "\\s+")
let wiki_opensnippet_re = Re.compile (Re.str "<span class=\"searchmatch\">")
let wiki_closesnippet_re = Re.compile (Re.str "</span>")

module Https = struct
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok x -> x
    | Error (`Msg m) ->
        Fmt.failwith "Failed to create system store X509 authenticator: %s" m

  let https ~authenticator =
    let () = Mirage_crypto_rng_unix.use_default () in
    let tls_config =
      match Tls.Config.client ~authenticator () with
      | Error (`Msg msg) -> failwith ("tls configuration problem: " ^ msg)
      | Ok tls_config -> tls_config
    in
    fun uri raw ->
      let host =
        Uri.host uri
        |> Option.map (fun x -> Domain_name.(host_exn (of_string_exn x)))
      in
      Tls_eio.client_of_flow ?host tls_config raw

  let make () = https ~authenticator
end

(* Helper for extracting string value from JSON arguments *)
let get_string_param json name =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt name fields with
      | Some (`String value) -> Ok value
      | _ ->
          Error (Printf.sprintf "Missing or invalid string parameter: %s" name))
  | _ -> Error "Expected JSON object for arguments"

(* A simple record to hold search result data *)
type search_result = {
  title : string;
  link : string;
  snippet : string;
  position : int;
}

(* Module to handle rate limiting using Eio *)
module Rate_limiter = struct
  type t = {
    requests_per_minute : int;
    requests : float Queue.t;
    mutex : Eio.Mutex.t;
  }

  let create requests_per_minute =
    {
      requests_per_minute;
      requests = Queue.create ();
      mutex = Eio.Mutex.create ();
    }

  let acquire t clock =
    Eio.Mutex.use_rw t.mutex ~protect:true @@ fun () ->
    let now = Eio.Time.now clock in
    (* Remove requests older than 1 minute *)
    let one_minute_ago = now -. 60.0 in
    while
      (not (Queue.is_empty t.requests))
      && Queue.peek t.requests < one_minute_ago
    do
      ignore (Queue.pop t.requests)
    done;

    (* If we've made too many requests, wait *)
    if Queue.length t.requests >= t.requests_per_minute then (
      let oldest_request = Queue.peek t.requests in
      let wait_time = 60.0 -. (now -. oldest_request) in
      if wait_time > 0. then Eio.Time.sleep clock wait_time;

      Queue.push now t.requests)
end

module DuckDuckGo_searcher = struct
  let base_url = "https://html.duckduckgo.com/html"

  let headers =
    Http.Header.of_list
      [
        ( "User-Agent",
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
           (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" );
        ("Content-Type", "application/x-www-form-urlencoded");
        ("charset", "utf-8");
      ]

  let format_results_for_llm (results : search_result list) : string =
    if List.length results = 0 then
      "No results were found for your search query. This could be due to \
       DuckDuckGo's bot detection or the query returned no matches. Please try \
       rephrasing your search or try again in a few minutes."
    else
      let result_strings =
        List.map
          (fun r ->
            Printf.sprintf "%d. %s\n   URL: %s\n   Summary: %s" r.position
              r.title r.link r.snippet)
          results
      in
      Printf.sprintf "Found %d search results:\n\n" (List.length results)
      ^ String.concat "\n\n" result_strings

  let search ~sw ~net ~clock ~rate_limiter query max_results =
    try
      Rate_limiter.acquire rate_limiter clock;
      Log.infof "Searching DuckDuckGo for: %s" query;

      let uri =
        Uri.of_string base_url |> fun uri ->
        Uri.add_query_params uri
          [ ("q", [ query ]); ("b", [ "" ]); ("kl", [ "" ]) ]
      in
      let client = Client.make ~https:(Some (Https.make ())) net in
      Log.infof "BODY: %s\n"
        (Uri.encoded_of_query
           [ ("q", [ query ]); ("b", [ "" ]); ("kl", [ "" ]) ]);

      let resp, body = Client.get ~sw ~headers client uri in

      if Http.Status.compare resp.status `OK <> 0 then
        Error
          (Printf.sprintf "HTTP Error: %s" (Http.Status.to_string resp.status))
      else
        let html = Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int in

        (* Parse the HTML response *)
        let soup = Soup.parse html in

        let results =
          soup |> Soup.select ".result"
          |> Soup.to_list (* <-- FIX: Convert nodes sequence to a list *)
          |> List.filter_map (fun result ->
                 let title_elem =
                   result |> Soup.select_one ".result__title > a"
                 in
                 let snippet_elem =
                   result |> Soup.select_one ".result__snippet"
                 in

                 match (title_elem, snippet_elem) with
                 | Some title_node, Some snippet_node -> (
                     let title =
                       title_node |> Soup.trimmed_texts |> String.concat ""
                     in
                     let link =
                       match Soup.attribute "href" title_node with
                       | Some href when not (String.contains href 'y') -> (
                           let uri = Uri.of_string href in
                           match Uri.get_query_param uri "uddg" with
                           | Some encoded_url ->
                               Some (Uri.pct_decode encoded_url)
                           | None -> Some href)
                       | _ -> None
                     in
                     let snippet =
                       snippet_node |> Soup.trimmed_texts |> String.concat ""
                     in
                     match link with
                     | Some l -> Some { title; link = l; snippet; position = 0 }
                     | None -> None)
                 | _ -> None)
        in
        let final_results =
          results |> List.mapi (fun i r -> { r with position = i + 1 })
          |> fun l -> List.filteri (fun i _ -> i < max_results) l
        in
        Log.infof "Successfully found %d results" (List.length final_results);
        Ok final_results
    with ex -> Error (Printexc.to_string ex)
end

(* Module for fetching and parsing web content *)
module Web_content_fetcher = struct
  let headers =
    Http.Header.of_list
      [
        ( "User-Agent",
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" );
      ]

  let truncate_at max_length content =
    if String.length content > max_length then
      String.sub content 0 max_length ^ "... [content truncated]"
    else content

  let rec get_with_redirects ~sw ~client ~headers ~max_redirects current_url =
    if max_redirects < 0 then Error "Too many redirects"
    else
      let resp, body =
        Client.get ~sw ~headers client (Uri.of_string current_url)
      in
      match resp.status with
      | `OK -> Ok body
      | `Moved_permanently | `Found | `See_other | `Temporary_redirect
      | `Permanent_redirect -> (
          match Http.Header.get resp.headers "location" with
          | None ->
              (* Drain body on error before returning *)
              let _ = Eio.Flow.read_all body in
              Error "Redirect response missing a Location header"
          | Some new_url ->
              (* Drain body before making the next request *)
              let _ = Eio.Flow.read_all body in
              let new_uri =
                Uri.resolve ""
                  (Uri.of_string current_url)
                  (Uri.of_string new_url)
              in
              get_with_redirects ~sw ~client ~headers
                ~max_redirects:(max_redirects - 1) (Uri.to_string new_uri))
      | status ->
          let _ = Eio.Flow.read_all body in
          Error
            (Printf.sprintf "Could not access the webpage (%s)"
               (Http.Status.to_string status))

  let fetch_markdown ~sw ~net ~clock ~rate_limiter ?(max_length = 8192)
      ~use_trafilatura url =
    try
      if use_trafilatura then
        let ic =
          Unix.open_process_args_in "trafilatura" [| "markdown"; "-u"; url |]
        in
        let output = In_channel.input_all ic in
        let exit_code = Unix.close_process_in ic in
        match exit_code with
        | WEXITED 0 ->
            let truncated_text = truncate_at max_length output in
            Log.infof "Successfully fetched and parsed content (%d characters)"
              (String.length truncated_text);
            Ok truncated_text
        | WEXITED n | WSIGNALED n | WSTOPPED n ->
            Error
              (Printf.sprintf
                 "Failed to fetch content using trafilatura (error code %d): %s"
                 n output)
      else (
        Rate_limiter.acquire rate_limiter clock;
        Log.infof "Fetching content from: %s" url;
        let client = Client.make ~https:(Some (Https.make ())) net in
        let url = "https://r.jina.ai/" ^ url in
        let headers = Http.Header.add headers "X-Base" "final" in

        (* Use the get_with_redirects function to handle redirects *)
        match Client.get ~sw ~headers client (Uri.of_string url) with
        | resp, body when resp.status = `OK ->
            let content =
              Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int
            in
            let truncated_text = truncate_at max_length content in
            Log.infof "Successfully fetched content (%d characters)"
              (String.length truncated_text);
            Ok truncated_text
        | resp, body ->
            let _ = Eio.Flow.read_all body in
            Error
              (Printf.sprintf "Could not access the webpage (%s)"
                 (Http.Status.to_string resp.status)))
    with ex ->
      Error
        (Printf.sprintf
           "An unexpected error occurred while fetching the webpage (%s)"
           (Printexc.to_string ex))

  let fetch_and_parse ~sw ~net ~clock ~rate_limiter ?(max_length = 8192) url =
    try
      Rate_limiter.acquire rate_limiter clock;
      Log.infof "Fetching content from: %s" url;
      let client = Client.make ~https:(Some (Https.make ())) net in

      match get_with_redirects ~sw ~client ~headers ~max_redirects:5 url with
      | Error msg -> Error msg
      | Ok body ->
          let html = Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int in
          let soup = Soup.parse html in

          (* Remove script, style, and navigation elements *)
          List.iter
            (fun selector ->
              soup |> Soup.select selector |> Soup.iter Soup.delete)
            [ "script"; "style"; "nav"; "header"; "footer" ];

          (* Get and clean up text content *)
          let text =
            soup |> Soup.texts |> List.map String.trim
            |> List.filter (fun s -> String.length s > 0)
            |> String.concat " "
            |> Re.replace_string ~all:true whitespace_re
                 ~by:" " (* Replace multiple whitespace with a single space *)
          in

          let truncated_text = truncate_at max_length text in
          Log.infof "Successfully fetched and parsed content (%d characters)"
            (String.length truncated_text);
          Ok truncated_text
    with ex ->
      Error
        (Printf.sprintf
           "An unexpected error occurred while fetching the webpage (%s)"
           (Printexc.to_string ex))

  let search_wikipedia ~sw ~net ~clock ~rate_limiter ?(max_results = 10)
      search_term =
    let parse_wiki (json : Yojson.Safe.t) =
      let open Yojson.Safe.Util in
      let fields = json |> member "query" |> member "search" |> to_list in
      let results =
        List.mapi
          (fun i item ->
            let title = item |> member "title" |> to_string in
            let title_for_url =
              String.trim title
              |> Re.replace_string ~all:true whitespace_re ~by:"_"
              |> Uri.pct_encode
            in
            let snippet =
              item |> member "snippet" |> to_string
              |> Re.replace_string ~all:true wiki_opensnippet_re ~by:""
              |> Re.replace_string ~all:true wiki_closesnippet_re ~by:""
            in
            let position = i + 1 in
            let link =
              Printf.sprintf "https://en.wikipedia.org/wiki/%s" title_for_url
            in
            { title; link; snippet; position })
          fields
      in

      if List.length results = 0 then
        Error "No results were found for your search query on Wikipedia."
      else
        let output_lines =
          Printf.sprintf "Found %d Wikipedia results:\n" (List.length results)
          :: List.fold_left
               (fun acc result ->
                 let item_lines =
                   [
                     Printf.sprintf "%d. %s\n" result.position result.title;
                     Printf.sprintf "URL: %s\n" result.link;
                     Printf.sprintf "Summary: %s\n\n" result.snippet;
                   ]
                 in
                 acc @ item_lines)
               [] results
        in
        Ok (String.concat "\n" output_lines)
    in

    try
      Rate_limiter.acquire rate_limiter clock;
      Log.infof "Searching Wikipedia for: %s" search_term;

      let base_url = "https://en.wikipedia.org/w/api.php" in
      let params =
        [
          ("action", "query");
          ("format", "json");
          ("list", "search");
          ("srsearch", search_term);
          ("srlimit", string_of_int max_results);
          ("srprop", "snippet|titlesnippet");
        ]
      in

      let query_string =
        params
        |> List.map (fun (k, v) -> k ^ "=" ^ Uri.pct_encode v)
        |> String.concat "&"
      in
      let url = base_url ^ "?" ^ query_string in

      let client = Client.make ~https:(Some (Https.make ())) net in

      match Client.get ~sw ~headers client (Uri.of_string url) with
      | resp, body when resp.status = `OK ->
          let json_content =
            Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int
          in
          let json = Yojson.Safe.from_string json_content in
          parse_wiki json
      | resp, body ->
          let _ = Eio.Flow.read_all body in
          Error
            (Printf.sprintf "Wikipedia API request failed (%s)"
               (Http.Status.to_string resp.status))
    with ex ->
      Error
        (Printf.sprintf
           "An unexpected error occurred while searching Wikipedia (%s)"
           (Printexc.to_string ex))
end

(* Command-line argument parsing *)
type server_mode = Stdio | Port of int

let server_mode = ref (Port 8080)
let set_port port = server_mode := Port port
let set_stdio () = server_mode := Stdio

let spec =
  [
    ("--serve", Arg.Int set_port, " Run http server, listening on PORT");
    ( "--stdio",
      Arg.Unit set_stdio,
      " Use stdio for communication instead of port (default)" );
  ]

let usage_msg = "ddg_mcp [--serve PORT | --stdio]"

let () =
  Arg.parse spec (fun _ -> ()) usage_msg;

  Random.self_init ();

  let use_trafilatura =
    match Sys.command "command -v trafilatura > /dev/null 2>&1" with
    | 0 ->
        Log.info "Trafilatura is available";
        true
    | _ ->
        Log.info "Trafilatura is not available, falling back to jina reader";
        false
  in

  Eio_main.run @@ fun env ->
  let search_rate_limiter = Rate_limiter.create 30 in
  let fetch_rate_limiter = Rate_limiter.create 20 in
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in

  let server =
    create_server ~name:"ocaml-ddg-search" ~version:"0.1.0"
      ~protocol_version:"2024-11-05" ()
    |> fun server -> configure_server server ~with_tools:true ()
  in

  let _ =
    add_tool server ~name:"search"
      ~description:"Search DuckDuckGo and return formatted results."
      ~schema_properties:
        [
          ("query", "string", "The search query string");
          ( "max_results",
            "integer",
            "Maximum number of results to return (default: 10)" );
        ]
      ~schema_required:[ "query" ]
      (fun args ->
        let response_text =
          Switch.run @@ fun sw ->
          match
            (get_string_param args "query", get_string_param args "max_results")
          with
          | Error msg, _ -> msg
          | Ok query, max_results -> (
              let max_results =
                match max_results with
                | Error _ -> 10
                | Ok len -> Option.value (int_of_string_opt len) ~default:10
              in
              match
                DuckDuckGo_searcher.search ~sw ~net ~clock
                  ~rate_limiter:search_rate_limiter query max_results
              with
              | Ok results -> DuckDuckGo_searcher.format_results_for_llm results
              | Error msg ->
                  Printf.sprintf "An error occurred while searching: %s" msg)
        in
        TextContent.yojson_of_t
          TextContent.{ text = response_text; annotations = None })
  in

  let _ =
    add_tool server ~name:"fetch_content"
      ~description:"Fetch and parse content from a webpage URL."
      ~schema_properties:
        [
          ("url", "string", "The webpage URL to fetch content from");
          ( "max_length",
            "integer",
            "Maximum length (in bytes) of content to return (default: 8192 \
             characters)" );
        ]
      ~schema_required:[ "url" ]
      (fun args ->
        let response_text =
          Switch.run @@ fun sw ->
          match
            (get_string_param args "url", get_string_param args "max_length")
          with
          | Error msg, _ -> msg
          | Ok url, max_length -> (
              let max_length =
                match max_length with
                | Error _ -> None
                | Ok len -> int_of_string_opt len
              in
              match
                Web_content_fetcher.fetch_and_parse ~sw ~net ~clock
                  ~rate_limiter:fetch_rate_limiter ?max_length url
              with
              | Ok content -> content
              | Error msg -> msg)
        in
        TextContent.yojson_of_t
          TextContent.{ text = response_text; annotations = None })
  in

  let _ =
    add_tool server ~name:"fetch_markdown"
      ~description:"Fetch and parse content from a webpage URL as Markdown."
      ~schema_properties:
        [
          ("url", "string", "The webpage URL to fetch content from");
          ( "max_length",
            "integer",
            "Maximum length (in bytes) of content to return (default: 8192 \
             characters)" );
        ]
      ~schema_required:[ "url" ]
      (fun args ->
        let response_text =
          Switch.run @@ fun sw ->
          match
            (get_string_param args "url", get_string_param args "max_length")
          with
          | Error msg, _ -> msg
          | Ok url, max_length -> (
              let max_length =
                match max_length with
                | Error _ -> None
                | Ok len -> int_of_string_opt len
              in
              match
                Web_content_fetcher.fetch_markdown ~sw ~net ~clock
                  ~rate_limiter:fetch_rate_limiter ?max_length ~use_trafilatura
                  url
              with
              | Ok content -> content
              | Error msg -> msg)
        in
        TextContent.yojson_of_t
          TextContent.{ text = response_text; annotations = None })
  in

  let _ =
    add_tool server ~name:"search_wikipedia"
      ~description:"Search Wikipedia and return formatted results."
      ~schema_properties:
        [
          ("search_term", "string", "The term to search for on Wikipedia");
          ( "max_results",
            "integer",
            "Maximum number of results to return (default: 10)" );
        ]
      ~schema_required:[ "search_term" ]
      (fun args ->
        let response_text =
          Switch.run @@ fun sw ->
          match
            ( get_string_param args "search_term",
              get_string_param args "max_results" )
          with
          | Error msg, _ -> msg
          | Ok search_term, max_results -> (
              let max_results =
                match max_results with
                | Error _ -> 10
                | Ok len -> Option.value (int_of_string_opt len) ~default:10
              in
              match
                Web_content_fetcher.search_wikipedia ~sw ~net ~clock
                  ~rate_limiter:search_rate_limiter ~max_results search_term
              with
              | Ok results -> results
              | Error msg ->
                  Printf.sprintf
                    "An error occurred while searching Wikipedia: %s" msg)
        in
        TextContent.yojson_of_t
          TextContent.{ text = response_text; annotations = None })
  in

  let on_error exn =
    Log.errorf "Unhandled server error: %s\n%s" (Printexc.to_string exn)
      (Printexc.get_backtrace ())
  in

  match !server_mode with
  | Stdio ->
      Log.infof "Starting MCP server in stdio mode";
      Mcp_server.run_sdtio_server env server
  | Port port ->
      Log.infof "Starting MCP server on port %d" port;
      Mcp_server.run_server env server ~port ~on_error
