#!/bin/sh
# aichat.history.library.sh
# History-store helpers shared by the history window handlers and by the chat window's
# restore-on-open path (aichat.chat.init.sh). Sources the base library for $dialog /
# $pasteboard / pb_get / pb_set / history_root. All read helpers delegate to
# history_store.py (bundled python) so JSON handling stays robust.
[ -n "${__AICHAT_HISTORY_LIB:-}" ] && return 0
__AICHAT_HISTORY_LIB=1

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

history_py="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
history_store="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/history_store.py"

# history_valid_sid <sid> — guard against path traversal / empties. Session ids are bare
# dir names like 20260707T193808Z-2042 or webui-<id>; never contain "/" "..", never start
# with a dot.
history_valid_sid() {
    case "$1" in
        ""|*/*|*..*|.*) return 1 ;;
        *) return 0 ;;
    esac
}

# history_session_dir <sid> — echo the absolute session directory (validated).
history_session_dir() {
    history_valid_sid "$1" || { echo "invalid session id: $1" >&2; return 1; }
    echo "$history_root/$1"
}

# history_index — TSV rows "title<TAB>session_id" for the sidebar list (recent first).
history_index() {
    "$history_py" "$history_store" index "$history_root"
}

# history_populate_table <win> <table_id> — (re)fill the sidebar list from the store, most
# recent first. Single visible "Title" column (declared in aichat.chat.json); session_id
# rides as the hidden trailing field. Safe to call repeatedly (chat init + refresh).
history_populate_table() {
    local win="$1" table_id="$2" rows
    "$dialog" "$win" "$table_id" omc_table_remove_all_rows
    rows=$(history_index)
    [ -n "$rows" ] && printf "%s" "$rows" | "$dialog" "$win" "$table_id" omc_table_set_rows_from_stdin
}

# history_transcript_json <session_dir> [prime] — ChatTranscript JSON for states["content"].
# Optional prime ("true"/"false"/"defer") rides on the JSON as the transient restore
# directive: "defer" = display only, the element replays the conversation into the agent
# lazily on the next send (the seamless sidebar switch); false = display with a FRESH agent
# context (Read Only); true/absent = replay immediately. See docs/session-prime.md in the
# mlx-agent repo.
history_transcript_json() {
    "$history_py" "$history_store" transcript "$1" ${2:+"$2"} ${3:+"$3"}
}

# history_info_line <sid> — one compact "Started · Messages" line about a saved conversation.
history_info_line() {
    local dir
    dir=$(history_session_dir "$1") || return 1
    "$history_py" "$history_store" info "$dir"
}

# The facts line in the model bar (aichat.chat.json), beside the model name.
CHAT_INFO_TEXT_ID=540

# chat_info_refresh <win> — restate what the chat window is showing.
#
# ONE function because there are now five callers and the line is PERMANENT. It used to be
# toggled by an (i) button, so each caller could reasonably guard on "is it even visible" and
# they drifted: New Chat rebuilt the line one way, the sidebar another, and the first turn a
# third. Nothing is hidden any more, so a caller that forgets to refresh leaves a line that is
# simply wrong - which is worse than the old failure of leaving one that was not shown.
#
# What it says is decided here rather than passed in: whichever conversation this window is
# bound to, or "New conversation" when it is bound to none (a fresh window, or one just
# cleared). The model is NOT named - it is the button immediately to the left, and naming it
# twice in one row was the first thing this line did that nobody wanted.
chat_info_refresh() {
    local win="$1" sid info=""
    sid=$(pb_get "aichatv2_session_${win}")
    # The DIRECTORY, not just a well-formed id. history_info_line summarizes whatever it can
    # read and a session that is no longer on disk reads as an empty one, so a window still
    # bound to a deleted conversation would announce "Messages: 0" as though that were a fact
    # about it. There is nothing to say about a conversation that is gone.
    if [ -n "$sid" ] && history_valid_sid "$sid" && [ -d "$history_root/$sid" ]; then
        info=$(history_info_line "$sid")
    fi
    [ -n "$info" ] || info="New conversation"
    "$dialog" "$win" "$CHAT_INFO_TEXT_ID" "$info"
}

# history_title <sid> — display title (meta.title, else first user line, else "(untitled)").
history_title() {
    local dir
    dir=$(history_session_dir "$1") || return 1
    "$history_py" "$history_store" title "$dir"
}

# history_init_meta <session_dir> <sid> <model_path> [agent_label] - write a fresh meta.json
# (JSON-safe, atomic: a concurrent history_index scan never sees a torn/empty file).
#
# model_path and agent_label are mutually exclusive: a conversation runs either the bundled
# model or an external ACP agent, and an external one has no model path to record.
history_init_meta() {
    "$history_py" "$history_store" meta-init "$2" "$3" "${4:-}" > "$1/meta.json.tmp" &&
        /bin/mv -f "$1/meta.json.tmp" "$1/meta.json"
}

# history_meta_field <sid> <key> — echo one string field from a session's meta.json ("" if
# missing/unreadable).
history_meta_field() {
    local dir
    dir=$(history_session_dir "$1") || return 1
    "$history_py" -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    v=d.get(sys.argv[2],"")
    sys.stdout.write(v if isinstance(v,str) else str(v))
except Exception:
    pass' "$dir/meta.json" "$2"
}

# history_inject_content <window_uuid> <view_id> <sid> [prime] — load a saved transcript
# into the Chat element via states["content"]. Unlike the string-state API this is
# re-injectable (OMC's omc_set_state uses the native setter): each call REPLACES the
# displayed conversation, so selecting different rows swaps the chat in place. Injecting
# {"version":1,"items":[]} (see aichat.chat.new.sh) clears it. Optional prime
# ("true"/"false"/"defer") is the context directive (see history_transcript_json); an optional
# fifth argument is keepRecentTurns, which asks the AGENT to summarize the older part of the
# restore rather than replay it.
history_inject_content() {
    local dir transcript
    dir=$(history_session_dir "$3") || return 1
    transcript=$(history_transcript_json "$dir" ${4:+"$4"} ${5:+"$5"})
    [ -n "$transcript" ] || return 1
    "$dialog" "$1" "$2" omc_set_state content "$transcript"
}

# history_append_journal <session-dir> <line> - append one finalized entry, atomically.
#
# NOT a plain `printf >> journal.jsonl`. The shell flushes in ~1 KB stdio chunks, so an envelope
# bigger than that is several write() calls, and this handler re-fires several times per turn with
# invocations that can overlap. A second writer landing between two chunks splices the tail of one
# envelope onto the head of another, and both lines are lost - _read_journal can only skip what it
# cannot parse. Two conversations in this user's history lost a message that way. Reproduced at 26
# torn lines in 120 with three concurrent writers; zero with this lock.
#
# mkdir is the atomic primitive history_store.py's _journal_lock uses too, so both writers - this
# one and the session markers - queue on the same door. The wait is bounded: a handler killed while
# holding the lock would otherwise wedge the chat, and an interleaved line is recoverable where a
# frozen window is not.
history_append_journal() { # <session-dir> <line>
    local lock="$1/.journal.lock" spins=0
    while ! /bin/mkdir "$lock" 2>/dev/null; do
        spins=$((spins + 1))
        [ "$spins" -ge 2000 ] && break
    done
    printf '%s\n' "$2" >> "$1/journal.jsonl"
    [ "$spins" -lt 2000 ] && /bin/rmdir "$lock" 2>/dev/null
    return 0
}

# history_envelope_mints <envelope-json> - true when this entry is conversation CONTENT, and so
# worth a session directory of its own.
#
# The agent announces itself with a `session` envelope, which finalizes as an entry like any other.
# Minting on it produced a history dir holding one agent announcement and no conversation: 21 of
# this user's 183 saved sessions were empty, showing as "(untitled)" rows that pushed real
# conversations down the sidebar. Only content mints; a `session`, `usage` or `plan` envelope
# arriving before there is anything to say is dropped, which costs nothing because none of the
# three is read back into a transcript.
#
# Called ONLY while the window is unbound, so the python spawn happens a handful of times per
# conversation rather than per entry - this handler is on the streaming path and its header asks
# for it to stay cheap.
history_envelope_mints() { # <envelope-json>
    printf '%s' "$1" | "$history_py" -c '
import json, sys
try:
    t = (json.load(sys.stdin) or {}).get("type")
except Exception:
    t = None
sys.exit(0 if t in ("message", "thought", "toolCall", "image", "system", "error") else 1)
' 2>/dev/null
}

# history_mark_session <sid> <started|resumed|modelChanged> [model-label] - record a session
# boundary in a conversation's transcript.
#
# The app writes these, not the element. ChatView renders session markers and emits its own only
# for what the AGENT reports (a condensed prime carries its digest on the wire); which MODEL is
# answering is known only here, because mlx-agent advertises no configOptions and so the element
# is never told. The label comes from this side or from nowhere.
#
# Best-effort: a conversation is not worth failing to open because its marker could not be
# written. The record is a convenience for the reader, not part of the conversation.
history_mark_session() { # <sid> <kind> [model] -> the ChatItem JSON on stdout
    local dir
    dir=$(history_session_dir "$1") || return 0
    "$history_py" "$history_store" session-event "$dir" "$2" "${3:-}" 2>/dev/null
    return 0
}

# history_mark_and_show <win> <chat-view-id> <sid> <kind> [model] - record the boundary AND put it
# on screen now.
#
# Recording alone leaves the marker invisible until the conversation is next loaded, which is a poor
# answer to "which model is answering me": the line explaining the handover shows up everywhere
# except the moment it happens. states["content"] cannot help - injecting REPLACES the transcript
# and re-primes the whole conversation - so ChatView 0.5.2 added states["append"] for exactly this:
# one item, appended, no transport traffic.
#
# The journal write stays the source of truth. The element is TOLD about the item rather than asked
# to persist it (the append state fires no entry), so there is one writer and no double-write. A
# host running against an older ChatView simply ignores the state and the marker waits for the next
# load, which is what it did before.
history_mark_and_show() { # <win> <chat-view-id> <sid> <kind> [model]
    local item
    item=$(history_mark_session "$3" "$4" "${5:-}")
    [ -n "$item" ] && "$dialog" "$1" "$2" omc_set_state append "$item"
    return 0
}

# =============================================================================
# Resuming a long conversation without replaying all of it
# =============================================================================
#
# Replaying a whole conversation into a model costs a full prefill of every token in it, and on a
# small context window it may not fit at all. mlx-agent can summarize the older part instead and
# prime the model with [summary, acknowledgment, the recent turns verbatim].
#
# THE AGENT DOES IT, NOT THIS LAYER. session/prime takes an optional condense object; this app
# asks for it by putting the key on the injected content and the agent performs it at the next
# prime. That replaced an earlier implementation here which ran mlx-agent's offline `digest` verb
# and injected the result as the transcript - it worked, but doing it outside the element meant
# the summary REPLACED THE DISPLAY, because injected content seeds both what is shown and what is
# sent. The live path separates them: the window keeps the whole conversation while the model is
# given a summary of its older half.
#
# Nothing is lost either way. journal.jsonl is append-only and no path here writes to it, so
# switching a conversation back to replaying in full restores every original turn.
#
# WHO SUMMARIZES IS A DIFFERENT QUESTION FROM WHETHER TO, and they have different lifetimes. The
# summarizer is the agent's --digest-backend, fixed when the agent launched (cad_digest_backend in
# the base library); whether a given conversation is summarized rides on session/prime per restore.
# The menu below sets both, which means changing the summarizer takes effect for the next chat
# window rather than the one in front of you - and the marker the element appends after a
# condensed prime reports which model actually did it, so the answer is never guesswork.

# How many trailing messages to ask the agent to keep verbatim. mlx-agent's own default is 6, and
# it may keep MORE - it snaps the boundary back to a user turn so the tail starts cleanly.
CAD_DIGEST_KEEP_RECENT=6

# Above this many model-facing messages, a resume defaults to summarizing. Below it a full replay
# is cheap and a summary would mostly be preamble.
CAD_DIGEST_ASK_ABOVE=24

# history_wire_count <sid> - model-facing messages in a conversation, "0" when unreadable.
#
# Counted through the same filter the agent's prime uses, so the number the default tests is the
# number that would actually be replayed - not the item count, which includes thoughts, tool calls
# and session markers the model never saw.
history_wire_count() {
    local dir count
    dir=$(history_session_dir "$1") || return 1
    count=$("$history_py" "$history_store" digest-input "$dir" 0 2>/dev/null \
        | "$history_py" -c 'import json,sys
try:
    sys.stdout.write(str(len(json.load(sys.stdin))))
except Exception:
    sys.stdout.write("0")')
    case "${count:-}" in
        ''|*[!0-9]*) printf '0\n' ;;
        *)           printf '%s\n' "$count" ;;
    esac
}

# summarize_can_condense <sid> - true when there is actually an older half to summarize.
#
# Asked of digest-input rather than recomputed here, because that is the same well-formedness
# filter the prime applies: a rule restated in two places is a rule that can disagree with itself,
# and the disagreement here is a menu offering something the agent will decline.
summarize_can_condense() { # <sid>
    local dir
    dir=$(history_session_dir "$1") || return 1
    "$history_py" "$history_store" digest-input "$dir" "$CAD_DIGEST_KEEP_RECENT" >/dev/null 2>&1
}

# summarize_session_own_model <win> - true when "the model in this chat" can summarize.
#
# WHICH IS NOW EVERY ENGINE THIS APP LAUNCHES, and the previous version of this got it wrong. It
# probed for a running llama-server on the window's stashed port, because under the old design a
# summary was produced by a SEPARATE mlx-agent process: borrowing a gguf model was free (the
# server already had it) while an MLX model would have been loaded a second time, gigabytes and
# all. That reasoning died with the batch verb. --digest-backend session summarizes with the
# agent's OWN already-loaded model, so it costs nothing whichever engine the window runs, and the
# port probe was excluding MLX windows from a choice that works perfectly well for them.
#
# The one case it does not cover is an EXTERNAL ACP agent: its command line is the user's own, so
# this app passes it no --digest-backend and has no idea what would summarize. That is what the
# stamp below distinguishes - it is set only for a window driven by someone else's agent.
summarize_session_own_model() { # <win>
    [ -z "$(pb_get "aichatv2_agent_$1")" ]
}

# summarize_foundation_ok - true when Apple's on-device model can summarize here.
#
# APPLE INTELLIGENCE IS macOS 26 AND LATER, which is why this control is a menu rather than a
# checkbox: what can write a summary differs per machine. foundation_probe reports osTooOld for
# exactly that, and foundation_offerable is the app's existing verdict on which reasons are
# permanent - reusing it means this agrees with the model picker rather than inventing a second
# opinion about the same Mac.
summarize_foundation_ok() {
    local reason
    command -v foundation_probe >/dev/null 2>&1 || \
        source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"
    reason=$(foundation_probe 2>/dev/null | /usr/bin/head -n 1 | /usr/bin/cut -f1)
    [ -n "$reason" ] || return 1
    foundation_offerable "$reason"
}

# history_resume_mode <sid> - "full", "auto", "foundation", "session", or "" when never chosen.
history_resume_mode() {
    history_meta_field "$1" resumeMode
}

# history_set_resume_mode <sid> <mode> - remember the choice with the conversation.
#
# In meta.json rather than on a pasteboard key because the decision belongs to the CONVERSATION,
# not to the window that happened to open it: the same answer should hold tomorrow, and in a
# second window, without being asked for again.
history_set_resume_mode() {
    local dir
    dir=$(history_session_dir "$1") || return 1
    "$history_py" "$history_store" meta-set "$dir" resumeMode "$2"
}

# The "On resume" menu, in the slot under the chat (aichat.chat.json id 560).
#
# Only while a SAVED conversation is loaded: a new chat has no older half, so the control is
# removed rather than disabled - omc_remove_element collapses the slot, where omc_disable would
# leave a permanent grey row under every new chat.
CAD_SUMMARIZE_SLOT_ID=560
CAD_SUMMARIZE_PICKER_ID=561

# summarize_hide <win> - collapse the slot. Safe when nothing is there.
summarize_hide() {
    "$dialog" "$1" "$CAD_SUMMARIZE_PICKER_ID" omc_remove_element 2>/dev/null
    return 0
}

# summarize_show <win> <sid> - build the menu for a resumed conversation.
summarize_show() {
    local win="$1" sid="$2" mode chosen help opts can own_model fm

    # WHAT IS ACTUALLY POSSIBLE COMES FIRST, and builds the menu from it. A choice that cannot be
    # honored is worse than no choice: an earlier version offered one on every resume, so on a
    # conversation with nothing to summarize the user could pick it, watch the agent decline, and
    # see the control snap back with no explanation.
    if summarize_can_condense "$sid"; then can=1; else can=0; fi
    if summarize_session_own_model "$win"; then own_model=1; else own_model=0; fi
    if summarize_foundation_ok; then fm=1; else fm=0; fi

    # Always first, always present: the conversation as it was. The only option needing nothing to
    # be available, which is also why every failure lands back on it.
    opts='{"title":"Replay the full conversation","tag":"full"}'
    if [ "$can" = "1" ]; then
        # Auto is mlx-agent's own default and it MEASURES rather than preferring - it sizes the
        # conversation against the on-device budget and picks. Offered by name rather than hidden
        # behind the others so the mechanism is visible instead of being a black box.
        opts="$opts,"'{"title":"Summarize - choose the model automatically","tag":"auto"}'
        [ "$own_model" = "1" ] && \
            opts="$opts,"'{"title":"Summarize with the model in this chat","tag":"session"}'
        # APPLE INTELLIGENCE IS macOS 26+. On anything older the entry is absent rather than
        # present-and-failing.
        [ "$fm" = "1" ] && \
            opts="$opts,"'{"title":"Summarize with Apple Intelligence","tag":"foundation"}'
    fi

    # What is selected: this conversation's stored answer if it is still on offer, otherwise the
    # recommendation, otherwise the full conversation.
    mode=$(history_resume_mode "$sid")
    case "$mode" in
        auto)       [ "$can" = "1" ] || mode="" ;;
        session)    { [ "$can" = "1" ] && [ "$own_model" = "1" ]; } || mode="" ;;
        foundation) { [ "$can" = "1" ] && [ "$fm" = "1" ]; }       || mode="" ;;
        full)       ;;
        *)          mode="" ;;
    esac
    if [ "$can" = "0" ]; then
        chosen=full
    elif [ -n "$mode" ]; then
        chosen="$mode"
    elif [ "$(history_wire_count "$sid")" -gt "$CAD_DIGEST_ASK_ABOVE" ]; then
        chosen=auto
    else
        chosen=full
    fi

    if [ "$can" = "0" ]; then
        help="This conversation is short enough to replay in full - there is no older part to summarize."
    else
        help="Summarizing replaces the older messages IN THE MODEL with a summary and keeps the last $CAD_DIGEST_KEEP_RECENT exactly. The conversation shown here does not change, and the summary appears in it so you can read what the model was given. Choosing a summarizer applies to the next chat window."
    fi

    # SIZED AS A PAIR. A footnote label beside a default-size menu reads as two unrelated things
    # stacked under the composer, which is what it looked like first.
    summarize_hide "$win"
    "$dialog" "$win" "$CAD_SUMMARIZE_SLOT_ID" omc_insert_element "{\"type\":\"Picker\",\"id\":$CAD_SUMMARIZE_PICKER_ID,\"properties\":{\"title\":\"On resume\",\"options\":[$opts],\"pickerStyle\":\"menu\",\"controlSize\":\"small\",\"font\":\"subheadline\",\"actionID\":\"aichat.chat.summarize.mode\",\"help\":\"$help\",\"padding\":{\"top\":4,\"bottom\":6,\"leading\":14,\"trailing\":14},\"frame\":{\"maxWidth\":\"infinity\",\"alignment\":\"leading\"}}}"
    "$dialog" "$win" "$CAD_SUMMARIZE_PICKER_ID" "$chosen"

    # Shown but not usable, rather than hidden. The row is where the user has learned to look, and
    # a control that explains itself answers "why not this one" where one that vanishes only
    # raises the question.
    [ "$can" = "0" ] && "$dialog" "$win" "$CAD_SUMMARIZE_PICKER_ID" omc_disable
    return 0
}
