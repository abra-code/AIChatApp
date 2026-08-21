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

# IS THIS A MESSAGE? Asked once, here, because two decisions below turn on it and both are on the
# streaming path. A deliberately cheap pre-filter and not a parser: history_envelope_mints spawns
# python and reads the whole envelope, which is what must not happen for every thought, tool call
# and re-fired usage or plan envelope of a turn. If the envelope's spelling ever changes this
# simply stops matching, and both callers below degrade to what they did before they existed.
case "$envelope" in
    *'"type":"message"'*|*'"type": "message"'*) envelope_is_message=1 ;;
    *) envelope_is_message= ;;
esac

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
    # ALREADY ON SCREEN, put there by the element the moment this message was sent and in front of
    # it: what happens here is the recording of the line the user is looking at, not its first
    # appearance. That is the only way it can lead the conversation on screen as well as in the
    # journal - by the time an entry finalizes and gets us here, the message this marker belongs
    # in front of has been displayed since the user pressed Return. The envelope carries the line
    # as the element placed it, stamped with that moment, and that is what is written.
    #
    # ONLY FOR A MESSAGE, because only a message is what the element placed the line in front of.
    # A session minted by something else (an error or a system entry can mint one too) leaves the
    # line waiting for the first message, which the branch below records it on; the fallback covers
    # the window that reached one with nothing held at all, a conversation with no opening line
    # being worse than one whose opening line arrives late.
    if [ -n "$envelope_is_message" ]; then
        history_marker_commit "$win" "$sid" "$CHAT_VIEW_ID" "$envelope" || \
            history_mark_and_show "$win" "$CHAT_VIEW_ID" "$sid" started "$(chat_engine_label "$win")"
    fi
    newly_minted=1
else
    # The other half of the same record: this conversation already existed, and if the sidebar armed
    # a resume for it then a MESSAGE is the moment it became one - a turn is being appended to a
    # conversation the user opened. The message test is what makes that true rather than nearly
    # true: any finalized entry used to be enough, so an agent announcing its session in a
    # conversation the user had merely clicked on wrote "Resumed with <model>" into it, and left
    # the arm disarmed so the real first message recorded nothing.
    #
    # Clearing the flag first, not last, NARROWS the window in which two overlapping invocations
    # could each write a marker (usage/plan entries re-fire several times per turn); it does not
    # close it. Measured, the gap is about 5 ms, and the first entry after a resume comes from a
    # send, which is dispatched synchronously with nothing else queued.
    #
    # READ ONLY FOR A MESSAGE. Nothing else can drain the queue, and this handler re-fires several
    # times per turn on entries that never will - reading the flag for each of them is a
    # $pasteboard spawn per thought, tool call and usage envelope on the streaming path.
    resume_key="aichatv2_resume_pending_${win}"
    resume_armed=
    [ -n "$envelope_is_message" ] && resume_armed=$(pb_get "$resume_key")
    if [ -n "$envelope_is_message" ] && [ "$resume_armed" = "$sid" ]; then
        pb_set "$resume_key" ""
        # The marker was minted when the conversation was loaded and placed by the element in front
        # of the message being recorded below; this records it. A model switched between the click
        # and this turn queued its own marker behind that one (aichat.chat.switch.model.sh), so the
        # pair names what the user saw and what is about to answer.
        #
        # The fallback re-reads the label NOW, which is what it has always done, for the window
        # that reached a turn with nothing held.
        history_marker_commit "$win" "$sid" "$CHAT_VIEW_ID" "$envelope" || \
            history_mark_and_show "$win" "$CHAT_VIEW_ID" "$sid" resumed "$(chat_engine_label "$win")"
    elif [ -n "$envelope_is_message" ] && [ -z "$resume_armed" ]; then
        # STILL HOLDING A LINE, WITH NO OTHER CONVERSATION CLAIMING IT. The element placed whatever
        # this window was holding in front of the message being recorded below, so it has to be
        # recorded here or the reload loses a line the user is looking at - and the queue that
        # cannot be drained goes on making every later marker queue behind it.
        #
        # Reachable two ways, both of which used to end here with the line displayed and never
        # written. A session minted by an entry that is NOT a message (an error or a system entry
        # can mint one) leaves its opening marker held, and no resume is ever armed for a
        # conversation this window started itself. And a sidebar click whose conversation fails to
        # load disarms, while the window goes on showing - and holding the line for - the
        # conversation it already had.
        #
        # THE EMPTY ARM IS THE WHOLE TEST, and it is what keeps the straggler case out: a turn
        # finalizing while another conversation is being opened finds the arm naming that one and
        # the binding naming this one, and lands in neither arm. No fallback either - nothing placed
        # and nothing held means the element put no line in front of this message.
        history_marker_commit "$win" "$sid" "$CHAT_VIEW_ID" "$envelope" || :
    elif [ -n "$envelope_is_message" ]; then
        # THE STRAGGLER ITSELF: the arm names another conversation - one being opened while this
        # turn was finishing - and this window is still bound to this one. It is neither a resume
        # of this conversation nor its first message, and the queue is not this conversation's to
        # drain. But whatever the element placed in front of this message is on screen in THIS
        # conversation, so it is recorded here, where the message is about to be, or the reload
        # loses a line the user saw.
        history_marker_record "$sid" "$envelope" || :
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
# The test is the cheap one made at the top of this handler: history_info_line spawns python and
# reads the whole journal, so doing it for every finalized entry (thoughts, tool calls, and the
# usage/plan envelopes that re-fire several times a turn) is exactly what must not happen.
if [ -z "$info_stated" ] && [ -n "$envelope_is_message" ]; then
    chat_info_refresh "$win"
fi
