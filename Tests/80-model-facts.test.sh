#!/bin/sh
# Tests/80-model-facts.test.sh - what a path IS, and what it is called.
#
# One picker drives three engines, and exactly one place decides which one a path belongs to.
# The picker rows, the info pane, the RAM check and the chat window's argv all dispatch on
# model_engine rather than re-deriving it, so an answer that is wrong here is wrong in four
# places at once - and two of the rules are explicitly ORDER-DEPENDENT, which is the kind of
# thing a later tidy-up silently reverses.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

# The sentinel is stated as a literal, with a drift guard, for the usual reason: every
# assertion below feeds it in and asks what comes back, so taking it from the applet would keep
# the tests green after a rename while testing a value nothing else uses.
FOUNDATION="foundation:apple-on-device"

M="$OMCTEST_WORK/models"
/bin/mkdir -p "$M"

# A GGUF is a single file; nothing reads its contents here, only its name and size.
mk_gguf() { /bin/mkdir -p "$(/usr/bin/dirname "$1")"; /usr/bin/head -c "${2:-64}" /dev/zero > "$1"; }

section "the harness and the applet agree on the sentinel"
check "the on-device id is the one under test" "$FOUNDATION" \
    "$(cad_lib_var FOUNDATION_MODEL_ID aichat.model.library.sh)"

section "recognizing what a path is"
mk_gguf "$M/Qwen3-4B-Q5_K_S.gguf" 2048
/bin/mkdir -p "$M/mlx-model"; echo '{}' > "$M/mlx-model/config.json"
/usr/bin/head -c 4096 /dev/zero > "$M/mlx-model/model.safetensors"
check "a gguf file"        "gguf"       "$(cad_call_lib aichat.model.library.sh model_engine "$M/Qwen3-4B-Q5_K_S.gguf")"
check "an mlx directory"   "mlx"        "$(cad_call_lib aichat.model.library.sh model_engine "$M/mlx-model")"
# The sentinel is tested FIRST in the function, and that order is load-bearing: every other
# branch touches the filesystem, and this id is deliberately not on it. Reached later it falls
# through to "unknown" and the picker reports Apple's own model as corrupt.
check "the on-device sentinel" "foundation" "$(cad_call_lib aichat.model.library.sh model_engine "$FOUNDATION")"
check "a gguf that is not on disk" "" "$(cad_call_lib aichat.model.library.sh model_engine "$M/gone.gguf")"
check "an empty path"              "" "$(cad_call_lib aichat.model.library.sh model_engine "")"
check "a plain directory"          "" "$(cad_call_lib aichat.model.library.sh model_engine "$M")"
check "  and it reports failure"   "1" "$(cad_call_lib aichat.model.library.sh model_engine "$M" >/dev/null; echo $?)"

section "config.json alone is not a model"
# HF snapshot directories of GGUF repos carry a config.json too. Treating that as MLX would
# offer the user a directory that cannot be loaded, and the shards are what tell them apart.
/bin/mkdir -p "$M/gguf-repo-snapshot"
echo '{}' > "$M/gguf-repo-snapshot/config.json"
mk_gguf "$M/gguf-repo-snapshot/weights.gguf" 128
check "a config with no shards is not mlx" "" \
    "$(cad_call_lib aichat.model.library.sh model_engine "$M/gguf-repo-snapshot")"

section "shards one level down still count, two levels down do not"
# The scan is bounded at maxdepth 2 because it runs per picker row. Both sides are asserted:
# the bound is a deliberate cost decision, and an unbounded rewrite would make the picker walk
# whole model caches on every open.
/bin/mkdir -p "$M/nested-1/shards"
echo '{}' > "$M/nested-1/config.json"
/usr/bin/head -c 128 /dev/zero > "$M/nested-1/shards/a.safetensors"
check "a shard in a subdirectory is found" "mlx" \
    "$(cad_call_lib aichat.model.library.sh model_engine "$M/nested-1")"
/bin/mkdir -p "$M/nested-2/a/b"
echo '{}' > "$M/nested-2/config.json"
/usr/bin/head -c 128 /dev/zero > "$M/nested-2/a/b/x.safetensors"
check "one buried deeper is not"           "" \
    "$(cad_call_lib aichat.model.library.sh model_engine "$M/nested-2")"

section "engines are named the way a person reads them"
check "gguf"        "GGUF (llama-server)"           "$(cad_call_lib aichat.model.library.sh model_engine_label gguf)"
check "mlx"         "MLX (in-process)"              "$(cad_call_lib aichat.model.library.sh model_engine_label mlx)"
check "foundation"  "Foundation Models (on device)" "$(cad_call_lib aichat.model.library.sh model_engine_label foundation)"
check "anything else" "an unrecognized engine"      "$(cad_call_lib aichat.model.library.sh model_engine_label wat)"

section "labelling a model"
check "the on-device model" "Apple Foundation Models" \
    "$(cad_call_lib aichat.model.library.sh model_display_label "$FOUNDATION")"
# The filename carries the quantisation, which is exactly what the user is choosing between.
check "a gguf keeps its quant" "Qwen3-4B-Q5_K_S" \
    "$(cad_call_lib aichat.model.library.sh model_display_label "$M/Qwen3-4B-Q5_K_S.gguf")"
check "an HF snapshot becomes org/name" "mlx-community/Llama-3.2-3B-Instruct-4bit" \
    "$(cad_call_lib aichat.model.library.sh model_display_label \
        "/cache/models--mlx-community--Llama-3.2-3B-Instruct-4bit/snapshots/abc123")"
check "anything else is its basename" "some-model" \
    "$(cad_call_lib aichat.model.library.sh model_display_label "/opt/some-model")"

section "a gguf inside an HF snapshot is still labelled by its quant"
# THE ORDER-DEPENDENT ONE. A GGUF downloaded from HF lives under models--org--name/snapshots/,
# so it matches the snapshot pattern too. If that branch ran first, every quant of the same
# repo would collapse to one identical row label - and the quant is the only thing telling
# those rows apart.
check "the quant wins over the repo name" "Llama-3.2-3B-Instruct-Q4_K_M" \
    "$(cad_call_lib aichat.model.library.sh model_display_label \
        "/cache/models--bartowski--Llama-3.2-3B-Instruct/snapshots/deadbeef/Llama-3.2-3B-Instruct-Q4_K_M.gguf")"

section "measuring a model on disk"
check "a gguf is its file size" "2048" \
    "$(cad_call_lib aichat.model.library.sh model_bytes "$M/Qwen3-4B-Q5_K_S.gguf")"
check "an mlx model is the sum of its shards" "4096" \
    "$(cad_call_lib aichat.model.library.sh model_bytes "$M/mlx-model")"
check "an unrecognized path measures zero"    "0" \
    "$(cad_call_lib aichat.model.library.sh model_bytes "$M/nope")"
# Unbounded on purpose here, unlike the detection scan: a 30GB model reported as 0 would
# silently defeat the RAM warning, which is the only guard between the user and a swap storm.
/usr/bin/head -c 256 /dev/zero > "$M/nested-2/a/b/y.safetensors"
check "shards at any depth are counted" "384" \
    "$(cad_call_lib aichat.model.library.sh model_dir_bytes "$M/nested-2")"

section "which engine a chat window is driving"
# The harness's own uuid, not an invented name: it is unique per file and per run, so these
# per-window keys cannot collide with a concurrent run or linger in the shared namespace.
W="$OMC_ACTIONUI_WINDOW_UUID"
cad_pb_set "aichatv2_agent_$W" ""
cad_pb_set "aichatv2_modelpath_$W" ""
check "neither stamped means nothing to say" "" "$(cad_call_lib aichat.model.library.sh chat_engine_label "$W")"
cad_pb_set "aichatv2_modelpath_$W" "$M/Qwen3-4B-Q5_K_S.gguf"
check "a local model is named by its label" "Qwen3-4B-Q5_K_S" \
    "$(cad_call_lib aichat.model.library.sh chat_engine_label "$W")"
cad_pb_set "aichatv2_agent_$W" "Claude Code"
# chat.init stamps exactly one of the two and blanks the other, but the ORDER still matters:
# an external window has no model path at all, and reading the model first is what used to
# leave these call sites with a bare "New conversation" and nothing after it.
check "an agent wins over a stale model path" "Claude Code" \
    "$(cad_call_lib aichat.model.library.sh chat_engine_label "$W")"

section "the info strip's suffix"
# The separator is U+00B7 written as its UTF-8 bytes, so this file stays ASCII while still
# asserting the exact string the applet emits.
sep=$(printf '\302\267')
check "for an agent" "   $sep   Agent: Claude Code" \
    "$(cad_call_lib aichat.model.library.sh chat_engine_info_suffix "$W")"
cad_pb_set "aichatv2_agent_$W" ""
check "for a model" "   $sep   Model: Qwen3-4B-Q5_K_S" \
    "$(cad_call_lib aichat.model.library.sh chat_engine_info_suffix "$W")"
cad_pb_set "aichatv2_modelpath_$W" ""
check "for neither" "" "$(cad_call_lib aichat.model.library.sh chat_engine_info_suffix "$W")"

section "whether to offer the on-device model at all"
# A DENYLIST, and the direction is the whole design. Reasons arrive from the agent verbatim,
# and its documented contract is that codes are ADDED rather than renamed - so an allowlist
# would hide the row for any code a newer macOS introduces, retiring the feature on exactly
# the systems that just gained a new state.
for r in available appleIntelligenceOff modelNotReady unknown timedOut probeFailed; do
    check "  $r is offered" "0" "$(cad_call_lib aichat.model.library.sh foundation_offerable "$r"; echo $?)"
done
check "a code this build has never heard of is offered" "0" \
    "$(cad_call_lib aichat.model.library.sh foundation_offerable someFutureReason; echo $?)"
for r in deviceNotEligible osTooOld notBuilt; do
    check "  $r is not" "1" "$(cad_call_lib aichat.model.library.sh foundation_offerable "$r"; echo $?)"
done

section "totalling the RAM held by running models"
# Built against a registry this test wrote, not the developer's own - see cad_model_call.
REG="$OMCTEST_WORK/servers.plist"
/bin/rm -f "$REG"
P="$OMC_OMC_SUPPORT_PATH/plister"
"$P" set dict "$REG" / >/dev/null 2>&1
"$P" insert "server-hosts" dict "$REG" / >/dev/null 2>&1
"$P" insert "server-info"  dict "$REG" / >/dev/null 2>&1
"$P" insert "$$" dict "$REG" /server-hosts >/dev/null 2>&1
"$P" insert "$$" string "$M/Qwen3-4B-Q5_K_S.gguf" "$REG" "/server-hosts/$$" >/dev/null 2>&1
"$P" insert "$$" dict "$REG" /server-info >/dev/null 2>&1
"$P" insert "size" string "1000" "$REG" "/server-info/$$" >/dev/null 2>&1
CAD_PREFS_OVERRIDE="$REG"; export CAD_PREFS_OVERRIDE
check "a live server counts" "1000" "$(cad_model_call calculate_total_server_ram)"
CAD_PREFS_OVERRIDE="$OMCTEST_WORK/no-such-registry.plist"; export CAD_PREFS_OVERRIDE
check "no registry means nothing running" "0" "$(cad_model_call calculate_total_server_ram)"

section "a dead process does not hold RAM"
# The registry outlives the processes it lists - a crash leaves entries behind - so every row
# is confirmed against the live process table. Without that the warning would fire on memory
# nothing is using, and the user would be told to close windows that are already closed.
DEAD="$OMCTEST_WORK/servers-dead.plist"
/bin/rm -f "$DEAD"
"$P" set dict "$DEAD" / >/dev/null 2>&1
"$P" insert "server-hosts" dict "$DEAD" / >/dev/null 2>&1
"$P" insert "server-info"  dict "$DEAD" / >/dev/null 2>&1
"$P" insert "999999" dict "$DEAD" /server-hosts >/dev/null 2>&1
"$P" insert "999998" string "$M/Qwen3-4B-Q5_K_S.gguf" "$DEAD" /server-hosts/999999 >/dev/null 2>&1
"$P" insert "999998" dict "$DEAD" /server-info >/dev/null 2>&1
"$P" insert "size" string "5000" "$DEAD" /server-info/999998 >/dev/null 2>&1
CAD_PREFS_OVERRIDE="$DEAD"; export CAD_PREFS_OVERRIDE
check "a stale registration counts for nothing" "0" "$(cad_model_call calculate_total_server_ram)"

section "each liveness guard is reachable on its own"
# The registry is filtered twice - the HOST app must be alive (/bin/ps) and each SERVER must be
# alive (kill -0). The dead fixture above has both pids dead, so either guard alone produces 0
# and removing either one is invisible; measured. These two isolate them: one live host with a
# dead server, one dead host with a live server. $$ is this test process, which is alive by
# definition; 999999 is above macOS pid_max, so it cannot be recycled into existence.
mk_registry() { # <file> <host-pid> <server-pid> <size>
    /bin/rm -f "$1"
    "$P" set dict "$1" / >/dev/null 2>&1
    "$P" insert "server-hosts" dict "$1" / >/dev/null 2>&1
    "$P" insert "server-info"  dict "$1" / >/dev/null 2>&1
    "$P" insert "$2" dict "$1" /server-hosts >/dev/null 2>&1
    "$P" insert "$3" string "/m/x.gguf" "$1" "/server-hosts/$2" >/dev/null 2>&1
    "$P" insert "$3" dict "$1" /server-info >/dev/null 2>&1
    "$P" insert "size" string "$4" "$1" "/server-info/$3" >/dev/null 2>&1
}
mk_registry "$OMCTEST_WORK/live-host-dead-server.plist" "$$" 999998 7000
CAD_PREFS_OVERRIDE="$OMCTEST_WORK/live-host-dead-server.plist"; export CAD_PREFS_OVERRIDE
check "a live host with a dead server counts nothing" "0" "$(cad_model_call calculate_total_server_ram)"
mk_registry "$OMCTEST_WORK/dead-host-live-server.plist" 999999 "$$" 7000
CAD_PREFS_OVERRIDE="$OMCTEST_WORK/dead-host-live-server.plist"; export CAD_PREFS_OVERRIDE
check "a dead host with a live server counts nothing" "0" "$(cad_model_call calculate_total_server_ram)"
mk_registry "$OMCTEST_WORK/both-live.plist" "$$" "$$" 7000
CAD_PREFS_OVERRIDE="$OMCTEST_WORK/both-live.plist"; export CAD_PREFS_OVERRIDE
check "  positive control: both alive does count" "7000" "$(cad_model_call calculate_total_server_ram)"

section "the RAM-pressure warning"
CAD_PREFS_OVERRIDE="$OMCTEST_WORK/no-such-registry.plist"; export CAD_PREFS_OVERRIDE
alerts_reset; alert_answers_reset
check "a model of unknown size does not warn" "0" \
    "$(cad_model_call warn_ram_pressure_for_new_model 0 "Tiny"; echo $?)"
check "  and raises no alert"                 "0" "$(alerts_count)"
check "a non-numeric size does not warn"      "0" \
    "$(cad_model_call warn_ram_pressure_for_new_model "" "Tiny"; echo $?)"
check "  still no alert"                      "0" "$(alerts_count)"
check "a model that fits does not warn"       "0" \
    "$(cad_model_call warn_ram_pressure_for_new_model 1048576 "Tiny"; echo $?)"
check "  still no alert"                      "0" "$(alerts_count)"

section "a model too big for this Mac asks first"
alerts_reset; alert_answers_reset
HUGE=999999999999
alert_answer 0
check "Load Anyway proceeds" "0" "$(cad_model_call warn_ram_pressure_for_new_model "$HUGE" "Enormous-70B"; echo $?)"
check "  and the user was asked" "1" "$(alerts_count)"
check "  about that model by name" "1" "$(alerts_mention 'Enormous-70B')"
alerts_reset; alert_answers_reset
alert_answer 1
check "Cancel refuses the load" "1" "$(cad_model_call warn_ram_pressure_for_new_model "$HUGE" "Enormous-70B"; echo $?)"
check "  and the user was asked once" "1" "$(alerts_count)"

section "loading a model that is already running activates its window"
CAD_PREFS_OVERRIDE="$REG"; export CAD_PREFS_OVERRIDE
"$P" insert "dialog" string "chat-window-7" "$REG" "/server-info/$$" >/dev/null 2>&1
cad_ui_reset
check "the running model is recognized" "0" \
    "$(cad_model_call activate_if_model_running "$M/Qwen3-4B-Q5_K_S.gguf" "$OMC_ACTIONUI_WINDOW_UUID" >/dev/null; echo $?)"
check "  the selector is closed"        "1" "$(ui_calls omc_terminate_ok)"
check "  and the chat window raised"    "1" "$(ui_calls omc_select)"
cad_ui_reset
# activate_if_model_running carries its OWN copy of the two liveness guards, and the fixture
# above uses $$ for both host and server - so either could be deleted unnoticed. These aim at
# each in turn: a registration is only live when BOTH ends are.
mk_registry "$OMCTEST_WORK/act-live-host.plist" "$$" 999998 100
CAD_PREFS_OVERRIDE="$OMCTEST_WORK/act-live-host.plist"; export CAD_PREFS_OVERRIDE
check "a live host with a dead server is not running" "1" \
    "$(cad_model_call activate_if_model_running "/m/x.gguf" "$OMC_ACTIONUI_WINDOW_UUID" >/dev/null; echo $?)"
mk_registry "$OMCTEST_WORK/act-dead-host.plist" 999999 "$$" 100
CAD_PREFS_OVERRIDE="$OMCTEST_WORK/act-dead-host.plist"; export CAD_PREFS_OVERRIDE
check "a dead host with a live server is not running" "1" \
    "$(cad_model_call activate_if_model_running "/m/x.gguf" "$OMC_ACTIONUI_WINDOW_UUID" >/dev/null; echo $?)"
CAD_PREFS_OVERRIDE="$REG"; export CAD_PREFS_OVERRIDE
check "a different model is not running" "1" \
    "$(cad_model_call activate_if_model_running "$M/other.gguf" "$OMC_ACTIONUI_WINDOW_UUID" >/dev/null; echo $?)"
check "  so nothing is closed"           "0" "$(ui_calls omc_terminate_ok)"
# Deliberately NOT unset: cad_* wrappers now fail closed anyway, but leaving the override
# in place keeps anything appended below this line pointed away from the real registry.

section "cumulative: no handler wrote to a view id the window does not declare"
# cad_unknown_writes_all, not ui_unknown_writes: ui_reset DELETES unknown_ids.log along with
# the windows, so the plain form covers only what happened since the last reset - which in a
# file that resets per section is close to nothing. Measured: a handler scribbling on a
# made-up view id went entirely unnoticed by the plain form.
check "no undeclared ids" "" "$(cad_unknown_writes_all)"
check "no table clobbered by a bare value write" "" "$(cad_suspect_writes_all)"

omctest_end
