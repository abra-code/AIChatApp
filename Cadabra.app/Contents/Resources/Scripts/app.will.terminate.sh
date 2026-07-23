#!/bin/sh

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.server.library.sh"

echo "[$(/usr/bin/basename "$0")]"
echo "OMC_FRONT_PROCESS_ID: ${OMC_FRONT_PROCESS_ID}"
srvlog "TERMINATE enter front=${OMC_FRONT_PROCESS_ID} app_pids=[$(srvlog_apppids)] hosts=[$(srvlog_hosts)] v2_servers=[$(srvlog_servers)]"

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

echo "Stop every llama-server this bundle owns (reliable at terminate: matches the server's own"
echo "binary + pinned port, independent of OMC_FRONT_PROCESS_ID / app-exe pgrep, both unreliable here)"
stop_all_bundle_servers

echo "Prune registry: stop any registered server whose host app is gone (other-instance leftovers)"
host_pids=$("$plister" get keys "$prefs" "/server-hosts")
while read -r host_pid; do
    echo "registered host_pid = $host_pid"
    # check if the registered host is our app 
    if [ "$host_pid" = "$OMC_FRONT_PROCESS_ID" ]; then
    	echo "host_pid = $host_pid is our app. Stop all servers we started"
    	srvlog "TERMINATE host=$host_pid == front -> OUR APP branch, killing its servers"
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
    elif [ -n "$host_pid" ]; then
    	# not our app, check if the host process exists
    	echo "host_pid = $host_pid is other app instance"
    	/bin/ps -p "$host_pid"
    	host_process_exists=$?
    	if [ "$host_process_exists" != 0 ]; then
    		echo "host process with pid=$host_pid does not exist, check if there are orphaned servers"
    		srvlog "TERMINATE host=$host_pid != front, host DEAD -> killing its orphaned servers"
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
			srvlog "TERMINATE host=$host_pid != front, host ALIVE -> LEAVING servers untouched (orphan bug if this host is really us)"
    	fi
    fi
done <<< "$host_pids"

# Belt-and-suspenders for the ACP agent: mlx-agent is the Chat element's child and its stdin
# closes when the app goes away, so it normally exits by itself (verified: on a hard kill of
# the app the agent is gone within seconds while llama-server survives). TERM any that is
# still alive anyway - a wedged agent would hold this session's MCP servers (replay, the
# bundled python servers) open, and those DO orphan. Identified by its own executable path
# under $OMC_APP_BUNDLE_PATH, the only reliable signal at terminate (OMC_FRONT_PROCESS_ID and
# app-exe pgrep are not - see the orphan-server postmortem). The reap below cannot cover this
# case: at terminate the agent is still parented to the app, and the reap only touches PPID 1.
agent_bin="$OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent"
for ap in $(/usr/bin/pgrep -f "$agent_bin" 2>/dev/null); do
    args=$(/bin/ps -p "$ap" -o args= 2>/dev/null)
    case "$args" in
        "$agent_bin"|"$agent_bin "*) ;;   # our bundled agent (guards a recycled pid)
        *) continue ;;
    esac
    echo "terminate: stopping bundle mlx-agent pid=$ap"
    kill -TERM "$ap" 2>/dev/null
done

# Reap the per-window agent-mode session dirs (Sessions/<window-uuid>/ holding each window's
# generated mcp-config.json + replay sandbox profile). They are regenerated on every launch and
# hold no durable state; at quit all windows are gone, and each agent already read its config at
# session/new, so removing the whole tree is safe (nothing re-reads it). This bounds the
# otherwise-unreaped accumulation across launches. ($mcp_app_support comes from the base library.)
if [ -n "$mcp_app_support" ] && [ -d "$mcp_app_support/Sessions" ]; then
    echo "terminate: removing agent session dirs under $mcp_app_support/Sessions"
    /bin/rm -rf "$mcp_app_support/Sessions"
fi

# Safety net: after the registry teardown above, sweep any of this bundle's llama-server
# / MCP server (bundled python, replay) / mlx-agent processes still orphaned on launchd —
# children stranded by an agent that died without tearing them down, and any leftovers
# from a crashed session. A still-running app instance's servers stay registered under a
# live host, so they are protected and left running.
reap_orphaned_bundle_processes

srvlog "TERMINATE exit hosts_after=[$(srvlog_hosts)] v2_servers_after=[$(srvlog_servers)]"
