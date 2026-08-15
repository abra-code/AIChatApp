#!/bin/sh
# aichat.select.local.model.benchmark.sh
# Runs a prefill/generate benchmark for the selected model and shows the result in the
# picker's Benchmark pane. GGUF benches against the bundled llama-server launched with the
# SAME GPU memory policy as a real chat window (compute_server_memory_args), so the numbers
# reflect what the app will actually deliver; MLX benches via mlx-agent bench. Results are
# persisted with machine info by aichat.bench.py and reloaded on selection.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.server.library.sh"

echo "[$(/usr/bin/basename "$0")]"

BENCH_TEXT_ID=50
BENCH_BTN_ID=51
BENCH_RUNNING_TTL=7200
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Column 3 (hidden) holds the full model path
selected_path="$OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE"
[ -n "$selected_path" ] || { echo "no selection"; exit 0; }
# The on-device model answers before the -e test below, which would otherwise call it "no longer
# on disk" - it was never on our disk. The button is disabled for this row, so this is reachable
# only by the re-enable at the end of a run that started on another model.
if [ "$(model_engine "$selected_path")" = "foundation" ]; then
    "$dialog_tool" "$window_uuid" $BENCH_TEXT_ID \
        "Benchmarking measures a model this Mac loads. The on-device model belongs to the system, so there is nothing here to measure."
    exit 0
fi
if [ ! -e "$selected_path" ]; then
    "$dialog_tool" "$window_uuid" $BENCH_TEXT_ID "The selected model is no longer on disk."
    exit 0
fi

# One benchmark at a time per window. The stamp is epoch-suffixed and TTL-bounded so a
# killed handler (SIGKILL skips the trap) can't wedge the window's benchmarking forever.
running_key="aichatv2_bench_running_${window_uuid}"
prev=$(pb_get "$running_key")
if [ -n "$prev" ]; then
    prev_epoch="${prev##*|}"
    case "$prev_epoch" in *[!0-9]*|"") prev_epoch=0 ;; esac
    if [ $(( $(/bin/date +%s) - prev_epoch )) -le "$BENCH_RUNNING_TTL" ]; then
        echo "benchmark already running for this window"
        exit 0
    fi
    echo "ignoring stale running stamp"
fi
pb_set "$running_key" "${selected_path}|$(/bin/date +%s)"
# launch_lock_release is ownership-guarded (no-op unless this process holds the lock), so
# it is safe in the trap: a TERM while we hold the lock releases it instead of leaving a
# stale dir for the 60 s steal to clean up.
trap 'pb_set "$running_key" ""; launch_lock_release' EXIT

engine=$(model_engine "$selected_path")
label=$(model_display_label "$selected_path")
db="$HOME/Library/Application Support/Cadabra/benchmarks.json"
py="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
helper="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.bench.py"

"$dialog_tool" "$window_uuid" $BENCH_BTN_ID omc_disable
"$dialog_tool" "$window_uuid" $BENCH_TEXT_ID "Benchmarking ${label}… This can take several minutes for large models; the app stays usable meanwhile."

# ── Launch under the same lock real chat launches hold ────────────────────────
# The sibling scan must not race a concurrent chat-window launch (both would see a world
# without the other's server and overcommit the GPU). The helper prints "launching:" to
# stderr immediately before spawning its engine process, so hold the lock from the policy
# scan until shortly after that line appears, then let the helper run to completion.
err_file=$(/usr/bin/mktemp)
out_file=$(/usr/bin/mktemp)

launch_lock_acquire

mem_args=""
note=""
if [ "$engine" = "gguf" ]; then
    mem_args=$(compute_server_memory_args "$selected_path")
    echo "benchmarking gguf with policy: $mem_args"
    # CPU-fallback numbers must not masquerade as this Mac's GPU speed for the model.
    case "$mem_args" in *"--fit off"*) note="GPU busy - measured on CPU fallback" ;; esac
    "$py" "$helper" run --engine gguf --model "$selected_path" \
        --llama-server "$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server" \
        --server-args "$mem_args" --db "$db" --label "$label" \
        --note "$note" >"$out_file" 2>"$err_file" &
else
    "$py" "$helper" run --engine mlx --model "$selected_path" \
        --mlx-agent "$OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent" \
        --db "$db" --label "$label" >"$out_file" 2>"$err_file" &
fi
helper_pid=$!

# Release the lock once the engine process exists (helper logs "launching:" just before
# spawning it) or the helper died early; cap the hold at 30 s so a wedged helper can
# never block real launches.
held=0
while [ "$held" -lt 30 ]; do
    /usr/bin/grep -q "^launching:" "$err_file" 2>/dev/null && { sleep 1; break; }
    kill -0 "$helper_pid" 2>/dev/null || break
    sleep 1; held=$((held + 1))
done
launch_lock_release

wait "$helper_pid"
rc=$?
out=$(/bin/cat "$out_file")
/bin/cat "$err_file" >&2

# Repaint and re-enable against the CURRENT selection: the run took minutes and the user
# may have moved on (selection.changed leaves the button alone while we're running).
current=$(pb_get "aichatv2_selected_model_${window_uuid}")
# Non-empty is not enough: the on-device row stamps a non-empty SENTINEL, so a run that finishes
# while it is selected would re-enable a button that row deliberately disables.
if [ -n "$current" ] && [ "$(model_engine "$current")" != "foundation" ]; then
    "$dialog_tool" "$window_uuid" $BENCH_BTN_ID omc_enable
fi
if [ "$current" = "$selected_path" ]; then
    if [ "$rc" = 0 ] && [ -n "$out" ]; then
        "$dialog_tool" "$window_uuid" $BENCH_TEXT_ID markdown "$out"
    else
        err_tail=$(/usr/bin/tail -2 "$err_file" 2>/dev/null | /usr/bin/tr '\n' ' ')
        "$dialog_tool" "$window_uuid" $BENCH_TEXT_ID "Benchmark failed. ${err_tail}"
    fi
else
    echo "selection moved on; result stored, pane left alone"
fi
/bin/rm -f "$err_file" "$out_file"
