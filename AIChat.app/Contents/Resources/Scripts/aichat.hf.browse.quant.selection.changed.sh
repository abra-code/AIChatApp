#!/bin/sh
# aichat.hf.browse.quant.selection.changed.sh
# Enables or disables the Download button based on whether a quantization is selected,
# and explains the selected quant (Q4_K_M, IQ4_XS, UD-Q4_K_XL, …) in the info text
# below the quant table.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.glossary.library.sh"

echo "[$(/usr/bin/basename "$0")]"

DOWNLOAD_BTN_ID=222
QUANT_INFO_ID=214
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

selected_file="$OMC_ACTIONUI_TABLE_213_COLUMN_3_VALUE"
echo "Selected quant file: $selected_file"

if [ -n "$selected_file" ]; then
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_enable
    quant_info=$(decode_quant_acronyms "$selected_file")
    if [ -n "$quant_info" ]; then
        "$dialog_tool" "$window_uuid" $QUANT_INFO_ID markdown "$quant_info"
    else
        "$dialog_tool" "$window_uuid" $QUANT_INFO_ID ""
    fi
else
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
    "$dialog_tool" "$window_uuid" $QUANT_INFO_ID ""
fi
