#!/bin/sh

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

webui_dir_path="$OMC_APP_BUNDLE_PATH/Contents/Resources/WebUI"

register_started_server()
{
	local host_pid="$1"
	local server_pid="$2"
	local model_path="$3"

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
		if [ "$seconds_count" -ge 20 ]; then
			local message=$(echo "Timed out after $seconds_count seconds while waiting for llama-server response.\n\nPlease try again")
			echo "$message"
			"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$message"
			result=13
			break
		elif [ "$seconds_count" -eq 5 ]; then
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

# Apple has shipped 8, 16, 24, 32, 36 & 48 GB of unified RAM in Apple Silicon Macs
# we aim to have a context size fitting N-4GB, except 8GB where we go more agressively towards 8GB (does it work?)
calculate_context_optimal_size()
{
	local model_path="$1"
	
	local file_size=$(/usr/bin/stat -f%z -L "${model_path}")
	# Convert file size to GB with bc
	local file_size_gb=$(echo "scale=2; ${file_size} / (1024 * 1024 * 1024)" | /usr/bin/bc -l)

	# Estimate model memory (1.2x rule)
	local model_memory_gb=$(echo "scale=2; ${file_size_gb} * 1.2" | /usr/bin/bc -l)

	local ram_bytes=$(/usr/sbin/sysctl -n hw.memsize)
	local ram_gb=$(echo "scale=0; ${ram_bytes} / (1024 * 1024 * 1024)" | /usr/bin/bc -l)
	# we need minimum 2GB of extra RAM not to destabilize the system 
	local model_exceeds_ram=$(echo "scale=2; ${model_memory_gb} > (${ram_gb} - 2)" | /usr/bin/bc -l)
	
	# ATTENTION: bc tool returns 1 for true and 0 for false when evaluating comparison expressions 
	if [ "$model_exceeds_ram" -eq 1 ]; then
	  # echo "Warning: Model requires ~${model_memory_gb} GB, but only $(($ram_gb - 2)) GB available after system reserve."
	  # try with tiny context size
	  context_size=1024
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
	
	# Conservative context estimate: ~0.15 GB per 1000 tokens (for 7B–13B models)
	local gb_per_thousand="0.15"
	local param_count=$(params_from_gguf_filename "${model_path}")
	
	if [ "${param_count}" -ge "30" ]; then
		gb_per_thousand="0.3"
	elif [ "${param_count}" -ge "20" ]; then
		gb_per_thousand="0.25"
	elif [ "${param_count}" -ge "14" ]; then
		gb_per_thousand="0.2"
	fi
	
	local context_per_gb=$(echo "scale=2; 1000 / ${gb_per_thousand}" | /usr/bin/bc -l)
	local context_size=$(echo "scale=2; ${available_for_context_gb} * ${context_per_gb}" | /usr/bin/bc -l)
	local size_kb=$(echo "scale=0; ${context_size}/1024" | /usr/bin/bc -l)

	echo $(( $size_kb * 1024 )) 

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
	"$HOME/.cache/huggingface/"*|"$HOME/.lmstudio/"*) ;;
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

# /usr/bin/curl "http://localhost:$port_num/slots" > /dev/null 2>&1

server_result=0

echo "Check if the required llama-server with selected model is already running"
running_process=$(/bin/ps -U $USER | /usr/bin/grep -E "$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server" | /usr/bin/grep -E "$port_num" | /usr/bin/grep -E "$AICHAT_MODEL_PATH")

if [ $? != 0 ]; then
	echo "Starting llama-server..."
	
	context_size=$(calculate_context_optimal_size "${AICHAT_MODEL_PATH}")
	
	# start the server
	echo "$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server --host 127.0.0.1 --port $port_num --ctx-size ${context_size} --context-shift --path $webui_dir_path --model $AICHAT_MODEL_PATH"

	"$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server" --host 127.0.0.1 --port $port_num --ctx-size ${context_size} --context-shift --path "$webui_dir_path" --model "$AICHAT_MODEL_PATH" &
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
			register_started_server "${OMC_FRONT_PROCESS_ID}" "${llama_server_pid}" "$AICHAT_MODEL_PATH"	
		fi
	else
		report_server_launch_failure
		server_result=$?
	fi
	
else
	llama_server_pid=$(echo "$running_process" | /usr/bin/grep -E --only-matching '^ *[[:digit:]]+ ' | /usr/bin/tr -d ' ')
	echo "llama-server already running with pid: $running_process"
	server_result=0
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

