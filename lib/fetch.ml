module FetchContentArgs = struct
  type t = {
    url : string;
    max_length : int; [@default 8192]
    start_from : int; [@default 0]
  }
  [@@deriving yojson]

  let schema () =
    `Assoc
      [
        ("type", `String "object");
        ( "properties",
          `Assoc
            [
              ( "url",
                `Assoc
                  [
                    ("type", `String "string");
                    ( "description",
                      `String "The webpage URL to fetch content from" );
                  ] );
              ( "max_length",
                `Assoc
                  [
                    ("type", `String "integer");
                    ( "description",
                      `String
                        "Maximum length (in bytes) of content to return \
                         (default: 8192 characters). Use -1 to disable the \
                         limit." );
                    ("default", `Int 8192);
                  ] );
              ( "start_from",
                `Assoc
                  [
                    ("type", `String "integer");
                    ( "description",
                      `String
                        "Byte offset to start returning content from (default: \
                         0)" );
                    ("default", `Int 0);
                  ] );
            ] );
        ("required", `List [ `String "url" ]);
      ]
end

module FetchMarkdownArgs = struct
  type t = {
    url : string;
    max_length : int; [@default 8192]
    start_from : int; [@default 0]
  }
  [@@deriving yojson]

  let schema () =
    `Assoc
      [
        ("type", `String "object");
        ( "properties",
          `Assoc
            [
              ( "url",
                `Assoc
                  [
                    ("type", `String "string");
                    ( "description",
                      `String "The webpage URL to fetch content from" );
                  ] );
              ( "max_length",
                `Assoc
                  [
                    ("type", `String "integer");
                    ( "description",
                      `String
                        "Maximum length (in bytes) of content to return \
                         (default: 8192 characters). Use -1 to disable the \
                         limit." );
                    ("default", `Int 8192);
                  ] );
              ( "start_from",
                `Assoc
                  [
                    ("type", `String "integer");
                    ( "description",
                      `String
                        "Byte offset to start returning content from (default: \
                         0)" );
                    ("default", `Int 0);
                  ] );
            ] );
        ("required", `List [ `String "url" ]);
      ]
end

let whitespace_re = Re.compile Re.(rep1 blank)

let headers =
  Http.Header.of_list
    [
      ( "User-Agent",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" );
    ]

let truncate_at max_length content =
  if max_length > 0 && String.length content > max_length then
    String.sub content 0 max_length ^ "... [content truncated]"
  else content

let slice_from_offset start_from content =
  if start_from > 0 && start_from < String.length content then
    String.sub content start_from (String.length content - start_from)
  else if start_from >= String.length content then ""
  else content

let rec get_with_redirects ~sw ~client ~headers ~max_redirects current_url =
  let current_url =
    if
      String.starts_with ~prefix:"https://" current_url
      || String.starts_with ~prefix:"https://" current_url
    then current_url
    else (
      Logs.info (fun m ->
          m "No http transport specified in '%s', adding https:// to the url."
            current_url);
      Printf.sprintf "https://%s" current_url)
  in

  (* Check for too many redirects *)
  if max_redirects < 0 then Error "Too many redirects"
  else
    let resp, body =
      Cohttp_eio.Client.get ~sw ~headers client (Uri.of_string current_url)
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
              Uri.resolve "" (Uri.of_string current_url) (Uri.of_string new_url)
            in
            get_with_redirects ~sw ~client ~headers
              ~max_redirects:(max_redirects - 1) (Uri.to_string new_uri))
    | status ->
        let _ = Eio.Flow.read_all body in
        Error
          (Printf.sprintf "Could not access the webpage (%s)"
             (Http.Status.to_string status))

let fetch_markdown ~sw ~net ~clock ~rate_limiter ?(max_length = 8192)
    ?(start_from = 0) ~use_trafilatura url =
  try
    if use_trafilatura then
      let ic =
        (* Drop images but keep formatting and urls, not yet sure what is the best choice here *)
        Unix.open_process_args_in "trafilatura"
          [| "markdown"; "--formatting"; "--links"; "-u"; url |]
      in
      let output = In_channel.input_all ic in
      let exit_code = Unix.close_process_in ic in
      match exit_code with
      | WEXITED 0 ->
          let sliced_text = slice_from_offset start_from output in
          let truncated_text = truncate_at max_length sliced_text in
          Logs.info (fun m ->
              m "Successfully fetched and parsed content (%d characters)"
                (String.length truncated_text));
          Ok truncated_text
      | WEXITED n | WSIGNALED n | WSTOPPED n ->
          Error
            (Printf.sprintf
               "Failed to fetch content using trafilatura (error code %d): %s" n
               output)
    else (
      Rate_limiter.acquire rate_limiter clock;
      Logs.info (fun m -> m "Fetching content from: %s" url);
      let client = Cohttp_eio.Client.make ~https:(Some (Https.make ())) net in
      let url = "https://r.jina.ai/" ^ url in
      let headers = Http.Header.add headers "X-Base" "final" in
      let headers =
        if start_from > 0 then
          Http.Header.add headers "Range"
            (Printf.sprintf "bytes=%d-" start_from)
        else headers
      in

      (* Use the get_with_redirects function to handle redirects *)
      match Cohttp_eio.Client.get ~sw ~headers client (Uri.of_string url) with
      | resp, body when resp.status = `OK ->
          let content =
            Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int
          in
          (* If server doesn't support Range requests, slice the content manually *)
          let sliced_content =
            if resp.status = `Partial_content then content
            else slice_from_offset start_from content
          in
          let truncated_text = truncate_at max_length sliced_content in
          Logs.info (fun m ->
              m "Successfully fetched content (%d characters)"
                (String.length truncated_text));
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

let fetch_and_parse ~sw ~net ~clock ~rate_limiter ?(max_length = 8192)
    ?(start_from = 0) url =
  try
    Rate_limiter.acquire rate_limiter clock;
    Logs.info (fun m -> m "Fetching content from: %s" url);
    let client = Cohttp_eio.Client.make ~https:(Some (Https.make ())) net in

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

        let sliced_text = slice_from_offset start_from text in
        let truncated_text = truncate_at max_length sliced_text in
        Logs.info (fun m ->
            m "Successfully fetched and parsed content (%d characters)"
              (String.length truncated_text));
        Ok truncated_text
  with ex ->
    Error
      (Printf.sprintf
         "An unexpected error occurred while fetching the webpage (%s)"
         (Printexc.to_string ex))
