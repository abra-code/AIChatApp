#!/bin/sh
# Tests/40-acp-agent-status.test.sh - what the list says about each agent, and what it takes
# to be called runnable in the first place.
#
# Two halves of one question. The status column is a single glyph in a 20pt column with the
# headers hidden, so it is the only thing in the row that answers "will this start" - and it is
# computed from acp_agent_which, which is where the answer is decided.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

# The glyphs are stated here as literals rather than read from the applet, because a test that
# sources the values it is testing passes just as happily with the mapping inverted. The drift
# guard below is what keeps that independence from turning into a wall of unexplained failures
# the first time somebody picks a different glyph.
READY="✅"
MISSING="➖"
UNKNOWN="•••"

section "the harness and the applet agree on which glyph means what"
check "the three glyphs are the ones under test" "$READY $MISSING $UNKNOWN" "$(cad_lib_glyphs)"

section "one glyph per state, and only three of them exist"
cad_reset
g_ready=$(cad_call acp_custom_add "Resolvable"    "/bin/echo acp")
g_missing=$(cad_call acp_custom_add "Nonexistent" "/opt/nowhere/agent acp")
g_empty=$(cad_call acp_custom_add "Nothing typed" "")
omc_run aichat.select.external.agent.init
check_status "init ran" 0
check "a resolvable command is the ready glyph"   "$READY"   "$(cad_field "$g_ready" 2)"
check "an unresolvable one is the missing glyph"  "$MISSING" "$(cad_field "$g_missing" 2)"
check "no command at all is the unknown glyph"    "$UNKNOWN" "$(cad_field "$g_empty" 2)"
# Every OTHER row too, catalog included: a fourth state leaking in would show up here and
# nowhere else, because nothing reads this column back.
check "no row carries anything but those three" "" \
    "$(ui_rows "$TABLE_ID" | /usr/bin/cut -f2 | /usr/bin/grep -v "^$READY$" | /usr/bin/grep -v "^$MISSING$" | /usr/bin/grep -v "^$UNKNOWN$")"
# And no WORD can leak back in, which is what this column used to hold. A letter or a space in
# a status cell means "Ready", "Not found" or "Not set" has returned - the marker itself is
# punctuation and emoji only, whichever three are chosen. Written in python rather than awk
# because /usr/bin/awk counts BYTES unless the build and the locale both agree on UTF-8, and
# every one of these markers is multi-byte.
check "no status cell contains a word" "" \
    "$(ui_rows "$TABLE_ID" | /usr/bin/cut -f2 | /usr/bin/python3 -c 'import sys
for line in sys.stdin:
    cell = line.rstrip("\n")
    if any(c.isalnum() or c == " " for c in cell):
        print(cell)')"
check "the hidden columns did not shift" "/bin/echo acp	$g_ready" "$(cad_row "$g_ready" | /usr/bin/cut -f3,4)"

section "a directory is not an agent"
# -x is TRUE for a directory - the execute bit there means "searchable", not "runnable" - so
# every branch of acp_agent_which used to resolve "/" and the list drew the ready glyph beside
# a path that cannot be started. The failure surfaced later, in the chat window.
W="$OMCTEST_WORK/whichcases"
/bin/mkdir -p "$W/adir" "$HOME/.faketool/bin/subdir" "$W/pathdir"
printf '#!/bin/sh\necho hi\n' > "$W/runme";  /bin/chmod 755 "$W/runme"
printf '#!/bin/sh\necho hi\n' > "$W/noexec"; /bin/chmod 644 "$W/noexec"
/bin/ln -sf "$W/runme" "$W/link-to-exec"
/bin/ln -sf "$W/adir"  "$W/link-to-dir"
/bin/ln -sf "$W/gone"  "$W/dangling"
runnable() { cad_call acp_agent_which "$1" >/dev/null 2>&1 && echo yes || echo no; }
check "/ is not an agent"                       "no"  "$(runnable /)"
check "/usr is not an agent"                    "no"  "$(runnable /usr)"
check "a plain directory is not an agent"       "no"  "$(runnable "$W/adir")"
check "a symlink to a directory is not"         "no"  "$(runnable "$W/link-to-dir")"
check "a dangling symlink is not"               "no"  "$(runnable "$W/dangling")"
check "a regular file without +x is not"        "no"  "$(runnable "$W/noexec")"
# The search-dir branch: a bare NAME that happens to be a directory inside one of the bin
# directories the scan walks. ~/.faketool/bin matches the ~/.[!.]*/bin glob.
check "a directory found BY NAME is not"        "no"  "$(runnable subdir)"
check "an executable regular file IS"           "yes" "$(runnable "$W/runme")"
check "a symlink to one IS - how agents install" "yes" "$(runnable "$W/link-to-exec")"
check "and it resolves to the path it was given" "$W/link-to-exec" "$(cad_call acp_agent_which "$W/link-to-exec")"

# The middle branch - a bare name resolved through `command -v` - is the one the assertions
# above do not reach: eight of them are absolute paths, and `subdir` returns nothing from
# command -v and falls through to the walk. Reverting that one line to a bare -x therefore ships
# green. A FIFO is what tells the two predicates apart: bash's command -v filters directories
# but NOT fifos, so it comes back as a full path, while execve on it fails with EACCES.
/usr/bin/mkfifo "$W/pathdir/faketool" 2>/dev/null
/bin/chmod 755 "$W/pathdir/faketool"
check "a FIFO on PATH is not an agent" "no" "$(PATH="$W/pathdir:$PATH"; runnable faketool)"
check "  positive control: a real file there IS" "yes" \
    "$(/bin/cp "$W/runme" "$W/pathdir/realtool"; PATH="$W/pathdir:$PATH"; runnable realtool)"

section "a resolved path containing a space survives the round trip"
# The case acp_command_first_word's quote handling exists for: splitting on the first space
# would look up "/My" and report a perfectly good agent as missing, naming it "My" in the
# window title.
/bin/mkdir -p "$OMCTEST_WORK/My Tools"
printf '#!/bin/sh\necho hi\n' > "$OMCTEST_WORK/My Tools/my agent"
/bin/chmod 755 "$OMCTEST_WORK/My Tools/my agent"
spaced=$(cad_call acp_custom_add "Spaced" "\"$OMCTEST_WORK/My Tools/my agent\" acp")
omc_run aichat.select.external.agent.init
check "a quoted path with a space is runnable" "$READY" "$(cad_field "$spaced" 2)"
check "  and the row carries it back verbatim" "\"$OMCTEST_WORK/My Tools/my agent\" acp" "$(cad_field "$spaced" 3)"

section "the status follows the command, not the other way round"
# The status is computed FROM the command, so an agent that has just been given one must stop
# saying "nothing to run" in the same repaint - otherwise the row contradicts the field above it.
cad_reset
omc_control "$TABLE_ID" ""
omc_run aichat.select.external.agent.add
fresh=$(cad_get /agents/custom/0/id)
check "a new agent starts unknown" "$UNKNOWN" "$(cad_field "$fresh" 2)"
omc_control "$PANE_OWNER_ID" "$fresh"
omc_control "$COMMAND_FIELD_ID" "/opt/nowhere/agent acp"
omc_run aichat.select.external.agent.command.changed
check "an unresolvable command moves it to missing" "$MISSING" "$(cad_field "$fresh" 2)"
omc_control "$COMMAND_FIELD_ID" "/bin/echo acp"
omc_run aichat.select.external.agent.command.changed
check "a resolvable one moves it to ready"          "$READY"   "$(cad_field "$fresh" 2)"
omc_control "$COMMAND_FIELD_ID" ""
omc_run aichat.select.external.agent.command.changed
check "clearing it goes back to unknown"            "$UNKNOWN" "$(cad_field "$fresh" 2)"

section "a catalog row's glyph answers for the command that will actually run"
# A catalog row shows the catalog's executable UNTIL the user configures that agent with their
# own command, and then it shows theirs - the override exists so reopening the dialog does not
# silently revert to a default the user has already replaced. The glyph has to move with it.
# It did not: it stayed the catalog's verdict about a command that is no longer the one stored,
# which is wrong in both directions and wrong in exactly the two cases the override creates.
#
# ASSERTED AS A CHANGE, not as two absolute values. Whether claude-code-acp is installed
# varies by machine, so the catalog's own verdict for that row is READY on some and MISSING on
# others - and an absolute expectation that happens to match the baseline is satisfied by the
# feature being ABSENT. Exactly one half of such a pair does real work on any given machine,
# and which one is unknowable from the test. Pinning the baseline first, then requiring the
# glyph to move away from it and back, bites on every machine.
cad_reset
omc_run aichat.select.external.agent.init
check_status "init ran" 0
baseline=$(cad_field claude-code-acp 2)
# cad_has, not a bare `case` - a case inside $( ) mis-parses under /bin/sh, the `*)` closing
# the substitution. That is what the helper is for.
check "the catalog's own verdict is one of the three" "1" \
    "$(cad_has "$READY|$MISSING|$UNKNOWN" "$baseline")"

# A command that certainly resolves, whatever this machine has installed, and one that
# certainly does not. Whichever the baseline was, at least one of these differs from it.
cad_call acp_agent_store claude-code-acp "/bin/echo acp" >/dev/null 2>&1
omc_run aichat.select.external.agent.init
check "the row shows the stored command"       "/bin/echo acp" "$(cad_field claude-code-acp 3)"
check "  and the glyph reads ready"            "$READY"        "$(cad_field claude-code-acp 2)"
ready_glyph=$(cad_field claude-code-acp 2)

cad_call acp_agent_store claude-code-acp "/opt/nowhere/agent acp" >/dev/null 2>&1
omc_run aichat.select.external.agent.init
check "an unresolvable stored command shows"   "/opt/nowhere/agent acp" "$(cad_field claude-code-acp 3)"
check "  and the glyph reads missing"          "$MISSING"      "$(cad_field claude-code-acp 2)"
# THE ONE THAT CANNOT BE SATISFIED BY THE FEATURE'S ABSENCE. Without the recompute both
# stores leave the catalog's verdict in place, so the two glyphs are equal whatever this
# machine has installed.
check "  the glyph MOVED between the two commands" "differ" \
    "$([ "$ready_glyph" != "$(cad_field claude-code-acp 2)" ] && echo differ || echo same)"
# The override is for ONE row. Every other catalog row keeps the catalog's answer, so a stored
# command cannot repaint the whole list.
check "no other row was affected"              "0" \
    "$(ui_rows "$TABLE_ID" | /usr/bin/awk -F '\t' '$4 != "claude-code-acp" && $3 ~ /nowhere/' | /usr/bin/grep -c .)"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"

omctest_end
