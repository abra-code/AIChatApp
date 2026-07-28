#!/usr/bin/env python3
# generate_mcp_configs.py
# Writes the session's mlx-agent --mcp-config JSON - {"servers":[{name,command,args,
# env?,gatedTools?}]} - plus the replay sandbox profile it references, both into the
# session dir. mlx-agent speaks MCP stdio directly, spawning each server with its
# command+args (the mcp-proxy HTTP shim of the WebUI era is gone from this app).
# Called by generate_stdio_mcp_config() in aichat.mcp.servers.library.sh.
#
# Usage: python3 generate_mcp_configs.py \
#            <out_json> <app_bundle> <tz> [<mcp_prefs_plist>]
#
# Almost all sandbox paths come from <mcp_prefs_plist>: the allow-network master
# gate, per-server enabled flags, the prominent project workspace, and the
# allowed-read / allowed-write lists shown and edited in the MCP servers dialog. When
# allow-network is false, the time and search servers are omitted and replay gets
# --deny-network. The bundled pdf server (pdfutil) is network-free, so it honors only its
# own enabled flag (plus its own writable flag) and reuses the local sandbox's readable
# dirs as its --root confinement (see the pdf block below). That plist is seeded with Homebrew, nvm, temp, third-party tool/data
# dirs, and the app bundle by mcp_prefs_write_defaults() in aichat.library.sh, so
# nothing is granted to the sandbox invisibly here. (The system executable dirs and
# macOS system libraries are granted by replay's sandbox baseline and are deliberately
# absent, as is the app bundle — replay self-sandboxes at startup and the local server
# has no playlist to re-read, so nothing under the bundle is read once the sandbox is
# live.)
#
# The one sandbox path NOT taken from the plist is the per-login-session temp dir
# ($TMPDIR): it is granted read-write fresh from the environment on every launch (see
# the local block). Its random /var/folders value differs per user login session and
# would go stale if stored, so only the on/off decision lives in the plist
# (servers/local/include-session-tmpdir, default on); the path itself is recomputed.

import json
import os
import plistlib
import sys

out_json        = sys.argv[1]
app_bundle      = sys.argv[2]
tz              = sys.argv[3]
mcp_prefs_plist = sys.argv[4] if len(sys.argv) > 4 else ""

# Everything (the config and the replay sandbox profile) lands in the session dir.
session_dir = os.path.dirname(os.path.abspath(out_json))

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

def srv_flag(name: str, key: str, default: bool = True) -> bool:
    return prefs.get("servers", {}).get(name, {}).get(key, default)

# Master network gate. When false, the network-dependent servers (time, search) are
# not started and the local (replay) server runs with --deny-network.
allow_network = prefs.get("allow-network", True)

# pdfutil's mutating tier, served only when the pdf server is started --writable
# (verified against `pdfutil mcp --help`). Every one of them takes an explicit `output`
# path and writes a new file there; they are gated so the user confirms each write.
PDF_MUTATING_TOOLS = ["pdf_merge", "pdf_extract_pages", "pdf_delete_pages", "pdf_rotate",
                      "pdf_metadata_set", "pdf_forms_fill", "pdf_watermark", "pdf_reduce"]

# ── Build the per-server config table, honoring enabled flags ─────────────────
servers = {}           # short name -> {command, args, env?, gatedTools?}
server_order = []      # short names in launch order
user_project = ""      # set in the local block; pre-init so it's always defined

if srv_enabled("local"):
    local_prefs = prefs.get("servers", {}).get("local", {})
    # ── replay sandbox paths ──────────────────────────────────────────────────
    # Every extra sandbox path is taken from the user-managed prefs (shown and
    # editable in the MCP servers dialog), except the per-login-session $TMPDIR
    # added read-write below, which is computed fresh each launch rather than
    # persisted. The prefs plist is seeded with Homebrew, nvm, temp, and
    # third-party tool/data dirs by mcp_prefs_write_defaults() in
    # aichat.library.sh — nothing else is added to the sandbox here. (replay's
    # sandbox baseline separately grants exec
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
    # Per-login-session temp dir ($TMPDIR, e.g. /var/folders/xx/.../T): granted
    # read-write so sandboxed shell tools can use the login session's own scratch
    # dir. The path itself is recomputed from the environment on every launch and
    # deliberately NOT read from / written to the prefs plist — its random
    # /var/folders value differs per user login session, so a persisted copy would go
    # stale. Only the user's decision is stored, in include-session-tmpdir (default
    # on, absent == on); the dialog shows the temp dir as a removable row that toggles
    # that flag. realpath() resolves the /var -> /private/var symlink to the canonical
    # path the kernel sandbox and the MCP soft path checks compare against (the same
    # reason the seeded write path is /private/tmp, not /tmp).
    include_session_tmpdir = local_prefs.get("include-session-tmpdir", True)
    session_tmpdir = os.environ.get("TMPDIR", "").strip()
    if include_session_tmpdir and session_tmpdir:
        session_tmpdir = os.path.realpath(session_tmpdir)
        if (os.path.isdir(session_tmpdir)
                and session_tmpdir != user_project
                and session_tmpdir not in profile_read_write):
            profile_read_write.append(session_tmpdir)
    # read-only dirs all live in the profile (drop any also granted read-write):
    profile_read_only = [directory for directory in allowed_read if directory not in profile_read_write]

    replay_args = ["--mcp-server"]
    if not allow_network:
        replay_args.append("--deny-network")
    if user_project:
        replay_args += ["--allow-write", user_project]

    # Write the sandbox profile next to the config and point replay at it.
    # allow_network is intentionally omitted from the JSON: in MCP mode the CLI
    # --deny-network gate is authoritative (replay overrides the profile's network
    # setting), and import_baseline / allow_exec / allow_fork keep their permissive
    # defaults so the Local server can still spawn shells and load system libraries.
    # replay reads this file at startup, before it self-sandboxes, so it does not
    # need to be inside any granted directory.
    if profile_read_only or profile_read_write:
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

    servers["local"] = {
        "command": replay_bin,
        "args": replay_args,
    }
    server_order.append("local")

if srv_enabled("pdf"):
    # pdfutil (github.com/abra-code/pdfutil, Apache 2.0): a network-free PDF server
    # exposing pdf_info / pdf_text / pdf_search / pdf_outline / pdf_render / pdf_ocr /
    # pdf_forms_list / pdf_list over MCP stdio, plus the mutating tier below when
    # writable. It confines every tool to its --root directories and requires at least
    # one, so it is granted the SAME directory set the local (replay) sandbox may touch:
    # the project workspace, the user's extra read/write paths, and the login-session
    # $TMPDIR. Those are read from the local prefs directly so PDF access does not depend
    # on the "local" server being enabled. pdfutil has no network, so it is NOT gated by
    # allow-network.
    pdfutil_bin = f"{app_bundle}/Contents/Support/pdfutil"
    pdf_local_prefs = prefs.get("servers", {}).get("local", {})
    # servers/pdf/writable adds --writable, which serves the eight mutating tools listed
    # in PDF_MUTATING_TOOLS. Default on, matching the other bundled servers (and strictly
    # milder than what the Local server already grants by default: pdfutil's outputs are
    # CREATE-ONLY - a new file under a --root, refused if anything already exists there,
    # with no overwrite parameter - so a mutating call can add a PDF but can never modify
    # or destroy an existing file, in either the read-write or the read-only path list).
    # The tools are still listed as gatedTools so each write costs a permission prompt.
    pdf_writable = srv_flag("pdf", "writable", True)
    pdf_roots = []

    def _add_pdf_root(directory):
        directory = (directory or "").strip()
        if not directory:
            return
        # pdfutil canonicalizes its roots (resolvingSymlinksInPath); realpath here so
        # the /var -> /private/var (and /tmp -> /private/tmp) symlinks match, and so
        # duplicates collapse. pdfutil rejects a --root that is not an existing dir, so
        # skip anything that no longer exists rather than start a server that exits 1.
        directory = os.path.realpath(directory)
        if os.path.isdir(directory) and directory not in pdf_roots:
            pdf_roots.append(directory)

    _add_pdf_root(pdf_local_prefs.get("project"))
    for directory in (pdf_local_prefs.get("allowed-write") or []):
        _add_pdf_root(directory)
    for directory in (pdf_local_prefs.get("allowed-read") or []):
        _add_pdf_root(directory)
    if pdf_local_prefs.get("include-session-tmpdir", True):
        _add_pdf_root(os.environ.get("TMPDIR", ""))

    # pdfutil requires >=1 existing --root and refuses to start otherwise. If the user
    # has cleared every sandbox path (empty project, no read/write paths, session tmpdir
    # off) there is nothing for it to read, so the server is simply omitted rather than
    # started against a fallback like $HOME - that would grant the PDF tools read access
    # to the whole home dir in exactly the configuration where the user asked for none,
    # and would also give pdf a broader set than replay. With no roots the toggle has
    # nothing to act on; enabling it takes effect again as soon as a sandbox path exists.
    if pdf_roots:
        pdf_args = ["mcp"]
        for root in pdf_roots:
            pdf_args += ["--root", root]
        if pdf_writable:
            pdf_args.append("--writable")
        servers["pdf"] = {
            "command": pdfutil_bin,
            "args": pdf_args,
        }
        if pdf_writable:
            servers["pdf"]["gatedTools"] = PDF_MUTATING_TOOLS
        server_order.append("pdf")
    else:
        print("  pdf server enabled but no readable sandbox paths configured; omitting it")

if allow_network and srv_enabled("time"):
    servers["time"] = {
        "command": python3_bin,
        "args": ["-m", "mcp_server_time", "--local-timezone", tz],
        "env": {"PYTHONPATH": packages_dir},
    }
    server_order.append("time")

if allow_network and srv_enabled("search"):
    servers["search"] = {
        "command": python3_bin,
        "args": ["-m", "duckduckgo_mcp_server.server"],
        "env": {"PYTHONPATH": packages_dir},
    }
    server_order.append("search")

# ── Emit the mlx-agent --mcp-config JSON ──────────────────────────────────────
# {"servers":[{name,command,args,env?,gatedTools?}]} from the servers constructed
# above. gatedTools lists the tools that require a session/request_permission
# round-trip before dispatch - replay's mutating + shell operations (verified against
# replay's tools/list). Read-only tools (read_file, list_directory, grep_files, ...)
# are not gated. time/search expose no mutating tools. The pdf server sets its own
# gatedTools in its block above (only when --writable), so it is absent here.
gated_by_server = {
    "local": ["write_file", "edit_file", "edit_files", "execute_command",
              "create_directory", "move_file", "delete_file"],
}
stdio_servers = []
for name in server_order:
    spec = servers[name]
    entry = {"name": name, "command": spec["command"], "args": list(spec.get("args") or [])}
    if spec.get("env"):
        entry["env"] = spec["env"]
    gated = spec.get("gatedTools") or gated_by_server.get(name)
    if gated:
        entry["gatedTools"] = list(gated)
    stdio_servers.append(entry)
out_abs = os.path.abspath(out_json)
os.makedirs(os.path.dirname(out_abs), exist_ok=True)
# Remove any prior config first so a failure below degrades to "no config found" (the
# transport builder then falls back to chat mode) instead of silently reusing a stale one.
if os.path.exists(out_abs):
    os.remove(out_abs)
with open(out_abs, "w") as fh:
    json.dump({"servers": stdio_servers}, fh, indent=2)
print(f"  wrote mcp config {out_json} ({len(stdio_servers)} server(s))")
if user_project:
    print(f"  project workspace: {user_project}")
