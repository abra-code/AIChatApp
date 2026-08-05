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
BENCH_TEXT_ID=50
BENCH_BTN_ID=51

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

    # Delete offers exactly what the handler can do, which is now both engines
    # (aichat.select.local.model.delete.sh dispatches on engine: a .gguf FILE, or an MLX model
    # DIRECTORY with its Hugging Face blobs). An unrecognised path stays disabled - that is the
    # "listed but since deleted or replaced" case, where there is nothing to offer.
    case "$engine" in
        gguf|mlx) "$dialog_tool" "$window_uuid" $DELETE_BUTTON_ID omc_enable ;;
        *)        "$dialog_tool" "$window_uuid" $DELETE_BUTTON_ID omc_disable ;;
    esac
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
        */Library/Application\ Support/Cadabra/Models/*) source_label="Downloaded" ;;
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

    # ── Benchmark pane ────────────────────────────────────────────────────────
    # Remember the selection so the benchmark handler only repaints the pane if the user
    # is still looking at the model it measured (runs take minutes).
    pb_set "aichatv2_selected_model_${window_uuid}" "$selected_path"
    bench_db="$HOME/Library/Application Support/Cadabra/benchmarks.json"
    bench_text=""
    if [ -f "$bench_db" ]; then
        bench_text=$("$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3" \
            "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.bench.py" \
            lookup --db "$bench_db" --label "$filename" --model "$selected_path" 2>/dev/null)
    fi
    if [ -n "$bench_text" ]; then
        "$dialog_tool" "$window_uuid" $BENCH_TEXT_ID markdown "$bench_text"
    else
        "$dialog_tool" "$window_uuid" $BENCH_TEXT_ID "No benchmark recorded for this model on this Mac. Run one to measure prefill and generation speed."
    fi
    # Leave the button alone while a run is in flight (the handler re-enables it). The
    # stamp is "path|epoch"; treat an old one as dead (SIGKILL'd handler) - same TTL as
    # the benchmark handler, else a wedged stamp would keep the button disabled forever.
    bench_running=$(pb_get "aichatv2_bench_running_${window_uuid}")
    bench_epoch="${bench_running##*|}"
    case "$bench_epoch" in *[!0-9]*|"") bench_epoch=0 ;; esac
    if [ -z "$bench_running" ] || [ $(( $(/bin/date +%s) - bench_epoch )) -gt 7200 ]; then
        "$dialog_tool" "$window_uuid" $BENCH_BTN_ID omc_enable
    fi
else
    pb_set "aichatv2_selected_model_${window_uuid}" ""
    "$dialog_tool" "$window_uuid" $LOAD_BUTTON_ID omc_disable
    "$dialog_tool" "$window_uuid" $REVEAL_BUTTON_ID omc_disable
    "$dialog_tool" "$window_uuid" $DELETE_BUTTON_ID omc_disable
    "$dialog_tool" "$window_uuid" $BENCH_BTN_ID omc_disable
    "$dialog_tool" "$window_uuid" $BENCH_TEXT_ID "Select a model from the list."
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
fi
