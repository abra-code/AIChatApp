#!/usr/bin/env python3
# generate_mcp_configs.py
# Writes mcp-proxy.json and llama-ui-mcp.json for the current session.
# Called by generate_mcp_configs() in aichat.library.sh.
#
# Usage: python3 generate_mcp_configs.py \
#            <app_bundle> <proxy_port> <out_proxy_json> <out_llama_ui_json> <tz>

import json
import os
import sys

app_bundle     = sys.argv[1]
proxy_port     = int(sys.argv[2])
out_proxy_json = sys.argv[3]
out_llama_ui_json = sys.argv[4]
tz             = sys.argv[5]

packages_dir = f"{app_bundle}/Contents/Library/Packages"
python3_bin  = f"{app_bundle}/Contents/Library/Python/bin/python3"
replay_bin   = f"{app_bundle}/Contents/Support/replay"
home         = os.path.expanduser("~")

# ── replay sandbox paths ──────────────────────────────────────────────────────
# User data dirs; Documents is read-write so the AI can create files there.
allowed_read = [
    f"{home}/Documents",
    f"{home}/Downloads",
    f"{home}/Desktop",
]
allowed_write = [
    f"{home}/Documents",
]

# System tool directories — needed for shell commands (git, grep, brew, node, …)
# to load their binaries and shared libraries inside the replay kernel sandbox.
# Only add dirs that actually exist on this machine.
candidate_tool_dirs = [
    "/bin", "/sbin",
    "/usr/bin", "/usr/sbin",
    "/usr/lib", "/usr/libexec", "/usr/share",
    "/usr/local/bin", "/usr/local/lib",
    "/System/Library/Frameworks",
    "/Library/Developer/CommandLineTools/usr/bin",
    "/private/etc/ssl",   # curl/LibreSSL needs openssl.cnf + cert.pem for HTTPS
    "/private/tmp", "/tmp",
    "/var/folders",
]
for d in candidate_tool_dirs:
    if os.path.isdir(d):
        allowed_read.append(d)

# /tmp / /private/tmp must also be writable for tools that create temp files
for d in ["/tmp", "/private/tmp"]:
    if os.path.isdir(d) and d not in allowed_write:
        allowed_write.append(d)

# App bundle (bundled Python, replay binary, MCP packages, dylibs)
allowed_read.append(app_bundle)

# Homebrew — arm64 standard location
if os.path.isdir("/opt/homebrew"):
    allowed_read.append("/opt/homebrew")

# nvm — if installed
nvm_dir = f"{home}/.nvm"
if os.path.isdir(nvm_dir):
    allowed_read.append(nvm_dir)

# ── replay --mcp-server args ──────────────────────────────────────────────────
replay_args = ["--mcp-server"]
for p in allowed_read:
    replay_args += ["--allow-read", p]
for p in allowed_write:
    replay_args += ["--allow-write", p]

# ── mcp-proxy.json (Python mcp-proxy --named-server-config format) ────────────
proxy_config = {
    "mcpServers": {
        "local": {
            "command": replay_bin,
            "args": replay_args,
            "enabled": True,
        },
        "time": {
            "command": python3_bin,
            "args": ["-m", "mcp_server_time", "--local-timezone", tz],
            "env": {"PYTHONPATH": packages_dir},
            "enabled": True,
        },
#         "fetch": {
#             "command": python3_bin,
#             "args": ["-m", "mcp_server_fetch"],
#             "env": {"PYTHONPATH": packages_dir},
#             "enabled": True,
#         },
        "search": {
            "command": python3_bin,
            "args": ["-m", "duckduckgo_mcp_server.server"],
            "env": {"PYTHONPATH": packages_dir},
            "enabled": True,
        },
    },
}

# ── llama-ui-mcp.json ─────────────────────────────────────────────────────────
# Python mcp-proxy serves CORS headers directly (--allow-origin '*'),
# so useProxy (llama cors-proxy) is not needed.
llama_ui_config = {
    "mcpServers": [
        {
            "url": f"http://127.0.0.1:{proxy_port}/servers/local/mcp",
            "name": "Local (Files & Shell)",
            "enabled": True,
        },
        {
            "url": f"http://127.0.0.1:{proxy_port}/servers/time/mcp",
            "name": "Time",
            "enabled": True,
        },
#         {
#             "url": f"http://127.0.0.1:{proxy_port}/servers/fetch/mcp",
#             "name": "Web Fetch",
#             "enabled": True,
#         },
        {
            "url": f"http://127.0.0.1:{proxy_port}/servers/search/mcp",
            "name": "Web Search (DuckDuckGo)",
            "enabled": True,
        },
    ]
}

for path, config in [(out_proxy_json, proxy_config), (out_llama_ui_json, llama_ui_config)]:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(config, fh, indent=2)
    print(f"  wrote {path}")
