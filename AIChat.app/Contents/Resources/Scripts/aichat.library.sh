#!/bin/sh
# aichat.library.sh
# Shared base library: OMC tool aliases, pasteboard + formatting helpers, and the
# global vars every handler needs. Kept small and sourced (directly or transitively)
# by every script. Feature-specific helpers live in dedicated libraries that source
# this one:
#   aichat.mcp.servers.library.sh  — MCP server preferences (mcp_prefs_*)
#   aichat.server.library.sh       — server/proxy launch, teardown, orphan reaping
#   aichat.model.library.sh        — model RAM checks & existing-session activation
#   aichat.mcp.inspect.library.sh  — MCP Servers inspector window
[ -n "${__AICHAT_BASE_LIB:-}" ] && return 0
__AICHAT_BASE_LIB=1

alert="$OMC_OMC_SUPPORT_PATH/alert"
dialog="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
plister="$OMC_OMC_SUPPORT_PATH/plister"
filt="$OMC_OMC_SUPPORT_PATH/filt"
pasteboard="$OMC_OMC_SUPPORT_PATH/pasteboard"
next_command="$OMC_OMC_SUPPORT_PATH/omc_next_command"

# ──────────────────────────────────────────────────────────────
# Pasteboard helpers
# ──────────────────────────────────────────────────────────────

pb_set() { "$pasteboard" "$1" set "$2"; }
pb_get() { "$pasteboard" "$1" get; }

# ──────────────────────────────────────────────────────────────
# Formatting helpers
# ──────────────────────────────────────────────────────────────

# format_bytes <bytes>  ->  human-readable string (KB / MB / GB)
format_bytes() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        printf "%.1f GB" "$(echo "scale=4; $bytes/1073741824" | /usr/bin/bc -l 2>/dev/null)"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        printf "%.0f MB" "$(echo "scale=0; $bytes/1048576" | /usr/bin/bc -l 2>/dev/null)"
    else
        printf "%d KB" "$(echo "scale=0; $bytes/1024" | /usr/bin/bc -l 2>/dev/null)"
    fi
}

# ──────────────────────────────────────────────────────────────
# Globals
# ──────────────────────────────────────────────────────────────

APPLET_NAME="AIChat"

# when no model is bundled with the app:
AICHAT_MODEL_PATH=""

# when a model is bundled with the app:
# AICHAT_MODEL_PATH="$OMC_APP_BUNDLE_PATH/Contents/Resources/LFM2-1.2B-F16.gguf"

prefs="/Users/$USER/Library/Preferences/com.abracode.AIChat-servers.plist"
# base port; aichat.init.sh picks a free port starting here
port_num="8088"
mcp_app_support="$HOME/Library/Application Support/AIChat"
