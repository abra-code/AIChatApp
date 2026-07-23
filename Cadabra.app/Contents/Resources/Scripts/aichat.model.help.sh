#!/bin/sh
# aichat.model.help.sh
# Help-button handler for the model dialogs. Opens the Model Guide viewer
# (non-blocking) without closing the window the user is in.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.model.help.dialog"
