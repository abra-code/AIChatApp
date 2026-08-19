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
# Stamped BEFORE the launch because a launch can run for minutes (up to a 300 s wait for a large
# --no-mmap model) and other handlers in this window read the stamp while it is in flight. Nothing
# between here and the launch reads it - the overlay and the button are passed their labels - so the
# early stamp is about concurrency, not about this script.
#
# Rolled back below when the launch fails and frees the port. Leaving a failed model stamped used to
# be invisible; it is not any more, because the resume marker reads this label at send time and
# would name a model that never loaded.
prev_model_path=$(pb_get "aichatv2_modelpath_${target_win}")
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
    # It reaches the display NOW, through the element's append state: an in-place switch
    # deliberately does not re-inject the transcript (the same agent process continues), and
    # re-injecting purely to show a marker would cost a re-prime of the whole conversation.
    #
    # Unless the conversation has not been spoken to yet. Switching models while merely LOOKING at a
    # conversation is the same non-event as clicking its row, and recording it would put a
    # modelChanged into a transcript nothing happened in. The pending resume already covers it: the
    # marker written on the first turn reads the label after this switch, so it names this model.
    switch_sid=$(pb_get "aichatv2_session_${target_win}")
    if [ -n "$switch_sid" ] && \
       [ "$(pb_get "aichatv2_resume_pending_${target_win}")" != "$switch_sid" ]; then
        history_mark_and_show "$target_win" 1 "$switch_sid" modelChanged "$LAUNCHED_MODEL_LABEL"
    fi
    echo "switched to $LAUNCHED_MODEL_LABEL"
else
    # The previous server is ALREADY GONE: launch_model_on_port frees the port first, terminating
    # the outgoing llama-server before it spawns anything. So the stamp goes back to the model that
    # the 530 button is still showing, the only model this window can honestly claim.
    #
    # THE TIMEOUT IS NOT AN EXCEPTION, though it looks like one. wait_for_server's 13 is a /health
    # poll that never checks the pid, so a model that died during tensor load reports exactly like
    # one still loading. And a server that timed out never reaches register_started_server, so it is
    # unprotected: the next chat window to open reaps it. Keeping it stamped would name a model that
    # is unregistered, unreachable and about to be killed - and would leave prev_model_path pointing
    # at it, so the NEXT failed switch would roll back to a model that never loaded either.
    pb_set "aichatv2_modelpath_${target_win}" "$prev_model_path"
    chat_window_set_status "$target_win" "failed to load model"
fi
chat_loading_overlay_hide "$target_win"
