Test SNF MCP Server basic functionality

Test that calling tools/list without initialization fails with proper error:
  $ echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | snf-mcp --stdio --quiet 2>/dev/null | jq -c '.error'
  {"code":-32600,"message":"Server not initialized"}

Test proper server initialization:
  $ echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | snf-mcp --stdio --quiet 2>/dev/null | jq -c '.result.serverInfo.name'
  "search-and-fetch"

Test server reports correct capabilities:
  $ echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | snf-mcp --stdio --quiet 2>/dev/null | jq -c '.result.capabilities | keys'
  ["logging","tools"]

Test tools/list after initialization:
  $ { echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' ; echo '{"jsonrpc":"2.0","method":"tools/list","id":2}'; } | snf-mcp --stdio --quiet 2>/dev/null
  {"id":1,"jsonrpc":"2.0","result":{"protocolVersion":"2025-06-18","capabilities":{"logging":{"enabled":true},"tools":{"listChanged":false}},"serverInfo":{"name":"search-and-fetch","version":"0.2.1"}}}
  {"id":2,"jsonrpc":"2.0","result":{"tools":[{"name":"fetch_markdown","title":"Fetch Markdown Content","description":"Fetch and parse content from a webpage URL as Markdown, preserving links and formatting.","inputSchema":{"type":"object","properties":{"url":{"type":"string","description":"The webpage URL to fetch content from"},"max_length":{"type":"integer","description":"Maximum length (in bytes) of content to return (default: 8192 characters). Use -1 to disable the limit.","default":8192},"start_from":{"type":"integer","description":"Byte offset to start returning content from (default: 0)","default":0}},"required":["url"]}},{"name":"search","title":"DuckDuckGo Search","description":"Search the web with DuckDuckGo and return results in a json object that includes title, url, and a brief description. The content of the results can be accessed using the fetch_* tools.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"The search query string"},"max_results":{"type":"integer","description":"Maximum number of results to return (default: 10)","default":10}},"required":["query"]}},{"name":"fetch_content","title":"Fetch Web Content","description":"Fetch content from a webpage URL, stripping it of unnecessary html tags.","inputSchema":{"type":"object","properties":{"url":{"type":"string","description":"The webpage URL to fetch content from"},"max_length":{"type":"integer","description":"Maximum length (in bytes) of content to return (default: 8192 characters). Use -1 to disable the limit.","default":8192},"start_from":{"type":"integer","description":"Byte offset to start returning content from (default: 0)","default":0}},"required":["url"]}},{"name":"search_wikipedia","title":"Wikipedia Search","description":"Search Wikipedia and return results in a json object that includes title, url, and a brief description. The content of the results can be accessed using the fetch_* tools.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"The search query string"},"max_results":{"type":"integer","description":"Maximum number of results to return (default: 10)","default":10}},"required":["query"]}}]}}

Test that invalid JSON-RPC method fails:
  $ { echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' ; echo '{"jsonrpc":"2.0","method":"something","id":2}'; } | dune exec snf-mcp -- --stdio --quiet
  {"id":1,"jsonrpc":"2.0","result":{"protocolVersion":"2025-06-18","capabilities":{"logging":{"enabled":true},"tools":{"listChanged":false}},"serverInfo":{"name":"search-and-fetch","version":"0.2.1"}}}
  snf-mcp: [ERROR] Failed to parse message: Unknown method: something
