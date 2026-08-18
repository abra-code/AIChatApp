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

# The ACP agent, used here only for its offline `digest` verb (see the digest section below).
# A library variable rather than a local so a test can point it at a stand-in, the same way
# $prefs is redirected - summarizing for real means loading a model and waiting seconds for an
# answer that varies run to run, which is not something an assertion can be written against.
history_agent_bin="$OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent"

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
    "$history_py" "$history_store" transcript "$1" ${2:+"$2"}
}

# history_info_line <sid> — one compact "Model · Started · Messages" line for the info strip.
history_info_line() {
    local dir
    dir=$(history_session_dir "$1") || return 1
    "$history_py" "$history_store" info "$dir"
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
# ("true"/"false"/"defer") is the context directive (see history_transcript_json).
history_inject_content() {
    local dir transcript
    dir=$(history_session_dir "$3") || return 1
    transcript=$(history_transcript_json "$dir" ${4:+"$4"})
    [ -n "$transcript" ] || return 1
    "$dialog" "$1" "$2" omc_set_state content "$transcript"
}

# =============================================================================
# Resuming a long conversation as a digest
# =============================================================================
#
# Replaying a whole conversation into a model costs a full prefill of every token in it, and on
# a small window it may not fit at all. mlx-agent's `digest` verb summarizes the older part into
# structured notes and renders them as one user turn, keeping the recent messages verbatim.
#
# THE BATCH VERB, NOT session/prime's `condense`. Both produce the same digest, but the live
# path needs the Chat element to ask for it, and the element sends session/prime with only
# sessionId and messages (ChatView's ACPChatTransport). Reaching the live path means changing a
# separate published Swift package and rebuilding the framework; the batch verb needs neither,
# because what it returns is text this layer can inject as an ordinary transcript.
#
# The digest is DISPLAY AND WIRE ALIKE, which is the honest consequence of doing it here rather
# than in the element: the window shows the summary and the recent turns, not the full
# scrollback. Nothing is lost - journal.jsonl is append-only and untouched, so resuming the same
# conversation with Full Reload brings back every original turn.
#
# WHICH MODEL WRITES THE SUMMARY IS THE POINT OF THE MENU, not a detail under it. The summary
# becomes the model's memory of everything it replaces, so a 3B on-device model summarizing a
# conversation held with something ten times its size is a real loss, and the chat then carries
# that summary as fact. The first version of this hardcoded the on-device model and never asked.
#
# So the menu names the summarizer, and nothing here substitutes one for another: a choice that
# cannot be honored is refused and reported. The cheap case is also the good one - a gguf window
# already has llama-server holding that exact model, so borrowing it costs no load - while an
# mlx model lives inside the agent process and would have to be loaded a second time, and an
# external ACP agent exposes no model to borrow at all.

# How many messages to ASK the summarizer to keep verbatim. mlx-agent's own default is 6.
#
# A request, not a promise, and the difference matters: DigestPlanner.split snaps the boundary
# backward to the nearest user turn so the tail starts cleanly, so it can keep more than asked.
# What this layer displays is read back from the summarizer's own report - see the keep=
# derivation in history_digest_inject. An earlier version of this comment claimed that using the
# same number on both sides was sufficient. It is not, and the gap it leaves is silent.
CAD_DIGEST_KEEP_RECENT=6

# The token that says "what is on screen is still what this job was started for".
#
# Bumped by every action that changes the displayed conversation - selecting a row, either
# direction of the checkbox, New Chat - and re-checked by a digest immediately before it writes.
#
# AN IDENTITY CHECK IS NOT ENOUGH, which is what this replaced. Comparing the session id only
# asks "is this window still on the same conversation"; it cannot see a user who resumed a long
# conversation, watched the box come up checked, and unchecked it while the digest was still
# running. The session id never changed, so a stale digest passed that check and overwrote the
# full transcript the user had just asked for - leaving meta.json saying "full", the checkbox
# unchecked, and the summary on screen and in the model's context.
#
# Seconds plus pid rather than a counter: a read-modify-write counter is itself a race between
# two handlers, and handlers here can overlap.
resume_epoch_bump() { # <win>
    resume_epoch_new="$(/bin/date +%s).$$"
    pb_set "aichatv2_resume_epoch_$1" "$resume_epoch_new"
    printf '%s\n' "$resume_epoch_new"
}

# resume_epoch <win> - the current token.
resume_epoch() {
    pb_get "aichatv2_resume_epoch_$1"
}

# Above this many model-facing messages, resuming offers the choice. Below it a full replay is
# cheap enough that asking would be friction for no benefit - and a digest of a short
# conversation is mostly preamble anyway.
CAD_DIGEST_ASK_ABOVE=24

# history_wire_count <sid> - model-facing messages in a conversation, "0" when unreadable.
#
# Counted through the same filter the digest and the transport use, so the number the size gate
# tests is the number that would actually be replayed - not the item count, which includes
# thoughts and tool calls the model never saw.
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

# summarize_session_base_url <win> - the chat's own model, as an OpenAI base URL, when it is
# reachable without loading anything. Empty otherwise.
#
# Only a gguf window has one: llama-server is already running with that exact model, on a port
# stashed at init. An mlx model lives inside the agent process, so the batch verb would build a
# SECOND backend and load gigabytes before writing a word - which is why "the model in this
# chat" is offered when this returns something and not otherwise.
summarize_session_base_url() { # <win>
    local port base
    port=$(pb_get "aichatv2_port_$1")
    case "${port:-}" in
        ''|*[!0-9]*) return 0 ;;
    esac
    base="http://127.0.0.1:$port/v1"
    # Probed rather than assumed. The port is stashed for the window's life, but the server
    # behind it can be gone - crashed, or reaped while the window sat idle - and offering a
    # dead one would put a choice in the menu that fails the moment it is picked.
    /usr/bin/curl -fsS --max-time 2 "$base/models" >/dev/null 2>&1 || return 0
    printf '%s\n' "$base"
}

# summarize_foundation_ok - true when Apple's on-device model can write a summary here.
#
# APPLE INTELLIGENCE IS macOS 26 AND LATER, so on anything older this is simply not one of the
# choices - which is the reason the control is a menu rather than a checkbox. foundation_probe
# reports `osTooOld` for exactly that, and foundation_offerable is the app's existing verdict on
# which reasons are permanent; reusing it means this agrees with the model picker rather than
# inventing a second opinion about the same machine.
summarize_foundation_ok() {
    local reason
    command -v foundation_probe >/dev/null 2>&1 || \
        source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"
    reason=$(foundation_probe 2>/dev/null | /usr/bin/head -n 1 | /usr/bin/cut -f1)
    [ -n "$reason" ] || return 1
    foundation_offerable "$reason"
}

# summarize_backend_args <win> <mode> - the digest flags for the chosen summarizer.
#
# Empty output means the choice cannot be honored right now, which the caller treats as a
# refusal rather than quietly summarizing with something else. Substituting a different model
# than the one named in the menu would make the menu a lie.
summarize_backend_args() { # <win> <mode>
    local base
    case "$2" in
        session)
            base=$(summarize_session_base_url "$1")
            [ -n "$base" ] || return 1
            printf -- '--backend openai --base-url %s\n' "$base" ;;
        foundation)
            summarize_foundation_ok || return 1
            printf -- '--backend foundation\n' ;;
        *)  return 1 ;;
    esac
}

# summarize_can_condense <sid> - true when there is actually an older half to summarize.
#
# Asked of digest-input rather than recomputed here, because it is the same call the digest
# itself will make: a rule restated in two places is a rule that can disagree with itself, and
# the disagreement here is a control that offers something the next step refuses.
#
# A conversation of keep-recent + 1 messages or fewer would keep every message verbatim, so
# there is nothing to summarize and no work worth seconds of a model's time.
summarize_can_condense() { # <sid>
    local dir
    dir=$(history_session_dir "$1") || return 1
    "$history_py" "$history_store" digest-input "$dir" "$CAD_DIGEST_KEEP_RECENT" \
        >/dev/null 2>&1
}

# history_resume_mode <sid> - "full", "digest", or "" when the user has not chosen yet.
history_resume_mode() {
    history_meta_field "$1" resumeMode
}

# history_set_resume_mode <sid> <full|digest> - remember the choice with the conversation.
#
# In meta.json rather than on a pasteboard key because the decision belongs to the CONVERSATION,
# not to the window that happened to open it: the same answer should hold tomorrow, and in a
# second window, without asking again.
history_set_resume_mode() {
    local dir
    dir=$(history_session_dir "$1") || return 1
    "$history_py" "$history_store" meta-set "$dir" resumeMode "$2"
}

# history_digest_inject <win> <view_id> <sid> - resume a conversation as a digest.
#
# 0 injected. Nonzero means the conversation was left exactly as it was, and the caller falls
# back to a full replay - every failure mode here resolves to the whole history rather than to a
# truncated one, which is mlx-agent's own guarantee and has to stay this layer's too.
#
# The nonzero codes are SEPARATE because the user-facing sentence differs, and getting that
# wrong is its own bug: telling someone to go and enable Apple Intelligence when their
# conversation was merely too short sends them to fix something that was never broken.
#
#   3  nothing to condense - the conversation has no older half
#   4  the summarizer is unavailable or declined - no on-device model, or it refused
#   5  superseded - the user did something else while this ran; NOT a failure, and not
#      something to report, because a later decision already owns the window
#   1  a real failure - the transcript could not be built or written
#
# Summarized with the on-device model on purpose. It is always present, costs no download and no
# GB of RAM, and needs no model load - measured at about 7 seconds for a 14-message conversation,
# against the tens of seconds a second copy of a local model would spend loading before it began.
history_digest_inject() {
    local win="$1" view_id="$2" sid="$3" guard="${4:-}" mode="${5:-}"
    local dir work rc transcript keep backend_args

    dir=$(history_session_dir "$sid") || return 1
    [ -x "$history_agent_bin" ] || return 4

    work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cadabra-digest.XXXXXX") || return 1

    "$history_py" "$history_store" digest-input "$dir" "$CAD_DIGEST_KEEP_RECENT" \
        > "$work/in.json" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        /bin/rm -rf "$work"
        return 3
    fi

    # THE MODEL THE USER PICKED, or nothing. No silent substitution: the menu names which model
    # writes the summary, so quietly using a different one would make the menu a lie about the
    # thing that matters most here - the summary becomes the model's memory of what it replaces.
    backend_args=$(summarize_backend_args "$win" "$mode")
    if [ -z "$backend_args" ]; then
        /bin/rm -rf "$work"
        return 4
    fi

    # Unquoted on purpose: this is a flag LIST, and the point is that it expands to two flags or
    # four. Every value in it is built here from a numeric port, so nothing a field split can
    # break reaches this line.
    "$history_agent_bin" digest $backend_args --in "$work/in.json" --render \
        --keep-recent "$CAD_DIGEST_KEEP_RECENT" > "$work/preamble.txt" 2>"$work/digest.err"
    rc=$?

    if [ "$rc" -ne 0 ] || [ ! -s "$work/preamble.txt" ]; then
        echo "digest: not condensed (rc=$rc) for $sid: $(/usr/bin/tail -n 1 "$work/digest.err" 2>/dev/null)" >&2
        /bin/rm -rf "$work"
        return 4
    fi

    # HOW MANY MESSAGES THE SUMMARIZER ACTUALLY LEFT VERBATIM, read from its own report rather
    # than assumed to be the number we asked for.
    #
    # --keep-recent is a request, not a promise. DigestPlanner.split snaps the boundary BACKWARD
    # to the nearest user turn so the verbatim tail starts cleanly, which means it can keep MORE
    # than asked. Reusing our own number would then take a shorter tail than the summary
    # actually stops at, and the messages in between would be neither summarized nor displayed -
    # gone from the window and from the model, with nothing reporting it.
    #
    # accepted - droppedTurns is the count that survived verbatim; RESULT_JSON is on stderr on
    # every successful run. If it cannot be read, fall back to what we asked for: that restores
    # the old behavior rather than inventing a number, and the old behavior is right whenever the
    # boundary did not move, which is the common case.
    keep=$("$history_py" -c 'import json,re,sys
try:
    m = re.search(r"RESULT_JSON:\s*(\{.*\})", open(sys.argv[1]).read())
    d = json.loads(m.group(1))
    n = int(d["accepted"]) - int(d["droppedTurns"])
    sys.stdout.write(str(n) if n > 0 else "")
except Exception:
    pass' "$work/digest.err" 2>/dev/null)
    case "${keep:-}" in
        ''|*[!0-9]*) keep="$CAD_DIGEST_KEEP_RECENT" ;;
    esac

    transcript=$("$history_py" "$history_store" digest-transcript "$dir" "$work/preamble.txt" \
        "$keep" defer 2>/dev/null)
    rc=$?
    /bin/rm -rf "$work"
    [ "$rc" -eq 0 ] && [ -n "$transcript" ] || return 1

    # Re-checked HERE, immediately before the write, and not only at the start. Everything above
    # this line takes seconds; a check made before it answers a question about a window state
    # that has had every opportunity to change since. This is the last instruction before the
    # conversation on screen is replaced, which is the only place the answer is still true.
    #
    # The token covers navigation AND the checkbox, which a session-id comparison could not: it
    # is bumped by every action that changes what is displayed, so a digest that was overtaken
    # by any of them stops here rather than overwriting the result of a later decision.
    if [ -n "$guard" ] && [ "$(resume_epoch "$win")" != "$guard" ]; then
        return 5
    fi

    "$dialog" "$win" "$view_id" omc_set_state content "$transcript"
}

# The Summarize checkbox, in the slot under the chat (aichat.chat.json id 560).
#
# It exists only while a SAVED conversation is loaded. A new chat has no older half to
# summarize, so the control is removed rather than disabled - omc_remove_element collapses the
# slot to nothing, where omc_disable would leave a permanent grey row under every new chat.
CAD_SUMMARIZE_SLOT_ID=560
CAD_SUMMARIZE_PICKER_ID=561

# The chat element's view id. Every handler declares CHAT_VIEW_ID=1 for itself; the background
# path below runs inside this library and has no handler to borrow it from.
CAD_CHAT_VIEW_ID=1

# summarize_hide <win> - collapse the slot. Safe to call when nothing is there.
summarize_hide() {
    "$dialog" "$1" "$CAD_SUMMARIZE_PICKER_ID" omc_remove_element 2>/dev/null
    return 0
}

# summarize_show <win> <sid> - create the checkbox for a resumed conversation.
#
# Checked when this conversation has been answered for before, otherwise when it is long enough
# that summarizing would help. The remembered answer wins over the recommendation: a user who
# unchecked it once should not have to keep unchecking it every time they come back.
summarize_show() {
    local win="$1" sid="$2" mode chosen epoch help opts can session_url fm

    # WHAT IS ACTUALLY POSSIBLE COMES FIRST, and builds the menu from it.
    #
    # A choice that cannot be honored is worse than no choice. The first version of this offered
    # a checkbox on every resume: on a conversation with nothing to summarize the user could tick
    # it, watch the digest decline, and see the box flip itself back - which reads as the app
    # fighting them and says nothing about why.
    #
    # Answered once each and reused. summarize_can_condense builds the whole transcript, and the
    # foundation probe talks to a system daemon; neither answer can change mid-resume.
    if summarize_can_condense "$sid"; then can=1; else can=0; fi
    session_url=$(summarize_session_base_url "$win")
    if summarize_foundation_ok; then fm=1; else fm=0; fi

    # Always first, always present: the conversation as it was. It is the only option that needs
    # nothing to be available, which is why it is also where every failure lands.
    opts='{"title":"Replay the full conversation","tag":"full"}'
    if [ "$can" = "1" ] && [ -n "$session_url" ]; then
        opts="$opts,"'{"title":"Summarize with the model in this chat","tag":"session"}'
    fi
    # APPLE INTELLIGENCE IS macOS 26 AND LATER. On anything older this entry is simply absent
    # rather than present-and-failing, which is the reason this control is a menu and not a
    # checkbox: what can write a summary differs per machine, and a checkbox cannot say so.
    if [ "$can" = "1" ] && [ "$fm" = "1" ]; then
        opts="$opts,"'{"title":"Summarize with Apple Intelligence","tag":"foundation"}'
    fi

    # What is selected: the answer already given for this conversation if it is still on offer,
    # otherwise the recommendation, otherwise the full conversation. A stored choice whose model
    # is gone - Apple Intelligence turned off, the chat's server stopped - falls back rather than
    # showing a selection that would fail the moment it ran.
    mode=$(history_resume_mode "$sid")
    case "$mode" in
        session)    [ -n "$session_url" ] || mode="" ;;
        foundation) [ "$fm" = "1" ]       || mode="" ;;
        full)       ;;
        *)          mode="" ;;
    esac
    if [ "$can" = "0" ]; then
        chosen=full
    elif [ -n "$mode" ]; then
        chosen="$mode"
    elif [ "$(history_wire_count "$sid")" -gt "$CAD_DIGEST_ASK_ABOVE" ]; then
        # The recommendation prefers the chat's own model, because it is both the better
        # summarizer and the free one - llama-server already holds it loaded.
        if [ -n "$session_url" ]; then chosen=session
        elif [ "$fm" = "1" ];   then chosen=foundation
        else                         chosen=full
        fi
    else
        chosen=full
    fi

    if [ "$can" = "0" ]; then
        help="This conversation is short enough to replay in full - there is no older part to summarize."
    elif [ -z "$session_url" ] && [ "$fm" = "0" ]; then
        help="No summarizer is available: this chat's model cannot be reached, and Apple Intelligence needs macOS 26 or later."
    else
        help="Summarizing replaces the older messages with a summary and keeps the last $CAD_DIGEST_KEEP_RECENT exactly. The saved conversation is not changed either way."
    fi

    # SIZED AS A PAIR. The label's font and the control's size are set together on purpose: a
    # footnote label beside a default-size menu reads as two unrelated things stacked under the
    # composer, which is what it looked like first. controlSize "small" brings the menu down to
    # the strip it sits in, and subheadline brings the label up to meet it - one step above
    # footnote and one below body, so it stays secondary to the conversation without shrinking
    # away from the control it names.
    summarize_hide "$win"
    "$dialog" "$win" "$CAD_SUMMARIZE_SLOT_ID" omc_insert_element "{\"type\":\"Picker\",\"id\":$CAD_SUMMARIZE_PICKER_ID,\"properties\":{\"title\":\"On resume\",\"options\":[$opts],\"pickerStyle\":\"menu\",\"controlSize\":\"small\",\"font\":\"subheadline\",\"actionID\":\"aichat.chat.summarize.mode\",\"help\":\"$help\",\"padding\":{\"top\":4,\"bottom\":6,\"leading\":14,\"trailing\":14},\"frame\":{\"maxWidth\":\"infinity\",\"alignment\":\"leading\"}}}"
    "$dialog" "$win" "$CAD_SUMMARIZE_PICKER_ID" "$chosen"

    # Shown but not usable, rather than hidden. The row is where the user has learned to look,
    # and a control that is present and explains itself answers "why can I not summarize this
    # one" - where a control that vanishes only raises the question.
    if [ "$can" = "0" ] || { [ -z "$session_url" ] && [ "$fm" = "0" ]; }; then
        "$dialog" "$win" "$CAD_SUMMARIZE_PICKER_ID" omc_disable
        return 0
    fi

    # A summarizing choice selected at load means the conversation should already BE summarized -
    # a menu describing something that has not happened is just wrong. Applied in the background
    # so the sidebar click stays instant: the digest takes seconds, and the model is not touched
    # until the next send anyway, so re-injecting before then is free.
    #
    # The token is taken HERE, after the display has settled, and handed to the job. Anything the
    # user does next bumps it and the job stands down.
    if [ "$chosen" != "full" ]; then
        epoch=$(resume_epoch_bump "$win")
        summarize_apply_async "$win" "$sid" "$epoch" "$chosen"
    fi
    return 0
}

# summarize_apply_async <win> <sid> - digest this conversation into the window, in the
# background, and only if the window is still showing it when the work finishes.
#
# THE GUARD IS THE POINT. A digest takes seconds and a sidebar is a list people click through,
# so the conversation on screen when this finishes is often not the one it started for.
# Injecting anyway would drop one conversation's summary into another's window - and because
# the injection also seeds the wire, the model would then be primed with a conversation the
# user is not looking at. The binding is re-read from the pasteboard immediately before the
# inject rather than captured up front, so it reflects the last click, not the first.
summarize_apply_async() {
    local win="$1" sid="$2" epoch="$3" mode="${4:-}"
    (
        # Detached from the handler's stdout/stderr on purpose. A background child inherits
        # them, and under the test harness that means holding the suite's log pipe open for as
        # long as this runs - which reads as a hung test rather than a slow digest.
        history_digest_inject "$win" "$CAD_CHAT_VIEW_ID" "$sid" "$epoch" "$mode" || exit 0
    ) >/dev/null 2>&1 &
    return 0
}
