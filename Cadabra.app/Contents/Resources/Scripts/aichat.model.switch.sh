#!/bin/sh
# aichat.model.switch.sh
# The model bar's button: arm the next model pick to land in THIS chat window, then open the
# model selector.
#
# ONE gesture, two outcomes, and this script deliberately does not choose between them -
# the selector's OK handler does, from what the window actually has. A window with a model
# gets an in-place switch (the pinned-port server restarts under a frozen Chat transport that
# keeps talking to the same baseURL). A window with none - File > New Chat Window - gets its
# first engine injected instead, which is the unrestricted path because nothing is frozen yet.
#
# Arming is TTL-stamped so a Cancel cannot turn a later first-launch pick into either one.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

model_switch_arm "$OMC_ACTIONUI_WINDOW_UUID"
"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.select.local.model"
