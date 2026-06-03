#!/bin/sh
# aichat.mcp.inspect.refresh.sh
# Re-probes the current session's servers, repopulates the server list, and
# resets the detail panes (the previous selection is cleared by the reload).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.inspect.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# reset_detail first so a "no servers" notice from populate stays on the status line.
mcp_inspect_reset_detail "$window_uuid"
mcp_inspect_populate "$window_uuid"
