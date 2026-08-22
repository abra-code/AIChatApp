#!/bin/sh
# aichat.server.library.sh
# Lifecycle of a chat session's server processes: free-port selection, the llama-server
# launch / health-probe / registration path, and reaping orphaned bundle processes.
# Sources aichat.mcp.servers.library.sh (the MCP prefs + generate_stdio_mcp_config the
# transport builder needs), which in turn sources the base library. Sourced by
# aichat.init (launch), aichat.cancel and app.will.terminate (teardown). NOT by the MCP
# inspector: it is stdio-based (mlx-agent tools) and sources only
# aichat.mcp.servers.library.sh.
#
# The mcp-proxy era is fully retired: mlx-agent owns the MCP stdio children now, the
# proxy launch/kill/reap machinery was removed with it, and the mcp-proxy package is no
# longer bundled. See Private/commit-notes-drop-mcp-proxy.md.
[ -n "${__AICHAT_SERVER_LIB:-}" ] && return 0
__AICHAT_SERVER_LIB=1
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"

# ──────────────────────────────────────────────────────────────
# Server-lifecycle debug log (opt-in orphan-cleanup diagnostics)
# ──────────────────────────────────────────────────────────────
# `touch /tmp/aichatv2_srvdbg` to enable; APPENDS to /tmp/aichatv2_srvdbg.log across ALL
# sessions (launch, model switch, window close, app quit) so an orphaned-server bug that only
# shows after several sessions is captured. `rm /tmp/aichatv2_srvdbg` to stop. The key signal:
# the OMC_FRONT_PROCESS_ID recorded as the registry host at LAUNCH vs. its value (and the real
# app pid) at TERMINATE - if they diverge, the teardown cannot recognise its own servers.
srvlog() {
    [ -f /tmp/aichatv2_srvdbg ] || return 0
    printf '%s [script=%s] %s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$$" "$*" \
        >> /tmp/aichatv2_srvdbg.log 2>/dev/null
}
# Live pids of THIS bundle's app executable - the real app-instance pid(s), to compare against
# the OMC_FRONT_PROCESS_ID stored as the registry host.
srvlog_apppids() { /usr/bin/pgrep -f "${OMC_APP_BUNDLE_PATH}/Contents/MacOS/" 2>/dev/null | /usr/bin/tr '\n' ',' ; }
# Registered host pids, and this bundle's live llama-server pids (comma-joined).
srvlog_hosts()   { [ -f "$prefs" ] && "$plister" get keys "$prefs" "/server-hosts" 2>/dev/null | /usr/bin/tr '\n' ',' ; }
srvlog_servers() { /usr/bin/pgrep -f "${OMC_APP_BUNDLE_PATH}/Contents/Support/Llama.cpp/llama-server" 2>/dev/null | /usr/bin/tr '\n' ',' ; }

# ──────────────────────────────────────────────────────────────
# Server management
# ──────────────────────────────────────────────────────────────

# find_free_port_in <start> <end>
# Returns the first unused port in [start, end], or empty string if all taken.
find_free_port_in() {
    local port="$1"
    local end="$2"
    while [ "$port" -le "$end" ]; do
        if ! /usr/sbin/lsof -ti tcp:"$port" > /dev/null 2>&1; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
    done
    echo ""
    return 1
}

# forget_server_host_entry <server_pid>
# Deletes a server's /server-hosts/<host>/<server> registration wherever it lives.
# Called after a server is found dead so no stale host->server mapping survives while
# the app keeps running (the host-level reapers only prune entries of dead *hosts*).
forget_server_host_entry() {
    local target_pid="$1"
    [ -z "$target_pid" ] && return 0
    local host_pids
    host_pids=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null) || return 0
    local _fh_host_pid _fh_remaining
    while IFS= read -r _fh_host_pid; do
        [ -z "$_fh_host_pid" ] && continue
        "$plister" delete "$prefs" "/server-hosts/$_fh_host_pid/$target_pid" 2>/dev/null
        # Drop the host dict too if this was its last server, so a host that outlives its only
        # server (e.g. a sibling-safe reap while the host is still alive) leaves no empty cruft.
        _fh_remaining=$("$plister" get keys "$prefs" "/server-hosts/$_fh_host_pid" 2>/dev/null)
        [ -z "$_fh_remaining" ] && "$plister" delete "$prefs" "/server-hosts/$_fh_host_pid" 2>/dev/null
    done <<< "$host_pids"
}

# ──────────────────────────────────────────────────────────────
# Orphaned bundle-process reaping (registry-independent safety net)
# ──────────────────────────────────────────────────────────────
#
# Four kinds of process run out of THIS app bundle and can outlive the session that
# started them:
#   • llama-server       ($OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server)
#     — the model server, one per chat window, launched with '&' from the init handler
#   • mlx-agent          ($OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent) — the
#     Chat element's ACP child, owner of the session's MCP stdio servers
#   • the bundled Python ($OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3)
#     — the time / search MCP servers, children of mlx-agent
#   • replay             ($OMC_APP_BUNDLE_PATH/Contents/Support/replay) — the Local
#     (files & shell) MCP server, a child of mlx-agent
#
# A llama-server reparents to launchd (PPID 1) once its init handler exits, so the
# pid-registry teardown (stop_orphaned_servers / the cancel & terminate handlers)
# reaches it only through a stored pid. mlx-agent's MCP children reparent to launchd
# when the agent dies without tearing them down (a wedged agent, a crash). Those links
# break in known ways: a session quit before the model finished loading never
# registered its server at all; an app force-quit / crash skips the terminate handler
# completely. The leftover llama-server / python3 / replay processes seen after the app
# is gone are exactly these.
#
# reap_orphaned_bundle_processes() is the net that needs no stored child pids. It scans
# for any bundled executable reparented to launchd (PPID 1 — "no running parent") and
# kills the ones not belonging to a still-running session. Ownership is keyed on the
# HOST app, exactly as the registry records it under /server-hosts: a llama-server is
# kept only while the host app that launched it is alive. MCP servers never need
# shielding: while their session lives they are children of a live mlx-agent (not PPID
# 1), so they never match the gate. Everything else at PPID 1 in a bundled dir is an
# orphan, reaped together with its subtree (a still-alive orphaned parent's children
# have that parent — not 1 — as their PPID, so they are snapshotted before signalling).
#
# The PPID-1 gate is what makes this safe to run at any moment, including mid-launch: a
# server stays a child of the (still-running) init handler until that handler exits,
# and the handler only exits AFTER registering it — so a wanted process is never
# simultaneously PPID 1 and unregistered. Transient bundled-python helpers
# (generate_mcp_configs.py) likewise always have a living parent and never match the
# gate. Because ownership is decided by host liveness, correctness does not depend on
# running order relative to the registry reapers — those still run first to keep the
# on-disk registry tidy.

# _bundle_managed_process <args-string>
# 0 if the command's executable lives in a swept bundle dir (llama-server, bundled
# python, replay, or mlx-agent). Matches the START of the whole argument string, so a bundle
# path containing spaces is handled and a path that only appears as a later argument is not
# mistaken for the executable.
#
# mlx-agent normally needs no sweeping: it is the Chat element's ACP child, so its stdin
# closes when the app goes away and it exits on its own (verified on a hard kill of the
# app). It is swept anyway for the case that self-teardown cannot cover - an agent wedged
# mid-generation, or one whose own MCP children outlive it - since a survivor would hold the
# session's MCP servers open. Sweeping it also reaps the agent's descendants (replay, the
# bundled python servers), which the two classes above already match.
_bundle_managed_process() {
    case "$1" in
        "$OMC_APP_BUNDLE_PATH/Contents/Library/Python/"*)                 return 0 ;;
        "$OMC_APP_BUNDLE_PATH/Contents/Support/replay"|\
        "$OMC_APP_BUNDLE_PATH/Contents/Support/replay "*)                 return 0 ;;
        "$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server"|\
        "$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server "*) return 0 ;;
        "$OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent"|\
        "$OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent "*)          return 0 ;;
    esac
    return 1
}

# _collect_descendants <pid>  ->  prints every descendant pid, one per line.
_collect_descendants() {
    local _cd_kid
    for _cd_kid in $(/usr/bin/pgrep -P "$1" 2>/dev/null); do
        echo "$_cd_kid"
        _collect_descendants "$_cd_kid"
    done
}

reap_orphaned_bundle_processes() {
    [ -n "$OMC_APP_BUNDLE_PATH" ] || return 0
    echo "Reaping orphaned bundle processes (llama-server / MCP servers / mlx-agent) with no running parent"

    # Protected pids: the llama-servers of still-running sessions, keyed on host
    # liveness (see header). A server is shielded only while its host app is alive.
    # MCP servers need no shielding: a live session's servers are children of a live
    # mlx-agent, so they never sit at PPID 1.
    # Space-padded for whole-token matching below (" 501 502 ").
    local protected=" "
    if [ -f "$prefs" ]; then
        local _rp_hosts _rp_host _rp_servers _rp_server
        _rp_hosts=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
        while IFS= read -r _rp_host; do
            [ -z "$_rp_host" ] && continue
            kill -0 "$_rp_host" 2>/dev/null || continue          # host app gone -> its session is orphaned
            _rp_servers=$("$plister" get keys "$prefs" "/server-hosts/$_rp_host" 2>/dev/null)
            while IFS= read -r _rp_server; do
                [ -z "$_rp_server" ] && continue
                kill -0 "$_rp_server" 2>/dev/null || continue    # already dead -> nothing to shield
                protected="${protected}${_rp_server} "           # keep this llama-server
            done <<< "$_rp_servers"
        done <<< "$_rp_hosts"
    fi

    # Scan every process; an orphan is a swept-dir executable reparented to launchd
    # (PPID 1) that is not in the protected set.
    local victims="" _rp_pid _rp_ppid _rp_args
    while read -r _rp_pid _rp_ppid _rp_args; do
        [ "$_rp_ppid" = "1" ] || continue
        _bundle_managed_process "$_rp_args" || continue
        case "$protected" in *" $_rp_pid "*) continue ;; esac
        echo "  orphan pid=$_rp_pid: $_rp_args"
        victims="${victims:+$victims }$_rp_pid"
    done <<< "$(/bin/ps -A -o pid=,ppid=,args=)"

    [ -z "$victims" ] && { echo "  none found"; return 0; }

    # Expand each victim to its full subtree first: a still-alive orphaned parent (a
    # wedged mlx-agent) has children whose PPID is that parent (not 1), so they were
    # skipped above — snapshot them before signalling, since they reparent to launchd
    # once the parent dies.
    local kill_set="$victims" _rp_v _rp_desc _rp_d
    for _rp_v in $victims; do
        _rp_desc=$(_collect_descendants "$_rp_v")
        for _rp_d in $_rp_desc; do
            case " $kill_set " in *" $_rp_d "*) ;; *) kill_set="$kill_set $_rp_d" ;; esac
        done
    done

    echo "  reaping: $kill_set"
    for _rp_v in $kill_set; do kill -TERM "$_rp_v" 2>/dev/null; done
    sleep 0.5
    for _rp_v in $kill_set; do kill -KILL "$_rp_v" 2>/dev/null; done
}

# ──────────────────────────────────────────────────────────────
# Pinned-port model server launch (shared by chat init + model switch)
# ──────────────────────────────────────────────────────────────
# Factored out of aichat.chat.init.sh so the in-place model-switch handler
# (aichat.chat.switch.model.sh) can restart a window's server without duplicating the launch
# / health-probe / registration logic. Everything below uses the base-library globals
# ($prefs, $plister, $dialog, $alert, $APPLET_NAME) plus the explicit window UUID and port
# passed in, so it is window-agnostic and safe to call from a handler running in any window's
# context. The port is per-window now (multi-model), not a shared pin.

# kv_cache_scale <type> — bytes-per-element scale of a KV cache quant, relative to f16.
kv_cache_scale() {
    case "$1" in
        q4_0|iq4_nl) echo "0.28" ;;
        q4_1)        echo "0.31" ;;
        q5_0)        echo "0.34" ;;
        q5_1)        echo "0.38" ;;
        q8_0)        echo "0.53" ;;
        f32)         echo "2.00" ;;
        f16|bf16|*)  echo "1.00" ;;
    esac
}

# params_from_gguf_filename <model_path> — rough param count (billions) from the filename.
params_from_gguf_filename() {
    local model_path="$1"
    local filename=$(/usr/bin/basename "${model_path}")
    local size_label=$(echo "$filename" | /usr/bin/grep -oE '([0-9]+x)?[0-9]+\.?[0-9]*[Bb]' | /usr/bin/tail -n -1)
    if [[ "$size_label" == *x*B ]]; then
        size_label=$(echo "$size_label" | /usr/bin/grep -oE '[0-9]+\.?[0-9]*[Bb]')
    fi
    local number=$(echo "$size_label" | /usr/bin/grep -oE '[0-9]+\.?[0-9]*')
    local unit=$(echo "$size_label" | /usr/bin/grep -oE '[Bb]')
    if [ "$unit" = "B" ] || [ "$unit" = "b" ]; then
        printf "%.0f\n" "${number}"
        return 0
    fi
    echo "0"
}

# scan_engine_footprints [retiring_model_path] [retiring_window]
# Echoes TWO numbers: "<total> <retiring>" - the estimated wired GPU footprint in MiB of every
# engine already running on this machine, and how much of that total belongs to the one engine the
# caller says it is about to stop (0 when there is none, or when it cannot be identified). Never
# fails.
#
# Each engine's footprint is roughly its weights plus KV/compute overhead; 15% + 768 MiB errs on
# the safe side. The patterns match the binary BASENAME on purpose: orphaned llama-servers from
# OTHER bundles (v1.2, Enoch - see the orphan-cleanup notes) and MLXChat's mlx-agent hold GPU
# memory just the same, and a basename pattern also dodges ERE metacharacters in the bundle path.
# The argv --model validation filters out unrelated matches. The outgoing server on OUR port was
# already killed and waited out by launch_model_on_port.
#
# WHY THE SECOND NUMBER IS REPORTED RATHER THAN SUBTRACTED HERE. What may be discounted is a
# question about the machine's total RAM against the Metal cap, and those live in
# compute_server_memory_args. This scan answers what it can see; the policy on top of it is
# stated once, next to the numbers it depends on.
#
# WHICH PROCESS IS "THE ONE ABOUT TO STOP", and the answer depends entirely on whether the caller
# can NAME it. <retiring_window> is that claim, and passing it changes the rule rather than adding
# to it:
#
#   Window given: only the process whose argv carries --mcp-config .../Sessions/<window>/ counts,
#     and NO MATCH MEANS NO DISCOUNT. That marker is in an agent's argv exactly when its window
#     runs tools, so a caller that has one is a caller that can identify its own agent - and if it
#     is not there, that agent is already gone. Anything else running the same model belongs to
#     somebody else and is not about to free anything.
#
#   Window empty: the SINGLE live process running the retiring model path, or nothing. Two windows
#     on one MLX model with tools off produce two identical argvs, so the one that is leaving is
#     unidentifiable and charging both is the safe direction - which is what this did before either
#     argument existed.
#
# THE NO-MATCH HALF IS THE POINT, and it was missing from the first version of this. A window whose
# agent has already died still carries its model stamp, and a user whose composer is dead is
# exactly the user who reaches for the model picker. Its stamp then names a model ANOTHER window is
# running; under a plain "fall back to the path rule" that window's agent was the single match, and
# the discount was taken for weights nothing was about to free - permanently, since that agent
# never leaves. Refusing is right whenever the caller could have identified its own and did not.
#
# A window that runs tools but has NO MCP servers configured carries no --mcp-config either, so its
# caller passes no window and it lands on the path rule. That is the safe direction, and the same
# answer it got before any of this.
scan_engine_footprints() {
    local retiring="$1" retiring_win="$2"
    local others_mib=0 pid margs mpath msize charge
    local by_path_mib=0 by_path_seen=0 by_win_mib=0
    # The marker that identifies ONE window's agent. Only present when that window runs tools; an
    # agent launched without them carries no --mcp-config and falls through to the path rule.
    # Both, deliberately: the window identifies a retirement the CALLER has declared, and a window
    # passed without one would let a first load discount an agent that is not going anywhere.
    local win_marker=""
    [ -n "$retiring" ] && [ -n "$retiring_win" ] && win_marker="/Sessions/${retiring_win}/"
    for pid in $(/usr/bin/pgrep -f "[/]llama-server" 2>/dev/null); do
        margs=$(/bin/ps -p "$pid" -o args= 2>/dev/null)
        mpath="${margs##*--model }"
        case "$mpath" in *.gguf*) mpath="${mpath%%.gguf*}.gguf" ;; *) continue ;; esac
        [ -f "$mpath" ] || continue
        msize=$(/usr/bin/stat -f%z -L "$mpath" 2>/dev/null)
        [ -n "$msize" ] || continue
        charge=$(( msize / 1048576 * 115 / 100 + 768 ))
        others_mib=$(( others_mib + charge ))
        if [ -n "$retiring" ] && [ "$mpath" = "$retiring" ]; then
            by_path_seen=$(( by_path_seen + 1 )); by_path_mib="$charge"
        fi
    done
    # NOTE: sharded GGUFs (-00001-of-000NN.gguf) are counted by their first shard only.
    for pid in $(/usr/bin/pgrep -f "[/]mlx-agent" 2>/dev/null); do
        margs=$(/bin/ps -p "$pid" -o args= 2>/dev/null)
        case "$margs" in *"--model "*) ;; *) continue ;; esac
        mpath="${margs##*--model }"
        mpath="${mpath%% --*}"
        [ -d "$mpath" ] || continue
        # -L: HF-cache snapshot dirs are symlink farms into blobs/ - without it du says 0.
        msize=$(/usr/bin/du -skL "$mpath" 2>/dev/null | /usr/bin/awk '{print $1}')
        [ -n "$msize" ] || continue
        charge=$(( msize / 1024 * 115 / 100 + 768 ))
        others_mib=$(( others_mib + charge ))
        if [ -n "$retiring" ] && [ "$mpath" = "$retiring" ]; then
            by_path_seen=$(( by_path_seen + 1 )); by_path_mib="$charge"
        fi
        # Checked INDEPENDENTLY of the model path, and deliberately: this window's agent is running
        # whatever this window's agent is running, and the caller's stamp is only its own record of
        # that. If the two ever disagree, the process is the fact.
        case "$margs" in
            *"$win_marker"*) [ -n "$win_marker" ] && by_win_mib="$charge" ;;
        esac
    done

    # The window rule REPLACES the path rule rather than preceding it. See the header: a caller
    # holding a marker that matches nothing has learned its own agent is gone, which is the one
    # answer a fallback to "the single process on that path" gets exactly backwards.
    local retiring_mib=0
    if [ -n "$win_marker" ]; then
        retiring_mib="$by_win_mib"
        if [ "$retiring_mib" = 0 ]; then
            srvlog "MEMPOLICY no live agent for window ${retiring_win}; discounting nothing"
        else
            srvlog "MEMPOLICY retiring engine identified by window ${retiring_win} mib=${retiring_mib}"
        fi
    elif [ "$by_path_seen" = 1 ]; then
        retiring_mib="$by_path_mib"
        srvlog "MEMPOLICY retiring engine identified by path [${retiring}] mib=${retiring_mib}"
    elif [ "$by_path_seen" -gt 1 ]; then
        srvlog "MEMPOLICY retiring engine [${retiring}] has ${by_path_seen} live processes; charging all"
    fi
    echo "$others_mib $retiring_mib"
}

# retiring_discount_mib <retiring_mib> <ram_mib> <cap_mib>
# How much of a retiring engine's footprint a starting server may plan as free. Echoes a number.
#
# NOT ALL OF IT, AND THE REASON IS THE CLOCK. The engine being replaced does not stop when the
# sizing runs. It stops when the Chat element reconciles the transport that this launch is a
# prerequisite for - which is after launch_model_on_port returns, and that is after
# wait_for_server, whose limit scales with the model and reaches 300 s. The two engines are
# resident together for the whole load of the incoming one, not for a moment at the end of it.
#
# Metal caps ONE process's working set at cap_mib, so a discount of D lets the new server plan up
# to cap_mib - reserve_mib - (others - D). At the peak of the overlap the machine holds
# cap_mib - reserve_mib + D, leaving (ram_mib - cap_mib) + reserve_mib - D free. Past
# D = ram_mib - cap_mib - the slack the Metal cap deliberately leaves outside itself - the load
# eats into the display reserve, and far enough past it the transient demand exceeds physical RAM:
# a 12 GiB MLX model retiring under a large GGUF on a 32 GB machine would do exactly that, for
# minutes, which is the WindowServer starvation this whole policy exists to prevent.
#
# The clamp costs nothing in the case that motivated the discount - 5987 MiB against 8520 MiB of
# slack on that machine - and turns the unbounded version's worst case back into "the display
# reserve survives even at the peak".
retiring_discount_mib() {
    local want="$1" slack=$(( $2 - $3 ))
    [ "$want" -gt "$slack" ] && want="$slack"
    [ "$want" -lt 0 ] && want=0
    echo "$want"
}

# ---------------------------------------------------------------------------------------
# GPU memory policy (Apple Silicon).
#
# Metal caps a process's GPU working set at roughly 74% of unified memory. llama-server's
# --fit machinery sizes layer offload and context against that cap by actually measuring
# device memory, but it is blind to two things this policy corrects (both confirmed by
# experiment on a 24 GB M5, where they show up as screen flashing / on-screen artifacts
# from a starved WindowServer):
#
#   1. Sibling llama-servers. Each server sees the FULL cap as "free device memory", so
#      with one server per window the fleet overcommits the GPU.
#   2. The display server itself. --fit's default free-memory margin is 1024 MiB, which
#      is not enough headroom for WindowServer + compositor on small-RAM machines.
#
# A third, independent failure is mmap: the Metal backend wires the ENTIRE mapped model
# file into the GPU working set even when --fit offloads only some layers, so a model
# whose file is near or above the cap fails every command buffer with
# kIOGPUCommandBufferCallbackErrorOutOfMemory no matter how few layers it offloads
# (observed with gemma-4-31B Q4_K_M, 17.8 GiB, on the 24 GB M5: -ngl 8 still OOMs;
# --no-mmap fixes it).
#
# compute_server_memory_args <model_path> [retiring_model_path] [retiring_window]
# Echoes the llama-server arguments implementing the policy:
#   --fit-target <MiB>  display reserve (RAM/8, clamped to 2-6 GiB) + the estimated
#                       footprint of every live sibling server, less the one engine the
#                       caller says it is about to stop (clamped - see the body)
#   --fit-ctx 8192      --fit may shrink the context this far before dropping GPU layers
#   [--no-mmap]         added when the file might not fully offload inside the budget,
#                       so only the layers that actually run on the GPU get wired
# Context size is deliberately NOT set: -c defaults to the model's own training limit
# and --fit shrinks it against MEASURED device memory (KV + compute buffers included),
# which beats any shell-side estimate. The retired heuristic below used to fix
# --ctx-size at up to 131072 computed from total RAM, which --fit is not allowed to
# shrink - on small models that alone could blow the GPU budget.
#
# GPU-stress testing overrides: if /tmp/aichatv2_srvtune exists (and is owned by the
# user) it is sourced and may set TUNE_BASE_RESERVE_MB, TUNE_FIT_TARGET_MB,
# TUNE_NO_MMAP (1|0), TUNE_CTX, TUNE_EXTRA_ARGS. The chosen policy is srvlog'd as
# MEMPOLICY either way (touch /tmp/aichatv2_srvdbg to capture).
compute_server_memory_args() {
    local model_path="$1"
    local retiring="$2"
    local retiring_win="$3"
    local ls_bin="$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server"

    local ram_mib=$(( $(/usr/sbin/sysctl -n hw.memsize) / 1048576 ))
    local cap_mib=$(( ram_mib * 74 / 100 ))

    local reserve_mib=$(( ram_mib / 8 ))
    [ "$reserve_mib" -lt 2048 ] && reserve_mib=2048
    [ "$reserve_mib" -gt 6144 ] && reserve_mib=6144

    local others_mib retiring_mib
    read -r others_mib retiring_mib <<EOF
$(scan_engine_footprints "$retiring" "$retiring_win")
EOF

    local granted
    granted=$(retiring_discount_mib "$retiring_mib" "$ram_mib" "$cap_mib")
    [ "$granted" != "$retiring_mib" ] && \
        srvlog "MEMPOLICY retiring discount clamped ${retiring_mib} -> ${granted}"
    retiring_mib="$granted"
    others_mib=$(( others_mib - retiring_mib ))
    [ "$others_mib" -lt 0 ] && others_mib=0

    local fit_target_mib=$(( reserve_mib + others_mib ))

    # $TMPDIR is the per-user mode-700 temp dir, so unlike /tmp no other local user can
    # plant or swap the file (sourcing a /tmp path would be a TOCTOU hole). Non-numeric
    # values are ignored, not trusted: an arithmetic expansion error would kill the
    # whole launch handler.
    local tune_file="${TMPDIR:-/tmp}/aichatv2_srvtune"
    local TUNE_BASE_RESERVE_MB="" TUNE_FIT_TARGET_MB="" TUNE_NO_MMAP="" TUNE_CTX="" TUNE_EXTRA_ARGS=""
    if [ -f "$tune_file" ] && [ -O "$tune_file" ]; then
        . "$tune_file"
    fi
    case "$TUNE_BASE_RESERVE_MB" in *[!0-9]*) TUNE_BASE_RESERVE_MB="" ;; esac
    case "$TUNE_FIT_TARGET_MB" in *[!0-9]*) TUNE_FIT_TARGET_MB="" ;; esac
    case "$TUNE_CTX" in *[!0-9]*) TUNE_CTX="" ;; esac
    [ -n "$TUNE_BASE_RESERVE_MB" ] && fit_target_mib=$(( TUNE_BASE_RESERVE_MB + others_mib ))
    [ -n "$TUNE_FIT_TARGET_MB" ] && fit_target_mib="$TUNE_FIT_TARGET_MB"

    local model_mib=$(( $(/usr/bin/stat -f%z -L "$model_path" 2>/dev/null || echo 0) / 1048576 ))
    local budget_mib=$(( cap_mib - fit_target_mib ))
    local args

    if [ "$budget_mib" -le $(( model_mib / 2 )) ]; then
        # Deep starvation (siblings already own most of the GPU): don't hand --fit an
        # impossible target - its probe walk toward ngl 0 can trip a llama.cpp assert
        # (GGML_SCHED_MAX_SPLIT_INPUTS, seen with gemma-4-E2B behind a wired 31B) and
        # abort the server. Go explicit CPU with a modest context instead: slow, but the
        # display stays alive and nothing crashes. --no-op-offload keeps per-op traffic
        # off the already-saturated GPU.
        # --no-mmap also here: it is unverified whether Metal wraps the mapped file at
        # -ngl 0, and it makes the launch pick up the size-scaled health-wait limit.
        args="--fit off -ngl 0 --no-op-offload --no-mmap --ctx-size ${TUNE_CTX:-16384}"
        [ -n "$TUNE_EXTRA_ARGS" ] && args="$args $TUNE_EXTRA_ARGS"
        srvlog "MEMPOLICY CPU-FALLBACK ram=${ram_mib} cap=${cap_mib} reserve=${reserve_mib} others=${others_mib} retiring=${retiring_mib} target=${fit_target_mib} model_mib=${model_mib} budget=${budget_mib} args=[$args]"
        echo "$args"
        return 0
    fi

    local no_mmap=0
    [ $(( model_mib * 100 )) -gt $(( budget_mib * 85 )) ] && no_mmap=1
    [ -n "$TUNE_NO_MMAP" ] && no_mmap="$TUNE_NO_MMAP"

    args="--fit-target $fit_target_mib --fit-ctx 8192"
    [ "$no_mmap" = "1" ] && args="$args --no-mmap"
    [ -n "$TUNE_CTX" ] && args="$args --ctx-size $TUNE_CTX"
    [ -n "$TUNE_EXTRA_ARGS" ] && args="$args $TUNE_EXTRA_ARGS"

    srvlog "MEMPOLICY ram=${ram_mib} cap=${cap_mib} reserve=${reserve_mib} others=${others_mib} retiring=${retiring_mib} target=${fit_target_mib} model_mib=${model_mib} no_mmap=${no_mmap} budget=${budget_mib} args=[$args]"
    echo "$args"
}

# launch_lock_acquire / launch_lock_release — serialize sibling-scan + spawn across
# windows. Without it, two windows launching in the same moment both scan before either
# server process exists, both see others=0, and both fit to the full GPU - exactly the
# overcommit the policy exists to prevent. mkdir is the atomic primitive; locks older
# than 60 s (crashed handler) are stolen, and a waiter gives up after 30 s rather than
# deadlock a launch.
# LAUNCH_LOCK_OWNED guards release: a waiter that gives up proceeds UNLOCKED and must
# not rmdir the lock the real holder still owns. Stale locks are stolen with an atomic
# rename (only one contender's mv of the directory can succeed; losers loop) - a plain
# rmdir+mkdir steal would let two contenders both "win".
LAUNCH_LOCK_OWNED=0
launch_lock_acquire() {
    local lock="${TMPDIR:-/tmp}/aichatv2_launch.lock" waited=0 age
    while ! /bin/mkdir "$lock" 2>/dev/null; do
        age=$(( $(/bin/date +%s) - $(/usr/bin/stat -f%m "$lock" 2>/dev/null || echo 0) ))
        if [ "$age" -gt 60 ]; then
            if /bin/mv "$lock" "$lock.stale.$$" 2>/dev/null; then
                srvlog "LAUNCH-LOCK stole stale lock age=${age}s"
                /bin/rm -rf "$lock.stale.$$" 2>/dev/null
            fi
            continue
        fi
        [ "$waited" -ge 30 ] && { srvlog "LAUNCH-LOCK wait timed out, proceeding unlocked"; return 0; }
        sleep 1; waited=$((waited + 1))
    done
    LAUNCH_LOCK_OWNED=1
}
launch_lock_release() {
    [ "$LAUNCH_LOCK_OWNED" = "1" ] || return 0
    LAUNCH_LOCK_OWNED=0
    /bin/rmdir "${TMPDIR:-/tmp}/aichatv2_launch.lock" 2>/dev/null
}

# calculate_context_optimal_size <model_path> [cache_type_k] [cache_type_v]
# Largest context window that fits comfortably in unified memory for this model + KV quant.
# NOTE: retired from the launch path in favor of compute_server_memory_args + --fit (see
# the policy comment above) - kept, with its two helpers, for reference until the
# GPU-stress testing round confirms the measured policy on more machines.
calculate_context_optimal_size() {
    local model_path="$1"
    local cache_type_k="${2:-f16}"
    local cache_type_v="${3:-f16}"

    local file_size=$(/usr/bin/stat -f%z -L "${model_path}")
    local file_size_gb=$(echo "scale=2; ${file_size} / (1024 * 1024 * 1024)" | /usr/bin/bc -l)
    local model_memory_gb=$(echo "scale=2; ${file_size_gb} + 0.5" | /usr/bin/bc -l)

    local ram_bytes=$(/usr/sbin/sysctl -n hw.memsize)
    local ram_gb=$(echo "scale=0; ${ram_bytes} / (1024 * 1024 * 1024)" | /usr/bin/bc -l)
    local model_exceeds_ram=$(echo "scale=2; ${model_memory_gb} > (${ram_gb} - 2)" | /usr/bin/bc -l)

    if [ "$model_exceeds_ram" -eq 1 ]; then
        echo "4096"
        return 0
    fi

    local extra_ram_gb=$(echo "scale=2; ${ram_gb} - ${model_memory_gb}" | /usr/bin/bc -l)
    extra_ram_gb=$(printf "%.0f" "${extra_ram_gb}")

    local ram_reserve_gb=2
    if [ "${extra_ram_gb}" -ge "16" ]; then
        ram_reserve_gb=6
    elif [ "${extra_ram_gb}" -ge "12" ]; then
        ram_reserve_gb=5
    elif [ "${extra_ram_gb}" -ge "8" ]; then
        ram_reserve_gb=4
    elif [ "${extra_ram_gb}" -ge "6" ]; then
        ram_reserve_gb=3
    fi

    local available_for_context_gb=$(echo "scale=2; ${ram_gb} - ${model_memory_gb} - ${ram_reserve_gb}" | /usr/bin/bc -l)

    local param_count=$(params_from_gguf_filename "${model_path}")
    local gb_per_thousand="0.13"
    if [ "${param_count}" -ge "60" ]; then
        gb_per_thousand="0.31"
    elif [ "${param_count}" -ge "25" ]; then
        gb_per_thousand="0.25"
    elif [ "${param_count}" -ge "12" ]; then
        gb_per_thousand="0.19"
    fi

    local scale_k=$(kv_cache_scale "$cache_type_k")
    local scale_v=$(kv_cache_scale "$cache_type_v")
    local gb_per_thousand_effective=$(echo "scale=4; ${gb_per_thousand} * (${scale_k} + ${scale_v}) / 2" | /usr/bin/bc -l)

    local context_per_gb=$(echo "scale=2; 1000 / ${gb_per_thousand_effective}" | /usr/bin/bc -l)
    local context_size=$(echo "scale=2; ${available_for_context_gb} * ${context_per_gb}" | /usr/bin/bc -l)
    local size_kb=$(echo "scale=0; ${context_size}/1024" | /usr/bin/bc -l)
    local ctx=$(( size_kb * 1024 ))

    [ "${ctx}" -lt 4096   ] && ctx=4096
    [ "${ctx}" -gt 131072 ] && ctx=131072
    echo "${ctx}"
    return 0
}

# register_started_server <host_pid> <server_pid> <model_path> <dialog_guid> <port> <size>
register_started_server() {
    local host_pid="$1"
    local server_pid="$2"
    local model_path="$3"
    local dialog_guid="$4"
    local server_port="$5"
    local model_size="$6"

    if ! [ -f "$prefs" ]; then
        "$plister" set dict "$prefs" '/'
    fi
    "$plister" get type "$prefs" '/server-hosts' >/dev/null 2>&1 || \
        "$plister" insert "server-hosts" dict "$prefs" '/'
    "$plister" get type "$prefs" "/server-hosts/$host_pid" >/dev/null 2>&1 || \
        "$plister" insert "$host_pid" dict "$prefs" '/server-hosts'
    "$plister" insert "$server_pid" string "$model_path" "$prefs" "/server-hosts/$host_pid"

    "$plister" get type "$prefs" "/server-info" >/dev/null 2>&1 || \
        "$plister" insert "server-info" dict "$prefs" '/'
    "$plister" get type "$prefs" "/server-info/$server_pid" >/dev/null 2>&1 || \
        "$plister" insert "$server_pid" dict "$prefs" '/server-info'
    [ -n "$server_port" ] && "$plister" insert "port" string "$server_port" "$prefs" "/server-info/$server_pid"
    [ -n "$model_size" ]  && "$plister" insert "size" string "$model_size" "$prefs" "/server-info/$server_pid"
    [ -n "$dialog_guid" ] && "$plister" insert "dialog" string "$dialog_guid" "$prefs" "/server-info/$server_pid"
    echo "registered server pid=$server_pid port=$server_port size=$model_size dialog=$dialog_guid"
}

# stop_all_bundle_servers — at app.will.terminate, TERM every llama-server this bundle owns,
# found by its own executable path under the OMC-provided $OMC_APP_BUNDLE_PATH. The app is
# unconditionally going away, so every model server it launched must stop.
#
# Why this signal: at terminate OMC_FRONT_PROCESS_ID is the *frontmost* app (GetFrontAppPID =
# NSWorkspace.frontmostApplication - on a non-frontmost quit that is NOT us), a pgrep for the app
# executable is already empty (the app has begun exiting), and there is no OMC env for the app's
# own pid. The one thing still true is that the llama-server is alive (that is the whole bug), so
# matching on its binary path under our bundle finds it every time. Deliberately NOT keyed on the
# port: the app will grow to run several models on different ports at once, and every one of them
# is ours to stop here.
#
# Accepted limitation: a SECOND concurrently-running OS instance of this same bundle would have
# its servers reaped too (same bundle path, no per-instance signal available at terminate). Note
# this is a SECOND OS-level copy of the app, NOT the several-models-in-one-app case this handler
# is built for: those all belong to this one instance and are all ours to stop. If two OS copies
# are ever supported, ownership will need a per-instance token wired in at launch, not
# reconstructed here.
#
# The exe-path re-check against the live argv (not the pgrep snapshot) is the pid-identity guard:
# a recycled pid, or a process that only mentions the path as a later argument, is never signalled.
stop_all_bundle_servers() {
    local ls_bin="$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server"
    local sp args
    for sp in $(/usr/bin/pgrep -f "$ls_bin" 2>/dev/null); do
        args=$(/bin/ps -p "$sp" -o args= 2>/dev/null)
        case "$args" in
            "$ls_bin"|"$ls_bin "*) ;;
            *) continue ;;
        esac
        echo "terminate: stopping bundle llama-server pid=$sp"
        srvlog "TERMINATE stop-bundle-server pid=$sp"
        kill -TERM "$sp" 2>/dev/null
        "$plister" delete "$prefs" "/server-info/$sp" 2>/dev/null
        forget_server_host_entry "$sp"
    done
}

# stop_orphaned_servers — TERM any registered server whose host app is gone; prune entries.
stop_orphaned_servers() {
    local host_pids server_pids host_pid server_pid
    host_pids=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
    while read -r host_pid; do
        [ -z "$host_pid" ] && continue
        if ! /bin/ps -p "$host_pid" >/dev/null 2>&1; then
            server_pids=$("$plister" get keys "$prefs" "/server-hosts/$host_pid" 2>/dev/null)
            while read -r server_pid; do
                [ -z "$server_pid" ] && continue
                /bin/ps -p "$server_pid" >/dev/null 2>&1 && kill -TERM "$server_pid"
                "$plister" delete "$prefs" "/server-info/$server_pid" 2>/dev/null
            done <<< "$server_pids"
            "$plister" delete "$prefs" "/server-hosts/$host_pid"
        fi
    done <<< "$host_pids"
}

# stop_window_server <win_uuid> [log_tag] - TERM the registered llama-server that belongs to ONE
# window and forget it. 0 when one was stopped, 1 when that window had none registered.
#
# One window, one server: register_started_server stores the window uuid as the server's
# `dialog`, and this walks the hosts looking for that value. It stops at the FIRST match, which
# is the same assumption the rest of the app makes - a window claims one port and relaunches on
# that port for as long as it lives.
#
# A function rather than the loop it was, because ending a window's server is not only what
# closing that window does. It was written inline in aichat.chat.cancel.sh; a load that fails
# after its server came up has to undo the launch, and switching a window's conversation to an
# engine that runs no server - MLX or the on-device model - will have to do the same while the
# window stays open, which is the one case a close handler can never reach. All of them need the
# registry entries gone as well as the process, or the next reader believes this window still has
# a server.
#
# <log_tag> names the caller in the server log and nothing else, so a switch can be told from a
# close when the log is read back weeks later.
stop_window_server() {
    local win="$1" log_tag="${2:-STOP-WINDOW-SERVER}"
    local found=0 host_pids server_pids host_pid server_pid stored_dialog
    [ -f "$prefs" ] || return 1
    # Find the server whose stored dialog guid matches this window, then kill only it.
    host_pids=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
    while IFS= read -r host_pid; do
        [ -z "$host_pid" ] && continue
        server_pids=$("$plister" get keys "$prefs" "/server-hosts/$host_pid" 2>/dev/null)
        while IFS= read -r server_pid; do
            [ -z "$server_pid" ] && continue
            stored_dialog=$("$plister" get string "$prefs" "/server-info/$server_pid/dialog" 2>/dev/null)
            if [ "$stored_dialog" = "$win" ]; then
                echo "Stopping server pid=$server_pid for window $win"
                srvlog "$log_tag killing server=$server_pid host=$host_pid win=$win"
                if kill -0 "$server_pid" 2>/dev/null; then
                    kill -TERM "$server_pid"
                fi
                "$plister" delete "$prefs" "/server-hosts/$host_pid/$server_pid" 2>/dev/null
                "$plister" delete "$prefs" "/server-info/$server_pid" 2>/dev/null
                found=1
                break
            fi
        done <<< "$server_pids"
        [ "$found" = 1 ] && break
    done <<< "$host_pids"
    if [ "$found" = 0 ]; then
        echo "No server found for window $win"
        srvlog "$log_tag no server matched win=$win"
        return 1
    fi
    return 0
}

# prune_server_registry <front_pid> - the terminate-time teardown of the registry.
#
# Two halves that look alike and are not the same operation. OUR host's servers are stopped
# because the app they belong to is going away. Another host's are stopped only if that host is
# already DEAD; a live sibling instance's servers are left strictly alone, because one instance
# quitting must not take another instance's loaded models with it.
#
# Lifted out of app.will.terminate so it can be tested at all. Everything else in that handler
# identifies processes with `pgrep` over paths inside the bundle - which, under a harness that
# runs the REAL bundle, match the developer's own running copy of the app - so the handler as a
# whole can never be dispatched by a test. This half touches nothing but the registry and the
# pids recorded in it, both of which a test can own outright.
prune_server_registry() { # <front_pid>
    local front="$1" server_pids server_pid
    if [ -n "$front" ]; then
        server_pids=$("$plister" get keys "$prefs" "/server-hosts/$front" 2>/dev/null)
        # Reports what was actually FOUND, not merely that this branch was entered. The
        # frontmost process at terminate is often some other app entirely, with nothing
        # registered under it, and a line claiming "killing its servers" on every quit makes
        # this log useless for the one bug it exists to diagnose - whether the pid recorded as
        # the registry host at launch is still the pid we see here.
        if [ -n "$server_pids" ]; then
            srvlog "TERMINATE host=$front == front -> OUR APP branch, killing its servers"
        else
            srvlog "TERMINATE front=$front has no registered servers - nothing of ours to stop"
        fi
        while IFS= read -r server_pid; do
            [ -z "$server_pid" ] && continue
            if /bin/ps -p "$server_pid" >/dev/null 2>&1; then
                echo "kill -TERM $server_pid"
                kill -TERM "$server_pid" 2>/dev/null
            fi
            "$plister" delete "$prefs" "/server-info/$server_pid" 2>/dev/null
        done <<< "$server_pids"
        "$plister" delete "$prefs" "/server-hosts/$front" 2>/dev/null
    fi
    # Every OTHER host, by the dead-host rule. Same code the launch path uses, deliberately:
    # two spellings of "is this host still alive" is how a live instance eventually gets read
    # as dead by one of them.
    stop_orphaned_servers
}

# wait_for_server <win_uuid> <port> [limit_seconds] [model_label] - poll /health on <port> until
# ready or time out with an alert. 0 = ready, 13 = timeout.
# limit_seconds defaults to 30; launches that pass --no-mmap hand in a size-scaled limit
# because the model file is read and copied instead of mapped.
#
# <model_label> is only ever read by the ten-second note below, which is why it is optional and
# last: a wait that finishes before then never needs it. It is PASSED rather than read out of
# LAUNCHED_MODEL_LABEL, which is set by the one caller - the label belongs to the launch, and a
# function that reached into its caller's global for it would be a function that cannot be
# called from anywhere else.
wait_for_server() {
    local win="$1" port="$2" limit="${3:-30}" label="$4" result=0 seconds_count=0
    while true; do
        /usr/bin/curl --fail --silent "http://localhost:$port/health" >/dev/null 2>&1 && {
            echo "server became responsive after $seconds_count seconds"; break; }
        seconds_count=$((seconds_count + 1))
        if [ "$seconds_count" -ge "$limit" ]; then
            local message="Timed out after $seconds_count seconds while waiting for llama-server response.\n\nPlease try again"
            "$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$message"
            result=13
            break
        elif [ "$seconds_count" -eq 10 ]; then
            # Ten seconds in, said in the overlay the load is already showing rather than in the
            # window title, which is the app's name and no longer reports anything (see the note
            # in aichat.library.sh). A big model mapped with --no-mmap is given up to 300 s, and
            # a spinner that has not changed in five minutes is indistinguishable from one that
            # is stuck.
            chat_loading_overlay_note "$win" "Still loading ${label:-the model}…"
        fi
        sleep 1
    done
    return "$result"
}

# report_server_launch_failure — alert + return 11 (unsupported / bad gguf).
report_server_launch_failure() {
    local message="llama-server failed to launch! \n\nVerify if the selected large language model is supported by llama.cpp engine."
    "$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$message"
    return 11
}

# launch_model_on_port <model_path> <win_uuid> <port> [retiring_model_path] [retiring_window]
# Free ONLY <port> (never a sibling window's server), launch llama-server for model_path on
# it, wait for health, and register it. Sets LAUNCHED_MODEL_LABEL. 0 = ready.
#
# The last two are for the one caller that starts a server while the engine it is replacing is
# still holding memory: an in-place switch arriving at gguf from mlx, which cannot free the
# outgoing agent until the transport it is about to build has been injected. They go straight to
# compute_server_memory_args; scan_engine_footprints is where they mean something.
#
# <retiring_window> is DELIBERATELY NOT <win_uuid>, though it is usually the same string. It is a
# claim that this caller can identify its own agent in the process table, which is only true when
# that agent was launched with an --mcp-config - so the caller passes it or leaves it empty, and
# reusing <win_uuid> here would assert something the caller has not checked.
#
# Every other caller omits both, because by the time they launch there is nothing of theirs left
# to retire - a first load's window was empty, and a gguf-to-gguf switch's outgoing server was
# TERMed and waited out by the free step below.
#
# Multi-model: <port> is the window's own port (find_free_port_in at init, stashed as
# aichatv2_port_<win>). On a NEW window it is a freshly-allocated idle port, so the free step
# is a no-op and the launch coexists with every other window's server. On an in-place
# gguf->gguf switch it is the SAME port the window already owns, so freeing it TERMs this
# window's outgoing server and the incoming model takes the port back - the agent's argv names the
# port and not the model, so nothing has to be re-injected and the agent's own conversation
# carries over. Other ports are never touched here.
LAUNCHED_MODEL_LABEL=""
launch_model_on_port() {
    local model_path="$1"
    local win="$2"
    local port="$3"
    local retiring="$4"
    local retiring_win="$5"
    LAUNCHED_MODEL_LABEL=$(/usr/bin/basename "$model_path" .gguf)

    # Free only THIS port. The binary-path guard means a non-bundle process that happens to
    # hold the port is never signalled (it would just fail the bind below and alert).
    local ls_bin="$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server"
    local old_pid args killed_pids="" still=""
    for old_pid in $(/usr/sbin/lsof -ti "tcp:${port}" 2>/dev/null); do
        args=$(/bin/ps -p "$old_pid" -o args= 2>/dev/null)
        case "$args" in
            "$ls_bin"|"$ls_bin "*) ;;
            *) continue ;;
        esac
        srvlog "LAUNCH freeing-port port=${port} old=${old_pid} win=$win"
        echo "stopping previous llama-server pid=$old_pid on port $port"
        kill -TERM "$old_pid" 2>/dev/null
        killed_pids="$killed_pids $old_pid"
        "$plister" delete "$prefs" "/server-info/$old_pid" 2>/dev/null
        forget_server_host_entry "$old_pid"
    done
    local w=0
    while /usr/sbin/lsof -ti "tcp:${port}" >/dev/null 2>&1 && [ "$w" -lt 10 ]; do sleep 1; w=$((w+1)); done
    # The listener closes before model teardown finishes, so waiting on the port is not
    # enough: an in-place swap could scan the DYING server as a sibling, see no budget,
    # and needlessly dive into the CPU fallback. Wait (bounded) for the pids themselves.
    w=0
    while [ -n "$killed_pids" ] && [ "$w" -lt 20 ]; do
        still=""
        for old_pid in $killed_pids; do
            /bin/ps -p "$old_pid" >/dev/null 2>&1 && still="$still $old_pid"
        done
        killed_pids="$still"
        [ -z "$killed_pids" ] && break
        sleep 1; w=$((w+1))
    done
    [ -n "$killed_pids" ] && srvlog "LAUNCH outgoing server(s) still exiting after ${w}s:${killed_pids}"

    local KV=q8_0
    local model_size mem_args
    model_size=$(/usr/bin/stat -f%z -L "$model_path" 2>/dev/null)

    # Lock across scan + spawn so a concurrent window's launch can't scan a world in
    # which our server doesn't exist yet (and vice versa).
    launch_lock_acquire
    mem_args=$(compute_server_memory_args "$model_path" "$retiring" "$retiring_win")

    # $mem_args is intentionally unquoted: it is a flag string built above (no paths).
    echo "launching llama-server for $LAUNCHED_MODEL_LABEL on port $port (mem policy: $mem_args)"
    "$ls_bin" \
        --host 127.0.0.1 --port "$port" \
        --cache-type-k "$KV" \
        --cache-type-v "$KV" \
        --context-shift \
        --sleep-idle-seconds 600 \
        --model "$model_path" \
        --jinja \
        $mem_args &
    local server_pid=$!
    if [ -z "$server_pid" ] || ! { sleep 1; /bin/ps -p "$server_pid" >/dev/null 2>&1; }; then
        launch_lock_release
        report_server_launch_failure
        return 11
    fi
    launch_lock_release

    # --no-mmap loads copy the whole file, so give big models more than the 30 s default:
    # 10 s per GiB of model on top of the base, capped at 5 minutes.
    local wait_limit=30
    case " $mem_args " in *" --no-mmap "*)
        wait_limit=$(( 30 + model_size / 1073741824 * 10 ))
        [ "$wait_limit" -gt 300 ] && wait_limit=300 ;;
    esac

    wait_for_server "$win" "$port" "$wait_limit" "$LAUNCHED_MODEL_LABEL"
    local r=$?
    if [ "$r" = 0 ]; then
        register_started_server "${OMC_FRONT_PROCESS_ID}" "$server_pid" "$model_path" "$win" "$port" "$model_size"
        srvlog "LAUNCH ok server=$server_pid port=$port win=$win registered_host=${OMC_FRONT_PROCESS_ID} app_pids=[$(srvlog_apppids)] hosts=[$(srvlog_hosts)] model=$LAUNCHED_MODEL_LABEL"
    else
        srvlog "LAUNCH failed r=$r server=$server_pid port=$port win=$win front=${OMC_FRONT_PROCESS_ID}"
    fi
    return "$r"
}
