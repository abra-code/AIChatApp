#!/bin/sh
# aichat.select.local.model.ok.sh
# Loads the selected model in a NEW chat window, coexisting with any models already running
# (each window gets its own llama-server on its own port; RAM permitting - the caller already
# warned). If the SAME model is already loaded, activates that window instead of duplicating
# it. An armed in-place switch (Model button) is the one path that reuses the current window.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh"

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

# ── The on-device model: usable right now? ────────────────────────────────────
# Checked HERE rather than by disabling the row, because the two recoverable states are
# invisible from the list and the user cannot act on what they cannot reach. This is the
# point where "Apple Intelligence is off" turns into a button that opens the right pane.
#
# Re-probed rather than trusting what the picker found at open: the dialog is modeless, so
# the user can leave it open, turn Apple Intelligence on (or off) in System Settings, and
# come back. The row's caption may be minutes stale; this answer is not.
if [ "$(model_engine "$selected_path")" = "foundation" ]; then
    fm_probe=$(foundation_probe)
    fm_reason=$(printf '%s' "$fm_probe" | /usr/bin/cut -f1)
    fm_summary=$(printf '%s' "$fm_probe" | /usr/bin/cut -f2)
    echo "foundation: reason=$fm_reason ($fm_summary)"

    case "$fm_reason" in
        available) ;;
        appleIntelligenceOff)
            "$alert" --level caution --title "Turn On Apple Intelligence?" \
                --ok "Open Settings" --cancel "Cancel" \
                "Apple Foundation Models needs Apple Intelligence, which is switched off.

Open System Settings > Apple Intelligence & Siri and turn it on, then come back here, click the refresh button above the model list, and pick this model again. The first time it is enabled macOS downloads the model, which can take a while."
            if [ $? -eq 0 ]; then
                foundation_open_settings
            fi
            # No refresh chained here on purpose. `open` returns as soon as LaunchServices
            # accepts the URL, so a rebuild would re-probe milliseconds later - long before
            # anyone could flip the switch - and re-derive the identical stale caption. What
            # actually keeps this correct is the re-probe at the top of this handler, which
            # runs on the next attempt; Reload resyncs the caption when the user wants it.
            exit 0 ;;
        modelNotReady)
            "$alert" --level caution --title "Still Downloading" --ok "OK" \
                "macOS is still downloading the on-device model.

Leave this Mac on power and connected to the network for a while, then pick this model again."
            exit 0 ;;
        timedOut)
            "$alert" --level caution --title "Not Responding" --ok "OK" \
                "The on-device model did not answer in time.

${fm_summary}"
            exit 0 ;;
        deviceNotEligible|osTooOld|notBuilt)
            # The three verdicts that are genuinely permanent on this machine. Named
            # EXPLICITLY rather than left to the catch-all: those rows are not listed, so
            # reaching here means a stale list, and asserting permanence is only honest for
            # a reason we actually recognize as permanent.
            "$alert" --level stop --title "Not Available" --ok "OK" \
                "The on-device model cannot be used on this Mac.

${fm_summary}"
            exit 0 ;;
        *)
            # Everything the picker lists but cannot use right now: `unknown`, `probeFailed`,
            # and any code added to the agent after this build. None of them is a verdict about
            # this Mac - they are ignorance, a transient failure, or a state we have not learned
            # yet - so do NOT say "cannot be used on this Mac". The picker deliberately lists
            # these (see foundation_offerable, a denylist); declaring it impossible the moment
            # the user acts on that would undo the point of listing it.
            #
            # `generationFailed` also lands here if it ever reaches this handler. That is right:
            # the agent's guidance is "treat as unusable, detail says why", which is this arm.
            "$alert" --level caution --title "Not Available Right Now" --ok "OK" \
                "The on-device model is not available, for a reason this version does not recognize.

${fm_summary}

Check Apple Intelligence in System Settings, or try again after a macOS update."
            exit 0 ;;
    esac
fi

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

    echo "in-place switch refused (current=$current_engine, selected=$new_engine)"
    # The guard above is gguf-to-gguf ONLY, so this branch is not reached solely by CROSS-engine
    # picks: two different MLX models land here too, and so does a current model that has since
    # been deleted (empty engine). Naming both engines unconditionally produced "runs on mlx and
    # ... runs on mlx", and "runs on  and ..." for the deleted case. Name them only when they
    # actually differ and both are known.
    if [ -n "$current_engine" ] && [ -n "$new_engine" ] && [ "$current_engine" != "$new_engine" ]; then
        switch_why="Switching a conversation to a different engine is not supported yet. This conversation runs on $(model_engine_label "$current_engine") and \"$(model_display_label "$selected_path")\" runs on $(model_engine_label "$new_engine")."
    else
        switch_why="Changing this conversation's model in place is not supported yet."
    fi
    "$alert" --level caution --title "Open in a New Window?" \
        --ok "Open in New Window" --cancel "Cancel" \
        "${switch_why}

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

# Picking a local model turns the external ACP agent off. The two are alternatives for the
# same slot - aichat.chat.init.sh checks the external agent FIRST and ignores the model
# entirely when it is on - so leaving it enabled here would silently discard the model the
# user just chose and start their previous agent instead. The command stays remembered, so
# switching back under Tools > External ACP Agent costs one click, not retyping.
acp_agent_disable

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
