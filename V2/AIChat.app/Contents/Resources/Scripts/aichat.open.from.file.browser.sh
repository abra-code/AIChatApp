#!/bin/sh

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

echo "[$(/usr/bin/basename "$0")]"

# this handler is called when the Open menu item is selected
if [ -n "$OMC_DLG_CHOOSE_FILE_PATH" ]; then
    selected_path="$OMC_DLG_CHOOSE_FILE_PATH"

    activate_if_model_running "$selected_path" && exit 0

    model_bytes=$(/usr/bin/stat -f%z -L "$selected_path" 2>/dev/null)
    model_label=$(/usr/bin/basename "$selected_path" .gguf)
    warn_ram_pressure_for_new_model "$model_bytes" "$model_label"
    if [ $? -ne 0 ]; then
        exit 0
    fi

    "$pasteboard" "AICHAT_MODEL_PATH" put "$selected_path"
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.new"
fi
