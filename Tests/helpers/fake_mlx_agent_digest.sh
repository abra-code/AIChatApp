#!/bin/sh
# Tests/helpers/fake_mlx_agent_digest.sh - a stand-in for `mlx-agent digest`.
#
# The real thing loads Apple's on-device model and summarizes, which takes seconds and returns
# different prose every run. Neither property belongs in an assertion: a test written against
# real output would be slow and would fail on wording, and one written loosely enough to pass
# would not be testing anything. What this applet has to get right is the PLUMBING around the
# digest - the wire filter, the transcript it builds from the preamble, the guard that stops a
# stale result landing in the wrong window, and the fallback when no digest arrives - and all
# of that is testable against a fixed preamble.
#
# Behavior is chosen by FAKE_DIGEST_MODE:
#   ok      (default) exit 0, print a preamble on stdout, RESULT_JSON on stderr
#   decline exit 3 with a reason on stderr - mlx-agent's "not condensed", the commonest case
#   empty   exit 0 but print NOTHING, the shape that would inject an empty conversation
#   fail    exit 1, a real failure
#
# It also records its argv to $FAKE_DIGEST_LOG when set, so a test can assert the applet asked
# for the flags it claims to (--backend foundation, --render, the same --keep-recent the
# transcript builder is given).

[ -n "${FAKE_DIGEST_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_DIGEST_LOG"

case "${FAKE_DIGEST_MODE:-ok}" in
    decline)
        printf '[digest] nothing to condense\n' >&2
        exit 3 ;;
    empty)
        exit 0 ;;
    fail)
        printf '[digest] summarizer unavailable\n' >&2
        exit 1 ;;
esac

# The real preamble's opening sentence, verbatim from mlx-agent's DigestRenderer, because the
# applet's own test asserts on it: if that wording changes upstream, a test naming it here is
# where the disagreement should surface.
cat <<'PREAMBLE'
Context restored from an earlier conversation. The 6 messages before this point are summarized below rather than quoted, so treat the wording as approximate and the content as established. The 6 messages after this exchange are the original text, unmodified.

Established facts:
- The store is Postgres with pgvector

Decisions:
- Go with pgvector
PREAMBLE

# The counts the applet reads back to size its verbatim tail. Overridable because the real
# summarizer does NOT always keep the number it was asked for: DigestPlanner.split snaps the
# boundary backward to the nearest user turn, so the tail can be LARGER. A stand-in that always
# reported exactly --keep-recent could not express the case that matters.
printf 'RESULT_JSON: {"accepted":%s,"condensed":true,"droppedTurns":%s,"primed":8}\n' \
    "${FAKE_DIGEST_ACCEPTED:-18}" "${FAKE_DIGEST_DROPPED:-12}" >&2
exit 0
