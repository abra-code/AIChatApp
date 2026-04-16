#!/bin/sh
# aichat.select.local.model.cancel.sh
# Closes the model selector window.

dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
"$dialog_tool" "$OMC_ACTIONUI_WINDOW_UUID" omc_window omc_terminate_cancel
