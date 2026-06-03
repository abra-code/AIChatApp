#!/bin/sh

alert="$OMC_OMC_SUPPORT_PATH/alert"
dialog="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
plister="$OMC_OMC_SUPPORT_PATH/plister"
filt="$OMC_OMC_SUPPORT_PATH/filt"
pasteboard="$OMC_OMC_SUPPORT_PATH/pasteboard"
next_command="$OMC_OMC_SUPPORT_PATH/omc_next_command"

# ──────────────────────────────────────────────────────────────
# Pasteboard helpers
# ──────────────────────────────────────────────────────────────

pb_set() { "$pasteboard" "$1" set "$2"; }
pb_get() { "$pasteboard" "$1" get; }

# ──────────────────────────────────────────────────────────────
# Formatting helpers
# ──────────────────────────────────────────────────────────────

# format_bytes <bytes>  ->  human-readable string (KB / MB / GB)
format_bytes() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        printf "%.1f GB" "$(echo "scale=4; $bytes/1073741824" | /usr/bin/bc -l 2>/dev/null)"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        printf "%.0f MB" "$(echo "scale=0; $bytes/1048576" | /usr/bin/bc -l 2>/dev/null)"
    else
        printf "%d KB" "$(echo "scale=0; $bytes/1024" | /usr/bin/bc -l 2>/dev/null)"
    fi
}

# ──────────────────────────────────────────────────────────────
# Server management
# ──────────────────────────────────────────────────────────────

# find_free_port()
# Returns the first unused port in the range 8088–8097, or empty string if all taken.
find_free_port() {
    local port=8088
    while [ "$port" -le 8097 ]; do
        if ! /usr/sbin/lsof -ti tcp:"$port" > /dev/null 2>&1; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
    done
    echo ""
    return 1
}

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

# generate_mcp_configs <app_bundle> <proxy_port> <out_proxy_json> <out_webui_json>
# Writes mcp-proxy.json and llama-ui-mcp.json using the bundled Python3.
# Phase 1: all four bundled servers hardcoded as enabled.
# Discovers tool directories at runtime to build replay's sandbox allowed-read list.
generate_mcp_configs() {
    local app_bundle="$1"
    local proxy_port="$2"
    local out_proxy_json="$3"
    local out_webui_json="$4"

    local python3="$app_bundle/Contents/Library/Python/bin/python3"
    if [ ! -f "$python3" ]; then
        echo "generate_mcp_configs: bundled Python not found: $python3"
        return 1
    fi

    local tz=$(/usr/bin/readlink /etc/localtime 2>/dev/null | /usr/bin/sed 's|.*/zoneinfo/||')
    [ -z "$tz" ] && tz="UTC"

    # Make sure the prefs plist exists and is seeded with defaults (temp, system
    # tool dirs, app bundle, …) so the sandbox the Python script builds matches
    # exactly what the MCP servers dialog shows. No-op when prefs already exist.
    mcp_prefs_init_if_missing

    local script="$app_bundle/Contents/Resources/Scripts/generate_mcp_configs.py"
    "$python3" "$script" "$app_bundle" "$proxy_port" "$out_proxy_json" "$out_webui_json" "$tz" "$mcp_prefs"
}

# any_mcp_server_enabled  ->  0 if at least one bundled server is enabled in prefs
any_mcp_server_enabled() {
    [ ! -f "$mcp_prefs" ] && return 0  # no prefs file = use defaults (all on)
    for srv in time search local; do
        [ "$(mcp_prefs_get_bool "servers/$srv/enabled")" = "true" ] && return 0
    done
    return 1
}

# capture_login_path <marker>
# Echoes the user's login-shell PATH (the value of $PATH after their login profile
# runs). Tries $SHELL first, then common shells, until one yields a PATH — this
# survives a $SHELL that is empty, whitespace-padded, or non-executable in the GUI
# launch context. stdin is taken from /dev/null so a profile that reads stdin can't
# block or consume input; <marker> isolates $PATH from any stdout a profile emits.
# Each attempt is traced to $AICHAT_AGENT_PATH_LOG when that variable is set.
capture_login_path() {
    local marker="$1" cand out rc lp
    for cand in "$SHELL" /bin/zsh /bin/bash /bin/sh; do
        # Trim accidental surrounding whitespace from $SHELL before testing it.
        cand="$(printf '%s' "$cand" | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$cand" ] && [ -x "$cand" ] || continue
        out="$("$cand" -lc "printf '%s%s' '$marker' \"\$PATH\"" </dev/null 2>&1)"; rc=$?
        lp="${out##*$marker}"   # drop any profile stdout before the marker
        [ "$lp" = "$out" ] && lp=""   # marker absent -> unusable capture
        if [ -n "$AICHAT_AGENT_PATH_LOG" ]; then
            printf '  try %-9s rc=%s raw=[%s] login_path=[%s]\n' \
                "$cand" "$rc" "$out" "$lp" >> "$AICHAT_AGENT_PATH_LOG" 2>/dev/null
        fi
        if [ -n "$lp" ]; then
            printf '%s' "$lp"
            return 0
        fi
    done
    return 1
}

# build_agent_path
# Echoes the PATH the agentic shell tool should run with. The GUI launch context
# only gives us a minimal PATH (system dirs + the OMC-injected embedded Python
# bin) — it lacks the Homebrew / version-manager / ~/bin dirs a terminal session
# has, so the shell server can't find brew, Homebrew git, etc. by name. We merge
# our current PATH with the user's *login* shell PATH so the agent sees their full
# terminal environment (the login shell is spawned once — negligible next to model
# load). Falls back to the current $PATH if no login shell yields a PATH.
#
# Merge rule (generic, no hard-coded dirs), built in priority order with dedup:
#   1. the first element of our current PATH — OMC injects the embedded Python bin
#      dir at the front, so pinning it here keeps the bundled python3/pip winning
#      for agentic execution. The login shell inherits our PATH and so usually
#      contains this dir too (not first); pinning it guarantees priority regardless.
#   2. every other element of our current PATH NOT already in the login PATH, in
#      order — preserves any further OMC-injected dirs up front.
#   3. the entire login PATH — so shared dirs (e.g. /usr/bin vs Homebrew) keep the
#      user's terminal ordering.
# Set $AICHAT_AGENT_PATH_LOG to a file path to capture a diagnostic trace.
build_agent_path() {
    local marker="__AICHAT_PATH__"

    [ -n "$AICHAT_AGENT_PATH_LOG" ] && {
        printf '[build_agent_path %s] SHELL=[%s] HOME=[%s]\n  current PATH=[%s]\n' \
            "$(date '+%H:%M:%S')" "$SHELL" "$HOME" "$PATH" > "$AICHAT_AGENT_PATH_LOG" 2>/dev/null
    }

    local login_path="$(capture_login_path "$marker")"

    if [ -z "$login_path" ]; then
        [ -n "$AICHAT_AGENT_PATH_LOG" ] && \
            printf '  RESULT: no login shell yielded a PATH — falling back to current PATH\n' \
            >> "$AICHAT_AGENT_PATH_LOG" 2>/dev/null
        printf '%s' "$PATH"                # no login shell available — keep OMC's PATH as-is
        return 0
    fi

    local result="" elem old_ifs="$IFS"
    add_path_elem() {   # append $1 to $result unless already present
        case ":$result:" in
            *":$1:"*) ;;
            *) result="${result:+$result:}$1" ;;
        esac
    }
    add_path_elem "${PATH%%:*}"                      # embedded Python bin (PATH[0]) — first
    IFS=":"
    for elem in $PATH; do                            # current PATH dirs unique to us
        [ -z "$elem" ] && continue
        case ":$login_path:" in
            *":$elem:"*) ;;                          # in login PATH — defer to step 3
            *) add_path_elem "$elem" ;;
        esac
    done
    for elem in $login_path; do                      # full login PATH (deduped)
        [ -z "$elem" ] && continue
        add_path_elem "$elem"
    done
    IFS="$old_ifs"
    unset -f add_path_elem

    [ -n "$AICHAT_AGENT_PATH_LOG" ] && \
        printf '  RESULT agent PATH=[%s]\n' "$result" >> "$AICHAT_AGENT_PATH_LOG" 2>/dev/null

    printf '%s' "$result"
}

# launch_mcp_proxy <app_bundle> <proxy_port> <config_json> <log_path>
# Starts one Python mcp-proxy instance PER bundled server, each on its own port, so
# every server gets its own WKWebView per-host connection budget. The WebUI holds a
# long-lived SSE GET stream per server; behind a single shared port those streams
# saturated WKWebView's ~6-connections-per-host limit and starved the tools/list
# POSTs (60s timeout -> "connected, 0 tools" -> model got no tools). mcp-proxy has no
# native multi-port mode, so we run N instances. See Private/mcp-tools-debugging-postmortem.md.
# The instances come from the manifest generate_mcp_configs.py writes next to
# config_json (mcp-proxy-instances.txt: "<name> <port>" per line); each instance uses
# --named-server-config mcp-proxy-<name>.json in that dir and logs to <stem>-<name>.log.
# Sets mcp_proxy_pid to a SPACE-SEPARATED list of surviving instance PIDs (empty if
# none); kill_mcp_proxy() accepts that list, so every teardown caller is unchanged.
mcp_proxy_pid=""
launch_mcp_proxy() {
    local app_bundle="$1"
    local proxy_port="$2"      # base port (informational; ports come from the manifest)
    local config_json="$3"
    local log_path="$4"

    mcp_proxy_pid=""
    local python3="$app_bundle/Contents/Library/Python/bin/python3"

    if [ ! -f "$python3" ]; then
        echo "launch_mcp_proxy: Python not found — skipping MCP"
        return 0
    fi
    # PYTHONPATH (the bundled Packages dir) is already exported by OMC, so the
    # import check and mcp-proxy below inherit it — don't re-export it here.
    if ! "$python3" -c "import mcp_proxy" 2>/dev/null; then
        echo "launch_mcp_proxy: mcp-proxy not installed — run update-mcp-servers.sh to enable MCP"
        return 0
    fi

    local config_dir manifest
    config_dir=$(/usr/bin/dirname "$config_json")
    manifest="$config_dir/mcp-proxy-instances.txt"
    if [ ! -f "$manifest" ]; then
        echo "launch_mcp_proxy: instance manifest not found ($manifest) — skipping MCP"
        return 0
    fi

    # Build the PATH the agentic shell tool runs with (see build_agent_path) once and
    # reuse it for every instance — set only for the mcp-proxy processes (not the whole
    # script), so the llama-server launched later keeps the original OMC launch PATH.
    # --pass-environment then propagates this PATH, with the rest of the env (HOME,
    # USER, …), to every child server, including the replay shell tool. Set
    # AICHAT_DEBUG_AGENT_PATH=1 to capture a PATH-merge trace next to the proxy log
    # (logs/agent-path.log) for debugging the login-shell merge.
    local AICHAT_AGENT_PATH_LOG=""
    [ -n "$AICHAT_DEBUG_AGENT_PATH" ] && AICHAT_AGENT_PATH_LOG="${log_path%/*}/agent-path.log"
    local agent_path="$(build_agent_path)"   # subshell inherits the log var above

    local pids="" name port cfg one_log
    while IFS=' ' read -r name port; do
        [ -z "$name" ] && continue
        cfg="$config_dir/mcp-proxy-$name.json"
        if [ ! -f "$cfg" ]; then
            echo "  mcp-proxy '$name': config not found ($cfg) — skipping instance"
            continue
        fi
        one_log="${log_path%.log}-$name.log"
        echo "Starting mcp-proxy '$name' (Python, port $port) -> $one_log"
        PATH="$agent_path" "$python3" -m mcp_proxy \
            --host 127.0.0.1 \
            --port "$port" \
            --allow-origin '*' \
            --pass-environment \
            --named-server-config "$cfg" \
            > "$one_log" 2>&1 &
        pids="${pids:+$pids }$!"
    done < "$manifest"

    sleep 1
    # Keep only the instances that survived startup.
    local live="" p
    for p in $pids; do
        if /bin/ps -p "$p" > /dev/null 2>&1; then
            live="${live:+$live }$p"
        else
            echo "mcp-proxy instance pid=$p exited immediately — check ${log_path%.log}-*.log"
        fi
    done
    mcp_proxy_pid="$live"

    if [ -n "$mcp_proxy_pid" ]; then
        echo "mcp-proxy started (pids: $mcp_proxy_pid)"
    else
        echo "no mcp-proxy instances survived — check ${log_path%.log}-*.log"
    fi
}

# kill_mcp_proxy <mcp_pid_list>
# Terminates one or more mcp-proxy instances (a single PID or a SPACE-SEPARATED list)
# and all child processes they spawned (tool instances, etc.). Callers pass the stored
# mcp-proxy-pid string verbatim, so the per-server multi-instance launch (see
# launch_mcp_proxy) is torn down exactly like the old single proxy with no caller changes.
kill_mcp_proxy() {
    local mcp_pids="$1"
    [ -z "$mcp_pids" ] && return
    local mcp_pid child_pids child all_procs="" all_children=""
    # Snapshot every instance's direct children BEFORE signaling anything. Once a proxy
    # exits (it may as soon as it gets SIGTERM or sees its children die) the children
    # reparent to launchd, so a later pgrep -P would miss them.
    for mcp_pid in $mcp_pids; do
        kill -0 "$mcp_pid" 2>/dev/null || continue
        child_pids=$(/usr/bin/pgrep -P "$mcp_pid" 2>/dev/null)
        echo "kill mcp-proxy pid=$mcp_pid children=$(echo "$child_pids" | tr '\n' ' ')"
        all_procs="${all_procs:+$all_procs }$mcp_pid"
        while IFS= read -r child; do
            [ -n "$child" ] && all_children="${all_children:+$all_children }$child"
        done <<< "$child_pids"
    done
    [ -z "$all_procs" ] && return
    for child in $all_children; do kill -TERM "$child" 2>/dev/null; done
    for mcp_pid in $all_procs; do kill -TERM "$mcp_pid" 2>/dev/null; done
    sleep 0.5
    for child in $all_children; do kill -KILL "$child" 2>/dev/null; done
    for mcp_pid in $all_procs; do kill -KILL "$mcp_pid" 2>/dev/null; done
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
    local _fh_host_pid
    while IFS= read -r _fh_host_pid; do
        [ -z "$_fh_host_pid" ] && continue
        "$plister" delete "$prefs" "/server-hosts/$_fh_host_pid/$target_pid" 2>/dev/null
    done <<< "$host_pids"
}

# reap_dead_server_mcp_proxies()
# Kills mcp-proxy processes whose owning llama-server has exited, then clears the
# stale /server-info and /server-hosts entries. mcp-proxy is launched with '&' from
# a handler that returns, so it reparents to launchd (PPID 1) and outlives its
# llama-server when the server dies by any path other than explicit cancel / app-quit
# (a crash, a binary swap, an external kill). Those orphans otherwise linger until
# app-quit: they drift the proxy port upward (find_free_port_in skips the bound ones)
# and — because each proxy spawns its child tool servers ONCE and reuses them for the
# whole session — keep answering tool calls from a frozen, possibly stale env (e.g. an
# old PATH). Running this at session launch keeps the port stable and guarantees no
# pre-existing proxy survives into the new session.
reap_dead_server_mcp_proxies() {
    [ -f "$prefs" ] || return 0
    local server_pids
    server_pids=$("$plister" get keys "$prefs" "/server-info" 2>/dev/null) || return 0
    local server_pid
    while IFS= read -r server_pid; do
        [ -z "$server_pid" ] && continue
        kill -0 "$server_pid" 2>/dev/null && continue   # server alive — keep its proxy
        local mcp_pid=$("$plister" get string "$prefs" "/server-info/$server_pid/mcp-proxy-pid" 2>/dev/null)
        if [ -n "$mcp_pid" ]; then
            echo "reaping orphaned mcp-proxy pid=$mcp_pid (owning server $server_pid is gone)"
            kill_mcp_proxy "$mcp_pid"
        fi
        "$plister" delete "$prefs" "/server-info/$server_pid" 2>/dev/null
        forget_server_host_entry "$server_pid"
    done <<< "$server_pids"
}

# ──────────────────────────────────────────────────────────────
# Orphaned bundle-process reaping (registry-independent safety net)
# ──────────────────────────────────────────────────────────────
#
# Three kinds of process run out of THIS app bundle and can outlive the session that
# started them:
#   • llama-server       ($OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server)
#     — the model server, one per chat window
#   • the bundled Python ($OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3)
#     — one detached mcp-proxy per enabled server, plus the time / search tool
#       servers each proxy spawns
#   • replay             ($OMC_APP_BUNDLE_PATH/Contents/Support/replay) — the Local
#     (files & shell) server, a child of the local mcp-proxy
#
# All three are launched with '&' from the init handler and reparent to launchd (PPID
# 1) once that handler exits. The pid-registry teardown (stop_orphaned_servers /
# kill_mcp_proxy / the cancel & terminate handlers) reaches a process only through a
# stored pid, and reaches a proxy's children only by walking `pgrep -P <proxy>` while
# the proxy is still alive. Those links break: a proxy that dies first (crash, idle
# exit, external kill) strands its children on launchd; a session quit before the model
# finished loading never registered its server or proxies at all; an app force-quit /
# crash skips the terminate handler completely. The leftover llama-server / python3 /
# replay processes seen after the app is gone are exactly these.
#
# reap_orphaned_bundle_processes() is the net that needs no stored child pids. It scans
# for any bundled executable reparented to launchd (PPID 1 — "no running parent") and
# kills the ones not belonging to a still-running session. Ownership is keyed on the
# HOST app, exactly as the registry records it under /server-hosts:
#   • a llama-server is kept only while the host app that launched it is alive;
#   • an mcp-proxy is kept only while BOTH its host AND its owning llama-server are
#     alive (a proxy whose model server has crashed serves a dead session and goes).
# Everything else at PPID 1 in a bundled dir is an orphan, reaped together with its
# subtree (a still-alive orphaned proxy's children have the proxy — not 1 — as their
# PPID, so they are snapshotted before signalling).
#
# The PPID-1 gate is what makes this safe to run at any moment, including mid-launch: a
# server and its proxies stay children of the (still-running) init handler until that
# handler exits, and the handler only exits AFTER registering them — so a wanted
# process is never simultaneously PPID 1 and unregistered. Transient bundled-python
# helpers (generate_mcp_configs, the mcp_proxy import probe) likewise always have a
# living parent and never match the gate. Because ownership is decided by host
# liveness, correctness does not depend on running order relative to the registry
# reapers — those still run first to keep the on-disk registry tidy.

# _bundle_managed_process <args-string>
# 0 if the command's executable lives in a swept bundle dir (llama-server, bundled
# python, or replay). Matches the START of the whole argument string, so a bundle path
# containing spaces is handled and a path that only appears as a later argument is not
# mistaken for the executable.
_bundle_managed_process() {
    case "$1" in
        "$OMC_APP_BUNDLE_PATH/Contents/Library/Python/"*)                 return 0 ;;
        "$OMC_APP_BUNDLE_PATH/Contents/Support/replay"|\
        "$OMC_APP_BUNDLE_PATH/Contents/Support/replay "*)                 return 0 ;;
        "$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server"|\
        "$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server "*) return 0 ;;
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
    echo "Reaping orphaned bundle processes (llama-server / mcp-proxy / replay) with no running parent"

    # Protected pids: the llama-servers and mcp-proxy instances of still-running
    # sessions, keyed on host liveness (see header). A server is shielded only while
    # its host app is alive; its proxies only while host AND server are both alive.
    # Space-padded for whole-token matching below (" 501 502 ").
    local protected=" "
    if [ -f "$prefs" ]; then
        local _rp_hosts _rp_host _rp_servers _rp_server _rp_mcp _rp_p
        _rp_hosts=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
        while IFS= read -r _rp_host; do
            [ -z "$_rp_host" ] && continue
            kill -0 "$_rp_host" 2>/dev/null || continue          # host app gone -> its session is orphaned
            _rp_servers=$("$plister" get keys "$prefs" "/server-hosts/$_rp_host" 2>/dev/null)
            while IFS= read -r _rp_server; do
                [ -z "$_rp_server" ] && continue
                kill -0 "$_rp_server" 2>/dev/null || continue    # server already dead -> don't shield its proxies
                protected="${protected}${_rp_server} "           # keep this llama-server
                _rp_mcp=$("$plister" get string "$prefs" "/server-info/$_rp_server/mcp-proxy-pid" 2>/dev/null)
                for _rp_p in $_rp_mcp; do
                    protected="${protected}${_rp_p} "            # keep its mcp-proxy instances
                done
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

    # Expand each victim to its full subtree first: a still-alive orphaned proxy has
    # children whose PPID is the proxy (not 1), so they were skipped above — snapshot
    # them before signalling, since they reparent to launchd once the proxy dies.
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

# calculate_total_server_ram()
# Sums model sizes (from /server-info) for all currently live registered servers.
# Prints the total in bytes.
calculate_total_server_ram() {
    local total=0
    [ ! -f "$prefs" ] && echo "0" && return 0

    local host_pids=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
    while IFS= read -r _ctr_host_pid; do
        [ -z "$_ctr_host_pid" ] && continue
        /bin/ps -p "$_ctr_host_pid" > /dev/null 2>&1 || continue
        local server_pids=$("$plister" get keys "$prefs" "/server-hosts/$_ctr_host_pid" 2>/dev/null)
        while IFS= read -r _ctr_server_pid; do
            [ -z "$_ctr_server_pid" ] && continue
            kill -0 "$_ctr_server_pid" 2>/dev/null || continue
            local _ctr_size=$("$plister" get string "$prefs" "/server-info/$_ctr_server_pid/size" 2>/dev/null)
            [ -n "$_ctr_size" ] && [ "$_ctr_size" -gt 0 ] 2>/dev/null && total=$((total + _ctr_size))
        done <<< "$server_pids"
    done <<< "$host_pids"
    echo "$total"
}

# warn_ram_pressure_for_new_model <model_bytes> <model_label>
# Warns if adding this model would push total server RAM past 75% of unified memory.
# When other models are already running, the combined load is shown.
# Returns 0 to proceed, 1 if the user chose Cancel.
warn_ram_pressure_for_new_model() {
    local model_bytes="$1"
    local model_label="$2"

    [ -n "$model_bytes" ] && [ "$model_bytes" -gt 0 ] 2>/dev/null || return 0

    local ram_bytes=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null)
    [ -n "$ram_bytes" ] && [ "$ram_bytes" -gt 0 ] 2>/dev/null || return 0

    local ram_threshold=$(( ram_bytes * 3 / 4 ))
    local current_load=$(calculate_total_server_ram)
    local new_total=$(( current_load + model_bytes ))

    [ "$new_total" -le "$ram_threshold" ] 2>/dev/null && return 0

    local ram_fmt=$(format_bytes "$ram_bytes")
    local model_fmt=$(format_bytes "$model_bytes")
    local threshold_fmt=$(format_bytes "$ram_threshold")
    local new_fmt=$(format_bytes "$new_total")

    local message
    if [ "$current_load" -gt 0 ] 2>/dev/null; then
        local current_fmt=$(format_bytes "$current_load")
        message="Loading \"${model_label}\" (${model_fmt}) will likely cause high memory pressure.

Running models:  ${current_fmt}
New model:       ${model_fmt}
Combined total:  ${new_fmt}
75% of RAM:      ${threshold_fmt}
Unified memory:  ${ram_fmt}

This may cause slowdowns or instability. Consider closing another model session first."
    else
        message="\"${model_label}\" (${model_fmt}) likely exceeds what your Mac can load.

Unified memory:  ${ram_fmt}
Recommended max: ${threshold_fmt}

Models larger than 75% of unified memory may fail to load or cause severe memory pressure. A smaller quantization is recommended."
    fi

    "$alert" \
        --level caution \
        --title "High Memory Usage" \
        --ok "Load Anyway" \
        --cancel "Cancel" \
        "$message"

    [ $? -eq 0 ] && return 0 || return 1
}

# activate_if_model_running <model_path> [selector_window_uuid]
# Searches all live registered servers for model_path.
# If found: closes the optional selector window and activates the existing chat window.
# Returns 0 if the model was already running (caller should exit), 1 otherwise.
activate_if_model_running() {
    local model_path="$1"
    local selector_uuid="$2"

    [ ! -f "$prefs" ] && return 1

    local host_pids=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
    while IFS= read -r _act_host_pid; do
        [ -z "$_act_host_pid" ] && continue
        /bin/ps -p "$_act_host_pid" > /dev/null 2>&1 || continue
        local server_pids=$("$plister" get keys "$prefs" "/server-hosts/$_act_host_pid" 2>/dev/null)
        while IFS= read -r _act_server_pid; do
            [ -z "$_act_server_pid" ] && continue
            kill -0 "$_act_server_pid" 2>/dev/null || continue
            local _act_running_model=$("$plister" get string "$prefs" "/server-hosts/$_act_host_pid/$_act_server_pid" 2>/dev/null)
            if [ "$_act_running_model" = "$model_path" ]; then
                echo "Same model already running, activating existing chat window"
                local _act_chat_window=$("$plister" get string "$prefs" "/server-info/$_act_server_pid/dialog" 2>/dev/null)
                if [ -n "$selector_uuid" ]; then
                    "$dialog" "$selector_uuid" omc_window omc_terminate_ok
                fi
                if [ -n "$_act_chat_window" ]; then
                    "$dialog" "$_act_chat_window" omc_window omc_select
                fi
                return 0
            fi
        done <<< "$server_pids"
    done <<< "$host_pids"
    return 1
}

APPLET_NAME="AIChat"

# when no model is bundled with the app:
AICHAT_MODEL_PATH=""

# when a model is bundled with the app:
# AICHAT_MODEL_PATH="$OMC_APP_BUNDLE_PATH/Contents/Resources/LFM2-1.2B-F16.gguf"

prefs="/Users/$USER/Library/Preferences/com.abracode.AIChat-servers.plist"
# base port; aichat.init.sh picks a free port starting here
port_num="8088"
mcp_app_support="$HOME/Library/Application Support/AIChat"

# ──────────────────────────────────────────────────────────────
# MCP servers preferences
# ──────────────────────────────────────────────────────────────
# User-editable settings for the bundled MCP servers, written by the
# aichat.mcp.servers dialog and read by aichat.init.sh / generate_mcp_configs.py.
#
# Schema:
#   /allow-network                : bool  (session-wide network master gate)
#   /servers/time/enabled         : bool
#   /servers/search/enabled       : bool
#   /servers/local/enabled        : bool
#   /servers/local/project        : string  (primary read-write workspace)
#   /servers/local/allowed-write  : array<string>  (additional RW paths)
#   /servers/local/allowed-read   : array<string>  (additional RO paths)
#
# allow-network is a master switch surfaced as the "Allow Network" checkbox. When
# false, the Time and Web Search & Fetch servers are not started and the local
# (replay) server is launched with --deny-network, cutting off all outbound/inbound
# network for the sandboxed shell. When true, each server follows its own toggle.
#
# allowed-write and allowed-read are seeded by mcp_prefs_write_defaults() with the
# temp dir, Homebrew, nvm, and third-party tool/data dirs, and are fully editable in
# the dialog — so the tables show every extra path the sandbox can touch and nothing
# is granted invisibly. The system executable dirs (/bin, /usr/bin, /sbin, /usr/sbin)
# and macOS system libraries (/usr/lib, /System/Library) are NOT listed: the replay
# sandbox baseline grants exec + system-dylib loading for those automatically. The
# app bundle is NOT listed either: replay self-sandboxes at startup and the local
# server has no playlist to re-read, so nothing under it is read once the sandbox is
# live. No private user dirs (Documents/Desktop/Downloads) are added by default.

mcp_prefs="/Users/$USER/Library/Preferences/com.abracode.AIChat-mcp.plist"

# mcp_prefs_write_defaults
# Overwrites the MCP prefs plist with built-in defaults.
mcp_prefs_write_defaults() {
    /bin/rm -f "$mcp_prefs"
    "$plister" set dict   "$mcp_prefs" /
    "$plister" insert "allow-network" bool true "$mcp_prefs" /
    "$plister" insert "servers" dict "$mcp_prefs" /
    "$plister" insert "time"   dict "$mcp_prefs" /servers
    "$plister" insert "enabled" bool true "$mcp_prefs" /servers/time
    "$plister" insert "search" dict "$mcp_prefs" /servers
    "$plister" insert "enabled" bool true "$mcp_prefs" /servers/search
    "$plister" insert "local"  dict "$mcp_prefs" /servers
    "$plister" insert "enabled" bool true "$mcp_prefs" /servers/local
    "$plister" insert "project" string "" "$mcp_prefs" /servers/local

    # Additional read-write paths (editable). Temp dir only — tools that create
    # scratch files need somewhere to write. /tmp is a symlink to /private/tmp and
    # the sandbox canonicalizes via realpath, so we seed the real path only. No
    # private user dirs by default.
    "$plister" insert "allowed-write" array "$mcp_prefs" /servers/local
    for d in /private/tmp; do
        [ -d "$d" ] && "$plister" append string "$d" "$mcp_prefs" /servers/local/allowed-write
    done

    # Additional read-only paths (editable). These are paths the replay sandbox does
    # NOT grant on its own: Homebrew, nvm, third-party tool dirs, data dirs, and temp
    # — so shell tools (git, node, …) can load their non-system dylibs and data, and
    # so the dialog shows exactly what the sandbox can read. The system executable
    # dirs (/bin, /usr/bin, /sbin, /usr/sbin) and the macOS system libraries
    # (/usr/lib, /System/Library) are granted automatically by the sandbox baseline
    # and are intentionally NOT listed here. The app bundle is NOT listed either:
    # replay self-sandboxes at startup (its binary and dylibs are already mapped) and
    # the local server has no playlist to re-read, so nothing under AIChat.app is
    # read once the sandbox is live. (Only if a sandboxed child had to run the
    # *bundled* python3 would Contents/Library be needed — not a current case, and
    # system /usr/bin/python3 is already reachable.) Only paths that exist on this
    # machine are added.
    "$plister" insert "allowed-read"  array "$mcp_prefs" /servers/local
    for d in \
        /usr/libexec /usr/share \
        /usr/local/bin /usr/local/lib \
        /Library/Developer/CommandLineTools/usr/bin \
        /private/etc/ssl /private/tmp /var/folders \
        /opt/homebrew "$HOME/.nvm"; do
        [ -d "$d" ] && "$plister" append string "$d" "$mcp_prefs" /servers/local/allowed-read
    done
}

# mcp_prefs_init_if_missing
mcp_prefs_init_if_missing() {
    [ -f "$mcp_prefs" ] && return 0
    mcp_prefs_write_defaults
}

# mcp_prefs_get_bool <key-path>  ->  "true" | "false"
# Falls back to "true" if key missing (defaults assume bundled servers are on).
mcp_prefs_get_bool() {
    local val=$("$plister" get value "$mcp_prefs" "/$1" 2>/dev/null)
    case "$val" in true|false) echo "$val" ;; *) echo "true" ;; esac
}

# mcp_prefs_get_string <key-path>
mcp_prefs_get_string() {
    "$plister" get string "$mcp_prefs" "/$1" 2>/dev/null
}

# mcp_prefs_set_bool <key-path> <true|false>
mcp_prefs_set_bool() {
    "$plister" set bool "$2" "$mcp_prefs" "/$1" 2>/dev/null
}

# mcp_prefs_set_string <key-path> <value>
mcp_prefs_set_string() {
    "$plister" set string "$2" "$mcp_prefs" "/$1" 2>/dev/null
}

# mcp_prefs_array_count <key-path>
mcp_prefs_array_count() {
    "$plister" get count "$mcp_prefs" "/$1" 2>/dev/null
}

# mcp_prefs_array_list <key-path>  ->  values, one per line
mcp_prefs_array_list() {
    "$plister" iterate "$mcp_prefs" "/$1" get string / 2>/dev/null
}

# mcp_prefs_array_append <key-path> <value>
# Refuses duplicates. Returns 0 if appended, 1 if already present.
mcp_prefs_array_append() {
    local found=$("$plister" find string "$2" "$mcp_prefs" "/$1" 2>/dev/null)
    [ -n "$found" ] && return 1
    "$plister" append string "$2" "$mcp_prefs" "/$1"
}

# mcp_prefs_array_remove_value <key-path> <value>
mcp_prefs_array_remove_value() {
    local idx=$("$plister" find string "$2" "$mcp_prefs" "/$1" 2>/dev/null)
    [ -z "$idx" ] && return 1
    "$plister" delete "$mcp_prefs" "/$1/$idx"
}

# mcp_refresh_path_table <window_uuid> <table_id> <prefs_key>
# Repopulates a single-column path table from the prefs array.
mcp_refresh_path_table() {
    local window_uuid="$1"
    local table_id="$2"
    local key="$3"
    "$dialog" "$window_uuid" "$table_id" omc_table_remove_all_rows
    local buffer=$(mcp_prefs_array_list "$key")
    if [ -n "$buffer" ]; then
        printf "%s\n" "$buffer" | "$dialog" "$window_uuid" "$table_id" omc_table_set_rows_from_stdin
    fi
}
