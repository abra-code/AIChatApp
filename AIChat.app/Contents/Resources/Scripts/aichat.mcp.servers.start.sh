#!/bin/sh
# aichat.mcp.servers.start.sh
# Saves the dialog's toggle + project-path state to $mcp_prefs (table contents
# are already persisted incrementally by the add/remove handlers), closes the
# window, and — if a model is queued on the pasteboard — chains to aichat.new.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

mcp_prefs_init_if_missing

mcp_prefs_set_bool   allow-network          "${OMC_ACTIONUI_VIEW_240_VALUE:-true}"
mcp_prefs_set_bool   servers/time/enabled   "${OMC_ACTIONUI_VIEW_210_VALUE:-true}"
mcp_prefs_set_bool   servers/search/enabled "${OMC_ACTIONUI_VIEW_220_VALUE:-true}"
mcp_prefs_set_bool   servers/local/enabled  "${OMC_ACTIONUI_VIEW_230_VALUE:-true}"
mcp_prefs_set_string servers/local/project  "${OMC_ACTIONUI_VIEW_310_VALUE:-}"

echo "saved MCP prefs: allow-network=${OMC_ACTIONUI_VIEW_240_VALUE} time=${OMC_ACTIONUI_VIEW_210_VALUE} search=${OMC_ACTIONUI_VIEW_220_VALUE} local=${OMC_ACTIONUI_VIEW_230_VALUE} project=${OMC_ACTIONUI_VIEW_310_VALUE}"

"$dialog" "$window_uuid" omc_window omc_terminate_ok

# If the model selector queued a model path, proceed to launch the session.
queued_model=$("$pasteboard" "AICHAT_MODEL_PATH" get)
if [ -n "$queued_model" ]; then
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.new"
fi
