#!/bin/sh
# aichat.chat.switch.model.sh
# In-place model switch: restart llama-server for the chosen model on the pinned port,
# targeting the ORIGINAL chat window (its UUID + the chosen model were stashed by the
# selector's OK handler in switch mode). The Chat element's transport is frozen to the
# pinned baseURL and llama-server serves whichever model is loaded, so NO config re-inject
# is needed - the same window and conversation continue with the new model. No new window.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.server.library.sh"

MODEL_BTN_ID=530

target_win=$(pb_get "aichatv2_switch_target")
pb_set "aichatv2_switch_target" ""
model_path=$("$pasteboard" "AICHATV2_MODEL_PATH" get)
"$pasteboard" "AICHATV2_MODEL_PATH" set ""

[ -n "$target_win" ] || { echo "no target window for switch"; exit 0; }
[ -n "$model_path" ] || { echo "no model for switch"; exit 0; }

echo "switching window $target_win to model $model_path"
chat_window_set_status "$target_win" "loading model…"
pb_set "aichatv2_modelpath_${target_win}" "$model_path"
chat_loading_overlay_show "$target_win" "$(/usr/bin/basename "$model_path" .gguf)"

launch_model_on_pinned_port "$model_path" "$target_win"
if [ $? -eq 0 ]; then
    "$dialog" "$target_win" "$MODEL_BTN_ID" omc_set_property "title" "$LAUNCHED_MODEL_LABEL"
    chat_window_set_status "$target_win" "$LAUNCHED_MODEL_LABEL"
    echo "switched to $LAUNCHED_MODEL_LABEL"
else
    chat_window_set_status "$target_win" "failed to load model"
fi
chat_loading_overlay_hide "$target_win"
