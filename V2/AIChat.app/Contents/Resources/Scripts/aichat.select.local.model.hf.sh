#!/bin/sh
# aichat.select.local.model.hf.sh
# Closes the local model selector and opens the Hugging Face browser.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

"$dialog" "$OMC_ACTIONUI_WINDOW_UUID" omc_window omc_terminate_cancel
"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.hf.browse"
