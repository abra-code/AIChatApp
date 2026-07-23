#!/usr/bin/env python3
"""mcp_tools_report.py - query the `mlx-agent tools` JSON dump for the MCP inspector.

The inspector window runs `mlx-agent tools --mcp-config <cfg>` once (init/refresh),
saves the dump, and the selection handlers extract display fragments from it via this
helper - one small query per UI update, no MCP traffic of its own. Replaces the
proxy-era mcp_inspect.py (which fetched tools/list over Streamable HTTP; AIChat V2's
servers are stdio children of mlx-agent and have no endpoint to query).

Usage:
  mcp_tools_report.py servers <dump.json>
      TSV rows for the server table: name<TAB>dot<TAB>index
      (dot: green = handshake ok, red = failed to launch/handshake)
  mcp_tools_report.py command <dump.json> <server_index>
      The server's spawn command line (command + args, one line).
  mcp_tools_report.py summary <dump.json> <server_index>
      One-line status: tool count, or the handshake error.
  mcp_tools_report.py tools <dump.json> <server_index>
      TSV rows for the tools table: display_name<TAB>index
      (display_name gets a lock suffix when the tool is permission-gated)
  mcp_tools_report.py desc <dump.json> <server_index> <tool_index>
      The tool's description block (description, exposed-as, gating note).
  mcp_tools_report.py schema <dump.json> <server_index> <tool_index>
      The tool's JSON input schema, pretty-printed.

Exit codes: 0 ok, 1 bad dump/index (a short message is printed to stdout so the
caller can surface it directly).
"""

import json
import sys

GREEN = "\U0001F7E2"   # green circle
RED = "\U0001F534"     # red circle
LOCK = "\U0001F512"    # lock: permission-gated tool


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f).get("servers", [])


def cell(text):
    """Make a value safe as a TSV table cell: tabs/newlines would shift the hidden
    index column or split the row, mis-targeting the selection handlers."""
    return str(text).replace("\t", " ").replace("\n", " ").replace("\r", " ")


def server_at(servers, idx):
    i = int(idx)
    if i < 0 or i >= len(servers):
        raise IndexError(idx)
    return servers[i]


def tool_at(server, idx):
    tools = server.get("tools", [])
    i = int(idx)
    if i < 0 or i >= len(tools):
        raise IndexError(idx)
    return tools[i]


def main(argv):
    if len(argv) < 3:
        print("usage: mcp_tools_report.py <query> <dump.json> [args]", file=sys.stderr)
        return 2
    query, dump_path = argv[1], argv[2]

    try:
        servers = load(dump_path)
    except (OSError, ValueError) as e:
        print(f"Could not read the tools dump: {e}")
        return 1

    try:
        if query == "servers":
            for i, s in enumerate(servers):
                dot = GREEN if s.get("status") == "ok" else RED
                print(f"{cell(s.get('name', f'server {i}'))}\t{dot}\t{i}")
            return 0

        if query == "command":
            s = server_at(servers, argv[3])
            parts = [s.get("command", "")] + list(s.get("args", []))
            print(" ".join(p for p in parts if p))
            return 0

        if query == "summary":
            s = server_at(servers, argv[3])
            if s.get("status") != "ok":
                print(f"Server failed to start: {s.get('error', 'unknown error')}")
                return 0
            tools = s.get("tools", [])
            gated = sum(1 for t in tools if t.get("gated"))
            note = f" ({gated} permission-gated {LOCK})" if gated else ""
            if tools:
                print(f"{len(tools)} tool(s){note} - select one to see its description and schema.")
            else:
                print("This server exposes no tools.")
            return 0

        if query == "tools":
            s = server_at(servers, argv[3])
            for j, t in enumerate(s.get("tools", [])):
                name = t.get("exposedName") or t.get("name", f"tool {j}")
                if t.get("gated"):
                    name = f"{name} {LOCK}"
                print(f"{cell(name)}\t{j}")
            return 0

        if query == "desc":
            t = tool_at(server_at(servers, argv[3]), argv[4])
            lines = [t.get("description") or "(no description)"]
            exposed = t.get("exposedName")
            real = t.get("name")
            if exposed and real and exposed != real:
                lines.append(f"\nExposed to the model as \"{exposed}\" (server tool name: \"{real}\").")
            if t.get("gated"):
                lines.append(f"\n{LOCK} Gated: the agent asks for permission before running this tool.")
            print("\n".join(lines))
            return 0

        if query == "schema":
            t = tool_at(server_at(servers, argv[3]), argv[4])
            schema = t.get("inputSchema")
            if schema is None:
                print("(no input schema)")
            else:
                print(json.dumps(schema, indent=2, ensure_ascii=False))
            return 0

    except (IndexError, ValueError):
        print("Selection is out of date - refresh the server list.")
        return 1

    print(f"unknown query: {query}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
