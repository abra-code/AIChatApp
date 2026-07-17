#!/bin/bash
# aichat.hf.browse.sort.changed.sh
# Re-fetches the model list when the sort picker changes, honouring the current Source
# (Any | MLX | GGUF). Has no effect while a search query is active (it re-runs the search).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.hf.browse.library.sh"

echo "[$(/usr/bin/basename "$0")]"

TABLE_ID=202
STATUS_TEXT_ID=203
INFO_TEXT_ID=211
QUANT_TABLE_ID=213
DOWNLOAD_BTN_ID=222
HF_LINK_ID=240
QUANT_LABEL_ID=212
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
PB_FORMAT="hf_model_format_${window_uuid}"

sort_tag="$OMC_ACTIONUI_VIEW_204_VALUE"
search_query="$OMC_ACTIONUI_VIEW_201_VALUE"

echo "Sort tag: '$sort_tag'  Search: '$search_query'  Source: '$(hf_source)'"

# If a search is active, re-run it with the new sort/source.
if [ -n "$search_query" ]; then
    echo "Search active — re-running search"
    pb_set "hf_last_query_${window_uuid}" ""
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.hf.browse.search"
    exit 0
fi

# Reset detail pane. Bumping the detail epoch invalidates any in-flight model.selection.changed
# fetch, and clearing the stashed format means a stale response cannot leave Download spuriously
# enabled for a repo that is no longer selected.
hf_detail_epoch_bump >/dev/null
pb_set "$PB_FORMAT" ""
"$dialog_tool" "$window_uuid" $QUANT_TABLE_ID omc_table_remove_all_rows
"$dialog_tool" "$window_uuid" $QUANT_LABEL_ID "Model Files"
"$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
"$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
"$dialog_tool" "$window_uuid" $HF_LINK_ID omc_hide

sort_param="$(hf_sort_param "$sort_tag")"
status_suffix="$(hf_sort_suffix "$sort_tag")"

"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_columns "Model" "Downloads"
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_column_widths 330 80
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_remove_all_rows
"$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Fetching ${status_suffix} $(hf_source_noun)models…"

rows="$(hf_fetch_rows "$sort_param" -1 "")"
if [ $? -ne 0 ]; then
    echo "HF API error"
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Failed to fetch models. Check your internet connection."
    exit 1
fi

if [ -n "$rows" ]; then
    count="$(printf '%s\n' "$rows" | /usr/bin/grep -c .)"
    printf '%s\n' "$rows" | "$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_rows_from_stdin
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Showing top ${count} ${status_suffix} $(hf_source_noun)models"
else
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "No models found"
fi

pb_set "hf_last_query_${window_uuid}" ""
