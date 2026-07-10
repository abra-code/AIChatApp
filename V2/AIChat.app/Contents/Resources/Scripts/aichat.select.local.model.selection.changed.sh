#!/bin/sh
# aichat.select.local.model.selection.changed.sh
# Updates the info pane and enables/disables Load Model when table selection changes.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.glossary.library.sh"

TABLE_ID=10
INFO_TEXT_ID=12
LOAD_BUTTON_ID=3
REVEAL_BUTTON_ID=20
DELETE_BUTTON_ID=24
USE_TOOLS_TOGGLE_ID=30

dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Column 3 (hidden) holds the full model path
selected_path="$OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE"

if [ -n "$selected_path" ]; then
    "$dialog_tool" "$window_uuid" $LOAD_BUTTON_ID omc_enable
    "$dialog_tool" "$window_uuid" $REVEAL_BUTTON_ID omc_enable
    "$dialog_tool" "$window_uuid" $DELETE_BUTTON_ID omc_enable

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

    python3="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
    check_script="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/gguf_check_tools.py"
    supports_tools=$("$python3" "$check_script" "$selected_path" 2>/dev/null)
    if [ "$supports_tools" = "true" ]; then
        tools_label="Supported"
        "$dialog_tool" "$window_uuid" $USE_TOOLS_TOGGLE_ID true
    else
        tools_label="Not detected"
        "$dialog_tool" "$window_uuid" $USE_TOOLS_TOGGLE_ID false
    fi

    br="  "
    info="**File:**     ${filename}${br}
**Size:**     ${size_gb} GB${br}
**Tools:**    ${tools_label}${br}
**Source:**   ${source_label}${br}
**Modified:** ${modified}${br}
**Path:**     ${selected_path}${br}"

    # Decode the acronyms in the filename (size, quant, Instruct, context, …).
    # Separate with a blank-looking gap line. A real blank line can't be used: this
    # SwiftUI markdown renderer (.full mode) treats it as a paragraph break, drops
    # the trailing hard break and glues the decoder onto the path. A U+2800 (Braille
    # blank) keeps the line non-empty so it stays in the same paragraph and renders
    # as a visible gap, while the two-space hard breaks give the line breaks.
    glossary=$(decode_model_acronyms "$filename")
    if [ -n "$glossary" ]; then
        gap=$(printf '\342\240\200')
        info="${info}${br}
${gap}${br}
${glossary}"
    fi

    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID markdown "$info"
else
    "$dialog_tool" "$window_uuid" $LOAD_BUTTON_ID omc_disable
    "$dialog_tool" "$window_uuid" $REVEAL_BUTTON_ID omc_disable
    "$dialog_tool" "$window_uuid" $DELETE_BUTTON_ID omc_disable
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
fi
