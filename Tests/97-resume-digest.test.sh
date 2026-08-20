#!/bin/sh
# Tests/97-resume-digest.test.sh - resuming a long conversation without replaying all of it.
#
# THE AGENT SUMMARIZES, NOT THIS APP. session/prime takes an optional condense object; the app
# asks by putting the key on the injected content, and the agent does the work at the next prime.
# So what is testable here is the ASKING - and the quiet failure is a request that never reaches
# the wire, because that looks exactly like an agent choosing not to condense: full fidelity, no
# error, just a slower turn nobody attributes to a bug.
#
# Four things, each with a section:
#
# 1. THE REQUEST. Present only when this conversation is set to summarize, and absent when it is
#    not - a stray condense key would summarize a conversation the user asked to see in full.
# 2. THE MENU. Built from what this machine can do (Apple Intelligence is macOS 26+), and inert
#    when the conversation has no older half rather than offering something that will decline.
# 3. THE SUMMARIZER. Which model writes the summary rides on the restore that asked for it, so
#    the choice reaches the conversation in front of the user rather than the next window.
# 4. THE MARKERS. Session boundaries are written by this app, and must survive a reload - which
#    is the whole reason they exist.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

CHAT_ID=1
SLOT_ID=560
PICKER_ID=561

# EVERY WINDOW IN THIS FILE RUNS ITS OWN LOCAL MODEL, and now has to say so.
#
# This file is about what a window may offer to summarize WITH, and "the model in this chat"
# requires there to be a model: since File > New Chat Window a window can be driven by neither a
# model nor an agent, and a bare "no foreign agent" answered yes for that case too - offering to
# summarize with a model the window does not have. The stamp is what chat_engine_load writes for
# every local engine, so a window without it is not a window this file means to describe.
#
# Applied through this wrapper rather than once at the top, because omc_window_switch mints a new
# uuid and the stamp is per window - a single stamp would cover only the first section.
# The sections that model an EXTERNAL agent stamp that too, and the agent still wins.
cad_model_window() { # <label>
    omc_window_switch "$1"
    cad_pb_set "aichatv2_modelpath_$OMC_ACTIONUI_WINDOW_UUID" "/models/Tiny-Q4_K_M.gguf"
}
cad_pb_set "aichatv2_modelpath_$OMC_ACTIONUI_WINDOW_UUID" "/models/Tiny-Q4_K_M.gguf"

cad_hist="$HOME/Library/Application Support/Cadabra/History"
cad_py="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
cad_store="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/history_store.py"

cad_mk_session() { # <sid> <pairs>
    /bin/mkdir -p "$cad_hist/$1"
    /usr/bin/python3 - "$cad_hist/$1" "$2" <<'PY'
import json, sys
d, pairs = sys.argv[1], int(sys.argv[2])
with open(d + "/journal.jsonl", "w") as f:
    n = 0
    for i in range(pairs):
        for role, text in (("local", "question %d" % i), ("agent", "answer %d" % i)):
            f.write(json.dumps({"type": "message", "id": "m%d" % n, "sequence": n,
                                "data": {"type": "message",
                                         "message": {"role": role, "text": text}}}) + "\n")
            n += 1
json.dump({"id": sys.argv[1].rsplit("/", 1)[-1], "created": "2026-08-17",
           "modelPath": "/models/test.gguf"}, open(d + "/meta.json", "w"))
PY
}

# The history library, with Apple Intelligence pinned. Availability is a property of the MACHINE
# (macOS 26+, feature on), so letting the real probe answer would assert one thing here and the
# opposite on the next Mac - the "expected value happens to equal the baseline" trap exactly.
cad_hist_call() {
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh" >/dev/null 2>&1
      prefs="${CAD_PREFS_OVERRIDE:-$OMCTEST_WORK/no-such-registry.plist}"
      case "${CAD_FM_OK:-}" in
          0) summarize_foundation_ok() { return 1; } ;;
          1) summarize_foundation_ok() { return 0; } ;;
      esac
      "$@" )
}

# The mode field of a resolve, which is what the handlers read off it. Asserted through the real
# function rather than a wrapper written for the tests: a helper only the suite calls is a helper
# that can keep passing after production stops using it.
cad_resolved_mode() { # <win> <sid> [lazy]
    set -- $(cad_hist_call summarize_resolve "$@")
    printf '%s\n' "${1:-}"
}

cad_menu_options() { cad_journal "$SLOT_ID"; }
cad_menu_selected() { cad_journal "$PICKER_ID" | /usr/bin/grep -vE '^omc_' | /usr/bin/tail -n 1; }

# The condense key as it appears on the injected content, read back from the recorded call.
cad_injected() { cad_journal "$CHAT_ID" | /usr/bin/sed -n 's/^omc_set_state content //p' | /usr/bin/tail -n 1; }

section "the request is on the wire only when the conversation asks for it"
cad_mk_session long 20
check "a plain restore carries no condense key" "0" \
    "$(cad_has "$("$cad_py" "$cad_store" transcript "$cad_hist/long" defer)" 'condense')"
# Presence of the key IS the request, so what matters is that it appears at all - and that it
# still defers, because the two directives travel together and the prime happens at send time.
check "asking for it puts the key on the content" "1" \
    "$(cad_has "$("$cad_py" "$cad_store" transcript "$cad_hist/long" defer 6)" '"condense": {"keepRecentTurns": 6}')"
check "  and the prime is still deferred"        "1" \
    "$(cad_has "$("$cad_py" "$cad_store" transcript "$cad_hist/long" defer 6)" '"prime": "defer"')"
# An explicit zero means "summarize, your defaults" rather than "keep nothing verbatim": the
# agent clamps its own bounds, and an empty object is a real request.
check "zero asks with no bounds attached"        "1" \
    "$(cad_has "$("$cad_py" "$cad_store" transcript "$cad_hist/long" defer 0)" '"condense": {}')"
check "a non-numeric bound is refused, not sent" "2" \
    "$("$cad_py" "$cad_store" transcript "$cad_hist/long" defer 12x >/dev/null 2>&1; echo $?)"

section "the menu is built from what this machine can actually do"
cad_mk_session short 4
cad_model_window menu
ui_declare_ids "$PICKER_ID"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" long
cad_journal_reset
CAD_FM_OK=0 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" long
check "replaying in full is always on offer"  "1" "$(cad_has "$(cad_menu_options)" '"tag":"full"')"
# Auto is named rather than hidden: it is mlx-agent's own default and it MEASURES rather than
# preferring, which is the kind of thing a user should be able to see they are getting.
check "auto is offered by name"               "1" "$(cad_has "$(cad_menu_options)" '"tag":"auto"')"
check "no Apple Intelligence before macOS 26" "0" "$(cad_has "$(cad_menu_options)" '"tag":"foundation"')"
check "a long conversation defaults to auto"  "auto" "$(cad_menu_selected)"

ui_reset
ui_reset_diagnostics
ui_declare_ids "$PICKER_ID"
CAD_FM_OK=1 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" long
check "with Apple Intelligence it is offered" "1" "$(cad_has "$(cad_menu_options)" '"tag":"foundation"')"

# "The model in this chat" is offered for EVERY engine this app launches, not just gguf. That is
# the fix for a gate that predated the live path: when a separate process did the summarizing,
# borrowing an MLX model meant loading it twice, so the option was hidden behind a running
# llama-server. The `session` summarizer uses the agent's own loaded model, so it is free for all
# of them, and an MLX window was being denied a choice that works.
check "  and so is the chat's own model"     "1" "$(cad_has "$(cad_menu_options)" '"tag":"session"')"

# The exception is an external ACP agent: its command line is the user's, so it need not be
# mlx-agent, need not know these words, and this app cannot say what would summarize there.
ui_reset
ui_reset_diagnostics
ui_declare_ids "$PICKER_ID"
cad_pb_set "aichatv2_agent_$OMC_ACTIONUI_WINDOW_UUID" "opencode"
CAD_FM_OK=1 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" long
check "an external agent offers no own-model choice" "0" \
    "$(cad_has "$(cad_menu_options)" '"tag":"session"')"
check "  but auto is still available"                "1" \
    "$(cad_has "$(cad_menu_options)" '"tag":"auto"')"
cad_pb_set "aichatv2_agent_$OMC_ACTIONUI_WINDOW_UUID" ""

ui_reset
ui_reset_diagnostics
ui_declare_ids "$PICKER_ID"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" short
CAD_FM_OK=1 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" short
check "a short conversation defaults to full" "full" "$(cad_menu_selected)"

section "a conversation with nothing to summarize offers an inert menu, not a trap"
# Reported from real use in the previous design: the control was offered on a short conversation,
# choosing it ran a summarize that declined, and it snapped back with no explanation.
cad_mk_session justshort 3     # 6 messages: keep-recent + 1 or fewer, no older half
check "6 messages cannot be condensed" "1" \
    "$(cad_hist_call summarize_can_condense justshort >/dev/null 2>&1; [ $? -ne 0 ] && echo 1 || echo 0)"
cad_model_window inert
ui_declare_ids "$PICKER_ID"
cad_journal_reset
CAD_FM_OK=1 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" justshort
check "the menu is still offered"          "1" "$(cad_has "$(cad_menu_options)" 'Picker')"
check "  with no summarizing options"      "0" "$(cad_has "$(cad_menu_options)" '"tag":"auto"')"
check "  set to replaying in full"         "full" "$(cad_menu_selected)"
check "  and disabled, so it cannot flash" "1" "$(cad_has "$(cad_journal "$PICKER_ID")" 'omc_disable')"
check "  and it says why"                  "1" "$(cad_has "$(cad_menu_options)" 'no older part to summarize')"

section "the summarizer rides on the restore that asked for it"
# THE USER-VISIBLE BUG THIS SECTION EXISTS FOR: pick "summarize with the model in this chat",
# send a message, and the marker afterwards named apple-foundation-models. WHO summarizes used to
# be --digest-backend, fixed when the agent launched and shared by every window, so a choice made
# in this conversation could not reach the agent already serving it - it applied to the NEXT chat
# window, with nothing on screen saying so.
cad_ask() { "$cad_py" "$cad_store" transcript "$cad_hist/long" defer "$@"; }
check "the chosen summarizer is on the content" "1" \
    "$(cad_has "$(cad_ask 6 session)" '"backend": "session"')"
check "  next to the bound it was asked with"   "1" \
    "$(cad_has "$(cad_ask 6 session)" '"keepRecentTurns": 6')"
# Absent means "however the agent is configured", which is what a conversation nobody has answered
# for should get - not a summarizer this app invented for it.
check "no choice sends no summarizer"           "0" "$(cad_has "$(cad_ask 6)" 'backend')"
check "  on a document that was actually produced" "1" "$(cad_has "$(cad_ask 6)" '"keepRecentTurns": 6')"
# A summarizer with no request to summarize is not a request: the condense object is what asks,
# and a naked backend on a full replay would describe work nobody wanted done.
check "and it never travels without a request"  "0" "$(cad_has "$(cad_ask "" session)" 'backend')"
check "  on a document that was actually produced" "1" "$(cad_has "$(cad_ask "" session)" '"version": 1')"

# THE LAUNCH FLAG IS GONE, and its absence is half the fix. A --digest-backend here would answer
# for every conversation the window ever opens, which is exactly the shape that could disagree
# with the menu.
cad_argv() {
    "$cad_py" "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/acp_transport_json.py" \
        /bin/echo mlx /models/m.gguf "$OMCTEST_WORK/no-such-mcp.json" "$OMCTEST_WORK" true 2>/dev/null
}
check "no --digest-backend reaches the agent" "0" "$(cad_has "$(cad_argv)" 'digest-backend')"
check "  and the transport is still built"    "1" "$(cad_has "$(cad_argv)" '"--model", "/models/m.gguf"')"

# THE SHELL MUST PASS AN EMPTY SLOT, NOT DROP IT. The `${N:+"$N"}` idiom that used to thread these
# optionals drops an empty argument and shifts every argument after it, so a caller with no
# keep-recent but a summarizer would hand the summarizer to the keep-recent slot: the store exits
# 2, prints nothing, and the window displays no conversation at all. Asserted through the SHELL,
# because calling the store directly with an explicit empty argument tests the store's guard and
# not the one that would break.
cad_model_window argvthread
ui_declare_ids "$PICKER_ID"
cad_journal_reset
cad_hist_call history_inject_content "$OMC_ACTIONUI_WINDOW_UUID" "$CHAT_ID" long defer "" session
check "an empty keep-recent still displays the conversation" "1" \
    "$(cad_has "$(cad_injected)" '"version": 1')"
check "  and asks for no summary"                            "0" \
    "$(cad_has "$(cad_injected)" 'condense')"

section "a choice this window cannot honor demotes to auto, and never reaches a foreign agent"
# WHAT DEMOTION IS FOR: only the WHO became impossible. Dropping the summary along with the
# summarizer would throw away the half of the answer that is still honorable, on a conversation
# long enough that the user asked for one.
cad_mk_session demote 20
cad_model_window demotion
ui_declare_ids "$PICKER_ID"
win="$OMC_ACTIONUI_WINDOW_UUID"

cad_hist_call history_set_resume_mode demote foundation
check "Apple Intelligence demotes to auto when this Mac has none" "auto" \
    "$(CAD_FM_OK=0 cad_resolved_mode "$win" demote lazy)"
check "  and stands when it has it"                               "foundation" \
    "$(CAD_FM_OK=1 cad_resolved_mode "$win" demote lazy)"

cad_pb_set "aichatv2_agent_$win" "opencode"
cad_hist_call history_set_resume_mode demote session
check "the chat's own model demotes for someone else's agent"     "auto" \
    "$(CAD_FM_OK=1 cad_resolved_mode "$win" demote lazy)"
cad_hist_call history_set_resume_mode demote foundation
check "  and so does Apple Intelligence"                          "auto" \
    "$(CAD_FM_OK=1 cad_resolved_mode "$win" demote lazy)"

# AND NOTHING IS NAMED AT A FOREIGN AGENT. auto/session/foundation are mlx-agent's words; an
# external agent is the user's own command line and need not know them. Asking it to summarize
# without naming a summarizer is the honest request - naming one would either be ignored, which
# is the original bug in a new place, or refused, which loses the summary.
cad_journal_reset
cad_pb_set "aichatv2_session_$win" ""
export OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE=demote
omc_run aichat.history.selection.changed
check "an external agent is still asked to summarize" "1" "$(cad_has "$(cad_injected)" 'condense')"
check "  but is named no summarizer"                  "0" "$(cad_has "$(cad_injected)" 'backend')"
check "  and the menu offers it none either"          "0" \
    "$(cad_has "$(cad_menu_options)" '"tag":"foundation"')"
unset OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE
cad_pb_set "aichatv2_agent_$win" ""

section "the menu handler records the choice, through the real dispatch"
# DISPATCHED, not called. The read side passes just as happily when the write is broken, and it
# has been: an early version of this handler stored the choice with plister's arguments in the
# wrong order, which parses, exits successfully, and stores nothing - green tests, and every
# window summarizing with something the user had not picked.
cad_mk_session pick 20
cad_model_window modechoice
ui_declare_ids "$PICKER_ID"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" pick
# No external agent stamped on this window, so "the model in this chat" is a choice it can offer.
# Asserted on `session` rather than `foundation` on purpose: Apple Intelligence is a property of
# the MACHINE, and the resolver falls back without it, so a foundation assertion here would pass
# on this Mac and fail on the next one.
cad_pb_set "aichatv2_agent_$OMC_ACTIONUI_WINDOW_UUID" ""
cad_journal_reset
omc_control "$PICKER_ID" "session"
omc_run aichat.chat.summarize.mode
check "the conversation remembers the choice" "session" "$(cad_hist_call history_resume_mode pick)"
# The request has to reach the wire too: recording the choice and injecting without it would be
# the same silent no-op one layer up.
check "the re-injection asks the agent to summarize" "1" "$(cad_has "$(cad_injected)" 'condense')"
# AND IT NAMES THE MODEL THE USER PICKED. This is the check that would have caught the reported
# bug: everything above it was already green while the summary was written by a model chosen by a
# flag the menu could not reach.
check "  naming the summarizer that was chosen"      "1" \
    "$(cad_has "$(cad_injected)" '"backend": "session"')"

# THE HANDLER RESOLVES, IT DOES NOT TRUST THE TAG IT WAS SENT. Injecting $mode directly passes
# every check above and is wrong in exactly the case the resolver exists for: a window driven by
# someone else's agent, where "the model in this chat" is not this app's to promise.
cad_pb_set "aichatv2_agent_$OMC_ACTIONUI_WINDOW_UUID" "opencode"
cad_journal_reset
omc_control "$PICKER_ID" "session"
omc_run aichat.chat.summarize.mode
# Asserted as "no summarizer at all", not as "not this one": demoting `session` to `auto` and then
# sending `auto` to a foreign agent would satisfy the narrower check while still speaking a
# vocabulary this app cannot promise the agent knows.
check "a choice the window cannot honor is not sent as one" "0" \
    "$(cad_has "$(cad_injected)" 'backend')"
check "  and the summary is still asked for"               "1" \
    "$(cad_has "$(cad_injected)" 'condense')"
# AND THE MENU IS CORRECTED TO WHAT WILL HAPPEN. Storing the pick, sending something else, and
# leaving the picker showing the pick is the divergence this whole change exists to close - now
# between three places instead of two. This is also the only assertion that fails when the
# handler injects the tag it was sent instead of resolving it.
check "  and the menu is corrected to match"               "auto" "$(cad_menu_selected)"
check "  while the conversation still remembers the pick"  "session" \
    "$(cad_hist_call history_resume_mode pick)"
cad_pb_set "aichatv2_agent_$OMC_ACTIONUI_WINDOW_UUID" ""

cad_journal_reset
omc_control "$PICKER_ID" "full"
omc_run aichat.chat.summarize.mode
check "choosing full is remembered"                "full" "$(cad_hist_call history_resume_mode pick)"
check "  and asks for no summary at all"           "0"    "$(cad_has "$(cad_injected)" 'condense')"
check "  so no summarizer travels either"          "0"    "$(cad_has "$(cad_injected)" 'backend')"

cad_journal_reset
omc_control "$PICKER_ID" "nonsense"
omc_run aichat.chat.summarize.mode
check "an unrecognized choice falls back to full"  "full" "$(cad_hist_call history_resume_mode pick)"
check "  and asks for no summary"                  "0"    "$(cad_has "$(cad_injected)" 'condense')"

section "resuming asks only when this conversation has an older half"
# The resume handler gates on TWO things - the stored mode, and whether there is anything to
# condense - where the menu handler gates on the mode alone. Both halves are asserted here
# because neither was dispatched by any test before.
cad_model_window resumeask
ui_declare_ids "$PICKER_ID"
cad_mk_session asklong 20
cad_mk_session askshort 3
cad_hist_call history_set_resume_mode asklong session
cad_hist_call history_set_resume_mode askshort session
# "The model in this chat" is only a choice this app can offer when the agent is its own.
cad_pb_set "aichatv2_agent_$OMC_ACTIONUI_WINDOW_UUID" ""

cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" ""
cad_journal_reset
export OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE=asklong
omc_run aichat.history.selection.changed
check "a long conversation set to summarize asks" "1" "$(cad_has "$(cad_injected)" 'condense')"
check "  with the summarizer it was set to"       "1" "$(cad_has "$(cad_injected)" '"backend": "session"')"

cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" ""
cad_journal_reset
export OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE=askshort
omc_run aichat.history.selection.changed
# The stored mode says summarize, but there is no older half - asking anyway would spend a round
# trip for an answer the agent is bound to decline.
check "a short one does not, whatever it stored"  "0" "$(cad_has "$(cad_injected)" 'condense')"

# THE MENU AND THE RESTORE ANSWER TOGETHER, and they used to answer separately: the menu replayed
# in full below CAD_DIGEST_ASK_ABOVE while the restore summarized whenever an older half existed
# at all. A twelve-message conversation therefore displayed "Replay the full conversation" and was
# summarized behind it.
cad_mk_session askmiddling 6      # 12 messages: an older half, but under the ask-above threshold
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" ""
cad_journal_reset
export OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE=askmiddling
omc_run aichat.history.selection.changed
check "an unanswered middling conversation is replayed" "0" "$(cad_has "$(cad_injected)" 'condense')"
check "  and the menu shows what was asked for"         "full" "$(cad_menu_selected)"
unset OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE

section "a resume is the first message sent, not the click that displayed the conversation"
# Marking at selection time recorded a resume for every row the user touched, so browsing a few
# conversations left a run of "Resumed with <model>" lines in each with nothing between them. The
# selection handler now only ARMS the marker; chat.entry.sh writes it when a turn arrives.
cad_mk_session browsed 3
cad_browsed() { "$cad_py" "$cad_store" transcript "$cad_hist/browsed"; }
win="$OMC_ACTIONUI_WINDOW_UUID"

cad_pb_set "aichatv2_session_$win" ""
export OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE=browsed
omc_run aichat.history.selection.changed
check "browsing a conversation records nothing" "0" "$(cad_has "$(cad_browsed)" '"kind": "resumed"')"
check "  but arms the marker for this window"   "browsed" "$(cad_pb_get "aichatv2_resume_pending_$win")"

# The turn arrives. THIS is the resume.
cad_entry() { # <text>
    ( export OMC_ACTIONUI_TRIGGER_CONTEXT="{\"sequence\":1,\"type\":\"message\",\"id\":\"$1\",\"data\":{\"type\":\"message\",\"message\":{\"role\":\"local\",\"text\":\"$1\"}}}"
      omc_run aichat.chat.entry )
}
cad_marker_count() { # <sid>
    "$cad_py" -c 'import json,sys; print(sum(1 for i in json.load(sys.stdin)["items"] if i.get("type")=="sessionEvent"))' <<EOF
$("$cad_py" "$cad_store" transcript "$cad_hist/$1")
EOF
}
# The engine label is stamped so the marker has something to name. An agent stamp rather than a
# model path keeps chat_engine_label off the filesystem.
cad_pb_set "aichatv2_agent_$win" "TestAgent"
cad_entry hello
check "sending into it records the resume"     "1" "$(cad_marker_count browsed)"
# Counting sessionEvents is not enough: a marker of the wrong KIND, or one naming nothing, would
# satisfy a count and tell the reader of the transcript nothing.
check "  recorded as a resume"                 "1" "$(cad_has "$(cad_browsed)" '"kind": "resumed"')"
check "  naming what is about to answer"       "1" "$(cad_has "$(cad_browsed)" '"model": "TestAgent"')"
check "  and disarms, so the next turn is not another resume" "" \
    "$(cad_pb_get "aichatv2_resume_pending_$win")"
# THE MARKER IS ALSO PUT ON SCREEN NOW. Recording it alone left the line explaining the handover
# visible everywhere except the moment it happened - the user had to close and reopen the
# conversation to learn which model was answering. states["content"] cannot serve this: injecting
# replaces the transcript and re-primes the whole conversation.
appended=$(cad_journal "$CHAT_ID" | /usr/bin/grep 'omc_set_state append' | /usr/bin/tail -1)
check "  and reaches the live transcript"      "1" "$(cad_has "$appended" 'omc_set_state append')"
check "    as a decodable ChatItem"            "1" "$(cad_has "$appended" '"type": "sessionEvent"')"
# The ITEM, not the envelope that carried it to the journal. Both start with the same type, so a
# check for the discriminator alone passes on either - and the envelope is not a ChatItem, so
# ChatView would throw on it and drop the restore. The envelope's giveaway is its "data" key.
check "    the item itself, not its envelope"  "0" "$(cad_has "$appended" '"data":')"
check "    with the payload under sessionEvent" "1" "$(cad_has "$appended" '"sessionEvent":')"
check "    naming the model"                   "1" "$(cad_has "$appended" 'TestAgent')"
cad_entry again
check "  a second turn adds no second marker"  "1" "$(cad_marker_count browsed)"

# THE SID ON THE FLAG IS THE ONLY DEFENSE FOR PART OF EVERY SIDEBAR CLICK. Arming happens before
# the window is re-bound, and three bundled-python3 calls run in between, so for a few tens of
# milliseconds the flag names the conversation being opened while the session still names the one
# being left. A turn finalizing in that gap - the user clicks away while the agent is still
# answering - would otherwise stamp a resume onto the conversation they just left, which is the
# exact bug this change exists to remove. Neither disarm path can help: nothing was abandoned.
cad_mk_session leftbehind 3
cad_pb_set "aichatv2_session_$win" "leftbehind"
cad_pb_set "aichatv2_resume_pending_$win" "browsed"
cad_entry straggler
check "a turn into the conversation being left is not the resume" "0" "$(cad_marker_count leftbehind)"
check "  and the arm still belongs to the one being opened" "browsed" \
    "$(cad_pb_get "aichatv2_resume_pending_$win")"
cad_pb_set "aichatv2_agent_$win" ""

# Abandoning an armed conversation must not leave the flag set either.
cad_pb_set "aichatv2_session_$win" ""
export OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE=browsed
omc_run aichat.history.selection.changed
omc_run aichat.chat.new
check "New Chat disarms the pending resume"    "" "$(cad_pb_get "aichatv2_resume_pending_$win")"

# Deleting the loaded conversation is the other way to abandon one.
cad_mk_session doomed 3
cad_pb_set "aichatv2_session_$win" ""
export OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE=doomed
omc_run aichat.history.selection.changed
alerts_reset; alert_answers_reset; alert_answer 0
omc_run aichat.history.delete
check "deleting it disarms the pending resume" "" "$(cad_pb_get "aichatv2_resume_pending_$win")"
alerts_reset; alert_answers_reset
unset OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE

section "session markers are written by the app and survive a reload"
# The reason they exist: the info pane names the model a conversation STARTED with, so a resume
# with a different model is otherwise recorded nowhere.
cad_mk_session marked 3
cad_hist_call history_mark_session marked resumed "Qwen3 4B"
cad_marked() { "$cad_py" "$cad_store" transcript "$cad_hist/marked"; }
check "the marker is in the transcript"   "1" "$(cad_has "$(cad_marked)" '"type": "sessionEvent"')"
check "  naming the model answering"      "1" "$(cad_has "$(cad_marked)" '"model": "Qwen3 4B"')"
check "  and what happened"               "1" "$(cad_has "$(cad_marked)" '"kind": "resumed"')"
# Two resumes must both be recorded. A fixed id would make the second overwrite the first, and a
# conversation would remember only its most recent opening.
cad_hist_call history_mark_session marked modelChanged "Llama 3.1 8B"
check "a second marker does not replace the first" "2" \
    "$("$cad_py" -c '
import json,sys
d=json.load(sys.stdin)
print(sum(1 for i in d["items"] if i.get("type")=="sessionEvent"))' < /dev/stdin <<EOF
$(cad_marked)
EOF
)"
check "an unknown kind is refused" "2" \
    "$("$cad_py" "$cad_store" session-event "$cad_hist/marked" nonsense >/dev/null 2>&1; echo $?)"

# The model is never fed a marker as if it had said it: the wire filter admits only message items
# with role local or agent, so a marker cannot become words the model believes are its own.
check "markers stay out of what the model is told" "6" "$(cad_hist_call history_wire_count marked)"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no table clobbered by a bare value write" "" "$(ui_suspect_writes)"

omctest_end
