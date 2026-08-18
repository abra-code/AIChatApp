#!/bin/sh
# Tests/97-resume-digest.test.sh - resuming a long conversation as a digest.
#
# Four things here can go wrong quietly, and each has a section:
#
# 1. THE WIRE FILTER. The digest summarizes what the MODEL saw, which is not what the window
#    shows: thoughts, tool calls and system notices are display items. A filter that drifts from
#    ACPChatTransport.primeHistory produces a summary of a conversation that never happened, and
#    it reads as authoritative.
# 2. THE GUARD. A digest takes seconds and a sidebar is a list people click through. Without a
#    check immediately before the write, one conversation's summary lands in a window showing
#    another - and because injecting also seeds the wire, the model gets primed with it.
# 3. THE FALLBACK. Every way the summarizer can decline has to end at the full conversation. A
#    resume that ends with an empty window is worse than one that ignored the menu.
# 4. SILENT SUBSTITUTION. The menu NAMES which model writes the summary, and the summary becomes
#    the model's memory of what it replaces. A choice that cannot be honored must be refused and
#    reported, never quietly served by a different model - and which models are available differs
#    per machine (Apple Intelligence is macOS 26+) and per chat (only a gguf window has a live
#    server to borrow), which is why the control is a menu at all.
#
# The summarizer itself is a stand-in (helpers/fake_mlx_agent_digest.sh) - see its header.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

CHAT_ID=1
SLOT_ID=560
PICKER_ID=561

cad_hist="$HOME/Library/Application Support/Cadabra/History"
fake_agent="$OMCTEST_TESTS/helpers/fake_mlx_agent_digest.sh"

# cad_mk_session <sid> <pairs> - a saved conversation of <pairs> user/assistant exchanges.
# Written as a journal, the way the applet writes one, so the transcript codec under test is
# the same code that reads a real conversation.
cad_mk_session() { # <sid> <pairs>
    "$cad_plister" >/dev/null 2>&1   # touch nothing; keeps the helper honest about its deps
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

# cad_hist_call <function> [args...] - the history library, with the summarizer redirected.
# Same shape as cad_model_call, and it FAILS CLOSED the same way: with no override the agent
# path points at a file that does not exist, so a test that forgets to redirect gets a refusal
# rather than a real summarization of its fixture.
cad_hist_call() {
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh" >/dev/null 2>&1
      history_agent_bin="${CAD_AGENT_OVERRIDE:-$OMCTEST_WORK/no-such-agent}"
      prefs="${CAD_PREFS_OVERRIDE:-$OMCTEST_WORK/no-such-registry.plist}"
      # Apple Intelligence availability is a property of the MACHINE - macOS 26 and later, with
      # the feature switched on - so a test that let the real probe answer would assert one thing
      # on this Mac and the opposite on the next, which is the "expected value happens to equal
      # the baseline" trap in its purest form. CAD_FM_OK pins it. The real function is tested
      # separately, against a stubbed probe, so nothing here depends on this override being right.
      case "${CAD_FM_OK:-}" in
          0) summarize_foundation_ok() { return 1; } ;;
          1) summarize_foundation_ok() { return 0; } ;;
      esac
      "$@" )
}

# cad_menu_options <win> - the options JSON the menu was built with.
cad_menu_options() { cad_journal "$SLOT_ID"; }

# cad_menu_selected <win> - the tag the menu was set to, i.e. the last plain value written to it.
# omc_disable and friends are commands rather than values, so they are filtered out here.
cad_menu_selected() {
    cad_journal "$PICKER_ID" | /usr/bin/grep -vE '^omc_' | /usr/bin/tail -n 1
}

section "the wire filter is the transport's filter, not the display's"
# Built with one of every item type the store knows about. Only the two message items whose
# role is local or agent may reach the digest.
/bin/mkdir -p "$cad_hist/mixed"
/usr/bin/python3 - "$cad_hist/mixed" <<'PY'
import json, sys
rows = [
    ("message", {"role": "local", "text": "keep me"}),
    ("thought", {"role": "agent", "text": "internal reasoning"}),
    ("message", {"role": "agent", "text": "keep me too"}),
    ("message", {"role": "system", "text": "session notice"}),
    ("message", {"role": "remote", "text": "peer line"}),
    ("message", {"role": "local", "text": ""}),
]
with open(sys.argv[1] + "/journal.jsonl", "w") as f:
    for i, (etype, msg) in enumerate(rows):
        f.write(json.dumps({"type": etype, "id": "i%d" % i, "sequence": i,
                            "data": {"type": etype, "message": msg}}) + "\n")
        if etype == "toolCall":
            continue
json.dump({"id": "mixed"}, open(sys.argv[1] + "/meta.json", "w"))
PY
check "only local and agent messages count" "2" "$(cad_hist_call history_wire_count mixed)"
# The positive control for the filter: without it, "2" could mean the reader found nothing and
# happened to agree. A conversation of known size must report its own size.
cad_mk_session plain 5
check "a plain conversation counts every turn" "10" "$(cad_hist_call history_wire_count plain)"
check "an unknown conversation counts zero"     "0"  "$(cad_hist_call history_wire_count nosuch)"

section "there is nothing to condense in a short conversation"
# Exit 3, the same code mlx-agent uses for "not condensed", so the caller can fall back without
# parsing a message. A conversation that would keep every message verbatim has no older half.
cad_mk_session tiny 3
check "digest-input declines a 6-message conversation" "3" \
    "$("$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3" \
        "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/history_store.py" \
        digest-input "$cad_hist/tiny" 6 >/dev/null 2>&1; echo $?)"
check "and accepts a long one" "0" \
    "$("$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3" \
        "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/history_store.py" \
        digest-input "$cad_hist/plain" 6 >/dev/null 2>&1; echo $?)"

section "the digested transcript is a user turn, an acknowledgment, then the tail verbatim"
# The preamble MUST be a local (user) item. primeHistory keeps only local and agent items, so a
# system item would display the summary and never send it - visible to the person, invisible to
# the model it was written for, which is the failure mode that looks like it worked.
cad_mk_session shape 9
printf 'Context restored from an earlier conversation.\n\nEstablished facts:\n- a fact\n' \
    > "$OMCTEST_WORK/preamble.txt"
"$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3" \
    "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/history_store.py" \
    digest-transcript "$cad_hist/shape" "$OMCTEST_WORK/preamble.txt" 6 defer \
    > "$OMCTEST_WORK/shape.json" 2>/dev/null
cad_shape() { /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d, "json": json}))' "$OMCTEST_WORK/shape.json" "$1"; }
check "the preamble is a user turn"        "local"        "$(cad_shape 'd["items"][0]["message"]["role"]')"
check "the acknowledgment is the agent's"  "agent"        "$(cad_shape 'd["items"][1]["message"]["role"]')"
check "and is the exact string mlx-agent primes" "Acknowledged." \
    "$(cad_shape 'd["items"][1]["message"]["text"]')"
check "the tail is kept, and only the tail" "8"           "$(cad_shape 'len(d["items"])')"
check "the last message survives verbatim"  "answer 8"    "$(cad_shape 'd["items"][-1]["message"]["text"]')"
# Scoped to the ITEMS on purpose. The transcript keeps the conversation's title, and the title
# is derived from its first user line - so the whole-document form of this check reports the
# opening question as present and would have to be weakened to pass. The title staying put is
# correct: a summarized conversation is still that conversation in the sidebar.
check "the summarized turns are gone"       "False"       "$(cad_shape '"question 0" in json.dumps(d["items"])')"
check "  but the conversation keeps its title" "question 0" "$(cad_shape 'd.get("title")')"
check "it still defers the prime"           "defer"       "$(cad_shape 'd.get("prime")')"

section "an empty preamble builds nothing"
# A digest that produced no text must not become a transcript. Injecting one would replace the
# conversation with two content-free turns - the shape of a successful resume, with the
# conversation missing.
: > "$OMCTEST_WORK/empty.txt"
check "digest-transcript refuses an empty preamble" "1" \
    "$("$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3" \
        "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/history_store.py" \
        digest-transcript "$cad_hist/shape" "$OMCTEST_WORK/empty.txt" 6 defer >/dev/null 2>&1; echo $?)"

section "the menu is built from what this machine can actually do"
# The reason this is a menu and not a checkbox: which model can write a summary differs per
# machine and per chat. Apple Intelligence needs macOS 26 or later; the chat's own model is
# reachable only when a llama-server is already running it. A checkbox cannot say any of that.
cad_mk_session long 20
cad_mk_session short 4
omc_window_switch resume-default
ui_declare_ids "$PICKER_ID"

cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" long
cad_journal_reset
CAD_FM_OK=0 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" long
check "replaying in full is always on offer"   "1" "$(cad_has "$(cad_menu_options)" '"tag":"full"')"
# The label and the control are sized as a pair. Asserted because they are easy to change
# independently and the result - a footnote label beside a default-size menu - looks like two
# unrelated controls rather than one, which is exactly how this shipped the first time.
check "the menu is the small control variant"  "1" "$(cad_has "$(cad_menu_options)" '"controlSize":"small"')"
check "  and its label is sized to match"      "1" "$(cad_has "$(cad_menu_options)" '"font":"subheadline"')"
check "no Apple Intelligence before macOS 26"  "0" "$(cad_has "$(cad_menu_options)" '"tag":"foundation"')"
check "and no chat model without a live server" "0" "$(cad_has "$(cad_menu_options)" '"tag":"session"')"
check "  so the only choice is selected"       "full" "$(cad_menu_selected)"
check "  and the menu says why it cannot help" "1" \
    "$(cad_has "$(cad_menu_options)" 'Apple Intelligence needs macOS 26')"

ui_reset
ui_reset_diagnostics
ui_declare_ids "$PICKER_ID"
CAD_FM_OK=1 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" long
check "with Apple Intelligence the option appears" "1" \
    "$(cad_has "$(cad_menu_options)" '"tag":"foundation"')"
check "  and a long conversation defaults to it"   "foundation" "$(cad_menu_selected)"

ui_reset
ui_reset_diagnostics
ui_declare_ids "$PICKER_ID"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" short
CAD_FM_OK=1 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" short
check "a short conversation still offers the choice" "1" \
    "$(cad_has "$(cad_menu_options)" '"tag":"foundation"')"
check "  but defaults to replaying in full"         "full" "$(cad_menu_selected)"

section "a remembered answer beats the recommendation, and an unavailable one does not stick"
# The recommendation is about length; the answer is about what this person wants. But a stored
# choice whose model is gone - Apple Intelligence switched off, the chat's server stopped - must
# not be shown as selected: it would fail the moment it ran.
cad_hist_call history_set_resume_mode long full
check "the answer is stored with the conversation" "full" "$(cad_hist_call history_resume_mode long)"
ui_reset
ui_reset_diagnostics
ui_declare_ids "$PICKER_ID"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" long
CAD_FM_OK=1 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" long
check "a long conversation answered 'full' stays full" "full" "$(cad_menu_selected)"

cad_hist_call history_set_resume_mode long foundation
ui_reset
ui_reset_diagnostics
ui_declare_ids "$PICKER_ID"
CAD_FM_OK=1 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" long
check "a stored summarizer is honored when available" "foundation" "$(cad_menu_selected)"

ui_reset
ui_reset_diagnostics
ui_declare_ids "$PICKER_ID"
CAD_FM_OK=0 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" long
check "  and dropped when the machine cannot do it" "full" "$(cad_menu_selected)"

section "a conversation with nothing to summarize offers an inert menu, not a trap"
# The bug this exists for, reported from real use: the control was offered on a short
# conversation, choosing to summarize ran a digest that declined, and the control snapped back.
# It flashed with no explanation, which reads as the app fighting the user.
#
# The rule is asked of digest-input, the same call the digest itself makes, so the control and
# the action can never disagree about what is possible.
cad_mk_session justshort 3     # 6 messages: at or below keep-recent + 1, nothing to condense
cad_mk_session justlong 5      # 10 messages: an older half exists
check "6 messages cannot be condensed"  "1" \
    "$(cad_hist_call summarize_can_condense justshort >/dev/null 2>&1; [ $? -ne 0 ] && echo 1 || echo 0)"
check "10 messages can be"              "1" \
    "$(cad_hist_call summarize_can_condense justlong >/dev/null 2>&1; [ $? -eq 0 ] && echo 1 || echo 0)"

omc_window_switch inert
ui_declare_ids "$PICKER_ID"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" justshort
cad_journal_reset
CAD_FM_OK=1 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" justshort
check "the menu is still offered"          "1" "$(cad_has "$(cad_menu_options)" 'Picker')"
check "  with no summarizing options"      "0" "$(cad_has "$(cad_menu_options)" '"tag":"foundation"')"
check "  set to replaying in full"         "full" "$(cad_menu_selected)"
check "  and disabled, so it cannot flash" "1" "$(cad_has "$(cad_journal "$PICKER_ID")" 'omc_disable')"
check "  and it says why"                  "1" "$(cad_has "$(cad_menu_options)" 'no older part to summarize')"

# The control: a conversation that CAN be condensed, on a machine that can summarize, is live.
ui_reset
ui_reset_diagnostics
ui_declare_ids "$PICKER_ID"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" justlong
CAD_FM_OK=1 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" justlong
check "a condensable conversation is left enabled" "0" \
    "$(cad_has "$(cad_journal "$PICKER_ID")" 'omc_disable')"

section "the summary is written by the model the menu names"
# Who writes the summary is not a detail: it becomes the model's memory of everything it
# replaces. The first version hardcoded the on-device model, so a conversation held with a large
# local model was summarized by a 3B one and then carried that summary as fact.
#
# Empty output means "cannot be honored", and the caller treats that as a refusal rather than
# summarizing with something else - substituting a different model than the menu named would
# make the menu a lie.
omc_window_switch backend
check "no live server means the chat model is refused" "" \
    "$(cad_hist_call summarize_backend_args "$OMC_ACTIONUI_WINDOW_UUID" session)"
check "Apple Intelligence off means it is refused"     "" \
    "$(CAD_FM_OK=0 cad_hist_call summarize_backend_args "$OMC_ACTIONUI_WINDOW_UUID" foundation)"
check "Apple Intelligence on names the on-device model" "--backend foundation" \
    "$(CAD_FM_OK=1 cad_hist_call summarize_backend_args "$OMC_ACTIONUI_WINDOW_UUID" foundation)"
check "an unknown mode is refused rather than guessed"  "" \
    "$(CAD_FM_OK=1 cad_hist_call summarize_backend_args "$OMC_ACTIONUI_WINDOW_UUID" whatever)"

cad_pb_set "aichatv2_port_$OMC_ACTIONUI_WINDOW_UUID" "not-a-port"
check "a malformed port does not become a URL" "" \
    "$(cad_hist_call summarize_backend_args "$OMC_ACTIONUI_WINDOW_UUID" session)"

# A port nothing is listening on: the stash outlives the server, and offering a dead one would
# put a choice in the menu that fails the moment it is picked.
cad_pb_set "aichatv2_port_$OMC_ACTIONUI_WINDOW_UUID" "8199"
check "a dead port is refused, not dialed" "" \
    "$(cad_hist_call summarize_backend_args "$OMC_ACTIONUI_WINDOW_UUID" session)"

# A live one. A throwaway server answering /v1/models the way llama-server does is enough - the
# probe asks nothing else of it.
cad_fake_port=8197
( /usr/bin/python3 -c '
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type","application/json")
        self.end_headers(); self.wfile.write(b"{\"data\":[]}")
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), H) as s:
    s.serve_forever()' "$cad_fake_port" >/dev/null 2>&1 & echo $! > "$OMCTEST_WORK/fakeserver.pid" )
omc_wait_for "/usr/bin/curl -fsS --max-time 1 http://127.0.0.1:$cad_fake_port/v1/models" 5
cad_pb_set "aichatv2_port_$OMC_ACTIONUI_WINDOW_UUID" "$cad_fake_port"
check "a live server names the chat's own model" \
    "--backend openai --base-url http://127.0.0.1:$cad_fake_port/v1" \
    "$(cad_hist_call summarize_backend_args "$OMC_ACTIONUI_WINDOW_UUID" session)"

# And that the menu OFFERS it, which is a different question from whether it works.
omc_window_switch backend-menu
ui_declare_ids "$PICKER_ID"
cad_pb_set "aichatv2_port_$OMC_ACTIONUI_WINDOW_UUID" "$cad_fake_port"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" long
cad_journal_reset
CAD_FM_OK=0 cad_hist_call summarize_show "$OMC_ACTIONUI_WINDOW_UUID" long
check "a gguf chat offers its own model"   "1" "$(cad_has "$(cad_menu_options)" '"tag":"session"')"
check "  and prefers it for a long chat"   "session" "$(cad_menu_selected)"

# AND THAT THE DIGEST ACTUALLY USES IT. The checks above test the chooser in isolation, and a
# chooser nobody calls is worth nothing: reverting history_digest_inject to a hardcoded backend
# left every one of them green. This reads the flags the summarizer was really invoked with.
cad_pb_set "aichatv2_resume_epoch_$OMC_ACTIONUI_WINDOW_UUID" "bk"
: > "$OMCTEST_WORK/backend-argv.log"
FAKE_DIGEST_LOG="$OMCTEST_WORK/backend-argv.log" CAD_AGENT_OVERRIDE="$fake_agent" \
    cad_hist_call history_digest_inject "$OMC_ACTIONUI_WINDOW_UUID" "$CHAT_ID" long bk session
check "the digest is invoked with the chosen model" "1" \
    "$(cad_has "$(/bin/cat "$OMCTEST_WORK/backend-argv.log" 2>/dev/null)" "--base-url http://127.0.0.1:$cad_fake_port/v1")"
check "  and not a hardcoded on-device one"         "0" \
    "$(cad_has "$(/bin/cat "$OMCTEST_WORK/backend-argv.log" 2>/dev/null)" '--backend foundation')"

# The refusal reaches the caller as 4 rather than being served by a different model.
: > "$OMCTEST_WORK/backend-argv.log"
FAKE_DIGEST_LOG="$OMCTEST_WORK/backend-argv.log" CAD_AGENT_OVERRIDE="$fake_agent" CAD_FM_OK=0 \
    cad_hist_call history_digest_inject "$OMC_ACTIONUI_WINDOW_UUID" "$CHAT_ID" long bk foundation
check "an unavailable summarizer refuses"     "4" "$?"
# And a caller that names NO summarizer is refused too, rather than quietly getting one. This
# path is unreachable from the app today - every call site passes a mode - so it is defensive,
# and defensive code that nothing exercises is how a default creeps back in. A function built on
# "refuse rather than substitute" must not itself substitute for a caller who forgot to ask.
: > "$OMCTEST_WORK/backend-argv.log"
FAKE_DIGEST_LOG="$OMCTEST_WORK/backend-argv.log" CAD_AGENT_OVERRIDE="$fake_agent" CAD_FM_OK=1 \
    cad_hist_call history_digest_inject "$OMC_ACTIONUI_WINDOW_UUID" "$CHAT_ID" long bk
check "naming no summarizer is refused, not defaulted" "4" "$?"
check "  and again nothing was invoked"                "0" \
    "$([ -s "$OMCTEST_WORK/backend-argv.log" ] && echo 1 || echo 0)"
check "  without invoking anything at all"    "0" \
    "$([ -s "$OMCTEST_WORK/backend-argv.log" ] && echo 1 || echo 0)"
unset FAKE_DIGEST_LOG CAD_AGENT_OVERRIDE

/bin/kill "$(/bin/cat "$OMCTEST_WORK/fakeserver.pid" 2>/dev/null)" 2>/dev/null
cad_pb_set "aichatv2_port_$OMC_ACTIONUI_WINDOW_UUID" ""

section "the on-device verdict comes from the app's own probe"
# summarize_foundation_ok is overridden elsewhere in this file so the DECISIONS can be tested on
# any machine. This section tests the function itself, with the probe stubbed instead, so the
# override never has to be taken on trust. osTooOld is exactly the pre-macOS-26 case.
cad_fm_with_probe() { # <reason>
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh" >/dev/null 2>&1
      . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh" >/dev/null 2>&1
      eval "foundation_probe() { printf '$1\tstubbed\n'; }"
      summarize_foundation_ok && echo 1 || echo 0 )
}
check "macOS older than 26 cannot summarize" "0" "$(cad_fm_with_probe osTooOld)"
check "an ineligible device cannot either"   "0" "$(cad_fm_with_probe deviceNotEligible)"
check "a ready machine can"                  "1" "$(cad_fm_with_probe available)"
# The denylist direction matters: an unknown reason from a newer agent must not retire the
# feature on a machine that just gained a state this build has not heard of.
check "an unrecognized reason is not fatal"  "1" "$(cad_fm_with_probe somethingNew)"

section "a stale digest never lands after the user has moved on"
# The guard is a TOKEN, not a session id, and this section is why. Every action that changes
# what is displayed bumps it, so a digest overtaken by any of them stands down. A session-id
# comparison could only see the first of the three cases below.
omc_window_switch guard
ui_declare_ids "$PICKER_ID"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" long
cad_pb_set "aichatv2_resume_epoch_$OMC_ACTIONUI_WINDOW_UUID" "current"
cad_journal_reset
CAD_FM_OK=1 CAD_AGENT_OVERRIDE="$fake_agent" \
    cad_hist_call history_digest_inject "$OMC_ACTIONUI_WINDOW_UUID" "$CHAT_ID" long stale foundation
check "a digest carrying a stale token is superseded" "5" "$?"
check "  and the chat was not touched"             "0" "$(cad_writes "$CHAT_ID")"

# The case a session-id guard could not catch, and the one a real user hits: same conversation
# throughout, but they unchecked the box while the digest was still running. The session id
# never changed; only the decision did.
cad_journal_reset
cad_hist_call history_set_resume_mode long full
epoch_then=$(cad_hist_call resume_epoch "$OMC_ACTIONUI_WINDOW_UUID")
cad_hist_call resume_epoch_bump "$OMC_ACTIONUI_WINDOW_UUID" >/dev/null
CAD_FM_OK=1 CAD_AGENT_OVERRIDE="$fake_agent" \
    cad_hist_call history_digest_inject "$OMC_ACTIONUI_WINDOW_UUID" "$CHAT_ID" long "$epoch_then" foundation
check "a digest overtaken by the menu is superseded" "5" "$?"
check "  so choosing full is not undone seconds later" "0" "$(cad_writes "$CHAT_ID")"

# The positive control: the same call carrying the CURRENT token must write. Without it every
# check above would pass just as happily with the digest broken outright.
cad_journal_reset
epoch_now=$(cad_hist_call resume_epoch "$OMC_ACTIONUI_WINDOW_UUID")
CAD_FM_OK=1 CAD_AGENT_OVERRIDE="$fake_agent" \
    cad_hist_call history_digest_inject "$OMC_ACTIONUI_WINDOW_UUID" "$CHAT_ID" long "$epoch_now" foundation
check "the same call with a current token writes" "1" \
    "$([ "$(cad_writes "$CHAT_ID")" -gt 0 ] && echo 1 || echo 0)"

section "every way the summarizer can decline ends at the full conversation"
omc_window_switch fallback
ui_declare_ids "$PICKER_ID"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" long
# The guard is armed with the window's REAL current token so it is a genuine no-op here. Passing
# a literal placeholder made it always mismatch, which did not show while decline-detection
# returned first - but it meant a regression in that detection would surface as rc 5 and still
# satisfy a check that only asked for "nonzero". The exact code is asserted for the same reason:
# "it failed somehow" is not what this section is about.
fallback_epoch=$(cad_hist_call resume_epoch_bump "$OMC_ACTIONUI_WINDOW_UUID")
for mode in decline empty fail; do
    cad_journal_reset
    FAKE_DIGEST_MODE="$mode" CAD_FM_OK=1 CAD_AGENT_OVERRIDE="$fake_agent" \
        cad_hist_call history_digest_inject "$OMC_ACTIONUI_WINDOW_UUID" "$CHAT_ID" long \
        "$fallback_epoch" foundation
    check "  '$mode' reports the summarizer declining, code 4" "4" "$?"
    check "  '$mode' writes nothing to the chat"               "0" "$(cad_writes "$CHAT_ID")"
done

# CLEARED EXPLICITLY, and this is not defensive clutter. `VAR=value func` persists the
# assignment when func is a SHELL FUNCTION - unlike an external command, where it applies to
# that command only. cad_hist_call is a function, so every FAKE_DIGEST_* set above stays set for
# the rest of the file. It cost a real debugging session: the summarizer kept reporting
# "unavailable" in a later section that had asked for nothing of the kind.
unset FAKE_DIGEST_MODE FAKE_DIGEST_ACCEPTED FAKE_DIGEST_DROPPED FAKE_DIGEST_LOG CAD_AGENT_OVERRIDE CAD_FM_OK

# And with no summarizer present at all - the state on a machine where the bundle was thinned.
cad_journal_reset
CAD_FM_OK=1 cad_hist_call history_digest_inject "$OMC_ACTIONUI_WINDOW_UUID" "$CHAT_ID" long \
    "$fallback_epoch" foundation
check "a missing agent binary reports the summarizer, not the length" "4" "$?"
check "  and writes nothing"                "0" "$(cad_writes "$CHAT_ID")"

section "a failed summarize says so instead of silently snapping back"
# The other half of the reported bug. Snapping the menu back to "full" is correct - it has to
# describe what the window holds - but doing it without a word is what made this feel broken.
# The handler is dispatched for real here so the alert, the stored mode and the menu reset are
# observed together rather than asserted about in isolation.
omc_window_switch failtalk
ui_declare_ids "$PICKER_ID"
# Dispatched for real, and made to fail WITHOUT stubbing anything: a conversation with no older
# half declines at the first step, before the summarizer is ever reached. That is what lets this
# section run the actual handler - a stubbed agent path is a test-lib convention that a real
# dispatch, running in its own process, would not see.
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" justshort
cad_hist_call history_set_resume_mode justshort digest
alerts_reset
cad_journal_reset
omc_control "$PICKER_ID" "foundation"
omc_run aichat.chat.summarize.mode
check "the user is told"                 "1" "$([ "$(alerts_count)" -gt 0 ] && echo 1 || echo 0)"
# And told the RIGHT thing. The cause decides the sentence: sending someone to enable Apple
# Intelligence because their conversation was short is its own bug.
check "  and told it is a length problem" "1" \
    "$([ "$(alerts_mention 'nothing to summarize')" -gt 0 ] && echo 1 || echo 0)"
check "  not sent to fix Apple Intelligence" "0" \
    "$(alerts_mention 'Apple Intelligence')"
check "the menu goes back to full"        "1" "$(cad_has "$(cad_journal "$PICKER_ID")" 'full')"
check "and the stored answer follows it"  "full" "$(cad_hist_call history_resume_mode justshort)"

# Superseded is not a failure: no alert, and the stored answer is left for the later action to
# own. Driven at the library level because it needs a guard that no longer matches.
alerts_reset
cad_hist_call history_set_resume_mode justlong digest
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" justlong
cad_pb_set "aichatv2_resume_epoch_$OMC_ACTIONUI_WINDOW_UUID" "now"
CAD_FM_OK=1 CAD_AGENT_OVERRIDE="$fake_agent" \
    cad_hist_call history_digest_inject "$OMC_ACTIONUI_WINDOW_UUID" "$CHAT_ID" justlong "earlier" foundation
check "a superseded digest reports 5, not a failure" "5" "$?"
check "  and raises no alert"                        "0" "$(alerts_count)"

section "deleting the loaded conversation stops its digest"
# Found in review, and the worst failure this feature could have. Deleting the conversation that
# is loaded is a FOURTH thing that changes what the window shows - alongside selecting a row,
# changing the menu, and New Chat - and it was the one that did not bump the token. A resume
# starts a digest on its own, it takes seconds, and the delete alert says "This cannot be
# undone": so a summary of the just-deleted conversation would appear in the cleared window and
# seed it into the model, after the user was told it was gone.
omc_window_switch deleted
ui_declare_ids "$PICKER_ID"
cad_mk_session doomed 20
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" doomed
del_epoch=$(cad_hist_call resume_epoch_bump "$OMC_ACTIONUI_WINDOW_UUID")

# Delete it through the real handler, with the row selected and the alert answered "Delete".
alert_answer 0
export OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE=doomed
cad_journal_reset
omc_run aichat.history.delete
unset OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE

check "the conversation is gone from disk" "0" \
    "$([ -d "$cad_hist/doomed" ] && echo 1 || echo 0)"
check "the window is unbound"              ""  \
    "$(cad_pb_get "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID")"
check "and the token moved on"             "1" \
    "$([ "$(cad_hist_call resume_epoch "$OMC_ACTIONUI_WINDOW_UUID")" != "$del_epoch" ] && echo 1 || echo 0)"

# The point of all of it: work carrying the pre-delete token is refused as superseded.
#
# Asserted against a conversation that still EXISTS, which is the honest way to test the token
# rather than a happy accident. A real digest reads its transcript first and injects seconds
# later, so the delete lands in the middle; replaying that here by calling the whole function
# after the delete would have it fail at the read instead (code 3, nothing to condense) and
# prove nothing about the guard at all. Same token, a readable conversation: only the token can
# stop this.
cad_journal_reset
CAD_FM_OK=1 CAD_AGENT_OVERRIDE="$fake_agent" \
    cad_hist_call history_digest_inject "$OMC_ACTIONUI_WINDOW_UUID" "$CHAT_ID" long \
    "$del_epoch" foundation
check "work carrying the pre-delete token is superseded" "5" "$?"
check "  and nothing of it reaches the window"           "0" "$(cad_writes "$CHAT_ID")"
unset CAD_FM_OK CAD_AGENT_OVERRIDE

section "the menu is removed when there is no conversation to summarize"
omc_window_switch hide
ui_declare_ids "$PICKER_ID"
cad_journal_reset
cad_hist_call summarize_hide "$OMC_ACTIONUI_WINDOW_UUID"
check "hiding removes the element" "1" "$(cad_has "$(cad_journal "$PICKER_ID")" 'omc_remove_element')"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no table clobbered by a bare value write" "" "$(ui_suspect_writes)"

omctest_end
