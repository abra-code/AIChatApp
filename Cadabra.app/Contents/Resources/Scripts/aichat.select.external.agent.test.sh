#!/bin/bash
# aichat.select.external.agent.test.sh
# Launches the command in the field exactly as a chat window would and reports what happened.
#
# This exists because every failure mode here is invisible until the first prompt otherwise:
# a typo'd path, an agent that needs a flag to enter ACP mode, an adapter that has to download
# itself first. The probe runs `initialize` then `session/new` - the same two calls the Chat
# element makes - so a green result means the window will at least open with a live composer.
#
# WHAT GREEN DOES NOT MEAN: that prompts will succeed. Measured on opencode 1.17.13 with zero
# credentials, both calls succeed and the refusal only arrives at the first prompt. So when the
# agent advertises auth methods this reports them as a warning rather than claiming a clean
# bill of health - ChatView does not implement ACP's `authenticate`, so that login has to
# happen in the agent's own CLI.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.select.external.agent.library.sh"

python3_bin="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
[ -x "$python3_bin" ] || python3_bin=/usr/bin/python3

# Cleaned, exactly as the Continue handler cleans it. Two reasons, and the second is the subtle
# one: a field holding nothing but spaces passes a plain -z test and would be probed as a command
# that shlex splits into no argv at all; and the identity this probe records at the end is keyed
# BY the command string, so measuring the raw value while Continue stores the cleaned one means
# the two never match again - and a command typed with a stray leading space would silently lose
# the agent name and version the user just verified from the conversation info line.
command_line=$(acp_clean_one_line "${OMC_ACTIONUI_VIEW_20_VALUE:-}")
if [ -z "$command_line" ]; then
    "$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Enter a command first."
    exit 0
fi

# TESTING A SAVED AGENT SAVES IT FIRST. Clicking a button need not take focus off the field it
# was typed into, so without this a user who types a command and immediately presses Test gets a
# probe of what they typed and a record that never heard about it - and the next repaint of the
# pane quietly puts the old command back, discarding the thing they just proved works. Testing
# is part of editing, so it commits like the rest of editing.
#
# The failure is carried rather than reported here: this handler's job is the probe, and its
# result belongs in the box at the end. A save failure is prepended to that result instead of
# being written now and then overwritten by it a few seconds later.
agent_save_pane_edits "$(agent_pane_owner)" "${OMC_ACTIONUI_VIEW_53_VALUE:-}" "$command_line"
save_status=$?

# The same workspace the agent will actually be launched in, so a probe that passes is a probe
# of the real configuration (an agent may well refuse a directory it cannot read).
cwd="$(mcp_prefs_get_string servers/local/project)"
case "$cwd" in
    /*) [ -d "$cwd" ] || cwd="$HOME" ;;
    *)  cwd="$HOME" ;;
esac

"$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Starting the agent..."

# shlex here too, so the probe splits the command line the same way the transport builder
# will. Doing it in the shell instead would glob and word-split what the user typed.
probe_json=$("$python3_bin" - "$command_line" "$cwd" <<'PY'
import json, os, shlex, subprocess, sys
command_line, cwd = sys.argv[1], sys.argv[2]
try:
    argv = shlex.split(command_line)
except ValueError:
    print(json.dumps({"ok": False, "error": "unbalanced quotes in the command"}))
    raise SystemExit(0)
if not argv:
    print(json.dumps({"ok": False, "error": "empty command"}))
    raise SystemExit(0)
probe = os.path.join(os.environ["OMC_APP_BUNDLE_PATH"], "Contents/Resources/Scripts/acp_probe.py")
# An OUTER timeout as well as the probe's own: the probe kills its agent's process group, but
# this handler must return no matter what happens inside it - an OMC subcommand that never
# exits leaves the dialog stuck on "Starting the agent..." with no way back.
# -B because acp_probe.py imports acp_agent_env, and Python caches an imported module by
# writing __pycache__ NEXT TO IT - which is inside the application bundle. Pressing Test then
# leaves a .pyc in Contents/Resources/Scripts, dirtying the code signature of a signed app and
# putting a build artifact in the repo of an unsigned one. The probe runs once per press, so
# there is nothing to gain by caching it either.
try:
    out = subprocess.run([sys.executable, "-B", probe, cwd, "25", "--"] + argv,
                         capture_output=True, text=True, timeout=40)
    stdout = out.stdout
except subprocess.TimeoutExpired:
    stdout = json.dumps({"ok": False,
                         "error": "the agent did not finish starting within 40 seconds"})
sys.stdout.write(stdout or json.dumps({"ok": False, "error": "probe produced no output"}))
PY
)

# Rendering is done in Python as well: the probe's answer is JSON, and picking it apart with
# sed/cut would break on the first agent whose error message contains a quote or a newline.
report=$("$python3_bin" - "$probe_json" <<'PY'
import json, re, sys

# NOT ONE LITERAL BACKTICK BELOW THIS LINE, deliberately. This heredoc sits inside $( ), and
# bash pairs up any two backticks it finds in that region as a nested command substitution -
# even inside a quoted heredoc - so an ODD number of them fails the parse of the entire file
# with "unexpected EOF while looking for matching backtick". An earlier version of this block
# passed "bash -n" only because its backticks happened to be balanced, which meant one
# careless edit to a docstring could break the script with an error that pointed nowhere near
# the edit. Building them from chr(96) removes the hazard rather than documenting it.
TICK = chr(96)
BR = "  "        # markdown hard line break
GAP = "\u2800"   # Braille blank - see flow()


def safe(text):
    """Agent-controlled text that is about to sit inside an inline code span.

    The agent picks its own name, version and auth-method strings, so they cannot be assumed
    to be inert markdown. Measured: a single backtick in one of them closes the span early
    and the damage cascades - the rest of the pane collapsed onto one line and the bold
    markers after it rendered as literal asterisks.
    """
    return str(text).replace(TICK, "'")


def flow(items):
    """Prose -> the only multi-line markdown this pane actually renders.

    The pane parses markdown and hands the result to a single SwiftUI Text, which renders one
    inline flow and ignores block structure, so a paragraph break is parsed and then dropped
    and the neighbors are concatenated. A two-space hard break survives; a U+2800 Braille
    blank is not whitespace, so it stays inside the paragraph and shows as a gap line.

    Flattened to PHYSICAL lines first. An item can itself contain newlines - an agent's error
    message routinely does - and the hard break has to land on every line, not on every list
    element, or the multi-line message glues back into one run-on line. That is the exact bug
    this helper exists to prevent, and it would have survived on the one channel a user only
    reaches when something has already gone wrong.

    Blankness is tested with strip(), not "not line": a line of spaces is still a blank line
    to the markdown parser, so testing for the empty string alone would let the break die.
    """
    lines = [line for item in items for line in str(item).split("\n")]
    return "\n".join((GAP if not line.strip() else line) + BR for line in lines)


try:
    d = json.loads(sys.argv[1])
except Exception:
    d = None
# isinstance rather than trusting the parse: json.loads("null") succeeds, and then d.get()
# would raise AttributeError, print nothing at all, and leave the pane silently blank.
if not isinstance(d, dict):
    print("**Test failed.** The probe returned nothing usable.")
    raise SystemExit(0)

lines = []
if d.get("ok"):
    # agentInfo is OPTIONAL in ACP and some agents omit it entirely - grok answers initialize
    # with protocolVersion 1 and no name or version at all. Falling back to the words "the
    # agent" INSIDE a code span rendered them as if they were the agent's actual name, so the
    # span is only used when there is a real name to put in it.
    # Name AND version go inside the one code span. Keeping the version outside it meant it
    # was sanitized by safe() - which only neutralizes backticks, the code-span hazard - while
    # being rendered as prose, where a version containing "**" would turn the rest bold. Both
    # inside means one sanitizer matches one context. Joining also covers the agent that sends
    # a version but no name, which previously dropped the version on the floor.
    ident = " ".join(p for p in (safe(d.get("name") or ""), safe(d.get("version") or "")) if p)
    started = (TICK + ident + TICK) if ident else "the agent"
    lines.append("**Ready.** Started " + started + ", spoke ACP, and opened a session.")
    caps = d.get("capabilities") or {}
    prompt_caps = caps.get("promptCapabilities") or {}
    extras = [k for k, v in prompt_caps.items() if v is True]
    if extras:
        lines.append("")
        lines.append("Supports: %s." % ", ".join(sorted(safe(e) for e in extras)))
    auth = d.get("authMethods") or []
    if auth:
        methods = ", ".join(TICK + safe(a) + TICK for a in auth)
        lines.append("")
        lines.append("**It still needs a login.** This agent advertises " + methods
                     + ". Cadabra cannot log in for you - run the agent's own login command "
                       "in Terminal first, or prompts will fail even though this test passed.")
else:
    lines.append("**Not working.** %s" % (d.get("error") or "The agent did not answer."))
    lines.append("")
    lines.append("Check that the path is right and that the command puts the agent into ACP "
                 "mode (most need a subcommand or flag for it).")

out = flow(lines)

err = (d.get("stderr") or "").strip()
tail_note = " (tail)" if d.get("stderr_truncated") else ""
if err:
    # Agent output goes inside a fence, NOT through flow(). Measured: fenced content survives
    # the render completely verbatim - newlines, indentation, backticks, "---" and "**" all
    # intact - whereas the same text as prose is parsed as markdown and quietly mangled
    # ("__init__.py" loses both pairs of underscores and becomes "init.py", a "---" line
    # deletes itself and both surrounding breaks, and a pair of backticks across two lines
    # swallows the break between them). Mangling a traceback in the one pane whose job is
    # diagnosing a failure is worse than not showing it.
    #
    # findall returns MAXIMAL runs, so one longer than the longest run is always longer than
    # every run: output that itself contains a fence cannot close ours early and leak.
    longest = max((len(run) for run in re.findall(TICK + "+", err)), default=0)
    fence = TICK * max(3, longest + 1)
    # The label ends a paragraph and the fence starts a block; that boundary is one of the
    # ones the renderer drops, so without the empty first line inside the fence the label
    # would run straight into the first line of output.
    out += "\n" + flow(["", "Agent output%s:" % tail_note])
    out += "\n" + fence + "\n\n" + err + "\n" + fence
elif tail_note:
    # Truncated to nothing but whitespace. Saying so beats staying silent: "the agent printed
    # something and we dropped it" and "the agent printed nothing" are different diagnoses.
    out += "\n" + flow(["", "The agent produced output, but only blank lines survived the tail."])

print(out)
PY
)

# A save that went missing goes FIRST, above the probe result. The probe may well be green, and
# a green result over a silently unsaved edit is the one combination that would send the user
# away believing both halves worked - which is exactly why BOTH failure kinds are reported here
# rather than only the writable one. A record that has been deleted out from under this window
# fails just as silently and looks even more convincing, because nothing is wrong with the file.
case "$save_status" in
    1) report="**This agent is no longer in the list,** so nothing was saved - it was removed in another window, or the settings file was edited by hand. The test below still ran on what you typed.

$report"
       ;;
    2) report="**This agent could not be saved.** Check that ~/Library/Application Support/Cadabra is writable - the test below still ran on what you typed.

$report"
       ;;
esac

"$dialog_tool" "$window_uuid" $RESULT_TEXT_ID markdown "$report"

# Remember what the agent called itself, against the command it was measured with. Test is the
# ONLY place in the app where an external agent's real name and version are ever observed -
# the chat element learns them again at launch but nothing carries them back to a script - so
# if they are not captured here the conversation info line has nothing to show but a label.
# Written only for a successful probe: a failed one has no identity to record, and overwriting
# a good reading with blanks would erase what the info line was showing.
verified=$("$python3_bin" - "$probe_json" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    d = None
if isinstance(d, dict) and d.get("ok"):
    # Tab-separated, and both fields stripped of tabs AND newlines first. The shell reader
    # below splits on tab, so a name carrying one would shift the version into it; a newline
    # survives strip() when it is interior, rides through the plist, and turns the one-line
    # info strip into two lines. The agent chooses these strings, so neither is hypothetical.
    def flatten(value):
        return " ".join(str(value or "").split())

    name = flatten(d.get("name"))
    version = flatten(d.get("version"))
    sys.stdout.write("%s\t%s" % (name, version))
PY
)
if [ -n "$verified" ]; then
    verified_name=${verified%%	*}
    verified_version=${verified#*	}
    acp_agent_record_verified "$command_line" "$verified_name" "$verified_version"
fi
