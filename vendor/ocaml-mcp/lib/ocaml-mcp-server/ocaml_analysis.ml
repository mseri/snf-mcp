(** OCaml code analysis - module signatures and build artifacts *)

open Eio

(* Setup logging *)
let src = Logs.Src.create "ocaml-analysis" ~doc:"OCaml analysis logging"

module Log = (val Logs.src_log src : Logs.LOG)

(** Read and parse a .cmi file to extract module signature *)
let read_cmi_signature ~cmi_path =
  try
    let cmi = Cmi_format.read_cmi cmi_path in
    (* Format the signature *)
    let buf = Buffer.create 1024 in
    let ppf = Format.formatter_of_buffer buf in
    Printtyp.signature ppf cmi.Cmi_format.cmi_sign;
    Format.pp_print_flush ppf ();
    Ok (Buffer.contents buf)
  with
  | Cmi_format.Error err ->
      Error (Format.asprintf "CMI format error: %a" Cmi_format.report_error err)
  | exn ->
      Error
        (Printf.sprintf "Failed to read CMI file: %s" (Printexc.to_string exn))

(** Read and parse a .cmt file to extract information *)
let read_cmt_file ~cmt_path =
  try
    let cmt = Cmt_format.read_cmt cmt_path in
    Ok cmt
  with
  | Cmt_format.Error _ -> Error "CMT format error"
  | exn ->
      Error
        (Printf.sprintf "Failed to read CMT file: %s" (Printexc.to_string exn))

(** Find .cmi or .cmt file for a module using Eio *)
let find_build_artifact ~env ~project_root ~module_path ~extension =
  let fs = Stdenv.fs env in
  let module_name =
    match module_path with [] -> None | path -> Some (String.concat "." path)
  in
  match module_name with
  | None -> None
  | Some name ->
      let lowercase_name = String.lowercase_ascii name in
      let filename = lowercase_name ^ extension in
      let build_dir = Filename.concat project_root "_build" in

      (* Search in common locations *)
      let search_paths =
        [
          Filename.concat build_dir "default";
          Filename.concat build_dir "_private/.pkg";
          build_dir;
        ]
      in

      (* Recursively search for the file using Eio *)
      let rec search_in_dir dir =
        let dir_path = Path.(fs / dir) in
        match Path.kind ~follow:true dir_path with
        | `Directory -> (
            try
              let entries = Path.read_dir dir_path in
              List.find_map
                (fun entry ->
                  let path = Filename.concat dir entry in
                  if entry = filename then
                    match Path.kind ~follow:true Path.(fs / path) with
                    | `Regular_file -> Some path
                    | _ -> None
                  else
                    match Path.kind ~follow:true Path.(fs / path) with
                    | `Directory -> search_in_dir path
                    | _ -> None)
                entries
            with _ -> None)
        | _ -> None
      in

      (* Try each search path *)
      List.find_map search_in_dir search_paths

(** Get module signature from build artifacts *)
let get_module_signature ~env ~project_root ~module_path =
  (* First try .cmi file *)
  match
    find_build_artifact ~env ~project_root ~module_path ~extension:".cmi"
  with
  | Some cmi_path ->
      Log.debug (fun m -> m "Found .cmi file at: %s" cmi_path);
      read_cmi_signature ~cmi_path
  | None -> (
      (* Try .cmt file as fallback *)
      match
        find_build_artifact ~env ~project_root ~module_path ~extension:".cmt"
      with
      | Some cmt_path -> (
          Log.debug (fun m -> m "Found .cmt file at: %s" cmt_path);
          match read_cmt_file ~cmt_path with
          | Ok cmt -> (
              match cmt.Cmt_format.cmt_annots with
              | Implementation _ ->
                  Error
                    "Found implementation (.cmt) but no interface. Consider \
                     generating an .mli file."
              | Interface sg ->
                  let buf = Buffer.create 1024 in
                  let ppf = Format.formatter_of_buffer buf in
                  Printtyp.signature ppf sg.sig_type;
                  Format.pp_print_flush ppf ();
                  Ok (Buffer.contents buf)
              | _ -> Error "No type information in .cmt file")
          | Error e -> Error e)
      | None ->
          Error
            (Printf.sprintf
               "Could not find module %s in build artifacts. Make sure the \
                project is built with dune."
               (String.concat "." module_path)))
