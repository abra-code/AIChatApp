#!/usr/bin/env python3
"""history_store.py - read-model for the AIChat history store.

The write path (aichat.chat.entry.sh) appends one finalized-entry envelope per line to
each session's journal.jsonl. Each envelope looks like:

    {"data": <ChatItem>, "id": "<itemId>", "sequence": N, "type": "<type>"}

where <ChatItem> is already exactly the shape the ActionUI Chat element consumes in
states["content"].items (e.g. {"type":"message","message":{"id","role","text"}}), and a
"usage" envelope carries {"data":{"used":N,...}} which maps to the transcript's top-level
"usage". So journal -> ChatTranscript is a near pass-through: collect item envelopes'
`data` (dedup by id, last write wins, first-seen order), take the last usage/plan.

Subcommands (all read-only; never mutate the store):
    index <history_root>       -> TSV rows  "title\tsession_id" (recent first); the
                                  single-column sidebar list reads session_id as a hidden
                                  trailing field (updated date moved to the info line)
    transcript <session_dir>   -> ChatTranscript JSON object for states["content"]
    preview <session_dir>      -> markdown summary (legacy; the chat pane is the preview now)
    info <session_dir>         -> one compact line "Model: X  ·  Started: Y  ·  Messages: N"
                                  for the toggle-able info strip above the chat

No third-party deps; runs under the bundle's embedded python3.
"""
import json
import os
import re
import sys
import time

# ChatItem discriminators the Chat element accepts (ChatModel.swift ItemType), and therefore the
# ones worth keeping: anything not named here is dropped when the journal is folded into a
# transcript. "usage" and "plan" are transcript-level fields, not items.
#
# sessionEvent is a ChatView 0.5.0 item recording that the SESSION changed - started, resumed, or
# handed to a different model - and it has to survive a reload or it answers nothing: the whole
# point is that reopening a conversation tomorrow still says which model wrote which part.
ITEM_TYPES = {"message", "thought", "toolCall", "image", "system", "error", "sessionEvent"}
TITLE_MAX = 60

def _read_journal(session_dir):
    """Yield parsed envelopes from journal.jsonl in write order; skip malformed lines."""
    path = os.path.join(session_dir, "journal.jsonl")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except (ValueError, TypeError):
                    continue
    except OSError:
        return


def _journal_lock(session_dir):
    """Take the per-session append lock, or give up after a bounded wait.

    journal.jsonl is appended to by two writers - this module's session markers and the shell
    handler that appends finalized entries - and `printf >>` from the shell flushes in ~1 KB
    stdio chunks, so a large envelope is several write() calls. Without a lock a second writer
    lands between two of them and both lines are destroyed: the tail of one envelope is spliced
    onto the head of another and _read_journal drops the result. Two conversations in this
    user's history lost a message that way before the lock existed.

    mkdir is the atomic primitive available to both writers. A holder that dies leaves the
    directory behind, so the wait is bounded: after that, write anyway. An interleaved line is
    recoverable by a reader; a deadlocked chat is not.
    """
    path = os.path.join(session_dir, ".journal.lock")
    for _ in range(2000):
        try:
            os.mkdir(path)
            return path
        except FileExistsError:
            time.sleep(0.001)
        except OSError:
            # NOT "someone else is holding it". The session directory is gone (another window
            # deleted this conversation) or is not writable, and no amount of waiting changes
            # either - while the wait itself is two seconds of a handler that runs on the
            # streaming path. Give up now and let the caller's own open() report it.
            return None
    return None


def _journal_unlock(token):
    if token:
        try:
            os.rmdir(token)
        except OSError:
            pass


def _journal_append(session_dir, line):
    token = _journal_lock(session_dir)
    try:
        with open(os.path.join(session_dir, "journal.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(line)
    finally:
        _journal_unlock(token)


def _read_meta(session_dir):
    try:
        with open(os.path.join(session_dir, "meta.json"), "r", encoding="utf-8") as fh:
            data = json.load(fh)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _first_local_text(envelopes):
    """First local (user) message text - the default session title."""
    for env in envelopes:
        if env.get("type") == "message":
            msg = (env.get("data") or {}).get("message") or {}
            if msg.get("role") == "local":
                return msg.get("text") or ""
    return ""


def _clean_title(text):
    text = " ".join((text or "").split())
    if not text:
        return "(untitled)"
    if len(text) > TITLE_MAX:
        text = text[: TITLE_MAX - 1].rstrip() + "…"
    return text


def _session_title(session_dir, meta, envelopes):
    title = (meta.get("title") or "").strip()
    if title:
        return _clean_title(title)
    return _clean_title(_first_local_text(envelopes))


def _updated_epoch(session_dir):
    """Most recent mtime among journal.jsonl / meta.json - proxy for last activity."""
    newest = 0.0
    for name in ("journal.jsonl", "meta.json"):
        try:
            newest = max(newest, os.path.getmtime(os.path.join(session_dir, name)))
        except OSError:
            continue
    if newest == 0.0:
        try:
            newest = os.path.getmtime(session_dir)
        except OSError:
            newest = 0.0
    return newest


# Apple's on-device model, which is not a path at all. Kept in step with FOUNDATION_MODEL_ID in
# aichat.model.library.sh; history records whatever was stamped as the window's model, so this
# side has to know the sentinel too or it renders it raw.
FOUNDATION_MODEL_ID = "foundation:apple-on-device"


def _model_label(model_path):
    """Display name for a model path. Mirrors model_display_label() in
    aichat.model.library.sh - keep the two in sync.

    Foundation Models: a sentinel, not a path. Tested FIRST, for the same reason the shell
      half does: every test below assumes a path, and basename() of a value with no slash is
      the value itself - so the sentinel would render verbatim in the info strip.
    GGUF: keep the filename (its quant suffix, e.g. -Q5_K_S, is exactly what the user is
      choosing between), only drop the .gguf extension.
    MLX in the HF cache (.../models--<org>--<name>/snapshots/<hash>/...): the leaf is a
      content hash, useless as a label, so surface "<org>/<name>" instead.
    ORDER IS LOAD-BEARING: the .gguf test runs FIRST, because a GGUF living in the HF cache
      also matches the snapshot pattern and would otherwise be relabelled org/name, losing
      the quant - the one thing that distinguishes two rows of the same model.
    """
    if not model_path:
        return ""
    if model_path == FOUNDATION_MODEL_ID:
        return "Apple Foundation Models"
    path = model_path.rstrip("/")
    base = os.path.basename(path)
    if base.endswith(".gguf"):
        return base[: -len(".gguf")]
    match = re.search(r"/models--([^/]+)/snapshots/", path)
    if match:
        return match.group(1).replace("--", "/")
    return base


def _build_transcript(session_dir):
    """Return (transcript_dict, stats) where stats = {msgs, model, created}."""
    meta = _read_meta(session_dir)
    envelopes = list(_read_journal(session_dir))

    items = {}          # id -> ChatItem data (dict preserves first-seen order, last value)
    pos = 0
    usage = None
    plan = None
    msg_count = 0
    for env in envelopes:
        etype = env.get("type")
        data = env.get("data")
        if etype in ITEM_TYPES and isinstance(data, dict):
            # ChatView writes its own sessionEvent entries (the marker after a condensed prime)
            # with the payload directly in `data`, without the ChatItem wrapper every other item
            # type carries - ChatStore.swift passes the bare SessionEvent to fireEntry instead of
            # ChatItem.sessionEvent(event). Stored verbatim, that becomes an item with no `type`,
            # and ChatItem's decoder does a plain decode of the discriminator: it throws, the
            # WHOLE ChatTranscript fails, and the restore is a silent no-op. One condensed resume
            # made its conversation unopenable. Wrap it back into the shape it should have had.
            if etype == "sessionEvent" and "type" not in data and "kind" in data:
                data = {"type": "sessionEvent", "sessionEvent": data}
            key = env.get("id")
            if not key:
                pos += 1
                key = "_pos%d" % pos
            items[key] = data
            if etype == "message":
                msg_count += 1
        elif etype == "usage" and isinstance(data, dict):
            usage = data
        elif etype == "plan" and isinstance(data, list):
            # Guard the type: ChatTranscript.plan must be an array. A malformed plan value
            # would otherwise fail the whole transcript decode and silently drop the session.
            plan = data

    transcript = {"version": 1, "items": list(items.values())}
    title = _session_title(session_dir, meta, envelopes)
    if title and title != "(untitled)":
        transcript["title"] = title
    if usage is not None:
        transcript["usage"] = usage
    if plan:
        transcript["plan"] = plan

    # Prefer recomputing the label from the raw modelPath so sessions written before this
    # derivation was HF-cache-aware (their stored "model" is a bare snapshot hash) display
    # correctly. Fall back to the stored label only when no path was recorded.
    model_path = meta.get("modelPath")
    model = _model_label(model_path) if model_path else (meta.get("model") or "")
    stats = {
        "msgs": msg_count,
        "model": model,
        # An external ACP agent has no model path - the agent brings its own model and we
        # never learn which. The conversation is identified by the AGENT instead, and the
        # two are mutually exclusive by construction.
        "agent": meta.get("agent") or "",
        "created": meta.get("created") or "",
        "title": title,
    }
    return transcript, stats


def cmd_index(history_root):
    rows = []
    try:
        entries = os.listdir(history_root)
    except OSError:
        return 0
    for name in entries:
        session_dir = os.path.join(history_root, name)
        if not os.path.isdir(session_dir):
            continue
        if not os.path.exists(os.path.join(session_dir, "journal.jsonl")) and \
           not os.path.exists(os.path.join(session_dir, "meta.json")):
            continue
        meta = _read_meta(session_dir)
        sid = meta.get("id") or name
        envelopes = list(_read_journal(session_dir))
        title = _session_title(session_dir, meta, envelopes)
        epoch = _updated_epoch(session_dir)
        rows.append((epoch, title, sid))
    rows.sort(key=lambda r: r[0], reverse=True)
    out = []
    for _epoch, title, sid in rows:
        # Tabs/newlines in EITHER field would corrupt the TSV fed to
        # omc_table_set_rows_from_stdin and shift the hidden column. Single visible column
        # (Title); sid rides as the hidden trailing field the button handlers read via
        # OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE.
        title = title.replace("\t", " ").replace("\n", " ")
        sid = sid.replace("\t", " ").replace("\n", " ")
        out.append("%s\t%s" % (title, sid))
    sys.stdout.write("\n".join(out))
    if out:
        sys.stdout.write("\n")
    return 0


def cmd_transcript(session_dir, prime=None, condense_keep=None, condense_backend=None):
    transcript, _stats = _build_transcript(session_dir)
    # Transient restore directive for the Chat element (NOT part of the persisted
    # transcript; the element's codec drops the key): "defer" displays the conversation
    # WITHOUT touching the agent - the element replays it (ACP session/prime) lazily,
    # when the user next sends into it (the seamless sidebar switch); false displays it
    # with a fresh agent context (Read Only); true/absent replays it immediately.
    if prime is not None:
        transcript["prime"] = prime
    # The other transient directive, and transient in the same way: the element drops it before
    # anything is persisted, so it can never end up in a stored conversation.
    #
    # PRESENCE OF THE KEY IS THE REQUEST. An empty object means "summarize, your defaults", so
    # this is emitted whenever condensation was asked for, with keepRecentTurns only when the
    # caller pinned it.
    #
    # THE SUMMARIZER RIDES HERE TOO, and that is what makes the menu under the chat mean what it
    # says. It used to be the agent's --digest-backend alone - fixed when the agent launched, one
    # value for the whole app - so a user who chose a summarizer for THIS conversation was answered
    # by whichever one the running agent had been started with, and the only trace was the name in
    # the marker afterwards. `backend` is per restore, so the choice belongs to the conversation it
    # was made in. Absent means "however the agent is configured".
    if condense_keep is not None:
        transcript["condense"] = {"keepRecentTurns": condense_keep} if condense_keep > 0 else {}
        if condense_backend:
            transcript["condense"]["backend"] = condense_backend
    json.dump(transcript, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def cmd_title(session_dir):
    meta = _read_meta(session_dir)
    envelopes = list(_read_journal(session_dir))
    sys.stdout.write(_session_title(session_dir, meta, envelopes))
    return 0


def _preview_line(item):
    itype = item.get("type")
    if itype in ("message", "thought"):
        msg = item.get("message") or {}
        role = msg.get("role")
        who = {"local": "You", "agent": "Assistant", "remote": "Them",
               "system": "System"}.get(role, role or "?")
        if itype == "thought":
            who += " (thinking)"
        text = " ".join((msg.get("text") or "").split())
        if len(text) > 200:
            text = text[:199].rstrip() + "…"
        return "**%s:** %s" % (who, text)
    if itype in ("system", "error"):
        text = " ".join((item.get("text") or "").split())
        label = "System" if itype == "system" else "Error"
        return "*%s: %s*" % (label, text)
    if itype == "toolCall":
        tc = item.get("toolCall") or {}
        return "`tool: %s (%s)`" % (tc.get("title") or "?", tc.get("status") or "")
    if itype == "image":
        return "*[image]*"
    if itype == "sessionEvent":
        ev = item.get("sessionEvent") or {}
        verb = {"started": "Started", "resumed": "Resumed",
                "modelChanged": "Switched"}.get(ev.get("kind"), "Session")
        model = ev.get("model") or ""
        # The digest is the interesting part when there is one: a preview that said only
        # "Resumed" would hide the fact that the model was handed a summary rather than the
        # conversation above it.
        digest = ev.get("digest") or {}
        note = ""
        if digest:
            dropped = digest.get("droppedTurns")
            note = " - %s earlier messages summarized" % dropped if dropped else " - summarized"
            by = digest.get("summarizer")
            if by:
                note += " by %s" % by
        return "*%s%s%s*" % (verb, (" with %s" % model) if model else "", note)
    return ""


def cmd_meta_init(sid, model_path, agent=""):
    """Emit a fresh meta.json for a new native session. Called once on first entry.
    Uses json.dumps so a model path with spaces/quotes is escaped correctly.

    Exactly one of model_path and agent is meaningful: a conversation runs either the bundled
    model or an external ACP agent. Recording the agent is what stops external conversations
    showing a blank where every other row names its model."""
    meta = {
        "id": sid,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": "native",
    }
    if model_path:
        meta["modelPath"] = model_path
        meta["model"] = _model_label(model_path)
    if agent:
        meta["agent"] = agent
    json.dump(meta, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def cmd_info(session_dir):
    """One compact line about a saved conversation - when it started, how much was said.

    It named the conversation's original model too, until the model bar started showing the
    window's CURRENT one immediately to its left. Two model names in one row is a question
    ("which of these is answering me?"), not information, and the transcript already answers
    it properly: the opening session marker records the model the conversation started with,
    and a marker records every switch since."""
    _transcript, stats = _build_transcript(session_dir)
    bits = []
    created = stats.get("created") or ""
    if created:
        if created.endswith("Z"):
            created = created[:-1]
        created = created.replace("T", " ")
        bits.append("Started: %s" % created)
    bits.append("Messages: %d" % stats.get("msgs", 0))
    sys.stdout.write("   ·   ".join(bits))
    return 0


def cmd_preview(session_dir, max_items=8):
    transcript, stats = _build_transcript(session_dir)
    lines = ["## %s" % (stats.get("title") or "(untitled)")]
    meta_bits = []
    if stats.get("agent"):
        meta_bits.append("Agent: %s" % stats["agent"])
    elif stats.get("model"):
        meta_bits.append("Model: %s" % stats["model"])
    meta_bits.append("Messages: %d" % stats.get("msgs", 0))
    if stats.get("created"):
        meta_bits.append("Started: %s" % stats["created"])
    lines.append("  \n".join(meta_bits))
    lines.append("\n---\n")
    items = transcript.get("items", [])
    shown = items[:max_items]
    for item in shown:
        rendered = _preview_line(item)
        if rendered:
            lines.append(rendered + "  ")
    if len(items) > len(shown):
        lines.append("\n*... %d more ...*" % (len(items) - len(shown)))
    if not items:
        lines.append("*(no messages recorded)*")
    sys.stdout.write("\n".join(lines))
    sys.stdout.write("\n")
    return 0


# The model-facing view of a transcript, and the ONLY definition of it in this file.
#
# It mirrors what ACPChatTransport.primeHistory sends on the wire, deliberately and exactly:
# message items whose role is local or agent, with non-empty text, mapped local -> user and
# agent -> assistant. Thoughts, tool calls, images, system notices and P2P (.remote) lines are
# display items - the model never produced or saw them - so summarizing them would put words in
# the model's mouth that its own context never held.
#
# If that filter ever drifts from the transport's, the digest describes a conversation the model
# did not have, which is worse than not digesting at all: it reads as authoritative.
def _wire_messages(transcript):
    out = []
    for item in transcript.get("items", []):
        if item.get("type") != "message":
            continue
        msg = item.get("message") or {}
        role = msg.get("role")
        text = msg.get("text") or ""
        if role not in ("local", "agent") or not text:
            continue
        out.append((item, "user" if role == "local" else "assistant", text))
    return out


def cmd_digest_input(session_dir, keep_recent):
    """Emit the mlx-agent digest wire array for a saved session.

    Exit 3 - the same code mlx-agent uses for "not condensed" - when there is nothing worth
    condensing, so the caller can fall back to a full replay without parsing a message. A
    conversation that would keep every message verbatim has no older part to summarize, and
    running a model over it would spend seconds to produce the transcript it started with.
    """
    transcript, _stats = _build_transcript(session_dir)
    wire = _wire_messages(transcript)
    if len(wire) <= keep_recent + 1:
        return 3
    json.dump([{"role": role, "content": text} for _item, role, text in wire],
              sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def _session_event_item(kind, model=""):
    """Mint one session-marker ChatItem, or None when the kind is not one of ours.

    The marker's IDENTITY is minted here - id and timestamp both - and that matters because a
    marker is now shown to the user before it is recorded (see history_marker_show in
    aichat.history.library.sh). The item that reaches the display is the item that later reaches
    the journal, byte for byte, so what a conversation shows live and what it shows on the next
    load are the same line rather than two lines that merely describe the same event.

    Unique per marker, and never reused: _build_transcript dedups items by id with last-write-
    wins, so a fixed id would make every resume overwrite the previous one and the conversation
    would remember only its most recent opening.
    """
    if kind not in ("started", "resumed", "modelChanged"):
        return None
    event_id = "se-%d-%d" % (int(time.time() * 1000), os.getpid())
    event = {"id": event_id, "kind": kind,
             "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    if model:
        event["model"] = model
    return {"type": "sessionEvent", "sessionEvent": event}


def _session_event_item_checked(item):
    """The marker this store would have minted for <item>, or None if it would not have minted it.

    THE JOURNAL IS APPEND-ONLY, which is what makes this validation rather than tidiness. Anything
    written here is in that conversation for good, and the items arrive from a pasteboard any
    process in the login session can write - so the recording path re-asks every question the mint
    answered instead of trusting the shape it is handed.

    It REBUILDS rather than approves, because approving field by field is a list that has to be
    kept in step with a Codable struct in another language. SessionEvent's optionals are typed
    (`timestamp: String?`, `model: String?`), and Swift's synthesized decoder THROWS on a JSON
    number where it expects a string - so `{"kind": "started", "timestamp": 123}` passes any check
    that only looks at id and kind, and then decodes as nothing: a permanent unreadable-item row in
    that conversation, with no way to remove it from inside the app. Returning a dict assembled
    from validated pieces means only shapes _session_event_item could have produced are ever
    recorded, and a field added there is a field this has to be taught about deliberately.

    The id is the one field that can break the store itself rather than the element: it keys
    _build_transcript's dedup dictionary, so a list or dict raises TypeError and the conversation
    stops opening at all.
    """
    if not isinstance(item, dict) or item.get("type") != "sessionEvent":
        return None
    event = item.get("sessionEvent")
    if not isinstance(event, dict):
        return None
    event_id = event.get("id")
    if not isinstance(event_id, str) or not event_id:
        return None
    if event.get("kind") not in ("started", "resumed", "modelChanged"):
        return None
    timestamp = event.get("timestamp")
    if not isinstance(timestamp, str) or not timestamp:
        return None
    model = event.get("model")
    if model is not None and not isinstance(model, str):
        return None
    rebuilt = {"id": event_id, "kind": event["kind"], "timestamp": timestamp}
    if model:
        rebuilt["model"] = model
    return {"type": "sessionEvent", "sessionEvent": rebuilt}


def _session_event_envelope(item):
    """The journal envelope carrying one session-marker ChatItem.

    The journal stores envelopes ({type, id, data}); the element is handed ChatItems (the `data`).
    Building the envelope from the item - rather than the pair being built together - is what lets
    a marker be shown now and journaled later from the same value.
    """
    return {"type": "sessionEvent", "id": item["sessionEvent"]["id"], "data": item}


def cmd_session_event(session_dir, kind, model=""):
    """Append a session marker to a conversation's journal, and print it for the display.

    WRITTEN BY THE APP, NOT THE ELEMENT, and that split is deliberate. ChatView renders these and
    emits its own only for what the AGENT tells it (a condensed prime, where the digest arrives on
    the wire). Everything else - that a conversation started, was resumed, or was handed to another
    model - is known here and nowhere else: mlx-agent advertises no configOptions, so the element is
    never told which model is answering. The label comes from the app or from no one.

    Appended in the journal's own envelope shape, so it folds into the transcript exactly like a
    message and survives a reload. That is the entire point: the info pane names the model a
    conversation STARTED with, so without a record in the transcript, resuming with a different
    model leaves the second one's identity nowhere.

    THE SHOW-NOW-RECORD-NOW PATH, for a marker whose place in the transcript is the end: an
    in-place model switch, which happens between turns. A marker that OPENS a stretch of
    conversation cannot use it - by the time the first turn of that stretch finalizes, the message
    it belongs in front of is already on screen - so those are minted by session-event-item, shown
    immediately, and recorded by session-event-record when the turn arrives.
    """
    item = _session_event_item(kind, model)
    if item is None:
        sys.stderr.write("session-event: unknown kind %s\n" % kind)
        return 2
    try:
        _journal_append(session_dir,
                        json.dumps(_session_event_envelope(item), ensure_ascii=False) + "\n")
    except OSError:
        return 1
    # Print the ChatItem - the envelope's `data`, not the envelope - so the caller can hand it
    # straight to the element's append state and have the marker appear NOW rather than on the next
    # load. Exactly what a restore would rebuild for this line, so showing it and reloading it
    # produce the same transcript.
    sys.stdout.write(json.dumps(item, ensure_ascii=False))
    return 0


def cmd_session_event_item(kind, model=""):
    """Mint a session marker WITHOUT recording it: print the ChatItem and touch no journal.

    For the markers that open a stretch of conversation ("started", "resumed"). They belong in
    front of the first message of that stretch, which is a place the append state cannot reach
    once the message is on screen - and the message is on screen before its entry ever finalizes.
    So the window shows the marker at the moment it becomes able to answer, and holds the item
    until a turn arrives to record it against (session-event-record). No session directory is
    needed or touched here, which is the point: at that moment there may not be one yet.
    """
    item = _session_event_item(kind, model)
    if item is None:
        sys.stderr.write("session-event-item: unknown kind %s\n" % kind)
        return 2
    sys.stdout.write(json.dumps(item, ensure_ascii=False))
    return 0


def cmd_session_event_record(session_dir):
    """Record markers that were already SHOWN: one ChatItem JSON per line on stdin.

    The other half of session-event-item. Written in one locked append so the markers land in the
    order the window showed them, and BEFORE the entry that triggered the recording (the caller
    journals that next) - which is the whole point of the split: the marker leads the message it
    opened instead of trailing it.

    A line that is not one of our markers is skipped rather than fatal. This runs on the first turn
    of a conversation, and refusing to record a marker is a cosmetic loss; refusing to record the
    conversation is not.
    """
    # split("\n"), NOT splitlines(). The queue is built and read with "\n" on the shell side, while
    # splitlines() ALSO breaks on U+0085, U+2028 and U+2029 - the three that survive
    # ensure_ascii=False unescaped (everything below 0x20 is escaped whatever that flag says). A
    # model label carrying one of them, from a .gguf filename or a typed agent name, would leave
    # the two halves disagreeing about how many markers they are looking at, and every fragment
    # would then be discarded as unparseable - shown to the user, and silently never recorded.
    lines = []
    for raw in sys.stdin.read().split("\n"):
        raw = raw.strip()
        if not raw:
            continue
        try:
            item = json.loads(raw)
        except ValueError:
            sys.stderr.write("session-event-record: not JSON, skipping a line\n")
            continue
        checked = _session_event_item_checked(item)
        if checked is None:
            sys.stderr.write("session-event-record: not a session marker, skipping a line\n")
            continue
        lines.append(json.dumps(_session_event_envelope(checked), ensure_ascii=False) + "\n")
    if not lines:
        return 0
    try:
        _journal_append(session_dir, "".join(lines))
    except OSError:
        return 1
    return 0


def cmd_meta_set(session_dir, key, value):
    """Set one string field in meta.json, preserving the rest.

    Atomic for the same reason history_init_meta is: history_index scans these files
    concurrently and must never read a torn one.
    """
    meta = _read_meta(session_dir)
    if not isinstance(meta, dict):
        meta = {}
    meta[key] = value
    # Suffixed with the pid rather than the bare "meta.json.tmp" that history_init_meta uses.
    # Two writers sharing one temp path do not corrupt the file - the rename keeps readers safe -
    # but they do interleave, and the loser's update vanishes with nothing to show for it.
    tmp = os.path.join(session_dir, "meta.json.tmp.%d" % os.getpid())
    try:
        with open(tmp, "w") as handle:
            json.dump(meta, handle, ensure_ascii=False)
        os.rename(tmp, os.path.join(session_dir, "meta.json"))
    except (IOError, OSError):
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return 1
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(
            "usage: history_store.py {index|transcript|preview|info|title|meta-init|"
            "meta-set|session-event|session-event-item|session-event-record|"
            "digest-input} ...\n")
        return 2
    cmd = argv[1]
    if cmd == "meta-init":
        if len(argv) < 3:
            sys.stderr.write("usage: history_store.py meta-init <sid> [model_path] [agent]\n")
            return 2
        return cmd_meta_init(argv[2], argv[3] if len(argv) > 3 else "",
                             argv[4] if len(argv) > 4 else "")
    # Takes a KIND where every other subcommand takes a session directory - it mints a marker for
    # a window that may not have a session yet - so it is dispatched here, above the path check.
    if cmd == "session-event-item":
        if len(argv) < 3:
            sys.stderr.write("usage: history_store.py session-event-item <kind> [model]\n")
            return 2
        return cmd_session_event_item(argv[2], argv[3] if len(argv) > 3 else "")
    if len(argv) < 3:
        sys.stderr.write("usage: history_store.py %s <path>\n" % cmd)
        return 2
    path = argv[2]
    if cmd == "index":
        return cmd_index(path)
    if cmd == "transcript":
        # Optional third positional: "true"/"false"/"defer" -> the transient "prime" key
        # on the emitted JSON; anything else / absent -> key omitted (element default:
        # replay immediately).
        prime = None
        if len(argv) > 3:
            prime = {"true": True, "false": False, "defer": "defer"}.get(argv[3].lower())
        # Optional fourth positional: keepRecentTurns for a condensed restore. Absent means no
        # condense key at all, which is the documented "replay everything" default.
        condense_keep = None
        if len(argv) > 4 and argv[4] != "":
            try:
                condense_keep = max(0, int(argv[4]))
            except ValueError:
                sys.stderr.write("transcript: condense keep must be a number\n")
                return 2
        # Optional fifth positional: which model summarizes THIS restore (the agent's
        # vocabulary - auto/foundation/session/none for mlx-agent). Only meaningful alongside a
        # condense request, and empty means "the agent's own default".
        condense_backend = argv[5] if len(argv) > 5 and argv[5] != "" else None
        return cmd_transcript(path, prime, condense_keep, condense_backend)
    if cmd == "preview":
        return cmd_preview(path)
    if cmd == "info":
        return cmd_info(path)
    if cmd == "title":
        return cmd_title(path)
    if cmd == "digest-input":
        # keep-recent is parsed defensively: a non-numeric value would otherwise raise and be
        # reported as a broken session rather than a bad argument.
        try:
            keep = int(argv[3]) if len(argv) > 3 else 6
        except ValueError:
            sys.stderr.write("digest-input: keep-recent must be a number\n")
            return 2
        return cmd_digest_input(path, max(0, keep))
    if cmd == "session-event":
        if len(argv) < 4:
            sys.stderr.write("usage: history_store.py session-event <dir> <kind> [model]\n")
            return 2
        return cmd_session_event(path, argv[3], argv[4] if len(argv) > 4 else "")
    if cmd == "session-event-record":
        return cmd_session_event_record(path)
    if cmd == "meta-set":
        if len(argv) < 5:
            sys.stderr.write("usage: history_store.py meta-set <dir> <key> <value>\n")
            return 2
        return cmd_meta_set(path, argv[3], argv[4])
    sys.stderr.write("unknown subcommand: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
