#!/bin/sh
# aichat.chat.error.sh
# Fires on a transport / parse error (errorActionID). Surface it as a toast and log the
# full context. The envelope carries the error detail in the ActionUI trigger context.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

win="$OMC_ACTIONUI_WINDOW_UUID"
ctx="$OMC_ACTIONUI_TRIGGER_CONTEXT"

echo "[$(/usr/bin/basename "$0")] chat transport error: $ctx"

"$dialog" "$win" omc_window omc_present_toast "Chat error - check the model server is running." 5
