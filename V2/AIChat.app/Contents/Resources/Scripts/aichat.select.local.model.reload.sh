#!/bin/bash
# aichat.select.local.model.reload.sh
# Re-scans local model caches by chaining to the init script.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.select.local.model.init"
