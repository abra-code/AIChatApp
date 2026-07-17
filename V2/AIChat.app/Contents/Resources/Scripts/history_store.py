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

# ChatItem discriminators the Chat element accepts (ChatModel.swift ItemType). "usage" and
# "plan" are transcript-level fields, not items.
ITEM_TYPES = {"message", "thought", "toolCall", "image", "system", "error"}
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


def _model_label(model_path):
    """Display name for a model path. Mirrors model_display_label() in
    aichat.model.library.sh - keep the two in sync.

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


def cmd_transcript(session_dir, prime=None):
    transcript, _stats = _build_transcript(session_dir)
    # Transient restore directive for the Chat element (NOT part of the persisted
    # transcript; the element's codec drops the key): "defer" displays the conversation
    # WITHOUT touching the agent - the element replays it (ACP session/prime) lazily,
    # when the user next sends into it (the seamless sidebar switch); false displays it
    # with a fresh agent context (Read Only); true/absent replays it immediately.
    if prime is not None:
        transcript["prime"] = prime
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
    return ""


def cmd_meta_init(sid, model_path):
    """Emit a fresh meta.json for a new native session. Called once on first entry.
    Uses json.dumps so a model path with spaces/quotes is escaped correctly."""
    meta = {
        "id": sid,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": "native",
    }
    if model_path:
        meta["modelPath"] = model_path
        meta["model"] = _model_label(model_path)
    json.dump(meta, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def cmd_info(session_dir):
    """One compact line for the info strip above the chat: original model, start date,
    message count. The active model lives in the toolbar; this reflects the conversation's
    own recorded metadata."""
    _transcript, stats = _build_transcript(session_dir)
    bits = []
    if stats.get("model"):
        bits.append("Model: %s" % stats["model"])
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
    if stats.get("model"):
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


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(
            "usage: history_store.py {index|transcript|preview|info|title|meta-init} ...\n")
        return 2
    cmd = argv[1]
    if cmd == "meta-init":
        if len(argv) < 3:
            sys.stderr.write("usage: history_store.py meta-init <sid> [model_path]\n")
            return 2
        return cmd_meta_init(argv[2], argv[3] if len(argv) > 3 else "")
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
        return cmd_transcript(path, prime)
    if cmd == "preview":
        return cmd_preview(path)
    if cmd == "info":
        return cmd_info(path)
    if cmd == "title":
        return cmd_title(path)
    sys.stderr.write("unknown subcommand: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
