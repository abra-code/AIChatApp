# Tests/lib.test.cadabra.sh - Cadabra's accessors for omctest.
#
# Sourced by every test file, immediately after omctest.sh itself.
#
# API 3 IS A HARD REQUIREMENT HERE, AND IT IS A SAFETY ONE. Cadabra keeps its entire
# configuration in one file under $HOME:
#
#     aichat.library.sh:  mcp_app_support="$HOME/Library/Application Support/Cadabra"
#                         cadabra_settings="$mcp_app_support/settings.plist"
#
# and plister is deliberately NOT stubbed by the harness, because the handlers depend on its
# exact read/write semantics. So on a harness that does not isolate $HOME - anything older than
# API 3 - a test that adds an agent writes the real configuration of whoever is running the
# suite, and cad_reset below deletes it. Nothing would warn: the tests would pass, in exactly
# the way that matters least. Refusing to run is the only correct response to that.
if [ "${OMCTEST_API_VERSION:-0}" -lt 3 ]; then
    printf 'lib.test.cadabra: needs omctest API 3 (isolated $HOME) - refusing to run against the real settings\n' >&2
    exit 1
fi

# Belt and braces. The version check above is a claim; this is the fact. It costs one string
# comparison and the thing it prevents is deleting the user's own configuration, so it stays
# even though it should be impossible to trip.
case "$HOME" in
    "$OMCTEST_SCRATCH"/*) ;;
    *)  printf 'lib.test.cadabra: HOME is %s, which is not inside the test scratch - refusing to run\n' "$HOME" >&2
        exit 1 ;;
esac

# The settings file every assertion is ultimately about. Recomputed here the way the applet
# computes it - interpolating $HOME rather than hardcoding - so that moving it in the applet
# shows up as a failing test rather than as a test asserting about a file nobody writes.
cad_settings="$HOME/Library/Application Support/Cadabra/settings.plist"

# The view ids, IMPORTED from the applet rather than restated. A second list here is a list
# that can disagree with the first, and the disagreement is silent: omc_control would write a
# perfectly valid variable for a view the window does not have.
eval "$(/usr/bin/sed -n 's/^\([A-Z][A-Z0-9_]*_ID\)=\([0-9][0-9]*\)$/\1=\2/p' \
    "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.select.external.agent.library.sh")"
[ -n "$TABLE_ID" ] && [ -n "$PANE_OWNER_ID" ] || {
    printf 'lib.test.cadabra: no view ids imported from aichat.select.external.agent.library.sh\n' >&2
    exit 1
}

# cad_plister - the real plister, from the same interposition directory the handlers reach it
# through. Not stubbed by the harness on purpose, so the tests read back exactly what the
# handlers wrote, byte for byte, through the same implementation.
cad_plister="$OMC_OMC_SUPPORT_PATH/plister"

# cad_get <pseudopath>  ->  a string value from the settings file, or nothing.
# Reads only. A missing file, a missing key and an empty value are all empty here, which is
# what most assertions want; when the difference matters, use cad_type.
cad_get() {
    "$cad_plister" get string "$cad_settings" "$1" 2>/dev/null
}

# cad_type <pseudopath>  ->  the value's type, or nothing when the key does not exist.
# This is how a test tells "the key is absent" from "the key holds an empty string" - a
# distinction that matters here, because a saved agent with no command yet is a real state.
cad_type() {
    "$cad_plister" get type "$cad_settings" "$1" 2>/dev/null
}

# cad_reset - back to a profile that has never opened Cadabra.
# The whole configuration is one file, so this is genuinely complete: there is no per-window
# pasteboard key or state directory for the agent dialog to leave behind.
cad_reset() {
    /bin/rm -f "$cad_settings"
}

# cad_call <function> [args...] - call one of the applet's own library functions directly.
#
# Whole-handler dispatches are coarse, and the rules worth testing here live in named
# functions: what counts as a runnable command, what a row looks like, how a label is cleaned.
# The subshell keeps the library's globals out of the test file and stops a function that
# exits from taking the whole file with it.
cad_call() {
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh" >/dev/null 2>&1
      "$@" )
}

# cad_row <agent-id>  ->  that agent's row from the list, tab-separated, or nothing.
#
# The rows carry FOUR values against TWO drawn columns: label, status glyph, command, id.
# Columns 3 and 4 are hidden and are what the sibling handlers read back as
# OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE / _4_VALUE, so a test that picks a row by its id is
# also asserting that the hidden columns are still where the handlers expect them.
cad_row() {
    ui_rows "$TABLE_ID" | /usr/bin/awk -F'\t' -v want="$1" '$4 == want { print; exit }'
}

# cad_field <agent-id> <column>  ->  one column of that row. 1 label, 2 status, 3 command, 4 id.
cad_field() {
    cad_row "$1" | /usr/bin/cut -f"$2"
}

# cad_journal <view-id>  ->  every value written to that view, in order, one line per call.
#
# ui_value answers "what does the control hold now", which is the right question most of the
# time and the wrong one for this dialog. The pane-owner protocol is about ORDER - the owner is
# cleared before a repaint and set after it - and about whether a handler wrote a field AT ALL.
# The virtual window cannot answer either: a value written twice looks like a value written
# once, and a field left alone looks exactly like a field rewritten with what it already held.
#
# The journal can, because it records every call in order. Its lines are
# <uuid> TAB <target> TAB <args, tab-joined, tabs and newlines flattened to spaces>.
cad_journal() {
    /usr/bin/awk -F'\t' -v t="$1" '$2 == t { sub(/ $/, "", $3); print $3 }' "$OMCTEST_UI/journal.tsv"
}

# cad_writes <view-id>  ->  how many calls were made against that view.
#
# The counting form, for "this handler must not touch that control". Counting rather than
# reading matters when the value written is the empty string, which is a real instruction here
# (clearing the pane owner) and which command substitution would otherwise swallow.
cad_writes() {
    /usr/bin/awk -F'\t' -v t="$1" '$2 == t { n++ } END { print n + 0 }' "$OMCTEST_UI/journal.tsv"
}

# cad_journal_reset - forget every recorded call, keeping the virtual window intact.
#
# ui_reset would wipe the window too, taking the table rows with it - and the rows are what the
# next section usually asserts against. Sections that count calls start from a clean journal
# instead, the way alerts_reset works for alerts.
cad_journal_reset() {
    : > "$OMCTEST_UI/journal.tsv"
}

# cad_lib_glyphs  ->  the three status glyphs the applet currently ships, space separated.
#
# For the drift guard ONLY. The assertions state the glyphs as literals, because a test that
# sources them from the code it is testing passes just as happily with the mapping inverted.
# But that independence costs a wall of unexplained failures the moment someone picks a
# different glyph, so one check compares the two and says it once.
cad_lib_glyphs() {
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh" >/dev/null 2>&1
      printf '%s %s %s' "$ACP_STATUS_READY" "$ACP_STATUS_MISSING" "$ACP_STATUS_UNKNOWN" )
}

# cad_fake_agent  ->  the path of the fake ACP agent in Tests/helpers.
#
# A real agent would mean depending on one being installed, on a network and on credentials,
# so a green Test result would mean different things on different machines. This one answers
# initialize and session/new identically every time, which is what lets a test assert on the
# PROBE'S OUTPUT rather than on whether some third-party binary happens to be present.
cad_fake_agent() {
    printf '%s\n' "$OMCTEST_TESTS/helpers/fake_acp_agent.py"
}
