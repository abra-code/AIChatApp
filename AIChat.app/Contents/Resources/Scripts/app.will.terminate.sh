#!/bin/sh

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"
echo "OMC_FRONT_PROCESS_ID: ${OMC_FRONT_PROCESS_ID}"

echo "Cancel any in-progress Hugging Face downloads"
if [ -n "$OMC_FRONT_PROCESS_ID" ]; then
    # Walk a process's parent chain; return 0 if ancestor_pid is found.
    is_our_descendant() {
        local pid="$1"
        while [ "$pid" -gt 1 ] 2>/dev/null; do
            local ppid
            ppid=$(/bin/ps -p "$pid" -o ppid= 2>/dev/null | /usr/bin/tr -d ' ')
            [ -z "$ppid" ] && return 1
            [ "$ppid" = "$OMC_FRONT_PROCESS_ID" ] && return 0
            pid="$ppid"
        done
        return 1
    }

    curl_pids=$(/usr/bin/pgrep -f "curl.*huggingface\.co" 2>/dev/null)
    while IFS= read -r curl_pid; do
        [ -z "$curl_pid" ] && continue
        is_our_descendant "$curl_pid" || continue
        curl_args=$(/bin/ps -p "$curl_pid" -o args= 2>/dev/null)
        dest_path=$(echo "$curl_args" | /usr/bin/grep -oE -- '-o [^ ]+' | /usr/bin/awk '{print $2}')
        echo "Stopping Hugging Face download curl pid=$curl_pid dest=$dest_path"
        kill -TERM "$curl_pid" 2>/dev/null
        if [ -n "$dest_path" ] && [ -f "$dest_path" ]; then
            echo "Removing partial download: $dest_path"
            /bin/rm -f "$dest_path"
        fi
    done <<< "$curl_pids"
fi

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
				# Kill associated mcp-proxy if it was registered for this server
				mcp_pid=$("$plister" get string "$prefs" "/server-info/$server_pid/mcp-proxy-pid" 2>/dev/null)
				kill_mcp_proxy "$mcp_pid"
				"$plister" delete "$prefs" "/server-info/$server_pid" 2>/dev/null
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
    				mcp_pid=$("$plister" get string "$prefs" "/server-info/$server_pid/mcp-proxy-pid" 2>/dev/null)
    				if [ -n "$mcp_pid" ]; then
    					echo "kill -TERM mcp-proxy pid=$mcp_pid"
    					kill -TERM "$mcp_pid" 2>/dev/null
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
