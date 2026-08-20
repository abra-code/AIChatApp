#!/bin/sh
# Tests/92-history.test.sh - the saved-conversation store.
#
# Two things here are worth more than the rest. The session id is interpolated straight into a
# filesystem path, so history_valid_sid is a security guard rather than a tidiness one. And the
# model label is implemented TWICE - once in shell for the picker, once in Python for the
# history rows - with a comment on each asking the reader to keep them in sync, which is the
# only kind of duplication a diff cannot police.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

# Prefixed HC_ rather than CHAT_, because one of the constants in that file is itself named
# CHAT_VIEW_ID and a CHAT_ prefix would produce CHAT_CHAT_VIEW_ID - leaving $CHAT_VIEW_ID empty
# and every write below going to view id "", which ui_unknown_writes does not flag.
cad_import_ids aichat.chat.new.sh HC_
# The facts line's id lives with the function that writes it, not with a handler.
cad_import_ids aichat.history.library.sh HL_

section "the ids this file drives are the ones the window declares"
# The guard the header argues for: an id that fails to import is empty, every write goes to view
# "", and ui_unknown_writes does not flag that - so nothing else in this file would notice.
check "the chat view and sidebar resolved" "1 510" "$HC_CHAT_VIEW_ID $HC_TABLE_ID"
check "and the facts line"                  "540"    "$HL_CHAT_INFO_TEXT_ID"

HROOT="$HOME/Library/Application Support/Cadabra/History"
hist() { cad_call_lib aichat.history.library.sh "$@"; }

# The Python half of the label rule, reached the way the guide suggests: the applet's own
# interpreter, with its Scripts directory importable, and arguments passed as argv rather than
# interpolated into the expression - the values worth testing are the ones with quotes in them.
py_label() {
    "$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3" -c '
import sys, os
sys.path.insert(0, os.path.join(os.environ["OMC_APP_BUNDLE_PATH"], "Contents", "Resources", "Scripts"))
import history_store
sys.stdout.write(history_store._model_label(sys.argv[1]))
' "$1"
}

# mk_session <sid> <meta-json|-> <journal-jsonl|->  [stamp YYYYMMDDhhmm]
mk_session() {
    d="$HROOT/$1"
    /bin/mkdir -p "$d"
    [ "$2" = "-" ] || printf '%s\n' "$2" > "$d/meta.json"
    [ "$3" = "-" ] || printf '%s\n' "$3" > "$d/journal.jsonl"
    if [ -n "$4" ]; then
        [ -f "$d/meta.json" ]     && /usr/bin/touch -t "$4" "$d/meta.json"
        [ -f "$d/journal.jsonl" ] && /usr/bin/touch -t "$4" "$d/journal.jsonl"
    fi
    return 0
}
local_msg() { printf '{"type":"message","data":{"message":{"role":"local","text":%s}}}' "$1"; }

section "a session id may not escape the history directory"
# The id is interpolated into "$history_root/$1" and then removed, renamed and read from, so
# this guard is the whole boundary. Every rejected shape below is one that reaches outside.
for bad in "" "a/b" ".." "../etc" "a/../b" ".hidden" "x..y" "./x"; do
    check "  refused: [$bad]" "1" "$(hist history_valid_sid "$bad"; echo $?)"
done
for good in "20260707T193808Z-2042" "webui-abc123" "a" "s.1"; do
    check "  allowed: [$good]" "0" "$(hist history_valid_sid "$good"; echo $?)"
done

section "the session directory refuses to name a path outside the store"
check "a valid id resolves"   "$HROOT/webui-abc123" "$(hist history_session_dir webui-abc123 2>/dev/null)"
check "a traversal fails"     "1"  "$(hist history_session_dir "../../etc" >/dev/null 2>&1; echo $?)"
# Nothing on stdout, because the caller assigns this to a variable and then writes to it. A
# guard that reports failure but still prints a path is a guard the next line ignores.
check "  and prints no path"  ""   "$(hist history_session_dir "../../etc" 2>/dev/null)"

section "the two model-label implementations agree"
# One in aichat.model.library.sh for the picker, one in history_store.py for the rows. They
# are asked the same questions here, including the two the comments call load-bearing.
for p in \
    "foundation:apple-on-device" \
    "/models/Qwen3-4B-Q5_K_S.gguf" \
    "/cache/models--mlx-community--Llama-3.2-3B-Instruct-4bit/snapshots/abc123" \
    "/cache/models--bartowski--Llama-3.2-3B-Instruct/snapshots/deadbeef/Llama-Q4_K_M.gguf" \
    "/opt/plain-dir" \
    "/models/with space/Model-Q8_0.gguf"; do
    check "  $p" "$(cad_call_lib aichat.model.library.sh model_display_label "$p")" "$(py_label "$p")"
done

section "the sidebar lists sessions, most recently touched first"
/bin/rm -rf "$HROOT"
mk_session oldest '{"id":"oldest","title":"Oldest chat"}' - 202601010900
mk_session middle - "$(local_msg '"How do I write a test?"')" 202603010900
mk_session newest '{"id":"newest","title":"Newest chat"}' - 202606010900
check "three sessions are listed" "3" "$(hist history_index | /usr/bin/grep -c .)"
check "the newest is first"  "Newest chat	newest" "$(hist history_index | /usr/bin/sed -n 1p)"
check "then the middle one"  "How do I write a test?	middle" "$(hist history_index | /usr/bin/sed -n 2p)"
check "and the oldest last"  "Oldest chat	oldest" "$(hist history_index | /usr/bin/sed -n 3p)"

section "a title comes from meta, else the first thing the user said"
check "meta wins"                "Newest chat" "$(hist history_title newest)"
check "else the first local line" "How do I write a test?" "$(hist history_title middle)"
mk_session silent '{"id":"silent"}' '{"type":"message","data":{"message":{"role":"agent","text":"hi"}}}'
check "a conversation the user never spoke in" "(untitled)" "$(hist history_title silent)"
mk_session blank '{"id":"blank"}' -
check "and one with nothing in it at all"      "(untitled)" "$(hist history_title blank)"

section "a title is squeezed onto one line and cut to fit"
mk_session messy '{"id":"messy","title":"  lots   of\n  space  "}' -
check "whitespace collapses" "lots of space" "$(hist history_title messy)"
long=$(/usr/bin/awk 'BEGIN{for(i=0;i<20;i++) printf "abcde "}')
mk_session verylong "$(printf '{"id":"verylong","title":"%s"}' "$long")" -
title=$(hist history_title verylong)
# 60 characters, the last of which is a horizontal ellipsis - written here as its UTF-8 bytes
# so this file stays ASCII.
check "an over-long title is cut" "60" \
    "$(printf '%s' "$title" | /usr/bin/python3 -c 'import sys; sys.stdout.write(str(len(sys.stdin.read())))')"
check "  and marked as cut"       "1" \
    "$(cad_has "$title" "$(printf '\342\200\246')")"

section "a directory that is not a session is not listed"
/bin/mkdir -p "$HROOT/not-a-session"
check "no journal and no meta means not a session" "0" \
    "$(hist history_index | /usr/bin/awk -F'\t' '$2 == "not-a-session"' | /usr/bin/grep -c .)"

section "a tab in a title cannot shift the hidden column"
# The rows go to omc_table_set_rows_from_stdin as TSV with the session id riding in the hidden
# trailing field, so a tab anywhere in the title would move the id into the visible column and
# hand the button handlers a fragment of a sentence to delete.
/bin/rm -rf "$HROOT"
mk_session tabbed "$(printf '{"id":"tabbed","title":"before\\tafter"}')" - 202606010900
check "the row still has two fields" "2" \
    "$(hist history_index | /usr/bin/head -1 | /usr/bin/awk -F'\t' '{print NF}')"
check "  and the id is intact"       "tabbed" \
    "$(hist history_index | /usr/bin/head -1 | /usr/bin/cut -f2)"

section "the sidebar table is repainted, not appended to"
/bin/rm -rf "$HROOT"
mk_session one '{"id":"one","title":"First"}'  - 202601010900
mk_session two '{"id":"two","title":"Second"}' - 202602010900
ui_reset
hist history_populate_table "$OMC_ACTIONUI_WINDOW_UUID" "$HC_TABLE_ID"
check "both sessions are rows" "2" "$(ui_row_count "$HC_TABLE_ID")"
hist history_populate_table "$OMC_ACTIONUI_WINDOW_UUID" "$HC_TABLE_ID"
check "refilling does not duplicate them" "2" "$(ui_row_count "$HC_TABLE_ID")"
/bin/rm -rf "$HROOT/two"
hist history_populate_table "$OMC_ACTIONUI_WINDOW_UUID" "$HC_TABLE_ID"
check "a deleted session leaves the list" "1" "$(ui_row_count "$HC_TABLE_ID")"
/bin/rm -rf "$HROOT"
ui_reset
hist history_populate_table "$OMC_ACTIONUI_WINDOW_UUID" "$HC_TABLE_ID"
check "an empty store leaves an empty list" "0" "$(ui_row_count "$HC_TABLE_ID")"

section "a new session's metadata"
d="$HROOT/fresh"
/bin/mkdir -p "$d"
hist history_init_meta "$d" fresh "/models/Qwen3-4B-Q5_K_S.gguf"
check_exists "meta.json was written" "$d/meta.json"
# Written through a temp file and renamed, so a concurrent index scan never reads a torn one.
check_absent "  and no temp file is left" "$d/meta.json.tmp"
check "it records the id"        "fresh" "$(hist history_meta_field fresh id)"
check "the model path"           "/models/Qwen3-4B-Q5_K_S.gguf" "$(hist history_meta_field fresh modelPath)"
check "and the label beside it"  "Qwen3-4B-Q5_K_S" "$(hist history_meta_field fresh model)"
check "it is a native session"   "native" "$(hist history_meta_field fresh source)"
check "with no agent"            ""       "$(hist history_meta_field fresh agent)"

section "an external agent's session records the agent, not a model"
d="$HROOT/ext"
/bin/mkdir -p "$d"
hist history_init_meta "$d" ext "" 'Claude "Code"'
check "the agent is recorded"  'Claude "Code"' "$(hist history_meta_field ext agent)"
check "and no model path is"   ""  "$(hist history_meta_field ext modelPath)"
# json.dumps, not string concatenation: a label with a quote in it would otherwise produce a
# meta.json that never parses again, and every field would silently read empty from then on.
check "the file still parses"  "ext" "$(hist history_meta_field ext id)"

section "a missing field reads empty rather than failing"
check "an absent key"       "" "$(hist history_meta_field fresh nosuchkey)"
mk_session broken 'this is not json' -
check "an unparseable meta" "" "$(hist history_meta_field broken id)"

section "the facts line says when a conversation started and how much was said"
/bin/rm -rf "$HROOT"
mk_session chat1 '{"id":"chat1","created":"2026-05-04T10:11:12Z","modelPath":"/m/Tiny-Q4_K_M.gguf","model":"Tiny-Q4_K_M"}' \
    "$(local_msg '"one"')"
line=$(hist history_info_line chat1)
check "it says when"         "1" "$(cad_has "$line" "Started: 2026-05-04 10:11:12")"
check "and how many messages" "1" "$(cad_has "$line" "Messages: 1")"
# NOT the model, even though the session records one. It sits immediately right of the model
# bar's button, which names the model this window is talking to NOW - and two model names in
# one row is a question rather than an answer. Which model started the conversation is in the
# transcript's opening session marker, where a switch since is also recorded.
check "but not the model"    "0" "$(cad_has "$line" "Tiny-Q4_K_M")"

section "and it is stated for whatever the window is showing"
ui_reset
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" chat1
hist chat_info_refresh "$OMC_ACTIONUI_WINDOW_UUID"
check "a bound conversation" "1" "$(cad_has "$(ui_value "$HL_CHAT_INFO_TEXT_ID")" "Messages: 1")"
ui_reset
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" ""
hist chat_info_refresh "$OMC_ACTIONUI_WINDOW_UUID"
check "an unbound window"    "New conversation" "$(ui_value "$HL_CHAT_INFO_TEXT_ID")"
ui_reset
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" nosuchsession
hist chat_info_refresh "$OMC_ACTIONUI_WINDOW_UUID"
check "  and one bound to a session that is gone" "New conversation" "$(ui_value "$HL_CHAT_INFO_TEXT_ID")"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" ""

section "restoring a conversation into the chat"
ui_reset
check "a saved session injects" "0" \
    "$(hist history_inject_content "$OMC_ACTIONUI_WINDOW_UUID" "$HC_CHAT_VIEW_ID" chat1; echo $?)"
check "  as chat content" "1" "$(ui_calls omc_set_state)"
content=$(ui_state "$HC_CHAT_VIEW_ID" content)
check "  carrying the conversation" "1" "$(cad_has "$content" '"items"')"

section "the restore directive rides along without being invented"
ui_reset
hist history_inject_content "$OMC_ACTIONUI_WINDOW_UUID" "$HC_CHAT_VIEW_ID" chat1 defer
check "defer is passed through" "1" \
    "$(cad_has "$(ui_state "$HC_CHAT_VIEW_ID" content)" '"prime": "defer"')"
ui_reset
hist history_inject_content "$OMC_ACTIONUI_WINDOW_UUID" "$HC_CHAT_VIEW_ID" chat1
check "and omitted when not asked for" "0" \
    "$(cad_has "$(ui_state "$HC_CHAT_VIEW_ID" content)" '"prime"')"

section "an invalid session id injects nothing"
ui_reset
check "it reports failure" "1" \
    "$(hist history_inject_content "$OMC_ACTIONUI_WINDOW_UUID" "$HC_CHAT_VIEW_ID" "../../etc" 2>/dev/null; echo $?)"
check "  and wrote nothing to the chat" "0" "$(cad_writes "$HC_CHAT_VIEW_ID")"

section "cumulative: no handler wrote to a view id the window does not declare"
# Cumulative across the whole file, which is what makes one check at the end meaningful.
# It was not always: ui_reset used to DELETE unknown_ids.log along with the windows, so this
# covered only what happened since the last reset - close to nothing in a file that resets per
section "the journal survives concurrent writers, and only content mints a session"
# THE FAILURE THIS PREVENTS IS SILENT AND PERMANENT. `printf >>` flushes in ~1 KB stdio chunks, so
# a large envelope is several write() calls; a second handler landing between two of them splices
# the tail of one line onto the head of another, and _read_journal can only skip what it cannot
# parse. Two of this user's saved conversations lost a message that way.
H_PY="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
H_STORE="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/history_store.py"
mk_session concurrent - - ; : > "$HROOT/concurrent/journal.jsonl"
pad=$("$H_PY" -c 'import sys; sys.stdout.write("X" * 3000)')
for w in A B C; do
    (   i=0
        while [ "$i" -lt 30 ]; do
            hist history_append_journal "$HROOT/concurrent" \
                "{\"type\":\"message\",\"w\":\"$w\",\"n\":$i,\"pad\":\"$pad\"}"
            i=$((i + 1))
        done ) &
done
wait
check "every line written concurrently is still parseable" "90 0" \
    "$("$H_PY" -c '
import json, sys
tot = bad = 0
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line: continue
    tot += 1
    try: json.loads(line)
    except Exception: bad += 1
sys.stdout.write("%d %d" % (tot, bad))' "$HROOT/concurrent/journal.jsonl")"
check "  and the lock is not left behind" "0" \
    "$([ -e "$HROOT/concurrent/.journal.lock" ] && echo 1 || echo 0)"

# The agent announces itself with a `session` envelope that finalizes like any other entry. Minting
# on it left a directory holding an announcement and no conversation - 21 of 183 real sessions.
hist history_envelope_mints '{"type":"session","data":{"agentName":"mlx-agent"}}'
check "an agent announcement does not mint a session" "1" "$?"
hist history_envelope_mints '{"type":"usage","data":{"used":729}}'
check "  nor does a usage update"                     "1" "$?"
hist history_envelope_mints '{"type":"sessionEvent","data":{"type":"sessionEvent"}}'
check "  nor does a session marker"                   "1" "$?"
hist history_envelope_mints '{"type":"message","data":{"message":{"role":"local","text":"hi"}}}'
check "a message does"                                "0" "$?"
hist history_envelope_mints 'not json at all'
check "  and unparseable input mints nothing"         "1" "$?"

section "ChatView's own sessionEvent entry is rewrapped so the transcript still decodes"
# ChatStore.swift hands fireEntry the bare SessionEvent instead of ChatItem.sessionEvent(event), so
# its condense marker arrives with the payload directly in `data`, with no `type` discriminator.
# Stored verbatim that is an item ChatItem's decoder throws on, and ChatTranscript decodes its items
# as one array: the WHOLE conversation fails to restore, silently, because the host does `try?`.
mk_session elementshape - '{"type":"message","id":"m1","data":{"type":"message","message":{"id":"m1","role":"local","text":"hi"}}}
{"type":"sessionEvent","id":"c1","sequence":16,"data":{"id":"c1","kind":"resumed","timestamp":"2026-08-18T21:56:33Z","digest":{"decisions":[],"establishedFacts":[],"openThreads":[],"userPreferences":[],"droppedTurns":4,"summarizer":"apple-foundation-models"}}}'
el_item() { "$H_PY" -c '
import json, sys
d = json.load(sys.stdin)
ev = [i for i in d["items"] if i.get("type") == "sessionEvent"]
sys.stdout.write(json.dumps(ev[0], sort_keys=True) if ev else "MISSING")
'; }
el_json=$("$H_PY" "$H_STORE" transcript "$HROOT/elementshape" | el_item)
check "the marker carries the type discriminator" "1" "$(cad_has "$el_json" '"type": "sessionEvent"')"
check "  with the payload under sessionEvent"     "1" "$(cad_has "$el_json" '"sessionEvent":')"
check "  and its digest intact"                   "1" "$(cad_has "$el_json" '"droppedTurns": 4')"
# No item may reach the element without a type: an untyped one is what throws, and one throw
# takes the whole conversation with it.
untyped_count() { "$H_PY" -c '
import json, sys
d = json.load(sys.stdin)
sys.stdout.write(str(sum(1 for i in d["items"] if "type" not in i)))
'; }
check "no item in the transcript is untyped" "0" \
    "$("$H_PY" "$H_STORE" transcript "$HROOT/elementshape" | untyped_count)"

# section, and a handler scribbling on a made-up view id went entirely unnoticed. omctest API 4
# carries the three diagnostic logs across a reset, and this lib asserts that minimum.
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no table clobbered by a bare value write" "" "$(ui_suspect_writes)"

omctest_end
