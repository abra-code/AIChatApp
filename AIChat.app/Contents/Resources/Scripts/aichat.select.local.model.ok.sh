#!/bin/sh
# aichat.select.local.model.ok.sh
# Loads the selected model: stops any running server, then chains to aichat.new.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

echo "[$(/usr/bin/basename "$0")]"

dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Column 3 (hidden) holds the full model path
selected_path="$OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE"

if [ -z "$selected_path" ]; then
    echo "No model selected"
    exit 0
fi

echo "Selected model path: $selected_path"

# ── Same model already running? ───────────────────────────────────────────────
activate_if_model_running "$selected_path" "$window_uuid" && exit 0

# ── RAM check ────────────────────────────────────────────────────────────────
# Check before closing the window so the user can pick a different model if they cancel.

model_bytes=$(/usr/bin/stat -f%z -L "$selected_path" 2>/dev/null)
model_label=$(/usr/bin/basename "$selected_path" .gguf)
warn_ram_pressure_for_new_model "$model_bytes" "$model_label"
if [ $? -ne 0 ]; then
    echo "User cancelled load due to RAM pressure warning"
    exit 0
fi

# Close the selector window now that we're committed to loading
"$dialog_tool" "$window_uuid" omc_window omc_terminate_ok

use_tools="${OMC_ACTIONUI_VIEW_30_VALUE:-false}"
"$pasteboard" "AICHAT_MODEL_PATH" put "$selected_path"
"$pasteboard" "AICHAT_USE_TOOLS" put "$use_tools"

# When tools are enabled, route through the MCP servers dialog so the user can
# review which servers + sandbox paths apply before the session launches.
# The dialog's Start handler chains to aichat.new once preferences are saved.
if [ "$use_tools" = "true" ]; then
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.mcp.servers"
else
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.new"
fi
