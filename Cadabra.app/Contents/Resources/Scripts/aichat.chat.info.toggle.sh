#!/bin/sh
# aichat.chat.info.toggle.sh
# (i) toolbar button: show/hide a slim one-line info strip above the chat (original model,
# start date, message count). It truly collapses when hidden by INSERTING / REMOVING a Text
# element in the info-slot container (id 541) - omc_hide would leave a gap. The current
# conversation is whichever session this window is bound to (empty = a fresh New Chat).
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

win="$OMC_ACTIONUI_WINDOW_UUID"
INFO_SLOT_ID=541
INFO_TEXT_ID=540
FLAG_KEY="aichatv2_info_${win}"

if [ "$(pb_get "$FLAG_KEY")" = "1" ]; then
    # Currently shown -> hide (collapse the slot back to zero height).
    "$dialog" "$win" "$INFO_TEXT_ID" omc_remove_element
    pb_set "$FLAG_KEY" "0"
    exit 0
fi

# Build the info line for the current conversation.
sid=$(pb_get "aichatv2_session_${win}")
info=""
if [ -n "$sid" ] && history_valid_sid "$sid"; then
    info=$(history_info_line "$sid")
fi
if [ -z "$info" ]; then
    # No session yet (a New Chat that has not been sent). Name whichever engine this window
    # was opened with, so the strip is never just "New conversation" with nothing after it.
    info="New conversation$(chat_engine_info_suffix "$win")"
fi

# Insert a fresh Text into the slot (defensively remove any stale one first), then set text.
"$dialog" "$win" "$INFO_TEXT_ID" omc_remove_element 2>/dev/null
"$dialog" "$win" "$INFO_SLOT_ID" omc_insert_element '{"type":"Text","id":540,"properties":{"font":"footnote","foregroundStyle":"secondary","textSelection":"enabled","padding":{"top":5,"bottom":5,"leading":14,"trailing":14},"frame":{"maxWidth":"infinity","alignment":"leading"}}}'
"$dialog" "$win" "$INFO_TEXT_ID" "$info"
pb_set "$FLAG_KEY" "1"
