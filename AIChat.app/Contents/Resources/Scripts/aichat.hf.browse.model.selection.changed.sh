#!/bin/bash
# aichat.hf.browse.model.selection.changed.sh
# Fetches model detail from Hugging Face and populates the quant table and info pane.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.glossary.library.sh"

echo "[$(/usr/bin/basename "$0")]"

MODEL_TABLE_ID=202
QUANT_TABLE_ID=213
INFO_TEXT_ID=211
QUANT_INFO_ID=214
DOWNLOAD_BTN_ID=222
HF_LINK_ID=240
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

repo_id="$OMC_ACTIONUI_TABLE_202_COLUMN_3_VALUE"
echo "Selected repo: $repo_id"

if [ -z "$repo_id" ]; then
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
    "$dialog_tool" "$window_uuid" $QUANT_TABLE_ID omc_table_remove_all_rows
    "$dialog_tool" "$window_uuid" $QUANT_INFO_ID ""
    "$dialog_tool" "$window_uuid" $HF_LINK_ID omc_hide
    exit 0
fi

# Reset quant table + its info and disable download while loading
"$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
"$dialog_tool" "$window_uuid" $QUANT_TABLE_ID omc_table_remove_all_rows
"$dialog_tool" "$window_uuid" $QUANT_INFO_ID ""
"$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Loading model info…"

tmp_json="/tmp/aichat_hf_model_$$.json"
http_code=$(/usr/bin/curl -fsSL \
    "https://huggingface.co/api/models/${repo_id}?blobs=true" \
    -o "$tmp_json" -w "%{http_code}" 2>/dev/null)

if [ "$http_code" != "200" ] || [ ! -s "$tmp_json" ]; then
    echo "HF model API error: HTTP $http_code"
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Failed to load model info (HTTP ${http_code})."
    rm -f "$tmp_json"
    exit 1
fi

# Extract summary fields
model_id=$("$plister" get value "$tmp_json" /id 2>/dev/null)
downloads=$("$plister" get value "$tmp_json" /downloads 2>/dev/null)
likes=$("$plister" get value "$tmp_json" /likes 2>/dev/null)
pipeline_tag=$("$plister" get value "$tmp_json" /pipeline_tag 2>/dev/null)

# Format downloads
if [ "$downloads" -ge 1000000 ] 2>/dev/null; then
    dl_fmt=$(printf "%.1fM" "$(echo "scale=1; $downloads/1000000" | /usr/bin/bc -l 2>/dev/null)")
elif [ "$downloads" -ge 1000 ] 2>/dev/null; then
    dl_fmt=$(printf "%dK" "$(echo "scale=0; $downloads/1000" | /usr/bin/bc -l 2>/dev/null)")
else
    dl_fmt="${downloads:-—}"
fi

# Build info text
info_text="**Model:**      ${model_id:-${repo_id}}  "
[ -n "$pipeline_tag" ] && info_text="${info_text}
**Task:**       ${pipeline_tag}  "
info_text="${info_text}
**Downloads:**  ${dl_fmt}  
**Likes:**      ${likes:-—}  "

# Try to get description from cardData
"$plister" get type "$tmp_json" /cardData > /dev/null 2>&1
if [ $? -eq 0 ]; then
    description=$("$plister" get value "$tmp_json" /cardData/model-description 2>/dev/null)
    [ -z "$description" ] && description=$("$plister" get value "$tmp_json" /cardData/description 2>/dev/null)
    if [ -n "$description" ]; then
        # Trim to ~400 chars at a word boundary
        description=$(printf '%s' "$description" | /usr/bin/cut -c1-400)
        info_text="${info_text}

${description}"
    fi
fi

# Decode the acronyms in the model name (size, Instruct, MoE, reasoning, …).
# Separate with a blank-looking gap line. A real blank line can't be used: this
# SwiftUI markdown renderer (.full mode) treats it as a paragraph break, drops the
# trailing hard break and glues the decoder onto the text above. A U+2800 (Braille
# blank) keeps the line non-empty so it stays in the same paragraph and renders as
# a visible gap, while the two-space hard breaks give the line breaks.
br="  "
glossary=$(decode_model_acronyms "${model_id##*/}")
if [ -n "$glossary" ]; then
    gap=$(printf '\342\240\200')
    info_text="${info_text}${br}
${gap}${br}
${glossary}"
fi

"$dialog_tool" "$window_uuid" $INFO_TEXT_ID markdown "$info_text"
"$dialog_tool" "$window_uuid" $HF_LINK_ID omc_set_property "url" "https://huggingface.co/${repo_id}"
"$dialog_tool" "$window_uuid" $HF_LINK_ID omc_show

# Populate quant table — siblings where rfilename ends in .gguf
sib_count=$("$plister" get count "$tmp_json" /siblings 2>/dev/null)
echo "Siblings count: $sib_count"

buf2=""
j=0
while [ "$j" -lt "$sib_count" ]; do
    fname=$("$plister" get value "$tmp_json" "/siblings/$j/rfilename" 2>/dev/null)
    case "$fname" in
        *.gguf)
            # Skip multimodal projector files — these are vision-encoder bridges
            # (e.g. mmproj-BF16.gguf) that cannot be loaded as standalone models.
            case "${fname##*/}" in mmproj-*) j=$((j + 1)); continue ;; esac

            # Skip secondary parts of split GGUFs (e.g. model-00002-of-00004.gguf)
            # Keep single files and first parts (-00001-of-N)
            if echo "$fname" | /usr/bin/grep -qE -- '-[0-9]+-of-[0-9]+\.gguf$'; then
                if ! echo "$fname" | /usr/bin/grep -qE -- '-00001-of-[0-9]+\.gguf$'; then
                    j=$((j + 1))
                    continue
                fi
                # First part of a split — count total parts for the label
                total_parts=$(echo "$fname" | /usr/bin/grep -oE -- '-of-([0-9]+)\.gguf$' | /usr/bin/grep -oE '[0-9]+')
                display_name="${fname} (${total_parts} parts)"
            else
                display_name="$fname"
            fi

            fsize=$("$plister" get value "$tmp_json" "/siblings/$j/size" 2>/dev/null)
            if [ -n "$fsize" ] && [ "$fsize" -gt 0 ] 2>/dev/null; then
                size_gb=$(printf "%.1f GB" "$(echo "scale=4; $fsize/1073741824" | /usr/bin/bc -l 2>/dev/null)")
            else
                size_gb="? GB"
            fi
            # Hidden col 3 stores the real rfilename (no display suffix) for download
            buf2="${buf2}${display_name}	${size_gb}	${fname}
"
            ;;
    esac
    j=$((j + 1))
done

if [ -n "$buf2" ]; then
    printf "%s" "$buf2" | "$dialog_tool" "$window_uuid" $QUANT_TABLE_ID omc_table_set_rows_from_stdin
    echo "Populated quant table"
else
    echo "No GGUF files found in siblings"
fi

rm -f "$tmp_json"
