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

Start the MCP server:
```bash
dune exec ./bin/ddg_mcp
```

The server will start and listen for MCP protocol messages on standard input/output.

### Testing the Server

You can test if the server is working by sending MCP protocol messages. For example, to list available tools:

```bash
curl -X POST http://localhost:8080 -H "Content-Type: application/json" -d '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/list"
}'
```

Expected response:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "tools": [
      {
        "description": "Fetch and parse content from a webpage URL.",
        "name": "fetch_content",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url": {
              "type": "string",
              "description": "The webpage URL to fetch content from"
            }
          },
          "required": ["url"]
        }
      },
      {
        "description": "Search DuckDuckGo and return formatted results.",
        "name": "search",
        "inputSchema": {
          "type": "object",
          "properties": {
            "query": {
              "type": "string",
              "description": "The search query string"
            },
            "max_results": {
              "type": "integer",
              "description": "Maximum number of results to return (default: 10)"
            }
          },
          "required": ["query"]
        }
      }
    ]
  }
}
```
or using the stdio interface, you can send a request like this:

```bash
echo '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"search","arguments":{"query":"Where is groningen"}},"id":2}' | dune exec ./bin/ddg_mcp.exe -- --stdio | jq
```

For the output, I'll let you try.

## Installation

### Build from Source

1. Clone the repository and run
```bash
$ cd ddg_mcp
$ opam install . --deps-only
$ dune build
$ dune install
```

### Integration with MCP Clients

This server can be integrated with any MCP-compatible client. Configure your client to connect to this server using the appropriate transport method.

## Rate Limiting

The server implements rate limiting to be respectful to external services:
- **Search requests**: Limited to 30 requests per minute
- **Content fetching**: Limited to 20 requests per minute
