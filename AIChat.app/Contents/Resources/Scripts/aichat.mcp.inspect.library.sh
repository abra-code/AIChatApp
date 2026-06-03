# aichat.mcp.inspect.library.sh
# ──────────────────────────────────────────────────────────────
# MCP Servers inspector (aichat.mcp.inspect dialog)
# ──────────────────────────────────────────────────────────────
# Read-only window that lists the servers the most recent agentic session
# launched (from llama-ui-mcp.json, written by generate_mcp_configs.py), shows
# each endpoint URL, and — on demand, per server — fetches tools/list over the
# proxy's Streamable HTTP endpoint via mcp_inspect.py so the user can inspect
# each tool's JSON input schema. The control IDs below match aichat.mcp.inspect.json.
#
# Sourced ONLY by the aichat.mcp.inspect.* handler scripts (not by every applet
# script), which keeps this inspector-specific code out of the base library.
# It sources aichat.server.library.sh for the shared primitives it relies on:
#   build_agent_path / kill_mcp_proxy (server lib) and, transitively from the base
#   library, $dialog / $plister / $prefs / mcp_app_support / pb_set / pb_get.
[ -n "${__AICHAT_MCP_INSPECT_LIB:-}" ] && return 0
__AICHAT_MCP_INSPECT_LIB=1

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.server.library.sh"

# Scratch dir for cached per-server tools/list results and the current schema.
mcp_inspect_dir="$mcp_app_support/inspect"

# mcp_url_port <url>  ->  the TCP port from an http://host:port/path URL (empty if none)
mcp_url_port() {
    printf '%s' "$1" | /usr/bin/sed -nE 's#^[a-z]+://[^/:]+:([0-9]+)(/.*)?$#\1#p'
}

# mcp_url_shortname <url>  ->  the server segment of .../servers/<name>/mcp
mcp_url_shortname() {
    printf '%s' "$1" | /usr/bin/sed -nE 's#.*/servers/([^/]+)/mcp.*#\1#p'
}

# mcp_port_listening <port>  ->  0 if a process is LISTENing on tcp:<port>.
# The LISTEN filter is essential: a plain `lsof -ti tcp:<port>` also matches the
# llama-server client connected to the proxy, and the stop path must never target
# that — only the proxy's own listening socket.
mcp_port_listening() {
    [ -n "$1" ] || return 1
    /usr/sbin/lsof -ti tcp:"$1" -sTCP:LISTEN > /dev/null 2>&1
}

# mcp_stop_proxy_on_port <port>
# Stops the mcp-proxy instance listening on <port> and its child tool server.
# Only the LISTENing pid is targeted (see mcp_port_listening), then kill_mcp_proxy
# snapshots and terminates its subtree — so a connected llama-server is left alone.
mcp_stop_proxy_on_port() {
    local port="$1"
    [ -n "$port" ] || return 1
    local listener
    listener=$(/usr/sbin/lsof -ti tcp:"$port" -sTCP:LISTEN 2>/dev/null)
    [ -z "$listener" ] && return 0
    kill_mcp_proxy "$listener"
}

# mcp_start_proxy_instance <name> <port>  ->  prints the new proxy pid, or empty on failure
# Relaunches one mcp-proxy instance from the per-server config generate_mcp_configs.py
# wrote (mcp-proxy-<name>.json), on its own port, exactly as launch_mcp_proxy does —
# same agent PATH (so the Local/shell server sees the user's full terminal PATH) and
# --pass-environment. Waits for the port to come up before reporting success.
mcp_start_proxy_instance() {
    local name="$1" port="$2"
    [ -n "$name" ] && [ -n "$port" ] || { echo ""; return 1; }

    local python3="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
    local packages_dir="$OMC_APP_BUNDLE_PATH/Contents/Library/Packages"
    local cfg="$mcp_app_support/mcp-proxy-$name.json"
    [ -f "$python3" ] || { echo ""; return 1; }
    [ -f "$cfg" ]     || { echo ""; return 1; }

    /bin/mkdir -p "$mcp_app_support/logs"
    local log="$mcp_app_support/logs/mcp-proxy-$name.log"
    local agent_path
    agent_path="$(build_agent_path)"

    PATH="$agent_path" PYTHONPATH="$packages_dir" "$python3" -m mcp_proxy \
        --host 127.0.0.1 \
        --port "$port" \
        --allow-origin '*' \
        --pass-environment \
        --named-server-config "$cfg" \
        >> "$log" 2>&1 &
    local pid=$!

    # Wait up to ~4s for the listener to bind (or the proxy to die).
    local i=0
    while [ "$i" -lt 8 ]; do
        mcp_port_listening "$port" && { echo "$pid"; return 0; }
        /bin/ps -p "$pid" > /dev/null 2>&1 || break
        sleep 0.5
        i=$((i + 1))
    done
    echo ""
    return 1
}

# mcp_owning_server_pid  ->  prints a live llama-server pid that owns this session's
# proxies (i.e. has a /server-info/<pid>/mcp-proxy-pid registered), or nothing.
# Used so a proxy started/restarted from this dialog is re-registered under its
# session and not swept by reap_orphaned_bundle_processes at the next launch.
mcp_owning_server_pid() {
    [ -f "$prefs" ] || return 1
    local hosts host servers s mcp
    hosts=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null) || return 1
    while IFS= read -r host; do
        [ -z "$host" ] && continue
        kill -0 "$host" 2>/dev/null || continue
        servers=$("$plister" get keys "$prefs" "/server-hosts/$host" 2>/dev/null)
        while IFS= read -r s; do
            [ -z "$s" ] && continue
            kill -0 "$s" 2>/dev/null || continue
            mcp=$("$plister" get string "$prefs" "/server-info/$s/mcp-proxy-pid" 2>/dev/null)
            if [ -n "$mcp" ]; then echo "$s"; return 0; fi
        done <<< "$servers"
    done <<< "$hosts"
    return 1
}

# mcp_register_proxy_pid <server_pid> <new_pid>
# Appends <new_pid> to a session's space-separated mcp-proxy-pid list so app-quit /
# cancel teardown and the orphan reaper treat it as a managed proxy. Best effort.
mcp_register_proxy_pid() {
    local server_pid="$1" new_pid="$2"
    [ -n "$server_pid" ] && [ -n "$new_pid" ] || return 1
    local cur
    cur=$("$plister" get string "$prefs" "/server-info/$server_pid/mcp-proxy-pid" 2>/dev/null)
    "$plister" set string "${cur:+$cur }$new_pid" "$prefs" "/server-info/$server_pid/mcp-proxy-pid" 2>/dev/null
}

# mcp_inspect_populate <window_uuid>
# Fills the server table (id 200) from llama-ui-mcp.json, marking each server
# 🟢 Running / 🔴 Stopped by probing its port. The hidden 3rd column carries the
# full URL for the selection handler. When there is nothing to show, the guidance
# goes to the endpoint status line (id 212) — there is no longer a window header.
# Callers run this AFTER mcp_inspect_reset_detail so the empty-state notice is the
# final word on the status line.
mcp_inspect_populate() {
    local window_uuid="$1"
    local SERVER_TABLE_ID=200
    local STATUS_ID=212
    local llama_ui_mcp_json="$mcp_app_support/llama-ui-mcp.json"

    # Server is first so it (the longest column) is the one ActionUI grows to fill
    # the pane; the 🟢/🔴 status dot is a narrow last column.
    "$dialog" "$window_uuid" $SERVER_TABLE_ID omc_table_set_columns "Server" "i"
    "$dialog" "$window_uuid" $SERVER_TABLE_ID omc_table_remove_all_rows

    if [ ! -f "$llama_ui_mcp_json" ]; then
        "$dialog" "$window_uuid" $STATUS_ID "No MCP session found. Start a chat with \"Use Tools in Agentic Session\" enabled."
        return 0
    fi

    local count
    count=$("$plister" get count "$llama_ui_mcp_json" /mcpServers 2>/dev/null)
    if [ -z "$count" ] || [ "$count" -le 0 ] 2>/dev/null; then
        "$dialog" "$window_uuid" $STATUS_ID "No MCP servers configured for the current session."
        return 0
    fi

    local i=0 buffer="" name url port status
    while [ "$i" -lt "$count" ]; do
        name=$("$plister" get value "$llama_ui_mcp_json" "/mcpServers/$i/name" 2>/dev/null)
        url=$("$plister" get value "$llama_ui_mcp_json" "/mcpServers/$i/url" 2>/dev/null)
        port=$(mcp_url_port "$url")
        if mcp_port_listening "$port"; then
            status="🟢"
        else
            status="🔴"
        fi
        # cols: 1=name (visible) 2=status dot (visible) 3=url (hidden data column)
        buffer="${buffer}${name}	${status}	${url}
"
        i=$((i + 1))
    done

    if [ -n "$buffer" ]; then
        printf "%s" "$buffer" | "$dialog" "$window_uuid" $SERVER_TABLE_ID omc_table_set_rows_from_stdin
    fi
}

# mcp_inspect_show_server <window_uuid> <url>
# Renders the detail panes for a server: endpoint URL + Copy, the Start/Stop/Restart
# button states (by probing the port), and — when the server is live — its tools.
# Shared by the row-selection handler and the start/stop/restart handlers so the view
# is rebuilt identically after a lifecycle action (the table selection is lost on
# repopulate, but the URL is held on the pasteboard, so the detail can be redrawn).
mcp_inspect_show_server() {
    local window_uuid="$1" url="$2"
    local ENDPOINT_FIELD_ID=210 ENDPOINT_STATUS_ID=212
    local START_BTN_ID=220 STOP_BTN_ID=221 RESTART_BTN_ID=222
    local TOOLS_TABLE_ID=300 SCHEMA_DESC_ID=402 SCHEMA_EDITOR_ID=403

    # Any (re)display invalidates the previously shown tool / schema.
    "$dialog" "$window_uuid" $TOOLS_TABLE_ID omc_table_remove_all_rows
    "$dialog" "$window_uuid" $SCHEMA_EDITOR_ID ""
    "$dialog" "$window_uuid" $SCHEMA_DESC_ID "Select a tool to inspect its JSON schema."
    pb_set "aichat_mcp_cache_${window_uuid}" ""

    if [ -z "$url" ]; then
        "$dialog" "$window_uuid" $ENDPOINT_FIELD_ID ""
        "$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "Select a server to view its endpoint and tools."
        "$dialog" "$window_uuid" $START_BTN_ID omc_disable
        "$dialog" "$window_uuid" $STOP_BTN_ID omc_disable
        "$dialog" "$window_uuid" $RESTART_BTN_ID omc_disable
        pb_set "aichat_mcp_url_${window_uuid}" ""
        return 0
    fi

    "$dialog" "$window_uuid" $ENDPOINT_FIELD_ID "$url"
    pb_set "aichat_mcp_url_${window_uuid}" "$url"

    local port
    port=$(mcp_url_port "$url")
    if ! mcp_port_listening "$port"; then
        # Stopped: only Start is actionable.
        "$dialog" "$window_uuid" $START_BTN_ID omc_enable
        "$dialog" "$window_uuid" $STOP_BTN_ID omc_disable
        "$dialog" "$window_uuid" $RESTART_BTN_ID omc_disable
        "$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "Server is not running — Start it to query its tools."
        return 0
    fi

    # Running: Stop / Restart are actionable; list tools.
    "$dialog" "$window_uuid" $START_BTN_ID omc_disable
    "$dialog" "$window_uuid" $STOP_BTN_ID omc_enable
    "$dialog" "$window_uuid" $RESTART_BTN_ID omc_enable
    "$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "Loading tools…"

    local short
    short=$(mcp_url_shortname "$url")
    [ -z "$short" ] && short="server"
    /bin/mkdir -p "$mcp_inspect_dir"
    local cache="$mcp_inspect_dir/${short}.tools.json"
    local python3_bin="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
    local inspect_py="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/mcp_inspect.py"
    local packages_dir="$OMC_APP_BUNDLE_PATH/Contents/Library/Packages"
    local err_file="$mcp_inspect_dir/.last-error"

    local rows rc
    rows=$(PYTHONPATH="$packages_dir" "$python3_bin" "$inspect_py" list "$url" "$cache" 2>"$err_file")
    rc=$?
    if [ "$rc" != 0 ]; then
        local msg
        msg=$(/bin/cat "$err_file" 2>/dev/null)
        "$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "Could not list tools: ${msg:-unknown error}"
        return 0
    fi

    pb_set "aichat_mcp_cache_${window_uuid}" "$cache"
    if [ -n "$rows" ]; then
        printf "%s\n" "$rows" | "$dialog" "$window_uuid" $TOOLS_TABLE_ID omc_table_set_rows_from_stdin
        local tool_count
        tool_count=$(printf "%s\n" "$rows" | /usr/bin/grep -c .)
        "$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "$tool_count tool(s) — select one to inspect its schema."
    else
        "$dialog" "$window_uuid" $ENDPOINT_STATUS_ID "This server exposes no tools."
    fi
}

# mcp_inspect_reset_detail <window_uuid>
# Clears the endpoint, tools, and schema panes and the lifecycle buttons (ids
# 210/212, 220/221/222, 300, 402/403) plus the per-window selection state.
# Used by the init and refresh handlers so a (re)load starts from a clean detail view.
mcp_inspect_reset_detail() {
    local window_uuid="$1"
    "$dialog" "$window_uuid" 300 omc_table_set_columns "Tool"
    "$dialog" "$window_uuid" 300 omc_table_set_column_widths 360
    "$dialog" "$window_uuid" 300 omc_table_remove_all_rows
    "$dialog" "$window_uuid" 210 ""
    "$dialog" "$window_uuid" 212 "Select a server to view its endpoint and tools."
    "$dialog" "$window_uuid" 220 omc_disable
    "$dialog" "$window_uuid" 221 omc_disable
    "$dialog" "$window_uuid" 222 omc_disable
    "$dialog" "$window_uuid" 402 "Select a tool to inspect its JSON schema."
    "$dialog" "$window_uuid" 403 ""
    pb_set "aichat_mcp_url_${window_uuid}" ""
    pb_set "aichat_mcp_cache_${window_uuid}" ""
}
