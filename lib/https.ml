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
