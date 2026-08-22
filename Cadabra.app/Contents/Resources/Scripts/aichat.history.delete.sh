#!/bin/sh
# aichat.history.delete.sh
# Delete a saved chat (its whole session directory) after a confirm, then refresh the list.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

win="$OMC_ACTIONUI_WINDOW_UUID"
sid="$OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE"
[ -n "$sid" ] || exit 0
dir=$(history_session_dir "$sid") || exit 0

title=$(history_title "$sid")
"$alert" --level caution --ok "Delete" --cancel "Cancel" \
    "Delete the saved chat \"$title\"? This cannot be undone."
[ $? -eq 0 ] || exit 0

# Belt-and-suspenders: history_session_dir already rejects traversal; only ever rm inside
# the history root.
case "$dir" in
    "$history_root"/*) /bin/rm -rf "$dir" ;;
    *) echo "refusing to delete outside history root: $dir" >&2; exit 1 ;;
esac

# If the deleted conversation is the one currently loaded in this window, clear the chat and
# unbind so a New Chat starts clean (no dangling binding to a now-gone session dir).
if [ "$(pb_get "aichatv2_session_${win}")" = "$sid" ]; then
    # The menu goes with the conversation it belonged to. Nothing else needs undoing: the
    # summary now happens inside the agent at prime time, so there is no job of ours in flight
    # to stop - deleting the session and unbinding the window is the whole of it.
    summarize_hide "$win"
    chat_inject_empty "$win"
    # Withdrawn with the transcript it belonged to, and BEFORE this window can mint anything.
    # What was held described the conversation just deleted; between here and the end of this
    # block there are several subprocess spawns, and a message finalizing in that gap mints a
    # session and records whatever the queue is holding as its opening line - a resume of a chat
    # that no longer exists, at the top of a brand-new one.
    history_marker_clear "$win" 1
    pb_set "aichatv2_session_${win}" ""
    pb_set "aichatv2_resume_pending_${win}" ""
    for b in 521 520 524; do "$dialog" "$win" "$b" omc_disable; done
    # What is left driving this window once the conversation it was showing is gone. The same
    # end state as New Chat: an empty chat, unbound, with the model bar still naming the engine.
    # Nothing has to be un-named here any more - the window title reports nothing (see
    # aichat.library.sh), so it cannot be left naming a chat that no longer exists.
    engine_label=$(chat_engine_label "$win")
    # And the opening line of what this window is now: an empty conversation with the same engine.
    # What it was holding for the deleted one went with the inject above.
    [ -n "$engine_label" ] && history_marker_lead "$win" 1 started "$engine_label"
fi

"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.history.refresh"
