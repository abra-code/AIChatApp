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

    # ── The on-device model is not a file, so most of this pane does not apply ────
    # No path to reveal, nothing to delete, no bytes to size, no date to stat, and nothing
    # to benchmark (`mlx-agent bench` measures MLX weights). Handled here and finished here
    # rather than threaded through every branch below as an exception.
    #
    # Load stays ENABLED even when the model is unavailable: pressing it is how the user
    # reaches the explanation and the Settings hop (see the ok handler). A disabled button
    # with an unusable row would state the problem and offer no way out of it.
    if [ "$engine" = "foundation" ]; then
        # Disable BEFORE probing, not after. Reveal was enabled unconditionally at the top of
        # this block, and foundation_probe spawns a subprocess - so probing first leaves Reveal
        # live for its duration with the sentinel already in the hidden column. `open -R` on a
        # non-path is only a silent no-op, but the window is real and closing it costs nothing.
        "$dialog_tool" "$window_uuid" $REVEAL_BUTTON_ID omc_disable
        "$dialog_tool" "$window_uuid" $DELETE_BUTTON_ID omc_disable
        "$dialog_tool" "$window_uuid" $BENCH_BTN_ID omc_disable

        probe=$(foundation_probe)
        reason=$(printf '%s' "$probe" | /usr/bin/cut -f1)
        summary=$(printf '%s' "$probe" | /usr/bin/cut -f2)
        # The window the agent actually reported. Present only when the model is available -
        # the agent answers and returns before it can read a context size on every other path -
        # so the rows built from it are OMITTED rather than filled with a plausible number we
        # did not measure. Printing "Context: 4096 tokens" beside "Apple Intelligence is
        # switched off" would be the exact lie this stopped hardcoding to avoid.
        window=$(printf '%s' "$probe" | /usr/bin/cut -f3)
        case "$window" in *[!0-9]*) window="" ;; esac
        # Same rule as the window: present only when the agent got far enough to measure them,
        # omitted rather than guessed. `locale_ok` is yes/no/empty, `langs` a space-joined list.
        locale_ok=$(printf '%s' "$probe" | /usr/bin/cut -f4)
        langs=$(printf '%s' "$probe" | /usr/bin/cut -f5)

        "$dialog_tool" "$window_uuid" $BENCH_TEXT_ID \
            "Benchmarking measures a model this Mac loads. The on-device model belongs to the system, so there is nothing here to measure."

        # Tools OFF by default, though the engine supports them. Every tool definition is
        # spent from the SAME small window the conversation lives in - a handful of MCP
        # servers can take a third of it before a word is typed. Defaulting this on (as the
        # other engines do, where the window is 32k and up) would quietly make the first
        # conversation the worst one. The toggle is left to the user, and the pane says what
        # it costs whenever it knows the number.
        "$dialog_tool" "$window_uuid" $USE_TOOLS_TOGGLE_ID false

        if [ "$reason" = "available" ]; then
            status_line="Ready"
        else
            status_line="$summary"
        fi

        br="  "
        info="**Model:**    Apple Foundation Models${br}
**Engine:**   Foundation Models (on device)${br}
**Status:**   ${status_line}${br}
**Size:**     none - part of macOS, nothing to download${br}"
        if [ -n "$window" ]; then
            info="${info}
**Context:**  ${window} tokens${br}
**Tools:**    Supported, but they are spent from that same ${window}-token window${br}"
        else
            info="${info}
**Tools:**    Supported, but they are spent from the same window the conversation lives in${br}"
        fi

        # The label column is one wider than the rows above it - "Languages:" is already as
        # long as their padded field. Spelling it "Langs:" would keep the column and cost the
        # reader more than the column is worth.
        # The count is derived from the list rather than read off the agent's `languages: N
        # distinct` line so the two cannot disagree. Safe because the agent emits the whole code
        # list with a SINGLE print, so the captured line is never wrapped or partial - if that
        # ever changes, scrape the count separately instead of counting a truncated list.
        if [ -n "$langs" ]; then
            lang_count=$(printf '%s' "$langs" | /usr/bin/wc -w | /usr/bin/tr -d ' ')
            info="${info}
**Languages:** ${lang_count} supported: ${langs}${br}"
        fi

        # The warning is prose at the bottom rather than a field, because it is the one thing
        # here that changes what the user should DO, and the fields above are all facts.
        # Only when the agent actually measured a `no` - an empty locale_ok means it never got
        # far enough to say, and inventing a reassurance would be worse than saying nothing.
        # Worded to STAND ALONE rather than referring back to the Languages row: an empty
        # language list and an unsupported locale are correlated (a model reporting no
        # languages supports no locale), so "not one of them" could point at a row that was
        # never rendered. Separated from the closing advice by a blank line, not a ${br} hard
        # break, so the one sentence here that changes what the user should do does not render
        # as another line of the same generic paragraph.
        warn=""
        if [ "$locale_ok" = "no" ]; then
            warn="The on-device model does not support your current locale. It does not refuse an unsupported language - it answers in English, or answers in the requested language with confident nonsense, or stops mid-reply with what reads as a safety refusal. Prefer an MLX or GGUF model for work in your own language.

"
        fi

        gap=$(printf '\342\240\200')
        info="${info}${br}
${gap}${br}
${warn}Best for short, bounded work - quick questions, summaries, rewriting. For long conversations, large documents or a real tool surface, load an MLX or GGUF model instead."

        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID markdown "$info"
        pb_set "aichatv2_selected_model_${window_uuid}" "$selected_path"
        exit 0
    fi

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
