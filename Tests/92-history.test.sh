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

section "the ids this file drives are the ones the window declares"
# The guard the header argues for: an id that fails to import is empty, every write goes to view
# "", and ui_unknown_writes does not flag that - so nothing else in this file would notice.
check "the chat view and sidebar resolved" "1 510" "$HC_CHAT_VIEW_ID $HC_TABLE_ID"

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
cad_ui_reset
hist history_populate_table "$OMC_ACTIONUI_WINDOW_UUID" "$HC_TABLE_ID"
check "both sessions are rows" "2" "$(ui_row_count "$HC_TABLE_ID")"
hist history_populate_table "$OMC_ACTIONUI_WINDOW_UUID" "$HC_TABLE_ID"
check "refilling does not duplicate them" "2" "$(ui_row_count "$HC_TABLE_ID")"
/bin/rm -rf "$HROOT/two"
hist history_populate_table "$OMC_ACTIONUI_WINDOW_UUID" "$HC_TABLE_ID"
check "a deleted session leaves the list" "1" "$(ui_row_count "$HC_TABLE_ID")"
/bin/rm -rf "$HROOT"
cad_ui_reset
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

section "the info line names the model, when to start and how much was said"
/bin/rm -rf "$HROOT"
mk_session chat1 '{"id":"chat1","created":"2026-05-04T10:11:12Z","modelPath":"/m/Tiny-Q4_K_M.gguf","model":"Tiny-Q4_K_M"}' \
    "$(local_msg '"one"')"
line=$(hist history_info_line chat1)
check "it names the model"   "1" "$(cad_has "$line" "Model: Tiny-Q4_K_M")"
check "it says when"         "1" "$(cad_has "$line" "Started: 2026-05-04 10:11:12")"
check "and how many messages" "1" "$(cad_has "$line" "Messages: 1")"

section "restoring a conversation into the chat"
cad_ui_reset
check "a saved session injects" "0" \
    "$(hist history_inject_content "$OMC_ACTIONUI_WINDOW_UUID" "$HC_CHAT_VIEW_ID" chat1; echo $?)"
check "  as chat content" "1" "$(ui_calls omc_set_state)"
content=$(ui_state "$HC_CHAT_VIEW_ID" content)
check "  carrying the conversation" "1" "$(cad_has "$content" '"items"')"

section "the restore directive rides along without being invented"
cad_ui_reset
hist history_inject_content "$OMC_ACTIONUI_WINDOW_UUID" "$HC_CHAT_VIEW_ID" chat1 defer
check "defer is passed through" "1" \
    "$(cad_has "$(ui_state "$HC_CHAT_VIEW_ID" content)" '"prime": "defer"')"
cad_ui_reset
hist history_inject_content "$OMC_ACTIONUI_WINDOW_UUID" "$HC_CHAT_VIEW_ID" chat1
check "and omitted when not asked for" "0" \
    "$(cad_has "$(ui_state "$HC_CHAT_VIEW_ID" content)" '"prime"')"

section "an invalid session id injects nothing"
cad_ui_reset
check "it reports failure" "1" \
    "$(hist history_inject_content "$OMC_ACTIONUI_WINDOW_UUID" "$HC_CHAT_VIEW_ID" "../../etc" 2>/dev/null; echo $?)"
check "  and wrote nothing to the chat" "0" "$(cad_writes "$HC_CHAT_VIEW_ID")"

section "cumulative: no handler wrote to a view id the window does not declare"
# cad_unknown_writes_all, not ui_unknown_writes: ui_reset DELETES unknown_ids.log along with
# the windows, so the plain form covers only what happened since the last reset - which in a
# file that resets per section is close to nothing. Measured: a handler scribbling on a
# made-up view id went entirely unnoticed by the plain form.
check "no undeclared ids" "" "$(cad_unknown_writes_all)"
check "no table clobbered by a bare value write" "" "$(cad_suspect_writes_all)"

omctest_end
