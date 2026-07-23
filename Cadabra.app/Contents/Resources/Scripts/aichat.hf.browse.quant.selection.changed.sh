#!/bin/sh
# aichat.hf.browse.quant.selection.changed.sh
# Fires when a row in table 213 is selected. Behaviour depends on the selected model's format
# (stashed by model.selection.changed):
#   GGUF - table 213 is a list of quant FILES; selecting one enables Download and explains the
#          quant (Q4_K_M, IQ4_XS, …) below the table.
#   MLX  - table 213 is a display-only file manifest (the whole repo downloads together), so
#          this is a no-op: Download was already enabled per-repo on model selection and must
#          stay enabled regardless of which file row the user clicks.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.glossary.library.sh"

echo "[$(/usr/bin/basename "$0")]"

DOWNLOAD_BTN_ID=222
QUANT_INFO_ID=214
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

fmt="$(pb_get "hf_model_format_${window_uuid}")"

# MLX (or unknown): the repo downloads whole; leave Download as model.selection.changed set it.
if [ "$fmt" != "gguf" ]; then
    echo "Non-GGUF format ('$fmt') — file-row selection is a no-op"
    exit 0
fi

selected_file="$OMC_ACTIONUI_TABLE_213_COLUMN_3_VALUE"
echo "Selected quant file: $selected_file"

if [ -n "$selected_file" ]; then
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_enable
    quant_info="$(decode_quant_acronyms "$selected_file")"
    if [ -n "$quant_info" ]; then
        "$dialog_tool" "$window_uuid" $QUANT_INFO_ID markdown "$quant_info"
    else
        "$dialog_tool" "$window_uuid" $QUANT_INFO_ID ""
    fi
else
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
    "$dialog_tool" "$window_uuid" $QUANT_INFO_ID ""
fi
