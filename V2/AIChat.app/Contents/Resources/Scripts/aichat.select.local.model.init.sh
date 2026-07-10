#!/bin/bash
# aichat.select.local.model.init.sh
# Discovers local GGUF models and populates the model selector table.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

TABLE_ID=10
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Set table columns. Column 3 (path) is hidden — data has 3 tab-separated
# values per row but only 2 column headers are declared.
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_columns "Model" "Size"
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_column_widths 390 70
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_remove_all_rows

# Discover GGUF files in known local model caches.
# Build TSV rows: model_name \t size_string \t full_path
buffer=""
for cache_dir in \
    "$HOME/.cache/huggingface/hub" \
    "$HOME/.lmstudio/models" \
    "$HOME/.ollama/models" \
    "$HOME/.localai/models" \
    "$HOME/Library/Application Support/Jan/data/models" \
    "$HOME/Library/Application Support/nomic.ai/GPT4All"; do
    [ -d "$cache_dir" ] || continue
    found_paths=$(/usr/bin/find "$cache_dir" -name "*.gguf" 2>/dev/null | /usr/bin/sort)
    while IFS= read -r model_path; do
        [ -n "$model_path" ] || continue
        filename=$(/usr/bin/basename "$model_path" .gguf)
        file_size=$(/usr/bin/stat -f%z -L "$model_path" 2>/dev/null || echo 0)
        size_gb=$(printf "%.1f GB" \
            "$(echo "scale=4; $file_size / (1024*1024*1024)" | /usr/bin/bc -l 2>/dev/null)")
        buffer="${buffer}${filename}	${size_gb}	${model_path}
"
    done <<< "$found_paths"
done

# Append recently opened models that are not already in the cache results.
PREFS_DOMAIN="com.abracode.AIChatV2"
PREFS_KEY="recentModelPaths"
recent_paths=$(/usr/bin/defaults read "$PREFS_DOMAIN" "$PREFS_KEY" 2>/dev/null | \
    /usr/bin/grep -E '^\s+"' | \
    /usr/bin/sed 's/^[[:space:]]*"\(.*\)",\{0,1\}$/\1/')
while IFS= read -r recent_path; do
    [ -n "$recent_path" ] || continue
    [ -f "$recent_path" ] || continue  # skip paths that no longer exist
    case "$buffer" in
        *"$recent_path"*) continue ;;  # already present from cache discovery
    esac
    filename=$(/usr/bin/basename "$recent_path" .gguf)
    file_size=$(/usr/bin/stat -f%z -L "$recent_path" 2>/dev/null || echo 0)
    size_gb=$(printf "%.1f GB" \
        "$(echo "scale=4; $file_size / (1024*1024*1024)" | /usr/bin/bc -l 2>/dev/null)")
    buffer="${buffer}${filename}	${size_gb}	${recent_path}
"
done <<< "$recent_paths"

if [ -n "$buffer" ]; then
    printf "%s" "$buffer" | "$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_rows_from_stdin
fi
