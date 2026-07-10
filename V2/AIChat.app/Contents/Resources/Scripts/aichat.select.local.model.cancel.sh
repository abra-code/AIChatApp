#!/bin/sh
# aichat.select.local.model.cancel.sh
# Closes the model selector window. Also clears any armed in-place model-switch handoff so a
# Model-button-then-cancel cannot leave a stale arm that turns a later first-launch model
# pick into an in-place switch of the wrong window (the arm is otherwise only consumed on OK).
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

pb_set "$MODEL_SWITCH_KEY" ""
"$dialog" "$OMC_ACTIONUI_WINDOW_UUID" omc_window omc_terminate_cancel
