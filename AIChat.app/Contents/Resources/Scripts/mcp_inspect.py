#!/usr/bin/env python3
# mcp_inspect.py
# Connects to a running mcp-proxy server over Streamable HTTP and reports its
# tools. Invoked by the MCP Servers inspector dialog handlers (not an OMC command
# itself) via the bundled python3, exactly like generate_mcp_configs.py.
#
# Two modes:
#
#   list <url> <cache_json>
#       Open an MCP session to <url>, fetch tools/list, write the full tool array
#       (name, description, inputSchema) to <cache_json>, and print one
#       tab-separated "<name>\t<one-line description>" row per tool to stdout for
#       omc_table_set_rows_from_stdin. Exit 0 on success; on failure print a short
#       message to stderr and exit non-zero (the caller surfaces it in the dialog).
#
#   schema <cache_json> <tool_name>
#       Read the cache written by `list` and print the pretty-printed JSON input
#       schema for <tool_name> to stdout (for omc_set_value_from_stdin). Exit 0 on
#       success, non-zero if the tool or cache is missing.
#
# The mcp client library ships in the bundled Packages dir (PYTHONPATH is exported
# by OMC); only the standard library is used beyond it.

import asyncio
import json
import os
import sys

CONNECT_TIMEOUT = 15  # seconds — proxy + child server startup is already done by now


def _one_line(text: str) -> str:
    # Collapse whitespace/newlines/tabs so a description is safe as a single TSV cell.
    return " ".join((text or "").split())


def _leaf_error(exc: BaseException) -> str:
    # The streamable-http client raises connection/protocol failures inside a
    # TaskGroup ExceptionGroup; unwrap to the innermost real error for a message
    # worth showing (e.g. "ConnectError: [Errno 61] Connection refused").
    while isinstance(exc, BaseExceptionGroup) and exc.exceptions:
        exc = exc.exceptions[0]
    return f"{type(exc).__name__}: {exc}"


async def _fetch_tools(url: str):
    # Imported lazily so `schema` mode (no network) works even if the client lib
    # is somehow unavailable.
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    async with streamablehttp_client(url) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.list_tools()
            return result.tools


def _list(url: str, cache_json: str) -> int:
    try:
        tools = asyncio.run(asyncio.wait_for(_fetch_tools(url), timeout=CONNECT_TIMEOUT))
    except asyncio.TimeoutError:
        print(f"Timed out connecting to {url}", file=sys.stderr)
        return 2
    except Exception as exc:  # connection refused, protocol error, etc.
        print(_leaf_error(exc), file=sys.stderr)
        return 1

    cache = []
    for tool in tools:
        cache.append({
            "name": tool.name,
            "description": tool.description or "",
            "inputSchema": tool.inputSchema or {},
        })

    os.makedirs(os.path.dirname(os.path.abspath(cache_json)), exist_ok=True)
    with open(cache_json, "w") as fh:
        json.dump(cache, fh, indent=2)

    for entry in cache:
        sys.stdout.write(f"{entry['name']}\t{_one_line(entry['description'])}\n")
    return 0


def _schema(cache_json: str, tool_name: str) -> int:
    try:
        with open(cache_json) as fh:
            cache = json.load(fh)
    except Exception as exc:
        print(f"Could not read tool cache: {exc}", file=sys.stderr)
        return 1

    for entry in cache:
        if entry.get("name") == tool_name:
            schema = entry.get("inputSchema") or {}
            print(json.dumps(schema, indent=2))
            return 0

    print(f"Tool not found in cache: {tool_name}", file=sys.stderr)
    return 1


def main(argv) -> int:
    if len(argv) >= 4 and argv[1] == "list":
        return _list(argv[2], argv[3])
    if len(argv) >= 4 and argv[1] == "schema":
        return _schema(argv[2], argv[3])
    print("usage: mcp_inspect.py list <url> <cache_json>", file=sys.stderr)
    print("       mcp_inspect.py schema <cache_json> <tool_name>", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
