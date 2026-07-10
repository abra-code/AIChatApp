#!/bin/sh
# aichat.history.refresh.sh
# Repopulate the sidebar list (Table 510) in the current window from the store. Chained by
# rename/delete so the list reflects the change without touching the model/server.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"
history_populate_table "$OMC_ACTIONUI_WINDOW_UUID" 510
