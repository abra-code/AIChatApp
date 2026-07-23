#!/bin/sh
# aichat.chat.new.sh
# New Chat (toolbar): clear the embedded Chat to a fresh conversation with the CURRENT model
# (no model re-pick - the Model button switches models). Injecting an empty transcript
# REPLACES the displayed conversation; unbinding the session key makes the next finalized
# entry mint a new session dir. Keeps the sidebar and the running server as-is.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

win="$OMC_ACTIONUI_WINDOW_UUID"
CHAT_VIEW_ID=1
TABLE_ID=510
INFO_TEXT_ID=540
ROW_BUTTONS="521 520 524"   # Rename Reveal Delete

# Clear the chat view (distinguishing empty transcript so a repeat clear is not deduped) and
# start a fresh session on the next turn.
chat_inject_empty "$win"
pb_set "aichatv2_session_${win}" ""

# Retitle to the active model (stamped by init / model switch).
model_path=$(pb_get "aichatv2_modelpath_${win}")
if [ -n "$model_path" ]; then
    label=$(model_display_label "$model_path")
    chat_window_set_status "$win" "$label"
fi

# Drop any selection and disable the row-action buttons (omc_deselect fires no actionID).
"$dialog" "$win" "$TABLE_ID" omc_deselect
for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_disable; done

# If the info strip is showing, refresh it to the "new conversation" state.
if [ "$(pb_get "aichatv2_info_${win}")" = "1" ]; then
    info="New conversation"
    [ -n "$model_path" ] && info="${info}   ·   Model: $(model_display_label "$model_path")"
    "$dialog" "$win" "$INFO_TEXT_ID" "$info"
fi
