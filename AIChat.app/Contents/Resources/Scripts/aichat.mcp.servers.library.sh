#!/bin/sh
# aichat.mcp.servers.library.sh
# MCP server preferences (the com.abracode.AIChat-mcp plist): read/written by the
# aichat.mcp.servers.* dialog handlers and read by the launch flow. Sourced by those
# handlers and — transitively — by aichat.server.library.sh, whose generate_mcp_configs
# and any_mcp_server_enabled read these prefs. Sources the base library for $plister/$dialog.
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

# "$HOME", not "/Users/$USER" - see the note in aichat.library.sh.
mcp_prefs="$HOME/Library/Preferences/com.abracode.AIChat-mcp.plist"

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
    local d
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
    # the local server has no playlist to re-read, so nothing under AIChat.app is
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
