#!/bin/sh
# aichat.mcp.servers.start.sh
# Saves the dialog's toggle + project-path state to $mcp_prefs (table contents
# are already persisted incrementally by the add/remove handlers) and closes the
# window. When a model launch is queued on the pasteboard (the selector's OK routed
# here with tools enabled), chains to aichat.chat, whose init reads these prefs while
# building the agent transport. Opened from the menu (nothing queued), it just saves:
# the settings apply to the next model load; running windows keep their server set.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

mcp_prefs_init_if_missing

mcp_prefs_set_bool   allow-network          "${OMC_ACTIONUI_VIEW_240_VALUE:-true}"
mcp_prefs_set_bool   servers/time/enabled   "${OMC_ACTIONUI_VIEW_210_VALUE:-true}"
mcp_prefs_set_bool   servers/search/enabled "${OMC_ACTIONUI_VIEW_220_VALUE:-true}"
mcp_prefs_set_bool   servers/pdf/enabled    "${OMC_ACTIONUI_VIEW_260_VALUE:-true}"
mcp_prefs_set_bool   servers/pdf/writable   "${OMC_ACTIONUI_VIEW_261_VALUE:-true}"
mcp_prefs_set_bool   servers/local/enabled  "${OMC_ACTIONUI_VIEW_230_VALUE:-true}"
mcp_prefs_set_string servers/local/project  "${OMC_ACTIONUI_VIEW_310_VALUE:-}"

echo "saved MCP prefs: allow-network=${OMC_ACTIONUI_VIEW_240_VALUE} time=${OMC_ACTIONUI_VIEW_210_VALUE} search=${OMC_ACTIONUI_VIEW_220_VALUE} pdf=${OMC_ACTIONUI_VIEW_260_VALUE} pdf-writable=${OMC_ACTIONUI_VIEW_261_VALUE} local=${OMC_ACTIONUI_VIEW_230_VALUE} project=${OMC_ACTIONUI_VIEW_310_VALUE}"

"$dialog" "$window_uuid" omc_window omc_terminate_ok

# If this dialog owns a queued launch (stashed window-scoped by init), re-arm the global
# queue with a fresh epoch - the user may have spent minutes in here - and open the chat
# window on it.
queued=$(pb_get "aichatv2_launch_${window_uuid}")
pb_set "aichatv2_launch_${window_uuid}" ""
if [ -n "$queued" ]; then
    launch_queue_arm "$(launch_queue_model "$queued")" "$(launch_queue_tools "$queued")"
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.chat"
fi
