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
# For chat_engine_label: the marker names the model answering from here on, and only this app
# knows it - mlx-agent advertises no configOptions, so the element is never told.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

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

# Re-selecting the already-loaded conversation is a no-op (no re-inject): the entry.sh
# first-turn flow re-selects row 0 programmatically, and re-injecting what is already
# loaded would only churn the display.
if [ "$(pb_get "aichatv2_session_${win}")" = "$sid" ]; then
    for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_enable; done
    exit 0
fi

# Record the resume BEFORE the transcript is read, so the marker is the last thing in it: the
# reader sees the conversation, then "Resumed with <model>", then whatever they say next. It also
# means the injection below already contains it, with no second write to the element.
history_mark_session "$sid" resumed "$(chat_engine_label "$win")"

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
# An agent that does not understand condense primes the complete history and says so, so asking
# costs nothing on a transport that cannot serve it.
if [ "$(history_resume_mode "$sid")" = "full" ] || ! summarize_can_condense "$sid"; then
    history_inject_content "$win" "$CHAT_VIEW_ID" "$sid" "defer"
else
    history_inject_content "$win" "$CHAT_VIEW_ID" "$sid" "defer" "$CAD_DIGEST_KEEP_RECENT"
fi
pb_set "aichatv2_session_${win}" "$sid"


# The Summarize checkbox belongs to a RESUME, so it is created here and nowhere else. A new
# chat has no older half to summarize, and a checkbox offering to condense an empty
# conversation would be a control that cannot do anything.
#
# Checked by default only when the conversation is long enough to be worth it - that is the
# recommendation the number supports, not a preference. An earlier answer for this conversation
# wins over the recommendation, because a user who unchecked it once should not have to keep
# unchecking it.
summarize_show "$win" "$sid"

# Title: which conversation is loaded (context state shows in the chat's status bar).
title=$(history_title "$sid")
chat_window_set_status "$win" "$title"

for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_enable; done

# Refresh the info strip if it is showing.
if [ "$(pb_get "aichatv2_info_${win}")" = "1" ]; then
    info=$(history_info_line "$sid")
    [ -n "$info" ] && "$dialog" "$win" "$INFO_TEXT_ID" "$info"
fi
