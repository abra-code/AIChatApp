#!/bin/sh
# aichat.mcp.servers.rw.selection.changed.sh
# Enables / disables the - button when the user picks (or clears) a row.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
RW_REMOVE_BTN_ID=322

if [ -n "$OMC_ACTIONUI_TABLE_320_COLUMN_1_VALUE" ]; then
    "$dialog" "$window_uuid" $RW_REMOVE_BTN_ID omc_enable
else
    "$dialog" "$window_uuid" $RW_REMOVE_BTN_ID omc_disable
fi
