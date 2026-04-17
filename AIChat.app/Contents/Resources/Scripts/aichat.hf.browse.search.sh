#!/bin/bash
# aichat.hf.browse.search.sh
# Searches Hugging Face for GGUF models matching the query in the search field.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

TABLE_ID=202
STATUS_TEXT_ID=203
INFO_TEXT_ID=211
QUANT_TABLE_ID=213
DOWNLOAD_BTN_ID=222
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

query="$OMC_ACTIONUI_VIEW_201_VALUE"
sort_tag="$OMC_ACTIONUI_VIEW_204_VALUE"
echo "Search query: '$query'  Sort: '$sort_tag'"

case "$sort_tag" in
    trending) sort_param="trendingScore" ;;
    recent)   sort_param="lastModified"  ;;
    *)        sort_param="downloads"     ;;
esac

# Bail out early if the query hasn't changed since the table was last populated.
# The TextField fires on focus-lost even when nothing was typed, which would
# otherwise reload the table and lose the current row selection.
pb_last_query="hf_last_query_${window_uuid}"
last_query=$(pb_get "$pb_last_query")
if [ "$query" = "$last_query" ]; then
    echo "Query unchanged ('$query') — skipping reload"
    exit 0
fi

# Reset quant table and download button regardless
"$dialog_tool" "$window_uuid" $QUANT_TABLE_ID omc_table_remove_all_rows
"$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model to see details."
"$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable

if [ -z "$query" ]; then
    # Empty — reload list honouring the current sort picker selection
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.hf.browse.sort.changed"
    exit 0
fi

"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_remove_all_rows
"$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Searching for \"${query}\"…"

# Basic URL encoding: spaces to +, leave other chars (model names are usually safe)
encoded_query=$(printf '%s' "$query" | /usr/bin/sed 's/ /+/g')

tmp_json="/tmp/aichat_hf_search_$$.json"
http_code=$(/usr/bin/curl -fsSL \
    "https://huggingface.co/api/models?filter=gguf&search=${encoded_query}&sort=${sort_param}&direction=-1&limit=30" \
    -o "$tmp_json" -w "%{http_code}" 2>/dev/null)

if [ "$http_code" != "200" ] || [ ! -s "$tmp_json" ]; then
    echo "HF search API error: HTTP $http_code"
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Search failed (HTTP ${http_code}). Check your internet connection."
    rm -f "$tmp_json"
    exit 1
fi

count=$("$plister" get count "$tmp_json" /)
echo "Search results: $count"

buffer=""
i=0
while [ "$i" -lt "$count" ]; do
    repo_id=$("$plister" get value "$tmp_json" "/$i/id")
    downloads=$("$plister" get value "$tmp_json" "/$i/downloads" 2>/dev/null)

    model_name="${repo_id##*/}"

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
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "${count} results for \"${query}\""
else
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "No results for \"${query}\""
fi

pb_set "$pb_last_query" "$query"
rm -f "$tmp_json"
