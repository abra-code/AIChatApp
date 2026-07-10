#!/bin/sh
# aichat.cancel.sh
# Called when a chat window is closed. Stops only the server for that window.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.server.library.sh"

echo "[$(/usr/bin/basename "$0")]"
echo "OMC_FRONT_PROCESS_ID: $OMC_FRONT_PROCESS_ID"
echo "OMC_ACTIONUI_WINDOW_UUID: $OMC_ACTIONUI_WINDOW_UUID"
srvlog "WINDOW-CANCEL enter front=${OMC_FRONT_PROCESS_ID} win=$OMC_ACTIONUI_WINDOW_UUID app_pids=[$(srvlog_apppids)] hosts=[$(srvlog_hosts)] v2_servers=[$(srvlog_servers)]"

if [ -f "$prefs" ]; then
    # Find the server whose stored dialog guid matches this window, then kill only it.
    found=0
    host_pids=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
    while IFS= read -r host_pid; do
        [ -z "$host_pid" ] && continue
        server_pids=$("$plister" get keys "$prefs" "/server-hosts/$host_pid" 2>/dev/null)
        while IFS= read -r server_pid; do
            [ -z "$server_pid" ] && continue
            stored_dialog=$("$plister" get string "$prefs" "/server-info/$server_pid/dialog" 2>/dev/null)
            if [ "$stored_dialog" = "$OMC_ACTIONUI_WINDOW_UUID" ]; then
                echo "Stopping server pid=$server_pid for window $OMC_ACTIONUI_WINDOW_UUID"
                srvlog "WINDOW-CANCEL killing server=$server_pid host=$host_pid win=$OMC_ACTIONUI_WINDOW_UUID"
                mcp_pid=$("$plister" get string "$prefs" "/server-info/$server_pid/mcp-proxy-pid" 2>/dev/null)
                if kill -0 "$server_pid" 2>/dev/null; then
                    kill -TERM "$server_pid"
                fi
                kill_mcp_proxy "$mcp_pid"
                "$plister" delete "$prefs" "/server-hosts/$host_pid/$server_pid" 2>/dev/null
                "$plister" delete "$prefs" "/server-info/$server_pid" 2>/dev/null
                found=1
                break
            fi
        done <<< "$server_pids"
        [ "$found" = 1 ] && break
    done <<< "$host_pids"

    [ "$found" = 0 ] && { echo "No server found for window $OMC_ACTIONUI_WINDOW_UUID"; srvlog "WINDOW-CANCEL no server matched win=$OMC_ACTIONUI_WINDOW_UUID"; }
fi

# Safety net: reap any of this bundle's llama-server / mcp-proxy / replay processes
# left orphaned on launchd — children stranded when the proxy above had already died
# (kill_mcp_proxy can't pgrep -P a dead proxy), or leftovers from an earlier crash.
# Other windows' servers stay registered to a live host, so they are protected and
# left running.
reap_orphaned_bundle_processes
srvlog "WINDOW-CANCEL exit hosts_after=[$(srvlog_hosts)] v2_servers_after=[$(srvlog_servers)]"
