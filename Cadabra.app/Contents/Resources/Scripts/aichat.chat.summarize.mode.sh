#!/bin/sh
# aichat.chat.summarize.mode.sh
# The "On resume" menu under the chat (Picker id 561, in the slot built by summarize_show).
#
#   full        replay the conversation as it was
#   auto        summarize, and let the agent pick the summarizer by measuring
#   session     summarize with the model this chat is already running
#   foundation  summarize with Apple Intelligence - macOS 26 and later only
#
# NOTHING HERE SUMMARIZES ANYTHING. The agent does it, at the next prime, because the injected
# content carries session/prime's condense object. This handler only records the choice and
# re-injects so the request reaches the wire.
#
# ONE CHOICE, ONE LIFETIME: it belongs to this conversation and takes effect on the next message
# sent into it. Both halves - whether to summarize and which model does it - ride on the same
# condense object, so what is picked here is what the agent is asked for.
#
# It was not always so. The summarizer was the agent's --digest-backend, fixed when the agent
# launched and shared app-wide, so this menu could only affect the NEXT chat window: pick a
# summarizer, send a message, and the marker afterwards named a different model with nothing on
# screen to explain why. The condense object now carries the summarizer per restore, and this
# handler no longer writes an app-wide setting - there is nothing left for one to mean.
#
# EVERY OPTION IS NON-DESTRUCTIVE. journal.jsonl is append-only and no branch writes to it, so
# switching back to "full" restores the whole conversation on the next prime.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"

win="$OMC_ACTIONUI_WINDOW_UUID"
CHAT_VIEW_ID=1

sid=$(pb_get "aichatv2_session_${win}")
if [ -z "$sid" ] || ! history_valid_sid "$sid"; then
    # No conversation bound to this window - a New Chat. The menu should not exist here, so remove
    # it rather than leave a control that answers for nothing.
    summarize_hide "$win"
    exit 0
fi

mode="${OMC_ACTIONUI_VIEW_561_VALUE:-full}"
case "$mode" in
    auto|session|foundation) ;;
    # Anything unrecognized is treated as "full". Defaulting the other way would turn a missing or
    # malformed value into a summarize, which is the branch that changes what the model is given.
    *) mode=full ;;
esac

history_set_resume_mode "$sid" "$mode"

# Re-inject so the request (or its absence) reaches the agent at the next prime. The DISPLAY is
# identical either way - the same transcript, the same items - which is exactly the property the
# live path buys: only what the model is given changes.
#
# Asked for through the resolver rather than from $mode directly, so that what is injected is what
# the menu will show. They can differ: a stored choice stops being on offer when the machine
# changes under it (an older OS has no Apple Intelligence, an external agent is not this app's
# model to promise), and the menu already falls back in that case.
resolved=$(summarize_resolve "$win" "$sid" lazy)
resume_mode=${resolved%% *}
if [ "$resume_mode" = "full" ]; then
    history_inject_content "$win" "$CHAT_VIEW_ID" "$sid" "defer"
else
    history_inject_content "$win" "$CHAT_VIEW_ID" "$sid" "defer" "$CAD_DIGEST_KEEP_RECENT" \
        "$(summarize_request_backend "$resolved")"
fi

# A choice that could not be honored must not be left showing in the menu. Reachable only when the
# window changed under the user between opening the menu and answering it - someone else's agent
# took the window over, Apple Intelligence went away - but leaving meta.json saying one thing, the
# wire another and the picker a third is precisely the divergence this whole change is about.
if [ "$resume_mode" != "$mode" ]; then
    summarize_show "$win" "$sid"
fi
