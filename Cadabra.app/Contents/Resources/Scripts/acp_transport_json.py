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
    engine == "external":   an ACP agent that is NOT mlx-agent (opencode, the Claude Code
                            ACP adapter, anything the user configured). <agent_bin> is ignored and
                            <target> is the complete command line as the user typed it, split
                            here with shlex - so quoted paths with spaces survive, and the
                            string that is stored is the string that was shown.

HOW THE EXTERNAL PATH DIFFERS, and why it cannot share the mlx-agent one: MCP servers reach
mlx-agent through `--mcp-config <path>`, which is mlx-agent's own flag and means nothing to
any other agent. Every ACP agent instead takes its servers as the `mcpServers` array of
`session/new`, which the Chat element sends from the transport's `mcpServers` key
(ACPChatTransport.swift:225). So the same server list is delivered two different ways
depending on who is being launched, and the external path converts it.

The conversion drops `gatedTools`. That key is an mlx-agent extension - it is how the
bundled agent knows which tools to route back through Cadabra's approval card - and an
external agent neither understands it nor needs it: it runs its own permission model and
raises ACP `session/request_permission`, which the Chat element already renders. Passing it
on would be a foreign key in a spec-defined object for no gain.

Writes one line of JSON to stdout and nothing else, so the caller's stdout stays
pure JSON.
"""
import json
import os
import shlex
import sys

import acp_agent_env


def read_servers(cfg):
    """The generated MCP config's server list, or [] for anything unreadable.

    A missing, empty or broken config must never wedge the window - it degrades to a chat
    with no tools, which is a working chat.
    """
    try:
        if os.path.isfile(cfg):
            with open(cfg) as handle:
                servers = json.load(handle).get("servers", [])
                return servers if isinstance(servers, list) else []
    except Exception:
        pass
    return []


def acp_mcp_servers(servers):
    """Cadabra's server list in the shape ACP's session/new expects.

    Only the spec's stdio fields survive: name, command, args, env. `gatedTools` is
    mlx-agent's own extension and is dropped (see the module docstring).

    `env` IS ALWAYS EMITTED, even empty. It is a mapping in our config and an array of
    {name, value} in ACP, so it has to be converted either way - but it is also REQUIRED, and
    omitting it when a server happens to have no environment is fatal. Measured against
    opencode 1.17.13: an entry of {name, command, args} is rejected with -32602 Invalid
    params, and so is one whose `env` is passed through as a mapping; only the array form is
    accepted. One malformed entry rejects the WHOLE session/new call, so a single env-less
    server takes every tool in the session down with it - and the error names no server, it
    is a schema-union dump that reads like an unrelated problem. Cadabra's own `pdf` server
    has no env today (generate_mcp_configs.py only sets it when non-empty), so this is a live
    case, not a hypothetical one.
    """
    out = []
    for server in servers:
        if not isinstance(server, dict) or not server.get("command"):
            continue
        env = server.get("env")
        entry = {"name": str(server.get("name", "")),
                 "command": str(server["command"]),
                 "args": [str(a) for a in server.get("args", []) or []],
                 "env": [{"name": str(k), "value": str(v)} for k, v in env.items()]
                        if isinstance(env, dict) else []}
        out.append(entry)
    return out


def main():
    agent, engine, target, cfg, cwd = sys.argv[1:6]

    # An agent that is not ours: the command line arrives as one user-typed string and is split
    # HERE rather than by a shell, so a path with spaces survives if it is quoted and nothing is
    # ever glob-expanded or word-split behind the user's back.
    if engine == "external":
        try:
            argv = shlex.split(target)
        except ValueError:
            # Unbalanced quotes. Refusing beats guessing: a "helpful" fallback split would run
            # something the user did not type.
            sys.stderr.write("acp_transport_json: external command has unbalanced quotes\n")
            argv = []
        # A lone empty token (`""` splits to ['']) is not a runnable command either, and it
        # would otherwise sail past the check below and build command: [""].
        argv = [a for a in argv if a != ""]
        if not argv:
            # NOTHING ON STDOUT, so the caller's `[ -n "$chat_config" ]` test fails and it
            # alerts. This used to emit `{"protocol":"local","transport":{"reply":"echo"}}` as
            # a safe-looking degradation, which was the worst available outcome: `local` is
            # ChatView's built-in demo transport and it never fails to construct, so the window
            # opened looking healthy - real title, enabled composer - and echoed the user's own
            # messages back at them, with no error anywhere and nothing to suggest the agent
            # had not started. A refusal the caller can see beats a chat that silently is not
            # one.
            sys.stderr.write("acp_transport_json: external agent has an empty command\n")
            return
        # env.PATH, because the app's own PATH is not enough to launch an agent that is an
        # interpreter script. ChatView merges this over the inherited environment and it is
        # what resolves the shebang's `node` (ACPChatTransport.swift:92). The probe behind the
        # Test button uses the identical value, so the two cannot disagree. See acp_agent_env.
        transport = {"command": argv, "cwd": cwd,
                     "env": {"PATH": acp_agent_env.launch_path()}}
        servers = acp_mcp_servers(read_servers(cfg))
        if servers:
            transport["mcpServers"] = servers
        json.dump({"protocol": "acp", "transport": transport}, sys.stdout)
        sys.stdout.write("\n")
        return

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
    # empty, or broken config leaves servers empty, so the transport falls back to plain
    # chat rather than wedging the window.
    if read_servers(cfg):
        argv += ["--mcp-config", cfg]

    json.dump({"protocol": "acp", "transport": {"command": argv, "cwd": cwd}}, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
