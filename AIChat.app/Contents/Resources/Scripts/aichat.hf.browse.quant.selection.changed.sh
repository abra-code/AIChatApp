#!/bin/sh
# aichat.hf.browse.quant.selection.changed.sh
# Enables or disables the Download button based on whether a quantization is selected.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

DOWNLOAD_BTN_ID=222
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

selected_file="$OMC_ACTIONUI_TABLE_213_COLUMN_3_VALUE"
echo "Selected quant file: $selected_file"

if [ -n "$selected_file" ]; then
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_enable
else
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
fi
