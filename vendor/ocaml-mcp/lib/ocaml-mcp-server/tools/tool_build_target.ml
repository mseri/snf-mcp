(** Dune build target tool *)

open Mcp_sdk
open Eio

type args = { targets : string list } [@@deriving yojson]

let name = "dune/build-target"
let description = "Build specific files/libraries/tests"

let handle _sw env project_root _dune_rpc args _ctx =
  let output_lines = ref [] in
  let add_line line = output_lines := line :: !output_lines in

  add_line
    (Printf.sprintf "Building targets: %s" (String.concat " " args.targets));

  let process_mgr = Stdenv.process_mgr env in

  (* Run dune build using Eio.Process *)
  let stdout_buf = Buffer.create 1024 in
  let stderr_buf = Buffer.create 1024 in

  let build_succeeded =
    try
      (* Change to project directory for the command *)
      let cwd = Eio.Path.(Stdenv.fs env / project_root) in
      Process.run process_mgr
        ("dune" :: "build" :: args.targets)
        ~cwd
        ~stdout:(Flow.buffer_sink stdout_buf)
        ~stderr:(Flow.buffer_sink stderr_buf);
      true
    with
    | Eio.Exn.Io (Process.E (Process.Child_error _), _) ->
        (* Process exited with non-zero status *)
        false
    | _ -> false
  in

  (* Collect output *)
  let stdout_content = Buffer.contents stdout_buf in
  let stderr_content = Buffer.contents stderr_buf in

  let stdout_lines =
    if stdout_content = "" then [] else String.split_on_char '\n' stdout_content
  in
  let stderr_lines =
    if stderr_content = "" then [] else String.split_on_char '\n' stderr_content
  in

  List.iter (fun line -> if line <> "" then add_line line) stdout_lines;
  List.iter (fun line -> if line <> "" then add_line line) stderr_lines;

  if build_succeeded then (
    (* Only add "Success" if dune didn't already output it *)
    let has_success =
      List.exists
        (fun line ->
          String.trim line = "Success" || String.trim line = "Success.")
        !output_lines
    in
    if not has_success then add_line "Success";
    Ok (Tool_result.text (String.concat "\n" (List.rev !output_lines))))
  else (
    (* Don't add "Build failed" if we already have error output from dune *)
    if List.length !output_lines = 1 then add_line "Build failed";
    Ok (Tool_result.error (String.concat "\n" (List.rev !output_lines))))

let register server ~sw ~env ~project_root ~dune_rpc =
  Server.tool server name ~description
    ~args:
      (module struct
        type t = args

        let to_yojson = args_to_yojson
        let of_yojson = args_of_yojson

        let schema () =
          `Assoc
            [
              ("type", `String "object");
              ( "properties",
                `Assoc
                  [
                    ( "targets",
                      `Assoc
                        [
                          ("type", `String "array");
                          ("items", `Assoc [ ("type", `String "string") ]);
                        ] );
                  ] );
              ("required", `List [ `String "targets" ]);
            ]
      end)
    (handle sw env project_root dune_rpc)
