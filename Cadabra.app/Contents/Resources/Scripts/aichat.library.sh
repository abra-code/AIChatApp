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
# First-model handoff (an empty chat window is handed its engine)
# ──────────────────────────────────────────────────────────────
# Which window a queued launch belongs to, when it belongs to one that is ALREADY OPEN. Empty
# is the normal case and means "open a new window for it", which is what every launch meant
# before File > New Chat Window existed.
#
# Deliberately a sibling of the launch queue rather than a field in it: the queue's format is
# read by four handlers and the MCP dialog moves it around, and widening it to carry a window
# would make every one of those a place where a window uuid could be dropped or mistaken for a
# tools flag. Two keys that travel together are easier to keep honest than one that means two
# things - and the one place they must travel together (the MCP servers dialog, which can hold
# a launch for minutes) moves both into its own window scope for exactly the same reason.
#
# No TTL of its own. Staleness is the QUEUE's question and it answers it with an epoch; this
# only says where. What it does need is disarming when its window closes, which is the chat
# window's cancel handler, below.
LOAD_TARGET_KEY="aichatv2_load_target"

# load_target_arm <chat_window_uuid> — the next queued launch lands in THIS window.
load_target_arm() { pb_set "$LOAD_TARGET_KEY" "$1"; }

# load_target_consume — read+CLEAR; echoes the window uuid, or nothing.
load_target_consume() {
    local val
    val=$(pb_get "$LOAD_TARGET_KEY")
    pb_set "$LOAD_TARGET_KEY" ""
    printf '%s' "$val"
}

# chat_window_open_mark <win> / chat_window_open_clear <win> / chat_window_is_open <win>
#
# Whether a chat window is still on screen, which nothing else here can answer: a window uuid
# is just a string, and omc_dialog_control writing to a window that is gone succeeds quietly.
#
# It exists for ONE hole, and disarming does not close that hole. A first-model launch with
# tools on is parked inside the MCP servers dialog for as long as the user needs there, in that
# dialog's OWN window scope - so a chat window closing meanwhile clears the global key and
# finds nothing to disarm. The launch then arrives for a window that no longer exists, and the
# damage is not a no-op write: chat_engine_load would start a real llama-server for it and
# leave the process orphaned. So the delivery end asks, rather than the closing end telling.
#
# Marked positively, by the window itself. A "this one is dead" marker would read as alive for
# any window whose init never ran at all.
chat_window_open_mark()  { pb_set "aichatv2_open_${1}" "1"; }
chat_window_open_clear() { pb_set "aichatv2_open_${1}" ""; }
chat_window_is_open()    { [ "$(pb_get "aichatv2_open_${1}")" = "1" ]; }

# load_target_disarm_for <chat_window_uuid> — drop the handoff iff it names this window.
# Called when a chat window closes: a launch aimed at a window that no longer exists would
# otherwise be delivered to nothing, and - worse - would divert the NEXT ordinary model pick
# away from opening its own window.
load_target_disarm_for() {
    case "$(pb_get "$LOAD_TARGET_KEY")" in "$1") pb_set "$LOAD_TARGET_KEY" "" ;; esac
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

# "$HOME", not "/Users/$USER". The same path for a normal account, and the two
# differ in every way that matters: $USER is an identity, so a path spelled from
# it is not the account's home but a guess about where the account's home is -
# wrong for a relocated or network home, and unreachable by the one mechanism
# that isolates state under test, which redirects $HOME. This was the last path
# in the app spelled the other way, and it is why the terminate handler's
# registry teardown could not be covered by a test at all: it would have pruned
# the running app's real registry.
prefs="$HOME/Library/Preferences/com.abracode.Cadabra-servers.plist"
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
# THREE SUBTREES, THREE OWNERS, ONE FILE. /servers + /allow-network belong to the MCP library,
# /agents to the ACP agents library, and /recent-models to the model library. None may assume
# it owns the file: see mcp_prefs_write_defaults, which used to begin with `rm -f` and would
# now take the other owners' settings with it.
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

# NO APP-WIDE SUMMARIZER SETTING LIVES HERE ANY MORE, and its absence is deliberate rather than an
# oversight. `cad_digest_backend` read a /digest-backend string out of the settings file and every
# chat window passed it to its agent as --digest-backend, which made "which model summarizes a
# condensed restore" a launch-scoped, app-wide answer. The control that set it is per conversation,
# so the two could not agree: choosing a summarizer for the conversation in front of you reached
# the NEXT window, and this one went on summarizing with whatever it had started with.
#
# The summarizer now rides on each restore's condense object (aichat.history.library.sh, and
# session/prime's `backend` in mlx-agent's docs/session-prime.md), so the conversation carries its
# own answer and nothing app-wide is needed. A /digest-backend left in an existing settings file by
# an older build is inert; nothing reads it.

# process_start_stamp <pid> - the instant that pid started, whitespace-normalized, or nothing
# if there is no such process.
#
# A PID IS NOT AN IDENTITY once it has been written down. Anything that records a pid and reads
# it back later - a lock file, a registry entry that outlives a crash - is holding a number the
# kernel is free to hand to an unrelated process in the meantime, and `kill -0` then reports
# that stranger as the original. Pairing the number with its start time closes it: two processes
# can share a pid, but not also the instant they began. Normalized because `ps` pads the field,
# so the same instant has two spellings and a naive string compare disagrees with itself.
process_start_stamp() { # <pid>
    [ -n "$1" ] || return 0
    /bin/ps -p "$1" -o lstart= 2>/dev/null | /usr/bin/tr -s ' ' | /usr/bin/sed 's/^ *//; s/ *$//'
}

# chat_window_set_status <window_uuid> <status> — reflect load/model/conversation state in a
# chat window's title. Lives in the BASE library so callers that have no business pulling in
# the server library (registry, port pinning, orphan reaping) still have it - the history
# selection handler is the one that forced the move.
chat_window_set_status() { "$dialog" "$1" omc_window "$2"; }
