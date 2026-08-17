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

# model_switch_disarm_for <chat_window_uuid> — drop the handoff iff it targets this window.
# Called from the chat window's close handler: a switch armed by a window that no longer
# exists must not make the selector treat the next pick as an in-place switch (it would
# either target a dead window or pop the cross-engine dialog with no conversation open).
model_switch_disarm_for() {
    local val
    val=$(pb_get "$MODEL_SWITCH_KEY")
    case "$val" in "$1|"*) pb_set "$MODEL_SWITCH_KEY" "" ;; esac
}

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

# ──────────────────────────────────────────────────────────────
# Launch handoff (model selector / Open... -> chat window)
# ──────────────────────────────────────────────────────────────
# ONE pasteboard entry carries a queued model launch: "model_path|use_tools|epoch". A single
# key keeps the model and its tools decision atomic (they can never desync the way two
# separate keys could), and the epoch makes staleness detectable - the pasteboard persists
# across app relaunches, so every reader validates before trusting. use_tools is "true" or
# "false". Model paths may contain "|"; parsing peels fields from the RIGHT so only the last
# two "|" are structural.
#
# This supersedes the bare AICHATV2_MODEL_PATH handoff: the ACP transport needs the tools
# decision at the same instant it needs the model (it builds the agent argv from both), and
# the old scheme carried only the path. AICHATV2_MODEL_PATH is still honored as a fallback
# by the chat init (Finder drops onto the app arrive that way, with no tools decision).
#
# The MCP servers dialog, when the selector routes a tools-on launch through it, moves the
# queue into its own window-scoped key (aichatv2_launch_<window>) at init: the pending launch
# then lives exactly as long as that dialog, a concurrently queued launch from another entry
# point can't clobber it, and a quit/crash with the dialog open leaves no armed global queue.
LAUNCH_QUEUE_KEY="aichatv2_launch_queue"
LAUNCH_QUEUE_TTL=120

# launch_queue_arm <model_path> <use_tools> — queue a launch (re-arming refreshes the epoch).
launch_queue_arm() { pb_set "$LAUNCH_QUEUE_KEY" "$1|$2|$(/bin/date +%s)"; }

# launch_queue_clear — drop any queued launch.
launch_queue_clear() { pb_set "$LAUNCH_QUEUE_KEY" ""; }

# launch_queue_consume — read+CLEAR the queue; echo "model_path|use_tools" only if armed
# within LAUNCH_QUEUE_TTL seconds (every hop that arms it chains to its reader immediately),
# else "". Stale or malformed queues are dropped. Split the result with
# launch_queue_model / launch_queue_tools.
launch_queue_consume() {
    local val rest epoch now age
    val=$(pb_get "$LAUNCH_QUEUE_KEY")
    [ -n "$val" ] || return 0
    launch_queue_clear
    rest=${val%|*}
    epoch=${val##*|}
    case "$epoch" in ""|*[!0-9]*) return 0 ;; esac
    now=$(/bin/date +%s)
    age=$((now - epoch))
    if [ "$age" -ge 0 ] && [ "$age" -le "$LAUNCH_QUEUE_TTL" ]; then
        echo "$rest"
    fi
}

# launch_queue_model / launch_queue_tools <"model_path|use_tools"> — split a consumed queue.
launch_queue_model() { printf '%s' "${1%|*}"; }
launch_queue_tools() { printf '%s' "${1##*|}"; }

# chat_inject_empty <win> — clear the embedded Chat (id 1) to an empty conversation.
# The Chat element's reconcileRestoredContent DEDUPES a re-injected transcript that equals
# the last one, and live-typed turns never update its "last loaded" transcript - so a plain
# {"items":[]} injected twice with typing in between is dropped and the second clear no-ops.
# We disambiguate with a per-window monotonic counter in the transcript "title" (app-owned,
# never rendered by the element, never persisted), so consecutive clears always differ.
# (macOS `date` has no %N, so a timestamp nonce could collide within one second - hence a
# counter.) Under ACP an empty inject clears the DISPLAY AND the agent's context: the element
# seeds the wire from the loaded transcript, so New Chat really does start the model fresh.
# (The old openai-sse transport cleared only the display - that caveat died with the flip.)
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

APPLET_NAME="Cadabra"

# when no model is bundled with the app:
AICHAT_MODEL_PATH=""

# when a model is bundled with the app:
# AICHAT_MODEL_PATH="$OMC_APP_BUNDLE_PATH/Contents/Resources/LFM2-1.2B-F16.gguf"

prefs="/Users/$USER/Library/Preferences/com.abracode.Cadabra-servers.plist"
# Multi-model: each gguf chat window runs its OWN llama-server on its OWN port, so several
# models can be loaded at once (RAM permitting - see warn_ram_pressure_for_new_model). A free
# port is claimed from this range at window init (find_free_port_in) and stashed per-window
# (aichatv2_port_<win>); the window's ACP transport baseURL is frozen to that port for the
# window's life, so an in-place gguf->gguf switch relaunches on the SAME port and needs no
# re-inject. Range chosen clear of v1's 8088-8097 (llama) and 8101-8140 (mcp) so v1 and the
# merged app coexist. (Was a single pinned 8099 in S1 - one active model at a time.)
LLAMA_PORT_RANGE_START="8150"
LLAMA_PORT_RANGE_END="8189"
mcp_app_support="$HOME/Library/Application Support/Cadabra"
# Chat history store root (per-session dirs; see aichat.history.library.sh + history_store.py).
history_root="$mcp_app_support/History"

# The one settings file. Application data the user configured - which MCP servers are on and
# what they may reach, and which external ACP agent to run - NOT a macOS preference, so it
# lives here rather than in ~/Library/Preferences, and in ONE file rather than a plist per
# feature. Emphatically not com.abracode.Cadabra.plist: cfprefsd caches and rewrites that
# domain wholesale on its own schedule, so a script writing it behind cfprefsd's back either
# loses its write or clobbers the system's.
#
# TWO SUBTREES, TWO OWNERS, ONE FILE. /servers + /allow-network belong to the MCP library and
# /agents to the ACP agents library. Neither may assume it owns the file: see
# mcp_prefs_write_defaults, which used to begin with `rm -f` and would now take the other
# owner's settings with it.
cadabra_settings="$mcp_app_support/settings.plist"

# cadabra_settings_init - create the directory and an empty root dict, once.
#
# `plister insert` cannot create the file it inserts into; only `set dict <file> /` can.
# Without this every write no-ops AND RETURNS SUCCESS, which is how a fresh profile's settings
# used to vanish silently. Callers that only READ must not call it - a read path that creates
# files is how merely looking at the configuration ends up writing it.
cadabra_settings_init() {
    [ -f "$cadabra_settings" ] && return 0
    /bin/mkdir -p "$mcp_app_support" 2>/dev/null || return 1
    "$plister" set dict "$cadabra_settings" / >/dev/null 2>&1
}

# chat_window_set_status <window_uuid> <status> — reflect load/model/conversation state in a
# chat window's title. Lives in the BASE library so callers that have no business pulling in
# the server library (registry, port pinning, orphan reaping) still have it - the history
# selection handler is the one that forced the move.
chat_window_set_status() { "$dialog" "$1" omc_window "$2"; }
