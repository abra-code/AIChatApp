#!/bin/sh
# aichat.chat.entry.sh
# Fires per FINALIZED Chat transcript entry (entryActionID). The envelope
# { sequence, type, id, data } arrives as the ActionUI trigger context; we append it
# verbatim to a per-session journal.jsonl for crash-safe incremental persistence
# (history store section 3). Keep this cheap: usage/plan updates can fire several times
# per turn. The transcript.json snapshot + restore path is added with the history UI.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"
# For chat_engine_label, used by the opening session marker below.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

win="$OMC_ACTIONUI_WINDOW_UUID"
CHAT_VIEW_ID=1

# Optional instrumentation: `touch /tmp/aichatv2_debug` to capture the raw trigger env.
if [ -f /tmp/aichatv2_debug ]; then
    {
        echo "=== chat.entry $(/bin/date -u +%H:%M:%S) win=$win ==="
        /usr/bin/printenv | /usr/bin/grep -E "OMC_ACTIONUI_(TRIGGER|VIEW_1)"
    } >> /tmp/aichatv2_debug.log 2>&1
fi

# The finalized-entry envelope arrives as the ActionUI trigger context. (The Chat element
# has no scalar value - valueType is Void - so there is no OMC_ACTIONUI_VIEW_1_VALUE to fall
# back to.) Read BEFORE the mint, because what it is decides whether a session is minted at all.
envelope="$OMC_ACTIONUI_TRIGGER_CONTEXT"
[ -z "$envelope" ] && exit 0

# One session dir per chat window, id created on the first finalized entry OF CONTENT.
session_key="aichatv2_session_${win}"
sid=$(pb_get "$session_key")
newly_minted=
# Initialized for the same reason newly_minted is: these are read as "did the block above run",
# and an exported variable of the same name in the environment answers yes before it has.
info_stated=
if [ -z "$sid" ]; then
    # Not everything that finalizes is a conversation. The agent's own `session` announcement used
    # to mint a directory holding nothing else, and those empty sessions accumulated at the top of
    # the sidebar as "(untitled)". Nothing to persist yet, so there is nothing to persist it into.
    history_envelope_mints "$envelope" || exit 0
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
    # Open the transcript with a record of what is answering it. Written BEFORE the first turn is
    # appended below, so it leads the conversation rather than interrupting it, and it is why a
    # conversation reopened months later can still say which model wrote its opening exchange -
    # the info pane only ever names the model a session STARTED with, and stops being the whole
    # truth the first time the conversation is resumed with another.
    #
    # ALREADY ON SCREEN, since the moment this window became able to answer: what happens here is
    # the recording of the line the user has been looking at, not its first appearance. That is the
    # only way it can lead the conversation on screen as well as in the journal - the message this
    # marker belongs in front of has been displayed since the user pressed Return, long before its
    # entry finalized and got us here. The fallback covers a session minted in a window that never
    # showed one (an error or system entry can mint one too); a conversation with no opening line
    # is worse than one whose opening line arrives late.
    history_marker_commit "$win" "$sid" || \
        history_mark_and_show "$win" "$CHAT_VIEW_ID" "$sid" started "$(chat_engine_label "$win")"
    newly_minted=1
else
    # The other half of the same record: this conversation already existed, and if the sidebar armed
    # a resume for it then THIS is the moment it became one - a turn is being appended to a
    # conversation the user opened. Clearing the flag first, not last, NARROWS the window in which
    # two overlapping invocations could each write a marker (usage/plan entries re-fire several
    # times per turn); it does not close it. Measured, the gap is about 5 ms, and the first entry
    # after a resume comes from a send, which is dispatched synchronously with nothing else queued.
    resume_key="aichatv2_resume_pending_${win}"
    if [ "$(pb_get "$resume_key")" = "$sid" ]; then
        pb_set "$resume_key" ""
        # The marker was shown when the conversation was loaded, in front of the message that is
        # being recorded below; this records it. A model switched between the click and this turn
        # queued its own marker behind that one (aichat.chat.switch.model.sh), so the pair names
        # what the user saw and what is about to answer.
        #
        # The fallback re-reads the label NOW, which is what it has always done, for the window
        # that reached a turn with nothing queued.
        history_marker_commit "$win" "$sid" || \
            history_mark_and_show "$win" "$CHAT_VIEW_ID" "$sid" resumed "$(chat_engine_label "$win")"
    fi
fi

history_append_journal "$history_root/$sid" "$envelope"

# On the FIRST entry of a brand-new session (New Chat + typing, or the fresh-launch chat),
# surface it in the sidebar immediately: repopulate the list and select the new row. The
# journal now holds this first turn, so the store derives its title correctly. We do this
# only once (guarded on newly_minted, which is set only in the mint block above) - the
# per-turn usage/plan re-fires never reach here. history_index sorts most-recent-first and
# this session's files were just written, so it is row 0; omc_select_row fires NO actionID,
# so it only highlights the row - it does NOT re-inject content over the live conversation.
if [ -n "$newly_minted" ]; then
    TABLE_ID=510
    ROW_BUTTONS="521 520 524"   # Rename Reveal Delete
    history_populate_table "$win" "$TABLE_ID"
    "$dialog" "$win" "$TABLE_ID" omc_select_row 0
    for b in $ROW_BUTTONS; do "$dialog" "$win" "$b" omc_enable; done
    # And the facts line, which until this moment read "New conversation". Stated here as well
    # as in the case below because a session can be minted by an entry that is not a message -
    # and marked done, because the minting entry USUALLY is one, and running the journal through
    # python twice for a single entry is the cost this handler is least able to afford.
    chat_info_refresh "$win"
    info_stated=1
fi

# The message count in the model bar goes stale the moment a turn lands, and the line is
# permanently on screen now - a visibly wrong number is worse than the old hidden one. So
# restate it per MESSAGE, which is twice a turn.
#
# The `case` is a deliberately cheap pre-filter and not a parser. This handler is on the
# streaming path and its header asks it to stay cheap; history_info_line spawns python and
# reads the whole journal, so doing it for every finalized entry (thoughts, tool calls, and
# the usage/plan envelopes that re-fire several times a turn) is exactly what must not happen.
# If the envelope's spelling ever changes this simply stops matching, and the line falls back
# to refreshing when a row is clicked - the behavior it had before this existed.
if [ -z "$info_stated" ]; then
    case "$envelope" in
        *'"type":"message"'*|*'"type": "message"'*) chat_info_refresh "$win" ;;
    esac
fi
