#!/bin/sh
# aichat.hf.browse.cancel.sh
# Handles both the Cancel button and window close (red X). If a download OPERATION is in
# progress it asks before closing. Serves both formats: PB_DL_DEST (a file for GGUF, a directory
# for MLX) marks the operation for the prompt; on Stop only the in-progress partial file is
# removed (PB_DL_PARTIAL), never the shared snapshot directory.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

PB_LAST_QUERY="hf_last_query_${window_uuid}"
PB_DL_PID="hf_download_pid_${window_uuid}"
PB_DL_DEST="hf_download_dest_${window_uuid}"
PB_DL_FILE="hf_download_file_${window_uuid}"
PB_DL_STOP="hf_download_stop_${window_uuid}"
PB_DL_PARTIAL="hf_download_partial_${window_uuid}"

# A download OPERATION is in progress whenever the destination is set - this covers the whole
# span (reading the file list, preflight, and the transfers), not just the moment a curl happens
# to be running. Keying on PB_DL_DEST (set at the start of download.sh) means a window closed
# during "Reading file list…" still prompts instead of silently continuing in the background.
dl_dest=$(pb_get "$PB_DL_DEST")

if [ -n "$dl_dest" ]; then
    dl_file=$(pb_get "$PB_DL_FILE")

    "$alert" \
        --level caution \
        --title "Download in Progress" \
        --ok "Continue In Background" \
        --cancel "Stop Download" \
        "\"${dl_file:-model}\" is still downloading. Stopping cancels it and removes the file currently in progress; files already downloaded are kept."

    if [ $? -ne 0 ]; then
        # User chose "Stop Download". Signal download.sh to abort at its next checkpoint, then
        # kill the CURRENT transfer. Re-read the pid AFTER the alert (it may have advanced to a
        # new file while the alert was open) and verify it is really our curl before killing, so
        # a stale/reused pid is never signalled. Delete ONLY the in-progress partial file
        # (PB_DL_PARTIAL), never PB_DL_DEST wholesale: both formats share the repo's HF-cache
        # snapshot dir, so rm -rf on the dir could destroy a GGUF file (possibly loaded) or other
        # snapshot files that this download did not create. Completed files stay (resume-friendly).
        pb_set "$PB_DL_STOP" "1"
        cur_pid=$(pb_get "$PB_DL_PID")
        if [ -n "$cur_pid" ]; then
            cmd=$(/bin/ps -p "$cur_pid" -o command= 2>/dev/null)
            case "$cmd" in
                *curl*huggingface.co*) kill "$cur_pid" 2>/dev/null ;;
            esac
        fi
        partial=$(pb_get "$PB_DL_PARTIAL")
        [ -n "$partial" ] && rm -f "$partial"
        pb_set "$PB_DL_PID"  ""
        pb_set "$PB_DL_DEST" ""
        pb_set "$PB_DL_FILE" ""
        pb_set "$PB_DL_PARTIAL" ""
        pb_set "$PB_LAST_QUERY" ""
    fi
    # Either choice: do not terminate here (window is closing / staying per OMC).
    exit 1
fi

# No active download — close normally.
pb_set "$PB_LAST_QUERY" ""
