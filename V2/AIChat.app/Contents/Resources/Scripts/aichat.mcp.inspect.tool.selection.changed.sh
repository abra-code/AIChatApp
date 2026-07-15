#!/bin/sh
# aichat.mcp.inspect.tool.selection.changed.sh
# A tool row was (de)selected. Render its description and JSON input schema from the
# dump. The hidden 2nd table column carries the tool's index; the owning server's
# index was stashed on the pasteboard by the server-selection handler.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.inspect.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
tool_idx="$OMC_ACTIONUI_TABLE_300_COLUMN_2_VALUE"
srv_idx=$(pb_get "aichatv2_mcp_srv_${window_uuid}")

mcp_inspect_show_tool "$window_uuid" "$srv_idx" "$tool_idx"
