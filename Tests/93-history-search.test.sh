#!/bin/sh
# Tests/93-history-search.test.sh - search across saved conversations.
#
# The sidebar's search field asks WHICH conversations mention a term; the Chat element's own find
# then shows WHERE, with the same term. This file covers the first half: history_store.py search
# ranks conversations by how often they mention the term, follows the element's rules for what
# counts (message bodies and captions by default, thoughts and tool calls only on request, deleted
# messages never), and hands the sidebar rows in exactly the shape `index` does - so the one
# populate helper serves both, and a filter survives a rename or delete repopulating the list.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

cad_import_ids aichat.chat.new.sh HC_

HROOT="$HOME/Library/Application Support/Cadabra/History"
hist() { cad_call_lib aichat.history.library.sh "$@"; }

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
msg() { printf '{"type":"message","id":"%s","data":{"type":"message","message":{"id":"%s","role":"%s","text":%s}}}' "$1" "$1" "$2" "$3"; }
deleted_msg() { printf '{"type":"message","id":"%s","data":{"type":"message","message":{"id":"%s","role":"agent","text":%s,"deleted":true}}}' "$1" "$1" "$2"; }
thought() { printf '{"type":"thought","id":"%s","data":{"type":"thought","thought":{"id":"%s","role":"agent","text":%s}}}' "$1" "$1" "$2"; }
tool() { printf '{"type":"toolCall","id":"%s","data":{"type":"toolCall","toolCall":{"id":"%s","title":%s,"kind":"search","status":"completed","contentText":%s}}}' "$1" "$1" "$2" "$3"; }

/bin/rm -rf "$HROOT"
# "loud" mentions the term four times in what a reader sees (a user-given title counts, a derived
# one does not - it is the first message, counted once already), plus three more in a thought and
# two in a tool card; "quiet" once; "silent" only in a deleted message; "unrelated" never.
mk_session loud '{"id":"loud","title":"Fox talk"}' "$(msg m1 local '"the quick brown fox"')
$(msg m2 agent '"A fox again and a FOX"')
$(thought t1 '"fox fox fox"')
$(tool c1 '"fox search"' '"fox"')" 202601010900
mk_session quiet - "$(msg q1 local '"one fox, late"')" 202606010900
mk_session silent - "$(msg s1 local '"hello"')
$(deleted_msg s2 '"fox"')" 202603010900
mk_session unrelated - "$(msg u1 local '"nothing here"')" 202605010900

section "search lists the conversations that mention the term, most mentions first"
check "two conversations match"      "2"              "$(hist history_search fox | /usr/bin/grep -c .)"
check "the loud one first"           "Fox talk	loud"     "$(hist history_search fox | /usr/bin/sed -n 1p)"
check "the quiet one second"         "one fox, late	quiet" "$(hist history_search fox | /usr/bin/sed -n 2p)"
check "case does not matter"         "2"              "$(hist history_search FOX | /usr/bin/grep -c .)"
check "nor does surrounding space"   "2"              "$(hist history_search '  fox ' | /usr/bin/grep -c .)"

section "what counts follows the element's own find"
check "a deleted message does not"   "0"  "$(hist history_search fox | /usr/bin/grep -c 'silent')"
check "an unrelated conversation does not" "0" "$(hist history_search fox | /usr/bin/grep -c 'unrelated')"
# Thoughts and tool calls are out of the default scope, in the "all" one: "quiet" mentions the term
# once either way, "loud" gains five, and the order holds.
check "the all scope keeps the order" "Fox talk	loud" "$(hist history_search fox all | /usr/bin/sed -n 1p)"
check "  and the count"               "2"                "$(hist history_search fox all | /usr/bin/grep -c .)"

section "an empty term lists nothing, so the caller shows the whole index instead"
check "empty"      "0" "$(hist history_search '' | /usr/bin/grep -c .)"
check "whitespace" "0" "$(hist history_search '   ' | /usr/bin/grep -c .)"

section "the shapes a typed term can take"
mk_session numeric - "$(msg n1 local '"call 2026 now"')"
mk_session dashed - "$(msg d1 local '"a -n flag"')"
mk_session tabbed - "$(msg t1 local '"a\ttab"')"
check "a number"           "call 2026 now	numeric" "$(hist history_search 2026)"
check "a leading dash"     "a -n flag	dashed"      "$(hist history_search -n)"
check "a double dash"      "0"                     "$(hist history_search -- | /usr/bin/grep -c .)"
check "a tab inside"       "1"                     "$(hist history_search "$(printf 'a\tt')" | /usr/bin/grep -c .)"
check "a glob"             "0"                     "$(hist history_search '*' | /usr/bin/grep -c .)"
mk_session broken - '{"type":"message","id":"b1","data":{"type":"message","message":{"id":"b1","role":"local","text":123}}}'
check "a malformed journal line does not take the list down" "1" "$(hist history_search 2026 2>/dev/null | /usr/bin/grep -c .)"
check "the term travels as a JSON string" '"2026"' "$(hist history_search_json 2026)"
check "  quotes and all"                 '"say \"hi\""' "$(hist history_search_json 'say "hi"')"
/bin/rm -rf "$HROOT/numeric" "$HROOT/dashed" "$HROOT/tabbed" "$HROOT/broken"

section "the rows have the index's shape, so one populate helper serves both"
check "title, tab, session id" "one fox, late	quiet" "$(hist history_search late)"
check "a sidebar with no term shows the index" "4" "$(hist history_index | /usr/bin/grep -c .)"

section "the term is remembered per window and drives which rows the sidebar gets"
check "the prefix is the one under test" "aichatv2_search_" "$(cad_lib_var CAD_SEARCH_PREFIX aichat.history.library.sh)"
cad_pb_set "aichatv2_search_WIN-A" "fox"
check "the window's term is read back" "fox" "$(hist history_search_query WIN-A)"
check "another window has none"        ""    "$(hist history_search_query WIN-B)"
cad_pb_set "aichatv2_search_WIN-A" ""
ui_reset
cad_pb_set "aichatv2_search_$OMC_ACTIONUI_WINDOW_UUID" ""
hist history_populate_table "$OMC_ACTIONUI_WINDOW_UUID" "$HC_TABLE_ID"
check "no term: the sidebar shows every conversation" "4" "$(ui_row_count "$HC_TABLE_ID")"
cad_pb_set "aichatv2_search_$OMC_ACTIONUI_WINDOW_UUID" "fox"
hist history_populate_table "$OMC_ACTIONUI_WINDOW_UUID" "$HC_TABLE_ID"
check "a term: only the ones that mention it"       "2" "$(ui_row_count "$HC_TABLE_ID")"
cad_pb_set "aichatv2_search_$OMC_ACTIONUI_WINDOW_UUID" ""
hist history_populate_table "$OMC_ACTIONUI_WINDOW_UUID" "$HC_TABLE_ID"
check "cleared: every conversation again"           "4" "$(ui_row_count "$HC_TABLE_ID")"

section "the handler: the field's text becomes the window's term and the sidebar follows"
ui_reset
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" ""
OMC_ACTIONUI_TRIGGER_CONTEXT="  fox " omc_run aichat.history.search
check "the term is trimmed and remembered" "fox" "$(hist history_search_query "$OMC_ACTIONUI_WINDOW_UUID")"
check "the sidebar is filtered"            "2"   "$(ui_row_count "$HC_TABLE_ID")"
check "no conversation open: the chat element is left alone" "0" "$(cad_writes "$HC_CHAT_VIEW_ID")"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" "loud"
cad_journal_reset
OMC_ACTIONUI_TRIGGER_CONTEXT="fox" omc_run aichat.history.search
check "a conversation open: its find gets the term" "1" "$(cad_has "$(cad_journal "$HC_CHAT_VIEW_ID")" '"fox"')"
OMC_ACTIONUI_TRIGGER_CONTEXT="" omc_run aichat.history.search
check "cleared: the whole list is back"    "4"   "$(ui_row_count "$HC_TABLE_ID")"
check "  and the term is gone"             ""    "$(hist history_search_query "$OMC_ACTIONUI_WINDOW_UUID")"
cad_pb_set "aichatv2_session_$OMC_ACTIONUI_WINDOW_UUID" ""

section "the store refuses a scope it does not know"
py="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
store="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/history_store.py"
check "bogus scope exits 2" "2" "$("$py" "$store" search "$HROOT" fox bogus >/dev/null 2>&1; echo $?)"
check "a limit caps the rows" "1" "$("$py" "$store" search "$HROOT" fox messages 1 | /usr/bin/grep -c .)"
check "a negative limit is refused" "2" "$("$py" "$store" search "$HROOT" fox messages -1 >/dev/null 2>&1; echo $?)"

/bin/rm -rf "$HROOT"

omctest_end
