#!/usr/bin/env python3
"""webui_history_extract.py - Route B (offline) extraction of llama.cpp WebUI chat history.

Enumerates the WebKit IndexedDB origins that AIChat.app (v1) wrote (each localhost:<port> is
a distinct origin, so history is fragmented across ports), decodes each origin's
`conversations` + `messages` object stores via webkit_ssv, and writes one dump per
(port, database) into a staging dir:

    webui-dump-<port>-<dbname>.json  =  {port, dbName, conversations:[...], messages:[...]}

This is the app-closed escape hatch; the in-app dump page (Route A) produces the same JSON
shape and the same converter (webui_history_convert.py) consumes it. Read-only w.r.t. the
source: each sqlite file (+ its -wal/-shm) is copied to a temp dir and checkpointed there,
never touched in place. No third-party deps; runs under the bundle's embedded python3.

Usage:
    webui_history_extract.py <staging_dir> [--webkit-root <dir>]
"""
import json
import os
import shutil
import sqlite3
import struct
import sys
import tempfile

import webkit_ssv

DEFAULT_WEBKIT_ROOT = os.path.expanduser(
    "~/Library/WebKit/com.abracode.AIChat/WebsiteData/Default")


def decode_origin_port(origin_path):
    """Port from a WebKit origin file: ...'localhost' 0x01 <uint16 LE port>."""
    try:
        with open(origin_path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    marker = b"localhost"
    pos = data.find(marker)
    if pos < 0:
        return None
    pos += len(marker)
    if pos + 3 > len(data) or data[pos] != 1:
        return None
    return struct.unpack_from("<H", data, pos + 1)[0]


def find_origins(webkit_root):
    """List (port, indexeddb_dir) for each localhost origin that has an IndexedDB dir."""
    out = []
    if not os.path.isdir(webkit_root):
        return out
    for name in sorted(os.listdir(webkit_root)):
        odir = os.path.join(webkit_root, name, name)
        idb = os.path.join(odir, "IndexedDB")
        origin_file = os.path.join(odir, "origin")
        if not os.path.isdir(idb) or not os.path.exists(origin_file):
            continue
        port = decode_origin_port(origin_file)
        if port is not None:
            out.append((port, idb))
    return out


def _database_name(conn):
    """The IndexedDB database name (e.g. LlamaUi / LlamacppWebui) from IDBDatabaseInfo."""
    try:
        cur = conn.execute("SELECT value FROM IDBDatabaseInfo WHERE key='DatabaseName'")
        row = cur.fetchone()
    except sqlite3.Error:
        return None
    if not row or row[0] is None:
        return None
    v = row[0]
    if isinstance(v, bytes):
        # WebKit stores it UTF-16LE; fall back to utf-8 then latin-1.
        for enc in ("utf-16-le", "utf-8", "latin-1"):
            try:
                s = v.decode(enc)
                s = s.replace("\x00", "").strip()
                if s:
                    return s
            except (UnicodeDecodeError, ValueError):
                continue
        return None
    return str(v).strip() or None


def _decode_store(conn, store_id):
    rows = []
    skipped = 0
    for (val,) in conn.execute(
            "SELECT value FROM Records WHERE objectStoreID=?", (store_id,)):
        try:
            obj = webkit_ssv.deserialize(val)
        except webkit_ssv.SSVError:
            skipped += 1
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows, skipped


def extract_database(sqlite_path, port):
    """Copy a DB safely, checkpoint its WAL, decode conversations + messages.

    Returns a dump dict {port, dbName, conversations, messages} or None if it has neither
    of the expected object stores.
    """
    tmp = tempfile.mkdtemp(prefix="webui-idb-")
    try:
        base = os.path.join(tmp, "db.sqlite3")
        shutil.copy2(sqlite_path, base)
        for suffix in ("-wal", "-shm"):
            src = sqlite_path + suffix
            if os.path.exists(src):
                shutil.copy2(src, base + suffix)
        # Checkpoint so a read sees WAL-only data, then read.
        cp = sqlite3.connect(base)
        try:
            cp.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        except sqlite3.Error:
            pass
        cp.close()

        conn = sqlite3.connect("file:%s?mode=ro" % base, uri=True)
        try:
            stores = {name: sid for sid, name in
                      conn.execute("SELECT id, name FROM ObjectStoreInfo")}
            if "conversations" not in stores and "messages" not in stores:
                return None
            dbname = _database_name(conn) or "unknown"
            conversations, cskip = _decode_store(conn, stores.get("conversations"))
            messages, mskip = _decode_store(conn, stores.get("messages"))
            return {
                "port": port,
                "dbName": dbname,
                "conversations": conversations,
                "messages": messages,
                "_skipped": {"conversations": cskip, "messages": mskip},
            }
        finally:
            conn.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def extract_all(webkit_root, staging_dir):
    os.makedirs(staging_dir, exist_ok=True)
    origins = find_origins(webkit_root)
    if not origins:
        sys.stderr.write("no WebUI origins found under %s\n" % webkit_root)
        return []
    dumps = []
    for port, idb in origins:
        for entry in sorted(os.listdir(idb)):
            db_path = os.path.join(idb, entry, "IndexedDB.sqlite3")
            if not os.path.exists(db_path):
                continue
            dump = extract_database(db_path, port)
            if dump is None:
                continue
            safe_db = "".join(c if c.isalnum() else "_" for c in dump["dbName"])
            out_path = os.path.join(staging_dir,
                                    "webui-dump-%d-%s.json" % (port, safe_db))
            with open(out_path, "w", encoding="utf-8") as fh:
                json.dump(dump, fh, ensure_ascii=False)
            skipped = dump.get("_skipped", {})
            print("port %d  %-14s  %3d conversations  %4d messages  (skipped c=%d m=%d)  -> %s"
                  % (port, dump["dbName"], len(dump["conversations"]),
                     len(dump["messages"]), skipped.get("conversations", 0),
                     skipped.get("messages", 0), os.path.basename(out_path)))
            dumps.append(out_path)
    return dumps


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(
            "usage: webui_history_extract.py <staging_dir> [--webkit-root <dir>]\n")
        return 2
    staging_dir = argv[1]
    webkit_root = DEFAULT_WEBKIT_ROOT
    if "--webkit-root" in argv:
        webkit_root = argv[argv.index("--webkit-root") + 1]
    dumps = extract_all(webkit_root, staging_dir)
    print("wrote %d dump file(s) to %s" % (len(dumps), staging_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
