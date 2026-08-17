#!/bin/sh
# Tests/30-acp-agent-editor.test.sh - the editor pane: who it belongs to, when its two fields
# reach the record, and what every button that acts on it must save first.
#
# This is the file that matters. The editor has no Save button, so both of its fields commit on
# focus loss - and the commonest way to finish an edit is to click another row, which fires the
# blur handler AND a selection change at once, in an order neither script can observe. Handlers
# see a SNAPSHOT of the window taken when they were dispatched, and two can be in flight
# together, so a handler that asks the table selection who it is editing can rename the agent
# the user just clicked instead of the one they typed into.
#
# The answer is that the pane carries its own identity in a hidden view: cleared before a
# repaint, set after it. A snapshot therefore either names a fully painted owner, or is empty
# and the handler declines. Most of what follows is that protocol, from both directions.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

UNKNOWN="•••"
MISSING="➖"

# Every painter must CLEAR the owner before touching a field and SET it after the last one.
# That ordering is the whole guarantee, so it is asserted directly rather than inferred from
# the values that end up on screen.
section "the pane-owner protocol: cleared before a repaint, signed after it"
cad_reset
cad_journal_reset
omc_run aichat.select.external.agent.add
check "+ clears the owner first"    ""          "$(cad_journal "$PANE_OWNER_ID" | /usr/bin/head -1)"
check "+ signs the new agent last"  "custom:1"  "$(cad_journal "$PANE_OWNER_ID" | /usr/bin/tail -1)"
check "  and signs it AFTER painting the name" "yes" \
    "$(/usr/bin/awk -F'\t' -v n="$NAME_FIELD_ID" -v o="$PANE_OWNER_ID" \
        '$2==n { name=NR } $2==o && $3 != " " { owner=NR } END { print (owner>name) ? "yes" : "no" }' \
        "$OMCTEST_UI/journal.tsv")"

omc_table_cell "$TABLE_ID" 4 custom:1
omc_table_cell "$TABLE_ID" 3 "-"
cad_journal_reset
omc_run aichat.select.external.agent.selection.changed
check "selecting a saved agent claims then signs" "2" "$(cad_writes "$PANE_OWNER_ID")"
check "  ending owned by that agent"  "custom:1" "$(cad_journal "$PANE_OWNER_ID" | /usr/bin/tail -1)"
omc_table_cell "$TABLE_ID" 4 opencode
omc_table_cell "$TABLE_ID" 3 "/opt/opencode acp"
cad_journal_reset
omc_run aichat.select.external.agent.selection.changed
check "selecting a built-in signs it too" "opencode" "$(cad_journal "$PANE_OWNER_ID" | /usr/bin/tail -1)"
omc_table_cell "$TABLE_ID" 4 ""
omc_table_cell "$TABLE_ID" 3 ""
cad_journal_reset
omc_run aichat.select.external.agent.selection.changed
# Both writes are empty here, so they are COUNTED rather than read back - command substitution
# would swallow them and the assertion would pass with neither write happening.
check "deselecting claims and signs, both empty" "2" "$(cad_writes "$PANE_OWNER_ID")"
check "  and leaves no owner behind"             ""  "$(ui_value "$PANE_OWNER_ID")"
cad_call acp_agent_store custom:1 "/opt/mine/agent acp" >/dev/null 2>&1
cad_journal_reset
omc_run aichat.select.external.agent.init
check "init claims first, with an empty write" "" "$(cad_journal "$PANE_OWNER_ID" | /usr/bin/head -1)"
check "  then signs the configured agent" "custom:1" "$(cad_journal "$PANE_OWNER_ID" | /usr/bin/tail -1)"

section "the command field commits on blur, exactly like the name"
# The bug this exists for, found in manual testing: the name saved when you clicked away and
# the command silently did not. The two fields sit one above the other and looked identical.
cad_reset
omc_run aichat.select.external.agent.add
omc_control "$PANE_OWNER_ID" custom:1
omc_control "$COMMAND_FIELD_ID" "/opt/mine/agent acp"
cad_journal_reset
omc_run aichat.select.external.agent.command.changed
check "the command reaches the record" "/opt/mine/agent acp" "$(cad_get /agents/custom/0/command)"
check "the row stops saying unknown"   "New Agent	$MISSING	/opt/mine/agent acp	custom:1" "$(cad_row custom:1)"
check "the edited row stays highlighted" "11" "$(ui_selection "$TABLE_ID")"
check "the pane owner is NOT touched"    "0"  "$(cad_writes "$PANE_OWNER_ID")"
# OK is deliberately left alone. Disabling it on an empty command looks tidier and breaks the
# button: this handler runs on focus loss, so typing a command and clicking straight on OK
# would reach a button that was still disabled when the click landed.
check "OK is left alone - no double-click trap" "0" "$(cad_writes "$OK_BUTTON_ID")"
check "the field is not rewritten"              "0" "$(cad_writes "$COMMAND_FIELD_ID")"

omc_table_cell "$TABLE_ID" 4 opencode
omc_table_cell "$TABLE_ID" 3 "/opt/opencode acp"
omc_run aichat.select.external.agent.selection.changed
omc_table_cell "$TABLE_ID" 4 custom:1
omc_table_cell "$TABLE_ID" 3 "/opt/mine/agent acp"
omc_run aichat.select.external.agent.selection.changed
check "coming back to the agent shows the saved command" "/opt/mine/agent acp" "$(ui_value "$COMMAND_FIELD_ID")"

omc_control "$PANE_OWNER_ID" custom:1
omc_control "$COMMAND_FIELD_ID" "/opt/mine/agent acp"
cad_journal_reset
omc_run aichat.select.external.agent.command.changed
check "an unchanged command writes nothing" "0" "$(cad_writes "$TABLE_ID")"
# An EMPTY command is allowed, unlike an empty name: a saved agent with nothing typed into it
# yet is a real state - it is what + creates.
omc_control "$COMMAND_FIELD_ID" ""
omc_run aichat.select.external.agent.command.changed
check "clearing it IS allowed"          ""         "$(cad_get /agents/custom/0/command)"
check "  and the row says unknown again" "$UNKNOWN" "$(cad_field custom:1 2)"
omc_control "$COMMAND_FIELD_ID" "$(printf ' /bin/echo\tacp ')"
cad_journal_reset
omc_run aichat.select.external.agent.command.changed
check "cleaned on the way in"             "/bin/echo acp" "$(cad_get /agents/custom/0/command)"
check "  the field is NOT written back"   "0"             "$(cad_writes "$COMMAND_FIELD_ID")"
check "  but the LIST carries the cleaned command" "/bin/echo acp" "$(cad_field custom:1 3)"
omc_control "$COMMAND_FIELD_ID" "/bin/echo  two  spaces"
omc_run aichat.select.external.agent.command.changed
# Interior spacing is part of an argument; only the ends are trimmed and tabs neutralized.
check "interior spacing is kept" "/bin/echo  two  spaces" "$(cad_get /agents/custom/0/command)"

# The same two race directions as the rename.
omc_control "$PANE_OWNER_ID" ""
omc_control "$COMMAND_FIELD_ID" "/opt/hijack acp"
omc_table_cell "$TABLE_ID" 4 custom:1
omc_run aichat.select.external.agent.command.changed
check "an empty pane owner writes nothing" "/bin/echo  two  spaces" "$(cad_get /agents/custom/0/command)"
omc_control "$PANE_OWNER_ID" opencode
omc_control "$COMMAND_FIELD_ID" "/opt/elsewhere acp"
cad_journal_reset
omc_run aichat.select.external.agent.command.changed
check "a built-in pane writes no record"   "/bin/echo  two  spaces" "$(cad_get /agents/custom/0/command)"
check "  and does not repaint"             "0" "$(cad_writes "$TABLE_ID")"
second=$(cad_call acp_custom_add "Second" "/bin/second")
omc_control "$PANE_OWNER_ID" custom:1
omc_control "$COMMAND_FIELD_ID" "/opt/follows/pane acp"
omc_table_cell "$TABLE_ID" 4 "$second"
omc_run aichat.select.external.agent.command.changed
check "the edit follows the pane, not the highlight" "/opt/follows/pane acp" "$(cad_get /agents/custom/0/command)"
check "  the highlighted agent is untouched"         "/bin/second" "$(cad_call acp_custom_get "$second" command)"

section "OK commits the name itself, and proves the record write landed"
# On macOS an AppKit button does not normally take key focus when clicked, so pressing Continue
# straight after typing a name may never blur the field. OK therefore commits from its OWN
# snapshot - the same one it is about to act on, so the two cannot disagree.
cad_reset
ok_id=$(cad_call acp_custom_add "Before" "/bin/before")
omc_control "$PANE_OWNER_ID" "$ok_id"
omc_table_cell "$TABLE_ID" 4 "$ok_id"
omc_control "$NAME_FIELD_ID" "Typed But Never Blurred"
omc_control "$COMMAND_FIELD_ID" "/bin/after"
omc_control "$USE_TOOLS_PICKER_ID" false
omc_run aichat.select.external.agent.ok
check "OK commits the typed name"  "Typed But Never Blurred" "$(cad_call acp_custom_get "$ok_id" label)"
check "  and the command with it"  "/bin/after"              "$(cad_call acp_custom_get "$ok_id" command)"
check "  and stores the agent"     "$ok_id"                  "$(cad_get /agents/external/id)"
omc_control "$NAME_FIELD_ID" "   "
omc_run aichat.select.external.agent.ok
check "an empty typed name is skipped, not stored" "Typed But Never Blurred" "$(cad_call acp_custom_get "$ok_id" label)"

# A silently failed RECORD write must be caught, not only the live-command one: plister can
# exit 0 having written nothing when the file cannot be written.
omc_control "$NAME_FIELD_ID" "Typed But Never Blurred"
omc_control "$COMMAND_FIELD_ID" "/bin/unwritable"
/bin/chmod 555 "$HOME/Library/Application Support/Cadabra"
cad_journal_reset
omc_run aichat.select.external.agent.ok
check "a failed record write is reported" "1" "$(cad_journal "$RESULT_TEXT_ID" | /usr/bin/grep -c 'Could not save')"
check "  and the window is NOT closed"    "0" "$(cad_writes omc_window)"
check "  and the record is unchanged"     "/bin/after" "$(cad_call acp_custom_get "$ok_id" command)"
# It must be the RECORD guard firing, not the live-command one further down. An unwritable
# settings file is not a missing record, and conflating them silently drops the agent's name.
check "  the id was NOT degraded to bare custom" "$ok_id"     "$(cad_get /agents/external/id)"
check "  and the live command was left alone"    "/bin/after" "$(cad_get /agents/external/command)"
/bin/chmod 755 "$HOME/Library/Application Support/Cadabra"

section "OK follows the pane, not the highlight"
race_id=$(cad_call acp_custom_add "Race Target" "/bin/echo one")
omc_control "$PANE_OWNER_ID" "$race_id"
omc_table_cell "$TABLE_ID" 4 opencode
omc_table_cell "$TABLE_ID" 3 "/opt/opencode acp"
omc_control "$COMMAND_FIELD_ID" "/bin/echo two"
omc_control "$NAME_FIELD_ID" "Race Target"
omc_run aichat.select.external.agent.ok
check "OK commits the pane's agent"        "$race_id"      "$(cad_get /agents/external/id)"
check "  with the field's command"         "/bin/echo two" "$(cad_get /agents/external/command)"
check "  written through to its record"    "/bin/echo two" "$(cad_call acp_custom_get "$race_id" command)"
# A built-in is claimed BY NAME only when the row still agrees with it. Otherwise the user has
# edited the command out from under a catalog row, and what they have is an ad-hoc command.
omc_control "$PANE_OWNER_ID" opencode
omc_table_cell "$TABLE_ID" 4 gemini
omc_table_cell "$TABLE_ID" 3 "/opt/gemini acp"
omc_control "$COMMAND_FIELD_ID" "/opt/gemini acp"
omc_run aichat.select.external.agent.ok
check "a built-in whose row disagrees is not claimed by name" "custom" "$(cad_get /agents/external/id)"
omc_table_cell "$TABLE_ID" 4 opencode
omc_table_cell "$TABLE_ID" 3 "/opt/opencode acp"
omc_control "$COMMAND_FIELD_ID" "/opt/opencode acp"
omc_run aichat.select.external.agent.ok
check "a built-in whose row agrees keeps its name" "opencode" "$(cad_get /agents/external/id)"

section "the commit paths cannot store what the pane is not showing"
# A stored id whose record does not exist must not arm - nor open the editor.
cad_reset
cad_call acp_agent_store custom:9 "/opt/ghost/agent acp" >/dev/null 2>&1
omc_run aichat.select.external.agent.init
check "a dangling stored id does not arm remove" "0" "$(ui_enabled "$REMOVE_BUTTON_ID")"
check "  nor open the editor"                    "0" "$(ui_visible "$CUSTOM_PANE_ID")"
check "  the About pane is shown instead"        "1" "$(ui_visible "$ABOUT_PANE_ID")"
check "  the selection is cleared"               ""  "$(ui_selection "$TABLE_ID")"
check "  and the field still shows the live command" "/opt/ghost/agent acp" "$(ui_value "$COMMAND_FIELD_ID")"
# Committing that id must not store a pointer to nothing.
omc_control "$PANE_OWNER_ID" custom:9
omc_table_cell "$TABLE_ID" 4 custom:9
omc_table_cell "$TABLE_ID" 3 "/opt/ghost/agent acp"
omc_control "$COMMAND_FIELD_ID" "/opt/typed/agent acp"
omc_control "$NAME_FIELD_ID" ""
omc_control "$USE_TOOLS_PICKER_ID" false
omc_run aichat.select.external.agent.ok
check "a dangling id degrades to the ad-hoc one" "custom" "$(cad_get /agents/external/id)"
check "  the typed command was stored"  "/opt/typed/agent acp" "$(cad_get /agents/external/command)"
# Asked through the applet's own counter rather than plister directly: /agents/custom was
# never created here, and `plister get count` on an absent key prints nothing rather than 0 -
# so a raw comparison against "0" fails for the very state it is trying to confirm.
check "  and no record was invented"    "0" "$(cad_call acp_custom_count)"
# A whitespace-only command is refused before anything is overwritten. shlex splits it into no
# argv at all, so without this the failure surfaces at launch instead of in the dialog asking.
before_cmd=$(cad_get /agents/external/command)
omc_control "$COMMAND_FIELD_ID" "   "
cad_journal_reset
omc_run aichat.select.external.agent.ok
check "a whitespace-only command is refused" "Enter a command before continuing." "$(cad_journal "$RESULT_TEXT_ID" | /usr/bin/tail -1)"
check "  and nothing was overwritten"        "$before_cmd" "$(cad_get /agents/external/command)"

section "Test saves the agent too - a button click need not blur the field"
# Testing is part of editing. Without this, a user proves a command works and the next repaint
# quietly puts the old one back, discarding the thing they just verified.
cad_reset
t_id=$(cad_call acp_custom_add "Before Test" "/bin/before")
omc_control "$PANE_OWNER_ID" "$t_id"
omc_control "$NAME_FIELD_ID" "Named By Test"
omc_control "$COMMAND_FIELD_ID" "$(cad_fake_agent)"
cad_journal_reset
omc_run aichat.select.external.agent.test
check "Test commits the typed command" "$(cad_fake_agent)" "$(cad_call acp_custom_get "$t_id" command)"
check "  and the typed name with it"   "Named By Test"     "$(cad_call acp_custom_get "$t_id" label)"
check "  and still reports a probe result" "1" "$(cad_journal "$RESULT_TEXT_ID" | /usr/bin/grep -c 'FakeAgent')"
# The identity is recorded against the CLEANED command, because Continue stores the cleaned one:
# measuring the raw value would mean the two never match again, and a command typed with a
# stray leading space would silently lose the name and version the user just watched it report.
check "  and records the agent's identity" "FakeAgent" "$(cad_get /agents/external/verifiedName)"
check "  keyed by the command it measured" "$(cad_call acp_custom_get "$t_id" command)" "$(cad_get /agents/external/verifiedCommand)"

omc_control "$PANE_OWNER_ID" opencode
omc_control "$NAME_FIELD_ID" "Hijack"
omc_run aichat.select.external.agent.test
check "a built-in pane writes no record" "Named By Test" "$(cad_call acp_custom_get "$t_id" label)"
omc_control "$PANE_OWNER_ID" ""
omc_run aichat.select.external.agent.test
check "an empty pane owner writes no record" "Named By Test" "$(cad_call acp_custom_get "$t_id" label)"

omc_control "$PANE_OWNER_ID" "$t_id"
omc_control "$NAME_FIELD_ID" "X"
omc_control "$COMMAND_FIELD_ID" ""
cad_journal_reset
omc_run aichat.select.external.agent.test
check "an empty command is refused before any save" "Enter a command first." "$(cad_journal "$RESULT_TEXT_ID" | /usr/bin/tail -1)"
check "  and saves nothing"                         "Named By Test" "$(cad_call acp_custom_get "$t_id" label)"

# A failed save is reported ABOVE the probe result rather than being overwritten by it.
#
# The NAME is what changes here, and the command deliberately does not. That is the case the
# saver reads the label back separately for: with the command unchanged, its own read-back
# passes without proving anything was writable, so a rename-only edit would otherwise sail
# through on a settings file that cannot be written at all. Keeping the command pointed at the
# fake agent also means the probe still succeeds, which is what lets the assertion below prove
# the warning was placed ABOVE a real result rather than instead of one.
omc_control "$NAME_FIELD_ID" "Renamed While Unwritable"
omc_control "$COMMAND_FIELD_ID" "$(cad_fake_agent)"
/bin/chmod 555 "$HOME/Library/Application Support/Cadabra"
cad_journal_reset
omc_run aichat.select.external.agent.test
check "a failed save is reported"           "1" "$(cad_journal "$RESULT_TEXT_ID" | /usr/bin/grep -c 'could not be saved')"
check "  and the probe result is still there" "1" "$(cad_journal "$RESULT_TEXT_ID" | /usr/bin/grep -c 'FakeAgent')"
check "  and the rename really did not land"  "Named By Test" "$(cad_call acp_custom_get "$t_id" label)"
/bin/chmod 755 "$HOME/Library/Application Support/Cadabra"

section "a record that vanished under the window is reported, never swallowed"
# The other way a save fails, and the one that looks most like success: nothing is wrong with
# the file, the record was simply removed in another window or edited out by hand. Test would
# otherwise show a green probe over an edit that went nowhere.
cad_reset
ghost=$(cad_call acp_custom_add "Doomed" "/bin/before")
cad_call acp_custom_remove "$ghost"
check "the record really is gone" "" "$(cad_call acp_custom_get "$ghost" label)"
omc_control "$PANE_OWNER_ID" "$ghost"
omc_control "$NAME_FIELD_ID" "New Name"
cad_journal_reset
omc_run aichat.select.external.agent.name.changed
check "the rename reports it"        "1" "$(cad_journal "$RESULT_TEXT_ID" | /usr/bin/grep -c 'no longer in the list')"
check "  and drops the phantom row"  ""  "$(cad_row "$ghost")"
check "  without forcing a selection" "" "$(ui_selection "$TABLE_ID")"
omc_control "$COMMAND_FIELD_ID" "/bin/new"
cad_journal_reset
omc_run aichat.select.external.agent.command.changed
check "the command edit reports it too" "1" "$(cad_journal "$RESULT_TEXT_ID" | /usr/bin/grep -c 'no longer in the list')"
omc_control "$COMMAND_FIELD_ID" "$(cad_fake_agent)"
cad_journal_reset
omc_run aichat.select.external.agent.test
check "Test warns instead of reporting a bare green" "1" "$(cad_journal "$RESULT_TEXT_ID" | /usr/bin/grep -c 'no longer in the list')"
check "  and still shows the probe result under it"  "1" "$(cad_journal "$RESULT_TEXT_ID" | /usr/bin/grep -c 'FakeAgent')"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"

omctest_end
