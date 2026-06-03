#!/bin/sh
# aichat.mcp.servers.rw.remove.sh
# Removes the selected row from the additional read-write list.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
RW_TABLE_ID=320
RW_REMOVE_BTN_ID=322

selected="$OMC_ACTIONUI_TABLE_320_COLUMN_1_VALUE"
[ -z "$selected" ] && exit 0

mcp_prefs_array_remove_value servers/local/allowed-write "$selected"
mcp_refresh_path_table "$window_uuid" $RW_TABLE_ID servers/local/allowed-write
"$dialog" "$window_uuid" $RW_REMOVE_BTN_ID omc_disable
