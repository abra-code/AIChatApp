#!/bin/sh
# aichat.mcp.servers.ro.selection.changed.sh
# Enables / disables the - button when the user picks (or clears) a row.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
RO_REMOVE_BTN_ID=332

if [ -n "$OMC_ACTIONUI_TABLE_330_COLUMN_1_VALUE" ]; then
    "$dialog" "$window_uuid" $RO_REMOVE_BTN_ID omc_enable
else
    "$dialog" "$window_uuid" $RO_REMOVE_BTN_ID omc_disable
fi
