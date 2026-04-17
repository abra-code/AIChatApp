#!/bin/sh
# aichat.select.local.model.selection.changed.sh
# Updates the info pane and enables/disables Load Model when table selection changes.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

TABLE_ID=10
INFO_TEXT_ID=12
LOAD_BUTTON_ID=3
REVEAL_BUTTON_ID=20

dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Column 3 (hidden) holds the full model path
selected_path="$OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE"

if [ -n "$selected_path" ]; then
    "$dialog_tool" "$window_uuid" $LOAD_BUTTON_ID omc_enable
    "$dialog_tool" "$window_uuid" $REVEAL_BUTTON_ID omc_enable

    filename=$(/usr/bin/basename "$selected_path")
    file_size=$(/usr/bin/stat -f%z -L "$selected_path" 2>/dev/null || echo 0)
    size_gb=$(printf "%.2f" \
        "$(echo "scale=4; $file_size / (1024*1024*1024)" | /usr/bin/bc -l 2>/dev/null)")
    modified=$(/usr/bin/stat -f "%Sm" -L "$selected_path" 2>/dev/null)
    parent=$(/usr/bin/dirname "$selected_path")

    # Detect cache source
    case "$selected_path" in
        */.cache/huggingface/*)                         source_label="Hugging Face" ;;
        */.lmstudio/*)                                  source_label="LM Studio" ;;
        */.ollama/*)                                    source_label="Ollama" ;;
        */.localai/*)                                   source_label="LocalAI" ;;
        */Jan/data/models/*)                            source_label="Jan" ;;
        */nomic.ai/GPT4All/*)                           source_label="GPT4All" ;;
        *)                                              source_label="Local file" ;;
    esac

    info="File:     ${filename}
Size:     ${size_gb} GB
Source:   ${source_label}
Modified: ${modified}
Path:     ${selected_path}"

    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "$info"
else
    "$dialog_tool" "$window_uuid" $LOAD_BUTTON_ID omc_disable
    "$dialog_tool" "$window_uuid" $REVEAL_BUTTON_ID omc_disable
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
fi
