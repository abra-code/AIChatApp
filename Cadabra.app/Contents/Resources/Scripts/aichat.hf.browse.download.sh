#!/bin/bash
# aichat.hf.browse.download.sh
# Downloads the selected model into the shared Hugging Face cache
# (~/.cache/huggingface/hub/models--<author>--<name>/snapshots/main/). Download-ONLY: the
# browser stays open and nothing is loaded - loading is an explicit decision made in the
# model picker, which owns the RAM warning and the agentic/regular path choice (auto-loading
# from here used to force the non-agentic regular chat path).
# Two shapes, chosen by the format stashed by model.selection.changed:
#   GGUF - one quant FILE (table 213 selection); AICHAT_MODEL_PATH = that .gguf file.
#   MLX  - the whole repo tree (config + *.safetensors shards + tokenizer); AICHAT_MODEL_PATH =
#          the snapshot DIRECTORY. Resumes (skips full-size files), cancellable across the whole
#          operation, with disk + RAM preflight and a shard-completeness check.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

echo "[$(/usr/bin/basename "$0")]"

INFO_TEXT_ID=211
PROGRESS_ID=230
PROGRESS_LABEL_ID=231
DOWNLOAD_BTN_ID=222
CANCEL_BTN_ID=221
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

PB_LAST_QUERY="hf_last_query_${window_uuid}"
PB_DL_PID="hf_download_pid_${window_uuid}"
PB_DL_DEST="hf_download_dest_${window_uuid}"
PB_DL_FILE="hf_download_file_${window_uuid}"
PB_DL_STOP="hf_download_stop_${window_uuid}"
# The single file currently being written (the only thing a Stop deletes). PB_DL_DEST is just
# the operation marker (a file for GGUF, a directory for MLX) so cancel can prompt across the
# whole operation; it is NOT deleted wholesale, because both formats share the repo's HF-cache
# snapshot dir - an MLX Stop must never rm -rf a GGUF file (possibly loaded) sitting alongside.
PB_DL_PARTIAL="hf_download_partial_${window_uuid}"
PB_FORMAT="hf_model_format_${window_uuid}"

repo_id="$OMC_ACTIONUI_TABLE_202_COLUMN_3_VALUE"
fmt="$(pb_get "$PB_FORMAT")"
echo "Repo: $repo_id  Format: $fmt"

if [ -z "$repo_id" ]; then
    echo "Missing repo, aborting"
    exit 0
fi

author="${repo_id%%/*}"
name="${repo_id##*/}"
# The canonical HF cache location, shared with other tools. snapshots/main holds the files
# directly (real files, not blob symlinks) - enough for the loader and the local picker, which
# both take a path; model_display_label renders models--<author>--<name>/snapshots/* as
# "<author>/<name>".
hf_cache="$HOME/.cache/huggingface/hub/models--${author}--${name}/snapshots/main"

# ── Shared helpers ────────────────────────────────────────────────────────────

reset_ui() {
    "$dialog_tool" "$window_uuid" $PROGRESS_ID omc_hide
    "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID omc_hide
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_enable
    "$dialog_tool" "$window_uuid" $CANCEL_BTN_ID omc_enable
}

cleanup_dl_state() {
    pb_set "$PB_DL_PID" ""
    pb_set "$PB_DL_DEST" ""
    pb_set "$PB_DL_FILE" ""
    pb_set "$PB_DL_STOP" ""
    pb_set "$PB_DL_PARTIAL" ""
    rm -f "$manifest" 2>/dev/null
}

stop_requested() { [ "$(pb_get "$PB_DL_STOP")" = "1" ]; }

# stop_exit <log-msg> - user-Stop epilogue. The browser stays open for further downloads
# now, so a Stop must restore the idle UI instead of leaving a stale progress bar and a
# disabled Download button behind.
stop_exit() {
    echo "$1"
    reset_ui
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Download stopped."
    exit 0
}

# download_finished <label> - download-only epilogue: browser stays open, user loads the
# model explicitly from the model picker (Select Model), where the RAM warning and the
# agentic/regular decision live.
#
# Two wordings, because the next step genuinely differs. In the ordinary case the picker is a
# menu away and the user goes there when they feel like it. In the browser LAUNCH opened - the
# Mac had no model at all - closing this window IS what opens the picker (see the cancel
# handler), so telling that user to go find a menu would describe a detour around the path they
# are already on.
download_finished() {
    reset_ui
    hf_first_run_armed_for "$window_uuid"
    if [ $? -eq 0 ]; then
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Downloaded \"$1\".

Close this window to pick it from the Local Models list and start chatting."
    else
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Downloaded. Load \"$1\" from the model picker (Select Model) when you want to chat with it."
    fi
}

# mlx_model_complete <dir> - 0 only if <dir> holds config.json plus every weight shard. A
# partial multi-shard pull must NOT count as complete, or the fast path would open a broken
# directory and skip the resume loop. With model.safetensors.index.json its shards are the
# authority; otherwise a single model.safetensors is required.
mlx_model_complete() {
    local dir="$1"
    [ -f "$dir/config.json" ] || return 1
    local idx="$dir/model.safetensors.index.json"
    if [ -f "$idx" ]; then
        local names="$(/usr/bin/grep -oE '"[^"]+\.safetensors"' "$idx" | /usr/bin/tr -d '"' | /usr/bin/sort -u)"
        local shard=""
        [ -n "$names" ] || return 1
        while IFS= read -r shard; do
            [ -n "$shard" ] || continue
            [ -f "$dir/$shard" ] || return 1
        done <<EOF
$names
EOF
        return 0
    fi
    [ -f "$dir/model.safetensors" ] || return 1
    return 0
}

# ══ GGUF: single quant file ═══════════════════════════════════════════════════
download_gguf() {
    local filename="$OMC_ACTIONUI_TABLE_213_COLUMN_3_VALUE"
    echo "GGUF file: $filename"
    if [ -z "$filename" ]; then
        echo "Missing filename, aborting"
        exit 0
    fi

    local dest_path="${hf_cache}/${filename}"
    # URL-encode the filename (spaces/#/?/% ) so an unusual quant name does not break the URL.
    local filename_enc="$(printf '%s' "$filename" | /usr/bin/sed 's/%/%25/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g')"
    local download_url="https://huggingface.co/${repo_id}/resolve/main/${filename_enc}"
    echo "Destination: $dest_path"

    # Already cached? Nothing to do - loading happens from the model picker.
    if [ -f "$dest_path" ]; then
        echo "File already cached: $dest_path"
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Already downloaded. Load \"${filename%.gguf}\" from the model picker (Select Model)."
        exit 0
    fi

    # Commit to a download: make the window cancellable for the whole operation.
    trap cleanup_dl_state EXIT
    pb_set "$PB_DL_DEST" "$dest_path"
    pb_set "$PB_DL_FILE" "$filename"
    pb_set "$PB_DL_STOP" ""
    pb_set "$PB_DL_PID" ""

    # Probe size.
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Checking download size…"
    local total_bytes="$(/usr/bin/curl -fsSIL "$download_url" \
        | /usr/bin/awk '/[Cc]ontent-[Ll]ength:/{len=$2} END{print len}' \
        | /usr/bin/tr -d '\r')"
    echo "Total bytes: '${total_bytes}'"
    if stop_requested; then stop_exit "cancelled during size probe"; fi

    # Disk preflight (reserve 15 GB headroom above the download).
    local SAFETY_HEADROOM_GB=15
    local safety_headroom=$((SAFETY_HEADROOM_GB * 1024 * 1024 * 1024))
    if [ -n "$total_bytes" ] && [ "$total_bytes" -gt 0 ] 2>/dev/null; then
        local avail_kb="$(df -Pk "$HOME" | /usr/bin/awk 'NR==2{print $4}')"
        local avail_bytes=$((avail_kb * 1024))
        local needed=$((total_bytes + safety_headroom))
        if [ "$avail_bytes" -lt "$needed" ] 2>/dev/null; then
            reset_ui
            "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
            "$alert" --level caution --title "Not Enough Disk Space" \
                "Not enough disk space to safely download this model.

Model size:       $(format_bytes "$total_bytes")
System headroom:  $(format_bytes "$safety_headroom")
Available space:  $(format_bytes "$avail_bytes")

macOS needs free space for swap files and system caches. Free up space and try again."
            exit 0
        fi
    fi

    # (No RAM preflight here: this is a pure download now, and the load-time RAM warning
    # lives in the model picker's OK handler.)

    # Download.
    "$dialog_tool" "$window_uuid" $CANCEL_BTN_ID omc_disable
    "$dialog_tool" "$window_uuid" $PROGRESS_ID omc_show
    "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID omc_show
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Downloading ${filename} from Hugging Face…"
    /bin/mkdir -p "$hf_cache"

    local total_fmt=""
    if [ -n "$total_bytes" ] && [ "$total_bytes" -gt 0 ] 2>/dev/null; then
        total_fmt=$(format_bytes "$total_bytes")
        "$dialog_tool" "$window_uuid" $PROGRESS_ID omc_set_property "total" "100"
        "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID "0 B / ${total_fmt} (0%)"
    else
        total_bytes=""
        "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID "Downloading…"
    fi

    pb_set "$PB_DL_PARTIAL" "$dest_path"
    /usr/bin/curl -fsSL -o "$dest_path" "$download_url" &
    local curl_pid=$!
    pb_set "$PB_DL_PID" "$curl_pid"

    if [ -n "$total_bytes" ]; then
        while kill -0 "$curl_pid" 2>/dev/null; do
            local downloaded="$(/usr/bin/stat -f%z -L "$dest_path" 2>/dev/null || echo 0)"
            local pct=$((downloaded * 100 / total_bytes))
            [ "$pct" -gt 100 ] && pct=100
            "$dialog_tool" "$window_uuid" $PROGRESS_ID "$pct"
            "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID "$(format_bytes "$downloaded") / ${total_fmt} (${pct}%)"
            sleep 0.5
        done
    fi
    wait "$curl_pid"
    local curl_result=$?
    pb_set "$PB_DL_PID" ""

    if stop_requested; then stop_exit "stopped during download"; fi

    if [ "$curl_result" != 0 ]; then
        echo "curl failed with exit code $curl_result"
        rm -f "$dest_path"
        reset_ui
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Download failed (error ${curl_result}).

Please check your internet connection and try again."
        exit 1
    fi

    echo "Download complete: $dest_path"
    download_finished "${filename%.gguf}"
}

# ══ MLX: whole repo tree ══════════════════════════════════════════════════════
download_mlx() {
    local dest_dir="$hf_cache"
    manifest="/tmp/aichatv2_hf_manifest_$$.tsv"
    echo "Destination dir: $dest_dir"

    # Already fully downloaded? Nothing to do - loading happens from the model picker. A
    # partial multi-shard dir must fall through to the resuming loop, so require a complete set.
    if mlx_model_complete "$dest_dir"; then
        echo "Model already complete: $dest_dir"
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Already downloaded. Load \"$(model_display_label "$dest_dir")\" from the model picker (Select Model)."
        exit 0
    fi

    # Commit to a download (cancellable from here, including the tree fetch / preflight window).
    trap cleanup_dl_state EXIT
    pb_set "$PB_DL_DEST" "$dest_dir"
    pb_set "$PB_DL_FILE" "$name"
    pb_set "$PB_DL_STOP" ""
    pb_set "$PB_DL_PID" ""

    # Fetch the repo file tree.
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Reading file list for ${name}…"
    local tree_json="/tmp/aichatv2_hf_tree_$$.json"
    local http_code="$(/usr/bin/curl -fsSL \
        "https://huggingface.co/api/models/${repo_id}/tree/main?recursive=true" \
        -o "$tree_json" -w '%{http_code}' 2>/dev/null)"
    if stop_requested; then rm -f "$tree_json"; stop_exit "cancelled during tree fetch"; fi
    if [ "$http_code" != "200" ] || [ ! -s "$tree_json" ]; then
        echo "HF tree API error: HTTP $http_code"
        reset_ui
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Could not read the model file list (HTTP ${http_code}). Check your connection and try again."
        rm -f "$tree_json"
        exit 1
    fi

    # Build a manifest of downloadable files as "<size><TAB><relpath>" lines. A temp file (not a
    # shell array) keeps this portable and lets the download loop read it with a subshell-free
    # `while read < file` so the byte counter persists.
    : > "$manifest"
    local entries="$("$plister" get count "$tree_json" / 2>/dev/null)"
    local total_bytes=0
    local weights_bytes=0
    local file_count=0
    local tab="$(printf '\t')"
    local k=0
    while [ "$k" -lt "$entries" ]; do
        local etype="$("$plister" get value "$tree_json" "/$k/type" 2>/dev/null)"
        local epath="$("$plister" get value "$tree_json" "/$k/path" 2>/dev/null)"
        local esize="$("$plister" get value "$tree_json" "/$k/size" 2>/dev/null)"
        [ -n "$esize" ] && [ "$esize" -gt 0 ] 2>/dev/null || esize=0
        k=$((k + 1))
        [ "$etype" = "file" ] || continue
        case "${epath##*/}" in ""|.gitattributes) continue ;; esac
        printf '%s%s%s\n' "$esize" "$tab" "$epath" >> "$manifest"
        file_count=$((file_count + 1))
        total_bytes=$((total_bytes + esize))
        case "$epath" in *.safetensors) weights_bytes=$((weights_bytes + esize)) ;; esac
    done
    rm -f "$tree_json"

    echo "Files: ${file_count}  total=${total_bytes}B  weights=${weights_bytes}B"
    if [ "$file_count" -eq 0 ]; then
        reset_ui
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "This repository has no downloadable files."
        exit 1
    fi

    # Disk preflight (reserve 15 GB headroom; a resume overstates need, which is safe).
    local SAFETY_HEADROOM_GB=15
    local safety_headroom=$((SAFETY_HEADROOM_GB * 1024 * 1024 * 1024))
    if [ "$total_bytes" -gt 0 ]; then
        local avail_kb="$(df -Pk "$HOME" | /usr/bin/awk 'NR==2{print $4}')"
        local avail_bytes=$((avail_kb * 1024))
        local needed=$((total_bytes + safety_headroom))
        if [ "$avail_bytes" -lt "$needed" ] 2>/dev/null; then
            reset_ui
            "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
            "$alert" --level caution --title "Not Enough Disk Space" \
                "Not enough disk space to safely download this model.

Model size:       $(format_bytes "$total_bytes")
System headroom:  $(format_bytes "$safety_headroom")
Available space:  $(format_bytes "$avail_bytes")

macOS needs free space for swap files and system caches. Free up space and try again."
            exit 0
        fi
    fi
    if stop_requested; then stop_exit "cancelled during preflight"; fi

    # (No RAM preflight here: pure download; the model picker's OK handler owns the
    # load-time RAM warning.)

    # Download all files sequentially.
    "$dialog_tool" "$window_uuid" $CANCEL_BTN_ID omc_disable
    "$dialog_tool" "$window_uuid" $PROGRESS_ID omc_show
    "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID omc_show
    "$dialog_tool" "$window_uuid" $PROGRESS_ID omc_set_property "total" "100"
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Downloading ${name} from Hugging Face…"
    /bin/mkdir -p "$dest_dir"

    local total_fmt="$(format_bytes "$total_bytes")"
    local base_done=0
    local dl_failed=""
    # Read via redirect (NOT a pipe) so base_done persists in this shell.
    local rel
    while IFS="$tab" read -r esize rel; do
        [ -n "$rel" ] || continue
        if stop_requested; then stop_exit "stopped before $rel"; fi
        local out="${dest_dir}/${rel}"
        /bin/mkdir -p "$(/usr/bin/dirname "$out")"

        # Skip a file already present at its full expected size (resume a partial run).
        if [ -f "$out" ] && [ "$esize" -gt 0 ] 2>/dev/null; then
            local have="$(/usr/bin/stat -f%z -L "$out" 2>/dev/null || echo 0)"
            if [ "$have" -eq "$esize" ]; then
                echo "skip (complete): $rel"
                base_done=$((base_done + esize))
                continue
            fi
        fi

        # URL-encode spaces and a few reserved chars in the repo-relative path (keep slashes).
        local rel_enc="$(printf '%s' "$rel" | /usr/bin/sed 's/%/%25/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g')"

        echo "downloading: $rel (${esize}B)"
        pb_set "$PB_DL_PARTIAL" "$out"
        /usr/bin/curl -fsSL -o "$out" "https://huggingface.co/${repo_id}/resolve/main/${rel_enc}" &
        local curl_pid=$!
        pb_set "$PB_DL_PID" "$curl_pid"

        while kill -0 "$curl_pid" 2>/dev/null; do
            local cur="$(/usr/bin/stat -f%z -L "$out" 2>/dev/null || echo 0)"
            local done_bytes=$((base_done + cur))
            local pct=0
            if [ "$total_bytes" -gt 0 ]; then
                pct=$((done_bytes * 100 / total_bytes))
                [ "$pct" -gt 100 ] && pct=100
                "$dialog_tool" "$window_uuid" $PROGRESS_ID "$pct"
                "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID "$(format_bytes "$done_bytes") / ${total_fmt} (${pct}%)"
            fi
            sleep 0.5
        done
        wait "$curl_pid"
        local curl_result=$?
        pb_set "$PB_DL_PID" ""

        if stop_requested; then stop_exit "stopped during $rel"; fi
        if [ "$curl_result" != 0 ]; then
            echo "curl failed on $rel (exit $curl_result)"
            dl_failed="$rel"
            break
        fi
        base_done=$((base_done + esize))
        pb_set "$PB_DL_PARTIAL" ""
    done < "$manifest"

    if [ -n "$dl_failed" ]; then
        # Keep verified files so a retry RESUMES; remove only the file that failed (may be a
        # truncated partial). The whole-dir wipe is reserved for an explicit user Stop.
        /bin/rm -f "${dest_dir}/${dl_failed}"
        reset_ui
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Download failed on ${dl_failed}. Already-downloaded files were kept - select Download again to resume.

Check your internet connection and try again."
        exit 1
    fi

    if ! mlx_model_complete "$dest_dir"; then
        echo "Downloaded tree is missing config.json or safetensors shards"
        reset_ui
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "The downloaded repository is missing config.json or its safetensors weights and cannot be loaded."
        exit 1
    fi

    echo "Download complete: $dest_dir"
    download_finished "$(model_display_label "$dest_dir")"
}

# ══ Dispatch ══════════════════════════════════════════════════════════════════
manifest=""
case "$fmt" in
    mlx)  download_mlx ;;
    gguf) download_gguf ;;
    *)
        echo "No format recorded for this selection"
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
        exit 0
        ;;
esac
