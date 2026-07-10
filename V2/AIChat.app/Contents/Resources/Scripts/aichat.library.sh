#!/bin/sh
# aichat.library.sh
# Shared base library: OMC tool aliases, pasteboard + formatting helpers, and the
# global vars every handler needs. Kept small and sourced (directly or transitively)
# by every script. Feature-specific helpers live in dedicated libraries that source
# this one:
#   aichat.mcp.servers.library.sh  — MCP server preferences (mcp_prefs_*)
#   aichat.server.library.sh       — server/proxy launch, teardown, orphan reaping
#   aichat.model.library.sh        — model RAM checks & existing-session activation
#   aichat.model.glossary.library.sh — decodes model-name acronyms for the info panes
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
# Model-switch handoff (single-window in-place model change)
# ──────────────────────────────────────────────────────────────
# The toolbar "Model" button (aichat.model.switch), running in the chat window's context,
# arms this with the chat window UUID before opening the model selector; the selector's OK
# handler consumes it to restart the pinned-port server for THAT window in place (no new
# window, no config re-inject - the Chat transport is frozen to the pinned baseURL and
# llama-server serves whichever model is loaded). Epoch-stamped + TTL-bounded so a
# Model-button-then-Cancel can't make a later first-launch model pick look like a switch.
MODEL_SWITCH_KEY="aichatv2_model_switch"
MODEL_SWITCH_TTL=120

# model_switch_arm <chat_window_uuid> — arm the next selector OK to switch this window.
model_switch_arm() { pb_set "$MODEL_SWITCH_KEY" "$1|$(/bin/date +%s)"; }

# model_switch_consume — read+CLEAR the handoff; echo the chat window UUID only if armed
# within MODEL_SWITCH_TTL seconds, else "" (stale/malformed handoffs are dropped). Window
# UUIDs never contain "|".
model_switch_consume() {
    local val win epoch now age
    val=$(pb_get "$MODEL_SWITCH_KEY")
    pb_set "$MODEL_SWITCH_KEY" ""
    [ -n "$val" ] || return 0
    win=${val%|*}
    epoch=${val##*|}
    case "$epoch" in ""|*[!0-9]*) return 0 ;; esac
    now=$(/bin/date +%s)
    age=$((now - epoch))
    if [ "$age" -ge 0 ] && [ "$age" -le "$MODEL_SWITCH_TTL" ]; then
        echo "$win"
    fi
}

# chat_inject_empty <win> — clear the embedded Chat (id 1) to an empty conversation.
# The Chat element's reconcileRestoredContent DEDUPES a re-injected transcript that equals
# the last one, and live-typed turns never update its "last loaded" transcript - so a plain
# {"items":[]} injected twice with typing in between is dropped and the second clear no-ops.
# We disambiguate with a per-window monotonic counter in the transcript "title" (app-owned,
# never rendered by the element, never persisted), so consecutive clears always differ.
# (macOS `date` has no %N, so a timestamp nonce could collide within one second - hence a
# counter.) NOTE: this clears the DISPLAY; the openai-sse transport's wire history is only
# cleared too once ActionUIChat seeds the wire from applyLoadedTranscript (component work).
chat_inject_empty() {
    local win="$1" seq
    seq=$(pb_get "aichatv2_clearseq_${win}")
    case "$seq" in ""|*[!0-9]*) seq=0 ;; esac
    seq=$((seq + 1))
    pb_set "aichatv2_clearseq_${win}" "$seq"
    "$dialog" "$win" 1 omc_set_state content "{\"version\":1,\"items\":[],\"title\":\"__cleared-${seq}__\"}"
}

# ──────────────────────────────────────────────────────────────
# "Loading model" overlay (native, over the chat)
# ──────────────────────────────────────────────────────────────
# chat_loading_overlay_show <win> <model-label> / chat_loading_overlay_hide <win>
# Insert / remove an indeterminate ProgressView spinner into the chat window's ZStack overlay
# slot (id 550, sits ON TOP of the Chat) while llama-server loads a model. A title-only
# ProgressView renders as a spinner + label. This lives in the applet because the Chat element
# CANNOT know about model loading - its transport is not built until the config is injected
# AFTER the /health probe, i.e. after the load already succeeded. (The element does know when it
# is awaiting a REPLY; that is a separate, component-level concern.)
CHAT_OVERLAY_SLOT_ID=550
CHAT_OVERLAY_ELEM_ID=551
chat_loading_overlay_show() {
    "$dialog" "$1" "$CHAT_OVERLAY_SLOT_ID" omc_insert_element \
        "{\"type\":\"ProgressView\",\"id\":${CHAT_OVERLAY_ELEM_ID},\"properties\":{\"title\":\"Loading $2…\"}}"
}
chat_loading_overlay_hide() {
    "$dialog" "$1" "$CHAT_OVERLAY_ELEM_ID" omc_remove_element
}

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

APPLET_NAME="AIChatV2"

# when no model is bundled with the app:
AICHAT_MODEL_PATH=""

# when a model is bundled with the app:
# AICHAT_MODEL_PATH="$OMC_APP_BUNDLE_PATH/Contents/Resources/LFM2-1.2B-F16.gguf"

prefs="/Users/$USER/Library/Preferences/com.abracode.AIChatV2-servers.plist"
# V2 pins a single llama-server port (S1: one active model at a time). Chosen outside
# v1's 8088-8097 llama range and 8101-8140 mcp range so v1 and v2 coexist. The Chat
# element's static baseURL in aichat.chat.json must match this.
port_num="8099"
mcp_app_support="$HOME/Library/Application Support/AIChatV2"
# Chat history store root (per-session dirs; see aichat.history.library.sh + history_store.py).
history_root="$mcp_app_support/History"
