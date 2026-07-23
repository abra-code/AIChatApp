#!/bin/bash
# aichat.hf.browse.init.sh
# Populates the browser table with the most-downloaded models for the current Source
# (Any | MLX | GGUF). The query + union logic lives in aichat.hf.browse.library.sh.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.hf.browse.library.sh"

echo "[$(/usr/bin/basename "$0")]"

TABLE_ID=202
STATUS_TEXT_ID=203
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_columns "Model" "Downloads"
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_column_widths 330 80
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_remove_all_rows
"$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Fetching trending models from Hugging Face…"

rows="$(hf_fetch_rows downloads -1 "")"
if [ $? -ne 0 ]; then
    echo "HF API error"
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Failed to fetch models. Check your internet connection."
    exit 1
fi

if [ -n "$rows" ]; then
    count="$(printf '%s\n' "$rows" | /usr/bin/grep -c .)"
    printf '%s\n' "$rows" | "$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_rows_from_stdin
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Showing top ${count} most downloaded $(hf_source_noun)models"
else
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "No models found"
fi

pb_set "hf_last_query_${window_uuid}" ""
