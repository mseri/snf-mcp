# Web fetch and search MCP Server

A Model Context Protocol (MCP) server that provides web search, Wikipedia search, and web content fetching capabilities, written in OCaml using the eio asynchronous runtime.

## Features

- **DuckDuckGo Search**: Search the web using DuckDuckGo's search engine
- **Wikipedia Search**: Search Wikipedia for articles and content
- **Web Content Fetching**: Fetch and parse content from web pages, with support for both cleaned-up HTML and Markdown formats
- **Rate Limiting**: Built-in rate limiting to respect service limits
- **MCP Protocol**: Fully compatible with the Model Context Protocol specification (vendoring <https://tangled.sh/@anil.recoil.org/ocaml-mcp/>)
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

### `search_wikipedia`
Search Wikipedia and return formatted results.

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
- `max_length` (integer, optional): Maximum length (in bytes) of content to return (default: 8192). Set `-1` to disable length limit.
- `start_from` (integer, optional): Byte offset to start returning content from (default: 0)

**Example:**
```json
{
  "url": "https://example.com/article",
  "max_length": 16384,
  "start_from": 1024
}
```

### `fetch_markdown`
Fetch and parse content from a webpage URL as Markdown.

**Parameters:**
- `url` (string, required): The webpage URL to fetch content from
- `max_length` (integer, optional): Maximum length (in bytes) of content to return (default: 8192). Set `-1` to disable length limit.
- `start_from` (integer, optional): Byte offset to start returning content from (default: 0)

**Example:**
```json
{
  "url": "https://example.com/article",
  "max_length": 16384,
  "start_from": 1024
}
```

## Usage

### Running the Server

The `snf-mcp` binary supports two modes of operation:

1. **HTTP Server Mode** (default): Listens on a network port
2. **Standard I/O Mode**: Communicates through stdin/stdout

Caveat: the installed binary is called `snf-mcp`

Start the MCP server in HTTP mode on port 3000:
```bash
dune exec snf-mcp -- --serve 3000
```

Use Standard I/O mode (useful for integrating with LLM clients):
```bash
dune exec snf-mcp
```

When installed via OPAM, you can run it directly:
```bash
snf_mcp [--serve PORT | --stdio]
  --serve  Run http server, listening on PORT
  --stdio  Use stdio for communication instead of port (default)
  --debug  Enable debug logging
  --verbose  Enable verbose logging
  --quiet  Suppress non-error logs (default)
  -help  Display this list of options
  --help  Display this list of options
```

### Testing the Server

#### HTTP Mode

When running in HTTP mode, you can test if the server is working by sending MCP protocol messages using curl.

First start the server with:
```bash
dune exec snf-mcp --serve 8080
```
Then, on a different terminal, you can use `curl` to interact with the server. Here are some example requests:

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

**Search Wikipedia:**
```bash
curl -X POST http://localhost:8080 -H "Content-Type: application/json" -d '{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": {
    "name": "search_wikipedia",
    "arguments": {
      "query": "OCaml programming language",
      "max_results": 3
    }
  }
}'
```

**Fetch webpage content as Markdown:**
```bash
curl -X POST http://localhost:8080 -H "Content-Type: application/json" -d '{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "tools/call",
  "params": {
    "name": "fetch_markdown",
    "arguments": {
      "url": "https://ocaml.org"
    }
  }
}'
```

#### Standard I/O Mode

When using stdio mode, you can pipe JSON-RPC requests to the binary:

```bash
echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | dune exec snf-mcp | jq
```

```bash
echo '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"search","arguments":{"query":"OCaml programming language"}},"id":2}' | dune exec snf-mcp | jq
```

```bash
echo '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"search_wikipedia","arguments":{"query":"OCaml programming language"}},"id":3}' | dune exec snf-mcp | jq
```

```bash
echo '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"fetch_content","arguments":{"url":"https://ocaml.org"}},"id":4}' | dune exec snf-mcp | jq
```

```bash
echo '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"fetch_markdown","arguments":{"url":"https://ocaml.org"}},"id":5}' | dune exec snf-mcp | jq
```

This mode is particularly useful when integrating with LLM clients that communicate over stdin/stdout.

## Installation

### Build from Source

1. Clone the repository
2. Install dependencies and build:
```bash
$ cd snf_mcp
$ opam install . --deps-only
$ dune build
$ dune install
```

This will make the `snf-mcp` binary available in your PATH.

### Integration with MCP Clients

This server can be integrated with any MCP-compatible client. Configure your client to connect to this server using the appropriate transport method.
Below we show how to configure the stdio version, the remote version is very similar.
Keep in mind that this is early software and not recommended for production or to be exposed on unprotected networks.

### LLM CLI

Install the [`llm-tools-mcp` plugin](https://github.com/VirtusLab/llm-tools-mcp) with
```
llm install llm-tools-mcp
```
then edit (or create) `~/.llm-tools-mcp/mcp.json` with
```
{
  "mcpServers": {
    "snf_mcp": {
      "command": "/path/to/snf-mcp",
      "args": [
        "--stdio"
      ]
    }
  }
}
```

#### LMStudio

Edit the json file from the interface adding the same json entry as in the LLM CLI example above.
See also the [official documentation](https://lmstudio.ai/docs/app/plugins/mcp).

#### Jan

Use the _full path_ to snf_mcp as command, and `--stdio` as the only argument.
See also the [official documentation](https://jan.ai/docs/mcp).

Note, _I was only able to configure stdio-based mcp servers_ with Jan.

### Rate Limiting

The server implements rate limiting to be respectful to external services:
- **Search requests (DuckDuckGo and Wikipedia)**: Limited to 30 requests per minute
- **Content fetching**: Limited to 20 requests per minute

## Troubleshooting

### Rate Limiting Issues

If you encounter errors or timeout messages, you might be hitting the rate limits. The server will automatically wait when rate limits are reached, but external services might still block requests if they detect automated usage.

### Search Quality

DuckDuckGo's search results are parsed from the HTML response. If search results appear incorrect or incomplete, it might be due to:
1. DuckDuckGo changing their HTML structure
2. Bot detection preventing proper results
3. Issues with the search query format

Try rephrasing your query or checking if DuckDuckGo's service is functioning normally.

### Content Extraction Quality

The `fetch_markdown` tool tries to use the `trafilatura` Python library if it's available on your system, as it produces higher quality text extraction. If `trafilatura` is not found, it falls back to [jina reader](https://jina.ai/reader/).


For best results, consider installing `trafilatura`, for example in one of the following 3 ways:

```bash
uv tool install trafilatura # Method 1: Using `uv` tool
pipx install trafilatura # Method 2: Using `pipx`
pip install trafilatura # Method 3: Using `pip`
```

# TODO
- Use pagination in the fetch
