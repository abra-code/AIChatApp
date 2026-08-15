#!/usr/bin/env python3
"""Emit the Chat element's ACP transport JSON for one chat window.

Called by aichat_acp_transport_json in aichat.mcp.servers.library.sh. Building the
argv and the JSON here (via json.dumps) keeps paths with spaces or quotes safe.
Agent mode is selected only when the generated MCP config lists >= 1 server;
otherwise the transport is plain chat (no --mcp-config).

Usage:
    acp_transport_json.py <agent_bin> <engine> <target> <mcp_config_path> <cwd>

    engine == "openai":     <target> is the llama-server base-url; mlx-agent talks to it.
    engine == "mlx":        <target> is a safetensors model directory loaded in-process.
    engine == "foundation": Apple's on-device model. <target> is UNUSED and expected to be
                            empty - the model belongs to the OS, and passing --model would be
                            refused by the agent because there is nothing to choose between.

Writes one line of JSON to stdout and nothing else, so the caller's stdout stays
pure JSON.
"""
import json
import os
import sys


def main():
    agent, engine, target, cfg, cwd = sys.argv[1:6]

    # Dispatched explicitly rather than "openai or else --model": the on-device engine has no
    # target, so falling through to the else would build `--model ""` and start an agent that
    # fails on an empty model path instead of using the model the user picked.
    if engine == "openai":
        argv = [agent, "acp", "--backend", "openai", "--base-url", target]
    elif engine == "foundation":
        argv = [agent, "acp", "--backend", "foundation"]
    else:
        argv = [agent, "acp", "--model", target]

    # Agent mode only when the config parsed and lists at least one server. A missing,
    # empty, or broken config leaves servers == 0, so the transport falls back to plain
    # chat rather than wedging the window.
    servers = 0
    try:
        if os.path.isfile(cfg):
            with open(cfg) as handle:
                servers = len(json.load(handle).get("servers", []))
    except Exception:
        servers = 0
    if servers > 0:
        argv += ["--mcp-config", cfg]

    json.dump({"protocol": "acp", "transport": {"command": argv, "cwd": cwd}}, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
