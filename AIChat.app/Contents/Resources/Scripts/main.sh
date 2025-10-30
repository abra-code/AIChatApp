#!/bin/sh

echo "[$(/usr/bin/basename "$0")]"
echo "OMC_CURRENT_COMMAND_GUID: ${OMC_CURRENT_COMMAND_GUID}"

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "AICHAT_MODEL_PATH = $AICHAT_MODEL_PATH"
echo "OMC_OBJ_PATH = $OMC_OBJ_PATH"

#if we have a model file bundled or a file was dropped on the app
if [ -n "$AICHAT_MODEL_PATH" ] || [ -n "$OMC_OBJ_PATH" ]; then
	# a file or folder dropped on the app icon
	"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.new"
else
	# launched without a dropped object, present a choose object dialog
	"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.open.from.file.browser"
fi
