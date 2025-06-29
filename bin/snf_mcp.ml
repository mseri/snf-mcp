open Eio.Std
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

let usage_msg = "ddg_mcp [--serve PORT | --stdio]"

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
    Mcp_sdk.create_server ~name:"ocaml-search-and-fetch" ~version:"0.2.0" ()
    |> fun server -> Mcp_sdk.configure_server server ~with_tools:true ()
  in

  let _ =
    Mcp_sdk.add_tool server ~name:"search"
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
        Switch.run @@ fun sw ->
        match
          (get_string_param args "query", get_int_param args "max_results" 10)
        with
        | Error msg, _ -> Mcp_sdk.Tool.create_error_result msg
        | Ok query, max_results -> (
            match
              Search.search ~sw ~net ~clock ~rate_limiter:search_rate_limiter
                query max_results
            with
            | Ok results ->
                let results = Search.format_results_for_llm results in
                Mcp_sdk.Tool.create_tool_result
                  [ Mcp.make_text_content results ]
                  ~is_error:false
            | Error msg -> Mcp_sdk.Tool.create_error_result msg))
  in

  let _ =
    Mcp_sdk.add_tool server ~name:"search_wikipedia"
      ~description:"Search Wikipedia and return formatted results."
      ~schema_properties:
        [
          ("query", "string", "The search query string");
          ( "max_results",
            "integer",
            "Maximum number of results to return (default: 10)" );
        ]
      ~schema_required:[ "query" ]
      (fun args ->
        Switch.run @@ fun sw ->
        match
          (get_string_param args "query", get_int_param args "max_results" 10)
        with
        | Error msg, _ -> Mcp_sdk.Tool.create_error_result msg
        | Ok query, max_results -> (
            match
              Search.search_wikipedia ~sw ~net ~clock
                ~rate_limiter:search_rate_limiter ~max_results query
            with
            | Ok results ->
                let results = Search.format_results_for_llm results in
                Mcp_sdk.Tool.create_tool_result
                  [ Mcp.make_text_content results ]
                  ~is_error:false
            | Error msg -> Mcp_sdk.Tool.create_error_result msg))
  in

  let _ =
    Mcp_sdk.add_tool server ~name:"fetch_content"
      ~description:"Fetch and parse content from a webpage URL."
      ~schema_properties:
        [
          ("url", "string", "The webpage URL to fetch content from");
          ( "max_length",
            "integer",
            "Maximum length (in bytes) of content to return (default: 8192 \
             characters). Use -1 to disable the limit." );
        ]
      ~schema_required:[ "url" ]
      (fun args ->
        Switch.run @@ fun sw ->
        match
          (get_string_param args "url", get_int_param args "max_length" 8192)
        with
        | Error msg, _ -> Mcp_sdk.Tool.create_error_result msg
        | Ok url, max_length -> (
            match
              Fetch.fetch_and_parse ~sw ~net ~clock
                ~rate_limiter:fetch_rate_limiter ~max_length url
            with
            | Ok content ->
                Mcp_sdk.Tool.create_tool_result
                  [ Mcp.make_text_content content ]
                  ~is_error:false
            | Error msg -> Mcp_sdk.Tool.create_error_result msg))
  in

  let _ =
    Mcp_sdk.add_tool server ~name:"fetch_markdown"
      ~description:"Fetch and parse content from a webpage URL as Markdown."
      ~schema_properties:
        [
          ("url", "string", "The webpage URL to fetch content from");
          ( "max_length",
            "integer",
            "Maximum length (in bytes) of content to return (default: 8192 \
             characters). Use -1 to disable the limit." );
        ]
      ~schema_required:[ "url" ]
      (fun args ->
        Switch.run @@ fun sw ->
        match
          (get_string_param args "url", get_int_param args "max_length" 8192)
        with
        | Error msg, _ -> Mcp_sdk.Tool.create_error_result msg
        | Ok url, max_length -> (
            (* Instead of using max_length to cut the content, we should use Cursor.t to allow for batched fetching of content in chunks *)
            match
              Fetch.fetch_markdown ~sw ~net ~clock
                ~rate_limiter:fetch_rate_limiter ~max_length ~use_trafilatura
                url
            with
            | Ok content ->
                Mcp_sdk.Tool.create_tool_result
                  [ Mcp.make_text_content content ]
                  ~is_error:false
            | Error msg -> Mcp_sdk.Tool.create_error_result msg))
  in

  let on_error exn =
    Logs.err (fun m ->
        m "Unhandled server error: %s\n%s" (Printexc.to_string exn)
          (Printexc.get_backtrace ()))
  in

  match !server_mode with
  | Stdio ->
      Logs.info (fun m -> m "Starting MCP server in stdio mode");
      Mcp_server.run_sdtio_server env server
  | Port port ->
      Logs.info (fun m -> m "Starting MCP server on port %d" port);
      Mcp_server.run_server env server ~port ~on_error
