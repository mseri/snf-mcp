(lang dune 3.17)

(name ddg_mcp)

(generate_opam_files true)

(source
 (github mseri/ddg_mcp))

(authors "Marcello Seri <marcello.seri@gmail.com>")

(maintainers "Marcello Seri <marcello.seri@gmail.com>")

(license ISC)

(documentation https://github.com/mseri/ddg_mcp)

(package
 (name ddg_mcp)
 (synopsis "A Model Context Protocol server for DuckDuckGo search and web content fetching")
 (description "A Model Context Protocol (MCP) server that provides DuckDuckGo search and web content fetching capabilities, written in OCaml using the Eio asynchronous runtime. Includes rate limiting and full MCP protocol compatibility.")
 (depends
  ocaml
  dune
  ca-certs
  eio
  eio_main
  cohttp
  cohttp-eio
  jsonrpc
  lambdasoup
  (mirage-crypto-rng (>= 1.2.0))
  re
  tls-eio
  (yojson (< 3.0.0))
  uri)
 (tags
  ("mcp" "duckduckgo" "search" "web" "eio" "async" "protocol")))
