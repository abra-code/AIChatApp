#!/bin/sh
# Tests/96-terminate-registry.test.sh - what quitting does to the server registry.
#
# The registry is how one instance of Cadabra knows which llama-servers are its own and which
# belong to another instance that is still running. Getting it wrong is not a cosmetic bug in
# either direction: prune too little and a quit leaves servers holding gigabytes of weights with
# no app to talk to them, prune too much and quitting ONE window's app kills the models loaded
# by a second instance the user is still working in.
#
# WHY THIS IS A FILE AND NOT A DISPATCH OF app.will.terminate. The handler around this logic
# identifies processes with `pgrep` over paths inside the bundle - llama-server, mlx-agent, the
# orphan sweep - and the harness runs the REAL bundle, so those patterns match the developer's
# own running copy of Cadabra. Dispatching it here would kill their servers. The registry half
# was lifted into prune_server_registry precisely so it could be reached without that; it
# touches nothing but the plist and the pids recorded in it.
#
# EVERY PID THIS FILE TERMS IS ONE IT SPAWNED. The fixtures name either a process this file
# started itself or a number no process can hold; nothing here can reach a pid it does not own.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

P="$OMC_OMC_SUPPORT_PATH/plister"
DEAD=999999          # no process can have this pid
# A FILE, not a variable, for the same reason omctest keeps its counters in files: spawn_sleeper
# is called through $( ), which is a subshell, so a variable assigned in it is discarded when the
# substitution ends. The list came back empty every run and four sleepers survived the suite by
# five minutes - the exact leak the reaping loop at the end was written to prevent.
SLEEPERS="$OMCTEST_WORK/sleepers"
: > "$SLEEPERS"

# A process this file owns, that will sit still until told otherwise, and that we can ask
# about later. Stands in for a llama-server: the code under test only ever asks "is this pid
# alive" and "TERM it", and a sleep answers both exactly as a server does.
# BOTH fds go to /dev/null, and that is load-bearing rather than tidy. The suite runs inside a
# pipeline to the build log, so a background child that inherits stderr holds that pipe open for
# as long as it lives - the runner then blocks waiting for EOF and the whole suite hangs for the
# full sleep. Measured: 300 seconds per sleeper, with no output and no clue why.
spawn_sleeper() {
    sleep 300 >/dev/null 2>&1 &
    printf '%s\n' "$!" >> "$SLEEPERS"
    printf '%s\n' "$!"
}
alive() { /bin/ps -p "$1" >/dev/null 2>&1 && echo 1 || echo 0; }
# A TERM is delivered asynchronously, so "it died" is a thing to wait for, not to assert
# immediately. Waiting for the EXPECTED state rather than sleeping keeps a slow machine from
# turning a correct teardown into a red check.
wait_gone() { omc_wait_for "! /bin/ps -p $1 >/dev/null 2>&1" 5; }

# mk_reg <file> - an empty registry.
# reg_add <file> <host-pid> <server-pid> - one server under one host, in both subtrees.
mk_reg() {
    /bin/rm -f "$1"
    "$P" set dict "$1" / >/dev/null 2>&1
    "$P" insert "server-hosts" dict "$1" / >/dev/null 2>&1
    "$P" insert "server-info"  dict "$1" / >/dev/null 2>&1
}
reg_add() {
    "$P" get type "$1" "/server-hosts/$2" >/dev/null 2>&1 || \
        "$P" insert "$2" dict "$1" /server-hosts >/dev/null 2>&1
    "$P" insert "$3" string "/m/x.gguf" "$1" "/server-hosts/$2" >/dev/null 2>&1
    "$P" insert "$3" dict "$1" /server-info >/dev/null 2>&1
    "$P" insert "size" string "7000" "$1" "/server-info/$3" >/dev/null 2>&1
}
has_host()   { "$P" get type "$1" "/server-hosts/$2" >/dev/null 2>&1 && echo 1 || echo 0; }
has_info()   { "$P" get type "$1" "/server-info/$2"  >/dev/null 2>&1 && echo 1 || echo 0; }
# Returns the function's own exit status, so a section asserting only that NOTHING changed can
# still prove the code ran. Without it, "the other instance is untouched" would pass just as
# happily if prune_server_registry did not exist and the shell returned 127.
prune() { # <registry> <front-pid>
    CAD_PREFS_OVERRIDE="$1" cad_call_lib aichat.server.library.sh prune_server_registry "$2" \
        >/dev/null 2>&1
}

section "quitting stops the servers this instance started"
REG="$OMCTEST_WORK/own.plist"
mk_reg "$REG"
mine=$(spawn_sleeper)
reg_add "$REG" "$$" "$mine"
check "the fixture registered it" "1" "$(has_host "$REG" "$$")"
prune "$REG" "$$"
wait_gone "$mine"
check "our own server is stopped"        "0" "$(alive "$mine")"
check "  its registration is gone"       "0" "$(has_host "$REG" "$$")"
check "  and so is its size record"      "0" "$(has_info "$REG" "$mine")"

section "and leaves another live instance's servers strictly alone"
# The one that costs real work if it is wrong. Two instances, both running; this one is
# quitting. The other's models must survive - a user with a long conversation open in a second
# window does not expect closing the first to unload it.
#
# The other "host" is a process this file spawned, so it is genuinely alive and genuinely not us.
REG="$OMCTEST_WORK/sibling.plist"
mk_reg "$REG"
mine=$(spawn_sleeper)
other_host=$(spawn_sleeper)
other_server=$(spawn_sleeper)
reg_add "$REG" "$$" "$mine"
reg_add "$REG" "$other_host" "$other_server"
prune "$REG" "$$"
wait_gone "$mine"
check "ours is stopped"                       "0" "$(alive "$mine")"
check "the live sibling's server is running"   "1" "$(alive "$other_server")"
check "  and still registered to it"          "1" "$(has_host "$REG" "$other_host")"
check "  with its size record intact"         "1" "$(has_info "$REG" "$other_server")"

section "a dead instance's leftovers are cleaned up"
# The other half of the same walk: an instance that crashed leaves its servers parented to
# launchd and its host entry behind. Nobody else will ever claim them.
REG="$OMCTEST_WORK/orphan.plist"
mk_reg "$REG"
orphan=$(spawn_sleeper)
reg_add "$REG" "$DEAD" "$orphan"
prune "$REG" "$$"
wait_gone "$orphan"
check "the orphaned server is stopped"   "0" "$(alive "$orphan")"
check "  and its dead host is pruned"    "0" "$(has_host "$REG" "$DEAD")"
check "  and its size record removed"    "0" "$(has_info "$REG" "$orphan")"

section "a registry with nothing of ours in it is left as it was"
# The negative control the two above need. Without it, "our servers were stopped" is satisfied
# by an implementation that stops everything, which is exactly the bug in the other direction.
REG="$OMCTEST_WORK/none-of-ours.plist"
mk_reg "$REG"
other_host=$(spawn_sleeper)
other_server=$(spawn_sleeper)
reg_add "$REG" "$other_host" "$other_server"
prune "$REG" "$$"
check "the teardown ran"                 "0" "$?"
check "the other instance is untouched"  "1" "$(alive "$other_server")"
check "  and its registration remains"   "1" "$(has_host "$REG" "$other_host")"

section "a server already gone is deregistered rather than signalled"
# The common case after a crash: the registry names a server that died some time ago. It must
# leave no entry behind, and it must not matter that there is nothing to signal.
REG="$OMCTEST_WORK/already-dead.plist"
mk_reg "$REG"
reg_add "$REG" "$$" "$DEAD"
prune "$REG" "$$"
check "the stale entry is dropped"       "0" "$(has_host "$REG" "$$")"
check "  and its size record with it"    "0" "$(has_info "$REG" "$DEAD")"

section "an empty or missing registry is not an error"
REG="$OMCTEST_WORK/empty.plist"
mk_reg "$REG"
prune "$REG" "$$"
check "the teardown ran"                 "0" "$?"
check "an empty registry survives"       "1" "$([ -f "$REG" ] && echo 1 || echo 0)"
CAD_PREFS_OVERRIDE="$OMCTEST_WORK/no-such-registry.plist" \
    cad_call_lib aichat.server.library.sh prune_server_registry "$$" >/dev/null 2>&1
check "a missing one is survivable too"  "0" \
    "$([ -f "$OMCTEST_WORK/no-such-registry.plist" ] && echo 1 || echo 0)"

# Nothing this file spawned may outlive it. They are 300-second sleeps, so a leak would sit in
# the developer's process list long after the suite reported green.
while IFS= read -r s; do
    [ -n "$s" ] || continue
    kill -TERM "$s" 2>/dev/null
done < "$SLEEPERS"

section "every sleeper this file started has been reaped"
# Asserted rather than assumed, because the reaping loop above silently did nothing for a while:
# it read a variable that a command substitution had thrown away. A leak is invisible from
# inside the suite - it reports green and leaves processes behind - so it needs a check.
omc_wait_for "! /bin/ps -p $(/usr/bin/tr '\n' ',' < "$SLEEPERS" | /usr/bin/sed 's/,$//') >/dev/null 2>&1" 5
still_alive=0
while IFS= read -r s; do
    [ -n "$s" ] || continue
    /bin/ps -p "$s" >/dev/null 2>&1 && still_alive=$((still_alive + 1))
done < "$SLEEPERS"
check "the file spawned some"        "1" "$([ -s "$SLEEPERS" ] && echo 1 || echo 0)"
check "  and none is still running"  "0" "$still_alive"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"

omctest_end
