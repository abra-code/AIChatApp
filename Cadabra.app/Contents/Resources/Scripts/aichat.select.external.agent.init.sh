#!/bin/bash
# aichat.select.external.agent.init.sh
# Populates the external-agent table and restores whatever was chosen last time.
#
# The table lists every agent in the catalog, found or not, and then every agent the user saved
# with the + button. Showing the missing ones is most of the point: "which agents can I even use
# here" is the question a user actually has, and an empty list on a machine with nothing
# installed answers it with silence. A missing row carries its install hint in the About pane.
#
# Almost all of this is agent_restore_configured_view, because "open showing what is configured"
# and "go back to showing what is configured after a list edit" are the same job. The row format
# and its hidden columns are documented on acp_agent_fill_table.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.select.external.agent.library.sh"

# Widths are NOT set here. The JSON owns them, because it is the only place that can express
# minWidths (there is no dialog-control verb for those) and a runtime
# omc_table_set_column_widths would silently overwrite the ideal widths while leaving the
# minimums behind, leaving the two halves of the sizing disagreeing with each other.
#
# These two names are never SEEN - the JSON hides the headers, so "Status" is a 20pt strip of
# check marks and crosses beside the agent name. The call still matters: the column COUNT is
# what decides how many of each row's four values get drawn, and the last two are the command
# and the id, which must stay hidden. Adding a name here reveals one of them.
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_columns "Agent" "Status"

agent_restore_configured_view $TABLE_ID

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
