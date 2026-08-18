#!/bin/sh
# aichat.chat.summarize.mode.sh
# The "On resume" menu under the chat (Picker id 561, in the slot 560 built by summarize_show).
# Its options are built from what is actually available on this machine:
#
#   full        replay the conversation as it was
#   session     summarize with the model this chat is already running (a live llama-server)
#   foundation  summarize with Apple Intelligence - macOS 26 and later only
#
# WHICH MODEL WRITES THE SUMMARY IS THE POINT OF THE MENU. The summary becomes the model's
# memory of everything it replaces, so substituting a different summarizer than the one named
# would be a lie about the thing that matters most. Every choice that cannot be honored is
# refused and reported rather than quietly served by something else.
#
# EVERY OPTION IS NON-DESTRUCTIVE. journal.jsonl is append-only and no branch here writes to it,
# so switching back to "full" rebuilds the whole conversation from the same file.
#
# The answer is remembered with the CONVERSATION (meta.json), not the window, so it holds
# tomorrow and in a second window without being asked for again.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"

win="$OMC_ACTIONUI_WINDOW_UUID"
CHAT_VIEW_ID=1

sid=$(pb_get "aichatv2_session_${win}")
if [ -z "$sid" ] || ! history_valid_sid "$sid"; then
    # No conversation bound to this window - a New Chat. The menu should not exist here, so
    # remove it rather than leave a control that answers for nothing.
    summarize_hide "$win"
    exit 0
fi

# Bumped FIRST, before either branch acts. This is the user overriding whatever is already
# happening, and a digest started by the resume may still be running: without this, choosing
# "full" restores the conversation and the older job overwrites it seconds later.
epoch=$(resume_epoch_bump "$win")

mode="${OMC_ACTIONUI_VIEW_561_VALUE:-full}"
case "$mode" in
    session|foundation) ;;
    # Anything unrecognized is treated as "full". Defaulting the other way would turn a missing
    # or malformed value into a summarize, which is the branch that costs seconds and changes
    # what the user is looking at.
    *) mode=full ;;
esac

if [ "$mode" = "full" ]; then
    history_set_resume_mode "$sid" "full"
    history_inject_content "$win" "$CHAT_VIEW_ID" "$sid" "defer"
    exit 0
fi

history_set_resume_mode "$sid" "$mode"

# Synchronous, unlike the resume path: the user just asked for this, so the wait is expected and
# a silent background change would be the surprising thing.
#
# Status captured from the call itself, NOT read inside `if ! ...`: there, $? is the status of
# the negation, which is 0 whenever the branch runs - so every failure would report success and
# pick the wrong message.
history_digest_inject "$win" "$CHAT_VIEW_ID" "$sid" "$epoch" "$mode"
digest_rc=$?

# Superseded is not a failure. Something the user did while this ran already decided what the
# window holds; resetting the menu and the stored answer here would undo that on the way out -
# the same class of bug the token was added to stop.
[ "$digest_rc" -eq 5 ] && exit 0

if [ "$digest_rc" -ne 0 ]; then
    history_set_resume_mode "$sid" "full"
    "$dialog" "$win" "$CAD_SUMMARIZE_PICKER_ID" "full"
    # A menu that snaps back with no explanation reads as the app fighting the user - it was the
    # first thing anyone noticed about this feature. The conversation is intact and still
    # displayed; only the summary did not happen, so say that and say why.
    #
    # One sentence per cause, because the actions they call for differ. A single "could not
    # summarize" would send someone to check Apple Intelligence for a conversation that was
    # simply too short.
    case "$digest_rc" in
        3)  "$alert" --level note --ok "OK" \
                "There is nothing to summarize in this conversation.
It is short enough that every message is replayed anyway, so a summary would not save the model any work." ;;
        4)  if [ "$mode" = "foundation" ]; then
                "$alert" --level note --ok "OK" \
                    "Could not summarize with Apple Intelligence.
It is available on macOS 26 and later, and has to be turned on in System Settings.
The conversation is unchanged and is still loaded in full."
            else
                "$alert" --level note --ok "OK" \
                    "Could not summarize with this chat's model.
The model has to be loaded and running to write the summary - it may have stopped, or this chat may be using an engine that cannot be reached this way.
The conversation is unchanged and is still loaded in full."
            fi ;;
        *)  "$alert" --level caution --ok "OK" \
                "Could not summarize this conversation.
The conversation is unchanged and is still loaded in full." ;;
    esac
fi
