# lib/core/tools/

Reusable tool definitions available to agents and workflows.

Tools expose discrete capabilities (file I/O, web search, code execution, etc.)
that agents and workflows can call as atomic operations.

## Planned Contents

- `tool.dart` — Abstract `Tool` interface (name, description, execute)
- `file_tool.dart` — Read/write local files
- `web_search_tool.dart` — Internet search capability
- `shell_tool.dart` — Execute shell commands (desktop only)
- `code_runner_tool.dart` — Run and evaluate code snippets
