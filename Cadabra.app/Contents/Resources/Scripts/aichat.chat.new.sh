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

# Retitle to whatever drives this window - the active model, or the external ACP agent, which
# has no model path and so used to leave the previous conversation's title sitting there.
label=$(chat_engine_label "$win")
[ -n "$label" ] && chat_window_set_status "$win" "$label"

# Drop any selection and disable the row-action buttons (omc_deselect fires no actionID).
"$dialog" "$win" "$TABLE_ID" omc_deselect
for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_disable; done

# Remove the Summarize checkbox if a conversation was loaded here before. It belongs to a
# resume: there is no older half of a new conversation to summarize, and the slot collapses to
# nothing when the control is gone, so this leaves no empty row behind.
#
# The token is bumped for the same reason the checkbox handler bumps it: a digest started by the
# resume may still be running, and this window is now a blank conversation. Unbinding the
# session above already stops it, but that is a fact about a different key - saying so here means
# the guard does not depend on which of the two happens to be checked.
resume_epoch_bump "$win" >/dev/null
summarize_hide "$win"

# If the info strip is showing, refresh it to the "new conversation" state.
if [ "$(pb_get "aichatv2_info_${win}")" = "1" ]; then
    "$dialog" "$win" "$INFO_TEXT_ID" "New conversation$(chat_engine_info_suffix "$win")"
fi
