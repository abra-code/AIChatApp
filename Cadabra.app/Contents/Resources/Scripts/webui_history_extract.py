#!/usr/bin/env python3
"""webui_history_extract.py - Route B (offline) extraction of llama.cpp WebUI chat history.

Enumerates the WebKit IndexedDB origins that AIChat.app (v1) wrote (each localhost:<port> is
a distinct origin, so history is fragmented across ports), decodes each origin's
`conversations` + `messages` object stores via webkit_ssv, and writes one dump per
(app, origin, database) into a staging dir:

    webui-dump-<app>-<host>-<port>-<dbname>.json  =  {port, host, dbName,
                                                      conversations:[...], messages:[...]}

This is the app-closed escape hatch; the in-app dump page (Route A) produces the same JSON
shape and the same converter (webui_history_convert.py) consumes it. Read-only w.r.t. the
source: each sqlite file (+ its -wal/-shm) is copied to a temp dir and checkpointed there,
never touched in place. No third-party deps; runs under the bundle's embedded python3.

Usage:
    webui_history_extract.py <staging_dir> [--bundle-id <id> | --webkit-root <dir>]
    webui_history_extract.py --help

--bundle-id points it at another app's WebKit data (Enoch.app is the next one to migrate);
the dumps are named and tagged after that app so several apps can be staged side by side.
"""
import errno
import json
import os
import shutil
import sqlite3
import struct
import sys
import tempfile

import webkit_ssv

DEFAULT_BUNDLE_ID = "com.abracode.AIChat"


def webkit_root_for(bundle_id):
    return os.path.expanduser("~/Library/WebKit/%s/WebsiteData/Default" % bundle_id)


DEFAULT_WEBKIT_ROOT = webkit_root_for(DEFAULT_BUNDLE_ID)

# How many times to re-copy a database whose source moved under us before giving up.
COPY_ATTEMPTS = 3


# Errors a later run cannot get past: the problem is the data or the path, not the moment.
PERMANENT_ERRNOS = frozenset([errno.EACCES, errno.EPERM, errno.ENAMETOOLONG, errno.ENOTDIR,
                              errno.EISDIR, errno.ELOOP, errno.EROFS])


def _is_transient(exc):
    """Would running this again, later, plausibly work?

    Classified by what the error IS rather than by where it was raised: the same call can
    fail because the disk is full (try again tomorrow) or because the file is not a database
    (never). Getting this wrong in either direction loses history - see ExtractError.
    """
    if isinstance(exc, sqlite3.OperationalError):
        return True    # disk or database is full, database is locked, cannot open
    if isinstance(exc, sqlite3.Error):
        return False   # file is not a database, disk image is malformed
    return getattr(exc, "errno", None) not in PERMANENT_ERRNOS


class ExtractError(Exception):
    """A source database could not be copied or read consistently.

    `retryable` separates the failures a later run could get past - a source that was being
    written to, a transient I/O error - from permanent ones like a corrupt database. Only
    the first kind should fail the run, because app.did.launch.sh reads a non-zero exit as
    "retry on the next launch": failing on a permanent condition loops forever, and not
    failing on a transient one lets the launch script write its terminal marker and retire
    the import while a database was left unread.
    """

    def __init__(self, message, retryable=False):
        Exception.__init__(self, message)
        self.retryable = retryable


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


# Loopback hosts a local llama-server can be reached on. The WebUI is always served from one
# of these; anything else is a real web site whose IndexedDB is not ours to import.
LOOPBACK_HOSTS = ("localhost", "::1", "0.0.0.0")
DEFAULT_PORTS = {"http": 80, "https": 443, "ws": 80, "wss": 443}


def _is_loopback(host):
    h = (host or "").lower().strip("[]")
    if h in LOOPBACK_HOSTS:
        return True
    # 127.0.0.0/8, parsed as an address rather than matched as a prefix - "127.0.0.1.evil.com"
    # starts with "127." and is a perfectly ordinary domain name. isascii() before isdigit()
    # because isdigit() is Unicode-aware and int() is not: "\xb2".isdigit() is True and
    # int("\xb2") raises, and \xb2 is an ordinary latin-1 byte in a damaged origin file.
    octets = h.split(".")
    return (len(octets) == 4 and octets[0] == "127"
            and all(o.isascii() and o.isdigit() and len(o) <= 3 and int(o) < 256
                    for o in octets))


def _read_wtf_string(data, pos):
    """(text, next_pos) for a WebKit-serialized string, or (None, pos).

    Layout is <uint32 LE length><0x01 = latin-1 | 0x00 = utf-16le><characters>.
    """
    if pos + 5 > len(data):
        return None, pos
    (length,) = struct.unpack_from("<I", data, pos)
    is_8bit = data[pos + 4]
    pos += 5
    if is_8bit == 1:
        end = pos + length
        enc = "latin-1"
    elif is_8bit == 0:
        end = pos + length * 2
        enc = "utf-16-le"
    else:
        return None, pos
    if end > len(data) or length > len(data):
        return None, pos
    return data[pos:end].decode(enc, "replace"), end


def decode_origin(origin_path):
    """(scheme, host, port) from a WebKit origin file, or None if it does not parse.

    The record is written TWICE (topOrigin then clientOrigin, identical for first-party
    data); only the first is read.

    The file is structured - <scheme><host><0x01><uint16 LE port> - so parse it instead of
    searching for the bytes "localhost", which is what this used to do. That search meant an
    origin recorded as 127.0.0.1 or [::1] simply did not exist as far as the extractor was
    concerned, and its entire history was skipped without a word.
    """
    try:
        with open(origin_path, "rb") as fh:
            data = fh.read(4096)
    except OSError:
        return None
    scheme, pos = _read_wtf_string(data, 0)
    if scheme is None:
        return None
    host, pos = _read_wtf_string(data, pos)
    if host is None or pos >= len(data):
        return None
    flag = data[pos]
    if flag == 1:  # port present
        if pos + 3 > len(data):
            return None
        return scheme, host, struct.unpack_from("<H", data, pos + 1)[0]
    if flag == 0:  # no explicit port - the scheme's default applies
        return scheme, host, DEFAULT_PORTS.get(scheme.lower(), 0)
    return None


def find_origins(webkit_root, report):
    """List (host, port, indexeddb_dir) for each loopback origin that has an IndexedDB dir.

    Every directory that holds an IndexedDB but is passed over is recorded, so "no history
    found" can never be confused with "did not recognize what was there". A remote origin is
    understood and correctly ignored; an origin file we could not parse is not, and only the
    second kind says anything about whether history was missed.
    """
    out = []
    if not os.path.isdir(webkit_root):
        return out
    for name in sorted(os.listdir(webkit_root)):
        odir = os.path.join(webkit_root, name, name)
        idb = os.path.join(odir, "IndexedDB")
        origin_file = os.path.join(odir, "origin")
        if not os.path.isdir(idb):
            continue
        if not os.path.exists(origin_file):
            report.suspect("origin dir %s has an IndexedDB but no origin file - skipped"
                           % name)
            continue
        origin = decode_origin(origin_file)
        if origin is None:
            report.suspect("could not parse the origin file of %s - skipped" % name)
            continue
        scheme, host, port = origin
        if not _is_loopback(host):
            # A plausible hostname that simply is not ours is understood and harmless. One
            # with bytes that cannot be in a hostname means the origin file is damaged, and
            # we have no idea whose IndexedDB this is.
            line = "skipping non-local origin %s://%s:%d" % (scheme, host, port)
            if all(c.isascii() and (c.isalnum() or c in "-._:[]") for c in host) and host:
                report.info(line)
            else:
                report.suspect(line + " - the host does not look like a hostname, so the "
                                      "origin file may be damaged")
            continue
        out.append((host, port, idb))
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
    """(decoded records, number of records that could not be used).

    Every record that does not end up in `rows` is counted. Two ways that used to go
    unnoticed: a record that decoded to something other than a dict was dropped without
    touching the counter, and a decoder bug that raised anything other than SSVError - a
    lone surrogate in the text is enough - propagated and killed the entire run, writing no
    dumps at all. One unreadable record is a record; it is not the whole history.
    """
    rows = []
    skipped = 0
    if store_id is None:
        return rows, skipped
    for (val,) in conn.execute(
            "SELECT value FROM Records WHERE objectStoreID=?", (store_id,)):
        try:
            obj = webkit_ssv.deserialize(val)
        except Exception:  # noqa: BLE001 - deliberately broad; see the docstring
            skipped += 1
            continue
        if isinstance(obj, dict):
            rows.append(obj)
        else:
            skipped += 1
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
            raise ExtractError("%s disappeared while being read" % sqlite_path,
                               retryable=True)
        for suffix in ("", "-wal"):
            try:
                os.remove(base + suffix)
            except OSError:
                pass
        if _stat_key(base + "-wal") is not None:
            raise ExtractError("could not clear %s-wal from the previous attempt; a stale "
                               "WAL beside a fresh database would silently roll it back"
                               % base, retryable=True)
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
                          "; it kept changing underneath"),
        retryable=_is_transient(last_error) if last_error else True)


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
        salt-clobbered / magic-clobbered / header-only WALs: the drained check saw None in
        all five, including the four that recovered zero rows.

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
        raise ExtractError("could not checkpoint the copied WAL: %s" % exc,
                           retryable=_is_transient(exc))
    finally:
        cp.close()
    if wal_bytes > WAL_HEADER_BYTES and _stat_key(base) == db_before:
        return ("its %d-byte WAL contributed nothing to the database - the WAL is "
                "unreadable, or holds only an unfinished transaction. Anything that was "
                "only in it is NOT in this dump" % wal_bytes)
    return None


def extract_database(sqlite_path, port, report=None):
    """Copy a DB safely, checkpoint its WAL, decode conversations + messages.

    Returns a dump dict {port, dbName, conversations, messages} or None if it has neither
    of the expected object stores. Raises ExtractError if the source could not be captured
    consistently - silently returning less history than exists is the failure to avoid. The
    caller decides what that costs: ExtractError.retryable says whether a later run could
    get past it.
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
            dbname = _database_name(conn) or "unknown"
            if wal_warning and report:
                report.suspect("%s: %s" % (dbname, wal_warning))
            have = [s for s in ("conversations", "messages") if s in stores]
            if not have:
                # Not necessarily a problem - a WebKit profile can hold unrelated IndexedDB
                # databases - but if the WebUI ever renames its stores this is the line that
                # turns "0 conversations" into something a human can act on.
                if report:
                    report.info("%s: no conversations/messages stores (has: %s) - skipped"
                         % (dbname, ", ".join(sorted(stores)) or "nothing"))
                return None
            if len(have) == 1 and report:
                missing = "messages" if have[0] == "conversations" else "conversations"
                report.suspect("%s: has a %s store but no %s store - the dump is half a "
                               "history" % (dbname, have[0], missing))
            conversations, cskip = _decode_store(conn, stores.get("conversations"))
            messages, mskip = _decode_store(conn, stores.get("messages"))
            if report and (cskip or mskip):
                report.suspect("%s: %d conversation and %d message records could not be decoded and "
                     "are NOT in the dump" % (dbname, cskip, mskip))
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


class Report(object):
    """Problems found during a run, split by what the caller should DO about them.

    All three are printed identically; they differ only in their effect on the exit status,
    and that distinction is the whole point. app.did.launch.sh reads a non-zero exit as
    "retry on the next launch" and a zero exit as "imported - write the terminal marker and
    never ask again", so classifying wrongly in either direction loses history:

      info      understood, and nothing was lost by skipping it (a remote origin, a
                database that is not ours). Permanent and harmless - it must never fail, or
                the pipeline re-runs on every launch forever on a Mac that has no v1
                history.
      retry     might succeed later (the source was being written to, a transient I/O
                error). Must fail, or the marker is written while a database went unread.
      suspect   history may have been missed HERE: an origin we could not parse, a database
                we could not read, records that would not decode, a WAL that contributed
                nothing. Permanent, so it cannot simply fail - but if the run came away with
                no records at all, every one of these is a candidate for where the history
                went, and reporting success would retire the import on that basis.

    `records` is what makes the last one work: the question is not "did we write a dump
    file" - a dump whose arrays are both empty is a file - but "did we recover anything".
    """

    def __init__(self):
        self.lines = []
        self.retry = []
        self.suspect_lines = []
        self.records = 0

    def info(self, line):
        self.lines.append(line)

    def retryable(self, line):
        self.lines.append(line)
        self.retry.append(line)

    def suspect(self, line):
        self.lines.append(line)
        self.suspect_lines.append(line)


def extract_all(webkit_root, staging_dir):
    """Write one dump per (app, origin, database). Returns (dump paths, Report)."""
    report = Report()
    # Look before creating: a run that finds nothing should leave no trace, rather than
    # leaving an empty directory behind wherever it was invoked from.
    origins = find_origins(webkit_root, report)
    if not origins:
        sys.stderr.write("no WebUI origins found under %s\n" % webkit_root)
        return [], report
    slug = app_slug(webkit_root)
    os.makedirs(staging_dir, exist_ok=True)
    dumps = []
    used = set()
    for host, port, idb in origins:
        try:
            entries = sorted(os.listdir(idb))
        except OSError as exc:
            line = "could not list %s: %s" % (idb, exc)
            (report.retryable if _is_transient(exc) else report.suspect)(line)
            continue
        for entry in entries:
            db_path = os.path.join(idb, entry, "IndexedDB.sqlite3")
            if not os.path.exists(db_path):
                continue
            # One unreadable database must not cost the user the other four. Anything that
            # goes wrong here is recorded and the enumeration carries on; the run reports
            # the failures at the end rather than dying on the first one - but a failure
            # that a later run could get past still has to fail this one, or the launch
            # script writes its terminal marker while a database went unread.
            try:
                dump = extract_database(db_path, port, report)
            # Never `info`: a database we could not read is a database whose history we
            # cannot account for. Either it is worth retrying, or it is a candidate for
            # where the history went if the run ends up finding none.
            except ExtractError as exc:
                where = "%s (%s:%d): %s" % (entry, host, port, exc)
                (report.retryable if exc.retryable else report.suspect)(where)
                continue
            except (sqlite3.Error, OSError) as exc:
                where = "%s (%s:%d): %s" % (entry, host, port, exc)
                (report.retryable if _is_transient(exc) else report.suspect)(where)
                continue
            if dump is None:
                continue
            dump["app"] = slug
            dump["host"] = host
            # The host belongs in the name: localhost:8080 and 127.0.0.1:8080 are DIFFERENT
            # origins with the same port, and both are found now that the origin file is
            # parsed properly. Even so the name is not provably unique - two databases whose
            # IDBDatabaseInfo is unreadable both fall back to "unknown" - so keep a fallback
            # rather than failing an import over a clash that can simply be resolved. The
            # per-database directory name does NOT disambiguate: WebKit derives it from a
            # hash of the database name, so the same database has the same directory name in
            # every origin.
            base = "webui-dump-%s-%s-%d-%s" % (slug, _sanitize(host), port,
                                               _sanitize(dump["dbName"]))
            # Reserve case-INSENSITIVELY. IndexedDB names are case-sensitive, so one origin
            # may hold both "LlamaUi" and "llamaui", but this filesystem is not: a set keyed
            # on the exact name would see no clash, and open(..., "x") would then fail, throw
            # away the dumps already written and abort a run that had nothing wrong with it.
            if base.lower() in used:
                n = 2
                while ("%s-%d" % (base, n)).lower() in used:
                    n += 1
                report.info("two databases at %s:%d both call themselves %r; writing the "
                            "second as %s-%d.json" % (host, port, dump["dbName"], base, n))
                base = "%s-%d" % (base, n)
            used.add(base.lower())
            out_name = base + ".json"
            out_path = os.path.join(staging_dir, out_name)
            # "x", never "w": a name already on disk that this run did not write means an
            # earlier dump is about to be destroyed, and losing history to a filename
            # collision must be loud. This one DOES abort the run - unlike the per-database
            # failures above, continuing would mean writing the rest of the dumps around a
            # hole nobody was told about.
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
            print("%s:%-5d  %-14s  %3d conversations  %4d messages  "
                  "(skipped c=%d m=%d, wal %d bytes)  -> %s"
                  % (host, port, dump["dbName"], len(dump["conversations"]),
                     len(dump["messages"]), skipped.get("conversations", 0),
                     skipped.get("messages", 0), dump.get("_walBytes", 0), out_name))
            report.records += len(dump["conversations"]) + len(dump["messages"])
            dumps.append(out_path)
    return dumps, report


USAGE = """usage: webui_history_extract.py <staging_dir> [--bundle-id <id> | --webkit-root <dir>]

Extracts llama.cpp WebUI chat history from WebKit IndexedDB into <staging_dir>,
one webui-dump-<app>-<host>-<port>-<dbname>.json per (app, origin, database).

Quit the app that owns the source data first: this refuses to read a database
that is being written to rather than capture a torn snapshot of it.

  <staging_dir>          directory to write the dumps into (created if needed)
  --bundle-id <id>       read the WebKit data of this app
                         (default: %s)
  --webkit-root <dir>    read this WebsiteData dir instead; cannot be combined
                         with --bundle-id
  -h, --help             show this message
""" % DEFAULT_BUNDLE_ID


def main(argv):
    # Hand-rolled rather than argparse so the failure modes stay explicit. The first
    # positional is a directory this script CREATES, so anything that looks like a flag
    # must be rejected outright: `webui_history_extract.py --help` used to be read as
    # "extract into a directory named --help", which silently created one and filled it
    # with a full history dump in whatever the caller's working directory happened to be.
    staging_dir = None
    webkit_root = None
    bundle_id = None
    rest = argv[1:]
    i = 0
    while i < len(rest):
        arg = rest[i]
        if arg in ("-h", "--help"):
            sys.stdout.write(USAGE)
            return 0
        if arg in ("--webkit-root", "--bundle-id"):
            # Must have a value, and the value must not itself be a flag - otherwise
            # `--webkit-root --help` would silently read history from a dir named --help.
            if i + 1 >= len(rest) or rest[i + 1].startswith("-") or not rest[i + 1]:
                sys.stderr.write("error: %s needs an argument\n\n" % arg)
                sys.stderr.write(USAGE)
                return 2
            if arg == "--webkit-root":
                webkit_root = rest[i + 1]
            else:
                bundle_id = rest[i + 1]
            i += 2
            continue
        if arg.startswith("-"):
            hint = ""
            if "=" in arg and arg.split("=", 1)[0] in ("--webkit-root", "--bundle-id"):
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
    if webkit_root is not None and bundle_id is not None:
        # Honouring one and ignoring the other would read a different app's history than
        # the caller asked for, and name the dumps after a third.
        sys.stderr.write("error: --bundle-id and --webkit-root cannot be combined\n\n")
        sys.stderr.write(USAGE)
        return 2
    if webkit_root is None:
        webkit_root = webkit_root_for(bundle_id or DEFAULT_BUNDLE_ID)
    if not os.path.isdir(webkit_root):
        # Worth its own error: without it a typo'd root just reports zero origins and exits
        # 0, which reads like "no history" rather than "wrong path".
        sys.stderr.write("error: not a directory: %s\n" % webkit_root)
        return 2

    try:
        dumps, report = extract_all(webkit_root, staging_dir)
    except ExtractError as exc:
        sys.stderr.write("error: %s\n" % exc)
        return 1
    except OSError as exc:
        # Reading the WebKit tree or creating the staging dir. A traceback here would be a
        # non-zero exit with no explanation, which the launch script retries forever.
        sys.stderr.write("error: %s\n" % exc)
        return 1
    print("wrote %d dump file(s) to %s%s"
          % (len(dumps), staging_dir,
             " (%d warning(s) below)" % len(report.lines) if report.lines else ""))
    # stdout is block-buffered when the launch script redirects it to webui-import.log while
    # stderr is not, so without this every warning lands above the lines it refers to.
    sys.stdout.flush()
    for line in report.lines:
        sys.stderr.write("warning: %s\n" % line)

    if report.retry:
        # Something might have worked on a different day: the source was being written to,
        # or the I/O failed. Fail so that no terminal marker is written and the next launch
        # tries again - reporting success here retires the import while a database that
        # holds history went unread.
        sys.stderr.write("error: %d database(s) could not be read this time - not "
                         "reporting success, so the next run retries\n" % len(report.retry))
        return 1
    if not report.records and report.suspect_lines:
        # No history recovered, and there is at least one place it could have gone. Note
        # this counts RECORDS, not dump files: a database whose records all failed to decode
        # still produces a dump, with two empty arrays in it, and calling that success
        # retires the import offer forever.
        sys.stderr.write("error: recovered no conversations or messages, and %d thing(s) "
                         "could not be read - refusing to report success\n"
                         % len(report.suspect_lines))
        return 1
    # Everything else is deliberately exit 0, including permanent problems that were fully
    # understood: a remote origin, an unrelated database, a record that will never decode. A
    # non-zero exit means "retry next launch", so failing on those re-runs the import on
    # every launch forever while the user never receives the history that IS readable.
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
