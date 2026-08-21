#!/bin/sh
# Tests/95-empty-chat-window.test.sh - a chat window that opens with no model, and the pick
# that gives it one.
#
# The routing is what is worth asserting here, and it is worth asserting because ONE gesture
# now has two destinations. The model bar's button arms the same handoff it always did, and
# the picker's OK decides from the target window's stamps whether that means "change what this
# conversation is talking to" (the matrix, in Tests/93) or "this window has no engine at all -
# give it one". Those two do genuinely different things to a
# live window, and nothing in the JSON or the menu says which one will happen.
#
# The engine load itself is deliberately NOT dispatched: it launches llama-server. What is
# dispatched is everything that decides where a launch goes, plus the guards that refuse to
# deliver one - including the case this file exists to pin, a launch parked in the MCP servers
# dialog while the window it names is closed.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

cad_import_ids aichat.chat.engine.library.sh CE_
cad_import_ids aichat.history.library.sh HL_
cad_import_ids aichat.library.sh BASE_
check "the model bar's button resolved" "542" "$CE_CHAT_MODEL_BTN_ID"
check "and the facts line beside it"    "540" "$HL_CHAT_INFO_TEXT_ID"
# The literal below is asserted, not read from the applet; this is the one check that reports a
# rename once instead of turning that assertion vacuously true.
check "the app calls itself what the tests do" "Cadabra" \
    "$(cad_lib_var APPLET_NAME aichat.library.sh)"
# Both runtime-inserted ids this file's handlers reach: the loading spinner, and the summarize
# picker that New Chat removes. Neither is in the JSON, so neither is known until declared.
check "and the two runtime-inserted ids" "550 551 561" \
    "$BASE_CHAT_OVERLAY_SLOT_ID $BASE_CHAT_OVERLAY_ELEM_ID $HL_CAD_SUMMARIZE_PICKER_ID"

lib() { cad_call_lib aichat.library.sh "$@"; }
hist() { cad_call_lib aichat.history.library.sh "$@"; }

# eng <function> [args...] - the chat engine library, with its two teardown calls neutered.
#
# NOT OPTIONAL. chat_engine_load reaps orphaned processes before it launches anything, and the
# reaper walks `ps` for paths under the REAL $OMC_APP_BUNDLE_PATH - which on a developer's
# machine is their own running copy of this app. The registry seam already fails closed
# (see cad_model_call); this closes the pgrep-based half the same way. Overridden AFTER the
# source, which is what lets it work without a seam in the applet.
eng() {
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.chat.engine.library.sh" >/dev/null 2>&1
      prefs="${CAD_PREFS_OVERRIDE:-$OMCTEST_WORK/no-such-registry.plist}"
      stop_orphaned_servers() { :; }
      reap_orphaned_bundle_processes() { :; }
      "$@" )
}

# json_prop <view-id> <property> - what the window DECLARES for a control, found by id rather
# than by position: the tree is rearranged often enough that a path would be asserting about
# the layout instead of about the control.
json_prop() {
    "$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3" -c '
import json, sys
def walk(node):
    if isinstance(node, dict):
        if node.get("id") == int(sys.argv[2]):
            sys.stdout.write(str(node.get("properties", {}).get(sys.argv[3], "")))
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(json.load(open(sys.argv[1])))
' "$OMC_APP_BUNDLE_PATH/Contents/Resources/Base.lproj/aichat.chat.json" "$1" "$2"
}

# A window uuid that is not this file's own: the picker's OK runs in the PICKER's window and
# acts on a chat window somewhere else, and a test that used one uuid for both could not tell
# the two apart.
CHATWIN="OMCTEST-emptychat-$$"

# A gguf that exists, because model_engine tests the filesystem rather than the name.
MODELS="$OMCTEST_WORK/models"
/bin/mkdir -p "$MODELS"
GGUF="$MODELS/Tiny-Q4_K_M.gguf"
/usr/bin/head -c 4096 /dev/zero > "$GGUF"
OTHER="$MODELS/Other-Q5_K_S.gguf"
/usr/bin/head -c 4096 /dev/zero > "$OTHER"

# empty_window - both engine stamps blank, which is what "this window has no engine" IS.
empty_window() {
    cad_pb_set "aichatv2_modelpath_$CHATWIN" ""
    cad_pb_set "aichatv2_agent_$CHATWIN" ""
    cad_pb_set "aichatv2_open_$CHATWIN" "1"
}

# arm_pick <tools> - the model bar's button, then a row picked in the selector.
arm_pick() {
    # Where the SELECTOR looks: its init captures the global arm into its own scope, and the OK
    # handler below runs as that selector window. Arming the global key here would be arming a
    # doorstep nobody is standing on.
    cad_pb_set "aichatv2_switcharm_$OMC_ACTIONUI_WINDOW_UUID" "$CHATWIN|$(/bin/date +%s)"
    cad_pb_set "aichatv2_load_target" ""
    lib launch_queue_clear
    omc_table_cell 10 3 "$GGUF"
    omc_control 30 "$1"
}

# ---------------------------------------------------------------------------
section "File > New Chat Window opens the chat window and carries no model"
# The whole point of a separate command rather than the menu item pointing at aichat.chat: a
# model picked minutes ago and not yet consumed is still in the queue, and chat init consumes
# whatever it finds. Without the clear, this gesture would silently open that model's window.
chains_reset
lib launch_queue_arm "$GGUF" false
omc_run aichat.chat.window
check_status "the command succeeds" 0
check "it opens the chat window"          "1" "$(chain_asked aichat.chat)"
check "it does not open the model picker" "0" "$(chain_asked aichat.select.local.model)"
check "and nothing is left queued"        ""  "$(cad_pb_get aichatv2_launch_queue)"

# ---------------------------------------------------------------------------
section "an empty window says nothing to itself - the JSON already says it"
# THE ONE BRANCH THAT WRITES NOTHING, and it has to stay that way. It finishes within
# milliseconds of the window being created, sooner than any path before it, and a write that
# early can be refused by a window that is not serving its dialog port yet ("error sending
# request to dialog port"). Every other branch loads an engine first and never noticed.
#
# What makes that safe is that aichat.chat.json ALREADY declares this state, so the two live in
# different files and can drift silently. The assertions below are the join: the declared facts
# line has to be the same sentence chat_info_refresh produces for a window bound to nothing,
# and the button has to arrive already asking for a model.
ui_reset
chains_reset
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" ""
cad_pb_set "aichatv2_agent_$OMC_ACTIONUI_WINDOW_UUID" ""
cad_pb_set "aichatv2_modelpath_$OMC_ACTIONUI_WINDOW_UUID" ""
lib launch_queue_clear
omc_run aichat.chat.init
check_status "init succeeds with no model at all" 0
check "the sidebar is still filled"      "1" "$(cad_writes 510)"
check "the model bar is left alone"      "0" "$(cad_writes "$CE_CHAT_MODEL_BTN_ID")"
check "so is the facts line"             "0" "$(cad_writes "$HL_CHAT_INFO_TEXT_ID")"
check "and the window keeps its name"    "0" "$(ui_calls omc_window)"
check "the window is marked open"        "1" "$(cad_pb_get "aichatv2_open_$OMC_ACTIONUI_WINDOW_UUID")"
check "and no engine was prepared"       "0" "$(ui_calls omc_set_state)"

# The join. chat_info_refresh writes into the live window, so the comparison is against what a
# reader would actually see - not against a string restated here, which is the drift itself.
declared_text=$(json_prop "$HL_CHAT_INFO_TEXT_ID" text)
ui_reset
hist chat_info_refresh "$OMC_ACTIONUI_WINDOW_UUID"
check "the declared facts line is the unbound one" "$(ui_value "$HL_CHAT_INFO_TEXT_ID")" "$declared_text"
check "the button ships asking for a model" "1" \
    "$(cad_has "$(json_prop "$CE_CHAT_MODEL_BTN_ID" title)" "Model")"

# ---------------------------------------------------------------------------
section "a model picked for an empty window is delivered into it, not into a new one"
chains_reset
empty_window
arm_pick false
omc_run aichat.select.local.model.ok
check_status "the pick succeeds" 0
check "it loads into the waiting window" "1" "$(chain_asked aichat.chat.load.model)"
check "  and does not open a second one" "0" "$(chain_asked aichat.chat)"
check "  nor treat it as a switch"       "0" "$(chain_asked aichat.chat.switch.model)"
check "the window is named"              "$CHATWIN" "$(cad_pb_get aichatv2_load_target)"
check "the model rides the launch queue" "1" \
    "$(cad_has "$(cad_pb_get aichatv2_launch_queue)" "$GGUF|false|")"

# ---------------------------------------------------------------------------
section "with tools on it goes by way of the servers dialog, and comes back aimed the same way"
# A fresh session's servers and working directory are chosen in that dialog, and this is a fresh
# session - so the empty window gets the same detour a new window gets. (Changing the decision
# later is the switch's business, and it rebuilds the agent rather than detouring: Tests/93.)
chains_reset
empty_window
arm_pick true
omc_run aichat.select.local.model.ok
check "the servers dialog is asked for" "1" "$(chain_asked aichat.mcp.servers)"
check "  and the load waits"            "0" "$(chain_asked aichat.chat.load.model)"

# The dialog takes ownership of both halves at init and hands them back at Start. Run it in a
# window of its own, which is what makes the window-scoped stash meaningful.
chains_reset
omc_window_switch "mcpdialog"
omc_run aichat.mcp.servers.init
check "the dialog owns the launch now" "" "$(cad_pb_get aichatv2_launch_queue)"
check "  and its destination"          "" "$(cad_pb_get aichatv2_load_target)"
omc_run aichat.mcp.servers.start
check "Start re-arms the launch"        "1" \
    "$(cad_has "$(cad_pb_get aichatv2_launch_queue)" "$GGUF|true|")"
check "  aimed at the waiting window"   "$CHATWIN" "$(cad_pb_get aichatv2_load_target)"
check "  and loads into it"             "1" "$(chain_asked aichat.chat.load.model)"
check "  rather than opening a new one" "0" "$(chain_asked aichat.chat)"

# ---------------------------------------------------------------------------
section "a launch parked in that dialog is dropped when its window closes"
# THE HOLE THIS FILE EXISTS FOR. Disarming happens on the global key, and by this point the
# dialog is holding the handoff in its own scope - so the close cannot reach it and the launch
# is delivered anyway. It must not be acted on: chat_engine_load would start a real
# llama-server for a window that is gone and leave it orphaned on launchd.
chains_reset
cad_pb_set "aichatv2_open_$CHATWIN" ""
omc_window_switch "loadmodel"
omc_run aichat.chat.load.model
check_status "the handler succeeds" 0
check "the queued launch is dropped"  "" "$(cad_pb_get aichatv2_launch_queue)"
check "and no engine was prepared"    "0" "$(ui_calls omc_set_state)"

# ---------------------------------------------------------------------------
section "and it refuses just as quietly when there is nothing to deliver"
ui_reset
cad_pb_set "aichatv2_load_target" ""
lib launch_queue_clear
omc_run aichat.chat.load.model
check_status "no target at all" 0
check "  nothing was written" "0" "$(ui_calls omc_set_state)"

ui_reset
empty_window
cad_pb_set "aichatv2_load_target" "$CHATWIN"
lib launch_queue_clear
omc_run aichat.chat.load.model
check_status "a target but no model" 0
check "  nothing was written" "0" "$(ui_calls omc_set_state)"

# ---------------------------------------------------------------------------
section "a window that already has a model is still switched, not re-engined"
# The other half of the branch. This is the path the empty-window check must not steal: the
# stamps decide, and a window with a model has one.
chains_reset
cad_pb_set "aichatv2_modelpath_$CHATWIN" "$OTHER"
cad_pb_set "aichatv2_agent_$CHATWIN" ""
cad_pb_set "aichatv2_open_$CHATWIN" "1"
cad_pb_set "aichatv2_port_$CHATWIN" "8151"
arm_pick false
cad_pb_set "aichatv2_modelpath_$CHATWIN" "$OTHER"
omc_run aichat.select.local.model.ok
check "it switches in place"        "1" "$(chain_asked aichat.chat.switch.model)"
check "  and does not re-engine it" "0" "$(chain_asked aichat.chat.load.model)"

section "an external agent's window is not an empty one either"
# It has no model path - init blanks it deliberately - so the agent stamp is the only thing
# telling the two apart, and reading only the model path would hand a first engine to a window
# that already has one.
chains_reset
cad_pb_set "aichatv2_modelpath_$CHATWIN" ""
cad_pb_set "aichatv2_agent_$CHATWIN" "Claude Code"
arm_pick false
cad_pb_set "aichatv2_agent_$CHATWIN" "Claude Code"
omc_run aichat.select.local.model.ok
check "it is not given a first engine" "0" "$(chain_asked aichat.chat.load.model)"

# ---------------------------------------------------------------------------
section "loading an engine stamps the window it was loaded INTO"
# The bug this section exists for shipped invisible. chat_engine_load was lifted out of chat
# init, and five pasteboard keys kept interpolating ${chat_window_uuid} - a global that exists
# only in the init script - so from the new handler every stamp landed on a suffixless key and
# the window it had just loaded still looked empty. Nothing visible broke: the model answered.
# Then the next pick from that window's model bar was read as a FIRST load again, and started a
# second llama-server beside the one that window was already talking to.
#
# Run on the mlx branch, the one engine that launches no server: mlx-agent maps the weights
# itself, so the transport is complete as soon as the directory can be named.
MLXDIR="$MODELS/Mlx-Test-Model"
/bin/mkdir -p "$MLXDIR"
printf '{}' > "$MLXDIR/config.json"
/usr/bin/head -c 512 /dev/zero > "$MLXDIR/model.safetensors"
ENGWIN="OMCTEST-engine-$$"
cad_pb_set "aichatv2_modelpath_$ENGWIN" ""
# PLANTED, not blank. Asserting the agent stamp is empty afterwards proves nothing when it was
# empty to begin with - the load has to be seen clearing it for THIS window.
cad_pb_set "aichatv2_agent_$ENGWIN" "STALE"
cad_pb_set "aichatv2_session_$ENGWIN" ""
# A sentinel on the key the bug wrote to. Asserting the right key holds the right value is not
# enough - it was ALSO true before the fix, of a key belonging to nobody.
cad_pb_set "aichatv2_modelpath_" "SENTINEL"
cad_pb_set "aichatv2_agent_" "SENTINEL"
# The loading overlay is inserted into declared slot 550 and removed again, so its own id is
# only ever known at runtime. Declared here rather than silently tripping the undeclared-id
# check, which no other file reaches because none of them loads an engine.
ui_declare_ids "$BASE_CHAT_OVERLAY_ELEM_ID" "$HL_CAD_SUMMARIZE_PICKER_ID"
cad_journal_reset
eng chat_engine_load "$ENGWIN" "$MLXDIR" false false
check_status "the engine loads"  0
# The PHYSICAL directory, not the one handed in: the mlx branch resolves symlinks on purpose,
# because mlx-swift-lm cannot map sharded weights through a symlinked model dir and reports it
# as a missing tensor. Under the harness $TMPDIR that is a real difference (/var -> /private/var),
# which is exactly why the stamp is asserted against the resolved form rather than the input.
MLXREAL=$(cd "$MLXDIR" && pwd -P)
check "the model is stamped for that window" "$MLXREAL" "$(cad_pb_get "aichatv2_modelpath_$ENGWIN")"
check "the agent stamp is blanked for it"    ""        "$(cad_pb_get "aichatv2_agent_$ENGWIN")"
check "and nothing landed on a suffixless key" "SENTINEL" "$(cad_pb_get "aichatv2_modelpath_")"
check "  nor on the agent's"                   "SENTINEL" "$(cad_pb_get "aichatv2_agent_")"
# What the stamp is FOR, end to end: the label the session marker and meta.json are written
# from, and the answer the picker reads to decide this window is no longer empty.
check "the window can name its engine" "Mlx-Test-Model" \
    "$(cad_call_lib aichat.model.library.sh chat_engine_label "$ENGWIN")"
# AND THE CONVERSATION'S OPENING LINE, minted here rather than by the first turn - this is where
# the model that will answer becomes known - and handed to the element to place in front of that
# message when it comes. Not shown now: an empty window is not a conversation, and a window whose
# user never types has nothing to open. Not recorded now either: there is no conversation to
# record it into yet.
englead=$(cad_journal 1 | /usr/bin/grep "omc_set_state lead")
check "a ready engine holds the line the conversation opens with" "1" \
    "$(cad_has "$englead" '"kind": "started"')"
check "  naming the engine it just loaded"     "1" "$(cad_has "$englead" 'Mlx-Test-Model')"
check "  and the app holds the same item"      "1" \
    "$(cad_has "$(cad_pb_get "aichatv2_pending_markers_$ENGWIN")" '"kind": "started"')"
# Nothing reaches the transcript. The append channel is what puts a line on screen, and a line on
# screen here is the claim this change exists to stop making.
check "  and puts nothing on screen"           ""  \
    "$(cad_journal 1 | /usr/bin/grep 'omc_set_state append')"

# THE OTHER BRANCH OF THE SAME DECISION: this window is not starting a conversation, it is being
# given the engine to continue one it is already showing - the empty window opened to READ a saved
# chat. The click that loaded it could mint no marker, because there was no model to name yet.
RESUMEWIN="OMCTEST-engine-resume-$$"
cad_pb_set "aichatv2_modelpath_$RESUMEWIN" ""
cad_pb_set "aichatv2_agent_$RESUMEWIN" ""
cad_pb_set "aichatv2_session_$RESUMEWIN" "some-saved-chat"
cad_pb_set "aichatv2_resume_pending_$RESUMEWIN" "some-saved-chat"
cad_pb_set "aichatv2_pending_markers_$RESUMEWIN" ""
eng chat_engine_load "$RESUMEWIN" "$MLXDIR" false false
check_status "the engine loads into it too" 0
check "an armed window opens with a resume, not a start" "1" \
    "$(cad_has "$(cad_pb_get "aichatv2_pending_markers_$RESUMEWIN")" '"kind": "resumed"')"
check "  naming the model it was just given"   "1" \
    "$(cad_has "$(cad_pb_get "aichatv2_pending_markers_$RESUMEWIN")" 'Mlx-Test-Model')"

section "and a window that has one is not handed another"
# Neither the picker nor the MCP servers dialog is modal, so a launch can be decided for a
# window that acquires an engine while the choosing is still going on. Delivering it anyway
# claims a second port and starts a second llama-server that nothing owns - changing the model of
# a window that HAS one belongs to the switch, which reuses that window's port and stamps.
chains_reset
ui_reset
cad_pb_set "aichatv2_open_$ENGWIN" "1"
cad_pb_set "aichatv2_load_target" "$ENGWIN"
# A DIFFERENT model, and an MLX one. Different, because the stamp is the discriminating
# assertion and queueing the model the window already has would satisfy it whether the guard
# held or not. MLX, because this section drives the real handler - the eng() seam above does
# not cover it - and a queued gguf getting past the guard would take chat_engine_load all the
# way into launch_model_on_port and spawn a real llama-server against the developer's own
# bundle. The mlx branch launches nothing even when it runs.
OTHERMLX="$MODELS/Mlx-Other-Model"
/bin/mkdir -p "$OTHERMLX"
printf '{}' > "$OTHERMLX/config.json"
/usr/bin/head -c 512 /dev/zero > "$OTHERMLX/model.safetensors"
lib launch_queue_arm "$OTHERMLX" false
omc_run aichat.chat.load.model
check_status "the handler succeeds" 0
# THE DISCRIMINATING ONE. The two below are true either way: launch_queue_consume clears the
# queue before it validates, and a refusal and a completed load both end with no second config
# injected. What only the refusal leaves behind is the FIRST engine's stamp, still naming the
# model this window actually has.
check "the window keeps the engine it has" "$MLXREAL" "$(cad_pb_get "aichatv2_modelpath_$ENGWIN")"
check "the launch is dropped"       "" "$(cad_pb_get aichatv2_launch_queue)"
check "and no second engine is prepared" "0" "$(ui_calls omc_set_state)"

# ---------------------------------------------------------------------------
section "a load that fails leaves the window as empty as it found it"
# STAMPED BEFORE IT CAN FAIL. chat_engine_load claims the window - model path, agent, port -
# ahead of the five branches that can still refuse, and until the stamps named the right window
# a failed first load was invisible: the window stayed empty and the user simply tried again.
# Now it would stay claimed by a model it never loaded, and that is not untidy, it is stuck.
# The picker reads exactly this pair to decide the window is empty, so the same model is
# refused as "unchanged", a different gguf is routed to the in-place switch - which relaunches
# a server under a Chat element that never got a config - and the first-load path refuses it
# as already-engined. Three doors, all closed, on a window that has nothing.
#
# Forced through the EXTERNAL branch with no agent command configured. That failure lands after
# the stamps and before anything is launched, so it exercises the rollback without a server, an
# agent binary or a probe that answers differently on different machines.
ui_reset
FAILWIN="OMCTEST-failedload-$$"
cad_pb_set "aichatv2_modelpath_$FAILWIN" ""
cad_pb_set "aichatv2_agent_$FAILWIN" ""
cad_pb_set "aichatv2_port_$FAILWIN" ""
cad_pb_set "aichatv2_session_$FAILWIN" ""
# The exit code directly: OMCTEST_STATUS is what omc_run leaves behind, and this is a library
# call, not a dispatch.
eng chat_engine_load "$FAILWIN" "" false true
fail_rc=$?
check "the load reports failure" "1" "$fail_rc"
check "the model stamp is put back"  "" "$(cad_pb_get "aichatv2_modelpath_$FAILWIN")"
check "  and the agent stamp"        "" "$(cad_pb_get "aichatv2_agent_$FAILWIN")"
check "  and the port"               "" "$(cad_pb_get "aichatv2_port_$FAILWIN")"
check "so the window still reads as empty" "" \
    "$(cad_call_lib aichat.model.library.sh chat_engine_label "$FAILWIN")"

# ---------------------------------------------------------------------------
section "a pick for a window that closed opens a new one, rather than nothing"
# The selector owns its arm for its whole life, so the chat window that asked for the model can
# be closed while the user is still choosing - and the chat window's close cannot reach an arm
# held inside a selector. Both delivery handlers then refuse, correctly and SILENTLY: the
# selector closed and nothing happened at all. The pick is worth more than that - the user
# asked for this model, and only the window they asked it for is gone.
chains_reset
CLOSEDWIN="OMCTEST-closed-$$"
cad_pb_set "aichatv2_modelpath_$CLOSEDWIN" ""
cad_pb_set "aichatv2_agent_$CLOSEDWIN" ""
cad_pb_set "aichatv2_open_$CLOSEDWIN" ""      # closed while the selector was open
cad_pb_set "aichatv2_switcharm_$OMC_ACTIONUI_WINDOW_UUID" "$CLOSEDWIN|$(/bin/date +%s)"
cad_pb_set "aichatv2_load_target" ""
lib launch_queue_clear
omc_table_cell 10 3 "$GGUF"
omc_control 30 false
omc_run aichat.select.local.model.ok
check "the model still opens a window" "1" "$(chain_asked aichat.chat)"
check "  not a load into a dead one"   "0" "$(chain_asked aichat.chat.load.model)"
check "  and nothing is left aimed"    ""  "$(cad_pb_get aichatv2_load_target)"

# ---------------------------------------------------------------------------
section "an empty window does not keep a cleared conversation's name"
# chat_engine_label answers nothing for a window with no engine, and both callers used to
# retitle only when it answered something - so New Chat cleared the transcript and reset the
# facts line while the title went on naming the conversation that had just been left.
ui_reset
cad_pb_set "aichatv2_modelpath_$OMC_ACTIONUI_WINDOW_UUID" ""
cad_pb_set "aichatv2_agent_$OMC_ACTIONUI_WINDOW_UUID" ""
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" "20260101T000000Z-1"
omc_run aichat.chat.new
check_status "New Chat succeeds with no engine" 0
check "the window is retitled"  "1"        "$(ui_calls omc_window)"
check "  to the app's own name" "Cadabra"  "$(ui_title)"
check "and the facts line resets" "New conversation" "$(ui_value "$HL_CHAT_INFO_TEXT_ID")"

# ---------------------------------------------------------------------------
section "closing a chat window disarms a launch aimed at it"
cad_pb_set "aichatv2_load_target" "$CHATWIN"
lib load_target_disarm_for "someone-elses-window"
check "another window's close leaves it alone" "$CHATWIN" "$(cad_pb_get aichatv2_load_target)"
lib load_target_disarm_for "$CHATWIN"
check "its own close drops it"                 ""         "$(cad_pb_get aichatv2_load_target)"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no table clobbered by a bare value write" "" "$(ui_suspect_writes)"

omctest_end
