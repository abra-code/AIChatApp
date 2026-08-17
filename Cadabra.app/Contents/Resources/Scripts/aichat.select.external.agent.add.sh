#!/bin/bash
# aichat.select.external.agent.add.sh
# The + button: create an empty agent of the user's own, select it, and open it for editing.
#
# It is saved IMMEDIATELY, before anything has been typed into it. That is deliberate: the row
# has to exist to be selected, and the editor edits a record rather than a form, so there is
# nothing here that could be lost by not committing. The cost is a row named "New Agent" with
# no command if the user changes their mind, which the - button removes in one click.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.select.external.agent.library.sh"

# The default name comes from the catalog, like the rest of the dialog's prose. Made unique
# first, so pressing + twice gives "New Agent" and "New Agent 2" rather than two rows nobody
# can tell apart.
IFS='	' read -r template_label template_rest <<EOF
$(acp_agent_custom_template)
EOF
[ -n "$template_label" ] && [ "$template_label" != "-" ] || template_label="New Agent"

new_id=$(acp_custom_add "$(acp_custom_unique_label "$template_label")" "")
if [ -z "$new_id" ]; then
    "$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Could not save a new agent. Check that ~/Library/Application Support/Cadabra is writable."
    exit 0
fi

# Repaint and re-select. Selecting programmatically does NOT fire the selection-changed action,
# so everything that handler would have done has to be done here too.
#
# The list rebuild deliberately happens BEFORE the pane is claimed: it runs the whole catalog
# scan, and the claimed span should hold pane writes only. agent_paint_custom_pane takes the
# claim itself, once its own slow work is done.
agent_refresh_list $TABLE_ID "$new_id"

agent_paint_custom_pane "$new_id"
agent_show_custom_pane
agent_sync_remove_button "$new_id"
"$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Name it, then type the command that starts it."

# OK is ENABLED even though the command is still empty, and the empty case is refused by the OK
# handler instead. Disabling it here would need the command field to re-enable it on every
# keystroke - one OMC subcommand per character - to buy a guard that already exists and reports
# itself in the same place the user is looking.
"$dialog_tool" "$window_uuid" $OK_BUTTON_ID omc_enable

agent_pane_commit "$new_id"
