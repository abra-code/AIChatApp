#!/bin/sh
# aichat.history.selection.changed.sh
# A sidebar row was clicked: load that conversation into the embedded Chat element in place
# (re-injecting states["content"] REPLACES the displayed transcript), bind this window to
# the session so typing continues it, enable the row-action buttons, and refresh the info
# strip if it is showing. No Open/Continue step - selecting IS opening; typing IS continuing
# (with the currently-loaded model, whatever it is).
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"

win="$OMC_ACTIONUI_WINDOW_UUID"
CHAT_VIEW_ID=1
INFO_TEXT_ID=540
ROW_BUTTONS="521 520 524"   # Rename Reveal Delete

# Column 2 (hidden trailing field) holds the session id.
sid="$OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE"

if [ -z "$sid" ] || ! history_valid_sid "$sid"; then
    for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_disable; done
    exit 0
fi

# Load the transcript into the chat (replaces whatever was shown) and bind the window to the
# session so aichat.chat.entry.sh appends new turns to it instead of minting a new session.
history_inject_content "$win" "$CHAT_VIEW_ID" "$sid"
pb_set "aichatv2_session_${win}" "$sid"

for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_enable; done

# Refresh the info strip if it is showing.
if [ "$(pb_get "aichatv2_info_${win}")" = "1" ]; then
    info=$(history_info_line "$sid")
    [ -n "$info" ] && "$dialog" "$win" "$INFO_TEXT_ID" "$info"
fi
