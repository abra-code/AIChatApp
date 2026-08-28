#!/bin/sh
# Tests/helpers/fake_curl.sh - the downloader's network, made scriptable.
#
# curl is the one tool on the download path the harness cannot intercept: it is not an OMC
# support tool, so rebuilding $OMC_OMC_SUPPORT_PATH does not reach it. The applet therefore
# names it through $hf_curl (CADABRA_CURL in aichat.library.sh) and a test points that at this
# script, which serves bytes out of a directory instead of off the network.
#
# It exists to make the interesting cases reachable, and every one of them is an INTERRUPTION:
# a transfer that stops halfway, one that lies about how much it sent, a resume the far end
# refuses. Those are the cases that used to leave a truncated file at a model's real name, and
# they are unreachable against a server that works.
#
# ── The state directory ($FAKE_CURL_DIR) ──────────────────────────────────────
# Global defaults, and a per-file override for anything named "f_<basename>.<key>":
#
#   size     the Content-Length to declare (default: the body file's size, else 64)
#   body     a file whose bytes ARE the resource - for anything whose CONTENT matters,
#            like a shard index the applet greps. Without one the body is a synthetic
#            position-dependent stream, so a resumed file that is off by any number of
#            bytes reads differently from one that is not.
#   deliver  how many bytes to actually write this invocation, counted from the resume
#            offset (default: everything left). This is the interruption.
#   exit     the exit status to report (default 0). "0 with a short body" and "18 with a
#            short body" are different bugs and both are worth being able to stage.
#   etag     the ETag to declare (default: a constant derived from the name). The applet
#            resumes a staging file only against the revision it came from, so changing this
#            between invocations is how a test says "the file was re-uploaded".
#   refuse_resume
#            non-empty: any invocation carrying -C - writes nothing and exits 33, the way a
#            server with no byte-range support answers. Its own branch in the applet, and the
#            one place where deleting the partial is the RIGHT move - which is exactly why it
#            has to be reachable separately from a connection that merely dropped.
#
#   log      APPENDED to, one line per invocation, with the whole argument list. A test
#            asserts on it to prove a resume actually asked for a range - or that a
#            transfer never happened at all, which is what committing a finished-but-
#            unrenamed staging file has to look like.
#
# ── What it implements ────────────────────────────────────────────────────────
#   -fsSIL <url>                 the size probe: prints an HTTP header block
#   -fsSL -o <path> <url>        a transfer, truncating
#   -fsSL -C - -o <path> <url>   a transfer that appends from the file's current size
#   -w '%{http_code}'            prints the status code, for the tree API call
#
# Anything else is ignored rather than refused: this is a stand-in for the flags the applet
# actually passes, not a curl.

state="${FAKE_CURL_DIR:?fake_curl: FAKE_CURL_DIR is not set}"
[ -d "$state" ] || /bin/mkdir -p "$state"

printf '%s\n' "$*" >> "$state/log"

head_mode=0
resume=0
want_code=0
out=""
url=""

while [ $# -gt 0 ]; do
    case "$1" in
        -fsSIL|-I) head_mode=1 ;;
        -C)        resume=1; shift ;;
        -o)        out="$2"; shift ;;
        -w)        want_code=1; shift ;;
        -*)        ;;
        *)         url="$1" ;;
    esac
    shift
done

base="${url##*/}"
# The tree API's URL ends in a path segment with a query string; keep the whole thing out of
# the way of the per-file keys by naming that case explicitly.
case "$url" in
    *"/api/models/"*) base="tree" ;;
esac

# cfg <key> - the per-file value if there is one, else the global, else nothing.
cfg() {
    if [ -f "$state/f_${base}.$1" ]; then
        /bin/cat "$state/f_${base}.$1"
        return 0
    fi
    if [ -f "$state/$1" ]; then
        /bin/cat "$state/$1"
    fi
}

body_file="$state/f_${base}.body"
if [ ! -f "$body_file" ] && [ -f "$state/body" ]; then
    body_file="$state/body"
fi

size="$(cfg size)"
if [ -z "$size" ] && [ -f "$body_file" ]; then
    size="$(/usr/bin/stat -f%z -L "$body_file" 2>/dev/null)"
fi
case "$size" in ''|*[!0-9]*) size=64 ;; esac

rc="$(cfg exit)"
case "$rc" in ''|*[!0-9]*) rc=0 ;; esac

etag="$(cfg etag)"
[ -z "$etag" ] && etag="fixture-${base}"

if [ "$head_mode" = "1" ]; then
    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Content-Length: %s\r\n' "$size"
    printf 'ETag: "%s"\r\n' "$etag"
    printf '\r\n'
    exit "$rc"
fi

# A server that will not do byte ranges. Nothing is written and nothing is truncated, which is
# what makes the applet's response to it observable: the partial it deletes is one this script
# never touched.
if [ "$resume" = "1" ] && [ -n "$(cfg refuse_resume)" ]; then
    exit 33
fi

if [ -z "$out" ]; then
    exit "$rc"
fi

/bin/mkdir -p "$(/usr/bin/dirname "$out")"

# The synthetic body: "12345678910111213..." truncated to length. Position-dependent on
# purpose - a resume that starts at the wrong offset produces a file that is the right SIZE
# and the wrong bytes, which is precisely the corruption a size check alone cannot see.
if [ ! -f "$body_file" ]; then
    body_file="$state/.synthetic_body"
    if [ ! -f "$body_file" ]; then
        /usr/bin/seq 1 200000 | /usr/bin/tr -d '\n' > "$body_file"
    fi
fi

offset=0
if [ "$resume" = "1" ] && [ -f "$out" ]; then
    offset="$(/usr/bin/stat -f%z -L "$out" 2>/dev/null || echo 0)"
else
    : > "$out"
fi

remaining=$((size - offset))
[ "$remaining" -lt 0 ] && remaining=0

deliver="$(cfg deliver)"
case "$deliver" in ''|*[!0-9]*) deliver="$remaining" ;; esac
[ "$deliver" -gt "$remaining" ] && deliver="$remaining"

if [ "$deliver" -gt 0 ]; then
    /usr/bin/tail -c "+$((offset + 1))" "$body_file" | /usr/bin/head -c "$deliver" >> "$out"
fi

[ "$want_code" = "1" ] && printf '200'
exit "$rc"
