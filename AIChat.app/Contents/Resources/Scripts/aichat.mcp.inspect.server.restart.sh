#!/bin/sh
# aichat.mcp.inspect.server.restart.sh
# Stops then starts the selected server's mcp-proxy on the same port. Useful when a
# server has gone unresponsive but the chat session is still alive.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.inspect.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
ENDPOINT_STATUS_ID=212

url=$(pb_get "aichat_mcp_url_${window_uuid}")
if [ -z "$url" ]; then
    "$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "Select a server first."
    exit 0
fi

port=$(mcp_url_port "$url")
short=$(mcp_url_shortname "$url")
[ -z "$short" ] && short="server"

"$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "Restarting $short…"
mcp_stop_proxy_on_port "$port"
sleep 0.5
pid=$(mcp_start_proxy_instance "$short" "$port")

if [ -n "$pid" ]; then
    owner=$(mcp_owning_server_pid)
    [ -n "$owner" ] && mcp_register_proxy_pid "$owner" "$pid"
    echo "restarted $short proxy pid=$pid owner=${owner:-none}"
fi

mcp_inspect_populate "$window_uuid"
mcp_inspect_show_server "$window_uuid" "$url"

if [ -z "$pid" ]; then
    "$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "Failed to restart $short — check logs/mcp-proxy-$short.log"
fi
