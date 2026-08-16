#!/bin/sh
# aichat.chat.entry.sh
# Fires per FINALIZED Chat transcript entry (entryActionID). The envelope
# { sequence, type, id, data } arrives as the ActionUI trigger context; we append it
# verbatim to a per-session journal.jsonl for crash-safe incremental persistence
# (history store section 3). Keep this cheap: usage/plan updates can fire several times
# per turn. The transcript.json snapshot + restore path is added with the history UI.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"

win="$OMC_ACTIONUI_WINDOW_UUID"

# Optional instrumentation: `touch /tmp/aichatv2_debug` to capture the raw trigger env.
if [ -f /tmp/aichatv2_debug ]; then
    {
        echo "=== chat.entry $(/bin/date -u +%H:%M:%S) win=$win ==="
        /usr/bin/printenv | /usr/bin/grep -E "OMC_ACTIONUI_(TRIGGER|VIEW_1)"
    } >> /tmp/aichatv2_debug.log 2>&1
fi

# One session dir per chat window, id created on the first finalized entry.
session_key="aichatv2_session_${win}"
sid=$(pb_get "$session_key")
newly_minted=
if [ -z "$sid" ]; then
    sid="$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
    pb_set "$session_key" "$sid"
    /bin/mkdir -p "$history_root/$sid"
    # Record what produced this session - the model, or the external ACP agent - from the
    # per-window stamps chat.init.sh wrote. Exactly one of the two is ever non-empty. This
    # feeds the info strip and the preview; the sidebar list shows only the title, and no
    # resume path reads either value back (the comment here used to claim both, which was
    # true of neither). JSON-safe.
    session_model_path=$(pb_get "aichatv2_modelpath_${win}")
    session_agent=$(pb_get "aichatv2_agent_${win}")
    history_init_meta "$history_root/$sid" "$sid" "$session_model_path" "$session_agent"
    newly_minted=1
fi

# The finalized-entry envelope arrives as the ActionUI trigger context. (The Chat element
# has no scalar value - valueType is Void - so there is no OMC_ACTIONUI_VIEW_1_VALUE to fall
# back to.)
envelope="$OMC_ACTIONUI_TRIGGER_CONTEXT"
[ -z "$envelope" ] && exit 0

printf '%s\n' "$envelope" >> "$history_root/$sid/journal.jsonl"

# On the FIRST entry of a brand-new session (New Chat + typing, or the fresh-launch chat),
# surface it in the sidebar immediately: repopulate the list and select the new row. The
# journal now holds this first turn, so the store derives its title correctly. We do this
# only once (guarded on newly_minted, which is set only in the mint block above) - the
# per-turn usage/plan re-fires never reach here. history_index sorts most-recent-first and
# this session's files were just written, so it is row 0; omc_select_row fires NO actionID,
# so it only highlights the row - it does NOT re-inject content over the live conversation.
if [ -n "$newly_minted" ]; then
    TABLE_ID=510
    INFO_TEXT_ID=540
    ROW_BUTTONS="521 520 524"   # Rename Reveal Delete
    history_populate_table "$win" "$TABLE_ID"
    "$dialog" "$win" "$TABLE_ID" omc_select_row 0
    for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_enable; done
    if [ "$(pb_get "aichatv2_info_${win}")" = "1" ]; then
        info=$(history_info_line "$sid")
        [ -n "$info" ] && "$dialog" "$win" "$INFO_TEXT_ID" "$info"
    fi
fi
