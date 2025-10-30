#!/bin/sh

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

# this handler is called when the Open menu item is selected
if [ -n "$OMC_DLG_CHOOSE_FILE_PATH" ]; then
	"$pasteboard" "AICHAT_MODEL_PATH" put "$OMC_DLG_CHOOSE_FILE_PATH";
	"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.new"
fi
