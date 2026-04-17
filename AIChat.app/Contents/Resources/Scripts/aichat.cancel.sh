#!/bin/sh
# aichat.cancel.sh
# Called when a chat window is closed. Stops only the server for that window.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"
echo "OMC_FRONT_PROCESS_ID: $OMC_FRONT_PROCESS_ID"
echo "OMC_NIB_DLG_GUID: $OMC_NIB_DLG_GUID"

[ ! -f "$prefs" ] && exit 0

# Find the server whose stored dialog guid matches this window, then kill only it.
host_pids=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
while IFS= read -r host_pid; do
    [ -z "$host_pid" ] && continue
    server_pids=$("$plister" get keys "$prefs" "/server-hosts/$host_pid" 2>/dev/null)
    while IFS= read -r server_pid; do
        [ -z "$server_pid" ] && continue
        stored_dialog=$("$plister" get string "$prefs" "/server-info/$server_pid/dialog" 2>/dev/null)
        if [ "$stored_dialog" = "$OMC_NIB_DLG_GUID" ]; then
            echo "Stopping server pid=$server_pid for window $OMC_NIB_DLG_GUID"
            if kill -0 "$server_pid" 2>/dev/null; then
                kill -TERM "$server_pid"
            fi
            "$plister" delete "$prefs" "/server-hosts/$host_pid/$server_pid" 2>/dev/null
            "$plister" delete "$prefs" "/server-info/$server_pid" 2>/dev/null
            exit 0
        fi
    done <<< "$server_pids"
done <<< "$host_pids"

echo "No server found for window $OMC_NIB_DLG_GUID"
