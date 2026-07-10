#!/bin/sh
# aichat.model.switch.sh
# Toolbar "Model" button: arm an in-place model switch for THIS chat window, then open the
# model selector. The selector's OK handler restarts the pinned-port server for this window
# (no new window; the frozen Chat transport keeps talking to the pinned baseURL, and
# llama-server serves whichever model is loaded). Arming is TTL-stamped so a Cancel can't
# turn a later first-launch pick into a switch.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

model_switch_arm "$OMC_ACTIONUI_WINDOW_UUID"
"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.select.local.model"
