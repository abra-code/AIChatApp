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
		# wait until we get a response from server
		/usr/bin/curl "http://localhost:$port_num/slots" > /dev/null 2>&1
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

stop_orphaned_servers

# /usr/bin/curl "http://localhost:$port_num/slots" > /dev/null 2>&1

server_result=0

echo "Check if the required llama-server with selected model is already running"
running_process=$(/bin/ps -U $USER | /usr/bin/grep -E "$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server" | /usr/bin/grep -E "$port_num" | /usr/bin/grep -E "$AICHAT_MODEL_PATH")

if [ $? != 0 ]; then
	echo "Starting llama-server..."
	# start the server
	"$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server" --host 127.0.0.1 --port $port_num --path "$webui_dir_path" --model "$AICHAT_MODEL_PATH" &
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
	echo "$dialog $OMC_NIB_DLG_GUID 2 http://localhost:$port_num/"
	"$dialog" "$OMC_NIB_DLG_GUID" 2 "http://localhost:$port_num/"
else
	echo ""
	echo "$dialog $OMC_NIB_DLG_GUID 2 file://${webui_dir_path}/start_error.html?port=$port_num"
	"$dialog" "$OMC_NIB_DLG_GUID" 2 "file://${webui_dir_path}/start_error.html?port=$port_num"
fi

