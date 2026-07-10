#!/bin/bash
# aichat.hf.browse.download.sh
# Downloads the selected GGUF file from Hugging Face into the local HF cache,
# then loads it with llama-server via aichat.new.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

echo "[$(/usr/bin/basename "$0")]"

INFO_TEXT_ID=211
PROGRESS_ID=230
PROGRESS_LABEL_ID=231
DOWNLOAD_BTN_ID=222
CANCEL_BTN_ID=221
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Pasteboard keys scoped to this window instance
PB_LAST_QUERY="hf_last_query_${window_uuid}"
PB_DL_PID="hf_download_pid_${window_uuid}"
PB_DL_DEST="hf_download_dest_${window_uuid}"
PB_DL_FILE="hf_download_file_${window_uuid}"

repo_id="$OMC_ACTIONUI_TABLE_202_COLUMN_3_VALUE"
filename="$OMC_ACTIONUI_TABLE_213_COLUMN_3_VALUE"

echo "Repo: $repo_id  File: $filename"

if [ -z "$repo_id" ] || [ -z "$filename" ]; then
    echo "Missing repo or filename, aborting"
    exit 0
fi

# Build HF cache destination path
# Format: ~/.cache/huggingface/hub/models--{author}--{model}/snapshots/main/{filename}
author="${repo_id%%/*}"
model_name="${repo_id##*/}"
cache_dir="$HOME/.cache/huggingface/hub/models--${author}--${model_name}/snapshots/main"
dest_path="${cache_dir}/${filename}"

echo "Destination: $dest_path"

download_url="https://huggingface.co/${repo_id}/resolve/main/${filename}"

# ── Helpers ───────────────────────────────────────────────────────────────────

reset_ui() {
    "$dialog_tool" "$window_uuid" $PROGRESS_ID omc_hide
    "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID omc_hide
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_enable
    "$dialog_tool" "$window_uuid" $CANCEL_BTN_ID omc_enable
}

# ── Already cached? ───────────────────────────────────────────────────────────

if [ -f "$dest_path" ]; then
    echo "File already exists, loading directly"
    activate_if_model_running "$dest_path" && exit 0
    cached_bytes=$(/usr/bin/stat -f%z -L "$dest_path" 2>/dev/null)
    warn_ram_pressure_for_new_model "$cached_bytes" "${filename%.gguf}"
    if [ $? -ne 0 ]; then
        exit 0
    fi
    pb_set "$PB_LAST_QUERY" ""
    "$dialog_tool" "$window_uuid" omc_window omc_terminate_ok
    "$pasteboard" "AICHAT_MODEL_PATH" put "$dest_path"
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.new"
    exit 0
fi

# ── Probe file size ───────────────────────────────────────────────────────────
# Do this before touching the UI so we can bail cleanly on disk-space issues.

"$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
"$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Checking download size…"

echo "Probing content-length: $download_url"
total_bytes=$(/usr/bin/curl -fsSIL "$download_url" \
    | /usr/bin/awk '/[Cc]ontent-[Ll]ength:/{len=$2} END{print len}' \
    | /usr/bin/tr -d '\r')

echo "Total bytes: '${total_bytes}'"

# ── Disk space preflight ──────────────────────────────────────────────────────
# macOS needs headroom for dynamic swap files, system caches, and APFS metadata.
# Apple recommends keeping at least 20 GB free at all times; below ~10% free the
# system risks kernel panics from swap exhaustion. We reserve 15 GB as a safety
# buffer on top of the download size.

SAFETY_HEADROOM_GB=15
safety_headroom=$((SAFETY_HEADROOM_GB * 1024 * 1024 * 1024))

if [ -n "$total_bytes" ] && [ "$total_bytes" -gt 0 ] 2>/dev/null; then
    # Read total and available in 1024-byte blocks
    disk_info=$(df -Pk "$HOME" | /usr/bin/awk 'NR==2{print $2, $4}')
    total_kb=$(echo "$disk_info" | /usr/bin/awk '{print $1}')
    avail_kb=$(echo "$disk_info" | /usr/bin/awk '{print $2}')
    total_disk=$((total_kb * 1024))
    avail_bytes=$((avail_kb * 1024))
    echo "Disk total: $total_disk  Available: $avail_bytes  Safety headroom: $safety_headroom"

    # Space needed = download + safety headroom
    needed=$((total_bytes + safety_headroom))

    if [ "$avail_bytes" -lt "$needed" ] 2>/dev/null; then
        avail_fmt=$(format_bytes "$avail_bytes")
        need_fmt=$(format_bytes "$total_bytes")
        headroom_fmt=$(format_bytes "$safety_headroom")
        "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_enable
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
        "$alert" \
            --level caution \
            --title "Not Enough Disk Space" \
            "Not enough disk space to safely download this model.

Model size:       ${need_fmt}
System headroom:  ${headroom_fmt}
Available space:  ${avail_fmt}

macOS requires free space for swap files and system caches. Filling the disk too close to capacity risks a kernel panic. Free up disk space and try again."
        exit 0
    fi
fi

# ── RAM check ────────────────────────────────────────────────────────────────

if [ -n "$total_bytes" ] && [ "$total_bytes" -gt 0 ] 2>/dev/null; then
    warn_ram_pressure_for_new_model "$total_bytes" "${filename%.gguf}"
    if [ $? -ne 0 ]; then
        "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_enable
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
        exit 0
    fi
fi

# ── Prepare download UI ───────────────────────────────────────────────────────

"$dialog_tool" "$window_uuid" $CANCEL_BTN_ID omc_disable
"$dialog_tool" "$window_uuid" $PROGRESS_ID omc_show
"$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID omc_show
"$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Downloading ${filename} from Hugging Face…"

/bin/mkdir -p "$cache_dir"

if [ -n "$total_bytes" ] && [ "$total_bytes" -gt 0 ] 2>/dev/null; then
    total_fmt=$(format_bytes "$total_bytes")
    "$dialog_tool" "$window_uuid" $PROGRESS_ID omc_set_property "total" "100"
    "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID "0 B / ${total_fmt} (0%)"
else
    total_bytes=""
    "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID "Downloading…"
fi

# ── Start download ────────────────────────────────────────────────────────────

echo "Downloading: $download_url"
/usr/bin/curl -fsSL -o "$dest_path" "$download_url" &
curl_pid=$!

# Record download state so cancel.sh can detect and interrupt it
pb_set "$PB_DL_PID"  "$curl_pid"
pb_set "$PB_DL_DEST" "$dest_path"
pb_set "$PB_DL_FILE" "$filename"

# ── Progress polling loop ─────────────────────────────────────────────────────

if [ -n "$total_bytes" ]; then
    while kill -0 "$curl_pid" 2>/dev/null; do
        downloaded=$(/usr/bin/stat -f%z "$dest_path" 2>/dev/null)
        [ -z "$downloaded" ] && downloaded=0

        

        done_fmt=$(format_bytes "$downloaded")
        pct=$(echo "scale=0; $downloaded*100/$total_bytes" | /usr/bin/bc -l 2>/dev/null)
        "$dialog_tool" "$window_uuid" $PROGRESS_ID "${pct}"
        "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID "${done_fmt} / ${total_fmt} (${pct}%)"

        sleep 0.5
    done
fi

wait "$curl_pid"
curl_result=$?

# ── Result ────────────────────────────────────────────────────────────────────

# If cancel.sh already cleared the PID, the user stopped the download via
# window close — exit silently; cancel.sh handles cleanup and termination.
active_pid=$(pb_get "$PB_DL_PID")
if [ -z "$active_pid" ]; then
    echo "Download was cancelled by window close — exiting"
    exit 0
fi

# Clear download state
pb_set "$PB_DL_PID"  ""
pb_set "$PB_DL_DEST" ""
pb_set "$PB_DL_FILE" ""

if [ "$curl_result" != 0 ]; then
    echo "curl failed with exit code $curl_result"
    rm -f "$dest_path"
    reset_ui
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Download failed (error ${curl_result}).

Please check your internet connection and try again."
    exit 1
fi

echo "Download complete: $dest_path"

warn_ram_pressure_for_new_model "$total_bytes" "${filename%.gguf}"
if [ $? -ne 0 ]; then
    reset_ui
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Download complete. Select Download again when ready to load."
    exit 0
fi

pb_set "$PB_LAST_QUERY" ""
"$dialog_tool" "$window_uuid" omc_window omc_terminate_ok
"$pasteboard" "AICHAT_MODEL_PATH" put "$dest_path"
"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.new"
