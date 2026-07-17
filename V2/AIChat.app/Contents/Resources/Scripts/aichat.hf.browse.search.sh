#!/bin/bash
# aichat.hf.browse.search.sh
# Searches Hugging Face for models matching the query, honouring the current Source
# (Any | MLX | GGUF). Shared query logic lives in aichat.hf.browse.library.sh.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.hf.browse.library.sh"

echo "[$(/usr/bin/basename "$0")]"

TABLE_ID=202
STATUS_TEXT_ID=203
INFO_TEXT_ID=211
QUANT_TABLE_ID=213
QUANT_LABEL_ID=212
DOWNLOAD_BTN_ID=222
HF_LINK_ID=240
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
PB_FORMAT="hf_model_format_${window_uuid}"

query="$OMC_ACTIONUI_VIEW_201_VALUE"
sort_tag="$OMC_ACTIONUI_VIEW_204_VALUE"
echo "Search query: '$query'  Sort: '$sort_tag'  Source: '$(hf_source)'"

sort_param="$(hf_sort_param "$sort_tag")"

# Bail out early if the query hasn't changed since the table was last populated. The TextField
# fires on focus-lost even when nothing was typed, which would otherwise reload the table and
# lose the current row selection.
pb_last_query="hf_last_query_${window_uuid}"
last_query="$(pb_get "$pb_last_query")"
if [ "$query" = "$last_query" ]; then
    echo "Query unchanged ('$query') — skipping reload"
    exit 0
fi

# Reset quant table and download button regardless. Bump the detail epoch (invalidate any
# in-flight model.selection fetch) and clear the stashed format so a stale response cannot
# leave Download spuriously enabled.
hf_detail_epoch_bump >/dev/null
pb_set "$PB_FORMAT" ""
"$dialog_tool" "$window_uuid" $QUANT_TABLE_ID omc_table_remove_all_rows
"$dialog_tool" "$window_uuid" $QUANT_LABEL_ID "Model Files"
"$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model to see details."
"$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
"$dialog_tool" "$window_uuid" $HF_LINK_ID omc_hide

if [ -z "$query" ]; then
    # Empty — reload list honouring the current sort/source picker.
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.hf.browse.sort.changed"
    exit 0
fi

"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_remove_all_rows
"$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Searching for \"${query}\"…"

rows="$(hf_fetch_rows "$sort_param" -1 "$query")"
if [ $? -ne 0 ]; then
    echo "HF search API error"
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Search failed. Check your internet connection."
    exit 1
fi

if [ -n "$rows" ]; then
    count="$(printf '%s\n' "$rows" | /usr/bin/grep -c .)"
    printf '%s\n' "$rows" | "$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_rows_from_stdin
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "${count} results for \"${query}\""
else
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "No results for \"${query}\""
fi

pb_set "$pb_last_query" "$query"
