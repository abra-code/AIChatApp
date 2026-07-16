#!/bin/sh

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

echo "[$(/usr/bin/basename "$0")]"

# this handler is called when the Open menu item is selected
if [ -n "$OMC_DLG_CHOOSE_FILE_PATH" ]; then
    selected_path="$OMC_DLG_CHOOSE_FILE_PATH"

    activate_if_model_running "$selected_path" && exit 0

    # Engine-dispatched, and named new_bytes so it stops shadowing the model_bytes FUNCTION.
    # stat here would size an MLX model at ~320 bytes (the directory entry): non-zero, so it
    # clears warn_ram_pressure_for_new_model's `-gt 0` guard, then never trips the threshold -
    # the warning silently never fires for exactly the models big enough to need it.
    new_bytes=$(model_bytes "$selected_path")
    model_label=$(model_display_label "$selected_path")
    warn_ram_pressure_for_new_model "$new_bytes" "$model_label"
    if [ $? -ne 0 ]; then
        exit 0
    fi

    "$pasteboard" "AICHAT_MODEL_PATH" put "$selected_path"
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.new"
fi
