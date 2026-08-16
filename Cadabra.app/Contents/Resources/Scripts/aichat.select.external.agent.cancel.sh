#!/bin/sh
# aichat.select.external.agent.cancel.sh
# Closes the external-agent window, changing nothing. The stored agent (if any) stays as it
# was: this dialog only ever commits on OK, so backing out of it must not switch engines.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

pb_set "aichatv2_extagent_cmd_${OMC_ACTIONUI_WINDOW_UUID}" ""
"$dialog" "$OMC_ACTIONUI_WINDOW_UUID" omc_window omc_terminate_cancel
