type search_result = {
  title : string;
  link : string;
  snippet : string;
  position : int;
}
[@@deriving yojson]

module Args = struct
  type t = { query : string; max_results : int [@default 10] }
  [@@deriving yojson]

  let schema () =
    `Assoc
      [
        ("type", `String "object");
        ( "properties",
          `Assoc
            [
              ( "query",
                `Assoc
                  [
                    ("type", `String "string");
                    ("description", `String "The search query string");
                  ] );
              ( "max_results",
                `Assoc
                  [
                    ("type", `String "integer");
                    ( "description",
                      `String
                        "Maximum number of results to return (default: 10)" );
                    ("default", `Int 10);
                  ] );
            ] );
        ("required", `List [ `String "query" ]);
      ]
end

let whitespace_re = Re.compile Re.(rep1 blank)
let wiki_opensnippet_re = Re.compile (Re.str "<span class=\"searchmatch\">")
let wiki_closesnippet_re = Re.compile (Re.str "</span>")
let ddg_uri = Uri.of_string "https://html.duckduckgo.com/html"
let wikipedia_uri = Uri.of_string "https://en.wikipedia.org/w/api.php"

let headers =
  Http.Header.of_list
    [
      ( "User-Agent",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, \
         like Gecko) Chrome/91.0.4472.124 Safari/537.36" );
      ("Content-Type", "application/x-www-form-urlencoded");
      ("charset", "utf-8");
    ]

let format_results_for_llm (results : search_result list) : string =
  if List.length results = 0 then
    "No results were found for your search query. This could be due to bot \
     detection mechanics or the query returned no matches. Please try \
     rephrasing your search or try again in a few minutes."
  else
    let result_strings =
      List.map
        (fun r ->
          Printf.sprintf "%d. %s\nURL: %s\nSummary: %s" r.position r.title
            r.link r.snippet)
        results
    in
    Printf.sprintf "Found %d search results:\n\n" (List.length results)
    ^ String.concat "\n\n" result_strings

let search ~sw ~net ~clock ~rate_limiter query max_results =
  try
    Rate_limiter.acquire rate_limiter clock;
    Logs.info (fun m -> m "Searching DuckDuckGo for: %s" query);

    let uri =
      Uri.add_query_params ddg_uri
        [ ("q", [ query ]); ("b", [ "" ]); ("kl", [ "" ]) ]
    in
    let client = Cohttp_eio.Client.make ~https:(Some (Https.make ())) net in
    Logs.info (fun m ->
        m "BODY: %s\n"
          (Uri.encoded_of_query
             [ ("q", [ query ]); ("b", [ "" ]); ("kl", [ "" ]) ]));

    (* Helper function to handle 202 responses with retry logic *)
    let rec fetch_with_retry ?(max_retries = 3) ?(delay = 1.0) uri =
      let resp, body = Cohttp_eio.Client.get ~sw ~headers client uri in
      match resp.status with
      | `OK ->
          let html = Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int in
          Ok html
      | `Accepted when max_retries > 0 ->
          (* Handle 202 response - read and discard body, then retry after delay *)
          let _ = Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int in
          Logs.info (fun m ->
              m
                "Received 202 response, retrying in %.1f seconds (%d retries \
                 left)"
                delay max_retries);
          Eio.Time.sleep clock delay;
          fetch_with_retry ~max_retries:(max_retries - 1) ~delay:(delay *. 1.5)
            uri
      | status ->
          let _ = Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int in
          Error (Printf.sprintf "HTTP Error: %s" (Http.Status.to_string status))
    in

    match fetch_with_retry uri with
    | Error msg -> Error msg
    | Ok html ->
        (* Parse the HTML response *)
        let soup = Soup.parse html in

        let results =
          soup |> Soup.select ".result" |> Soup.to_list
          |> List.filter_map (fun result ->
                 let title_elem =
                   result |> Soup.select_one ".result__title > a"
                 in

                 Option.bind title_elem (function title_node ->
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
                       let snippet_elem =
                         result |> Soup.select_one ".result__snippet"
                       in
                       match snippet_elem with
                       | Some snippet_node ->
                           snippet_node |> Soup.trimmed_texts
                           |> String.concat ""
                       | None -> ""
                     in
                     Option.map
                       (fun l -> { title; link = l; snippet; position = 0 })
                       link))
        in
        let final_results =
          results |> List.mapi (fun i r -> { r with position = i + 1 })
          |> fun l -> List.filteri (fun i _ -> i < max_results) l
        in
        Logs.info (fun m ->
            m "Successfully found %d results" (List.length final_results));
        Ok final_results
  with ex -> Error (Printexc.to_string ex)

let search_wikipedia ~sw ~net ~clock ~rate_limiter ?(max_results = 10) query =
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
    Ok results
  in

  try
    Rate_limiter.acquire rate_limiter clock;
    Logs.info (fun m -> m "Searching Wikipedia for: %s" query);

    let params =
      [
        ("action", "query");
        ("format", "json");
        ("list", "search");
        ("srsearch", query);
        ("srlimit", string_of_int max_results);
        ("srprop", "snippet|titlesnippet");
      ]
    in

    let url = Uri.add_query_params' wikipedia_uri params in

    let client = Cohttp_eio.Client.make ~https:(Some (Https.make ())) net in

    match Cohttp_eio.Client.get ~sw ~headers client url with
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
