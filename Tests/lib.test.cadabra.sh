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
if [ "$OMCTEST_API_VERSION" -lt 3 ]; then
    printf 'lib.test.cadabra: needs omctest API 3 (isolated $HOME) - refusing to run against the real settings\n' >&2
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
# The registry of running llama-servers is the one piece of Cadabra's state that an isolated
# $HOME does NOT cover: aichat.library.sh builds its path from "/Users/$USER" rather than from
# $HOME, so under test it still resolves to the developer's real file. Everything that reads it
# is read-only, so this is not dangerous - but it is not deterministic either, and a test
# asserting "no models are loaded" would fail for whoever happens to have a chat window open.
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

# THE PASTEBOARD IS NOT ISOLATED BY THE HARNESS, and that has a consequence worth spelling out.
#
# What the harness isolates is the WINDOW UUID - unique per file and per run - which makes every
# window-scoped key (aichatv2_launch_<win>, aichatv2_clearseq_<win>, aichatv2_selected_model_<win>)
# unique for free. omctest.sh says as much where it mints the uuid: "pasteboard keys outlive the
# process".
#
# Cadabra also has two keys with NO window in their name - the model-switch handoff and the
# launch queue - and those are shared with whatever else is using this pasteboard namespace,
# including the developer's own running copy of Cadabra. Verified rather than assumed: a
# sentinel written into aichatv2_launch_queue is gone after running 50-settings-core.
#
# Both are TTL-bounded transient handoffs, so the blast radius is one dropped pending switch,
# but "the test suite reached outside its scratch" is not a thing to leave undocumented. These
# snapshot the keys at the top of a file that touches them and put them back at the end.
CAD_GLOBAL_PB_KEYS="aichatv2_launch_queue aichatv2_model_switch"

# ONE FILE PER KEY, not a TSV. These values carry model paths, and a path may contain a tab or
# a newline on every filesystem macOS mounts - which a `IFS=<tab> read -r k v` loop would
# truncate, and a newline would corrupt the whole snapshot rather than one entry.
cad_pb_snapshot() {
    /bin/mkdir -p "$OMCTEST_WORK/.pb-snapshot"
    for cad_pb_k in $CAD_GLOBAL_PB_KEYS; do
        cad_pb_get "$cad_pb_k" > "$OMCTEST_WORK/.pb-snapshot/$cad_pb_k"
    done
}

# Best effort, and worth being honest about its limits: there is no EXIT trap, so a file that
# dies part way never reaches this, and it cannot protect a LIVE Cadabra during the run - only
# leave the keys as it found them afterwards. Both handoffs are TTL-bounded, so the value put
# back is either still valid or already refused on read.
cad_pb_restore() {
    [ -d "$OMCTEST_WORK/.pb-snapshot" ] || return 0
    for cad_pb_k in $CAD_GLOBAL_PB_KEYS; do
        [ -f "$OMCTEST_WORK/.pb-snapshot/$cad_pb_k" ] || continue
        cad_pb_set "$cad_pb_k" "$(/bin/cat "$OMCTEST_WORK/.pb-snapshot/$cad_pb_k")"
    done
    return 0
}

# Snapshot the shared keys for EVERY file, and put them back however the file ends.
#
# Per file rather than per suite because that is the only scope this lib controls, and it is
# enough: whatever a file breaks, it repairs. It has to be every file, not just the ones whose
# TESTS write these keys - the pre-existing agent-dialog files dispatch a handler that calls
# launch_queue_arm, so they leave a well-formed, in-TTL launch entry behind that a live Cadabra
# would act on within its 120s window.
#
# The trap is COMPOSED rather than set. In standalone mode omctest installs its own EXIT/INT/TERM
# traps to remove the scratch, and a bare `trap ... EXIT` here would silently replace them,
# turning a tidy-up into a leak. Under the runner no such trap exists and the plain form is right.
cad_pb_snapshot
# The detection is a COMMAND SUBSTITUTION, not a pipeline. `trap` with no operands run as a
# pipeline element executes in a subshell, where caught traps are reset to default - so it
# prints nothing, the test always failed, and this always installed the bare form, replacing
# omctest's scratch cleanup in standalone mode. Measured: a file sourcing only omctest.sh leaks
# nothing; the same file sourcing this lib leaked one full isolated $HOME per run.
if case "$(trap)" in *omctest_cleanup_scratch*) true ;; *) false ;; esac; then
    trap 'cad_pb_restore; omctest_cleanup_scratch' EXIT
    trap 'cad_pb_restore; omctest_cleanup_scratch; exit 130' INT
    trap 'cad_pb_restore; omctest_cleanup_scratch; exit 143' TERM
else
    trap 'cad_pb_restore' EXIT
    trap 'cad_pb_restore; exit 130' INT
    trap 'cad_pb_restore; exit 143' TERM
fi

# cad_ui_reset - ui_reset, without throwing away the three diagnostic logs.
#
# ui_reset removes unknown_ids.log, suspect_writes.log and errors.log along with the windows,
# so the standing "no undeclared ids" check at the end of a file covers only what happened since
# the LAST reset - which in a file that resets between sections is almost nothing. Measured: in
# a file resetting before every section, that closing check covered zero writes and a handler
# scribbling on a made-up view id went unnoticed.
#
# This carries the three logs forward. Use cad_unknown_writes_all for the closing check.
# Truncated at source time. OMCTEST_SCRATCH can be pre-set to a fixed directory (which
# OMCTEST_KEEP_SCRATCH invites), and without this a run that legitimately failed "no undeclared
# ids" keeps failing after the applet is fixed - the worst kind of stale test.
/bin/rm -f "$OMCTEST_WORK"/.cumulative-unknown_ids.log \
           "$OMCTEST_WORK"/.cumulative-suspect_writes.log \
           "$OMCTEST_WORK"/.cumulative-errors.log 2>/dev/null

cad_ui_reset() {
    for cad_log in unknown_ids suspect_writes errors; do
        if [ -s "$OMCTEST_UI/$cad_log.log" ]; then
            /bin/cat "$OMCTEST_UI/$cad_log.log" >> "$OMCTEST_WORK/.cumulative-$cad_log.log"
        fi
    done
    ui_reset
}

# The cumulative counterparts, covering the whole file rather than the last section.
cad_unknown_writes_all() {
    /bin/cat "$OMCTEST_WORK/.cumulative-unknown_ids.log" 2>/dev/null
    ui_unknown_writes
}
cad_suspect_writes_all() {
    /bin/cat "$OMCTEST_WORK/.cumulative-suspect_writes.log" 2>/dev/null
    ui_suspect_writes
}

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
