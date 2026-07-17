#!/bin/bash
# aichat.hf.browse.model.selection.changed.sh
# Fetches model detail from Hugging Face and fills the info pane, then branches by the repo's
# actual on-disk format so the browser works for both engines and in "Any" mode:
#   GGUF repo (has *.gguf files)      -> table 213 lists the quant FILES; pick one to download.
#   MLX repo (config.json + *.safetensors) -> table 213 is a display-only FILE MANIFEST and the
#                                        whole repo downloads as one directory.
# The detected format is stashed (hf_model_format_<win>) for quant.selection.changed / download.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.hf.browse.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.glossary.library.sh"

echo "[$(/usr/bin/basename "$0")]"

MODEL_TABLE_ID=202
QUANT_TABLE_ID=213
QUANT_LABEL_ID=212
INFO_TEXT_ID=211
QUANT_INFO_ID=214
DOWNLOAD_BTN_ID=222
HF_LINK_ID=240
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
PB_FORMAT="hf_model_format_${window_uuid}"

repo_id="$OMC_ACTIONUI_TABLE_202_COLUMN_3_VALUE"
echo "Selected repo: $repo_id"

if [ -z "$repo_id" ]; then
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
    "$dialog_tool" "$window_uuid" $QUANT_TABLE_ID omc_table_remove_all_rows
    "$dialog_tool" "$window_uuid" $QUANT_INFO_ID ""
    "$dialog_tool" "$window_uuid" $HF_LINK_ID omc_hide
    pb_set "$PB_FORMAT" ""
    hf_detail_epoch_bump >/dev/null
    exit 0
fi

# Reset detail while loading
"$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
"$dialog_tool" "$window_uuid" $QUANT_TABLE_ID omc_table_remove_all_rows
"$dialog_tool" "$window_uuid" $QUANT_INFO_ID ""
"$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Loading model info…"

# Claim the latest detail epoch. The ?blobs=true fetch below can take seconds; if a later
# selection or a list reload (sort/search/source) bumps the epoch meanwhile, our results are
# stale and we drop them instead of repopulating the detail pane for a no-longer-shown repo.
detail_epoch="$(hf_detail_epoch_bump)"

tmp_json="/tmp/aichatv2_hf_model_$$.json"
http_code="$(/usr/bin/curl -fsSL \
    "https://huggingface.co/api/models/${repo_id}?blobs=true" \
    -o "$tmp_json" -w '%{http_code}' 2>/dev/null)"

if [ "$http_code" != "200" ] || [ ! -s "$tmp_json" ]; then
    echo "HF model API error: HTTP $http_code"
    if [ "$(hf_detail_epoch_get)" = "$detail_epoch" ]; then
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Failed to load model info (HTTP ${http_code})."
    fi
    rm -f "$tmp_json"
    exit 1
fi

if [ "$(hf_detail_epoch_get)" != "$detail_epoch" ]; then
    echo "Selection superseded (epoch changed) — dropping stale results"
    rm -f "$tmp_json"
    exit 0
fi

# ── Info pane (identical for both formats) ────────────────────────────────────
model_id="$("$plister" get value "$tmp_json" /id 2>/dev/null)"
downloads="$("$plister" get value "$tmp_json" /downloads 2>/dev/null)"
likes="$("$plister" get value "$tmp_json" /likes 2>/dev/null)"
pipeline_tag="$("$plister" get value "$tmp_json" /pipeline_tag 2>/dev/null)"

if [ "$downloads" -ge 1000000 ] 2>/dev/null; then
    dl_fmt="$(printf "%.1fM" "$(echo "scale=1; $downloads/1000000" | /usr/bin/bc -l 2>/dev/null)")"
elif [ "$downloads" -ge 1000 ] 2>/dev/null; then
    dl_fmt="$(printf "%dK" "$(echo "scale=0; $downloads/1000" | /usr/bin/bc -l 2>/dev/null)")"
else
    dl_fmt="${downloads:-—}"
fi

info_text="**Model:**      ${model_id:-${repo_id}}  "
[ -n "$pipeline_tag" ] && info_text="${info_text}
**Task:**       ${pipeline_tag}  "
info_text="${info_text}
**Downloads:**  ${dl_fmt}
**Likes:**      ${likes:-—}  "

"$plister" get type "$tmp_json" /cardData > /dev/null 2>&1
if [ $? -eq 0 ]; then
    description="$("$plister" get value "$tmp_json" /cardData/model-description 2>/dev/null)"
    [ -z "$description" ] && description="$("$plister" get value "$tmp_json" /cardData/description 2>/dev/null)"
    if [ -n "$description" ]; then
        description="$(printf '%s' "$description" | /usr/bin/cut -c1-400)"
        info_text="${info_text}

${description}"
    fi
fi

# Decode the acronyms in the model name (size, Instruct, MoE, reasoning, …). A U+2800 (Braille
# blank) gap line keeps the decoder in the same markdown paragraph as a visible gap.
br="  "
glossary="$(decode_model_acronyms "${model_id##*/}")"
if [ -n "$glossary" ]; then
    gap="$(printf '\342\240\200')"
    info_text="${info_text}${br}
${gap}${br}
${glossary}"
fi

"$dialog_tool" "$window_uuid" $INFO_TEXT_ID markdown "$info_text"
"$dialog_tool" "$window_uuid" $HF_LINK_ID omc_set_property "url" "https://huggingface.co/${repo_id}"
"$dialog_tool" "$window_uuid" $HF_LINK_ID omc_show

# ── Detect format from the repo's files ───────────────────────────────────────
# Primary signal is what the repo actually contains; the Source picker only breaks a tie for a
# repo that ships BOTH (rare). GGUF wins ties under "Any"/"GGUF" (lets the user pick a quant),
# MLX under "MLX".
sib_count="$("$plister" get count "$tmp_json" /siblings 2>/dev/null)"
has_gguf=0
has_config=0
has_weights=0
j=0
while [ "$j" -lt "$sib_count" ]; do
    fname="$("$plister" get value "$tmp_json" "/siblings/$j/rfilename" 2>/dev/null)"
    case "$fname" in
        *.gguf) has_gguf=1 ;;
        config.json) has_config=1 ;;
        *.safetensors) has_weights=1 ;;
    esac
    j=$((j + 1))
done
has_mlx=0
[ "$has_config" = 1 ] && [ "$has_weights" = 1 ] && has_mlx=1

source_sel="$(hf_source)"
fmt="none"
case "$source_sel" in
    gguf) [ "$has_gguf" = 1 ] && fmt="gguf" ;;
    mlx)  [ "$has_mlx" = 1 ] && fmt="mlx" ;;
    *)    if [ "$has_gguf" = 1 ]; then fmt="gguf"; elif [ "$has_mlx" = 1 ]; then fmt="mlx"; fi ;;
esac
echo "Detected format: $fmt (gguf=$has_gguf mlx=$has_mlx source=$source_sel)"
pb_set "$PB_FORMAT" "$fmt"

# ── GGUF: list quant files; Download is per-file (enabled by quant.selection.changed) ─────────
if [ "$fmt" = "gguf" ]; then
    "$dialog_tool" "$window_uuid" $QUANT_LABEL_ID "Select Quantization"
    "$dialog_tool" "$window_uuid" $QUANT_INFO_ID "Select quantization for model information"
    buf2=""
    j=0
    while [ "$j" -lt "$sib_count" ]; do
        fname="$("$plister" get value "$tmp_json" "/siblings/$j/rfilename" 2>/dev/null)"
        case "$fname" in
            *.gguf)
                # Skip multimodal projector files (mmproj-*.gguf): vision-encoder bridges that
                # cannot load as standalone models.
                case "${fname##*/}" in mmproj-*) j=$((j + 1)); continue ;; esac
                # Split GGUFs: keep the first part (-00001-of-N), skip the rest.
                if echo "$fname" | /usr/bin/grep -qE -- '-[0-9]+-of-[0-9]+\.gguf$'; then
                    if ! echo "$fname" | /usr/bin/grep -qE -- '-00001-of-[0-9]+\.gguf$'; then
                        j=$((j + 1))
                        continue
                    fi
                    total_parts="$(echo "$fname" | /usr/bin/grep -oE -- '-of-([0-9]+)\.gguf$' | /usr/bin/grep -oE '[0-9]+')"
                    display_name="${fname} (${total_parts} parts)"
                else
                    display_name="$fname"
                fi
                fsize="$("$plister" get value "$tmp_json" "/siblings/$j/size" 2>/dev/null)"
                if [ -n "$fsize" ] && [ "$fsize" -gt 0 ] 2>/dev/null; then
                    size_disp="$(printf "%.1f GB" "$(echo "scale=4; $fsize/1073741824" | /usr/bin/bc -l 2>/dev/null)")"
                else
                    size_disp="? GB"
                fi
                buf2="${buf2}${display_name}	${size_disp}	${fname}
"
                ;;
        esac
        j=$((j + 1))
    done
    if [ -n "$buf2" ]; then
        printf "%s" "$buf2" | "$dialog_tool" "$window_uuid" $QUANT_TABLE_ID omc_table_set_rows_from_stdin
        echo "Populated quant table"
    fi
    rm -f "$tmp_json"
    exit 0
fi

# ── MLX: display-only file manifest; Download acts on the whole repo (enabled now) ────────────
if [ "$fmt" = "mlx" ]; then
    "$dialog_tool" "$window_uuid" $QUANT_LABEL_ID "Model Files"
    buf2=""
    j=0
    weights_bytes=0
    while [ "$j" -lt "$sib_count" ]; do
        fname="$("$plister" get value "$tmp_json" "/siblings/$j/rfilename" 2>/dev/null)"
        fsize="$("$plister" get value "$tmp_json" "/siblings/$j/size" 2>/dev/null)"
        [ -n "$fsize" ] && [ "$fsize" -gt 0 ] 2>/dev/null || fsize=0
        case "${fname##*/}" in ""|.gitattributes) j=$((j + 1)); continue ;; esac
        case "$fname" in *.safetensors) weights_bytes=$((weights_bytes + fsize)) ;; esac
        if [ "$fsize" -gt 0 ]; then
            size_disp="$(format_bytes "$fsize")"
        else
            size_disp="—"
        fi
        # Col 3 mirrors the path only to satisfy the 3-column shape; the manifest is display-only
        # (download.sh re-fetches the tree from the repo id), so the row-selection handler no-ops.
        buf2="${buf2}${fname}	${size_disp}	${fname}
"
        j=$((j + 1))
    done
    if [ -n "$buf2" ]; then
        printf "%s" "$buf2" | "$dialog_tool" "$window_uuid" $QUANT_TABLE_ID omc_table_set_rows_from_stdin
    fi
    weights_fmt="$(format_bytes "$weights_bytes")"
    "$dialog_tool" "$window_uuid" $QUANT_INFO_ID markdown "Downloads the full model repository (**${weights_fmt}** of weights). All files (config, weights, tokenizer) are fetched into your Hugging Face cache."
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_enable
    rm -f "$tmp_json"
    exit 0
fi

# ── Neither loadable format ───────────────────────────────────────────────────
"$dialog_tool" "$window_uuid" $QUANT_LABEL_ID "Model Files"
case "$source_sel" in
    gguf) "$dialog_tool" "$window_uuid" $QUANT_INFO_ID markdown "This repository has no GGUF files to download." ;;
    mlx)  "$dialog_tool" "$window_uuid" $QUANT_INFO_ID markdown "This repository has no MLX safetensors weights + config.json, so it cannot be loaded." ;;
    *)    "$dialog_tool" "$window_uuid" $QUANT_INFO_ID markdown "This repository has no GGUF or MLX (safetensors + config.json) weights this app can load." ;;
esac
"$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
rm -f "$tmp_json"
