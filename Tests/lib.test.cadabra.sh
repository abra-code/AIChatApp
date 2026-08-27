# Tests/lib.test.cadabra.sh - Cadabra's accessors for omctest.
#
# Sourced by every test file, immediately after omctest.sh itself.
#
# API 3 IS A HARD REQUIREMENT HERE, AND IT IS A SAFETY ONE. Cadabra keeps its entire
# configuration in one file under $HOME:
#
#     aichat.library.sh:  mcp_app_support="$HOME/Library/Application Support/Cadabra"
#                         cadabra_settings="$mcp_app_support/settings.plist"
#
# and plister is deliberately NOT stubbed by the harness, because the handlers depend on its
# exact read/write semantics. So on a harness that does not isolate $HOME - anything older than
# API 3 - a test that adds an agent writes the real configuration of whoever is running the
# suite, and cad_reset below deletes it. Nothing would warn: the tests would pass, in exactly
# the way that matters least. Refusing to run is the only correct response to that.
# EVERY GUARD BELOW FAILS CLOSED. That is not pedantry: the thing on the other side of them is
# `rm -f` on the developer's own settings file, so a guard that errors and falls through is
# worse than no guard, because it reads as protection.
#
# The version is matched as DIGITS rather than compared with `[ -lt ]`. A non-numeric value
# makes `[` exit 2, which is neither true nor false - the `if` simply does not fire and
# execution continues past the check that exists to stop it.
case "${OMCTEST_API_VERSION:-}" in
    ''|*[!0-9]*)
        printf 'lib.test.cadabra: OMCTEST_API_VERSION is [%s], not a number - refusing to run\n' \
            "${OMCTEST_API_VERSION:-}" >&2
        exit 1 ;;
esac
if [ "$OMCTEST_API_VERSION" -lt 4 ]; then
    printf 'lib.test.cadabra: needs omctest API 4 (isolated $HOME, namespaced pasteboards, diagnostics that survive ui_reset) - refusing to run\n' >&2
    exit 1
fi

# Belt and braces, and the belt needed a buckle. An EMPTY $OMCTEST_SCRATCH turns the pattern
# below into "/*", which matches /Users/anything - so the check billed as "the fact" passed in
# precisely the state it exists to catch, and cad_reset then removed the real settings.plist.
# Both variables are required to be non-empty before either is used as a pattern.
[ -n "${OMCTEST_SCRATCH:-}" ] || {
    printf 'lib.test.cadabra: OMCTEST_SCRATCH is empty - refusing to run\n' >&2
    exit 1
}
[ -n "${HOME:-}" ] || {
    printf 'lib.test.cadabra: HOME is empty - refusing to run\n' >&2
    exit 1
}
case "$HOME" in
    "$OMCTEST_SCRATCH"/*) ;;
    *)  printf 'lib.test.cadabra: HOME is %s, which is not inside the test scratch - refusing to run\n' "$HOME" >&2
        exit 1 ;;
esac

# The settings file every assertion is ultimately about. Recomputed here the way the applet
# computes it - interpolating $HOME rather than hardcoding - so that moving it in the applet
# shows up as a failing test rather than as a test asserting about a file nobody writes.
cad_settings="$HOME/Library/Application Support/Cadabra/settings.plist"

# The view ids, IMPORTED from the applet rather than restated. A second list here is a list
# that can disagree with the first, and the disagreement is silent: omc_control would write a
# perfectly valid variable for a view the window does not have.
eval "$(/usr/bin/sed -n 's/^\([A-Z][A-Z0-9_]*_ID\)=\([0-9][0-9]*\)$/\1=\2/p' \
    "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.select.external.agent.library.sh")"
[ -n "$TABLE_ID" ] && [ -n "$PANE_OWNER_ID" ] || {
    printf 'lib.test.cadabra: no view ids imported from aichat.select.external.agent.library.sh\n' >&2
    exit 1
}

# cad_plister - the real plister, from the same interposition directory the handlers reach it
# through. Not stubbed by the harness on purpose, so the tests read back exactly what the
# handlers wrote, byte for byte, through the same implementation.
cad_plister="$OMC_OMC_SUPPORT_PATH/plister"

# THAT IT EXISTS, THAT IT RUNS, AND THAT IT CAN WRITE ARE THREE SEPARATE QUESTIONS.
#
# All three are asked, in that order, and each gets its OWN message. Collapsing them is not a
# tidiness question: only the third is fixed by turning a sandbox off, so a shared branch sends
# two of the three causes to a fix that does nothing and refuses identically on every re-run.
#
# The first is reachable. omctest's standalone init reports a missing support directory with
# `return 1` from a sourced file, which does NOT stop the file that sourced it - so execution
# can arrive here with the interposition directory empty of tools while every earlier guard
# passes: $HOME was already redirected, $OMCTEST_WORK exists, and the view-id import above reads
# out of the bundle rather than out of the support directory. A checkout without
# Contents/Frameworks, which is gitignored in these applet repos, is exactly that state.
#
# -f AS WELL AS -x, because -x alone is true of a directory. It is also true of a file the
# kernel will refuse to exec, which no file test can see; that shape is caught after the probe
# instead, on the status.
[ -f "$cad_plister" ] && [ -x "$cad_plister" ] || {
    printf 'lib.test.cadabra: no plister at %s - the interposition directory has no plister in it (unbuilt Frameworks, or a support directory that does not carry the tool) - refusing to run\n' \
        "$cad_plister" >&2
    exit 1
}

# AND IT MUST BE ABLE TO WRITE, WHICH IS NOT THE SAME QUESTION AS WHETHER IT RUNS.
#
# plister saves with NSDataWritingAtomic, and that stages the new bytes in the per-user temp
# directory ($DARWIN_USER_TEMP_DIR, under /var/folders) before renaming them into place. A
# process whose sandbox denies that directory therefore fails EVERY write while every read,
# every mkdir and every other tool in the suite keeps working - a plain write to the very same
# destination succeeds, so nothing about the destination looks wrong.
#
# What that looks like without this guard: cadabra_settings_init cannot create the settings
# file, so no accessor can store anything, so several dozen assertions across every file report
# an empty string where a value was expected. Nothing names the cause, and the shape of it -
# reads fine, writes vanish - reads exactly like a bug in the applet.
#
# The probe writes into $OMCTEST_WORK rather than $HOME on purpose: $cad_settings is the file
# the suite is about, and a guard that creates it would defeat the check_absent assertions in
# 10-acp-storage that exist to prove the read paths do not.
#
# -d and -w as well as -n: a work directory that is missing or read-only is a condition that can
# actually occur, and without them it falls through to the probe and gets told about the sandbox.
[ -n "${OMCTEST_WORK:-}" ] && [ -d "$OMCTEST_WORK" ] && [ -w "$OMCTEST_WORK" ] || {
    printf 'lib.test.cadabra: OMCTEST_WORK is [%s], which is not a writable directory - refusing to run\n' \
        "${OMCTEST_WORK:-}" >&2
    exit 1
}
# $$ because two runs of one file can share a pre-set OMCTEST_SCRATCH, and work/ is not
# recreated between them: a fixed name lets one run's cleanup land between the other's write and
# its check. The removal below still runs, for the recycled pid a fixed name would have hidden.
cad_pl_probe="$OMCTEST_WORK/plister-write-probe.$$.plist"
/bin/rm -rf "$cad_pl_probe" 2>/dev/null
# -e rather than -f, and BEFORE the write: a directory at this path, or a file rm cannot remove,
# makes the test below answer "plister cannot write" forever no matter what the sandbox allows.
# The second of those is also the one shape that could pass a probe plister did not write.
if [ -e "$cad_pl_probe" ]; then
    printf 'lib.test.cadabra: %s exists and cannot be removed - refusing to run\n' "$cad_pl_probe" >&2
    exit 1
fi
"$cad_plister" set dict "$cad_pl_probe" / >/dev/null 2>&1
cad_pl_rc=$?

# LISTED EXHAUSTIVELY, NOT AS AN ENUMERATION OF FAILURES. plister answers with 0 or 255 and
# nothing else - every return in main.cpp is noErr or -1 - so any OTHER status came from the
# shell or from a signal, and describes something that happened INSTEAD of plister running.
# Enumerating only 126 and 127 leaves the rest falling through to the file oracle below, which
# then blames the sandbox for them: a bundle whose code signature the kernel rejects is killed
# after a successful execve, so it arrives here as 137, not 126. That is the collapse this whole
# block is arranged to prevent, and re-signing rather than the sandbox is what fixes it.
#
# The arch case is not hypothetical here. thin_app.sh strips the shipped bundles to one
# architecture, and the plister the harness reaches is the APPLET's own - Cadabra.app's copy is
# arm64 only, while OMC's master copy is universal. On an Intel host every file in this suite
# would refuse, and without this branch every one of them would blame the sandbox.
case "$cad_pl_rc" in
    0|255) ;;   # plister's own answer; the file below decides whether the write landed
    126|127)
        /bin/rm -f "$cad_pl_probe"
        printf 'lib.test.cadabra: plister at %s exists but could not be executed (status %s) - wrong architecture for this host, or a bad interpreter line - refusing to run\n' \
            "$cad_plister" "$cad_pl_rc" >&2
        exit 1 ;;
    *)
        /bin/rm -f "$cad_pl_probe"
        printf 'lib.test.cadabra: plister at %s did not run to completion (status %s) - killed by a signal, usually a code signature the kernel rejected after an edit inside the bundle - refusing to run\n' \
            "$cad_plister" "$cad_pl_rc" >&2
        exit 1 ;;
esac

# TESTS FOR THE FILE, NOT FOR $?. Several plister builds across this workspace print the save
# error and still exit 0 - the behavior main.cpp now calls out as "a write that did not happen
# is not a success" - so a guard keyed on the exit status sails straight past them. That rule is
# about the SAVE outcome, which is why the exec statuses above are read and this one is not.
# -s rather than -f costs nothing and covers a future write path that is not one atomic
# writeToURL:, so the message says "did not write a usable file" rather than denying the
# existence of a short file the reader is about to see sitting in the directory.
if [ ! -s "$cad_pl_probe" ]; then
    cad_pl_tmp=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null)
    # Empty as well as failed: the fallback has to name a temp directory, and /var/folders alone
    # is the parent of every user's, so it would send a reader looking in the wrong place.
    [ -n "$cad_pl_tmp" ] || cad_pl_tmp="the per-user temp directory under /var/folders"
    /bin/rm -f "$cad_pl_probe"
    printf 'lib.test.cadabra: plister did not write a usable file (%s) - refusing to run\n' "$cad_pl_probe" >&2
    printf '  Every settings write would fail silently and the suite would report dozens of\n' >&2
    printf '  empty values as applet bugs. Usual cause: a sandbox that denies %s,\n' "$cad_pl_tmp" >&2
    printf '  where plister stages its atomic write. Re-run with the sandbox off.\n' >&2
    exit 1
fi
/bin/rm -f "$cad_pl_probe"
unset cad_pl_probe cad_pl_tmp cad_pl_rc

# cad_get <pseudopath>  ->  a string value from the settings file, or nothing.
# Reads only. A missing file, a missing key and an empty value are all empty here, which is
# what most assertions want; when the difference matters, use cad_type.
cad_get() {
    "$cad_plister" get string "$cad_settings" "$1" 2>/dev/null
}

# cad_type <pseudopath>  ->  the value's type, or nothing when the key does not exist.
# This is how a test tells "the key is absent" from "the key holds an empty string" - a
# distinction that matters here, because a saved agent with no command yet is a real state.
cad_type() {
    "$cad_plister" get type "$cad_settings" "$1" 2>/dev/null
}

# cad_count <pseudopath>  ->  how many items a container holds, "0" when it does not exist.
#
# `plister get count` prints NOTHING for an absent key, so the empty string has to be turned
# into a number here - a check comparing against "0" would otherwise pass for "no such key"
# and for "a container with nothing in it" alike. It is also the only honest way to count a
# list whose entries may contain newlines: the text form cannot represent the answer.
cad_count() {
    cad_count_n=$("$cad_plister" get count "$cad_settings" "$1" 2>/dev/null)
    case "${cad_count_n:-}" in
        ''|*[!0-9]*) printf '0\n' ;;
        *)           printf '%s\n' "$cad_count_n" ;;
    esac
}

# cad_reset - back to a profile that has never opened Cadabra.
# The whole configuration is one file, so this is genuinely complete: there is no per-window
# pasteboard key or state directory for the agent dialog to leave behind.
cad_reset() {
    /bin/rm -f "$cad_settings"
}

# cad_call <function> [args...] - call one of the applet's own library functions directly.
#
# Whole-handler dispatches are coarse, and the rules worth testing here live in named
# functions: what counts as a runnable command, what a row looks like, how a label is cleaned.
# The subshell keeps the library's globals out of the test file and stops a function that
# exits from taking the whole file with it.
cad_call() {
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh" >/dev/null 2>&1
      prefs="${CAD_PREFS_OVERRIDE:-$OMCTEST_WORK/no-such-registry.plist}"
      "$@" )
}

# cad_has <haystack> <needle>  ->  1 when the needle appears, 0 when it does not.
#
# A FUNCTION rather than an inline `case`, and that is not a style preference. These comparisons
# are wanted inside $( ), and /bin/sh - bash 3.2 in POSIX mode, the interpreter the engine uses -
# parses the `*)` of a case pattern as the CLOSING paren of the command substitution. What you
# get is a syntax error reported on a later line, and an assertion whose "actual" value is a
# fragment of your own source. Every file that needed this rediscovered it, so it lives here.
cad_has() {
    case "$1" in
        *"$2"*) echo 1 ;;
        *)      echo 0 ;;
    esac
}

# cad_call_lib <library-file> <function> [args...] - cad_call against a library of your choice.
#
# cad_call reaches the ACP agents library and, transitively, the MCP servers and base
# libraries. The model, history and inspector libraries are separate chains that source only
# the base, so they need naming. Same subshell, same reasons.
cad_call_lib() {
    cad_lib_name="$1"; shift
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/$cad_lib_name" >/dev/null 2>&1
      prefs="${CAD_PREFS_OVERRIDE:-$OMCTEST_WORK/no-such-registry.plist}"
      "$@" )
}

# cad_model_call <function> [args...] - the model library, with a redirectable server registry.
#
# FAILS CLOSED, and so do cad_call and cad_call_lib: with no CAD_PREFS_OVERRIDE set they point
# $prefs at a file that does not exist rather than leaving it on the developer's real registry.
# An opt-in seam is one a future test forgets to opt into, and the failure mode of forgetting
# is reading (and one day writing) the real thing.
#
# The registry of running llama-servers is now under the isolated $HOME like everything else -
# aichat.library.sh used to build its path from "/Users/$USER", which no amount of $HOME
# redirection could reach, and that was the original reason for this override. It is kept
# anyway, and pointed at a nonexistent file by DEFAULT, because the registry is the one piece
# of state whose readers also TERM processes: stop_orphaned_servers is on the chat-init path.
# A seam that fails closed costs nothing and means the next spelling mistake in a path is a
# missing file rather than the developer's real registry.
#
# Setting CAD_PREFS_OVERRIDE points those functions at a file the test built. The override is
# applied AFTER the library is sourced, which is what makes it work without touching the applet.
cad_model_call() {
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh" >/dev/null 2>&1
      prefs="${CAD_PREFS_OVERRIDE:-$OMCTEST_WORK/no-such-registry.plist}"
      "$@" )
}

# cad_lib_var <name> - the value of one of the applet's library variables.
#
# For DRIFT GUARDS ONLY, never for the expected value of an assertion. A test that reads its
# expectations out of the code under test agrees with that code by construction. What this is
# for is the other half of the glyph pattern: assertions state literals, and one check compares
# those literals against the applet so a rename reports itself once instead of turning every
# assertion below it vacuously true.
# The optional second argument names the library to read it from, because the constants are
# spread across chains that do not source one another: the model library is not reachable from
# the ACP one. Defaulting to the ACP chain keeps the existing callers unchanged.
cad_lib_var() {
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/${2:-aichat.acp.agents.library.sh}" >/dev/null 2>&1
      prefs="${CAD_PREFS_OVERRIDE:-$OMCTEST_WORK/no-such-registry.plist}"
      eval "printf '%s' \"\${$1}\"" )
}

# cad_import_ids <script-file> <prefix> - import a handler's view-id constants, prefixed.
#
# Same reasoning as the unprefixed import above: restating ids is restating something that can
# silently disagree. The PREFIX is what makes it usable more than once - ids are unique only
# within a document, and Cadabra's dialogs collide freely (COMMAND_FIELD_ID is 20 in the agent
# selector and 210 in the inspector; TABLE_ID is 10, 202 and 510 in three different windows).
# A bare import would let one window's constant answer for another's control.
cad_import_ids() {
    cad_ids_file="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/$1"
    cad_ids_defs=$(/usr/bin/sed -n "s/^\([A-Z][A-Z0-9_]*_ID\)=\([0-9][0-9]*\)\$/$2\1=\2/p" "$cad_ids_file")
    if [ -z "$cad_ids_defs" ]; then
        printf 'lib.test.cadabra: no view ids imported from %s\n' "$1" >&2
        exit 1
    fi
    eval "$cad_ids_defs"
}

# cad_pb_set / cad_pb_get <key> [value] - the real pasteboard, called directly.
#
# Not through the applet's pb_set/pb_get wrappers: several handoffs here are validated on read
# (epoch, TTL, shape), and a test that arms them through the applet's own arming function can
# only ever produce well-formed input. Writing the key directly is what lets a test say "a
# stale one is refused" and mean it.
cad_pb_set() { "$OMC_OMC_SUPPORT_PATH/pasteboard" "$1" set "$2"; }
cad_pb_get() { "$OMC_OMC_SUPPORT_PATH/pasteboard" "$1" get; }

# THE PASTEBOARD IS ISOLATED BY THE HARNESS AS OF API 4, and this lib used to do it by hand.
#
# Two layers. The WINDOW UUID is unique per file and per run, which makes every window-scoped key
# (aichatv2_launch_<win>, aichatv2_clearseq_<win>, aichatv2_selected_model_<win>) unique for free.
# That was never enough for Cadabra: the model-switch handoff and the launch queue have NO window
# in their name, so they were shared with whatever else was using the pasteboard - a concurrent
# run of this suite, or the developer's own running copy of Cadabra, which would have acted on a
# well-formed launch entry the suite left behind. Measured both ways: a sentinel written into
# aichatv2_launch_queue did not survive a run of 50-settings-core, and 70-mcp-servers-dialog
# failed about one time in six when two runs overlapped.
#
# omctest now keeps every board as a FILE in the per-file scratch (API 6; API 4 did it by
# prefixing the NAME instead), so a board dies with the run and never reaches the machine's
# pasteboard server at all. So this lib no longer snapshots and restores those two keys,
# and no longer needs an EXIT trap composed with omctest's own - which is where the old version
# had its own bug: `trap` with no operands run as a PIPELINE element executes in a subshell where
# caught traps are reset, so the detection printed nothing, the composed form was never chosen,
# and the bare trap it installed instead replaced omctest's scratch cleanup. One full isolated
# $HOME leaked per standalone run.

# cad_raw <pseudopath>  ->  the value as STORED, empty when the key does not exist.
#
# The reason this is not cad_call mcp_prefs_get_bool: that accessor falls back to "true" for a
# key that is absent, unreadable or non-boolean. Asserting "true" through it on a profile that
# was just reset therefore asserts the FALLBACK and passes just as happily when the write never
# happened. Anything checking that a default was actually STORED has to read it raw.
cad_raw() {
    "$cad_plister" get value "$cad_settings" "$1" 2>/dev/null
}

# cad_row <agent-id>  ->  that agent's row from the list, tab-separated, or nothing.
#
# The rows carry FOUR values against TWO drawn columns: label, status glyph, command, id.
# Columns 3 and 4 are hidden and are what the sibling handlers read back as
# OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE / _4_VALUE, so a test that picks a row by its id is
# also asserting that the hidden columns are still where the handlers expect them.
cad_row() {
    ui_rows "$TABLE_ID" | /usr/bin/awk -F'\t' -v want="$1" '$4 == want { print; exit }'
}

# cad_field <agent-id> <column>  ->  one column of that row. 1 label, 2 status, 3 command, 4 id.
cad_field() {
    cad_row "$1" | /usr/bin/cut -f"$2"
}

# cad_journal <view-id>  ->  every value written to that view, in order, one line per call.
#
# ui_value answers "what does the control hold now", which is the right question most of the
# time and the wrong one for this dialog. The pane-owner protocol is about ORDER - the owner is
# cleared before a repaint and set after it - and about whether a handler wrote a field AT ALL.
# The virtual window cannot answer either: a value written twice looks like a value written
# once, and a field left alone looks exactly like a field rewritten with what it already held.
#
# The journal can, because it records every call in order. Its lines are
# <uuid> TAB <target> TAB <args, tab-joined, tabs and newlines flattened to spaces>.
cad_journal() {
    /usr/bin/awk -F'\t' -v t="$1" '$2 == t { sub(/ $/, "", $3); print $3 }' "$OMCTEST_UI/journal.tsv"
}

# cad_writes <view-id>  ->  how many calls were made against that view.
#
# The counting form, for "this handler must not touch that control". Counting rather than
# reading matters when the value written is the empty string, which is a real instruction here
# (clearing the pane owner) and which command substitution would otherwise swallow.
cad_writes() {
    /usr/bin/awk -F'\t' -v t="$1" '$2 == t { n++ } END { print n + 0 }' "$OMCTEST_UI/journal.tsv"
}

# cad_journal_reset - forget every recorded call, keeping the virtual window intact.
#
# ui_reset would wipe the window too, taking the table rows with it - and the rows are what the
# next section usually asserts against. Sections that count calls start from a clean journal
# instead, the way alerts_reset works for alerts.
cad_journal_reset() {
    : > "$OMCTEST_UI/journal.tsv"
}

# cad_lib_glyphs  ->  the three status glyphs the applet currently ships, space separated.
#
# For the drift guard ONLY. The assertions state the glyphs as literals, because a test that
# sources them from the code it is testing passes just as happily with the mapping inverted.
# But that independence costs a wall of unexplained failures the moment someone picks a
# different glyph, so one check compares the two and says it once.
cad_lib_glyphs() {
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh" >/dev/null 2>&1
      prefs="${CAD_PREFS_OVERRIDE:-$OMCTEST_WORK/no-such-registry.plist}"
      printf '%s %s %s' "$ACP_STATUS_READY" "$ACP_STATUS_MISSING" "$ACP_STATUS_UNKNOWN" )
}

# cad_fake_agent  ->  the path of the fake ACP agent in Tests/helpers.
#
# A real agent would mean depending on one being installed, on a network and on credentials,
# so a green Test result would mean different things on different machines. This one answers
# initialize and session/new identically every time, which is what lets a test assert on the
# PROBE'S OUTPUT rather than on whether some third-party binary happens to be present.
cad_fake_agent() {
    printf '%s\n' "$OMCTEST_TESTS/helpers/fake_acp_agent.py"
}
