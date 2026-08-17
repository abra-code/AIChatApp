#!/bin/sh
# Tests/50-settings-core.test.sh - the base library every other script stands on.
#
# aichat.library.sh owns three things nothing else can recover from if they are wrong: the
# creation of the one settings file, the two pasteboard handoffs that carry a model launch
# between windows, and the clear-the-chat counter. All three are validated on READ - by epoch,
# by TTL, by shape - which is exactly the kind of logic that looks obviously correct and has an
# off-by-one in the comparison.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

# The pasteboard keys and TTLs are stated as literals for the same reason the status glyphs
# are: every assertion below arms a key by name and then asks the applet to read it back, so a
# test that took the name FROM the applet would keep passing after a rename while proving
# nothing - it would be writing and reading a key no shipping code touches.
MODEL_SWITCH_KEY="aichatv2_model_switch"
LAUNCH_QUEUE_KEY="aichatv2_launch_queue"
TTL=120

section "the harness and the applet agree on the handoff keys"
check "keys and TTLs are the ones under test" \
    "$MODEL_SWITCH_KEY $LAUNCH_QUEUE_KEY $TTL $TTL" \
    "$(cad_lib_var MODEL_SWITCH_KEY) $(cad_lib_var LAUNCH_QUEUE_KEY) $(cad_lib_var MODEL_SWITCH_TTL) $(cad_lib_var LAUNCH_QUEUE_TTL)"

section "the settings file is created once, and only by a writer"
cad_reset
# The applet's own directory is deliberately not pre-created by the harness, so this is the
# real first-run path: no Cadabra directory, no file.
check_absent "a fresh profile has no settings file" "$cad_settings"
check "a read does not create one" "true" "$(cad_call mcp_prefs_get_bool servers/time/enabled)"
# The rule this is about: "callers that only READ must not call cadabra_settings_init - a read
# path that creates files is how merely looking at the configuration ends up writing it."
check_absent "  and left no file behind" "$cad_settings"
cad_call cadabra_settings_init
check_exists "  positive control: a writer does create it" "$cad_settings"
check "  with a dict at the root" "dict" "$(cad_type /)"
# plister insert cannot create the file it inserts into, which is why this exists at all: skip
# it and every subsequent write no-ops AND RETURNS SUCCESS.
cad_call mcp_prefs_init_if_missing
check "an insert into the created file lands" "dict" "$(cad_type /servers)"
n_before=$(cad_call mcp_prefs_array_count servers/local/allowed-read)
cad_call cadabra_settings_init
check "re-initializing keeps what was there" "$n_before" "$(cad_call mcp_prefs_array_count servers/local/allowed-read)"
check "  and reports success"                "0" "$(cad_call cadabra_settings_init; echo $?)"

section "the session config dir is per window, under the app support dir"
check "a window's config dir" \
    "$HOME/Library/Application Support/Cadabra/Sessions/WIN-1" \
    "$(cad_call aichat_session_config_dir WIN-1)"

section "the model-switch handoff"
cad_pb_set "$MODEL_SWITCH_KEY" ""
cad_call model_switch_arm "win-A"
check "an armed handoff names its window" "win-A" "$(cad_call model_switch_consume)"
check "  and consuming it clears it"      ""      "$(cad_call model_switch_consume)"

now=$(/bin/date +%s)
# AT the boundary, near enough to mean it. A +-10s fixture leaves a nine-second slack window in
# which the acceptance test can be silently narrowed and nothing notices - measured. The accept
# side keeps 2s of headroom because real time passes between stamping the epoch here and the
# comparison running; the refuse side needs none, so it is exact. An `-le` to `-lt` flip is one
# second wide and is not reachable without freezing the clock, which needs a seam the applet
# does not have.
cad_pb_set "$MODEL_SWITCH_KEY" "win-A|$((now - TTL + 2))"
check "just inside the TTL is honored" "win-A" "$(cad_call model_switch_consume)"
cad_pb_set "$MODEL_SWITCH_KEY" "win-A|$((now - TTL - 1))"
check "just outside it is refused"     ""      "$(cad_call model_switch_consume)"
# A refused handoff must still be cleared. Otherwise a Model-button-then-Cancel leaves a dead
# window armed on the pasteboard forever, and the next first-launch model pick reads it.
cad_pb_set "$MODEL_SWITCH_KEY" "win-A|$((now - TTL - 1))"
cad_call model_switch_consume >/dev/null
check "  and a refused one is cleared anyway" "" "$(cad_pb_get "$MODEL_SWITCH_KEY")"
cad_pb_set "$MODEL_SWITCH_KEY" "win-A|not-a-number"
check "a malformed epoch is refused"   ""      "$(cad_call model_switch_consume)"
cad_pb_set "$MODEL_SWITCH_KEY" "win-A"
check "no epoch at all is refused"     ""      "$(cad_call model_switch_consume)"
# age must be >= 0, not merely <= TTL. A clock that moved backwards - or a handoff written by a
# machine ahead of this one - would otherwise be accepted forever.
cad_pb_set "$MODEL_SWITCH_KEY" "win-A|$((now + 3600))"
check "an epoch in the future is refused" ""   "$(cad_call model_switch_consume)"

section "disarming targets one window, by whole name"
cad_call model_switch_arm "win-A"
cad_call model_switch_disarm_for "win-B"
check "another window's close leaves it armed" "win-A" "$(cad_call model_switch_consume)"
cad_call model_switch_arm "win-A"
cad_call model_switch_disarm_for "win-A"
check "its own window's close disarms it"      ""      "$(cad_call model_switch_consume)"
# The match is on "<window>|", not on a bare prefix: window uuids share prefixes routinely
# (OMCTEST-foo-123 and OMCTEST-foo-1234), and a prefix match would let one window's close
# disarm another's pending switch.
cad_call model_switch_arm "win-A2"
cad_call model_switch_disarm_for "win-A"
check "a window whose name is a prefix does not" "win-A2" "$(cad_call model_switch_consume)"

section "the launch queue carries the model and its tools decision together"
cad_pb_set "$LAUNCH_QUEUE_KEY" ""
cad_call launch_queue_arm "/models/tiny.gguf" "true"
q=$(cad_call launch_queue_consume)
check "the queue round-trips"        "/models/tiny.gguf|true" "$q"
check "  the model half"             "/models/tiny.gguf"      "$(cad_call launch_queue_model "$q")"
check "  the tools half"             "true"                   "$(cad_call launch_queue_tools "$q")"
check "  and consuming clears it"    ""                       "$(cad_call launch_queue_consume)"
cad_call launch_queue_arm "/models/tiny.gguf" "false"
check "tools-off round-trips too"    "false" "$(cad_call launch_queue_tools "$(cad_call launch_queue_consume)")"

# The reason the fields are peeled from the RIGHT. A model path is a filename the user chose,
# and "|" is legal in one on every filesystem macOS mounts; splitting from the left would hand
# the chat window a truncated path and a tools decision of "b/model.gguf".
section "a model path containing the separator survives"
weird="/models/a|b/c|d.gguf"
cad_call launch_queue_arm "$weird" "true"
q=$(cad_call launch_queue_consume)
check "the path comes back whole"    "$weird" "$(cad_call launch_queue_model "$q")"
check "  and the decision with it"   "true"   "$(cad_call launch_queue_tools "$q")"

section "a stale or malformed launch queue is dropped"
now=$(/bin/date +%s)
cad_pb_set "$LAUNCH_QUEUE_KEY" "/m.gguf|true|$((now - TTL + 2))"
check "just inside the TTL is honored" "/m.gguf|true" "$(cad_call launch_queue_consume)"
cad_pb_set "$LAUNCH_QUEUE_KEY" "/m.gguf|true|$((now - TTL - 1))"
check "just outside it is refused"     ""             "$(cad_call launch_queue_consume)"
cad_pb_set "$LAUNCH_QUEUE_KEY" "/m.gguf|true|$((now - TTL - 1))"
cad_call launch_queue_consume >/dev/null
check "  and the stale entry is cleared" "" "$(cad_pb_get "$LAUNCH_QUEUE_KEY")"
cad_pb_set "$LAUNCH_QUEUE_KEY" "/m.gguf|true|later"
check "a malformed epoch is refused"   ""             "$(cad_call launch_queue_consume)"
cad_pb_set "$LAUNCH_QUEUE_KEY" "/m.gguf|true|$((now + 3600))"
check "an epoch in the future is refused" ""          "$(cad_call launch_queue_consume)"
cad_call launch_queue_arm "/m.gguf" "true"
cad_call launch_queue_clear
check "clearing drops it"              ""             "$(cad_call launch_queue_consume)"

section "clearing the chat is distinguishable from clearing it again"
# The Chat element DEDUPES a re-injected transcript equal to the last one, and live-typed turns
# never update its notion of the last one - so two identical empty injects would make the
# second New Chat a no-op. The counter in the title is the whole defense.
ui_reset
cad_call chat_inject_empty "$OMC_ACTIONUI_WINDOW_UUID"
first=$(ui_state 1 content)
cad_call chat_inject_empty "$OMC_ACTIONUI_WINDOW_UUID"
second=$(ui_state 1 content)
check "the first clear is an empty transcript" "1" "$(cad_has "$first"  '"items":[]')"
check "  and so is the second"                 "1" "$(cad_has "$second" '"items":[]')"
check "the two clears are not identical"       "differ" \
    "$([ "$first" = "$second" ] && echo same || echo differ)"
check "  the counter advanced"                 "1" "$(cad_has "$second" '__cleared-2__')"

section "the clear counter is per window, and survives a corrupt value"
ui_reset
saved_win="$OMC_ACTIONUI_WINDOW_UUID"
omc_window_switch "second-chat"
cad_call chat_inject_empty "$OMC_ACTIONUI_WINDOW_UUID"
check "a second window counts from one" "1" "$(cad_has "$(ui_state 1 content)" '__cleared-1__')"
# TWO things were wrong with the obvious version of this, and both made it unfailable.
#
# The fixture has to be "12x", not "not-a-number": /bin/sh evaluates $(("not-a-number" + 1)) as
# arithmetic over three UNSET names, which is 0, +1 = 1 - the very answer the guard produces, so
# deleting the guard changed nothing. "12x" is a real arithmetic error ("value too great for
# base"), which is the only shape that tells the two apart.
#
# And the window has to be reset between the calls, because both write byte-identical content:
# without that, the check cannot tell that the second call happened at all.
ui_reset
cad_pb_set "aichatv2_clearseq_$OMC_ACTIONUI_WINDOW_UUID" "12x"
cad_call chat_inject_empty "$OMC_ACTIONUI_WINDOW_UUID"
check "the corrupt counter did not stop the clear" "1" "$(cad_writes 1)"
check "a corrupt counter restarts at one" "1" "$(cad_has "$(ui_state 1 content)" '__cleared-1__')"
# Restoring the variable IS the whole mechanism - omc_window_switch only assigns it - so
# calling it here would just mint a third uuid for nothing.
OMC_ACTIONUI_WINDOW_UUID="$saved_win"; export OMC_ACTIONUI_WINDOW_UUID

section "the window title reflects state"
ui_reset
cad_call chat_window_set_status "$OMC_ACTIONUI_WINDOW_UUID" "Loading Tiny"
check "the status becomes the title" "Loading Tiny" "$(ui_title)"

section "byte sizes are rendered at the boundaries, not near them"
check "zero"                "0 KB"    "$(cad_call format_bytes 0)"
check "under a kilobyte"    "0 KB"    "$(cad_call format_bytes 1023)"
check "exactly a kilobyte"  "1 KB"    "$(cad_call format_bytes 1024)"
check "just under a mega"   "1023 KB" "$(cad_call format_bytes 1048575)"
check "exactly a megabyte"  "1 MB"    "$(cad_call format_bytes 1048576)"
check "just under a giga"   "1023 MB" "$(cad_call format_bytes 1073741823)"
check "exactly a gigabyte"  "1.0 GB"  "$(cad_call format_bytes 1073741824)"
check "two gigabytes"       "2.0 GB"  "$(cad_call format_bytes 2147483648)"
# A 7B model at Q4 is the commonest thing this ever formats, and it is the size where a
# scale=0 division in the GB branch would silently print "4.0 GB" for everything.
check "a realistic model size" "4.1 GB" "$(cad_call format_bytes 4400000000)"

section "cumulative: no handler wrote to a view id the window does not declare"
# Cumulative across the whole file, which is what makes one check at the end meaningful.
# It was not always: ui_reset used to DELETE unknown_ids.log along with the windows, so this
# covered only what happened since the last reset - close to nothing in a file that resets per
# section, and a handler scribbling on a made-up view id went entirely unnoticed. omctest API 4
# carries the three diagnostic logs across a reset, and this lib asserts that minimum.
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no table clobbered by a bare value write" "" "$(ui_suspect_writes)"

omctest_end
