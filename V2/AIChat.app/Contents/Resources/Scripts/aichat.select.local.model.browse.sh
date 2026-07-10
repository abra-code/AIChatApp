#!/bin/sh
# aichat.select.local.model.browse.sh
# Closes the model selector and opens the standard file browser instead.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
"$dialog_tool" "$OMC_ACTIONUI_WINDOW_UUID" omc_window omc_terminate_cancel

"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.open.from.file.browser"
