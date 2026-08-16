"""The PATH an external ACP agent has to be launched with.

WHY THIS EXISTS. A GUI-launched .app inherits a minimal PATH - typically
/usr/bin:/bin:/usr/sbin:/sbin - with none of the places a developer's tools actually live.
That is invisible for a compiled agent whose absolute path we resolved ourselves, and fatal
for an agent that is an interpreter script. Measured on this Mac:

    /usr/local/bin/kilo is `#!/usr/bin/env node`

    full PATH     -> {"ok": true, "name": "Kilo", "version": "7.1.23", ...}
    app-like PATH -> {"ok": false, "error": "agent closed its output before answering",
                      "stderr": "env: node: No such file or directory"}

The exec fails before the agent writes a single byte, so the only symptom is stdout reaching
EOF during the handshake, which reads as "the agent is broken" rather than "we did not give
it a PATH". opencode hides the problem because it is a compiled binary with no interpreter to
find; every node-based agent (kilo, the Claude Code ACP adapter, Gemini CLI) hits it.

NOT THE SAME LIST as acp_agent_search_dirs in aichat.acp.agents.library.sh, and deliberately
so. That one answers "where do agent executables get installed", and is used to FIND an agent
to show in the catalog. This one answers "where does an agent's own interpreter and helper
tools live" - node, npx, bun - and is used to LAUNCH it. They overlap heavily; when adding a
directory, consider whether both questions want it.

Both the probe behind the Test button and the transport handed to ChatView import this, so a
green Test cannot mean something different from the launch that follows it.
"""
import glob
import os

# Appended to the inherited PATH, not prepended: the same precedence acp_agent_which uses
# when it resolves an executable (a user who deliberately shadows a tool on their own PATH
# still wins).
#
# Order matters for one reason: it decides which `node` an agent gets when more than one
# exists. A GUI app's inherited PATH carries no signal about that - it is the four system
# dirs and nothing else - so the tie is broken here. The canonical package-manager dirs lead,
# because that is where an interpreter an agent was installed against actually lives; a
# leftover old node under a per-tool directory should not shadow it.
PACKAGE_MANAGER_DIRS = [
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "~/.local/bin",
    "~/go/bin",
]

SYSTEM_DIRS = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

# Per-tool install directories are DISCOVERED, not enumerated. Every one of these tools digs
# its own hole in the home directory and drops a bin/ in it - opencode in ~/.opencode/bin,
# grok in ~/.grok/bin, bun in ~/.bun/bin, cargo in ~/.cargo/bin - and the list is open-ended,
# so hardcoding it means the next agent is invisible until someone edits this file. Globbing
# finds it with no code change, which is the whole point: the catalog is a convenience, but
# "can this machine run the thing at all" should not depend on us having heard of it.
#
# ".[!.]*/bin" rather than ".*/bin": the latter also matches "." and "..", which would expand
# to ~/bin and /Users/bin. Harmless here only because neither happens to exist.
PER_TOOL_PATTERN = os.path.join(".[!.]*", "bin")


def per_tool_dirs():
    """Existing ~/.<tool>/bin directories, sorted so the resulting PATH is deterministic.

    The home directory is glob.escape()d before the pattern is joined onto it. It is DATA, not
    part of the pattern, and glob would otherwise reinterpret any metacharacter in it: measured
    with a home of "/tmp/home[1] test", the unescaped version treats "[1]" as a character class
    and finds nothing at all, silently returning us to the bug this function exists to fix. The
    shell twin never had the problem because "$HOME" is quoted there.
    """
    pattern = os.path.join(glob.escape(os.path.expanduser("~")), PER_TOOL_PATTERN)
    return sorted(d for d in glob.glob(pattern) if os.path.isdir(d))


def launch_path_dirs():
    """The appended directories, in search order."""
    return ([os.path.expanduser(d) for d in PACKAGE_MANAGER_DIRS]
            + per_tool_dirs()
            + SYSTEM_DIRS)


def launch_path(inherited=None):
    """The inherited PATH with the well-known tool directories appended, de-duplicated.

    Non-existent directories are kept rather than filtered: a PATH entry that does not exist
    costs nothing, and dropping it would make the result depend on when this ran, which is
    the sort of thing that turns into an intermittent bug report.
    """
    if inherited is None:
        inherited = os.environ.get("PATH", "")
    entries = [e for e in inherited.split(os.pathsep) if e]
    entries.extend(launch_path_dirs())
    seen = set()
    ordered = []
    for entry in entries:
        if entry not in seen:
            seen.add(entry)
            ordered.append(entry)
    return os.pathsep.join(ordered)


def launch_env(base=None):
    """A copy of the environment with PATH replaced by launch_path()."""
    env = dict(os.environ if base is None else base)
    env["PATH"] = launch_path(env.get("PATH", ""))
    return env
