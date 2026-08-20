#!/bin/sh
# aichat.history.selection.changed.sh
# A sidebar row was clicked: load that conversation into the embedded Chat element in place
# (re-injecting states["content"] REPLACES the displayed transcript) and bind this window to
# the session so typing continues it. Switching is SEAMLESS: the "defer" prime directive
# displays the transcript without touching the agent's context. The Chat element replays the
# conversation into the model (ACP session/prime) lazily, only when the user actually sends a
# message into it, and skips the replay when the agent already holds that conversation
# (browsing away and back is free). The element's status bar dot shows whether the context is
# loaded or loads on the next message.
#
# One conversation in the sidebar does ask a question: a LONG one, once, the first time it is
# resumed. That is the single case where "defer" is not free - the replay still happens, it is
# just deferred, and on a small context window it may not fit at all. See the digest section in
# aichat.history.library.sh. Everything below the threshold, and everything already answered
# for, stays exactly as seamless as it was.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"
# For chat_engine_label: the marker shown below names what will answer the next message.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

win="$OMC_ACTIONUI_WINDOW_UUID"
CHAT_VIEW_ID=1
ROW_BUTTONS="521 520 524"   # Rename Reveal Delete

# Column 2 (hidden trailing field) holds the session id.
sid="$OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE"

if [ -z "$sid" ] || ! history_valid_sid "$sid"; then
    for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_disable; done
    exit 0
fi

# Re-selecting the already-loaded conversation is a no-op (no re-inject): the entry.sh
# first-turn flow re-selects row 0 programmatically, and re-injecting what is already
# loaded would only churn the display.
if [ "$(pb_get "aichatv2_session_${win}")" = "$sid" ]; then
    for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_enable; done
    exit 0
fi

# A RESUME IS THE FIRST MESSAGE SENT INTO A CONVERSATION, NOT THE CLICK THAT DISPLAYED IT. Marking
# it here recorded one for every row the user touched, so browsing a handful of conversations left a
# run of "Resumed with <model>" lines in each with nothing between them - a transcript claiming a
# history of conversations that never happened. Clicking a row is reading, not resuming.
#
# So arm it here and let aichat.chat.entry.sh write the marker when a turn actually arrives. The
# flag carries the SID rather than a bare 1, and that comparison does real work: the window is not
# re-bound until further down this script, so for the few tens of milliseconds it takes to get there
# the flag names the conversation being opened while the session still names the one being left. A
# turn finalizing in that gap - the user clicks away while the agent is still answering - would
# otherwise stamp a resume onto the conversation they just left. It also covers the easier case of a
# conversation armed here and then abandoned (New Chat, another row, a delete).
#
# The marker still reaches the DISPLAY as soon as the conversation is loaded, further down: showing
# one costs nothing (this display is rebuilt from the store on every click) while RECORDING one is
# what claims a conversation was continued. Splitting the two is what lets the line appear where it
# belongs - in front of the message it was sent into, rather than behind it.
pb_set "aichatv2_resume_pending_${win}" "$sid"

# Load the transcript into the chat (replaces whatever was shown) and bind the window to the
# session so aichat.chat.entry.sh appends new turns to it instead of minting a new session.
#
# CONDENSATION IS ASKED FOR HERE AND PERFORMED BY THE AGENT. When this conversation is set to
# summarize, the injected content carries a condense request alongside the defer directive, and
# the agent summarizes at the next send - the same moment the deferred prime happens anyway. The
# DISPLAY is untouched either way: the window keeps the whole conversation while the model is
# given a summary of its older half, and the element appends a marker showing what that summary
# said. Nothing here summarizes anything itself.
#
# The request names WHICH model summarizes, which is why the menu under the chat means what it
# says. It used to name only "summarize", leaving the summarizer to a flag fixed when the agent
# launched - so the conversation could be summarized by a model the user had not chosen, and the
# only sign of it was the name in the marker afterwards.
#
# An agent that does not understand condense primes the complete history and says so, so asking
# costs nothing on a transport that cannot serve it.
resolved=$(summarize_resolve "$win" "$sid")
resume_mode=${resolved%% *}
if [ "$resume_mode" = "full" ]; then
    history_inject_content "$win" "$CHAT_VIEW_ID" "$sid" "defer"
    loaded=$?
else
    history_inject_content "$win" "$CHAT_VIEW_ID" "$sid" "defer" "$CAD_DIGEST_KEEP_RECENT" \
        "$(summarize_request_backend "$resolved")"
    loaded=$?
fi
# BINDING FOLLOWS THE DISPLAY. history_inject_content fails when the conversation could not be
# read at all, and binding anyway would leave the window showing the previous conversation while
# every message typed into it was appended to this one. Disarm the resume with it: nothing was
# resumed.
#
# The status is captured on the spot rather than read after the `fi`, which would work today and
# stop working the moment anything is added below either branch.
if [ "$loaded" -ne 0 ]; then
    pb_set "aichatv2_resume_pending_${win}" ""
    chat_window_set_status "$win" "could not open this conversation"
    for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_enable; done
    exit 0
fi
# THE MARKERS SHOWN FOR THE CONVERSATION BEING LEFT GO FIRST, before this window is bound to the
# new one. The injection above replaced the transcript, so they are already off the screen; what
# the order buys is the gap between here and the bind below. An entry finalizing in that gap - the
# user clicks away while the agent is still answering - would otherwise find the window bound to
# the NEW conversation while the queue still held the old one's markers, and record them there.
# It is the same race the sid on the arm was written to narrow, and it is narrowed the same way:
# in the remaining gap the arm names the new conversation and the binding still names the old, so
# aichat.chat.entry.sh's commit test fails and nothing is recorded at all.
history_marker_clear "$win"
pb_set "aichatv2_session_${win}" "$sid"

# WHAT THIS WINDOW IS ABOUT TO CONTINUE WITH, at the end of the conversation just loaded and in
# front of whatever the user types next.
#
# Nothing is shown while this window has no engine: there would be no model to name. Such a window
# is reading rather than resuming, and its marker is shown by chat_engine_load when a model arrives.
engine_label=$(chat_engine_label "$win")
[ -n "$engine_label" ] && history_marker_show "$win" "$CHAT_VIEW_ID" resumed "$engine_label"

# The Summarize checkbox belongs to a RESUME, so it is created here and nowhere else. A new
# chat has no older half to summarize, and a checkbox offering to condense an empty
# conversation would be a control that cannot do anything.
#
# Set by default only when the conversation is long enough to be worth it - that is the
# recommendation the number supports, not a preference. An earlier answer for this conversation
# wins over the recommendation, because a user who answered once should not have to keep
# answering.
#
# Handed the resolution the restore above was built from, so the control cannot show one thing
# while the agent was asked for another.
summarize_show "$win" "$sid" "$resolved"

# Title: which conversation is loaded (context state shows in the chat's status bar).
title=$(history_title "$sid")
chat_window_set_status "$win" "$title"

for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_enable; done

# The facts line now describes the conversation that was just loaded. Called after the window
# was rebound above, which is what makes it name this conversation rather than the last one.
chat_info_refresh "$win"
