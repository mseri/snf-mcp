(lang dune 3.17)

(name snf_mcp)

(generate_opam_files true)

(source
 (github mseri/snf_mcp))

(authors "Marcello Seri <marcello.seri@gmail.com>")

(maintainers "Marcello Seri <marcello.seri@gmail.com>")

(license ISC)

(documentation https://github.com/mseri/snf_mcp)

(package
 (name snf_mcp)
 (synopsis "A Model Context Protocol server for web search and content fetching")
 (description "A Model Context Protocol (MCP) server that provides web search and web content fetching capabilities, written in OCaml using the Eio asynchronous runtime. Includes rate limiting and full MCP protocol compatibility.")
 (depends
  ocaml
  dune
  ca-certs
  (eio (>= 0.13))
  eio_main
  fmt
  cohttp
  cohttp-eio
  (jsonrpc (>= 1.7.0))
  lambdasoup
  logs
  (mirage-crypto-rng (>= 1.2.0))
  re
  tls-eio
  (yojson (< 3.0.0))
  uri)
 (tags
  ("mcp" "fetch" "search" "web" "eio" "ocaml")))
