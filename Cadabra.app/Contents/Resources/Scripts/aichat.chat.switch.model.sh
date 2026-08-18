#!/bin/sh
# aichat.chat.switch.model.sh
# In-place model switch: restart llama-server for the chosen model on the window's OWN port,
# targeting the ORIGINAL chat window (its UUID + the chosen model were stashed by the
# selector's OK handler in switch mode). The Chat element's transport is frozen to that
# window's baseURL and llama-server serves whichever model is loaded, so NO config re-inject
# is needed - the same window and conversation continue with the new model. No new window.
# The window's port was claimed and stashed at init (aichatv2_port_<win>); reusing it is what
# lets the frozen baseURL stay valid while other windows' servers keep running untouched.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.server.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"
# For history_mark_session: the switch is recorded in the conversation's own transcript.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"

MODEL_BTN_ID=530

target_win=$(pb_get "aichatv2_switch_target")
pb_set "aichatv2_switch_target" ""
model_path=$("$pasteboard" "AICHATV2_MODEL_PATH" get)
"$pasteboard" "AICHATV2_MODEL_PATH" set ""

[ -n "$target_win" ] || { echo "no target window for switch"; exit 0; }
[ -n "$model_path" ] || { echo "no model for switch"; exit 0; }

# The window's frozen baseURL points at this port; the switch MUST reuse it or the window
# would keep talking to the old (now dead) port. A window launched under this code always has
# it stashed; bail loudly rather than silently relaunch on a different port.
target_port=$(pb_get "aichatv2_port_${target_win}")
[ -n "$target_port" ] || { echo "no stashed port for window $target_win; cannot switch in place"; exit 0; }

echo "switching window $target_win to model $model_path on port $target_port"
chat_window_set_status "$target_win" "loading model…"
pb_set "aichatv2_modelpath_${target_win}" "$model_path"
chat_loading_overlay_show "$target_win" "$(model_display_label "$model_path")"

launch_model_on_port "$model_path" "$target_win" "$target_port"
if [ $? -eq 0 ]; then
    "$dialog" "$target_win" "$MODEL_BTN_ID" omc_set_property "title" "$LAUNCHED_MODEL_LABEL"
    chat_window_set_status "$target_win" "$LAUNCHED_MODEL_LABEL"
    # The handover, recorded in the conversation it happened in. This is the case the info pane
    # cannot describe at all: it names the model the session STARTED with, and an in-place switch
    # keeps the same session, so without a marker the transcript has two stretches of assistant
    # turns written by different models and nothing saying where one ends.
    #
    # It reaches the display on the next load, not now: an in-place switch deliberately does not
    # re-inject the transcript (the same agent process continues), and re-injecting purely to show
    # a marker would cost a re-prime of the whole conversation.
    switch_sid=$(pb_get "aichatv2_session_${target_win}")
    [ -n "$switch_sid" ] && history_mark_session "$switch_sid" modelChanged "$LAUNCHED_MODEL_LABEL"
    echo "switched to $LAUNCHED_MODEL_LABEL"
else
    chat_window_set_status "$target_win" "failed to load model"
fi
chat_loading_overlay_hide "$target_win"
