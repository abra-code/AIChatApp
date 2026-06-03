#!/bin/sh
# aichat.mcp.servers.rw.add.sh
# Adds a folder to the local server's additional read-write paths.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
RW_TABLE_ID=320

mcp_prefs_init_if_missing

# OMC presents its built-in folder picker (configured via CHOOSE_OBJECT_DIALOG in
# Command.plist) because this script references $OMC_DLG_CHOOSE_OBJECT_PATH.
chosen="$OMC_DLG_CHOOSE_OBJECT_PATH"
[ -z "$chosen" ] && exit 0
chosen="${chosen%/}"

if mcp_prefs_array_append servers/local/allowed-write "$chosen"; then
    mcp_refresh_path_table "$window_uuid" $RW_TABLE_ID servers/local/allowed-write
else
    echo "already present: $chosen"
fi
