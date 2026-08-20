#!/bin/sh
# Tests/95-empty-chat-window.test.sh - a chat window that opens with no model, and the pick
# that gives it one.
#
# The routing is what is worth asserting here, and it is worth asserting because ONE gesture
# now has two destinations. The model bar's button arms the same handoff it always did, and
# the picker's OK decides from the target window's stamps whether that means "switch this
# conversation's model" (restart a pinned-port server under a frozen transport) or "this
# window has no engine at all - give it one". Those two do genuinely different things to a
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
check "the model bar's button resolved" "542" "$CE_CHAT_MODEL_BTN_ID"
check "and the facts line beside it"    "540" "$HL_CHAT_INFO_TEXT_ID"

lib() { cad_call_lib aichat.library.sh "$@"; }
hist() { cad_call_lib aichat.history.library.sh "$@"; }

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
    cad_pb_set "aichatv2_model_switch" "$CHATWIN|$(/bin/date +%s)"
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
# The tools decision has to be made BEFORE the transport freezes, and this is the one load
# where it can still be made - so the empty window gets the same detour a new window gets.
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
