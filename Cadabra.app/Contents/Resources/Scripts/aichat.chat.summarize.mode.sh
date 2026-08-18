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
# The choice has two halves with different lifetimes, which is worth knowing when reading this:
# WHETHER to summarize is per conversation and takes effect on the next send; WHICH model does it
# is the agent's --digest-backend, fixed when the agent launched, so a change lands on the next
# chat window. The element's marker reports which model actually summarized, so the difference is
# visible rather than something to reason about.
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

# The summarizer half of the choice, stored for the agents this app launches from here on. "auto"
# is also what an unset setting resolves to, so choosing it clears any earlier pin.
if [ "$mode" != "full" ]; then
    cadabra_settings_init
    # Value BEFORE the file: plister is `set <type> <value> <file> <pseudopath>`. The other order
    # parses and writes nothing, silently, which is how this shipped its first version.
    "$plister" set string "$mode" "$cadabra_settings" "/digest-backend" >/dev/null 2>&1
fi

# Re-inject so the request (or its absence) reaches the agent at the next prime. The DISPLAY is
# identical either way - the same transcript, the same items - which is exactly the property the
# live path buys: only what the model is given changes.
if [ "$mode" = "full" ]; then
    history_inject_content "$win" "$CHAT_VIEW_ID" "$sid" "defer"
else
    history_inject_content "$win" "$CHAT_VIEW_ID" "$sid" "defer" "$CAD_DIGEST_KEEP_RECENT"
fi
