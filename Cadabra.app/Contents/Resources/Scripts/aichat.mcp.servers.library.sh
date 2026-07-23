#!/bin/sh
# aichat.mcp.servers.library.sh
# MCP server preferences (the com.abracode.Cadabra-mcp plist): read/written by the
# aichat.mcp.servers.* dialog handlers and read by the launch flow
# (generate_stdio_mcp_config / aichat_acp_transport_json below). Sourced by those
# handlers, by the MCP inspector, and — transitively — by aichat.server.library.sh.
# Sources the base library for $plister/$dialog.
[ -n "${__AICHAT_MCP_SERVERS_LIB:-}" ] && return 0
__AICHAT_MCP_SERVERS_LIB=1
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

# ──────────────────────────────────────────────────────────────
# MCP servers preferences
# ──────────────────────────────────────────────────────────────
# User-editable settings for the bundled MCP servers, written by the
# aichat.mcp.servers dialog and read by aichat.init.sh / generate_mcp_configs.py.
#
# Schema:
#   /allow-network                : bool  (session-wide network master gate)
#   /servers/time/enabled         : bool
#   /servers/search/enabled       : bool
#   /servers/pdf/enabled          : bool  (pdfutil - read-only PDF tools, no network)
#   /servers/local/enabled        : bool
#   /servers/local/project        : string  (primary read-write workspace)
#   /servers/local/allowed-write  : array<string>  (additional RW paths)
#   /servers/local/allowed-read   : array<string>  (additional RO paths)
#   /servers/local/include-session-tmpdir : bool  (grant the login session $TMPDIR RW)
#
# allow-network is a master switch surfaced as the "Allow Network" checkbox. When
# false, the Time and Web Search & Fetch servers are not started and the local
# (replay) server is launched with --deny-network, cutting off all outbound/inbound
# network for the sandboxed shell. When true, each server follows its own toggle.
#
# allowed-write and allowed-read are seeded by mcp_prefs_write_defaults() with the
# temp dir, Homebrew, nvm, and third-party tool/data dirs, and are fully editable in
# the dialog — so the tables show every extra path the sandbox can touch and nothing
# is granted invisibly. The system executable dirs (/bin, /usr/bin, /sbin, /usr/sbin)
# and macOS system libraries (/usr/lib, /System/Library) are NOT listed: the replay
# sandbox baseline grants exec + system-dylib loading for those automatically. The
# app bundle is NOT listed either: replay self-sandboxes at startup and the local
# server has no playlist to re-read, so nothing under it is read once the sandbox is
# live. No private user dirs (Documents/Desktop/Downloads) are added by default.

mcp_prefs="/Users/$USER/Library/Preferences/com.abracode.Cadabra-mcp.plist"

# mcp_prefs_write_defaults
# Overwrites the MCP prefs plist with built-in defaults.
mcp_prefs_write_defaults() {
    /bin/rm -f "$mcp_prefs"
    "$plister" set dict   "$mcp_prefs" /
    "$plister" insert "allow-network" bool true "$mcp_prefs" /
    "$plister" insert "servers" dict "$mcp_prefs" /
    "$plister" insert "time"   dict "$mcp_prefs" /servers
    "$plister" insert "enabled" bool true "$mcp_prefs" /servers/time
    "$plister" insert "search" dict "$mcp_prefs" /servers
    "$plister" insert "enabled" bool true "$mcp_prefs" /servers/search
    "$plister" insert "pdf"    dict "$mcp_prefs" /servers
    "$plister" insert "enabled" bool true "$mcp_prefs" /servers/pdf
    "$plister" insert "local"  dict "$mcp_prefs" /servers
    "$plister" insert "enabled" bool true "$mcp_prefs" /servers/local
    "$plister" insert "project" string "" "$mcp_prefs" /servers/local

    # Additional read-write paths (editable). Temp dir only — tools that create
    # scratch files need somewhere to write. /tmp is a symlink to /private/tmp and
    # the sandbox canonicalizes via realpath, so we seed the real path only. No
    # private user dirs by default. The per-login-session $TMPDIR (a random
    # /var/folders path) is intentionally NOT seeded into this array: it changes per
    # user login session, so generate_mcp_configs.py grants it read-write fresh from
    # the environment on each launch instead of persisting a value that would go
    # stale. Only the user's decision to include it is stored, in
    # include-session-tmpdir below; the dialog shows it as a removable row
    # (mcp_refresh_rw_table) so the temp grant can be revoked without saving its path.
    "$plister" insert "allowed-write" array "$mcp_prefs" /servers/local
    for d in /private/tmp; do
        [ -d "$d" ] && "$plister" append string "$d" "$mcp_prefs" /servers/local/allowed-write
    done

    # Grant the login session $TMPDIR read-write by default. This stores only the
    # on/off decision, never the (per-session) path; generate_mcp_configs.py and the
    # dialog recompute the path from the environment. Removing the temp row in the
    # dialog clears this flag.
    "$plister" insert "include-session-tmpdir" bool true "$mcp_prefs" /servers/local

    # Additional read-only paths (editable). These are paths the replay sandbox does
    # NOT grant on its own: Homebrew, nvm, third-party tool dirs, data dirs, and temp
    # — so shell tools (git, node, …) can load their non-system dylibs and data, and
    # so the dialog shows exactly what the sandbox can read. The system executable
    # dirs (/bin, /usr/bin, /sbin, /usr/sbin) and the macOS system libraries
    # (/usr/lib, /System/Library) are granted automatically by the sandbox baseline
    # and are intentionally NOT listed here. The app bundle is NOT listed either:
    # replay self-sandboxes at startup (its binary and dylibs are already mapped) and
    # the local server has no playlist to re-read, so nothing under Cadabra.app is
    # read once the sandbox is live. (Only if a sandboxed child had to run the
    # *bundled* python3 would Contents/Library be needed — not a current case, and
    # system /usr/bin/python3 is already reachable.) Only paths that exist on this
    # machine are added.
    "$plister" insert "allowed-read"  array "$mcp_prefs" /servers/local
    for d in \
        /usr/libexec /usr/share \
        /usr/local/bin /usr/local/lib \
        /Library/Developer/CommandLineTools/usr/bin \
        /private/etc/ssl /private/tmp /var/folders \
        /opt/homebrew "$HOME/.nvm"; do
        [ -d "$d" ] && "$plister" append string "$d" "$mcp_prefs" /servers/local/allowed-read
    done
}

# mcp_prefs_init_if_missing
mcp_prefs_init_if_missing() {
    [ -f "$mcp_prefs" ] && return 0
    mcp_prefs_write_defaults
}

# mcp_prefs_get_bool <key-path>  ->  "true" | "false"
# Falls back to "true" if key missing (defaults assume bundled servers are on).
mcp_prefs_get_bool() {
    local val=$("$plister" get value "$mcp_prefs" "/$1" 2>/dev/null)
    case "$val" in true|false) echo "$val" ;; *) echo "true" ;; esac
}

# mcp_prefs_get_string <key-path>
mcp_prefs_get_string() {
    "$plister" get string "$mcp_prefs" "/$1" 2>/dev/null
}

# mcp_prefs_set_bool <key-path> <true|false>
mcp_prefs_set_bool() {
    "$plister" set bool "$2" "$mcp_prefs" "/$1" 2>/dev/null
}

# mcp_prefs_set_string <key-path> <value>
mcp_prefs_set_string() {
    "$plister" set string "$2" "$mcp_prefs" "/$1" 2>/dev/null
}

# mcp_prefs_array_count <key-path>
mcp_prefs_array_count() {
    "$plister" get count "$mcp_prefs" "/$1" 2>/dev/null
}

# mcp_prefs_array_list <key-path>  ->  values, one per line
mcp_prefs_array_list() {
    "$plister" iterate "$mcp_prefs" "/$1" get string / 2>/dev/null
}

# mcp_prefs_array_append <key-path> <value>
# Refuses duplicates. Returns 0 if appended, 1 if already present.
mcp_prefs_array_append() {
    local found=$("$plister" find string "$2" "$mcp_prefs" "/$1" 2>/dev/null)
    [ -n "$found" ] && return 1
    "$plister" append string "$2" "$mcp_prefs" "/$1"
}

# mcp_prefs_array_remove_value <key-path> <value>
mcp_prefs_array_remove_value() {
    local idx=$("$plister" find string "$2" "$mcp_prefs" "/$1" 2>/dev/null)
    [ -z "$idx" ] && return 1
    "$plister" delete "$mcp_prefs" "/$1/$idx"
}

# mcp_refresh_path_table <window_uuid> <table_id> <prefs_key>
# Repopulates a single-column path table from the prefs array.
mcp_refresh_path_table() {
    local window_uuid="$1"
    local table_id="$2"
    local key="$3"
    "$dialog" "$window_uuid" "$table_id" omc_table_remove_all_rows
    local buffer=$(mcp_prefs_array_list "$key")
    if [ -n "$buffer" ]; then
        printf "%s\n" "$buffer" | "$dialog" "$window_uuid" "$table_id" omc_table_set_rows_from_stdin
    fi
}

# mcp_session_tmpdir  ->  canonical realpath of $TMPDIR, or empty
# The per-login-session scratch dir offered as a removable read-write grant. Its
# value (a random /var/folders path) changes per login session, so it is NEVER stored
# in the prefs plist — only the include-session-tmpdir decision is. `cd && pwd -P`
# resolves the /var -> /private/var symlink to the same path os.path.realpath($TMPDIR)
# yields in generate_mcp_configs.py, so the row shown matches what is granted.
mcp_session_tmpdir() {
    [ -n "${TMPDIR:-}" ] || return 0
    ( cd "$TMPDIR" 2>/dev/null && pwd -P )
}

# mcp_refresh_rw_table <window_uuid> <table_id>
# Repopulates the read-write table from the persisted allowed-write array, then
# appends the session $TMPDIR as a synthetic (non-persisted) row when
# include-session-tmpdir is on. The row is shown so the user can see the temp grant
# and, by removing it, deny it — only that decision is stored, never the volatile path.
mcp_refresh_rw_table() {
    local window_uuid="$1"
    local table_id="$2"
    mcp_refresh_path_table "$window_uuid" "$table_id" servers/local/allowed-write
    if [ "$(mcp_prefs_get_bool servers/local/include-session-tmpdir)" = "true" ]; then
        local td=$(mcp_session_tmpdir)
        [ -n "$td" ] && printf "%s\n" "$td" \
            | "$dialog" "$window_uuid" "$table_id" omc_table_add_rows_from_stdin
    fi
}

# ──────────────────────────────────────────────────────────────
# ACP transport (stdio-direct MCP for the bundled mlx-agent)
# ──────────────────────────────────────────────────────────────
# generate_stdio_mcp_config writes the mlx-agent --mcp-config file for one window;
# aichat_acp_transport_json turns it into the Chat element's states["config"] transport,
# selecting agent mode iff at least one server ends up enabled.

# aichat_session_config_dir <window_uuid>
# Per-window dir holding this window's generated mcp-config.json and the replay sandbox
# profile. Overwritten on every launch / model switch, so nothing here is durable state.
aichat_session_config_dir() {
    printf '%s/Sessions/%s' "$mcp_app_support" "$1"
}

# generate_stdio_mcp_config <out_config_json>
# Emit the mlx-agent --mcp-config (stdio-direct) file into <out_config_json>, honoring the
# current MCP-servers prefs (per-server enabled flags, the allow-network master gate, and
# the replay sandbox read/write paths). The replay sandbox profile is written next to
# <out_config_json>. Returns 0 when the file is written (possibly {"servers":[]} if the
# user disabled everything), non-zero if the bundled Python or the generator is missing.
generate_stdio_mcp_config() {
    local out_json="$1"
    local python3="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
    local script="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/generate_mcp_configs.py"
    if [ ! -f "$python3" ] || [ ! -f "$script" ]; then
        echo "generate_stdio_mcp_config: bundled Python/generator missing ($python3 / $script)"
        return 1
    fi

    # Seed the prefs plist with defaults on first run so the config the model sees matches
    # exactly what the MCP Servers dialog shows. No-op when prefs already exist.
    mcp_prefs_init_if_missing

    local tz="$(/usr/bin/readlink /etc/localtime 2>/dev/null | /usr/bin/sed 's|.*/zoneinfo/||')"
    [ -z "$tz" ] && tz="UTC"

    local out_dir="$(/usr/bin/dirname "$out_json")"
    /bin/mkdir -p "$out_dir" 2>/dev/null

    # The generator writes the mlx-agent config to <out_json> and the replay sandbox
    # profile beside it in the same session dir.
    "$python3" "$script" "$out_json" "$OMC_APP_BUNDLE_PATH" "$tz" "$mcp_prefs"
}

# aichat_acp_transport_json <agent_bin> <engine> <target> <window_uuid> [use_tools]
# Generate this window's MCP config, then echo the ACP transport JSON for the Chat
# element's states["config"].
#
# <engine> selects how mlx-agent generates, and what <target> means:
#   openai - <target> is the llama-server base-url (e.g. http://127.0.0.1:8099/v1). The
#            APPLET owns that server (launch, restart on model switch, reaping); mlx-agent
#            only talks to it. This is V2's path today.
#   mlx    - <target> is a safetensors model directory loaded in-process by mlx-agent.
#            Unused until M2, but built now so M2 is a config change, not a port.
#
# When the config has at least one server, the transport adds --mcp-config <cfg> (which
# defaults mlx-agent to agent mode); otherwise it is a plain chat transport with no tools.
# use_tools is the per-session decision (the selector's agentic-session checkbox, or the
# caller's auto-detection): anything but "true" skips config generation entirely - and
# removes any config left by a previous launch of the same window - so the session is plain
# chat regardless of which servers the prefs enable. Omitted means "true" (prefs decide).
# Argv/JSON encoding is done in Python (json.dumps) so paths with spaces or quotes are safe;
# if the bundled Python is somehow absent it falls back to a sed-escaped hand-built chat
# transport rather than wedging the window. Echoes only the JSON on stdout; any generator
# diagnostics go to stderr.
aichat_acp_transport_json() {
    local agent_bin="$1"
    local engine="$2"
    local target="$3"
    local window_uuid="$4"
    local use_tools="${5:-true}"

    local python3="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
    local cfg="$(aichat_session_config_dir "$window_uuid")/mcp-config.json"

    # The agent's working directory: the user's chosen Project workspace. ChatView launches
    # mlx-agent with this as the process cwd AND sends it as session/new's `cwd`, so relative
    # paths resolve here and mlx-agent tells the model where it is (a model cannot call getcwd).
    # ACP requires cwd to be an ABSOLUTE path. The Project field is an editable TextField (the
    # folder picker only pre-fills it), so the stored value can be anything the user typed -
    # validate it here rather than trusting it. A relative value would otherwise be anchored by
    # ChatView against the host's cwd ("/" for a launchd-launched GUI app), yielding e.g.
    # "/Documents" and possibly a failed process launch - worse than the old "rooted at /". Fall
    # back to $HOME for anything not absolute-and-existing, so the agent is never rooted at "/".
    local cwd="$(mcp_prefs_get_string servers/local/project)"
    case "$cwd" in
        /*) [ -d "$cwd" ] || cwd="$HOME" ;;
        *)  cwd="$HOME" ;;
    esac

    if [ "$use_tools" = "true" ]; then
        # Generate the config; its diagnostics go to stderr so stdout stays pure JSON.
        generate_stdio_mcp_config "$cfg" 1>&2
    else
        # Tools off for this session: no config, and drop a stale one from a previous
        # launch of this window so the argv builder below sees no servers.
        /bin/rm -f "$cfg"
    fi

    # Build the transport argv + JSON in a helper (json.dumps keeps paths with spaces/quotes
    # safe): agent mode only when the config parsed and lists >=1 server (a missing/empty/broken
    # config falls back to chat — never wedges the window).
    local builder="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/acp_transport_json.py"
    if [ -x "$python3" ] && [ -f "$builder" ]; then
        "$python3" "$builder" "$agent_bin" "$engine" "$target" "$cfg" "$cwd" && return 0
    fi

    # Bundled Python missing (or the builder above failed): emit a plain chat-only transport by
    # hand. mlx-agent needs no Python to run, so chat still works even if the interpreter is gone
    # — this is the honest "never wedges the window" path. JSON-escape the path values (backslash
    # then quote) so spaces/quotes are safe. agent_bin/target are program-controlled and never
    # hold control chars; cwd is user-supplied and validated absolute-and-existing above, so a raw
    # control char in a folder name (APFS permits it) would still slip through unescaped here — a
    # tolerated gap on this rare degraded path (json.dumps on the primary path handles it fully).
    local ae="$(printf '%s' "$agent_bin" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')"
    local te="$(printf '%s' "$target"    | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')"
    local ce="$(printf '%s' "$cwd"       | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')"
    if [ "$engine" = "openai" ]; then
        printf '{"protocol":"acp","transport":{"command":["%s","acp","--backend","openai","--base-url","%s"],"cwd":"%s"}}\n' "$ae" "$te" "$ce"
    else
        printf '{"protocol":"acp","transport":{"command":["%s","acp","--model","%s"],"cwd":"%s"}}\n' "$ae" "$te" "$ce"
    fi
}
