#!/usr/bin/env python3
"""webui_history_extract.py - Route B (offline) extraction of llama.cpp WebUI chat history.

Enumerates the WebKit IndexedDB origins that AIChat.app (v1) wrote (each localhost:<port> is
a distinct origin, so history is fragmented across ports), decodes each origin's
`conversations` + `messages` object stores via webkit_ssv, and writes one dump per
(app, port, database) into a staging dir:

    webui-dump-<app>-<port>-<dbname>.json = {port, dbName, conversations:[...], messages:[...]}

This is the app-closed escape hatch; the in-app dump page (Route A) produces the same JSON
shape and the same converter (webui_history_convert.py) consumes it. Read-only w.r.t. the
source: each sqlite file (+ its -wal/-shm) is copied to a temp dir and checkpointed there,
never touched in place. No third-party deps; runs under the bundle's embedded python3.

Usage:
    webui_history_extract.py <staging_dir> [--webkit-root <dir>]
    webui_history_extract.py --help
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

# How many times to re-copy a database whose source moved under us before giving up.
COPY_ATTEMPTS = 3


class ExtractError(Exception):
    """A source database could not be copied or read consistently."""


def _sanitize(text):
    # isalnum() alone is Unicode-aware, which would put non-ASCII straight into a filename.
    return "".join(c if (c.isalnum() and c.isascii()) else "_" for c in text)


def app_slug(webkit_root):
    """A short discriminator for the app whose WebsiteData we are reading.

    Dumps used to be named webui-dump-<port>-<db>.json, and that tuple is NOT unique across
    apps: AIChat and Enoch both have localhost:8086 and localhost:8089 IndexedDB databases
    named LlamacppWebui. Extracting both into one staging dir - the natural thing to do,
    since the converter globs a single directory - silently overwrote one app's dumps with
    the other's and still printed success and exited 0.
    """
    root = os.path.abspath(os.path.expanduser(webkit_root))
    parts = [p for p in root.split(os.sep) if p]
    name = ""
    # ~/Library/WebKit/<bundle-id>/WebsiteData/Default -> <bundle-id>. Scan from the right so
    # a root that happens to sit under another WebKit/ dir still resolves to the nearest id.
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == "WebsiteData" and i > 0:
            name = parts[i - 1]
            break
        if parts[i] == "WebKit" and i + 1 < len(parts):
            name = parts[i + 1]
            break
    if not name:
        name = parts[-1] if parts else "unknown"
    # com.abracode.AIChat -> AIChat, so the filenames stay readable. Two apps whose bundle ids
    # end in the same word would still collide, which is why the writer opens with "x".
    bits = name.split(".")
    if len(bits) >= 3 and bits[-1]:
        name = bits[-1]
    return _sanitize(name) or "unknown"


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


def _stat_key(path):
    """(size, mtime_ns, inode) for a file, or None if it does not exist."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_size, st.st_mtime_ns, st.st_ino)


def _copy_snapshot(sqlite_path, base):
    """Copy a sqlite db and its -wal to `base`, proving neither moved during the copy.

    Most of the history can live in the -wal (one real origin here: a 172 KB db beside a
    2.2 MB wal), and a -wal captured mid-append is TORN: sqlite silently ignores the
    trailing partial frames, so extraction reports success while dropping the newest
    conversations. Measured on that origin - intact 30 messages, wal truncated to half
    22, wal missing 13 - with no error in any case. So stat the pair before and after and
    refuse a copy that raced a writer.

    The -shm is deliberately NOT copied: it is derived state (a cache of the wal index) that
    sqlite rebuilds from the wal, so copying it buys nothing and adds a third unsynchronised
    read that the stat guard below does not cover.

    Mixing snapshots is the dangerous case, and sqlite gives no protection against it: a
    database from one moment beside a -wal from an earlier one checkpoints happily and rolls
    the data BACKWARDS, because the main file records no wal identity to check. Hence the
    removes at the top of every attempt, and the assertion that they worked.

    Returns the size of the captured -wal, for reporting.
    """
    wal_path = sqlite_path + "-wal"
    last_error = None
    for _ in range(COPY_ATTEMPTS):
        before = (_stat_key(sqlite_path), _stat_key(wal_path))
        if before[0] is None:
            raise ExtractError("%s disappeared while being read" % sqlite_path)
        for suffix in ("", "-wal"):
            try:
                os.remove(base + suffix)
            except OSError:
                pass
        if _stat_key(base + "-wal") is not None:
            raise ExtractError("could not clear %s-wal from the previous attempt; a stale "
                               "WAL beside a fresh database would silently roll it back"
                               % base)
        shutil.copy2(sqlite_path, base)
        if before[1] is not None:
            try:
                shutil.copy2(wal_path, base + "-wal")
            except OSError as exc:
                # Usually the writer checkpointing the wal away mid-copy, in which case the
                # next attempt succeeds. Keep the reason: if it is really EACCES/EIO, all
                # three attempts fail and "kept changing" would send the user hunting the
                # wrong problem.
                last_error = exc
                continue
        if (_stat_key(sqlite_path), _stat_key(wal_path)) == before:
            return before[1][0] if before[1] else 0
    raise ExtractError(
        "%s could not be copied consistently after %d attempts%s - quit the app that owns "
        "it and retry" % (sqlite_path, COPY_ATTEMPTS,
                          " (%s)" % last_error if last_error else
                          "; it kept changing underneath"))


# A WAL file that is only a header carries no frames, so contributing nothing is correct.
WAL_HEADER_BYTES = 32


def _checkpoint_copy(base, wal_bytes):
    """Fold the copied -wal into the copied db. Returns a warning string, or None.

    Finding out whether that actually happened is harder than it looks, and two obvious
    checks are both worthless:

      - the pragma's return row reports (0, 0, 0) whether the wal held everything or
        nothing; and
      - the -wal file is always gone by the time we could stat it, because sqlite
        checkpoints and DELETES it when the last connection closes. A "the wal is drained,
        so the frames must be in the database" assertion therefore passes just as happily
        when the wal was ignored in its entirety. Measured over intact / truncated /
        salt-clobbered / magic-clobbered / header-only WALs: that check saw None in all
        five, including the four that recovered zero rows.

    What does discriminate is the main database file. If frames were applied it was written
    to; if the wal was unreadable it was not touched at all. Same five cases: changed only
    for the intact one.

    This reports rather than raises. A wal that will never be readable is a permanent
    condition, and app.did.launch.sh retries a failed extract on every launch - so failing
    here would loop forever and cost the user the history that IS in the main database. It
    is also not certain loss: a wal holding only an unfinished transaction legitimately
    contributes nothing.
    """
    db_before = _stat_key(base)
    cp = sqlite3.connect(base)
    try:
        cp.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()
    except sqlite3.Error as exc:
        raise ExtractError("could not checkpoint the copied WAL: %s" % exc)
    finally:
        cp.close()
    if wal_bytes > WAL_HEADER_BYTES and _stat_key(base) == db_before:
        return ("its %d-byte WAL contributed nothing to the database - the WAL is "
                "unreadable, or holds only an unfinished transaction. Anything that was "
                "only in it is NOT in this dump" % wal_bytes)
    return None


def extract_database(sqlite_path, port):
    """Copy a DB safely, checkpoint its WAL, decode conversations + messages.

    Returns a dump dict {port, dbName, conversations, messages} or None if it has neither
    of the expected object stores. Raises ExtractError if the source could not be captured
    consistently - silently returning less history than exists is the failure to avoid.
    """
    tmp = tempfile.mkdtemp(prefix="webui-idb-")
    try:
        base = os.path.join(tmp, "db.sqlite3")
        wal_bytes = _copy_snapshot(sqlite_path, base)
        wal_warning = _checkpoint_copy(base, wal_bytes)

        conn = sqlite3.connect("file:%s?mode=ro" % base, uri=True)
        try:
            stores = {name: sid for sid, name in
                      conn.execute("SELECT id, name FROM ObjectStoreInfo")}
            if "conversations" not in stores and "messages" not in stores:
                return None
            dbname = _database_name(conn) or "unknown"
            if wal_warning:
                sys.stderr.write("warning: %s: %s\n" % (dbname, wal_warning))
            conversations, cskip = _decode_store(conn, stores.get("conversations"))
            messages, mskip = _decode_store(conn, stores.get("messages"))
            return {
                "port": port,
                "dbName": dbname,
                "conversations": conversations,
                "messages": messages,
                "_skipped": {"conversations": cskip, "messages": mskip},
                "_walBytes": wal_bytes,
            }
        finally:
            conn.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _discard(paths):
    for p in paths:
        try:
            os.unlink(p)
        except OSError:
            pass


def extract_all(webkit_root, staging_dir):
    # Look before creating: a run that finds nothing should leave no trace, rather than
    # leaving an empty directory behind wherever it was invoked from.
    origins = find_origins(webkit_root)
    if not origins:
        sys.stderr.write("no WebUI origins found under %s\n" % webkit_root)
        return []
    slug = app_slug(webkit_root)
    os.makedirs(staging_dir, exist_ok=True)
    dumps = []
    for port, idb in origins:
        for entry in sorted(os.listdir(idb)):
            db_path = os.path.join(idb, entry, "IndexedDB.sqlite3")
            if not os.path.exists(db_path):
                continue
            dump = extract_database(db_path, port)
            if dump is None:
                continue
            out_name = "webui-dump-%s-%d-%s.json" % (slug, port, _sanitize(dump["dbName"]))
            out_path = os.path.join(staging_dir, out_name)
            # "x", never "w": a name that is already taken means an earlier dump is about to
            # be destroyed, and losing history to a filename collision must be loud.
            try:
                fh = open(out_path, "x", encoding="utf-8")
            except FileExistsError:
                # Leave the staging dir as we found it. Half this run's dumps sitting beside
                # a previous run's is a mix nobody can reason about, and the converter would
                # happily read the pair.
                _discard(dumps)
                raise ExtractError(
                    "%s already exists - refusing to overwrite a previous dump. Extract "
                    "each app into its own empty staging dir, or remove the old dumps "
                    "first." % out_path) from None
            try:
                with fh:
                    json.dump(dump, fh, ensure_ascii=False)
            except BaseException:
                # json.dump writes incrementally, so anything from ENOSPC to a SIGINT leaves
                # a truncated file - and a truncated dump is INVISIBLE downstream: the
                # converter catches ValueError per file and moves on, reporting 0
                # conversations and exit 0. Never leave a corpse that reads as a dump.
                _discard([out_path])   # swallows its own errors: never mask the real one
                raise
            skipped = dump.get("_skipped", {})
            print("port %d  %-14s  %3d conversations  %4d messages  "
                  "(skipped c=%d m=%d, wal %d bytes)  -> %s"
                  % (port, dump["dbName"], len(dump["conversations"]),
                     len(dump["messages"]), skipped.get("conversations", 0),
                     skipped.get("messages", 0), dump.get("_walBytes", 0), out_name))
            dumps.append(out_path)
    return dumps


USAGE = """usage: webui_history_extract.py <staging_dir> [--webkit-root <dir>]

Extracts llama.cpp WebUI chat history from WebKit IndexedDB into <staging_dir>,
one webui-dump-<app>-<port>-<dbname>.json per (app, port, database).

Quit the app that owns the source data first: this refuses to read a database
that is being written to rather than capture a torn snapshot of it.

  <staging_dir>          directory to write the dumps into (created if needed)
  --webkit-root <dir>    WebKit WebsiteData dir to read
                         (default: %s)
  -h, --help             show this message
""" % DEFAULT_WEBKIT_ROOT


def main(argv):
    # Hand-rolled rather than argparse so the failure modes stay explicit. The first
    # positional is a directory this script CREATES, so anything that looks like a flag
    # must be rejected outright: `webui_history_extract.py --help` used to be read as
    # "extract into a directory named --help", which silently created one and filled it
    # with a full history dump in whatever the caller's working directory happened to be.
    staging_dir = None
    webkit_root = DEFAULT_WEBKIT_ROOT
    rest = argv[1:]
    i = 0
    while i < len(rest):
        arg = rest[i]
        if arg in ("-h", "--help"):
            sys.stdout.write(USAGE)
            return 0
        if arg == "--webkit-root":
            # Must have a value, and the value must not itself be a flag - otherwise
            # `--webkit-root --help` would silently read history from a dir named --help.
            if i + 1 >= len(rest) or rest[i + 1].startswith("-"):
                sys.stderr.write("error: --webkit-root needs a directory argument\n\n")
                sys.stderr.write(USAGE)
                return 2
            webkit_root = rest[i + 1]
            i += 2
            continue
        if arg.startswith("-"):
            hint = ""
            if arg.split("=", 1)[0] == "--webkit-root" and "=" in arg:
                hint = " (write it as two arguments: %s %s)" % tuple(arg.split("=", 1))
            sys.stderr.write("error: unknown option %r%s\n\n" % (arg, hint))
            sys.stderr.write(USAGE)
            return 2
        if staging_dir is not None:
            sys.stderr.write("error: unexpected extra argument %r\n\n" % arg)
            sys.stderr.write(USAGE)
            return 2
        staging_dir = arg
        i += 1

    if staging_dir is None:
        sys.stderr.write("error: no staging directory given\n\n")
        sys.stderr.write(USAGE)
        return 2
    if not staging_dir:
        # os.makedirs("") raises FileNotFoundError, which is a traceback rather than an answer.
        sys.stderr.write("error: the staging directory cannot be an empty path\n\n")
        sys.stderr.write(USAGE)
        return 2
    if os.path.exists(staging_dir) and not os.path.isdir(staging_dir):
        sys.stderr.write("error: %s exists and is not a directory\n" % staging_dir)
        return 2
    if not os.path.isdir(webkit_root):
        # Worth its own error: without it a typo'd --webkit-root just reports zero
        # origins and exits 0, which reads like "no history" rather than "wrong path".
        sys.stderr.write("error: --webkit-root is not a directory: %s\n" % webkit_root)
        return 2

    try:
        dumps = extract_all(webkit_root, staging_dir)
    except ExtractError as exc:
        sys.stderr.write("error: %s\n" % exc)
        return 1
    print("wrote %d dump file(s) to %s" % (len(dumps), staging_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
