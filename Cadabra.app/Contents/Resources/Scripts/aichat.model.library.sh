#!/bin/sh
# aichat.model.library.sh
# Model session helpers used by the model-loading flows: total RAM of running models,
# the RAM-pressure warning shown before loading a new model, and activating an existing
# chat window when the same model is already running. Sources the base library for
# $prefs / $dialog / $alert / format_bytes. Sourced by aichat.init and the model-open
# handlers (hf.browse.download, open.from.file.browser, select.local.model.ok).
[ -n "${__AICHAT_MODEL_LIB:-}" ] && return 0
__AICHAT_MODEL_LIB=1
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

# ── Engine detection and per-engine model facts ───────────────────────────────
# The app drives two engines from one picker, so exactly ONE place decides what a path IS;
# the picker rows, the info pane, the RAM check and chat.init's argv all dispatch on this
# rather than re-deriving it. The distinction is a SHAPE difference, not a naming
# convention: a GGUF model is a single FILE, an MLX model is a DIRECTORY holding
# config.json + *.safetensors shards. That is why callers cannot just stat the path, and
# why "size" and "display name" mean two different computations per engine.

# model_engine <path> -> "gguf" | "mlx" | "" (unknown, or no longer on disk)
model_engine() {
	case "$1" in
		*.gguf) [ -f "$1" ] && { echo "gguf"; return 0; } ;;
	esac
	if [ -d "$1" ] && [ -f "$1/config.json" ]; then
		# config.json alone is not enough - HF snapshot dirs of GGUF repos carry one too.
		# The shards are what make it loadable. -maxdepth 2 because shards normally sit
		# beside config.json but some repos nest them one level down; bounded so this stays
		# cheap enough to call per picker row.
		local _st
		_st=$(/usr/bin/find -L "$1" -maxdepth 2 -name '*.safetensors' -type f 2>/dev/null | /usr/bin/head -n 1)
		[ -n "$_st" ] && { echo "mlx"; return 0; }
	fi
	echo ""
	return 1
}

# model_display_label <path> -> the name to show for a model.
# GGUF: the FILENAME carries the quantisation (...-Q5_K_S), which is exactly what the user
# is choosing between, so keep it and only drop the extension.
# MLX: the path is .../models--<org>--<name>/snapshots/<hash>/, whose leaf is a content
# hash - useless as a label - so surface "<org>/<name>" instead.
# ORDER IS LOAD-BEARING: the .gguf test must run FIRST, because a GGUF living in the HF
# cache also matches the snapshot pattern and would otherwise be relabelled to org/name,
# silently losing the quant - the one thing that distinguishes two rows of the same model.
model_display_label() {
	case "$1" in
		*.gguf) /usr/bin/basename "$1" .gguf; return 0 ;;
	esac
	case "$1" in
		*"/models--"*"/snapshots/"*)
			printf '%s' "$1" | /usr/bin/sed -E 's#.*/models--([^/]+)/snapshots/.*#\1#; s#--#/#g' ;;
		*) /usr/bin/basename "$1" ;;
	esac
}

# model_dir_bytes <dir> -> total bytes of the model's *.safetensors shards, summed RECURSIVELY
# (find, not a top-level glob) so a repo whose shards live in a subdirectory is still measured.
# Used for the MLX RAM check (weights dominate the footprint).
model_dir_bytes() {
	local total=0
	local st=""
	local sz=""
	while IFS= read -r st; do
		[ -n "$st" ] || continue
		sz=$(/usr/bin/stat -f%z -L "$st" 2>/dev/null || echo 0)
		total=$((total + sz))
	done <<EOF
$(/usr/bin/find -L "$1" -name "*.safetensors" -type f 2>/dev/null)
EOF
	echo "$total"
}

# model_supports_tools <path> [engine] -> 0 when the model can drive the agent's tool loop.
# Both engines answer the SAME question - does the chat template know how to render tool
# definitions and tool calls - but the template lives in a different container per engine:
# GGUF metadata vs tokenizer_config.json. A cheap read either way; neither loads the model.
# Pass <engine> when the caller already knows it, to skip a re-detect.
model_supports_tools() {
	local _eng="${2:-$(model_engine "$1")}"
	case "$_eng" in
		gguf)
			local _py="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
			local _chk="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/gguf_check_tools.py"
			[ -x "$_py" ] && [ -f "$_chk" ] || return 1
			[ "$("$_py" "$_chk" "$1" 2>/dev/null)" = "true" ] ;;
		mlx)
			# Extract the TEMPLATE, then ask the same question the gguf branch asks of it
			# ("tool_call" in tmpl), so the two engines cannot answer differently.
			# Two traps a grep over tokenizer_config.json falls into:
			#  - FALSE POSITIVE: the file also carries added_tokens_decoder, so a model that
			#    merely has <|tool_call_start|> in its VOCABULARY matches even when its
			#    template never renders a tool. A false badge also auto-enables the tools
			#    toggle in the picker, which spawns MCP servers the user did not ask for.
			#  - FALSE NEGATIVE: newer HF exports put the template in chat_template.jinja and
			#    leave no chat_template key here at all.
			local _py="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
			[ -x "$_py" ] || return 1
			"$_py" - "$1" <<'PY' 2>/dev/null
import json, os, sys
d = sys.argv[1]
parts = []
# A model may ship the template in EITHER place, and LFM2 ships it in both. Rather than
# guess which one mlx-swift-lm's tokenizer will actually pick at load time, read both and
# ask whether tools appear in either. Getting the precedence wrong would mean badging on
# the template the runtime does not use; reading both cannot.
jinja = os.path.join(d, "chat_template.jinja")
if os.path.isfile(jinja):
    with open(jinja, encoding="utf-8", errors="replace") as f:
        parts.append(f.read())
try:
    with open(os.path.join(d, "tokenizer_config.json"), encoding="utf-8", errors="replace") as f:
        v = json.load(f).get("chat_template", "")
    # Older exports allow a LIST of {name, template} variants; check them all.
    parts.append(v if isinstance(v, str) else json.dumps(v))
except Exception:
    pass
sys.exit(0 if any("tool_call" in p for p in parts) else 1)
PY
			;;
		*) return 1 ;;
	esac
}

# model_bytes <path> [engine] -> on-disk size in bytes (0 if unknown).
# GGUF is one file; MLX is the SUM of its shards. find (not a top-level glob) so a repo that
# nests its shards is still measured - a 30GB model reported as 0 would silently defeat the
# RAM-pressure warning, which is the one guard standing between the user and a swap storm.
model_bytes() {
	local _eng="${2:-$(model_engine "$1")}"
	case "$_eng" in
		gguf) /usr/bin/stat -f%z -L "$1" 2>/dev/null || echo 0 ;;
		mlx)
			local _total=0 _st _sz
			while IFS= read -r _st; do
				[ -n "$_st" ] || continue
				_sz=$(/usr/bin/stat -f%z -L "$_st" 2>/dev/null || echo 0)
				_total=$((_total + _sz))
			done <<EOF
$(/usr/bin/find -L "$1" -name "*.safetensors" -type f 2>/dev/null)
EOF
			echo "$_total" ;;
		*) echo 0 ;;
	esac
}

# calculate_total_server_ram()
# Sums model sizes (from /server-info) for all currently live registered servers.
# Prints the total in bytes.
#
# NOTE (two engines): this counts llama-server registrations only. A loaded MLX model holds
# its weights inside mlx-agent, which registers no server, so it is invisible here and the
# advisory under-reports when an MLX chat is open. Accepted deliberately: this is a soft
# 75% warning and the agent's own 90% hard gate is what actually refuses a load.
calculate_total_server_ram() {
    local total=0
    [ ! -f "$prefs" ] && echo "0" && return 0

    local host_pids=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
    local _ctr_host_pid
    while IFS= read -r _ctr_host_pid; do
        [ -z "$_ctr_host_pid" ] && continue
        /bin/ps -p "$_ctr_host_pid" > /dev/null 2>&1 || continue
        local server_pids=$("$plister" get keys "$prefs" "/server-hosts/$_ctr_host_pid" 2>/dev/null)
        local _ctr_server_pid
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
    local _act_host_pid
    while IFS= read -r _act_host_pid; do
        [ -z "$_act_host_pid" ] && continue
        /bin/ps -p "$_act_host_pid" > /dev/null 2>&1 || continue
        local server_pids=$("$plister" get keys "$prefs" "/server-hosts/$_act_host_pid" 2>/dev/null)
        local _act_server_pid
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
