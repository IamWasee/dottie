---
name: mcp-server-builder
description: Use when building or fixing an MCP server ("make an MCP server", "MCP tool for X", "connect Claude or Gemini to my API"). Covers TypeScript SDK or Python FastMCP, tool design, testing and registering it.
---

# MCP Server Builder

## When to use

- The user wants an AI client (Gemini CLI, Claude Code, Claude Desktop) to reach an API, database, app or files through tools.
- An existing MCP server needs new tools, fixes or testing.

Do not use when:

- A plain script the user runs by hand would do. Write the script.
- The idea is still vague (which service, which actions). Use brainstorming-before-building first.

## Steps

1. Pin down the service and the 3 to 8 jobs the user wants done ("find an issue", "create a note"). Read the service's API docs. Design tools around those jobs, not one tool per endpoint.
2. Pick the stack: Python with FastMCP for quick, small servers; TypeScript SDK when the project is already Node or needs npm libraries. Use stdio transport for local servers (the client starts it as a subprocess).
3. Tool design rules:
   - Names: `snake_case` verbs with a service prefix, e.g. `notes_search`, `notes_create`.
   - Description: what it does, when to use it, what it returns, in two or three sentences. The model only sees this.
   - Inputs: typed and described, with sensible defaults and limits (`limit` default 20, max 100).
   - Output: concise and readable; return the fields a model needs, paginate long lists, offer a `detail` or `format` option instead of dumping raw JSON.
   - Errors: return a clear message saying what went wrong and what to try next, never a stack trace.
   - Mark read-only tools as read-only; make destructive tools need explicit arguments (an id, not "all").
4. Secrets: read API tokens from environment variables (`os.environ["NOTES_TOKEN"]`, `process.env.NOTES_TOKEN`). Never hard-code them or ask the user to paste them into the chat; tell them which variable to set in the client config.
5. Python (FastMCP), in the project folder:
   ```
   python3 -m venv .venv && source .venv/bin/activate
   python3 -m pip install "mcp[cli]" httpx
   ```
   `server.py`: `from mcp.server.fastmcp import FastMCP`, `mcp = FastMCP("notes")`, decorate typed functions with `@mcp.tool()` (the docstring becomes the description), end with `if __name__ == "__main__": mcp.run()`.
6. TypeScript: `npm init -y`, `npm install @modelcontextprotocol/sdk zod`, `npm install -D typescript @types/node`, set `"type": "module"`. In `src/index.ts` create `new McpServer({ name: "notes", version: "1.0.0" })`, add tools with `server.registerTool(name, { description, inputSchema: { query: z.string() } }, handler)` returning `{ content: [{ type: "text", text }] }`, then `await server.connect(new StdioServerTransport())`. Build with `npx tsc`.
7. Never write to stdout except through the SDK on stdio servers; log to stderr (`console.error`, `print(..., file=sys.stderr)`), or the protocol breaks.
8. Test with MCP Inspector: `npx @modelcontextprotocol/inspector python3 server.py` or `npx @modelcontextprotocol/inspector node build/index.js`. It opens a local web page: list tools, call each with normal, empty and bad inputs, read the results. Also add unit tests for the logic behind each tool (test-driven-development).
9. Register it, after showing the user the exact entry and getting their yes (it changes their client config):
   - Gemini CLI: add to `.gemini/settings.json` in the project (or `~/.gemini/settings.json` for all projects):
     ```
     { "mcpServers": { "notes": { "command": "/abs/path/.venv/bin/python3",
       "args": ["/abs/path/server.py"], "env": { "NOTES_TOKEN": "$NOTES_TOKEN" }, "timeout": 30000 } } }
     ```
     or run `gemini mcp add notes /abs/path/.venv/bin/python3 /abs/path/server.py`. Check with `/mcp` inside gemini or `gemini mcp list`.
   - Claude Code: `claude mcp add notes -- /abs/path/.venv/bin/python3 /abs/path/server.py` (add `--scope project` to write `.mcp.json` for the repo, `-e NOTES_TOKEN=...` for env). Check with `claude mcp list`.
10. Write a short `README.md` next to the server: what it does, each tool, required env vars, the config snippets above.

## Tools on a Mac

- Runtimes: `python3 --version` (3.10+ needed for the mcp package), `node --version` (18+). Missing: `brew install python node`.
- Faster Python setup if the user has it: `brew install uv`, then `uv init`, `uv add "mcp[cli]"`, `uv run mcp dev server.py` (dev also opens Inspector).
- Absolute paths for configs: `realpath server.py`, `which node`.
- Try the API before wrapping it: `curl -sS -H "Authorization: Bearer $NOTES_TOKEN" https://api.example.com/v1/notes | python3 -m json.tool | head -40`.
- Validate config JSON: `python3 -m json.tool .gemini/settings.json > /dev/null && echo ok`.

## Quality checklist

- Every tool has a clear description, typed and described inputs, and limits on output size.
- Each tool was called in Inspector with good and bad input and returned a readable result.
- No secrets in code or README; tokens come from env vars.
- Nothing printed to stdout outside the protocol.
- Config uses absolute paths and was added only with the user's yes.

## Reply to the user

"Built the <name> MCP server in output/<folder> with <N> tools; all tested in MCP Inspector. To use it, set <ENV_VAR> and add the entry from the README; want me to register it?"

## Pitfalls

- One tool per REST endpoint, leaving the model to chain ten calls for one job.
- Returning huge raw JSON that floods the model's context.
- `print()` debugging on a stdio server, which corrupts the stream.
- Relative paths or a bare `python3` in config, which resolve differently when the client launches it.
- Using a Python older than 3.10 for the mcp package.
- Tool descriptions that say what the code does but not when to call it.

Based on: anthropics/skills "mcp-builder"
