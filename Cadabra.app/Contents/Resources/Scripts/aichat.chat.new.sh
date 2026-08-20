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
ROW_BUTTONS="521 520 524"   # Rename Reveal Delete

# Clear the chat view (distinguishing empty transcript so a repeat clear is not deduped) and
# start a fresh session on the next turn.
chat_inject_empty "$win"
pb_set "aichatv2_session_${win}" ""
# Whatever the sidebar armed belongs to the conversation being left behind. The next turn mints a
# new session and never looks at the flag, and the turn after that would fail its SID check - but
# leaving a stale arm lying around to be refused later is not the same as clearing it.
pb_set "aichatv2_resume_pending_${win}" ""

# Retitle to whatever drives this window - the active model, or the external ACP agent, which
# has no model path and so used to leave the previous conversation's title sitting there.
# Falls back to the app's own name rather than doing nothing. chat_engine_label answers
# nothing for a window that has no engine yet - an ordinary state since File > New Chat Window
# - and "do nothing" there left the cleared conversation's title sitting above an empty
# transcript, naming a chat this window is no longer showing.
label=$(chat_engine_label "$win")
chat_window_set_status "$win" "${label:-$APPLET_NAME}"

# The new conversation's opening line, in front of the message that will start it. The inject
# above emptied the transcript, so the markers shown for the conversation being left are off the
# screen and must not be recorded into whatever this window types next - clear before showing.
#
# Nothing to show for a window with no engine: there would be no model to name, and the marker is
# shown by chat_engine_load when one arrives.
history_marker_clear "$win"
[ -n "$label" ] && history_marker_show "$win" "$CHAT_VIEW_ID" started "$label"

# Drop any selection and disable the row-action buttons (omc_deselect fires no actionID).
"$dialog" "$win" "$TABLE_ID" omc_deselect
for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_disable; done

# Remove the Summarize checkbox if a conversation was loaded here before. It belongs to a
# resume: there is no older half of a new conversation to summarize, and the slot collapses to
# nothing when the control is gone, so this leaves no empty row behind.
summarize_hide "$win"

# The facts line, back to the state it describes. The session key was unbound above, so this
# resolves to "New conversation" on its own - it is not told what to say.
chat_info_refresh "$win"
