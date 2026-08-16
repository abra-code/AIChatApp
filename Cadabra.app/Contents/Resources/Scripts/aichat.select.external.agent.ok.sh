#!/bin/bash
# aichat.select.external.agent.ok.sh
# Stores the chosen agent, switches Cadabra onto it, and opens the chat.
#
# The COMMAND FIELD is what gets stored, not the selected row: the row only ever seeded the
# field, and everything after that - including the whole "Custom command" case - is the user
# editing it. Reading the row here instead would silently discard their edit.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh"

dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
RESULT_TEXT_ID=24

command_line="${OMC_ACTIONUI_VIEW_20_VALUE:-}"
selected_id="${OMC_ACTIONUI_TABLE_10_COLUMN_4_VALUE:-custom}"
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
# highlighted. Getting this wrong would make the label lie: the window would say "opencode"
# over a session running something else entirely.
row_command="${OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE:-}"
if [ "$selected_id" != "custom" ] && [ "$command_line" != "$row_command" ]; then
    selected_id="custom"
fi

acp_agent_store "$selected_id" "$command_line"
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
