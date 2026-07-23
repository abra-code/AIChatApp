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
    chat_inject_empty "$win"
    pb_set "aichatv2_session_${win}" ""
    for b in 521 520 524; do "$dialog" "$win" "$b" omc_disable; done
    # The title tracks the loaded CONVERSATION (stamped by the selection handler), so it has
    # to fall back to the model here - otherwise the window keeps naming a chat that no
    # longer exists. Same end state as New Chat: empty chat, unbound, titled by model.
    model_path=$(pb_get "aichatv2_modelpath_${win}")
    [ -n "$model_path" ] && chat_window_set_status "$win" "$(model_display_label "$model_path")"
fi

"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.history.refresh"
