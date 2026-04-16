#!/bin/sh
# aichat.select.local.model.ok.sh
# Loads the selected model: stops any running server, then chains to aichat.new.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Column 3 (hidden) holds the full model path
selected_path="$OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE"

if [ -z "$selected_path" ]; then
    echo "No model selected"
    exit 0
fi

echo "Selected model path: $selected_path"

# Close the selector window before starting the server
"$dialog_tool" "$window_uuid" omc_window omc_terminate_ok

# Stop any llama-server currently on our port so the new model can bind to it
existing_pid=$(/usr/sbin/lsof -ti tcp:$port_num 2>/dev/null | head -1)
if [ -n "$existing_pid" ]; then
    echo "Stopping existing server (pid=$existing_pid) on port $port_num"
    kill -TERM "$existing_pid"
    count=0
    while kill -0 "$existing_pid" 2>/dev/null && [ "$count" -lt 5 ]; do
        sleep 1
        count=$((count + 1))
    done
fi

"$pasteboard" "AICHAT_MODEL_PATH" put "$selected_path"
"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.new"
