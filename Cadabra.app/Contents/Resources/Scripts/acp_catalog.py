#!/usr/bin/env python3
"""Read the bundled ACP agent catalog and hand it to the shell library as TSV.

The catalog itself is Resources/acp-agents.json. It used to be a heredoc of tab-separated
lines inside aichat.acp.agents.library.sh, which made it awkward to extend and easy to break:
tab is IFS *whitespace*, so one empty field collapses into its neighbor and shifts every later
field left - and in this particular table that means prose sliding into the argv column, where
it would be RUN. JSON makes an absent value unambiguous and lets a row carry structure, most
usefully an "args" LIST, so "this agent takes no arguments" is [] instead of a single space
smuggled through a tab-separated field.

The shell side still reads TSV, because it can do that with `IFS=<tab> read` and no
interpreter of its own, and because the scan/consumer code already speaks it.

THE INVARIANT THIS FILE OWNS, and the reason the hand-maintained version kept going wrong:
every emitted field is non-empty and contains no tab, no carriage return and no newline.
Absent values become "-", which the shell reads as "none". Enforcing it in code rather than
in a comment is the actual improvement here - a human editing JSON cannot reintroduce the
collapsing-field bug, because this file will not emit an empty one.

Usage:
    acp_catalog.py rows [<catalog.json>]

Emits, tab separated, one row per agent:
    id, label, command, args, url, summary, note

A missing or unreadable catalog is reported on stderr and exits non-zero with NO rows on
stdout, so the dialog shows an empty list rather than a plausible-looking partial one.
"""
import json
import os
import sys

# The emitted columns, in order. This tuple is also the PRIVACY BOUNDARY of the catalog: a key
# in acp-agents.json that is not named here never reaches the shell, and therefore never reaches
# the dialog. "verification" is deliberately absent - it records what we probed and how, which is
# our provenance and not something a user running Cadabra on their own machine could check or act
# on. Adding a field here makes it user-visible, so do it on purpose.
FIELDS = ("id", "label", "command", "args", "url", "summary", "note")
ABSENT = "-"


def default_catalog_path():
    # Scripts/ lives beside the catalog's directory: <Resources>/Scripts/acp_catalog.py
    # -> <Resources>/acp-agents.json
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(os.path.dirname(here), "acp-agents.json")


def flatten(value):
    """One line, no tabs, no empties. See the invariant note at the top of the file."""
    if value is None:
        return ABSENT
    if isinstance(value, (list, tuple)):
        value = " ".join(str(v) for v in value)
    # split()/join collapses tabs, newlines and runs of spaces in one step, which is exactly
    # the set of characters that would corrupt the row or the display.
    text = " ".join(str(value).split())
    return text if text else ABSENT


def load(path):
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    agents = data.get("agents")
    if not isinstance(agents, list):
        raise ValueError("catalog has no \"agents\" list")
    return agents


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] != "rows":
        sys.stderr.write("usage: acp_catalog.py rows [<catalog.json>]\n")
        return 2
    path = argv[1] if len(argv) > 1 else default_catalog_path()
    try:
        agents = load(path)
    except Exception as exc:            # unreadable, absent, malformed - all the same to us
        sys.stderr.write("acp_catalog: cannot read %s: %s\n" % (path, exc))
        return 1

    out = []
    for agent in agents:
        if not isinstance(agent, dict):
            continue
        # An id is the one field with no sensible default: it keys the stored selection, so an
        # entry without one could never be selected, stored, or looked up again.
        agent_id = flatten(agent.get("id"))
        if agent_id == ABSENT:
            # ABSENT is what an absent value flattens to AND a legal one-character string, so
            # distinguish the two rather than reporting "no id" for an entry that has one and
            # merely collided with the sentinel. Vanishingly unlikely, but a diagnostic that
            # misdescribes its input costs more time than it ever saves.
            if " ".join(str(agent.get("id") or "").split()) == ABSENT:
                sys.stderr.write('acp_catalog: skipping an entry whose id is "%s", which this'
                                 ' format reserves to mean "absent"\n' % ABSENT)
            else:
                sys.stderr.write("acp_catalog: skipping an entry with no id\n")
            continue
        out.append("\t".join(flatten(agent.get(name)) for name in FIELDS))
    sys.stdout.write("".join(line + "\n" for line in out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
