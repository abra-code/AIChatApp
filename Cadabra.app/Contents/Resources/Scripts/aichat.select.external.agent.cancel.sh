#!/bin/sh
# aichat.select.external.agent.cancel.sh
# Closes the external-agent window without changing which agent Cadabra uses. The stored
# selection stays as it was: only OK commits that, so backing out must not switch engines.
#
# Edits to the LIST are a different thing and are already saved. Adding, renaming or deleting an
# agent of your own writes straight to settings.plist, the way an entry in a sidebar does; the
# row has to exist before it can be selected, and there is no form here to abandon. So Cancel
# means "do not switch to this", not "undo everything I did in this window".
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

pb_set "aichatv2_extagent_cmd_${OMC_ACTIONUI_WINDOW_UUID}" ""
"$dialog" "$OMC_ACTIONUI_WINDOW_UUID" omc_window omc_terminate_cancel
