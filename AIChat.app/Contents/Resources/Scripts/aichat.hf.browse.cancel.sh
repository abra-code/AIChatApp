#!/bin/sh
# aichat.hf.browse.cancel.sh
# Handles both the Cancel button and window close (red X).
# If a download is in progress, asks the user before closing.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

PB_LAST_QUERY="hf_last_query_${window_uuid}"
PB_DL_PID="hf_download_pid_${window_uuid}"
PB_DL_DEST="hf_download_dest_${window_uuid}"
PB_DL_FILE="hf_download_file_${window_uuid}"

curl_pid=$(pb_get "$PB_DL_PID")

if [ -n "$curl_pid" ] && kill -0 "$curl_pid" 2>/dev/null; then
    # Download is active — ask before closing
    dl_file=$(pb_get "$PB_DL_FILE")

    "$alert" \
        --level caution \
        --title "Download in Progress" \
        --ok "Continue In Background" \
        --cancel "Stop Download" \
        "\"${dl_file:-model}\" is still downloading. Stopping will delete the partial file."

    if [ $? -ne 0 ]; then
        # User chose "Stop Download"
        kill "$curl_pid" 2>/dev/null
        dl_dest=$(pb_get "$PB_DL_DEST")
        rm -f "$dl_dest"
        pb_set "$PB_DL_PID"  ""
        pb_set "$PB_DL_DEST" ""
        pb_set "$PB_DL_FILE" ""
        pb_set "$PB_LAST_QUERY" ""
        # "$dialog" "$window_uuid" omc_window omc_terminate_cancel
    fi
    # else: do not terminate; window is closing
    exit 1
fi

# No active download — close normally
pb_set "$PB_LAST_QUERY" ""
# "$dialog" "$window_uuid" omc_window omc_terminate_cancel
