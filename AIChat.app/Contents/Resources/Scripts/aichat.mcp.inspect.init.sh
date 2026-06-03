#!/bin/sh
# aichat.mcp.inspect.init.sh
# Populates the MCP Servers inspector: lists the current session's servers with
# their endpoints and Running/Stopped status. Tools are loaded lazily when a
# server row is selected (see aichat.mcp.inspect.server.selection.changed).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.inspect.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# reset_detail first so a "no servers" notice from populate stays on the status line.
mcp_inspect_reset_detail "$window_uuid"
mcp_inspect_populate "$window_uuid"
