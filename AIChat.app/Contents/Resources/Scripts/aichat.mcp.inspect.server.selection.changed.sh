#!/bin/sh
# aichat.mcp.inspect.server.selection.changed.sh
# A server row was (de)selected. Render its endpoint, lifecycle buttons, and tools
# via mcp_inspect_show_server. The hidden 3rd table column carries the full URL
# (see mcp_inspect_populate).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.inspect.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
url="$OMC_ACTIONUI_TABLE_200_COLUMN_3_VALUE"

mcp_inspect_show_server "$window_uuid" "$url"
