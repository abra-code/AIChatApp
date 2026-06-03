#!/bin/sh
# aichat.mcp.servers.reset.sh
# Restores the dialog to bundled defaults: all servers on, network allowed, project
# blank, the temp dir as read-write, and Homebrew / nvm / third-party tool dirs as
# read-only
# (whichever exist). The system executable dirs, macOS system libraries, and the app
# bundle are not listed (granted by the sandbox baseline / not read once sandboxed).
# See mcp_prefs_write_defaults in the library.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

TIME_TOGGLE_ID=210
SEARCH_TOGGLE_ID=220
LOCAL_TOGGLE_ID=230
NETWORK_TOGGLE_ID=240
PROJECT_FIELD_ID=310
RW_TABLE_ID=320
RW_REMOVE_BTN_ID=322
RO_TABLE_ID=330
RO_REMOVE_BTN_ID=332

mcp_prefs_write_defaults

"$dialog" "$window_uuid" $TIME_TOGGLE_ID    true
"$dialog" "$window_uuid" $SEARCH_TOGGLE_ID  true
"$dialog" "$window_uuid" $LOCAL_TOGGLE_ID   true
"$dialog" "$window_uuid" $NETWORK_TOGGLE_ID true
"$dialog" "$window_uuid" $PROJECT_FIELD_ID  ""

# Defaults allow network, so the network-dependent toggles are interactive again.
"$dialog" "$window_uuid" $TIME_TOGGLE_ID   omc_enable
"$dialog" "$window_uuid" $SEARCH_TOGGLE_ID omc_enable

mcp_refresh_path_table "$window_uuid" $RW_TABLE_ID servers/local/allowed-write
mcp_refresh_path_table "$window_uuid" $RO_TABLE_ID servers/local/allowed-read

"$dialog" "$window_uuid" $RW_REMOVE_BTN_ID omc_disable
"$dialog" "$window_uuid" $RO_REMOVE_BTN_ID omc_disable
