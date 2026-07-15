#!/bin/sh
# aichat.select.local.model.ok.sh
# Loads the selected model: stops any running server, then chains to aichat.chat.

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

# ── In-place model switch? ────────────────────────────────────────────────────
# Armed by a chat window's Model button (aichat.model.switch). Instead of opening a new
# chat window, restart the pinned-port server for THAT window and let its frozen transport
# continue against the new model (see aichat.chat.switch.model.sh).
switch_win=$(model_switch_consume)
if [ -n "$switch_win" ]; then
    current=$(pb_get "aichatv2_modelpath_${switch_win}")
    if [ "$current" = "$selected_path" ]; then
        echo "model unchanged; closing selector"
        "$dialog_tool" "$window_uuid" omc_window omc_terminate_ok
        exit 0
    fi
    model_bytes=$(/usr/bin/stat -f%z -L "$selected_path" 2>/dev/null)
    model_label=$(/usr/bin/basename "$selected_path" .gguf)
    warn_ram_pressure_for_new_model "$model_bytes" "$model_label"
    if [ $? -ne 0 ]; then
        echo "switch cancelled at RAM-pressure warning"
        model_switch_arm "$switch_win"   # re-arm so another pick still switches
        exit 0
    fi
    "$dialog_tool" "$window_uuid" omc_window omc_terminate_ok
    pb_set "aichatv2_switch_target" "$switch_win"
    "$pasteboard" "AICHATV2_MODEL_PATH" put "$selected_path"
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.chat.switch.model"
    exit 0
fi

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

# Queue the chosen model + tools decision for the chat window's init handler (single
# epoch-stamped pasteboard entry - see launch_queue_arm in the base library). The ACP
# transport needs both at once: the tools decision selects whether the agent argv carries
# --mcp-config, and it cannot be re-decided after the transport freezes.
use_tools="${OMC_ACTIONUI_VIEW_30_VALUE:-false}"
launch_queue_arm "$selected_path" "$use_tools"

# When tools are enabled, route through the MCP servers dialog so the user can review
# which servers + sandbox paths apply and pick the session's working directory before
# the session launches. Its Start handler chains to aichat.chat once preferences are
# saved; closing the dialog discards the queued launch. Tools off goes straight to chat.
if [ "$use_tools" = "true" ]; then
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.mcp.servers"
else
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.chat"
fi
