#!/bin/bash
# aichat.select.external.agent.ok.sh
# Stores the chosen agent, switches Cadabra onto it, and opens the chat.
#
# The COMMAND FIELD is what gets stored, not the selected row: the row only ever seeded the
# field, and everything after that - including the whole "Custom command" case - is the user
# editing it. Reading the row here instead would silently discard their edit.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.select.external.agent.library.sh"

# Cleaned, not raw. Two reasons, and the first is a real hole: a field holding nothing but
# spaces passes a plain -z test, so "   " would be stored as the command, split by shlex into
# no argv at all, and fail at launch instead of here. The second is that a saved agent's record
# is cleaned on the way in, so storing the raw value here would leave the record and the live
# command disagreeing over whitespace the user cannot see. acp_clean_one_line trims the ends
# and neutralizes tabs; it deliberately leaves interior runs alone, because spacing inside a
# quoted argument is part of the argument.
command_line=$(acp_clean_one_line "${OMC_ACTIONUI_VIEW_20_VALUE:-}")
# The agent the pane is showing. Pressing this button also takes focus off the Name field, which
# commits a pending rename in a SEPARATE handler that may still be running - so the selection is
# not a fixed thing during this script, and the pane owner is. An empty owner means no agent is
# on screen, or one is being painted; either way what gets stored is what is in the command
# field, under the bare "custom" id, which is exactly what that id means.
selected_id="$(agent_pane_owner)"
selected_id="${selected_id:-custom}"
# The Tools picker's tag: "true" (all servers), "readonly" (only servers with no gated
# tools), "false" (none). Validated rather than trusted - this value decides whether the MCP
# servers are handed to a third-party agent at all, so an unrecognized one falls back to the
# most restrictive setting instead of being passed through to a comparison it might match.
use_tools="${OMC_ACTIONUI_VIEW_30_VALUE:-false}"
case "$use_tools" in
    true|readonly|false) ;;
    *) echo "unrecognized tools setting '$use_tools', treating as off" >&2; use_tools="false" ;;
esac

if [ -z "$command_line" ]; then
    "$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Enter a command before continuing."
    exit 0
fi

# An edit that no longer matches the row it came from is a custom command, whatever row is
# highlighted. Getting this wrong would make the label lie: the model bar would say "opencode"
# over a session running something else entirely.
#
# A SAVED custom agent is exempt, because it OWNS its command: the record is the definition
# and the field is how you edit it, so an edit belongs in the record. Degrading "custom:3" to
# a bare "custom" here would throw away the name the user gave it and leave the agent named by
# a bare basename - the row would still be in the list, and committing it would silently
# stop being the thing that was committed.
# Cleaned on both sides of the comparison, so a difference that is only whitespace does not
# read as "the user edited this" and demote a perfectly good catalog row to an unnamed command.
#
# The row is only a valid reference for this test while it is the SAME agent the pane is
# showing. When the highlight and the pane disagree - which a repaint racing a rename can leave
# behind for a click or two - the command that seeded the field is not the one carried by the
# highlighted row, and comparing against it would answer a question nobody asked. Treat that as
# edited: an unnamed command is a truthful label for "we cannot show this came from a catalog
# row", where naming the highlighted agent would be a confident lie in the model bar.
row_id="${OMC_ACTIONUI_TABLE_10_COLUMN_4_VALUE:-}"
row_command=$(acp_clean_one_line "${OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE:-}")
case "$selected_id" in
    custom|custom:*) ;;
    *)
        if [ "$row_id" != "$selected_id" ] || [ "$command_line" != "$row_command" ]; then
            selected_id="custom"
        fi
        ;;
esac

# A saved agent's record is written FIRST, and its failure is not ignored. acp_custom_set
# returns non-zero for an id with no record behind it, which happens when the agent was deleted
# out from under this window - a second dialog, or the settings file edited by hand. Storing the
# id anyway would leave /agents/external/id naming a record that does not exist, and the window
# would open naming a bare basename for no reason the user could see. Falling back to the
# bare "custom" id says the true thing instead: a command with no record behind it.
# The NAME is committed here as well as the command - see agent_save_pane_edits, which every
# button that acts on the editor shares. Clicking a button need not blur the field it was typed
# into, so a name typed and then committed with this button would otherwise be dropped.
agent_save_pane_edits "$selected_id" "${OMC_ACTIONUI_VIEW_53_VALUE:-}" "$command_line"
case $? in
    1)  echo "no record for $selected_id - storing it as an unnamed command" >&2
        selected_id="custom"
        ;;
    2)  "$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Could not save this agent. Check that ~/Library/Application Support/Cadabra is writable."
        exit 0
        ;;
esac

acp_agent_store "$selected_id" "$command_line"

# Read back before committing to it. Every plister write in this path can fail SILENTLY - it
# exits 0 having written nothing when the settings file cannot be written - and the rest of this
# script closes the window and launches a chat. Without this check that chat would start on the
# PREVIOUS agent while the dialog reported success, which is the one outcome worse than an error.
if [ "$(acp_agent_stored_command)" != "$command_line" ]; then
    "$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Could not save this agent. Check that ~/Library/Application Support/Cadabra is writable."
    exit 0
fi
echo "external agent selected: $command_line (id=$selected_id, tools=$use_tools)"

# Same handoff the model picker uses. The launch queue carries the tools decision, which the
# transport needs at build time and cannot re-decide afterwards: it selects whether the MCP
# servers are handed to the agent in session/new. The model path slot is empty on purpose -
# an external agent brings its own model, and chat.init.sh ignores the picker's engine when
# the external agent is enabled.
launch_queue_arm "" "$use_tools"

"$dialog_tool" "$window_uuid" omc_window omc_terminate_ok

# Both tool settings go through the MCP servers step: "readonly" still needs the servers
# configured and probed, because the probe is what produces the gatedTools lists that decide
# which of them qualify as read-only.
case "$use_tools" in
    true|readonly) "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.mcp.servers" ;;
    *)             "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.chat" ;;
esac
