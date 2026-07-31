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
archive.json. A currNode that does not resolve falls back to the newest leaf rather than
producing an empty session. Conversations are deduped across origins/DBs by id (LlamaUi beats
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


def _branch_from(node, by_id):
    """Root-first chain ending at `node`, following parent links. Cycle-safe."""
    branch = []
    seen = set()
    while node and node in by_id and node not in seen:
        seen.add(node)
        m = by_id[node]
        branch.append(m)
        node = m.get("parent")
    branch.reverse()
    return branch


def _best_leaf_branch(by_id):
    """Best chain to show for a conversation whose currNode cannot be followed.

    Ranked (anchored, newest leaf, longest), and ties broken by message id so the choice is
    stable across runs. "Anchored" - the chain starts at the tree root rather than at a node
    whose parent is missing - comes first on purpose: not every chain in this data is
    root-to-leaf. Both damaged conversations here also carry an ORPHAN fragment (top is a
    tool message pointing at a parent that is not in the conversation at all), and in one of
    them that fragment is the NEWER of the two. Showing it would open the transcript
    mid-thought with a tool result from nowhere, so an anchored chain wins even when it is
    older and the orphan is only used when there is nothing anchored at all. Whatever is not
    on the chosen chain is still in archive.json and is counted as flattened.
    """
    parents = set()
    for m in by_id.values():
        p = m.get("parent")
        if p in by_id:
            parents.add(p)
    best = []
    best_key = None
    for mid in sorted(by_id, key=str):  # key=str: ids are strings, but never assume it
        if mid in parents:
            continue  # not a leaf
        branch = _branch_from(mid, by_id)
        if not branch:
            continue
        top = branch[0]
        anchored = top.get("type") == "root" or not top.get("parent")
        try:
            ts = float(by_id[mid].get("timestamp") or 0)
        except (TypeError, ValueError):
            ts = 0.0
        key = (bool(anchored), ts, len(branch))
        if best_key is None or key > best_key:
            best_key, best = key, branch
    return best


def _active_branch(conv, by_id):
    """(messages on the active branch, root-first; whether currNode had to be recovered).

    currNode is a message id, and it can point at a message that is not in the dump - an
    id left behind by a deleted or never-persisted node. Following it then yields nothing,
    and since journal.jsonl is the only file the history store reads, the session lists but
    restores EMPTY: the conversation looks imported and is not. Two real conversations here
    are in that state, one of them 12 messages long.

    So when currNode does not resolve, fall back to the best leaf instead of giving up. The
    full tree is in archive.json either way; this only decides which branch is shown.
    """
    node = conv.get("currNode")
    if node in by_id:
        return _branch_from(node, by_id), False
    return _best_leaf_branch(by_id), bool(by_id)


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
    branch, recovered = _active_branch(conv, by_id)
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
    return transcript, {"branch": len(branch), "total": len(messages), "model": model,
                        "recovered": recovered}


def _load_dumps(dumps_dir, unreadable=None):
    """conversation id -> winning (conv, messages, port, dbName) across all dumps.

    A dump that will not load is named, not swallowed: the extract side goes to some length
    never to WRITE a bad dump, and a read side that drops one in silence undoes that - the
    run would report "1 conversation" where the other file held forty.
    """
    best = {}
    for path in sorted(glob.glob(os.path.join(dumps_dir, "webui-dump-*.json"))):
        try:
            dump = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError) as exc:
            if unreadable is not None:
                unreadable.append("%s: %s" % (os.path.basename(path), exc))
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


def _size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def _write_session(out_dir, entry):
    conv = entry["conv"]
    cid = conv["id"]
    # The id comes from the user's own IndexedDB rather than the network, so this is
    # robustness rather than a trust boundary - but it lands in a path, and "../.." in it
    # would write the session outside the history root.
    sid = "webui-" + "".join(c if (c.isalnum() and c.isascii()) or c in "-_" else "_"
                             for c in str(cid))
    session_dir = os.path.join(out_dir, sid)
    updated = conv.get("lastModified") or 0

    meta_path = os.path.join(session_dir, "meta.json")
    journal_path = os.path.join(session_dir, "journal.jsonl")
    # Skip only a session that is up to date AND fully written. journal.jsonl is written LAST
    # (below) and is the file history_store.py reads, so a NON-EMPTY one marks a complete
    # session; meta.json alone means a prior run was interrupted mid-write and must be re-done
    # rather than left listing-but-restoring-empty. A session already extended with live
    # continued turns has journal.jsonl and current meta, so it is (correctly) skipped and
    # never clobbered.
    #
    # Size, not existence: a run from before the currNode recovery below wrote a ZERO-BYTE
    # journal for every conversation whose currNode dangled, with a current _lastModified
    # beside it. Testing existence would skip exactly those sessions and the recovery would
    # never reach the ones already on disk - which is the entire point of it. A conversation
    # that genuinely produces no items is simply rewritten each run: idempotent and cheap.
    old = None
    if os.path.exists(meta_path):
        try:
            old = json.load(open(meta_path, encoding="utf-8"))
        except (OSError, ValueError):
            old = None
    if old is not None:
        on_disk = _size(journal_path)
        # Never overwrite a session the user has continued in. Selecting an imported session
        # makes it the live one, and further turns are APPENDED to this journal - so a
        # journal larger than the one this importer wrote is a conversation in progress, and
        # os.replace() below would delete the new turns. Comparing sizes rather than
        # trusting _lastModified matters because that value CAN advance: a retryable extract
        # failure tells the user to go quit AIChat 1.x, which is exactly the act that
        # touches the source and bumps it.
        if on_disk > old.get("_journalBytes", on_disk):
            return {"status": "skipped"}
        if on_disk > 0 and float(old.get("_lastModified", 0)) >= float(updated):
            return {"status": "skipped"}  # not newer and complete - idempotent no-op

    transcript, stats = build_transcript(conv, entry["messages"])
    journal = _journal_bytes(transcript)
    os.makedirs(session_dir, exist_ok=True)

    # A session that legitimately produces no items is rewritten on every run (its journal is
    # zero bytes, so the guard above cannot tell it from one left blank by an old run). That
    # would revert a title the user set with aichat.history.rename.sh, which merges into this
    # same file - so a title we did not write ourselves wins.
    title = (conv.get("name") or "").strip() or "(untitled)"
    if old is not None and old.get("title") and old["title"] != title:
        title = old["title"]

    meta = {
        "id": sid,
        "source": "webui-import",
        "title": title,
        "created": _iso(updated),
        "updated": _iso(updated),
        "origin": entry["port"],
        "sourceDb": entry["dbName"],
        "_lastModified": updated,
        # What we wrote, so a later run can tell "unchanged since the import" from
        # "the user carried on chatting in it".
        "_journalBytes": len(journal.encode("utf-8")),
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
        fh.write(journal)
    os.replace(jtmp, journal_path)   # LAST: presence == complete session
    return {
        "status": "imported",
        "flattened": max(0, stats["total"] - stats["branch"]),
        "recovered": stats["recovered"],
        # A session whose journal is empty although the conversation HAS real messages will
        # list in the sidebar and restore blank - the one outcome indistinguishable from a
        # successful import at a glance. It is still written (archive.json keeps the
        # messages, so it is recoverable), but it must not pass unmentioned.
        #
        # "Real" excludes the structural root node and tool results, which never produce
        # transcript items on their own. Every conversation carries a root, so counting it
        # would flag every "New chat" the user opened and abandoned - noise in the one
        # channel that is supposed to be signal.
        "empty": not journal and any(
            m.get("type") != "root" and m.get("role") != "tool"
            for m in entry["messages"] if isinstance(m, dict)),
    }


def convert(dumps_dir, out_dir):
    unreadable = []
    best = _load_dumps(dumps_dir, unreadable)
    os.makedirs(out_dir, exist_ok=True)
    imported = skipped = flattened_total = failed = 0
    recovered = []
    empty = []
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
        if result["status"] == "skipped":
            skipped += 1
            continue
        imported += 1
        flattened_total += result["flattened"]
        if result["recovered"]:
            recovered.append((cid, result["flattened"]))
        if result["empty"]:
            empty.append(cid)
    for cid, left_off in recovered:
        sys.stderr.write("recovered session %s: currNode did not resolve, imported the best "
                         "surviving branch instead (%d message(s) left off it, still in "
                         "archive.json)\n" % (cid, left_off))
    for cid in empty:
        sys.stderr.write("EMPTY session %s: it has messages but no transcript items - it "
                         "will list and restore blank (archive.json still holds them)\n" % cid)
    for line in unreadable:
        sys.stderr.write("UNREADABLE dump %s - whatever it held was not imported\n" % line)
    return {"conversations": len(best), "imported": imported, "skipped": skipped,
            "failed": failed, "flattened_messages": flattened_total,
            "recovered": len(recovered), "empty": len(empty),
            "unreadable": len(unreadable)}


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: webui_history_convert.py <dumps_dir> <out_dir>\n")
        return 2
    report = convert(argv[1], argv[2])
    # `failed` belongs here: a failed conversation is dropped ENTIRELY, so leaving it to a
    # per-session stderr line is exactly the silent shortfall this is all trying to avoid.
    print("conversations: %d  imported: %d  skipped(older/unchanged): %d  failed: %d  "
          "unreadable dumps: %d  flattened(non-active-branch) messages: %d  recovered: %d  "
          "empty: %d"
          % (report["conversations"], report["imported"], report["skipped"],
             report["failed"], report["unreadable"], report["flattened_messages"],
             report["recovered"], report["empty"]))
    # Nothing at all got through, and it was not for lack of trying: an unwritable or full
    # history root fails every session identically. Exit 0 here and app.did.launch.sh writes
    # its terminal marker having imported NOTHING, retiring the offer for good.
    if report["conversations"] and report["imported"] == 0 and not report["skipped"]:
        sys.stderr.write("error: %d conversation(s) to import and not one succeeded - "
                         "not reporting success\n" % report["conversations"])
        return 1
    # Otherwise deliberately 0, even when individual sessions failed, were recovered, or came
    # out empty: the caller treats a non-zero convert as "retry next launch", and re-running
    # forever over one conversation that is simply shaped that way would never terminate.
    # The counts and the per-session lines above are the report; the log keeps them.
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
