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
# WITHDRAWN BEFORE THIS WINDOW CAN MINT ANYTHING, not further down with the new conversation's own
# line. The markers held here were minted for the transcript the inject above just emptied, and
# between this handler's first line and its last there are several subprocess spawns - a message
# finalizing in that gap mints a session and records whatever the queue is holding as its opening
# line, which would be a resume of the conversation the user just left at the top of a brand-new
# one. Nothing else in this handler needs the old queue, so there is no reason to carry it.
history_marker_clear "$win" "$CHAT_VIEW_ID"
pb_set "aichatv2_session_${win}" ""
# Whatever the sidebar armed belongs to the conversation being left behind. The next turn mints a
# new session and never looks at the flag, and the turn after that would fail its SID check - but
# leaving a stale arm lying around to be refused later is not the same as clearing it.
pb_set "aichatv2_resume_pending_${win}" ""

# WHAT DRIVES THIS WINDOW - the active model, or the external ACP agent, which has no model path.
# Empty for a window that has no engine yet, an ordinary state since File > New Chat Window.
#
# This used to be the window's new title as well, because the old one named the conversation
# being cleared. The title reports nothing now (see aichat.library.sh); what a New Chat leaves
# behind it is an empty transcript, a facts line reading "New conversation", and the model bar
# still naming the engine that is about to answer the next message - none of which this handler
# has to correct.
label=$(chat_engine_label "$win")

# The new conversation's opening line, held for the message that will start it. What this window
# was holding for the conversation being left went with the inject, at the top of this handler.
#
# Nothing to hold for a window with no engine: there would be no model to name, and the marker is
# minted by chat_engine_load when one arrives.
[ -n "$label" ] && history_marker_lead "$win" "$CHAT_VIEW_ID" started "$label"

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
