#!/bin/sh
# Tests/94-launch-import.test.sh - the one-time offer to import AIChat 1.x history.
#
# This is a consent state machine, and the thing that makes it worth testing is that two of its
# states are indistinguishable by looking at the app: "the user said no" and "the question was
# never actually put to them" both end with no history imported. The applet is careful to tell
# them apart - a marker written on a dialog nobody saw would retire the offer forever - and
# nothing else in the app would notice if that care were removed.
#
# Everything it touches is under $HOME, so an isolated home makes the whole flow assertable.
# Its sibling, app.will.terminate, is still not dispatched anywhere in this suite, but the reason
# has narrowed: its registry teardown IS covered now (the registry moved to $HOME and the logic
# moved to prune_server_registry, exercised in 96-terminate-registry). What is left in the
# handler identifies processes with pgrep over paths inside the bundle, which under a harness
# that runs the REAL bundle match the developer's own running copy of the app.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

SUPPORT="$HOME/Library/Application Support/Cadabra"
MARKER="$SUPPORT/.webui_history_imported"
CONSENT="$SUPPORT/.webui_import_consent"
LOCK="$SUPPORT/.webui_import.lock"
LOG="$SUPPORT/webui-import.log"
V1="$HOME/Library/WebKit/com.abracode.AIChat/WebsiteData/Default"

# The whole flow is backgrounded so launch is never blocked, so every assertion about what it
# decided has to wait for it.
#
# Two things this got wrong first, both worth stating. The predicate runs under a FRESH
# /bin/sh, so it may only use plain commands and paths expanded here - a harness function like
# alerts_count inside it is simply not found, and the wait then times out silently rather than
# failing loudly. And the completion signal cannot be "the log is non-empty": the redirection
# creates the file and the header is written before the pipeline runs, so waiting on that races
# the very output being asserted. It waits for a TERMINAL line instead.
#
# Not the lock file either. It is now written and removed by the child alone, so its absence is
# a real signal - but it is absent BEFORE the child starts too, which is not the state meant.
wait_for_import_done() {
    omc_wait_for "/usr/bin/grep -qE 'import OK|will retry next launch|could not ask|user declined' \"$LOG\"" 30
}

reset_import_state() {
    /bin/rm -rf "$SUPPORT" "$HOME/Library/WebKit"
    /bin/mkdir -p "$SUPPORT"
    alerts_reset
    alert_answers_reset
}
# A machine that HAS v1 data. The contents do not matter to the decision logic - only that the
# directory exists - and the pipeline is run against this copy, never the developer's own.
give_v1_data() { /bin/mkdir -p "$V1"; printf 'not a real database\n' > "$V1/junk.db"; }

section "once answered, the question is never asked again"
reset_import_state
give_v1_data
printf 'imported earlier\n' > "$MARKER"
omc_run app.did.launch
check_status "the handler ran" 0
check "no alert is raised"     "0" "$(alerts_count)"
check "the marker is untouched" "imported earlier" "$(/bin/cat "$MARKER")"
check "  and no consent file appears" "0" "$([ -f "$CONSENT" ] && echo 1 || echo 0)"

section "a Mac that never had AIChat 1.x is not asked at all"
reset_import_state
omc_run app.did.launch
check_status "the handler ran" 0
check "nobody is asked"        "0" "$(alerts_count)"
check_exists "but the answer is recorded" "$MARKER"
check "  as nothing to import" "1" "$(cad_has "$(/bin/cat "$MARKER")" "nothing to import")"
# Recorded rather than left absent so the next launch does not rescan; the marker's presence
# IS the terminal state, whichever of the three ways it was reached.

section "declining is as durable as importing"
reset_import_state
give_v1_data
alert_answer 1
omc_run app.did.launch
check_status "the handler ran" 0
wait_for_import_done
check "the user was asked once"     "1" "$(alerts_count)"
check "  about their 1.x history"   "1" "$(alerts_mention '1\.x')"
check "the refusal is recorded"     "1" "$([ -f "$MARKER" ] && echo 1 || echo 0)"
check "  saying they declined"      "1" "$(cad_has "$(/bin/cat "$MARKER")" "declined")"
check "and no consent was stored"   "0" "$([ -f "$CONSENT" ] && echo 1 || echo 0)"
check "nothing was imported"        "0" "$([ -d "$HOME/Library/Application Support/Cadabra/History" ] && echo 1 || echo 0)"

section "a question nobody saw is not an answer"
# THE ONE THAT MATTERS. Only rc 0 and rc 1 are the user speaking. The alert tool failing to
# draw (255), or timing out (3), means the offer was never actually made - and a marker written
# on that basis would silently retire it forever for a dialog that never appeared.
for rc in 255 3; do
    reset_import_state
    give_v1_data
    alert_answer "$rc"
    omc_run app.did.launch
    wait_for_import_done
    check "  rc=$rc leaves no marker"  "0" "$([ -f "$MARKER" ] && echo 1 || echo 0)"
    check "  rc=$rc leaves no consent" "0" "$([ -f "$CONSENT" ] && echo 1 || echo 0)"
    check "  rc=$rc says why"          "1" "$(cad_has "$(/bin/cat "$LOG")" "could not ask")"
    check "  rc=$rc will ask again"    "1" "$(cad_has "$(/bin/cat "$LOG")" "ask again next launch")"
    # The fastest exit there is: the alert fails to draw and the child is gone in milliseconds.
    # What this pins is that the CHILD's own `rm -f "$lock"` runs on that path, so the lock it
    # claimed does not outlive it.
    #
    # Honest about what it does NOT catch: reverting to the old shape, where the PARENT wrote
    # the lock after forking, leaves this green. Verified by doing exactly that. The parent's
    # printf is one statement after `&` while the child must fork and exec the alert stub
    # before reaching its rm, so the parent always wins the write and the child always removes
    # it; the old bug needs the parent descheduled in between, which does not happen here. Both
    # implementations also write the same pid, so even the file contents match. That race is
    # not reachable deterministically from a test, and pretending otherwise would be worse
    # than saying so.
    check "  rc=$rc leaves no lock behind" "0" "$([ -f "$LOCK" ] && echo 1 || echo 0)"
    /bin/rm -f "$LOCK"
done

section "consent already given is not asked for twice, and completes"
# An interrupted or failed import retries SILENTLY on the next launch: the consent file records
# that the user already said yes, and re-asking a question they have answered would be the
# annoying kind of correct.
#
# A store with nothing readable in it is a SUCCESS, not a failure - there was nothing to import
# and the pipeline says so - which is why this fixture reaches the marker.
reset_import_state
give_v1_data
printf 'user approved earlier\n' > "$CONSENT"
omc_run app.did.launch
wait_for_import_done
check "the user is not asked again" "0" "$(alerts_count)"
check "  and the pipeline ran"      "1" "$(cad_has "$(/bin/cat "$LOG")" "webui history import")"
check "the import is recorded"      "1" "$(cad_has "$(/bin/cat "$LOG")" "import OK")"
check_exists "  and the marker written" "$MARKER"
# Consent has done its job once the marker exists; leaving it would be a second source of truth
# for a question that now has a terminal answer.
check "the consent file is cleaned up" "0" "$([ -f "$CONSENT" ] && echo 1 || echo 0)"
/bin/rm -f "$LOCK"

section "a failed import does not retire the offer"
# The marker is written only when BOTH steps report success, and this is the branch that keeps
# the offer alive. Forced by making the history store a regular FILE, so the convert step has
# nowhere to write and reports failure - which is a real failure of the run rather than an
# empty one, and the distinction is the whole point of the branch.
reset_import_state
give_v1_data
printf 'user approved earlier\n' > "$CONSENT"
printf 'not a directory\n' > "$SUPPORT/History"
omc_run app.did.launch
wait_for_import_done
check "no marker was written" "0" "$([ -f "$MARKER" ] && echo 1 || echo 0)"
check "  and the log says it will retry" "1" "$(cad_has "$(/bin/cat "$LOG")" "will retry next launch")"
check "consent survives for the retry"   "1" "$([ -f "$CONSENT" ] && echo 1 || echo 0)"
# ACTUALLY LAUNCH AGAIN. The point of keeping the consent file is that the retry is silent, and
# asserting alerts_count without a second dispatch measures the launch that just happened -
# which was already silent for a different reason.
# The blocking file STAYS for the retry: clearing it first would let the retry succeed, and the
# claim being tested is that a still-failing retry is silent and still refuses the marker.
/bin/rm -f "$LOCK"
alerts_reset; alert_answers_reset
omc_run app.did.launch
wait_for_import_done
check "the retry asks nothing"           "0" "$(alerts_count)"
check "  and still refuses the marker"   "0" "$([ -f "$MARKER" ] && echo 1 || echo 0)"
/bin/rm -f "$LOCK" "$SUPPORT/History"

section "a second launch does not start a second import"
# NO consent file here, deliberately. With one, the alert is skipped because consent was already
# given, so "no alert was raised" would be true whether the lock guard worked or not - proved by
# disabling the guard and watching this section stay green. Without it, the only thing that can
# keep the dialog away is the lock.
#
# The lock line is built through the app's OWN process_start_stamp rather than by spelling `ps`
# out here: it is the identity check under test, and a test that reimplements it passes when the
# two spellings agree with each other rather than when the handler is right.
lock_line_for() { # <pid>
    printf '%s %s\n' "$1" "$(cad_call_lib aichat.library.sh process_start_stamp "$1")"
}
reset_import_state
give_v1_data
lock_line_for "$$" > "$LOCK"          # this test file's own shell: alive, and provably so
alert_answer 1
omc_run app.did.launch
check_status "the handler ran" 0
check "a live import blocks another" "0" "$(alerts_count)"
# Give a broken guard time to prove itself before concluding it is silent: an unwaited negative
# assertion here wins its race against the forked child and stays green either way.
omc_wait_for "[ -s \"$LOG\" ]" 3
check "  and nothing was logged"     "0" "$([ -s "$LOG" ] && echo 1 || echo 0)"
check "  and no answer was consumed"  "0" "$([ -f "$MARKER" ] && echo 1 || echo 0)"
check "  and the lock it honored is untouched" "$(lock_line_for "$$")" "$(/bin/cat "$LOCK")"
alert_answers_reset

section "a lock nobody holds is ignored"
# Three ways a lock can name a process that is not the import, and all three must let the offer
# through. The third is the one with teeth: a pid that IS alive, because the number was reused
# while the app was closed. `kill -0` alone says "held" there and retires the offer silently for
# as long as that unrelated process lives.
for lock_case in legacy dead recycled; do
    reset_import_state
    give_v1_data
    case "$lock_case" in
        legacy)   printf '%s\n' "$$" > "$LOCK" ;;              # the pid-only format: unverifiable
        dead)     lock_line_for 999999 > "$LOCK" ;;            # a pid that cannot be running
        recycled) printf '%s Thu Jan  1 00:00:00 1970\n' "$$" > "$LOCK" ;;  # alive, wrong process
    esac
    alert_answer 1
    omc_run app.did.launch
    wait_for_import_done
    check "  $lock_case: the offer is made anyway" "1" "$(alerts_count)"
    /bin/rm -f "$LOCK"
done

section "cumulative: no handler wrote to a view id the window does not declare"
# Cumulative across the whole file, which is what makes one check at the end meaningful.
# It was not always: ui_reset used to DELETE unknown_ids.log along with the windows, so this
# covered only what happened since the last reset - close to nothing in a file that resets per
# section, and a handler scribbling on a made-up view id went entirely unnoticed. omctest API 4
# carries the three diagnostic logs across a reset, and this lib asserts that minimum.
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no table clobbered by a bare value write" "" "$(ui_suspect_writes)"

omctest_end
