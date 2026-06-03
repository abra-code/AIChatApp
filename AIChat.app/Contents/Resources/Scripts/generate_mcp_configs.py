#!/usr/bin/env python3
# generate_mcp_configs.py
# Writes mcp-proxy.json and llama-ui-mcp.json for the current session.
# Called by generate_mcp_configs() in aichat.library.sh.
#
# Usage: python3 generate_mcp_configs.py \
#            <app_bundle> <proxy_port> <out_proxy_json> <out_llama_ui_json> <tz> [<mcp_prefs_plist>]
#
# All sandbox paths come from <mcp_prefs_plist>: the allow-network master gate,
# per-server enabled flags, the prominent project workspace, and the allowed-read /
# allowed-write lists shown and edited in the MCP servers dialog. When allow-network
# is false, the time and search servers are omitted and replay gets --deny-network. That plist is seeded with Homebrew, nvm,
# temp, third-party tool/data dirs, and the app bundle by mcp_prefs_write_defaults()
# in aichat.library.sh, so nothing is granted to the sandbox invisibly here. (The
# system executable dirs and macOS system libraries are granted by replay's sandbox
# baseline and are deliberately absent, as is the app bundle — replay self-sandboxes
# at startup and the local server has no playlist to re-read, so nothing under the
# bundle is read once the sandbox is live.)

import json
import os
import plistlib
import sys

app_bundle        = sys.argv[1]
proxy_port        = int(sys.argv[2])
out_proxy_json    = sys.argv[3]
out_llama_ui_json = sys.argv[4]
tz                = sys.argv[5]
mcp_prefs_plist   = sys.argv[6] if len(sys.argv) > 6 else ""

packages_dir = f"{app_bundle}/Contents/Library/Packages"
python3_bin  = f"{app_bundle}/Contents/Library/Python/bin/python3"
replay_bin   = f"{app_bundle}/Contents/Support/replay"

# ── Load user preferences (if any) ────────────────────────────────────────────
prefs = {}
if mcp_prefs_plist and os.path.isfile(mcp_prefs_plist):
    try:
        with open(mcp_prefs_plist, "rb") as fh:
            prefs = plistlib.load(fh)
    except Exception as e:
        print(f"  warning: could not read MCP prefs ({e}); using defaults")

def srv_enabled(name: str) -> bool:
    return prefs.get("servers", {}).get(name, {}).get("enabled", True)

# Master network gate. When false, the network-dependent servers (time, search) are
# not started and the local (replay) server runs with --deny-network.
allow_network = prefs.get("allow-network", True)

# ── Build the per-server config tables, honoring enabled flags ────────────────
proxy_servers = {}
llama_servers = []
server_order = []      # short names in launch order; parallels llama_servers
user_project = ""      # set in the local block; pre-init so it's always defined

if srv_enabled("local"):
    local_prefs = prefs.get("servers", {}).get("local", {})
    # ── replay sandbox paths ──────────────────────────────────────────────────
    # Every extra sandbox path is taken from the user-managed prefs (shown and
    # editable in the MCP servers dialog). The prefs plist is seeded with
    # Homebrew, nvm, temp, and third-party tool/data dirs by
    # mcp_prefs_write_defaults() in aichat.library.sh — nothing is added to the
    # sandbox invisibly here. (replay's sandbox baseline separately grants exec
    # of /bin, /usr/bin, /sbin, /usr/sbin and loading of system libraries under
    # /usr/lib and /System/Library; the app bundle is not needed because replay
    # self-sandboxes at startup and the local server has no playlist to re-read.)
    allowed_read = [directory for directory in (local_prefs.get("allowed-read") or []) if directory]

    # Project workspace: the prominent read-write directory chosen by the user.
    # It is passed as the single explicit --allow-write so replay treats it as the
    # project (working) directory: the first entry of list_allowed_directories and
    # the base that grep_files resolves relative globs against when a call omits
    # `directory`.
    user_project = (local_prefs.get("project") or "").strip()

    # Every other directory travels in a generated --sandbox-profile JSON instead
    # of a long --allow-read/--allow-write command line. As of replay 2.1 a
    # profile's read_only/read_write dirs are also folded into the MCP allowed-dir
    # list (list_allowed_directories and the write_file/read_file path checks), so
    # the soft MCP path layer stays in sync with the kernel sandbox either way.
    # additional read-write dirs (everything the user added beyond the project):
    profile_read_write = []
    for directory in (local_prefs.get("allowed-write") or []):
        if directory and directory != user_project and directory not in profile_read_write:
            profile_read_write.append(directory)
    # read-only dirs all live in the profile (drop any also granted read-write):
    profile_read_only = [directory for directory in allowed_read if directory not in profile_read_write]

    replay_args = ["--mcp-server"]
    if not allow_network:
        replay_args.append("--deny-network")
    if user_project:
        replay_args += ["--allow-write", user_project]

    # Write the sandbox profile next to the proxy configs and point replay at it.
    # allow_network is intentionally omitted from the JSON: in MCP mode the CLI
    # --deny-network gate is authoritative (replay overrides the profile's network
    # setting), and import_baseline / allow_exec / allow_fork keep their permissive
    # defaults so the Local server can still spawn shells and load system libraries.
    # replay reads this file at startup, before it self-sandboxes, so it does not
    # need to be inside any granted directory.
    if profile_read_only or profile_read_write:
        session_dir = os.path.dirname(os.path.abspath(out_proxy_json))
        os.makedirs(session_dir, exist_ok=True)
        sandbox_profile_path = os.path.join(session_dir, "mcp-replay-sandbox.json")
        sandbox_profile = {}
        if profile_read_only:
            sandbox_profile["read_only"] = profile_read_only
        if profile_read_write:
            sandbox_profile["read_write"] = profile_read_write
        with open(sandbox_profile_path, "w") as profile_file:
            json.dump(sandbox_profile, profile_file, indent=2)
        replay_args += ["--sandbox-profile", sandbox_profile_path]

    proxy_servers["local"] = {
        "command": replay_bin,
        "args": replay_args,
        "enabled": True,
    }
    llama_servers.append({
        # Stable id so the WebUI's per-server enable/disable state (keyed by id in
        # LlamaUi.mcpDefaultEnabled) survives across launches. Without an explicit
        # id the WebUI falls back to a positional id (LlamaUI-MCP-Server-N) that
        # shifts whenever a server is omitted (e.g. network off drops time+search),
        # mis-binding the saved enable flags. Keep these in sync with mcp-seed.js.
        "id": "aichat-local",
        "url": f"http://127.0.0.1:{proxy_port}/servers/local/mcp",
        "name": "Local (Files & Shell)",
        "enabled": True,
    })
    server_order.append("local")

if allow_network and srv_enabled("time"):
    proxy_servers["time"] = {
        "command": python3_bin,
        "args": ["-m", "mcp_server_time", "--local-timezone", tz],
        "env": {"PYTHONPATH": packages_dir},
        "enabled": True,
    }
    llama_servers.append({
        "id": "aichat-time",
        "url": f"http://127.0.0.1:{proxy_port}/servers/time/mcp",
        "name": "Time",
        "enabled": True,
    })
    server_order.append("time")

if allow_network and srv_enabled("search"):
    proxy_servers["search"] = {
        "command": python3_bin,
        "args": ["-m", "duckduckgo_mcp_server.server"],
        "env": {"PYTHONPATH": packages_dir},
        "enabled": True,
    }
    llama_servers.append({
        "id": "aichat-search",
        "url": f"http://127.0.0.1:{proxy_port}/servers/search/mcp",
        "name": "Web Search (DuckDuckGo)",
        "enabled": True,
    })
    server_order.append("search")

proxy_config    = {"mcpServers": proxy_servers}
llama_ui_config = {"mcpServers": llama_servers}

# ── Per-server ports ──────────────────────────────────────────────────────────
# The WebUI holds one long-lived SSE GET stream per server. With every server
# behind a single host:port they shared WKWebView's ~6-connections-per-host limit,
# and once enough streams were open the tools/list POSTs were starved (60s timeout
# → "connected, 0 tools" → the model got no tools). Giving each server its own
# 127.0.0.1 port gives each its own connection budget. We launch one mcp-proxy
# instance per server (it has no native multi-port mode) — see launch_mcp_proxy()
# in aichat.library.sh and Private/mcp-tools-debugging-postmortem.md (Incident 3).
import socket

def _free_port(start, span=80):
    for p in range(start, start + span):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", p))
                return p
            except OSError:
                continue
    return start  # nothing free in range; let the proxy surface the bind error

out_dir = os.path.dirname(out_proxy_json)
os.makedirs(out_dir, exist_ok=True)
manifest_lines = []
next_port = proxy_port
for name, llama_entry in zip(server_order, llama_servers):
    port = _free_port(next_port)
    next_port = port + 1
    # Rewrite the WebUI URL to this server's own port (overrides the base-port
    # placeholder set above).
    llama_entry["url"] = f"http://127.0.0.1:{port}/servers/{name}/mcp"
    # One single-server proxy config per instance.
    per_path = os.path.join(out_dir, f"mcp-proxy-{name}.json")
    with open(per_path, "w") as fh:
        json.dump({"mcpServers": {name: proxy_servers[name]}}, fh, indent=2)
    manifest_lines.append(f"{name} {port}")

# Manifest read by launch_mcp_proxy(): one "<name> <port>" line per instance to
# start (the per-instance config path is derived by convention from <name>).
manifest_path = os.path.join(out_dir, "mcp-proxy-instances.txt")
with open(manifest_path, "w") as fh:
    fh.write("".join(line + "\n" for line in manifest_lines))

# out_proxy_json (combined) is kept for reference/debug; out_llama_ui_json now
# carries the per-server-port URLs and is the WebUI's --ui-config-file.
for path, config in [(out_proxy_json, proxy_config), (out_llama_ui_json, llama_ui_config)]:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(config, fh, indent=2)
    print(f"  wrote {path}")

for line in manifest_lines:
    print(f"  instance {line}")
if user_project:
    print(f"  project workspace: {user_project}")
