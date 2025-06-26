# DuckDuckGo MCP Server

A Model Context Protocol (MCP) server that provides DuckDuckGo search and web content fetching capabilities, written in OCaml using the Eio asynchronous runtime.

## Features

- **DuckDuckGo Search**: Search the web using DuckDuckGo's search engine
- **Web Content Fetching**: Fetch and parse content from web pages
- **Rate Limiting**: Built-in rate limiting to respect service limits
- **MCP Protocol**: Fully compatible with the Model Context Protocol specification
- **Asynchronous**: Built on Eio for efficient concurrent operations

## Tools Provided

### `search`
Search DuckDuckGo and return formatted results.

**Parameters:**
- `query` (string, required): The search query string
- `max_results` (integer, optional): Maximum number of results to return (default: 10)

**Example:**
```json
{
  "query": "OCaml programming language",
  "max_results": 5
}
```

### `fetch_content`
Fetch and parse content from a webpage URL.

**Parameters:**
- `url` (string, required): The webpage URL to fetch content from

**Example:**
```json
{
  "url": "https://example.com/article"
}
```

## Usage

### Running the Server

The `ddg_mcp` binary supports two modes of operation:

1. **HTTP Server Mode** (default): Listens on a network port
2. **Standard I/O Mode**: Communicates through stdin/stdout

Start the MCP server in HTTP mode (default port 8080):
```bash
dune exec ./bin/ddg_mcp
```

Or specify a custom port:
```bash
dune exec ./bin/ddg_mcp -- --port 3000
```

Use Standard I/O mode (useful for integrating with LLM clients):
```bash
dune exec ./bin/ddg_mcp -- --stdio
```

When installed via OPAM, you can run it directly:
```bash
ddg_mcp [--port PORT] [--stdio]
```

### Testing the Server

#### HTTP Mode

When running in HTTP mode, you can test if the server is working by sending MCP protocol messages using curl:

**List available tools:**
```bash
curl -X POST http://localhost:8080 -H "Content-Type: application/json" -d '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/list"
}'
```

**Perform a search:**
```bash
curl -X POST http://localhost:8080 -H "Content-Type: application/json" -d '{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "search",
    "arguments": {
      "query": "OCaml programming language",
      "max_results": 3
    }
  }
}'
```

**Fetch webpage content:**
```bash
curl -X POST http://localhost:8080 -H "Content-Type: application/json" -d '{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "fetch_content",
    "arguments": {
      "url": "https://ocaml.org"
    }
  }
}'
```

#### Standard I/O Mode

When using stdio mode, you can pipe JSON-RPC requests to the binary:

```bash
echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | dune exec ./bin/ddg_mcp -- --stdio | jq
```

```bash
echo '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"search","arguments":{"query":"OCaml programming language"}},"id":2}' | dune exec ./bin/ddg_mcp -- --stdio | jq
```

This mode is particularly useful when integrating with LLM clients that communicate over stdin/stdout.

## Installation

### Build from Source

1. Clone the repository
2. Install dependencies and build:
```bash
$ cd ddg_mcp
$ opam install . --deps-only
$ dune build
$ dune install
```

This will make the `ddg_mcp` binary available in your PATH.

### Integration with MCP Clients

This server can be integrated with any MCP-compatible client. Configure your client to connect to this server using the appropriate transport method.

## Rate Limiting

The server implements rate limiting to be respectful to external services:
- **Search requests**: Limited to 30 requests per minute
- **Content fetching**: Limited to 20 requests per minute

## Implementation Details

The server is built on the following technologies:
- **OCaml**: Type-safe functional programming language
- **Eio**: Effect-based I/O library for OCaml with built-in concurrency
- **Lambdasoup**: HTML parsing library used to extract search results and webpage content
- **MCP SDK**: Model Context Protocol library for standardized tool calling
- **Cohttp-eio**: HTTP client/server built on the Eio runtime

## Troubleshooting

### Rate Limiting Issues

If you encounter errors or timeout messages, you might be hitting the rate limits. The server will automatically wait when rate limits are reached, but external services might still block requests if they detect automated usage.

### Search Quality

DuckDuckGo's search results are parsed from the HTML response. If search results appear incorrect or incomplete, it might be due to:
1. DuckDuckGo changing their HTML structure
2. Bot detection preventing proper results
3. Issues with the search query format

Try rephrasing your query or checking if DuckDuckGo's service is functioning normally.
