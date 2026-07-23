#!/bin/sh
# aichat.mcp.inspect.init.sh
# Populates the MCP Servers inspector: generates the effective config from the current
# prefs and runs `mlx-agent tools` to capture the servers' real tool surface (see
# aichat.mcp.inspect.library.sh). Tools render when a server row is selected.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.inspect.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# reset_detail first so a populate failure/empty notice stays on the status line.
mcp_inspect_reset_detail "$window_uuid"
mcp_inspect_populate "$window_uuid"
