#!/bin/sh
# aichat.mcp.inspect.refresh.sh
# Regenerates the effective config from the current prefs and re-runs the
# `mlx-agent tools` dump - so a change saved in Configure MCP Servers shows up
# here without reopening the window. The previous selection is cleared.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.inspect.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# reset_detail first so a populate failure/empty notice stays on the status line.
mcp_inspect_reset_detail "$window_uuid"
mcp_inspect_populate "$window_uuid"
