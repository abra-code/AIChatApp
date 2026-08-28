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
        echo "Stopping Hugging Face download curl pid=$curl_pid"
        kill -TERM "$curl_pid" 2>/dev/null
        # The partial is KEPT, and that is a change: this used to dig the destination out of
        # curl's argv and delete it. It had to, because curl wrote straight to the model's real
        # name and leaving the fragment there meant the picker listed a corrupt model on the next
        # launch. Downloads are staged now (see aichat.hf.browse.download.sh): what is on disk is
        # a "<final>.part" that no reader looks at and the next Download resumes from. Deleting it
        # would only throw away however many gigabytes had arrived, for a quit.
    done <<< "$curl_pids"
fi

echo "Stop every llama-server this bundle owns (reliable at terminate: matches the server's own"
echo "binary + pinned port, independent of OMC_FRONT_PROCESS_ID / app-exe pgrep, both unreliable here)"
stop_all_bundle_servers

echo "Prune registry: our own servers, plus any registered server whose host app is gone"
prune_server_registry "$OMC_FRONT_PROCESS_ID"

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
