#!/bin/bash
# aichat.hf.browse.init.sh
# Fetches trending GGUF models from Hugging Face and populates the browser table.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

TABLE_ID=202
STATUS_TEXT_ID=203
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_columns "Model" "Downloads"
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_column_widths 330 80
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_remove_all_rows
"$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Fetching trending models from Hugging Face…"

tmp_json="/tmp/aichat_hf_trending_$$.json"
http_code=$(/usr/bin/curl -fsSL \
    "https://huggingface.co/api/models?filter=gguf&sort=downloads&direction=-1&limit=50" \
    -o "$tmp_json" -w "%{http_code}" 2>/dev/null)

if [ "$http_code" != "200" ] || [ ! -s "$tmp_json" ]; then
    echo "HF API error: HTTP $http_code"
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Failed to fetch models (HTTP ${http_code}). Check your internet connection."
    rm -f "$tmp_json"
    exit 1
fi

count=$("$plister" get count "$tmp_json" /)
echo "Trending GGUF models count: $count"

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
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "Showing top ${count} most downloaded GGUF models"
else
    "$dialog_tool" "$window_uuid" $STATUS_TEXT_ID "No models found"
fi

pb_set "hf_last_query_${window_uuid}" ""
rm -f "$tmp_json"
