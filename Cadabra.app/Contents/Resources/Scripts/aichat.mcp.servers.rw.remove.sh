#!/bin/sh
# aichat.mcp.servers.rw.remove.sh
# Removes the selected row from the additional read-write list.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
RW_TABLE_ID=320
RW_REMOVE_BTN_ID=322

selected="$OMC_ACTIONUI_TABLE_320_COLUMN_1_VALUE"
[ -z "$selected" ] && exit 0

# The session $TMPDIR is a synthetic row, not an array entry: removing it clears the
# include-session-tmpdir decision (so the temp grant is denied) rather than deleting a
# stored path. Any other row is a real allowed-write entry.
session_tmpdir=$(mcp_session_tmpdir)
if [ -n "$session_tmpdir" ] && [ "$selected" = "$session_tmpdir" ]; then
    mcp_prefs_set_bool servers/local/include-session-tmpdir false
else
    mcp_prefs_array_remove_value servers/local/allowed-write "$selected"
fi
mcp_refresh_rw_table "$window_uuid" $RW_TABLE_ID
"$dialog" "$window_uuid" $RW_REMOVE_BTN_ID omc_disable
