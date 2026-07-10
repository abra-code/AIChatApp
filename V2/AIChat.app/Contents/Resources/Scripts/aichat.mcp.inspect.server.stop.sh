#!/bin/sh
# aichat.mcp.inspect.server.stop.sh
# Stops the selected server's mcp-proxy (and its child tool server) by its port.
# Only the LISTENing proxy is targeted, so a connected llama-server is left running.

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

"$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "Stopping $short…"
mcp_stop_proxy_on_port "$port"

mcp_inspect_populate "$window_uuid"
mcp_inspect_show_server "$window_uuid" "$url"
"$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "Stopped $short."
