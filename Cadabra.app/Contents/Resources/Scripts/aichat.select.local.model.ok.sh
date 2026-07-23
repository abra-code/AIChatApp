#!/bin/sh
# aichat.select.local.model.ok.sh
# Loads the selected model in a NEW chat window, coexisting with any models already running
# (each window gets its own llama-server on its own port; RAM permitting - the caller already
# warned). If the SAME model is already loaded, activates that window instead of duplicating
# it. An armed in-place switch (Model button) is the one path that reuses the current window.

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
    # ── The in-place switch is GGUF-to-GGUF ONLY ─────────────────────────────
    # The Model button routes through THIS picker (aichat.model.switch.sh arms the switch and
    # opens it), and the picker now lists MLX models - so without this guard a user can reach
    # a cross-engine switch that the switch path is architecturally unable to perform.
    # aichat.chat.switch.model.sh restarts llama-server underneath a transport that was FROZEN
    # with the pinned baseURL, and deliberately re-injects nothing. Both directions break, one
    # loudly and one silently:
    #   gguf -> mlx: launch_model_on_port TERMs the healthy server FIRST, then fails to
    #     load a directory as a gguf - the conversation is left pointing at a dead port.
    #   mlx -> gguf: a server does start, but the window's frozen argv is [--model <dir>] with
    #     no baseURL, so it keeps generating with the OLD model under the NEW title.
    # The real 2x2 (stop/start the server, respawn the agent, re-prime the transcript) is M2
    # piece 4, gated on the ChatView cancel fix. Until then refuse, and offer the one thing
    # that is always correct: open it in a new window, leaving this conversation untouched.
    current_engine=$(model_engine "$current")
    new_engine=$(model_engine "$selected_path")

    if [ "$current_engine" = "gguf" ] && [ "$new_engine" = "gguf" ]; then
        # Engine-dispatched anyway: keeps this branch honest if the guard ever widens.
        new_bytes=$(model_bytes "$selected_path" "$new_engine")
        model_label=$(model_display_label "$selected_path")
        warn_ram_pressure_for_new_model "$new_bytes" "$model_label"
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

    echo "cross-engine switch refused (current=$current_engine, selected=$new_engine)"
    "$alert" --level caution --title "Open in a New Window?" \
        --ok "Open in New Window" --cancel "Cancel" \
        "Switching a conversation between the GGUF and MLX engines is not supported yet.

\"$(model_display_label "$selected_path")\" can be opened in a new chat window instead. The current conversation stays exactly as it is."
    if [ $? -ne 0 ]; then
        echo "user declined the new-window fallback"
        exit 0
    fi
    # Fall through to the normal new-window path below. The switch arm was already consumed,
    # so nothing is left armed to fire later.
fi

# ── Same model already running? ───────────────────────────────────────────────
activate_if_model_running "$selected_path" "$window_uuid" && exit 0

# ── RAM check ────────────────────────────────────────────────────────────────
# Check before closing the window so the user can pick a different model if they cancel.

new_bytes=$(model_bytes "$selected_path")
model_label=$(model_display_label "$selected_path")
warn_ram_pressure_for_new_model "$new_bytes" "$model_label"
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
