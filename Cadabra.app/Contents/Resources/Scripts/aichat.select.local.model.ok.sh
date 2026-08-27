#!/bin/sh
# aichat.select.local.model.ok.sh
# Loads the selected model in a NEW chat window, coexisting with any models already running
# (each window gets its own llama-server on its own port; RAM permitting - the caller already
# warned). If the SAME model is already loaded, activates that window instead of duplicating
# it. An armed handoff from a chat window's model bar is what reuses an existing window
# instead: an in-place switch when that window already has a model, and a first engine when it
# has none (File > New Chat Window). Both branches are below; the switch refuses only an
# external agent's window, and says why where it does it.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh"

echo "[$(/usr/bin/basename "$0")]"

dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Column 5 (hidden) holds the full model path - the picker draws four (format icon, Model,
# tools icon, Size) and carries this one past them. See aichat.select.local.model.init.sh.
selected_path="$OMC_ACTIONUI_TABLE_10_COLUMN_5_VALUE"

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
# Armed by a chat window's model bar (aichat.model.switch) and captured by this selector's own
# init, so two selectors open at once cannot answer for each other. Instead of opening a new chat
# window, hand THAT window's conversation to the chosen model: a server restart when both are
# GGUF, and a new agent primed from the transcript otherwise (see aichat.chat.switch.model.sh).
switch_win=$(model_switch_consume_for "$window_uuid")

# STILL THERE? The selector owns its arm for its whole life now, so the chat window that asked
# for this can be closed while the user is still choosing - and the close cannot reach an arm
# held in here. Both branches below end at a handler that checks the window is open and drops
# the launch, which is right, but silently: the selector closed and nothing happened at all.
#
# Dropping the arm instead sends the pick down the ordinary new-window path below, which is
# what a model pick meant before any of this existed and is the only useful thing left to do
# with it - the user asked for this model, and the window they asked it FOR is gone.
if [ -n "$switch_win" ] && ! chat_window_is_open "$switch_win"; then
    echo "chat window $switch_win closed while its model was being chosen - opening a new one"
    switch_win=""
fi

if [ -n "$switch_win" ]; then
    current=$(pb_get "aichatv2_modelpath_${switch_win}")

    # ── An EMPTY window's first model, which is not a switch ─────────────────
    # File > New Chat Window opens with no engine at all, and its model bar button routes
    # here through the very same arming the toolbar used to do - so this branch has to tell
    # "change the model of a running conversation" from "give this window one to begin with".
    # Both stamps empty is that second thing, and only that: chat init stamps exactly one of
    # the pair for every engine it starts, INCLUDING the external agent (which is why the
    # agent is checked here at all - an external window has no model path either).
    #
    # It differs from the switch in what it has to arrange rather than in what it may load: with
    # no engine yet there is no agent to replace, no port to reuse and no conversation to carry,
    # so the load goes through the ordinary launch queue - aimed at this window instead of a new
    # one - and detours through the MCP servers dialog when tools are on, which is where a fresh
    # session's servers and working directory are chosen.
    if [ -z "$current" ] && [ -z "$(pb_get "aichatv2_agent_${switch_win}")" ]; then
        first_engine=$(model_engine "$selected_path")
        first_bytes=$(model_bytes "$selected_path" "$first_engine")
        first_label=$(model_display_label "$selected_path")
        warn_ram_pressure_for_new_model "$first_bytes" "$first_label"
        if [ $? -ne 0 ]; then
            echo "first model load cancelled at RAM-pressure warning"
            model_switch_rearm_for "$window_uuid" "$switch_win"   # still ours to carry out
            exit 0
        fi
        echo "first model for empty window $switch_win: $selected_path"
        # The same rule the new-window path states below: choosing a local model turns the
        # stored external ACP agent off. This window is unaffected either way (the load is
        # dispatched with external=false), but the PREFERENCE is app-wide, so leaving it on
        # means the next File > New Chat Window opens on the agent the user just chose against.
        acp_agent_disable
        "$dialog_tool" "$window_uuid" omc_window omc_terminate_ok
        load_target_arm "$switch_win"
        launch_queue_arm "$selected_path" "${OMC_ACTIONUI_VIEW_30_VALUE:-false}"
        # Tools on routes through the MCP servers dialog exactly as a new window's launch does -
        # this is where the servers and sandbox paths for a session are chosen, and its Start hands
        # the launch back with the window still named.
        if [ "${OMC_ACTIONUI_VIEW_30_VALUE:-false}" = "true" ]; then
            "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.mcp.servers"
        else
            "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.chat.load.model"
        fi
        exit 0
    fi

    # UNCHANGED MEANS BOTH HALVES. The checkbox is this window's own tools decision now (the row
    # click seeds it from the stamp), so picking the same model with the box toggled is a
    # deliberate gesture - "keep this model, give it its tools" - and closing the selector on it
    # would answer a request by discarding it.
    #
    # An unstamped window - loaded before the stamp existed - stays on the unchanged side, and
    # that clause is a POLICY, not a duplicate of a check further down: an unrecorded decision is
    # not a request, because nothing knows what it would be changing FROM. The switch agrees with
    # it (chat_engine_switch reads an empty stamp as unchanged in both places it asks), so the two
    # gates cannot disagree about the same pick - but do not delete this on the grounds that the
    # switch would catch it anyway. What the switch would do with the pick this lets through is
    # respawn an MLX agent, or restart a llama-server that is already serving the right model.
    switch_tools_now=$(pb_get "aichatv2_tools_${switch_win}")
    if [ "$current" = "$selected_path" ] && \
       { [ -z "$switch_tools_now" ] || [ "${OMC_ACTIONUI_VIEW_30_VALUE:-false}" = "$switch_tools_now" ]; }; then
        echo "model unchanged; closing selector"
        "$dialog_tool" "$window_uuid" omc_window omc_terminate_ok
        exit 0
    fi
    # ── The in-place switch, over the whole engine matrix ────────────────────
    # This used to be GGUF-to-GGUF ONLY, and the reason it was is worth keeping: the switch
    # handler restarted llama-server on the window's pinned port and re-injected NOTHING,
    # believing the Chat element had frozen its transport on the first config it received. Under
    # that belief every other pair was unreachable - an MLX model is an argv, not a server, and a
    # frozen argv cannot be changed - so both cross-engine directions broke, one loudly and one
    # silently, and the guard refused them all with the offer of a new window.
    #
    # The element does not freeze anything. A DIFFERENT viable config re-configures it in place:
    # the old agent is stopped, a new one is built from the new argv, and it is primed from the
    # transcript on screen. So every pair of local engines is reachable, and which of them needs
    # a re-injection - and in what order, against a server that has to exist first - is
    # chat_engine_switch's business, not this handler's. What is decided HERE is what the user is
    # allowed to ask for and what it costs in memory.
    current_agent=$(pb_get "aichatv2_agent_${switch_win}")
    if [ -n "$current_agent" ]; then
        # The one pair that stays refused, and not for want of a mechanism. An external ACP agent
        # owns its session, its context and its tool loop; none of it is portable, and priming a
        # local model with a transcript the agent produced would hand it someone else's
        # conversation to continue as if it were its own.
        echo "in-place switch refused: window $switch_win runs the external agent $current_agent"
        "$alert" --level caution --title "Open in a New Window?" \
            --ok "Open in New Window" --cancel "Cancel" \
            "This conversation runs on ${current_agent}, and a conversation cannot be moved from an agent to a local model.

\"$(model_display_label "$selected_path")\" can be opened in a new chat window instead. The current conversation stays exactly as it is."
        if [ $? -ne 0 ]; then
            echo "user declined the new-window fallback"
            exit 0
        fi
        # Fall through to the normal new-window path below. The switch arm was already consumed,
        # so nothing is left armed to fire later.
    else
        new_engine=$(model_engine "$selected_path")
        if [ -z "$new_engine" ]; then
            # Deleted between the scan that listed it and the click. Refused HERE rather than by
            # the switch handler, so the picker is still open and the user can choose again -
            # which is what the re-arm below is for.
            model_alert_not_loadable "$selected_path"
            model_switch_rearm_for "$window_uuid" "$switch_win"   # still ours to carry out
            exit 0
        fi
        # Conservative on a switch, and knowingly: the model about to be FREED is counted among
        # the running ones, because nothing has been stopped yet and this warning is shown before
        # anything is. A switch that would fit only after the outgoing model is gone can still be
        # warned about; the user is the one who knows they are replacing rather than adding.
        new_bytes=$(model_bytes "$selected_path" "$new_engine")
        model_label=$(model_display_label "$selected_path")
        warn_ram_pressure_for_new_model "$new_bytes" "$model_label"
        if [ $? -ne 0 ]; then
            echo "switch cancelled at RAM-pressure warning"
            model_switch_rearm_for "$window_uuid" "$switch_win"   # still ours to carry out
            exit 0
        fi
        echo "in-place switch: window $switch_win to $selected_path ($new_engine)"
        "$dialog_tool" "$window_uuid" omc_window omc_terminate_ok
        pb_set "aichatv2_switch_target" "$switch_win"
        # The tools decision rides along with the model. The row click seeded the checkbox from
        # what this window is actually running with (aichat.select.local.model.selection.changed),
        # so leaving it alone carries that forward and changing it means it: every cell rebuilds
        # the agent process, and gguf-to-gguf does too when this is the only thing that changed.
        #
        # Unlike a FIRST load, this does not detour through the MCP servers dialog. Worth being
        # honest about what that costs: the server set and the working directory are app-wide
        # preferences re-read when the transport is built, so a tools-on switch adopts whatever
        # they say NOW, which another window's dialog may have changed since this conversation
        # started. Carrying a per-window snapshot of them is the fix, and it is not this change.
        pb_set "aichatv2_switch_tools" "${OMC_ACTIONUI_VIEW_30_VALUE:-false}"
        "$pasteboard" "AICHATV2_MODEL_PATH" put "$selected_path"
        "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.chat.switch.model"
        exit 0
    fi
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
# --mcp-config, so changing it later means replacing the agent (which is what an in-place switch
# does when that decision is the thing that changed).
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
