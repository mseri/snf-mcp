open Snf
open Mcp_sdk

(* Define argument types in separate modules to avoid naming conflicts *)
module Search_args = struct
  type t = { query : string; max_results : int option } [@@deriving yojson]
end

module Fetch_args = struct
  type t = { url : string; max_length : int option } [@@deriving yojson]
end

type server_mode = Stdio | Port of int

(* Command-line argument parsing *)
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

let usage_msg = "snf-mcp [options]"

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
  Eio.Switch.run @@ fun sw ->
  let search_rate_limiter = Rate_limiter.create 30 in
  let fetch_rate_limiter = Rate_limiter.create 20 in
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in

  (* Create server using new SDK *)
  let server =
    Server.create
      ~server_info:{ name = "ocaml-search-and-fetch"; version = "0.2.0" }
      ()
  in

  (* Register search tool *)
  Server.tool server "search" ~title:"Search DuckDuckGo"
    ~description:"Search DuckDuckGo and return formatted results."
    ~args:
      (module struct
        type t = Search_args.t

        let to_yojson = Search_args.to_yojson
        let of_yojson = Search_args.of_yojson

        let schema () =
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("query", `Assoc [ ("type", `String "string") ]);
                    ("max_results", `Assoc [ ("type", `String "integer") ]);
                  ] );
              ("required", `List [ `String "query" ]);
            ]
      end)
    (fun args _ctx ->
      let max_results = Option.value args.max_results ~default:10 in

      Search.search ~sw ~net ~clock ~rate_limiter:search_rate_limiter args.query
        max_results
      |> Result.map (fun results ->
             let results = Search.format_results_for_llm results in
             {
               Mcp.Request.Tools.Call.content =
                 [ Mcp.Types.Content.Text { type_ = "text"; text = results } ];
               is_error = None;
               structured_content = None;
             }));

  (* Register search_wikipedia tool *)
  Server.tool server "search_wikipedia" ~title:"Search Wikipedia"
    ~description:"Search Wikipedia and return formatted results."
    ~args:
      (module struct
        type t = Search_args.t

        let to_yojson = Search_args.to_yojson
        let of_yojson = Search_args.of_yojson

        let schema () =
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("query", `Assoc [ ("type", `String "string") ]);
                    ("max_results", `Assoc [ ("type", `String "integer") ]);
                  ] );
              ("required", `List [ `String "query" ]);
            ]
      end)
    (fun args _ctx ->
      let max_results = Option.value args.max_results ~default:10 in

      Search.search_wikipedia ~sw ~net ~clock ~rate_limiter:search_rate_limiter
        ~max_results args.query
      |> Result.map (fun results ->
             let results = Search.format_results_for_llm results in
             {
               Mcp.Request.Tools.Call.content =
                 [ Mcp.Types.Content.Text { type_ = "text"; text = results } ];
               is_error = None;
               structured_content = None;
             }));

  (* Register fetch_content tool *)
  Server.tool server "fetch_content" ~title:"Fetch Content"
    ~description:"Fetch and parse content from a webpage URL."
    ~args:
      (module struct
        type t = Fetch_args.t

        let to_yojson = Fetch_args.to_yojson
        let of_yojson = Fetch_args.of_yojson

        let schema () =
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("url", `Assoc [ ("type", `String "string") ]);
                    ("max_length", `Assoc [ ("type", `String "integer") ]);
                  ] );
              ("required", `List [ `String "url" ]);
            ]
      end)
    (fun args _ctx ->
      let max_length = Option.value args.max_length ~default:8192 in
      Fetch.fetch_and_parse ~sw ~net ~clock ~rate_limiter:fetch_rate_limiter
        ~max_length args.url
      |> Result.map (fun content ->
             {
               Mcp.Request.Tools.Call.content =
                 [ Mcp.Types.Content.Text { type_ = "text"; text = content } ];
               is_error = None;
               structured_content = None;
             }));

  (* Register fetch_markdown tool *)
  Server.tool server "fetch_markdown" ~title:"Fetch Markdown"
    ~description:"Fetch and parse content from a webpage URL as Markdown."
    ~args:
      (module struct
        type t = Fetch_args.t

        let to_yojson = Fetch_args.to_yojson
        let of_yojson = Fetch_args.of_yojson

        let schema () =
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ("url", `Assoc [ ("type", `String "string") ]);
                    ("max_length", `Assoc [ ("type", `String "integer") ]);
                  ] );
              ("required", `List [ `String "url" ]);
            ]
      end)
    (fun args _ctx ->
      let max_length = Option.value args.max_length ~default:8192 in
      Fetch.fetch_markdown ~sw ~net ~clock ~rate_limiter:fetch_rate_limiter
        ~max_length ~use_trafilatura args.url
      |> Result.map (fun content ->
             {
               Mcp.Request.Tools.Call.content =
                 [ Mcp.Types.Content.Text { type_ = "text"; text = content } ];
               is_error = None;
               structured_content = None;
             }));
  let mcp_server = Server.to_mcp_server server in

  match !server_mode with
  | Stdio ->
      Logs.info (fun m -> m "Starting MCP server in stdio mode");
      let stdin = Eio.Stdenv.stdin env in
      let stdout = Eio.Stdenv.stdout env in
      let transport = Mcp_eio.Stdio.create ~stdin ~stdout in
      let connection =
        Mcp_eio.Connection.create (module Mcp_eio.Stdio) transport
      in

      Logs.info (fun m -> m "Starting MCP server in stdio mode");
      Mcp_eio.Connection.serve ~sw connection mcp_server
  | Port port ->
      Logs.info (fun m -> m "Starting MCP server on port %d" port);
      let net = Eio.Stdenv.net env in
      let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
      let transport = Mcp_eio.Socket.create_client ~net ~sw addr in
      let connection =
        Mcp_eio.Connection.create (module Mcp_eio.Socket) transport
      in
      Mcp_eio.Connection.serve ~sw connection mcp_server
