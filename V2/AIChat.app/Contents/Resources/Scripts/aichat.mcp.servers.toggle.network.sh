#!/bin/sh
# aichat.mcp.servers.toggle.network.sh
# Handles the "Allow Network" master checkbox. Persists the flag and, in the live
# dialog, enables or disables the network-dependent server toggles (Time and Web
# Search & Fetch) so it is visually clear they won't start when network is off.
# The actual gating + replay's --deny-network are applied in generate_mcp_configs.py.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.server.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

TIME_TOGGLE_ID=210
SEARCH_TOGGLE_ID=220

allow_network="${OMC_ACTIONUI_VIEW_240_VALUE:-true}"

mcp_prefs_init_if_missing
mcp_prefs_set_bool allow-network "$allow_network"

if [ "$allow_network" = "true" ]; then
    "$dialog" "$window_uuid" $TIME_TOGGLE_ID   omc_enable
    "$dialog" "$window_uuid" $SEARCH_TOGGLE_ID omc_enable
else
    "$dialog" "$window_uuid" $TIME_TOGGLE_ID   omc_disable
    "$dialog" "$window_uuid" $SEARCH_TOGGLE_ID omc_disable
fi

echo "saved allow-network=$allow_network"
