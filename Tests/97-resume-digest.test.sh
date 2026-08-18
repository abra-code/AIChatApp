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
# 3. THE SUMMARIZER. --digest-backend is a LAUNCH flag, so it is read from the settings file and
#    validated: an unrecognized value makes mlx-agent exit(2) and the window never gets an agent.
# 4. THE MARKERS. Session boundaries are written by this app, and must survive a reload - which
#    is the whole reason they exist.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

CHAT_ID=1
SLOT_ID=560
PICKER_ID=561

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
omc_window_switch menu
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
# llama-server. --digest-backend session uses the agent's own loaded model, so it is free for all
# of them, and an MLX window was being denied a choice that works.
check "  and so is the chat's own model"     "1" "$(cad_has "$(cad_menu_options)" '"tag":"session"')"

# The exception is an external ACP agent: its command line is the user's, so this app passes it
# no --digest-backend and cannot say what would summarize.
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
omc_window_switch inert
ui_declare_ids "$PICKER_ID"
cad_journal_reset
CAD_FM_OK=1 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" justshort
check "the menu is still offered"          "1" "$(cad_has "$(cad_menu_options)" 'Picker')"
check "  with no summarizing options"      "0" "$(cad_has "$(cad_menu_options)" '"tag":"auto"')"
check "  set to replaying in full"         "full" "$(cad_menu_selected)"
check "  and disabled, so it cannot flash" "1" "$(cad_has "$(cad_journal "$PICKER_ID")" 'omc_disable')"
check "  and it says why"                  "1" "$(cad_has "$(cad_menu_options)" 'no older part to summarize')"

section "the summarizer is a launch flag, read and validated before it reaches the agent"
# An unrecognized value makes mlx-agent exit(2) on a usage error, which would present as a chat
# window whose agent never starts - a long way from the setting that caused it.
check "unset resolves to auto"        "auto"       "$(cad_call_lib aichat.library.sh cad_digest_backend)"
"$cad_plister" set dict "$cad_settings" / >/dev/null 2>&1
"$cad_plister" set string foundation "$cad_settings" /digest-backend >/dev/null 2>&1
check "a stored choice is honored"    "foundation" "$(cad_call_lib aichat.library.sh cad_digest_backend)"
"$cad_plister" set string nonsense "$cad_settings" /digest-backend >/dev/null 2>&1
check "an unknown value is not passed through" "auto" "$(cad_call_lib aichat.library.sh cad_digest_backend)"
"$cad_plister" delete "$cad_settings" /digest-backend >/dev/null 2>&1

# And that it actually reaches the argv the agent is launched with.
cad_argv() {
    "$cad_py" "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/acp_transport_json.py" \
        /bin/echo mlx /models/m.gguf "$OMCTEST_WORK/no-such-mcp.json" "$OMCTEST_WORK" true "$1" 2>/dev/null
}
check "the backend is passed to the agent"    "1" "$(cad_has "$(cad_argv session)" '"--digest-backend", "session"')"
check "auto is passed rather than omitted"    "1" "$(cad_has "$(cad_argv auto)" '"--digest-backend", "auto"')"
# The builder is the last gate before argv: a bad value must be dropped here even if the reader
# above is bypassed, because that is what turns a bad setting into a window with no agent.
check "and a bad value never reaches argv"    "0" "$(cad_has "$(cad_argv nonsense)" 'digest-backend')"

section "the menu handler records the choice, through the real dispatch"
# DISPATCHED, not called. The read side above passes just as happily when the WRITE is broken,
# and it was: plister is `set <type> <value> <file> <path>`, and the first version of the handler
# had the file first. That parses, exits successfully, and stores nothing - so every window would
# have launched on auto no matter what the menu said, with the read side still green.
cad_mk_session pick 20
omc_window_switch modechoice
ui_declare_ids "$PICKER_ID"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" pick
"$cad_plister" delete "$cad_settings" /digest-backend >/dev/null 2>&1
cad_journal_reset
omc_control "$PICKER_ID" "foundation"
omc_run aichat.chat.summarize.mode
check "the conversation remembers the choice" "foundation" "$(cad_hist_call history_resume_mode pick)"
check "and the summarizer setting is stored"  "foundation" "$(cad_call_lib aichat.library.sh cad_digest_backend)"
# The request has to reach the wire too: recording the choice and injecting without it would be
# the same silent no-op one layer up.
check "the re-injection asks the agent to summarize" "1" "$(cad_has "$(cad_injected)" 'condense')"

cad_journal_reset
omc_control "$PICKER_ID" "full"
omc_run aichat.chat.summarize.mode
check "choosing full is remembered"                "full" "$(cad_hist_call history_resume_mode pick)"
check "  and asks for no summary at all"           "0"    "$(cad_has "$(cad_injected)" 'condense')"
# Choosing full must not silently re-pin the summarizer: it is not a summarizer choice.
check "  and leaves the stored summarizer alone"   "foundation" \
    "$(cad_call_lib aichat.library.sh cad_digest_backend)"

cad_journal_reset
omc_control "$PICKER_ID" "nonsense"
omc_run aichat.chat.summarize.mode
check "an unrecognized choice falls back to full"  "full" "$(cad_hist_call history_resume_mode pick)"
check "  and asks for no summary"                  "0"    "$(cad_has "$(cad_injected)" 'condense')"
"$cad_plister" delete "$cad_settings" /digest-backend >/dev/null 2>&1

section "resuming asks only when this conversation has an older half"
# The resume handler gates on TWO things - the stored mode, and whether there is anything to
# condense - where the menu handler gates on the mode alone. Both halves are asserted here
# because neither was dispatched by any test before.
omc_window_switch resumeask
ui_declare_ids "$PICKER_ID"
cad_mk_session asklong 20
cad_mk_session askshort 3
cad_hist_call history_set_resume_mode asklong foundation
cad_hist_call history_set_resume_mode askshort foundation

cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" ""
cad_journal_reset
export OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE=asklong
omc_run aichat.history.selection.changed
check "a long conversation set to summarize asks" "1" "$(cad_has "$(cad_injected)" 'condense')"

cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" ""
cad_journal_reset
export OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE=askshort
omc_run aichat.history.selection.changed
# The stored mode says summarize, but there is no older half - asking anyway would spend a round
# trip for an answer the agent is bound to decline.
check "a short one does not, whatever it stored"  "0" "$(cad_has "$(cad_injected)" 'condense')"
unset OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE

# And the resume left its own marker behind, which is the other half of this handler's job.
check "the resume was recorded in the conversation" "1" \
    "$(cad_has "$("$cad_py" "$cad_store" transcript "$cad_hist/asklong")" '"kind": "resumed"')"

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
