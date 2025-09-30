open Snf

(* Helper for extracting string value from JSON arguments *)
let get_string_param json name =
  match Yojson.Safe.Util.(member name json |> to_string_option) with
  | Some value -> Ok value
  | _ -> Error (Printf.sprintf "Missing or invalid string parameter: %s" name)

let get_int_param json name default =
  match Yojson.Safe.Util.(member name json) with
  | `String s -> Option.value (int_of_string_opt s) ~default
  | `Int i -> i
  | _ -> default

(* MCP SDK imports *)
(* Command-line argument parsing *)
type server_mode = Stdio | Port of int

let log_level = ref Logs.Error
let server_mode = ref Stdio
let set_port port = server_mode := Port port
let set_stdio () = server_mode := Stdio

let spec =
  [
    ("--serve", Arg.Int set_port, " Run http server, listening on PORT");
    ( "--stdio",
      Arg.Unit set_stdio,
      " Use stdio for communication instead of port (default)" );
    ( "--debug",
      Arg.Unit (fun () -> log_level := Logs.Debug),
      " Enable debug logging" );
    ( "--verbose",
      Arg.Unit (fun () -> log_level := Logs.Info),
      " Enable verbose logging" );
    ( "--quiet",
      Arg.Unit (fun () -> log_level := Logs.Error),
      " Suppress non-error logs (default)" );
  ]

let usage_msg = "snf-mcp [--serve PORT | --stdio]"

let () =
  Arg.parse spec (fun _ -> ()) usage_msg;

  Logs.set_level (Some !log_level);
  Logs.set_reporter (Logs_fmt.reporter ());

  let use_trafilatura =
    if Sys.win32 then (
      Logs.info (fun m -> m "We are on windows, falling back to jina reader");
      false)
    else
      match Sys.command "command -v trafilatura > /dev/null 2>&1" with
      | 0 ->
          Logs.info (fun m -> m "Trafilatura is available");
          true
      | _ ->
          Logs.info (fun m ->
              m "Trafilatura is not available, falling back to jina reader");
          false
  in

  Eio_main.run @@ fun env ->
  let search_rate_limiter = Rate_limiter.create 30 in
  let fetch_rate_limiter = Rate_limiter.create 20 in
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in

  let server =
    Mcp_sdk_eio.Server.create
      ~server_info:{ name = "search-and-fetch"; version = "0.2.1" }
      ()
  in

  let register_tools sw =
    Mcp_sdk_eio.Server.tool server "search" ~title:"DuckDuckGo Search"
      ~description:
        "Search the web with DuckDuckGo and return results in a json object \
         that includes title, url, and a brief description. The content of the \
         results can be accessed using the fetch_* tools. Prefer fetching the \
         markdown to reduce token usage."
      ~args:(module Search.Args)
      (fun args _ctx ->
        let fmt_err msg =
          {
            Mcp.Request.Tools.Call.content =
              [
                Mcp.Types.Content.Text
                  { type_ = "text"; text = msg; meta = None };
              ];
            is_error = Some true;
            structured_content = None;
            meta = None;
          }
        in
        let promise, resolver = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
            let result =
              match
                let args = Search.Args.to_yojson args in
                ( get_string_param args "query",
                  get_int_param args "max_results" 10 )
              with
              | Error msg, _ -> Ok (fmt_err msg)
              | Ok query, max_results -> (
                  match
                    Search.search ~sw ~net ~clock
                      ~rate_limiter:search_rate_limiter query max_results
                  with
                  | Ok results ->
                      let output =
                        `String (Search.format_results_for_llm results)
                      in
                      Ok
                        {
                          Mcp.Request.Tools.Call.content =
                            [
                              Mcp.Types.Content.Text
                                {
                                  type_ = "text";
                                  text = Yojson.Safe.to_string output;
                                  meta = None;
                                };
                            ];
                          is_error = Some false;
                          structured_content = Some output;
                          meta = None;
                        }
                  | Error msg -> Ok (fmt_err msg))
            in
            Eio.Promise.resolve resolver result);
        promise);

    Mcp_sdk_eio.Server.tool server "search_wikipedia" ~title:"Wikipedia Search"
      ~description:
        "Search Wikipedia and return results in a json object that includes \
         title, url, and a brief description. The content of the results can \
         be accessed using the fetch_* tools. Prefer fetching the markdown to \
         reduce token usage."
      ~args:(module Search.Args)
      (fun args _ctx ->
        let fmt_err msg =
          {
            Mcp.Request.Tools.Call.content =
              [
                Mcp.Types.Content.Text
                  { type_ = "text"; text = msg; meta = None };
              ];
            is_error = Some true;
            structured_content = None;
            meta = None;
          }
        in
        let promise, resolver = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
            let result =
              match
                let args = Search.Args.to_yojson args in
                ( get_string_param args "query",
                  get_int_param args "max_results" 10 )
              with
              | Error msg, _ -> Ok (fmt_err msg)
              | Ok query, max_results -> (
                  match
                    Search.search_wikipedia ~sw ~net ~clock
                      ~rate_limiter:search_rate_limiter ~max_results query
                  with
                  | Ok results ->
                      let output =
                        `String (Search.format_results_for_llm results)
                      in
                      Ok
                        {
                          Mcp.Request.Tools.Call.content =
                            [
                              Mcp.Types.Content.Text
                                {
                                  type_ = "text";
                                  text = Yojson.Safe.to_string output;
                                  meta = None;
                                };
                            ];
                          is_error = Some false;
                          structured_content = Some output;
                          meta = None;
                        }
                  | Error msg -> Ok (fmt_err msg))
            in
            Eio.Promise.resolve resolver result);
        promise);

    Mcp_sdk_eio.Server.tool server "fetch_content" ~title:"Fetch Web Content"
      ~description:
        "Fetch content from a webpage URL, stripping it of unnecessary html \
         tags."
      ~args:(module Fetch.FetchContentArgs)
      (fun args _ctx ->
        let fmt_err msg =
          {
            Mcp.Request.Tools.Call.content =
              [
                Mcp.Types.Content.Text
                  { type_ = "text"; text = msg; meta = None };
              ];
            is_error = Some true;
            structured_content = None;
            meta = None;
          }
        in
        let promise, resolver = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
            let result =
              match
                let args = Fetch.FetchContentArgs.to_yojson args in
                ( get_string_param args "url",
                  get_int_param args "max_length" 8192,
                  get_int_param args "start_from" 0 )
              with
              | Error msg, _, _ -> Ok (fmt_err msg)
              | Ok url, max_length, start_from -> (
                  match
                    Fetch.fetch_and_parse ~sw ~net ~clock
                      ~rate_limiter:fetch_rate_limiter ~max_length ~start_from
                      url
                  with
                  | Ok content ->
                      let output = `String content in
                      Ok
                        {
                          Mcp.Request.Tools.Call.content =
                            [
                              Mcp.Types.Content.Text
                                {
                                  type_ = "text";
                                  text = Yojson.Safe.to_string output;
                                  meta = None;
                                };
                            ];
                          is_error = Some false;
                          structured_content = Some output;
                          meta = None;
                        }
                  | Error msg -> Ok (fmt_err msg))
            in
            Eio.Promise.resolve resolver result);
        promise);

    Mcp_sdk_eio.Server.tool server "fetch_markdown"
      ~title:"Fetch Markdown Content"
      ~description:
        "Fetch and parse content from a webpage URL as Markdown, preserving \
         links and formatting. Prefer this method to reduce token usage."
      ~args:(module Fetch.FetchMarkdownArgs)
      (fun args _ctx ->
        let fmt_err msg =
          {
            Mcp.Request.Tools.Call.content =
              [
                Mcp.Types.Content.Text
                  { type_ = "text"; text = msg; meta = None };
              ];
            is_error = Some true;
            structured_content = None;
            meta = None;
          }
        in
        let promise, resolver = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
            let result =
              match
                let args = Fetch.FetchMarkdownArgs.to_yojson args in
                ( get_string_param args "url",
                  get_int_param args "max_length" 8192,
                  get_int_param args "start_from" 0 )
              with
              | Error msg, _, _ -> Ok (fmt_err msg)
              | Ok url, max_length, start_from -> (
                  (* Instead of using max_length to cut the content, we should use Cursor.t to allow for batched fetching of content in chunks *)
                  match
                    Fetch.fetch_markdown ~sw ~net ~clock
                      ~rate_limiter:fetch_rate_limiter ~max_length ~start_from
                      ~use_trafilatura url
                  with
                  | Ok content ->
                      let output = `String content in
                      Ok
                        {
                          Mcp.Request.Tools.Call.content =
                            [
                              Mcp.Types.Content.Text
                                {
                                  type_ = "text";
                                  text = Yojson.Safe.to_string output;
                                  meta = None;
                                };
                            ];
                          is_error = Some false;
                          structured_content = Some output;
                          meta = None;
                        }
                  | Error msg -> Ok (fmt_err msg))
            in
            Eio.Promise.resolve resolver result);
        promise)
  in

  (* let on_error exn =
    Logs.err (fun m ->
        m "Unhandled server error: %s\n%s" (Printexc.to_string exn)
          (Printexc.get_backtrace ()))
  in *)
  Eio.Switch.run @@ fun sw ->
  register_tools sw;

  match !server_mode with
  | Stdio ->
      Logs.info (fun m -> m "Starting MCP server in stdio mode");
      let stdin = Eio.Stdenv.stdin env in
      let stdout = Eio.Stdenv.stdout env in
      let transport = Mcp_eio.Stdio.create ~stdin ~stdout in
      let clock = Eio.Stdenv.clock env in
      let connection =
        Mcp_eio.Connection.create ~clock (module Mcp_eio.Stdio) transport
      in
      Mcp_sdk_eio.Server.run ~sw ~env server connection
  | Port port ->
      Logs.info (fun m -> m "Starting MCP server on port %d" port);
      let transport = Mcp_eio.Http.create_server ~sw ~port () in
      let clock = Eio.Stdenv.clock env in
      let connection =
        Mcp_eio.Connection.create ~clock (module Mcp_eio.Http) transport
      in
      Logs.info (fun m ->
          m "MCP HTTP Server listening on http://localhost:%d" port);

      Eio.Fiber.fork ~sw (fun () -> Mcp_eio.Http.run_server transport env);
      Mcp_sdk_eio.Server.run ~sw ~env server connection
