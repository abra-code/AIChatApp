#!/bin/sh
# aichat.select.local.model.selection.changed.sh
# Updates the info pane and enables/disables Load Model when table selection changes.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"
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

    # Everything below is engine-dispatched through the model library, so the pane and the
    # list badge can never disagree about a model. Note size: a GGUF is one file, an MLX
    # model is a directory of shards - stat'ing the selection directly would report an MLX
    # model as a few hundred bytes (the directory entry), not the ~4-30GB it really is.
    engine=$(model_engine "$selected_path")

    # Delete only offers what it can actually do: aichat.select.local.model.delete.sh handles
    # a single .gguf FILE and exits on anything else, so leaving the button enabled for an MLX
    # row makes Delete a silent no-op. Disabling it says so honestly. Recursively deleting a
    # multi-GB model DIRECTORY is a destructive operation that deserves its own design (and
    # its own confirmation), not an incidental widening of a file-shaped handler.
    if [ "$engine" = "gguf" ]; then
        "$dialog_tool" "$window_uuid" $DELETE_BUTTON_ID omc_enable
    else
        "$dialog_tool" "$window_uuid" $DELETE_BUTTON_ID omc_disable
    fi
    filename=$(model_display_label "$selected_path")
    model_size=$(model_bytes "$selected_path" "$engine")
    size_gb=$(printf "%.2f" \
        "$(echo "scale=4; $model_size / (1024*1024*1024)" | /usr/bin/bc -l 2>/dev/null)")
    modified=$(/usr/bin/stat -f "%Sm" -L "$selected_path" 2>/dev/null)

    case "$engine" in
        gguf) engine_label="GGUF (llama-server)" ;;
        mlx)  engine_label="MLX (in-process)" ;;
        *)    engine_label="Unrecognised" ;;
    esac

    # Detect cache source
    case "$selected_path" in
        */Library/Application\ Support/AIChatV2/Models/*) source_label="Downloaded" ;;
        */.cache/huggingface/*)                         source_label="Hugging Face" ;;
        */.lmstudio/*)                                  source_label="LM Studio" ;;
        */.ollama/*)                                    source_label="Ollama" ;;
        */.localai/*)                                   source_label="LocalAI" ;;
        */Jan/data/models/*)                            source_label="Jan" ;;
        */nomic.ai/GPT4All/*)                           source_label="GPT4All" ;;
        *)                                              source_label="Local file" ;;
    esac

    if model_supports_tools "$selected_path" "$engine"; then
        tools_label="Supported"
        "$dialog_tool" "$window_uuid" $USE_TOOLS_TOGGLE_ID true
    else
        tools_label="Not detected"
        "$dialog_tool" "$window_uuid" $USE_TOOLS_TOGGLE_ID false
    fi

    br="  "
    info="**Model:**    ${filename}${br}
**Engine:**   ${engine_label}${br}
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
