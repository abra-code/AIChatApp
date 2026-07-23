#!/usr/bin/env python3
"""webui_history_convert.py - convert extracted WebUI dumps into history sessions.

Consumes the webui-dump-*.json files produced by webui_history_extract.py (Route B) or the
in-app dump page (Route A - same shape) and writes one native history session directory per
conversation, in the AIChat history-store layout:

    <out>/webui-<convId>/
        meta.json        {id, source:"webui-import", title, created, updated, origin, ...}
        transcript.json  ChatTranscript v1 (the active branch, mapped to Chat items)
        archive.json     the untouched {conv, messages} - lossless, keeps flattened branches

The WebUI stores messages as a TREE (branch/edit support); we flatten to the ACTIVE branch
(the conv.currNode -> parent chain) for the transcript and preserve the full tree in
archive.json. Conversations are deduped across origins/DBs by id (LlamaUi beats
LlamacppWebui, newer lastModified breaks ties). Idempotent: the session id derives from the
conversation id, and a re-run upserts only when lastModified is newer - so it is safe to run
repeatedly up to the final cutover. No third-party deps.

Usage:
    webui_history_convert.py <dumps_dir> <out_dir>
"""
import glob
import json
import os
import sys
import time

DB_PRIORITY = {"LlamaUi": 2, "LlamacppWebui": 1}
# WebUI role -> ChatRole (valid: local, agent, remote, system). "tool" is folded into cards.
ROLE_MAP = {"user": "local", "assistant": "agent", "system": "system"}


def _iso(ms):
    if not ms:
        return ""
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(float(ms) / 1000.0))
    except (ValueError, OSError):
        return ""


def _guess_kind(name):
    n = (name or "").lower()
    pairs = [("read", "read"), ("cat", "read"), ("get", "read"),
             ("edit", "edit"), ("write", "edit"), ("apply", "edit"), ("patch", "edit"),
             ("delete", "delete"), ("remove", "delete"),
             ("move", "move"), ("rename", "move"),
             ("search", "search"), ("grep", "search"), ("find", "search"), ("list", "search"),
             ("exec", "execute"), ("command", "execute"), ("run", "execute"),
             ("bash", "execute"), ("shell", "execute"),
             ("fetch", "fetch"), ("http", "fetch"), ("url", "fetch"), ("web", "fetch")]
    for needle, kind in pairs:
        if needle in n:
            return kind
    return "other"


def _active_branch(conv, by_id):
    """Messages on the active branch (root-first), following currNode -> parent."""
    branch = []
    node = conv.get("currNode")
    seen = set()
    while node and node in by_id and node not in seen:
        seen.add(node)
        m = by_id[node]
        branch.append(m)
        node = m.get("parent")
    branch.reverse()
    return branch


def _tool_results(branch):
    """toolCallId -> result content, from the tool-role messages on the branch."""
    out = {}
    for m in branch:
        if m.get("role") == "tool" and m.get("toolCallId"):
            out[m["toolCallId"]] = m.get("content") or ""
    return out


def _tool_call_items(msg, tool_results):
    """Map a message's toolCalls JSON string to ChatItem toolCall entries."""
    raw = msg.get("toolCalls")
    if not raw:
        return []
    try:
        calls = json.loads(raw) if isinstance(raw, str) else raw
    except (ValueError, TypeError):
        return []
    if not isinstance(calls, list):
        return []
    items = []
    for c in calls:
        if not isinstance(c, dict):
            continue
        fn = c.get("function") or {}
        name = fn.get("name") or c.get("name") or "tool"
        cid = c.get("id") or "%s-tc%d" % (msg.get("id", "m"), len(items))
        result = tool_results.get(cid, "")
        items.append({
            "type": "toolCall",
            "toolCall": {
                "id": cid,
                "title": name,
                "kind": _guess_kind(name),
                "status": "completed" if result else "pending",
                "contentText": result,
                "rawInput": fn.get("arguments") or "",
            },
        })
    return items


def build_transcript(conv, messages):
    """Return (transcript_dict, stats). stats: {branch, total, model}."""
    by_id = {m["id"]: m for m in messages if isinstance(m, dict) and "id" in m}
    branch = _active_branch(conv, by_id)
    tool_results = _tool_results(branch)

    items = []
    model = ""
    for m in branch:
        role = m.get("role")
        mtype = m.get("type")
        if mtype == "root":
            continue  # structural tree root, not a real message
        if role == "tool":
            continue  # folded into the toolCall card of the requesting message
        mid = m.get("id") or "m%d" % len(items)
        if m.get("model"):
            model = m["model"]

        # reasoning/thinking -> a thought item preceding the message
        thought = m.get("thinking") or m.get("reasoningContent")
        if thought and role == "assistant":
            items.append({"type": "thought",
                          "message": {"id": mid + "-thought", "role": "agent",
                                      "text": str(thought)}})
        # tool-call request cards (assistant)
        items.extend(_tool_call_items(m, tool_results))

        # Emit the message only when it has real text. A tool-use turn often has empty
        # content (its payload is the toolCalls, already emitted as cards above), so an
        # empty agent message would just be noise.
        text = str(m.get("content") or "")
        if text.strip():
            items.append({"type": "message",
                          "message": {"id": mid, "role": ROLE_MAP.get(role, "system"),
                                      "text": text}})

    transcript = {"version": 1, "items": items}
    name = (conv.get("name") or "").strip()
    if name:
        transcript["title"] = name
    return transcript, {"branch": len(branch), "total": len(messages), "model": model}


def _load_dumps(dumps_dir):
    """conversation id -> winning (conv, messages, port, dbName) across all dumps."""
    best = {}
    for path in sorted(glob.glob(os.path.join(dumps_dir, "webui-dump-*.json"))):
        try:
            dump = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        port = dump.get("port")
        dbname = dump.get("dbName") or "unknown"
        prio = DB_PRIORITY.get(dbname, 0)
        by_conv = {}
        for m in dump.get("messages", []):
            if isinstance(m, dict) and m.get("convId"):
                by_conv.setdefault(m["convId"], []).append(m)
        for conv in dump.get("conversations", []):
            cid = conv.get("id")
            if not cid:
                continue
            lm = conv.get("lastModified") or 0
            cur = best.get(cid)
            if cur is None or (prio, lm) > (cur["prio"], cur["lm"]):
                best[cid] = {"conv": conv, "messages": by_conv.get(cid, []),
                             "port": port, "dbName": dbname, "prio": prio, "lm": lm}
    return best


# The live write path (aichat.chat.entry.sh) records history as journal.jsonl - one envelope
# {"sequence","type","id","data":<ChatItem>} per line - and history_store.py's read model
# (index/transcript/title/info) reads ONLY journal.jsonl. So an imported session MUST have a
# journal.jsonl or it lists (via meta.json) but restores empty, and a continued turn appended to
# a missing journal would drop the imported history. We derive the journal from the same items
# build_transcript already produced, making imported sessions structurally identical to native
# ones: they restore, and continuing one appends new turns after the imported history.
def _item_env_id(item, pos):
    itype = item.get("type")
    if itype in ("message", "thought"):
        return (item.get("message") or {}).get("id") or "webui-i%d" % pos
    if itype == "toolCall":
        return (item.get("toolCall") or {}).get("id") or "webui-i%d" % pos
    return item.get("id") or "webui-i%d" % pos


def _journal_bytes(transcript):
    seq = 0
    out = []
    for item in transcript.get("items", []):
        seq += 1
        out.append(json.dumps({"sequence": seq, "type": item.get("type"),
                               "id": _item_env_id(item, seq), "data": item},
                              ensure_ascii=False))
    for level_key in ("usage", "plan"):  # transcript-level envelopes, if ever present
        if level_key in transcript:
            seq += 1
            out.append(json.dumps({"sequence": seq, "type": level_key,
                                   "data": transcript[level_key]}, ensure_ascii=False))
    return ("\n".join(out) + "\n") if out else ""


def _write_session(out_dir, entry):
    conv = entry["conv"]
    cid = conv["id"]
    sid = "webui-" + cid
    session_dir = os.path.join(out_dir, sid)
    updated = conv.get("lastModified") or 0

    meta_path = os.path.join(session_dir, "meta.json")
    journal_path = os.path.join(session_dir, "journal.jsonl")
    # Skip only a session that is up to date AND fully written. journal.jsonl is written LAST
    # (below) and is the file history_store.py reads, so its presence marks a complete session;
    # meta.json alone means a prior run was interrupted mid-write and must be re-done rather than
    # left listing-but-restoring-empty. A session already extended with live continued turns has
    # journal.jsonl and current meta, so it is (correctly) skipped and never clobbered.
    if os.path.exists(meta_path) and os.path.exists(journal_path):
        try:
            old = json.load(open(meta_path, encoding="utf-8"))
            if float(old.get("_lastModified", 0)) >= float(updated):
                return "skipped"  # not newer and complete - idempotent no-op
        except (OSError, ValueError):
            pass

    transcript, stats = build_transcript(conv, entry["messages"])
    os.makedirs(session_dir, exist_ok=True)

    meta = {
        "id": sid,
        "source": "webui-import",
        "title": (conv.get("name") or "").strip() or "(untitled)",
        "created": _iso(updated),
        "updated": _iso(updated),
        "origin": entry["port"],
        "sourceDb": entry["dbName"],
        "_lastModified": updated,
    }
    if stats["model"]:
        meta["model"] = stats["model"]

    # Per-process temp suffix so two import runs racing on the same session (e.g. a background
    # import orphaned by a quit, plus the next launch's fresh run) never write the same .tmp file
    # and corrupt each other - each writes its own tmp and os.replace is atomic per file.
    def atomic(path, obj):
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False)
        os.replace(tmp, path)

    # Order matters: everything EXCEPT journal.jsonl first, then journal.jsonl last, so the
    # skip-guard above (journal.jsonl present) can treat the session as all-or-nothing.
    atomic(meta_path, meta)
    atomic(os.path.join(session_dir, "transcript.json"), transcript)
    atomic(os.path.join(session_dir, "archive.json"),
           {"conv": conv, "messages": entry["messages"]})
    jtmp = "%s.%d.tmp" % (journal_path, os.getpid())
    with open(jtmp, "w", encoding="utf-8") as fh:
        fh.write(_journal_bytes(transcript))
    os.replace(jtmp, journal_path)   # LAST: presence == complete session
    flattened = max(0, stats["total"] - stats["branch"])
    return "imported", flattened


def convert(dumps_dir, out_dir):
    best = _load_dumps(dumps_dir)
    os.makedirs(out_dir, exist_ok=True)
    imported = skipped = flattened_total = failed = 0
    for cid, entry in best.items():
        # Isolate each session: one malformed conversation must not abort the whole import (which
        # would leave the marker unwritten and retry - re-hitting the same bad entry - every
        # launch). Skip it, log it, keep going; a partial write from a raised session is re-done
        # next run by the journal-completeness guard.
        try:
            result = _write_session(out_dir, entry)
        except Exception as exc:  # noqa: BLE001 - best-effort import, never abort the batch
            failed += 1
            sys.stderr.write("skip session %s: %s\n" % (cid, exc))
            continue
        if result == "skipped":
            skipped += 1
        else:
            imported += 1
            flattened_total += result[1]
    return {"conversations": len(best), "imported": imported, "skipped": skipped,
            "failed": failed, "flattened_messages": flattened_total}


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: webui_history_convert.py <dumps_dir> <out_dir>\n")
        return 2
    report = convert(argv[1], argv[2])
    print("conversations: %d  imported: %d  skipped(older/unchanged): %d  "
          "flattened(non-active-branch) messages: %d"
          % (report["conversations"], report["imported"],
             report["skipped"], report["flattened_messages"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
