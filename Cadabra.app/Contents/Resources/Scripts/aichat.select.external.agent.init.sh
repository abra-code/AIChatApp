#!/bin/bash
# aichat.select.external.agent.init.sh
# Populates the external-agent table and restores whatever was chosen last time.
#
# The table lists every agent in the catalog, found or not. Showing the missing ones is most
# of the point: "which agents can I even use here" is the question a user actually has, and
# an empty list on a machine with nothing installed answers it with silence. A missing row
# carries its install hint in the About pane instead.
#
# Column 3 (the command) and column 4 (the catalog id) are HIDDEN - rows carry 4 tab-separated
# values but only 2 headers exist - and the sibling handlers read them as
# OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE / _4_VALUE. Adding a visible column would shift both
# indices here, in selection.changed, in test and in ok.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh"

TABLE_ID=10
INFO_TEXT_ID=12
COMMAND_FIELD_ID=20
RESULT_TEXT_ID=24
USE_TOOLS_PICKER_ID=30
OK_BUTTON_ID=3
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Widths are NOT set here. The JSON owns them, because it is the only place that can express
# minWidths (there is no dialog-control verb for those) and a runtime
# omc_table_set_column_widths would silently overwrite the ideal widths while leaving the
# minimums behind, leaving the two halves of the sizing disagreeing with each other.
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_columns "Agent" "Status"
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_remove_all_rows

stored_id=$(acp_agent_stored_id)
stored_command=$(acp_agent_stored_command)

# One pass over the scan, building the row buffer. The note is NOT a column - it is looked up
# again by selection.changed from the same catalog, so it never has to survive a tab-separated
# round trip through the table (notes contain punctuation, and one stray tab would shift the
# hidden columns that the OK handler runs).
buffer=""
stored_row=-1
row_index=0
while IFS='	' read -r id label state argv url summary note; do
    [ -n "$id" ] || continue
    case "$state" in
        found)   shown="Ready" ;;
        missing) shown="Not found" ;;
        *)       shown="Custom" ;;
    esac
    # A remembered command wins over the catalog default for its own row, so reopening the
    # dialog shows what is actually configured rather than silently reverting to the default.
    if [ -n "$stored_command" ] && [ "$id" = "$stored_id" ]; then
        argv="$stored_command"
    fi
    [ "$id" = "$stored_id" ] && stored_row=$row_index
    row_index=$((row_index + 1))
    buffer="${buffer}${label}	${shown}	${argv}	${id}
"
done <<EOF
$(acp_agent_scan)
EOF

printf "%s" "$buffer" | "$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_rows_from_stdin

# Re-select the stored row so a returning user can press Continue straight away. Without it
# the dialog opens with the command pre-filled and the button dead - OK is enabled only by
# selection.changed - so the only way to commit an unchanged setup was to click a row, which
# for a custom command also blanked the field they were trying to keep.
if [ "$stored_row" -ge 0 ]; then
    "$dialog_tool" "$window_uuid" $TABLE_ID omc_select_row "$stored_row"
    "$dialog_tool" "$window_uuid" $OK_BUTTON_ID omc_enable
fi

# Pre-fill the command field with the stored command so a returning user sees their setup
# immediately, even before touching the list.
if [ -n "$stored_command" ]; then
    "$dialog_tool" "$window_uuid" $COMMAND_FIELD_ID "$stored_command"
    # Backticks neutralized for the code span only. The FIELD gets the command unaltered -
    # that is what will be run - but one backtick in the displayed copy closes the span early
    # and the rest of the pane renders as garbage, in the one place whose job is showing the
    # user exactly what is configured.
    shown_command=$(printf '%s' "$stored_command" | /usr/bin/tr '`' "'")
    info="**Currently configured:** \`${shown_command}\`

Select a row to change it, or press **Test** to check this one."
else
    info="Cadabra normally talks to its own bundled agent. Pick a different local ACP agent here to use it instead - it brings its own model and its own credentials.

Select one from the list to see what it needs."
fi
# Piped through acp_md_paragraphs because a bare blank line is dropped by the renderer and
# glues the two paragraphs together.
"$dialog_tool" "$window_uuid" $INFO_TEXT_ID markdown "$(printf '%s' "$info" | acp_md_paragraphs)"

"$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Press Test to launch the agent and check that it answers."

# Tools default to ALL: an external coding agent with no filesystem access is a chat box,
# which is not why anyone points Cadabra at opencode. The value is the picker's TAG, and the
# tags are the literal strings the rest of the path already speaks ("true"/"false"), so
# widening this control to three states changed no downstream comparison.
#
# "readonly" is the middle setting: hand the agent only the servers whose every tool declared
# itself read-only. It exists because gatedTools - Cadabra's own "ask before this tool runs"
# list - is an mlx-agent extension that an external agent cannot honor, so the only leverage
# left is what we hand over rather than what we ask it to gate.
"$dialog_tool" "$window_uuid" $USE_TOOLS_PICKER_ID true
