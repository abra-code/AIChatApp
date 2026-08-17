#!/bin/sh
# Tests/20-acp-agent-list.test.sh - the agent list: creating, renaming, deleting, and what the
# window looks like when it opens.
#
# The dialog has two panes in a ZStack and exactly one is visible at a time, so almost every
# assertion here comes in a pair: what was shown AND what was hidden. A test that only checks
# the show would pass with both panes drawn on top of each other.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

UNKNOWN="•••"

section "+ creates a named record, selects it, and opens the editor"
cad_reset
omc_table_cell "$TABLE_ID" 4 ""
omc_run aichat.select.external.agent.add
check_status "add ran"                    0
check "one record exists"                 "custom:1"   "$(cad_get /agents/custom/0/id)"
check "named from the catalog template"   "New Agent"  "$(cad_get /agents/custom/0/label)"
check "with no command yet"               ""           "$(cad_get /agents/custom/0/command)"
check "the row shows the unknown glyph"   "New Agent	$UNKNOWN	-	custom:1" "$(cad_row custom:1)"
check "the new row was selected"          "11"         "$(ui_selection "$TABLE_ID")"
check "the custom pane is shown"          "1"          "$(ui_visible "$CUSTOM_PANE_ID")"
check "  and the About pane hidden"       "0"          "$(ui_visible "$ABOUT_PANE_ID")"
check "remove is enabled"                 "1"          "$(ui_enabled "$REMOVE_BUTTON_ID")"
check "the name field is seeded"          "New Agent"  "$(ui_value "$NAME_FIELD_ID")"
check "the command field is blanked"      ""           "$(ui_value "$COMMAND_FIELD_ID")"
# Blanked, not merely untouched: an empty value could be either, and the difference is whether
# the previous agent's command is still sitting in the field.
check "  and blanked EXPLICITLY"          "1"          "$(cad_writes "$COMMAND_FIELD_ID")"
check "OK is enabled"                     "1"          "$(ui_enabled "$OK_BUTTON_ID")"

section "+ twice does not make two rows with the same name"
# Names are not identity here, so duplicates are legal - and legal-but-indistinguishable is the
# worst kind. The Finder's convention, for the Finder's reason.
omc_run aichat.select.external.agent.add
check "second record"        "custom:2"      "$(cad_get /agents/custom/1/id)"
check "  disambiguated name" "New Agent 2"   "$(cad_get /agents/custom/1/label)"
omc_run aichat.select.external.agent.add
check "third record name"    "New Agent 3"   "$(cad_get /agents/custom/2/label)"

section "a rename writes through AND shows up in the list"
# The whole point: a rename the sidebar does not show reads as a rename that did not happen.
omc_control "$PANE_OWNER_ID" custom:2
omc_control "$NAME_FIELD_ID" "My Coder"
cad_journal_reset
omc_run aichat.select.external.agent.name.changed
check "the label is stored"                "My Coder"  "$(cad_get /agents/custom/1/label)"
check "the row carries the new name"       "My Coder	$UNKNOWN	-	custom:2" "$(cad_row custom:2)"
check "the old name is gone from the list" ""          "$(ui_rows "$TABLE_ID" | /usr/bin/grep 'New Agent 2')"
check "the renamed row stays highlighted"  "12"        "$(ui_selection "$TABLE_ID")"
# The rename repaints the ROWS and nothing else. The pane and its owner keep exactly one
# writer - the painter - so a concurrent selection change can at worst leave the highlight on
# the wrong row, rather than a pane describing one agent while the buttons act on another.
check "the pane owner is NOT touched"      "0"         "$(cad_writes "$PANE_OWNER_ID")"
check "the detail pane is NOT repainted"   "0"         "$(cad_writes "$CUSTOM_TEXT_ID")"
check "the field is not rewritten"         "0"         "$(cad_writes "$NAME_FIELD_ID")"

section "a rename refuses an empty name and reports it without touching the field"
omc_control "$NAME_FIELD_ID" "   "
cad_journal_reset
omc_run aichat.select.external.agent.name.changed
check "the label is unchanged"        "My Coder" "$(cad_get /agents/custom/1/label)"
# The refusal is REPORTED, not repaired. Writing the old name back into the field is an
# unserialized pane write that can land inside another agent's signed editor, where the next
# blur commits it as a rename of THAT agent.
check "the field is NOT written"      "0"   "$(cad_writes "$NAME_FIELD_ID")"
check "the refusal is reported"       "1"   "$(cad_journal "$RESULT_TEXT_ID" | /usr/bin/grep -c 'needs a name')"
check "  and it names what was kept"  "1"   "$(cad_journal "$RESULT_TEXT_ID" | /usr/bin/grep -c 'My Coder')"
check "the list is NOT repainted"     "0"   "$(cad_writes "$TABLE_ID")"

section "a rename ignores an unchanged name, a built-in, and a pane mid-repaint"
omc_control "$NAME_FIELD_ID" "My Coder"
cad_journal_reset
omc_run aichat.select.external.agent.name.changed
check "no repaint for an unchanged name" "0" "$(cad_writes "$TABLE_ID")"
omc_control "$PANE_OWNER_ID" opencode
omc_control "$NAME_FIELD_ID" "Hijack"
cad_journal_reset
omc_run aichat.select.external.agent.name.changed
check "a built-in cannot be renamed"     "0"         "$(cad_writes "$NAME_FIELD_ID")"
check "  and nothing was written"        "My Coder"  "$(cad_get /agents/custom/1/label)"
# The race the whole mechanism exists for: this snapshot caught a repaint in flight, so the
# name in the field belongs to nobody the handler can name. It must decline rather than guess.
omc_control "$PANE_OWNER_ID" ""
omc_control "$NAME_FIELD_ID" "Hijack"
omc_table_cell "$TABLE_ID" 4 custom:2
cad_journal_reset
omc_run aichat.select.external.agent.name.changed
check "an empty pane owner writes nothing"        "My Coder" "$(cad_get /agents/custom/1/label)"
check "  even with a row highlighted underneath"  "0"        "$(cad_writes "$TABLE_ID")"
# And the inverse: the highlight has already moved to another agent while the pane still shows
# the one being renamed. The rename must follow the PANE.
omc_control "$PANE_OWNER_ID" custom:2
omc_control "$NAME_FIELD_ID" "Renamed Under Race"
omc_table_cell "$TABLE_ID" 4 custom:3
omc_run aichat.select.external.agent.name.changed
check "the rename follows the pane, not the highlight" "Renamed Under Race" "$(cad_get /agents/custom/1/label)"
check "  the highlighted agent is untouched"           "New Agent 3"        "$(cad_get /agents/custom/2/label)"

section "a tab pasted into a name cannot corrupt the row"
omc_control "$PANE_OWNER_ID" custom:2
omc_control "$NAME_FIELD_ID" "$(printf 'A\tB')"
cad_journal_reset
omc_run aichat.select.external.agent.name.changed
check "stored cleaned"                  "A B" "$(cad_get /agents/custom/1/label)"
check "the field is NOT written back"   "0"   "$(cad_writes "$NAME_FIELD_ID")"
check "but the LIST shows the cleaned name" "A B" "$(cad_field custom:2 1)"
check "the repainted row still has 4 columns" "4" "$(cad_row custom:2 | /usr/bin/awk -F'\t' '{ print NF }')"
omc_control "$NAME_FIELD_ID" "My Coder"
omc_run aichat.select.external.agent.name.changed

section "- deletes only a saved agent"
omc_control "$PANE_OWNER_ID" opencode
omc_run aichat.select.external.agent.remove
check "a built-in row is not deletable" "3" "$("$cad_plister" get count "$cad_settings" /agents/custom 2>/dev/null)"
omc_control "$PANE_OWNER_ID" custom:2
omc_run aichat.select.external.agent.remove
check "the saved one is gone"           "2" "$("$cad_plister" get count "$cad_settings" /agents/custom 2>/dev/null)"
check "  and the survivors are intact"  "custom:1 custom:3" \
    "$(cad_get /agents/custom/0/id) $(cad_get /agents/custom/1/id)"
check "the list was repainted without it" "" "$(cad_row custom:2)"

section "deleting the CONFIGURED agent keeps the command and drops the dangling id"
# The record goes, but the live command and the enabled flag do not: deleting a row from a list
# must not silently switch the user back to the bundled agent.
cad_call acp_agent_store custom:3 "/opt/mine/agent acp" >/dev/null 2>&1
check "the stored id before"  "custom:3" "$(cad_get /agents/external/id)"
omc_control "$PANE_OWNER_ID" custom:3
omc_run aichat.select.external.agent.remove
check "the id is demoted to the ad-hoc one" "custom"               "$(cad_get /agents/external/id)"
check "the command survives untouched"      "/opt/mine/agent acp"  "$(cad_get /agents/external/command)"
check "still enabled - a list edit must not switch engines" "true" \
    "$("$cad_plister" get value "$cad_settings" /agents/external/enabled 2>/dev/null)"
check "the About pane is shown"   "1" "$(ui_visible "$ABOUT_PANE_ID")"
check "  and the editor hidden"   "0" "$(ui_visible "$CUSTOM_PANE_ID")"
check "remove is disabled again"  "0" "$(ui_enabled "$REMOVE_BUTTON_ID")"
check "OK stays enabled - there is still a command to commit" "1" "$(ui_enabled "$OK_BUTTON_ID")"
check "the field shows what is still configured" "/opt/mine/agent acp" "$(ui_value "$COMMAND_FIELD_ID")"
check "the selection was explicitly cleared"     ""  "$(ui_selection "$TABLE_ID")"

section "every emitted row is exactly 4 columns, none empty"
# Four values against two drawn columns: an empty field collapses under IFS when the row is
# read back, shifting the hidden command and id left - which hands the OK handler a label where
# the command should be.
omc_table_cell "$TABLE_ID" 4 ""
omc_run aichat.select.external.agent.add
check "no row with the wrong column count" "" "$(ui_rows "$TABLE_ID" | /usr/bin/awk -F'\t' 'NF!=4 { print NR": "NF }')"
check "no empty field in any row"          "" "$(ui_rows "$TABLE_ID" | /usr/bin/awk -F'\t' '{ for (i=1;i<=NF;i++) if ($i == "") print NR":"i }')"
check "the catalog rows are all there"     "11" "$(ui_rows "$TABLE_ID" | /usr/bin/awk -F'\t' '$4 !~ /^custom/' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

section "init on a fresh profile"
cad_reset
ui_reset
omc_run aichat.select.external.agent.init
check_status "init ran"                     0
check "the columns are set once"            "Agent
Status"     "$(ui_columns "$TABLE_ID")"
check "only the catalog is listed"          "11"        "$(ui_row_count "$TABLE_ID")"
check "nothing is selected"                 ""          "$(ui_selection "$TABLE_ID")"
check "OK is explicitly disabled"           "0"         "$(ui_enabled "$OK_BUTTON_ID")"
check "the command field is explicitly emptied" "1"     "$(cad_writes "$COMMAND_FIELD_ID")"
check "  and it is empty"                   ""          "$(ui_value "$COMMAND_FIELD_ID")"
check "remove is disabled"                  "0"         "$(ui_enabled "$REMOVE_BUTTON_ID")"
check "the About pane is shown"             "1"         "$(ui_visible "$ABOUT_PANE_ID")"
check "the tools picker defaults to all"    "true"      "$(ui_value "$USE_TOOLS_PICKER_ID")"
check_absent "merely opening the dialog created no settings file" "$cad_settings"

section "init with a saved agent configured opens straight into the editor"
saved=$(cad_call acp_custom_add "My Coder" "/bin/echo acp")
cad_call acp_agent_store "$saved" "/bin/echo acp" >/dev/null 2>&1
omc_run aichat.select.external.agent.init
check "its row is selected"           "11"            "$(ui_selection "$TABLE_ID")"
check "OK is enabled"                 "1"             "$(ui_enabled "$OK_BUTTON_ID")"
check "remove is enabled"             "1"             "$(ui_enabled "$REMOVE_BUTTON_ID")"
check "the editor is shown"           "1"             "$(ui_visible "$CUSTOM_PANE_ID")"
check "  and the About pane hidden"   "0"             "$(ui_visible "$ABOUT_PANE_ID")"
check "the name field is filled"      "My Coder"      "$(ui_value "$NAME_FIELD_ID")"
check "the field shows the live command" "/bin/echo acp" "$(ui_value "$COMMAND_FIELD_ID")"

section "selection.changed swaps the pane for the kind of row"
omc_table_cell "$TABLE_ID" 4 opencode
omc_table_cell "$TABLE_ID" 3 "/opt/opencode acp"
cad_journal_reset
omc_run aichat.select.external.agent.selection.changed
check "built-in: the About pane is shown"      "1" "$(ui_visible "$ABOUT_PANE_ID")"
check "built-in: the editor is hidden"         "0" "$(ui_visible "$CUSTOM_PANE_ID")"
check "built-in: remove is disabled"           "0" "$(ui_enabled "$REMOVE_BUTTON_ID")"
check "built-in: the field is seeded from the row" "/opt/opencode acp" "$(ui_value "$COMMAND_FIELD_ID")"
check "built-in: the info names the agent"     "1" "$(cad_journal "$INFO_TEXT_ID" | /usr/bin/grep -c '\*\*OpenCode\*\*')"
check "built-in: the info carries the vendor link" "1" "$(cad_journal "$INFO_TEXT_ID" | /usr/bin/grep -c 'More about OpenCode')"
check "built-in: OK is enabled"                "1" "$(ui_enabled "$OK_BUTTON_ID")"
omc_table_cell "$TABLE_ID" 4 "$saved"
omc_table_cell "$TABLE_ID" 3 "/bin/echo acp"
cad_journal_reset
omc_run aichat.select.external.agent.selection.changed
check "saved: the editor is shown"     "1"        "$(ui_visible "$CUSTOM_PANE_ID")"
check "saved: the About pane is hidden" "0"       "$(ui_visible "$ABOUT_PANE_ID")"
check "saved: remove is enabled"       "1"        "$(ui_enabled "$REMOVE_BUTTON_ID")"
check "saved: the name field is filled" "My Coder" "$(ui_value "$NAME_FIELD_ID")"
check "saved: the helper text links the registry" "1" \
    "$(cad_journal "$CUSTOM_TEXT_ID" | /usr/bin/grep -c 'agentclientprotocol.com/get-started/registry')"
check "saved: OK is enabled"           "1"        "$(ui_enabled "$OK_BUTTON_ID")"
omc_table_cell "$TABLE_ID" 4 ""
omc_table_cell "$TABLE_ID" 3 ""
omc_run aichat.select.external.agent.selection.changed
check "no selection: remove is disabled" "0" "$(ui_enabled "$REMOVE_BUTTON_ID")"
check "no selection: the About pane is shown" "1" "$(ui_visible "$ABOUT_PANE_ID")"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"

omctest_end
