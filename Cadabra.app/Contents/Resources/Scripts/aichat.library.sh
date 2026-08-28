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

# The one tool here that is NOT an OMC tool, and therefore the one the test harness cannot
# reach by rebuilding $OMC_OMC_SUPPORT_PATH. It is named through a variable so a test can put a
# recorder in its place; nothing else may hardcode /usr/bin/curl on the download path, or that
# path stops being testable. Everything the model downloader does - the size probe, the file
# list, and the transfers themselves - goes through this.
hf_curl="${CADABRA_CURL:-/usr/bin/curl}"

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
# handler consumes it to change THAT window's model in place, with no new window: a restart of
# the pinned-port server when both models are GGUF (llama-server serves whichever model is loaded,
# so the agent never notices), and otherwise a new agent built from the new argv and primed from
# the transcript on screen. Epoch-stamped + TTL-bounded so a
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

# model_switch_valid <armed-value> — echo the chat window UUID if the arm is well-formed and
# within MODEL_SWITCH_TTL seconds, else nothing. Window UUIDs never contain "|".
model_switch_valid() {
    local val="$1" win epoch now age
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

# Where a selector keeps the arm it owns. One spelling, because six call sites spelled it by
# hand and a seventh would have been a silent no-op.
MODEL_SWITCH_ARM_PREFIX="aichatv2_switcharm_"

# model_switch_capture <selector_window_uuid> — the selector takes ownership of the arm at its
# own init, moving it out of the global key into one scoped to this selector window.
#
# THE GLOBAL KEY HOLDS ONE ARM, AND THERE CAN BE MORE THAN ONE SELECTOR. Opening a window
# before choosing its model is the ordinary way to work now, so two empty windows each sending
# their model bar to a selector is an ordinary thing to do - and while the arm was global the
# second one overwrote the first, so the model landed in the window the user was not looking
# at, and the first selector's later pick found nothing armed and opened a third window. The
# selector's Cancel had the mirror of it: it cleared the global key, disarming somebody else.
#
# Same move the MCP servers dialog makes with a queued launch, for the same reason: state that
# belongs to a dialog should live exactly as long as that dialog.
#
# THE SECOND GUARD IS THE CORRECTNESS ONE. The selector's init is a plain command in the SAME
# window, so Reload and Delete re-run it - and an unconditional capture then copied the (by now
# empty) doorstep over the arm this selector was already holding, losing the pick silently.
# That path is not hypothetical: the on-device model's own alert tells the user to press Reload
# and pick again.
#   - already holding one     -> it is ours; a doorstep arm belongs to a selector still opening
#   - nothing on the doorstep -> nothing to take. This one only saves two pasteboard forks per
#     menu-opened init; with it removed the function would write two empty values over two
#     already-empty keys. Kept for the cost, not claimed as a guard.
#
# WHAT THIS DOES NOT CLOSE: two model bars pressed before either selector's init runs. The
# doorstep holds one arm and model_switch_arm overwrites it, so the first window's arm is lost
# and the first selector captures the second window's. Scoping narrows that window from the
# whole life of both dialogs to the gap between arming and an init that does a full model-cache
# discovery - a real reduction, and not a fix. Closing it properly means making the doorstep a
# queue that inits drain in order.
model_switch_capture() {
    local pending
    pending=$(pb_get "$MODEL_SWITCH_KEY")
    [ -n "$pending" ] || return 0
    [ -z "$(pb_get "${MODEL_SWITCH_ARM_PREFIX}${1}")" ] || return 0
    pb_set "${MODEL_SWITCH_ARM_PREFIX}${1}" "$pending"
    pb_set "$MODEL_SWITCH_KEY" ""
}

# model_switch_consume_for <selector_window_uuid> — read+CLEAR this selector's own arm; echo
# the chat window UUID it names, or nothing when it is absent, malformed or stale.
model_switch_consume_for() {
    local val
    val=$(pb_get "${MODEL_SWITCH_ARM_PREFIX}${1}")
    pb_set "${MODEL_SWITCH_ARM_PREFIX}${1}" ""
    model_switch_valid "$val"
}

# model_switch_rearm_for <selector_window_uuid> <chat_window_uuid> — put an arm back, stamped
# now. For a pick this selector declined to carry out (the RAM warning), where the user is
# expected to choose again in the same selector.
model_switch_rearm_for() {
    pb_set "${MODEL_SWITCH_ARM_PREFIX}${1}" "$2|$(/bin/date +%s)"
}

# model_switch_release_for <selector_window_uuid> — drop this selector's arm and nobody else's.
model_switch_release_for() { pb_set "${MODEL_SWITCH_ARM_PREFIX}${1}" ""; }

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
#
# A BARE MARK, and the staleness argument is a bound rather than a mechanism. The pasteboard
# outlives the app and only the close handler clears this, so a crash leaves a "1" behind
# forever. That cannot mislead anyone: window uuids are freshly minted per window and never
# reused, so a stale mark names a uuid nothing will ever ask about again. For it to do harm the
# GLOBAL load target would have to name that same dead uuid at the same time - and the one path
# that can park a launch past a window's death, the MCP servers dialog, dies with the app that
# crashed. Verifying the mark instead would mean recording the app's pid, and this engine gives
# a handler no reliable way to learn it: OMC_FRONT_PROCESS_ID is the FRONTMOST app, which on a
# background quit is somebody else (see the note on stop_all_bundle_servers).
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

# ──────────────────────────────────────────────────────────────
# First-run Hugging Face handoff (launch -> browser -> picker)
# ──────────────────────────────────────────────────────────────
# Launch opens the Hugging Face browser INSTEAD of the model picker when it finds no model
# installed (see Cadabra.main.sh): an empty picker offers nothing to pick, and downloading a
# model is the one thing that user has to do first. This marks the window launch opened so
# its close handler can hand back to the picker - the model just downloaded is then one click
# from a chat, rather than behind a menu the user has no reason to go looking in.
#
# ARMED GLOBALLY, THEN CAPTURED PER WINDOW: the same two-step model_switch_capture uses, for
# the same reason. The arming side is the main command, which has no window uuid to scope the
# key to because the window it is about does not exist yet. The browser's init runs
# milliseconds later, inside that window, and moves the mark into the window's own scope -
# after which a second browser opened from the menu cannot consume a mark that is not about it.
#
# No TTL, unlike the switch arm. Nothing user-driven sits between the arm and the capture -
# it is one command hop - and a global mark left behind by a window whose init never ran is
# claimed by the next browser to open, which opens the picker once, extra, and clears it.
HF_FIRST_RUN_KEY="aichatv2_hf_first_run"
HF_FIRST_RUN_PREFIX="aichatv2_hf_first_run_"

# hf_first_run_arm / hf_first_run_clear - the next Hugging Face browser to open is, or is not,
# the one launch opened.
#
# THE MAIN COMMAND WRITES ONE OF THESE ON EVERY LAUNCH, and is the only writer of the global
# key. That is what bounds the one hole a persistent pasteboard leaves: an arm stranded by a
# crash between the main command and the browser's init would otherwise still be sitting there
# months later, and the next browser opened from the menu - on a Mac now full of models - would
# capture it and announce that nothing is installed. Clearing on every launch means a stale arm
# cannot outlive the launch after the one that stranded it.
hf_first_run_arm()   { pb_set "$HF_FIRST_RUN_KEY" "1"; }
hf_first_run_clear() { pb_set "$HF_FIRST_RUN_KEY" ""; }

# hf_first_run_capture <hf_window_uuid> - take ownership of a global arm, moving it into this
# window's scope. Returns 0 only when there WAS one, so the browser's init can use the same
# call to decide whether to say why the window opened.
hf_first_run_capture() {
    [ "$(pb_get "$HF_FIRST_RUN_KEY")" = "1" ] || return 1
    pb_set "$HF_FIRST_RUN_KEY" ""
    pb_set "${HF_FIRST_RUN_PREFIX}${1}" "1"
    return 0
}

# hf_first_run_armed_for <hf_window_uuid> - 0 if this window is the one launch opened. A PEEK,
# and the reason there is one: the download handler asks so that what it says AFTER a download
# can name what closing the window will actually do, and asking must not be what spends the mark.
hf_first_run_armed_for() { [ "$(pb_get "${HF_FIRST_RUN_PREFIX}${1}")" = "1" ]; }

# hf_first_run_consume_for <hf_window_uuid> - read+CLEAR this window's mark; 0 if this was the
# browser launch opened. Cleared on read, so a close handler that runs twice chains once.
hf_first_run_consume_for() {
    hf_first_run_armed_for "$1" || return 1
    pb_set "${HF_FIRST_RUN_PREFIX}${1}" ""
    return 0
}

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
#
# THE ONLY PLACE A LOAD CAN SAY ANYTHING, and that is why the note below exists. The window title
# used to carry this - and every other transient status - but it sits in the narrow strip above
# the sidebar, where a model name or a conversation title is truncated to nothing useful. The
# title is now the app's name and stays that way (declared as WINDOW_TITLE in Command.json and
# written by nobody); the overlay is where a load has room to describe itself.
CHAT_OVERLAY_SLOT_ID=550
CHAT_OVERLAY_ELEM_ID=551
chat_loading_overlay_show() {
    "$dialog" "$1" "$CHAT_OVERLAY_SLOT_ID" omc_insert_element \
        "{\"type\":\"ProgressView\",\"id\":${CHAT_OVERLAY_ELEM_ID},\"properties\":{\"title\":\"Loading $2…\"}}"
}
# chat_loading_overlay_note <win> <text> - relabel the spinner already on screen.
# A no-op when no overlay is showing: the element id does not exist, and the write is dropped.
chat_loading_overlay_note() {
    "$dialog" "$1" "$CHAT_OVERLAY_ELEM_ID" omc_set_property "title" "$2"
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
# (aichatv2_port_<win>); a window keeps that port for as long as it has a server, so an
# in-place gguf->gguf switch relaunches on the SAME port and needs no re-inject. A switch
# to a model that runs no server stops that server and gives the port back.
# Range chosen clear of v1's 8088-8097 (llama) and 8101-8140 (mcp) so v1 and the
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

# THE WINDOW TITLE IS THE APP'S NAME, AND NOTHING ELSE WRITES IT. There used to be a
# chat_window_set_status here, and six handlers reached for it to report what a window was doing:
# the model being loaded, the conversation that had just been opened, "still loading model…",
# "failed to load model". None of it fit. A NavigationSplitView puts its title over the SIDEBAR,
# in a strip a few hundred points wide, so every one of those strings arrived truncated - a
# 31B model's name and a real conversation title both die in the same ellipsis.
#
# So the title is declared once, as WINDOW_TITLE in Command.json, and left alone. What the old
# statuses said now lives where there is room for it: the model bar names the engine
# (chat_model_bar_set), the facts line describes the conversation (chat_info_refresh), the
# loading overlay describes a load in progress (above), a failure raises the alert it always
# raised, and aichat.chat.error.sh's toast is the pattern for anything transient.
