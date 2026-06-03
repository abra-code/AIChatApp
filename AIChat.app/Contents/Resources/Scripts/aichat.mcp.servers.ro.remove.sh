#!/bin/sh
# aichat.mcp.servers.ro.remove.sh
# Removes the selected row from the additional read-only list.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
RO_TABLE_ID=330
RO_REMOVE_BTN_ID=332

selected="$OMC_ACTIONUI_TABLE_330_COLUMN_1_VALUE"
[ -z "$selected" ] && exit 0

mcp_prefs_array_remove_value servers/local/allowed-read "$selected"
mcp_refresh_path_table "$window_uuid" $RO_TABLE_ID servers/local/allowed-read
"$dialog" "$window_uuid" $RO_REMOVE_BTN_ID omc_disable
