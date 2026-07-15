#!/bin/sh
# aichat.mcp.servers.init.sh
# Populates the MCP servers dialog from $mcp_prefs (creating defaults if missing).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"

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

mcp_prefs_init_if_missing

# Toggles
"$dialog" "$window_uuid" $TIME_TOGGLE_ID   "$(mcp_prefs_get_bool servers/time/enabled)"
"$dialog" "$window_uuid" $SEARCH_TOGGLE_ID "$(mcp_prefs_get_bool servers/search/enabled)"
"$dialog" "$window_uuid" $LOCAL_TOGGLE_ID  "$(mcp_prefs_get_bool servers/local/enabled)"

# Allow Network master gate. When off, the network-dependent server toggles are
# greyed out (their stored values are kept and restored when network is re-enabled).
allow_network=$(mcp_prefs_get_bool allow-network)
"$dialog" "$window_uuid" $NETWORK_TOGGLE_ID "$allow_network"
if [ "$allow_network" = "true" ]; then
    "$dialog" "$window_uuid" $TIME_TOGGLE_ID   omc_enable
    "$dialog" "$window_uuid" $SEARCH_TOGGLE_ID omc_enable
else
    "$dialog" "$window_uuid" $TIME_TOGGLE_ID   omc_disable
    "$dialog" "$window_uuid" $SEARCH_TOGGLE_ID omc_disable
fi

# Project workspace TextField
project_path=$(mcp_prefs_get_string servers/local/project)
"$dialog" "$window_uuid" $PROJECT_FIELD_ID "$project_path"

# Configure single-column tables
"$dialog" "$window_uuid" $RW_TABLE_ID omc_table_set_columns "Path"
"$dialog" "$window_uuid" $RW_TABLE_ID omc_table_set_column_widths 560
"$dialog" "$window_uuid" $RO_TABLE_ID omc_table_set_columns "Path"
"$dialog" "$window_uuid" $RO_TABLE_ID omc_table_set_column_widths 560

# Populate path tables from prefs. The read-write table also shows the session
# $TMPDIR as a removable (but unstored) row; see mcp_refresh_rw_table.
mcp_refresh_rw_table "$window_uuid" $RW_TABLE_ID
mcp_refresh_path_table "$window_uuid" $RO_TABLE_ID servers/local/allowed-read

# - buttons start disabled until the user picks a row
"$dialog" "$window_uuid" $RW_REMOVE_BTN_ID omc_disable
"$dialog" "$window_uuid" $RO_REMOVE_BTN_ID omc_disable

# Take ownership of a queued launch (the model selector routed here with tools enabled):
# move it from the global queue into this window's own key, so it lives exactly as long
# as this dialog - another entry point queueing a launch meanwhile can't clobber it, and
# a quit with the dialog open leaves nothing armed. The confirm button reflects what
# confirming does: launching the queued session ("Start") or just saving prefs ("Save",
# when opened from Tools > Configure MCP Servers with nothing queued).
CONFIRM_BTN_ID=393
queued=$(launch_queue_consume)
pb_set "aichatv2_launch_${window_uuid}" "$queued"
if [ -n "$queued" ]; then
    "$dialog" "$window_uuid" $CONFIRM_BTN_ID omc_set_property "title" "Start"
else
    "$dialog" "$window_uuid" $CONFIRM_BTN_ID omc_set_property "title" "Save"
fi
