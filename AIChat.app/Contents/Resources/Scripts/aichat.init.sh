#!/bin/sh

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

webui_dir_path="$OMC_APP_BUNDLE_PATH/Contents/Resources/WebUI"

register_started_server()
{
	local host_pid="$1"
	local server_pid="$2"
	local model_path="$3"
	local dialog_guid="$4"
	local server_port="$5"
	local model_size="$6"

	echo "register_started_server"

	if ! [ -f "$prefs" ]; then
		echo "creating new $prefs"
		"$plister" set dict "$prefs" '/'
		echo "plister result: $?"
	else
		echo "Preferences file exists: $prefs"
	fi
	
	# record the information about this app starting the server
	echo "check if prefs have /server-hosts"
	"$plister" get type "$prefs" '/server-hosts'
	has_server_hosts=$?
	echo "plister result: $has_server_hosts"
	if [ "$has_server_hosts" != 0 ]; then
		echo "insert server-hosts in prefs"
		"$plister" insert "server-hosts" dict "$prefs" '/'
		echo "plister result: $?"
	else
		echo "/server-hosts exists in prefs"
	fi
	
	echo "check if prefs have /server-hosts/$host_pid"
	"$plister" get type "$prefs" "/server-hosts/$host_pid"
	has_this_host=$?
	echo "plister result: $has_this_host"
	if [ "$has_this_host" != 0 ]; then
		echo "insert $host_pid in /server-hosts"
		"$plister" insert "$host_pid" dict "$prefs" '/server-hosts'
		echo "plister result: $?"
	else
		echo "prefs has /server-hosts/$host_pid"
	fi
	
	echo "check if prefs have /server-hosts/$host_pid/$server_pid"
	"$plister" get type "$prefs" "/server-hosts/$host_pid/$server_pid"
	has_this_server_pid=$?
	echo "plister result: $has_this_server_pid"
	if [ "$has_this_server_pid" != 0 ]; then
		echo "In /server-hosts/$host_pid insert key $server_pid, model value: $model_path"
		"$plister" insert "$server_pid" string "$model_path" "$prefs" "/server-hosts/$host_pid"
		echo "plister result: $?"
	else
		echo "error: server_pid $server_pid already registered for newly started server - this is unexpected"
	fi

	# Store per-server metadata (port, size, dialog guid) keyed by server_pid.
	# dialog_guid lets cancel.sh close only this window's server.
	# size lets calculate_total_server_ram() sum running load for RAM warnings.
	"$plister" get type "$prefs" "/server-info"
	if [ $? != 0 ]; then
		"$plister" insert "server-info" dict "$prefs" '/'
	fi
	"$plister" get type "$prefs" "/server-info/$server_pid"
	if [ $? != 0 ]; then
		"$plister" insert "$server_pid" dict "$prefs" '/server-info'
	fi
	if [ -n "$server_port" ]; then
		"$plister" insert "port" string "$server_port" "$prefs" "/server-info/$server_pid"
	fi
	if [ -n "$model_size" ]; then
		"$plister" insert "size" string "$model_size" "$prefs" "/server-info/$server_pid"
	fi
	if [ -n "$dialog_guid" ]; then
		"$plister" insert "dialog" string "$dialog_guid" "$prefs" "/server-info/$server_pid"
	fi
	echo "registered server-info port=$server_port size=$model_size dialog=$dialog_guid"
}

stop_orphaned_servers()
{
	echo "Stop orphaned servers without host app running"
	host_pids=$("$plister" get keys "$prefs" "/server-hosts")
	while read -r host_pid; do
		echo "registered host_pid = $host_pid"
		if [ -n "$host_pid" ]; then
			/bin/ps -p "$host_pid"
			host_process_exists=$?
			if [ "$host_process_exists" != 0 ]; then
				echo "host process with pid=$host_pid does not exist, check if there are orphaned servers"
				server_pids=$("$plister" get keys "$prefs" "/server-hosts/$host_pid")
				while read -r server_pid; do
					if [ -n "$server_pid" ]; then
						/bin/ps -p "$server_pid"
						server_process_exists=$?
						if [ "$server_process_exists" = 0 ]; then
							echo "kill -TERM $server_pid"
							kill -TERM "$server_pid"
						fi
						"$plister" delete "$prefs" "/server-info/$server_pid" 2>/dev/null
					fi
				done <<< "$server_pids"
				"$plister" delete "$prefs" "/server-hosts/$host_pid"
			else
				echo "other app instance with pid = $host_pid is running. leave its servers untouched"
			fi
		fi
	done <<< "$host_pids"
}

wait_for_server_response()
{
	local result=0
	local seconds_count=0
	
	while true; do
		# wait until model is fully loaded — /health returns 200 when ready, 503 while loading
		/usr/bin/curl --fail --silent "http://localhost:$port_num/health" > /dev/null 2>&1
		local server_response_result=$?
		if [ "$server_response_result" = 0 ]; then
			echo "server became responsive after $seconds_count seconds"
			break
		fi
		
		# or 20 seconds pass
		seconds_count=$((seconds_count + 1))
		if [ "$seconds_count" -ge 30 ]; then
			local message=$(echo "Timed out after $seconds_count seconds while waiting for llama-server response.\n\nPlease try again")
			echo "$message"
			"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$message"
			result=13
			break
		elif [ "$seconds_count" -eq 10 ]; then
			echo "$dialog $OMC_NIB_DLG_GUID 2 file://${webui_dir_path}/start_slow.html"
			"$dialog" "$OMC_NIB_DLG_GUID" 2 "file://${webui_dir_path}/start_slow.html"
		fi
		
		sleep 1
	done
	
	return "$result"
}

report_server_launch_failure()
{
	local message=$(echo "llama-server failed to launch! \n\nVerify if the selected large language model is supported by llama.cpp engine.")
	echo "$message"
	"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$message"
	return 11
}

params_from_gguf_filename()
{
	local model_path="$1"
	local filename=$(/usr/bin/basename "${model_path}")
	
	# Extract SizeLabel (e.g., 7B, 8x7B, 13B, 3.8B)
	local size_label=$(echo "$filename" | /usr/bin/grep -oE '([0-9]+x)?[0-9]+\.?[0-9]*[Bb]' | /usr/bin/tail -n -1)

	# Handle MoE: extract second number (e.g., 8x7B → 7B)
	if [[ "$size_label" == *x*B ]]; then
	  size_label=$(echo "$size_label" | /usr/bin/grep -oE '[0-9]+\.?[0-9]*[Bb]')
	fi

	# Extract numeric part and unit
	local number=$(echo "$size_label" | /usr/bin/grep -oE '[0-9]+\.?[0-9]*')
	local unit=$(echo "$size_label" | /usr/bin/grep -oE '[Bb]')

	if [ "$unit" = "B" ] || [ "$unit" = "b" ]; then
		# rounded params count
	  printf "%.0f\n" "${number}"
	  return 0
	fi

	echo "0"
}

# Returns the bytes-per-element scale factor for a KV cache quantization type,
# relative to f16 (1.00). Used by calculate_context_optimal_size.
# Values are derived from llama.cpp block sizes:
#   q8_0  → 34 B / 32 el = 1.0625 B/el  →  1.0625/2 = 0.53
#   q5_0  → 22 B / 32 el = 0.6875 B/el  →  0.6875/2 = 0.34
#   q5_1  → 24 B / 32 el = 0.75   B/el  →  0.75/2   = 0.38
#   q4_0  → 18 B / 32 el = 0.5625 B/el  →  0.5625/2 = 0.28
#   q4_1  → 20 B / 32 el = 0.625  B/el  →  0.625/2  = 0.31
#   iq4_nl→ 18 B / 32 el = 0.5625 B/el  →  same as q4_0
kv_cache_scale()
{
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

# calculate_context_optimal_size <model_path> [cache_type_k] [cache_type_v]
# Estimates the largest context window that fits comfortably in unified memory.
# KV cache type parameters (default: f16) scale the per-token KV cost so the
# result automatically reflects the chosen quantization.
calculate_context_optimal_size()
{
	local model_path="$1"
	local cache_type_k="${2:-f16}"
	local cache_type_v="${3:-f16}"
	
	local file_size=$(/usr/bin/stat -f%z -L "${model_path}")
	# Convert file size to GB with bc
	local file_size_gb=$(echo "scale=2; ${file_size} / (1024 * 1024 * 1024)" | /usr/bin/bc -l)

	# Model runtime memory: weights are mmap'd so the on-disk file size is the
	# in-memory footprint, plus a fixed ~512 MB compute-buffer overhead.
	# The old 1.2× rule over-penalised large models (e.g. 40 GB → 48 GB claimed,
	# reality is ~40.5 GB), leaving far less room for context than available.
	local model_memory_gb=$(echo "scale=2; ${file_size_gb} + 0.5" | /usr/bin/bc -l)

	local ram_bytes=$(/usr/sbin/sysctl -n hw.memsize)
	local ram_gb=$(echo "scale=0; ${ram_bytes} / (1024 * 1024 * 1024)" | /usr/bin/bc -l)
	# we need minimum 2GB of extra RAM not to destabilize the system 
	local model_exceeds_ram=$(echo "scale=2; ${model_memory_gb} > (${ram_gb} - 2)" | /usr/bin/bc -l)
	
	# ATTENTION: bc tool returns 1 for true and 0 for false when evaluating comparison expressions 
	if [ "$model_exceeds_ram" -eq 1 ]; then
	  context_size=4096
	  echo "${context_size}"
	  return 0
	fi
	
	local extra_ram_gb=$(echo "scale=2; ${ram_gb} - ${model_memory_gb}" | /usr/bin/bc -l)
	# rounded to the nearest integer
	extra_ram_gb=$(printf "%.0f" "${extra_ram_gb}")
	
	# the more we have extra RAM the bigger we can pick the RAM reserve for the system and other processes
	# 2GB is the smallest default, let's check if we can make it higher
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
	
	# f16 KV cache cost per 1K tokens (K + V, both heads).
	# Modern models use GQA so the real driver is n_layers × n_kv_heads, not
	# total param count. Empirical values (2 × n_layers × n_kv_heads × head_dim × 2 B):
	#   ≤12B  GQA  e.g. Llama 3.1 8B  (32L × 8kv × 128d) → 0.131 GB/1K  → use 0.13
	#   ~14B  GQA  e.g. Qwen 2.5 14B  (48L × 8kv × 128d) → 0.197 GB/1K  → use 0.19
	#   ~32B  GQA  e.g. Qwen 2.5 32B  (64L × 8kv × 128d) → 0.262 GB/1K  → use 0.25
	#   ~70B  GQA  e.g. Llama 3.3 70B (80L × 8kv × 128d) → 0.328 GB/1K  → use 0.31
	# Param count from the filename is used as a proxy for model class.
	local param_count=$(params_from_gguf_filename "${model_path}")
	local gb_per_thousand="0.13"

	if [ "${param_count}" -ge "60" ]; then
		gb_per_thousand="0.31"
	elif [ "${param_count}" -ge "25" ]; then
		gb_per_thousand="0.25"
	elif [ "${param_count}" -ge "12" ]; then
		gb_per_thousand="0.19"
	fi

	# Apply KV cache quantization scale. gb_per_thousand covers K + V equally
	# (each half), so the effective cost is (scale_k + scale_v) / 2 × base cost.
	local scale_k=$(kv_cache_scale "$cache_type_k")
	local scale_v=$(kv_cache_scale "$cache_type_v")
	local gb_per_thousand_effective=$(echo "scale=4; ${gb_per_thousand} * (${scale_k} + ${scale_v}) / 2" | /usr/bin/bc -l)

	local context_per_gb=$(echo "scale=2; 1000 / ${gb_per_thousand_effective}" | /usr/bin/bc -l)
	local context_size=$(echo "scale=2; ${available_for_context_gb} * ${context_per_gb}" | /usr/bin/bc -l)
	local size_kb=$(echo "scale=0; ${context_size}/1024" | /usr/bin/bc -l)
	local ctx=$(( size_kb * 1024 ))

	# Clamp: at least 4096 (minimum useful chat context); at most 131072 (128K) —
	# the widest context most current models are trained for and a practical ceiling
	# on KV cache size regardless of how much headroom a high-RAM machine reports.
	[ "${ctx}" -lt 4096   ] && ctx=4096
	[ "${ctx}" -gt 131072 ] && ctx=131072

	echo "${ctx}"
	return 0
}

echo "$dialog $OMC_NIB_DLG_GUID 2 file://${webui_dir_path}/start.html"
"$dialog" "$OMC_NIB_DLG_GUID" 2 "file://${webui_dir_path}/start.html"
echo ""

echo "OMC_CURRENT_COMMAND_GUID: ${OMC_CURRENT_COMMAND_GUID}"
echo "OMC_NIB_DLG_GUID: ${OMC_NIB_DLG_GUID}"
echo "OMC_FRONT_PROCESS_ID: ${OMC_FRONT_PROCESS_ID}"
echo "AICHAT_MODEL_PATH: $AICHAT_MODEL_PATH"

llama_server_pid=""

if [ -z "${AICHAT_MODEL_PATH}" ] && [ -n "${OMC_OBJ_PATH}" ]; then
	# from objected dropped on app
	AICHAT_MODEL_PATH="$OMC_OBJ_PATH"
	echo "GGUF file dropped on app: AICHAT_MODEL_PATH: $AICHAT_MODEL_PATH"
elif [ -z "$AICHAT_MODEL_PATH" ]; then
	AICHAT_MODEL_PATH=$("$pasteboard" "AICHAT_MODEL_PATH" get);
	echo "GGUF from open dialog: AICHAT_MODEL_PATH: $AICHAT_MODEL_PATH"
	"$pasteboard" "AICHAT_MODEL_PATH" set ""
fi

if [ -z "$AICHAT_MODEL_PATH" ]; then
	alert_message="Model path not specified"
	echo "$alert_message"
	"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$alert_message"
	exit 1
fi

echo "AICHAT_MODEL_PATH = $AICHAT_MODEL_PATH"

# Persist model path as a recent if it lives outside the standard caches.
# The model selector init script reads this list and deduplicates against cache results.
case "$AICHAT_MODEL_PATH" in
	"$HOME/.cache/huggingface/"*|"$HOME/.lmstudio/"*|\
	"$HOME/.ollama/"*|"$HOME/.localai/"*|\
	"$HOME/Library/Application Support/Jan/"*|\
	"$HOME/Library/Application Support/nomic.ai/"*) ;;
	*)
		_prefs_domain="com.abracode.AIChat"
		_prefs_key="recentModelPaths"
		_existing=$(/usr/bin/defaults read "$_prefs_domain" "$_prefs_key" 2>/dev/null | \
			/usr/bin/grep -E '^\s+"' | \
			/usr/bin/sed 's/^[[:space:]]*"\(.*\)",\{0,1\}$/\1/')
		# Build new list: new path first, existing minus duplicates, max 10
		_new_list="$AICHAT_MODEL_PATH"
		while IFS= read -r _p; do
			[ -n "$_p" ] || continue
			[ "$_p" = "$AICHAT_MODEL_PATH" ] && continue
			_new_list="${_new_list}
${_p}"
		done <<< "$_existing"
		# Write back using PlistBuddy so no bash arrays are needed
		_plist="$HOME/Library/Preferences/${_prefs_domain}.plist"
		/usr/libexec/PlistBuddy -c "Delete :${_prefs_key}" "$_plist" 2>/dev/null
		/usr/libexec/PlistBuddy -c "Add :${_prefs_key} array" "$_plist"
		_i=0
		while IFS= read -r _p && [ "$_i" -lt 10 ]; do
			[ -n "$_p" ] || continue
			/usr/libexec/PlistBuddy -c "Add :${_prefs_key}:${_i} string $_p" "$_plist"
			_i=$((_i + 1))
		done <<< "$_new_list"
		echo "saved recent model (${_i} entries)"
		;;
esac

stop_orphaned_servers

server_result=0

# Assign a free port for this session
port_num=$(find_free_port)
if [ -z "$port_num" ]; then
	"$alert" --level stop --title "$APPLET_NAME" --ok "OK" "No free ports available (checked 8088–8097). Close a running chat session and try again."
	exit 1
fi
echo "Using port $port_num"

echo "Starting llama-server..."

KV_CACHE_TYPE_K="q8_0"
KV_CACHE_TYPE_V="q8_0"
context_size=$(calculate_context_optimal_size "${AICHAT_MODEL_PATH}" "${KV_CACHE_TYPE_K}" "${KV_CACHE_TYPE_V}")
model_size=$(/usr/bin/stat -f%z -L "${AICHAT_MODEL_PATH}" 2>/dev/null)

# ── MCP proxy setup ───────────────────────────────────────────────────────────
use_tools=$("$pasteboard" "AICHAT_USE_TOOLS" get)
"$pasteboard" "AICHAT_USE_TOOLS" set ""
echo "AICHAT_USE_TOOLS = $use_tools"

mcp_app_support="$HOME/Library/Application Support/AIChat"
mcp_proxy_json="$mcp_app_support/mcp-proxy.json"
llama_ui_mcp_json="$mcp_app_support/llama-ui-mcp.json"
mcp_proxy_log="$mcp_app_support/logs/mcp-proxy.log"

if [ "$use_tools" = "true" ]; then
    /bin/mkdir -p "$mcp_app_support/logs"

    mcp_proxy_port=$(find_free_port_in 8101 8110)
    if [ -z "$mcp_proxy_port" ]; then
        echo "No free port for mcp-proxy (checked 8101–8110) — skipping MCP"
    fi

    if [ -n "$mcp_proxy_port" ]; then
        echo "Generating MCP configs (proxy port $mcp_proxy_port)..."
        generate_mcp_configs "$OMC_APP_BUNDLE_PATH" "$mcp_proxy_port" "$mcp_proxy_json" "$llama_ui_mcp_json"
        launch_mcp_proxy "$OMC_APP_BUNDLE_PATH" "$mcp_proxy_port" "$mcp_proxy_json" "$mcp_proxy_log"
    fi
else
    echo "Tools disabled — skipping MCP proxy"
fi

# ── Launch llama-server ───────────────────────────────────────────────────────
llama_server_bin="$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server"

# Base args — always present
llama_args=(
    --host 127.0.0.1 --port "$port_num"
    --ctx-size "${context_size}"
    --cache-type-k "${KV_CACHE_TYPE_K}"
    --cache-type-v "${KV_CACHE_TYPE_V}"
    --context-shift
    --sleep-idle-seconds 600
    --path "$webui_dir_path"
    --model "$AICHAT_MODEL_PATH"
    --jinja
)

# Agentic / MCP flags — only when mcp-proxy is running
if [ -n "$mcp_proxy_pid" ] && [ -f "$llama_ui_mcp_json" ]; then
    llama_args+=(--webui-mcp-proxy --webui-config-file "$llama_ui_mcp_json")
    echo "MCP proxy active — enabling --webui-mcp-proxy and --webui-config-file"
fi

echo "${llama_server_bin} ${llama_args[*]}"
"${llama_server_bin}" "${llama_args[@]}" &
llama_server_pid=$!
if [ "$llama_server_pid" != "" ]; then
	sleep 1
	/bin/ps -p "$llama_server_pid"
	server_process_exists=$?
	if [ "$server_process_exists" != 0 ]; then
		# server exited. most likely something wrong with selected gguf model
		report_server_launch_failure
		server_result=$?
	else
		# server process running, check if it is responsive
		wait_for_server_response
		server_result=$?

		echo "Register server with pid $llama_server_pid"
		register_started_server "${OMC_FRONT_PROCESS_ID}" "${llama_server_pid}" "$AICHAT_MODEL_PATH" "$OMC_NIB_DLG_GUID" "$port_num" "$model_size"

		# Store mcp-proxy pid so terminate.sh can kill it alongside llama-server
		if [ -n "$mcp_proxy_pid" ]; then
			"$plister" insert "mcp-proxy-pid" string "$mcp_proxy_pid" "$prefs" "/server-info/$llama_server_pid"
			echo "registered mcp-proxy-pid=$mcp_proxy_pid under server-info/$llama_server_pid"
		fi
	fi
else
	report_server_launch_failure
	server_result=$?
fi

if [ "$server_result" = 0 ]; then
	echo ""
	# Append ?v=VERSION so WKWebView fetches index.html fresh when the WebUI changes.
	# The version token comes from a file written by update-llama-cpp.sh alongside the
	# WebUI files. Without it the URL falls back to plain localhost (no cache-busting).
	webui_version_file="${webui_dir_path}/version"
	webui_version=""
	if [ -f "$webui_version_file" ]; then
		webui_version=$(/bin/cat "$webui_version_file")
	fi
	if [ -n "$webui_version" ]; then
		webui_url="http://localhost:${port_num}/?v=${webui_version}"
	else
		webui_url="http://localhost:${port_num}/"
	fi
	echo "$dialog $OMC_NIB_DLG_GUID 2 $webui_url"
	"$dialog" "$OMC_NIB_DLG_GUID" 2 "$webui_url"
else
	echo ""
	echo "$dialog $OMC_NIB_DLG_GUID 2 file://${webui_dir_path}/start_error.html?port=$port_num"
	"$dialog" "$OMC_NIB_DLG_GUID" 2 "file://${webui_dir_path}/start_error.html?port=$port_num"
fi

