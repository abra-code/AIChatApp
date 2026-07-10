#!/bin/bash
# aichat.hf.browse.sort.changed.sh
# Re-fetches top models when the sort picker selection changes.
# Has no effect while a search query is active.
# The second column always shows download count regardless of sort mode —
# the sort tag only controls the ordering returned by the API.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

TABLE_ID=202
STATUS_TEXT_ID=203
INFO_TEXT_ID=211
QUANT_TABLE_ID=213
DOWNLOAD_BTN_ID=222
HF_LINK_ID=240
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

sort_tag="$OMC_ACTIONUI_VIEW_204_VALUE"
search_query="$OMC_ACTIONUI_VIEW_201_VALUE"

echo "Sort tag: '$sort_tag'  Search: '$search_query'"

# If a search is active, re-run it with the new sort order.
# Clear the pasteboard first so search.sh doesn't treat it as a no-op.
if [ -n "$search_query" ]; then
    echo "Search active — re-running search with new sort"
    pb_set "hf_last_query_${window_uuid}" ""
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.hf.browse.search"
    exit 0
fi

# Reset detail pane
"$dialog_tool" "$window_uuid" $QUANT_TABLE_ID omc_table_remove_all_rows
"$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
"$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
"$dialog_tool" "$window_uuid" $HF_LINK_ID omc_hide

case "$sort_tag" in
    trending)
        sort_param="trendingScore"
        direction="-1"
        status_suffix="trending"
        ;;
    recent)
        sort_param="lastModified"
        direction="-1"
        status_suffix="recently updated"
        ;;
    downloads|*)
        sort_param="downloads"
        direction="-1"
        status_suffix="most downloaded"
        ;;
esac

"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_columns "Model" "Downloads"
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_column_widths 330 80
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_remove_all_rows
"$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Fetching ${status_suffix} GGUF models…"

tmp_json="/tmp/aichatv2_hf_sort_$$.json"
http_code=$(/usr/bin/curl -fsSL \
    "https://huggingface.co/api/models?filter=gguf&sort=${sort_param}&direction=${direction}&limit=50" \
    -o "$tmp_json" -w "%{http_code}" 2>/dev/null)

if [ "$http_code" != "200" ] || [ ! -s "$tmp_json" ]; then
    echo "HF API error: HTTP $http_code"
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Failed to fetch models (HTTP ${http_code}). Check your internet connection."
    rm -f "$tmp_json"
    exit 1
fi

count=$("$plister" get count "$tmp_json" /)
echo "Results: $count"

buffer=""
i=0
while [ "$i" -lt "$count" ]; do
    repo_id=$("$plister" get value "$tmp_json" "/$i/id")
    model_name="${repo_id##*/}"

    downloads=$("$plister" get value "$tmp_json" "/$i/downloads" 2>/dev/null)
    if [ "$downloads" -ge 1000000 ] 2>/dev/null; then
        dl_fmt=$(printf "%.1fM" "$(echo "scale=1; $downloads/1000000" | /usr/bin/bc -l 2>/dev/null)")
    elif [ "$downloads" -ge 1000 ] 2>/dev/null; then
        dl_fmt=$(printf "%dK" "$(echo "scale=0; $downloads/1000" | /usr/bin/bc -l 2>/dev/null)")
    else
        dl_fmt="${downloads:-—}"
    fi

    buffer="${buffer}${model_name}	${dl_fmt}	${repo_id}
"
    i=$((i + 1))
done

if [ -n "$buffer" ]; then
    printf "%s" "$buffer" | "$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_rows_from_stdin
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Showing top ${count} ${status_suffix} GGUF models"
else
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "No models found"
fi

pb_set "hf_last_query_${window_uuid}" ""
rm -f "$tmp_json"
