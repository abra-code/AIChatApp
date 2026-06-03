#!/bin/sh
# aichat.mcp.servers.ro.add.sh
# Adds a folder to the local server's additional read-only paths.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
RO_TABLE_ID=330

mcp_prefs_init_if_missing

# OMC presents its built-in folder picker (configured via CHOOSE_OBJECT_DIALOG in
# Command.plist) because this script references $OMC_DLG_CHOOSE_OBJECT_PATH.
chosen="$OMC_DLG_CHOOSE_OBJECT_PATH"
[ -z "$chosen" ] && exit 0
chosen="${chosen%/}"

if mcp_prefs_array_append servers/local/allowed-read "$chosen"; then
    mcp_refresh_path_table "$window_uuid" $RO_TABLE_ID servers/local/allowed-read
else
    echo "already present: $chosen"
fi
