#!/bin/bash
# aichat.select.external.agent.selection.changed.sh
# Repaints the About pane, loads the row's command into the editable field, and enables OK.
#
# The command field is the contract, not the table row: whatever ends up in it is what gets
# stored and run. Selecting a row seeds it; the user is free to edit afterwards, which is the
# only way "Custom command" can work at all.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh"

INFO_TEXT_ID=12
COMMAND_FIELD_ID=20
RESULT_TEXT_ID=24
OK_BUTTON_ID=3
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

selected_command="$OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE"
selected_id="$OMC_ACTIONUI_TABLE_10_COLUMN_4_VALUE"

if [ -z "$selected_id" ]; then
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select an agent from the list."
    exit 0
fi

# Re-read the catalog rather than carrying the note through the table: notes are prose and a
# single tab in one would shift every hidden column after it.
note=""
state=""
label=""
while IFS='	' read -r id row_label row_state row_argv row_note; do
    if [ "$id" = "$selected_id" ]; then
        label="$row_label"
        state="$row_state"
        note="$row_note"
        break
    fi
done <<EOF
$(acp_agent_scan)
EOF

case "$selected_id" in
    custom)
        # Seed from the stored command, not "". Blanking it here is what made a saved custom
        # command impossible to re-commit: the field was pre-filled at init, clicking the only
        # row that keeps selected_id=custom wiped it, and OK then refused with "Enter a
        # command before continuing".
        "$dialog_tool" "$window_uuid" $COMMAND_FIELD_ID "$(acp_agent_stored_command)"
        info="**${label}**

${note}

Type the command exactly as you would run it in Terminal, including any subcommand or flag that puts the agent into ACP mode. Quote a path that contains spaces."
        ;;
    *)
        [ "$selected_command" = "-" ] || "$dialog_tool" "$window_uuid" $COMMAND_FIELD_ID "$selected_command"
        if [ "$state" = "missing" ]; then
            info="**${label}**

**Not installed on this Mac.** The command below is what Cadabra would run once it is.

${note}"
            # Install instructions are COMPUTED rather than carried in the catalog note,
            # because they depend on whether the package manager this agent needs is itself
            # here. Empty for a row with no package-manager install, which is most of them.
            hint=$(acp_agent_install_hint "$selected_id")
            if [ -n "$hint" ]; then
                info="${info}

${hint}"
            fi
        else
            info="**${label}**

${note}"
        fi
        ;;
esac

# Piped through acp_md_paragraphs: a bare blank line is a paragraph break the flattened
# renderer drops, which would run the heading straight into the note text.
"$dialog_tool" "$window_uuid" $INFO_TEXT_ID markdown "$(printf '%s' "$info" | acp_md_paragraphs)"
"$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Press Test to launch the agent and check that it answers."

# OK is enabled for every row, including a missing one: the command field is editable, so the
# user may be pointing a known-agent row at a binary we did not find on the search path. Test
# is how you check before committing; refusing to enable OK here would block that legitimate
# case to prevent a mistake the window already reports clearly.
"$dialog_tool" "$window_uuid" $OK_BUTTON_ID omc_enable
