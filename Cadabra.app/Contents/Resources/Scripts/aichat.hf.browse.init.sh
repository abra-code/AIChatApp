#!/bin/bash
# aichat.hf.browse.init.sh
# Populates the browser table with the most-downloaded models for the current Source
# (Any | MLX | GGUF). The query + union logic lives in aichat.hf.browse.library.sh.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.hf.browse.library.sh"

echo "[$(/usr/bin/basename "$0")]"

TABLE_ID=202
STATUS_TEXT_ID=203
INFO_TEXT_ID=211
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Take ownership of the arm launch leaves when it opens this window because the Mac has no
# model installed (see Cadabra.main.sh), moving it into this window's scope so that closing
# THIS browser is what hands back to the model picker. A no-op when the window was opened from
# the menu, which is the ordinary case.
#
# Before the fetch, and deliberately: the network is the slow, failing part of this script, and
# a user who arrived here because they have nothing installed still needs the window to explain
# itself and still needs the handoff when they close it.
hf_first_run_capture "$window_uuid"
if [ $? -eq 0 ]; then
    # Replaces the pane's "Select a model from the list." - true, but not an answer to the
    # question a user who never asked for this window is actually holding.
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "No models are installed on this Mac yet.

Pick a model on the left, choose a quantization if it offers one, and click Download.

When it finishes, close this window - the Local Models list opens with your new model in it."
fi

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
