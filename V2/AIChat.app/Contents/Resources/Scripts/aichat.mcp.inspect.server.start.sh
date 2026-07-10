#!/bin/sh
# aichat.mcp.inspect.server.start.sh
# Starts the selected server's mcp-proxy (from its saved config, on its own port)
# and re-registers it under the live session so the orphan reaper won't sweep it.
# The selected server's URL is held on the pasteboard by mcp_inspect_show_server.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.inspect.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
ENDPOINT_STATUS_ID=212

url=$(pb_get "aichatv2_mcp_url_${window_uuid}")
if [ -z "$url" ]; then
    "$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "Select a server first."
    exit 0
fi

port=$(mcp_url_port "$url")
short=$(mcp_url_shortname "$url")
[ -z "$short" ] && short="server"

if mcp_port_listening "$port"; then
    mcp_inspect_show_server "$window_uuid" "$url"
    "$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "$short is already running."
    exit 0
fi

"$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "Starting $short…"
pid=$(mcp_start_proxy_instance "$short" "$port")

if [ -n "$pid" ]; then
    owner=$(mcp_owning_server_pid)
    [ -n "$owner" ] && mcp_register_proxy_pid "$owner" "$pid"
    echo "started $short proxy pid=$pid owner=${owner:-none}"
fi

mcp_inspect_populate "$window_uuid"
mcp_inspect_show_server "$window_uuid" "$url"

if [ -z "$pid" ]; then
    "$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "Failed to start $short — check logs/mcp-proxy-$short.log"
fi
