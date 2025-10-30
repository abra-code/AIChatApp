#!/bin/sh

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"
echo "OMC_FRONT_PROCESS_ID: ${OMC_FRONT_PROCESS_ID}"

echo "Stop our servers and orphaned servers without host app running"
host_pids=$("$plister" get keys "$prefs" "/server-hosts")
while read -r host_pid; do
    echo "registered host_pid = $host_pid"
    # check if the registered host is our app 
    if [ "$host_pid" = "$OMC_FRONT_PROCESS_ID" ]; then
    	echo "host_pid = $host_pid is our app. Stop all servers we started"
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
    elif [ -n "$host_pid" ]; then
    	# not our app, check if the host process exists
    	echo "host_pid = $host_pid is other app instance"
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
