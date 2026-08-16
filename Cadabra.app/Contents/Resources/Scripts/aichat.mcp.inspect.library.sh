# aichat.mcp.inspect.library.sh
# ──────────────────────────────────────────────────────────────
# MCP Servers inspector (aichat.mcp.inspect dialog)
# ──────────────────────────────────────────────────────────────
# Read-only window into the tool surface an agentic session gets from the CURRENT
# MCP prefs - the verification companion to the Configure MCP Servers dialog. On
# init/refresh it generates the effective mlx-agent --mcp-config from the prefs
# (exactly what the next launch would generate) and runs `mlx-agent tools`, which
# spawns the stdio servers, performs the real initialize + tools/list handshake with
# the same exposed-name collision rules the agent applies at session start, dumps the
# result as JSON, and shuts the servers down. Selection handlers then read display
# fragments out of that dump via mcp_tools_report.py - no MCP traffic after populate.
#
# There is deliberately no start/stop/restart here (that was the proxy-era AIChat
# inspector): Cadabra's MCP servers are stdio children owned by each window's
# mlx-agent, with no lifecycle the applet could or should manage.
#
# Sourced ONLY by the aichat.mcp.inspect.* handler scripts. Control IDs match
# aichat.mcp.inspect.json. Sources the servers library for generate_stdio_mcp_config
# (and, transitively, the base library: $dialog / pb_set / pb_get / mcp_app_support).
[ -n "${__AICHAT_MCP_INSPECT_LIB:-}" ] && return 0
__AICHAT_MCP_INSPECT_LIB=1

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"

# Scratch dir for the generated inspection config + the current tools dump. The dump is
# shared (not per-window): it reflects the global prefs, so any inspector window showing
# it is showing the same truth, and every init/refresh regenerates it.
mcp_inspect_dir="$mcp_app_support/inspect"
mcp_inspect_dump="$mcp_inspect_dir/tools.json"

SERVER_TABLE_ID=200
COMMAND_FIELD_ID=210
STATUS_ID=212
TOOLS_TABLE_ID=300
DESC_EDITOR_ID=402
SCHEMA_EDITOR_ID=403

# mcp_inspect_report <query> [args...]  ->  mcp_tools_report.py against the shared dump.
# Prints the result on stdout; rc 1 = stale/bad dump (the output is a user-facing message).
mcp_inspect_report() {
    local q="$1"; shift
    "$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3" \
        "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/mcp_tools_report.py" \
        "$q" "$mcp_inspect_dump" "$@" 2>/dev/null
}

# mcp_inspect_reset_detail <window_uuid>
# Clears the command/status/tools/description/schema panes and the per-window
# selection state. Callers run this before (re)populating the server table.
mcp_inspect_reset_detail() {
    local window_uuid="$1"
    "$dialog" "$window_uuid" $TOOLS_TABLE_ID omc_table_set_columns "Tool"
    "$dialog" "$window_uuid" $TOOLS_TABLE_ID omc_table_set_column_widths 360
    "$dialog" "$window_uuid" $TOOLS_TABLE_ID omc_table_remove_all_rows
    "$dialog" "$window_uuid" $COMMAND_FIELD_ID ""
    "$dialog" "$window_uuid" $STATUS_ID "Select a server to view its tools."
    "$dialog" "$window_uuid" $DESC_EDITOR_ID "Select a tool to see its description."
    "$dialog" "$window_uuid" $SCHEMA_EDITOR_ID ""
    pb_set "aichatv2_mcp_srv_${window_uuid}" ""
}

# mcp_inspect_populate <window_uuid>
# Generates the effective config from the current prefs, runs `mlx-agent tools`
# (spawns + handshakes the servers; bounded per server by the agent's own timeout),
# and fills the server table: name, 🟢/🔴 handshake dot, hidden index column for the
# selection handler. Failure/empty states land on the status line.
mcp_inspect_populate() {
    local window_uuid="$1"

    # Server is first so it (the longest column) is the one ActionUI grows to fill
    # the pane; the handshake dot is a narrow last column (index stays hidden).
    "$dialog" "$window_uuid" $SERVER_TABLE_ID omc_table_set_columns "Server" "i"
    "$dialog" "$window_uuid" $SERVER_TABLE_ID omc_table_remove_all_rows

    local agent_bin="$OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent"
    if [ ! -x "$agent_bin" ]; then
        "$dialog" "$window_uuid" $STATUS_ID "mlx-agent is missing from the bundle ($agent_bin)."
        return 0
    fi

    /bin/mkdir -p "$mcp_inspect_dir"
    local cfg="$mcp_inspect_dir/mcp-config.json"
    "$dialog" "$window_uuid" $STATUS_ID "Launching MCP servers to query their tools…"
    if ! generate_stdio_mcp_config "$cfg" 1>&2; then
        "$dialog" "$window_uuid" $STATUS_ID "Could not generate the MCP config (bundled Python missing?)."
        return 0
    fi

    # Dump to a window-scoped temp file and mv into place: rename is atomic, so a
    # concurrent init/refresh (double-click, second inspector window) can never leave
    # a half-written tools.json behind - readers see the old dump or the new one.
    local err="$mcp_inspect_dir/.last-error"
    local tmp_dump="$mcp_inspect_dir/.tools.${window_uuid}.tmp"
    if ! "$agent_bin" tools --mcp-config "$cfg" > "$tmp_dump" 2>"$err"; then
        local msg
        msg=$(/usr/bin/tail -1 "$err" 2>/dev/null)
        /bin/rm -f "$tmp_dump"
        "$dialog" "$window_uuid" $STATUS_ID "Could not query the servers: ${msg:-mlx-agent tools failed}"
        return 0
    fi
    /bin/mv -f "$tmp_dump" "$mcp_inspect_dump"

    local rows
    rows=$(mcp_inspect_report servers)
    if [ -z "$rows" ]; then
        "$dialog" "$window_uuid" $STATUS_ID "No MCP servers enabled. Use Tools > Configure MCP Servers… to enable some."
        return 0
    fi

    printf "%s\n" "$rows" | "$dialog" "$window_uuid" $SERVER_TABLE_ID omc_table_set_rows_from_stdin
    "$dialog" "$window_uuid" $STATUS_ID "Select a server to view its tools."
}

# mcp_inspect_show_server <window_uuid> <server_index>
# Renders one server: its spawn command line, the tool-count/error status line, and
# the tools table (exposed names, 🔒 on permission-gated tools; hidden index column).
# The index is remembered on the pasteboard for the tool-selection handler.
mcp_inspect_show_server() {
    local window_uuid="$1" idx="$2"

    "$dialog" "$window_uuid" $TOOLS_TABLE_ID omc_table_remove_all_rows
    "$dialog" "$window_uuid" $DESC_EDITOR_ID "Select a tool to see its description."
    "$dialog" "$window_uuid" $SCHEMA_EDITOR_ID ""
    pb_set "aichatv2_mcp_srv_${window_uuid}" "$idx"

    if [ -z "$idx" ]; then
        "$dialog" "$window_uuid" $COMMAND_FIELD_ID ""
        "$dialog" "$window_uuid" $STATUS_ID "Select a server to view its tools."
        return 0
    fi

    "$dialog" "$window_uuid" $COMMAND_FIELD_ID "$(mcp_inspect_report command "$idx")"
    "$dialog" "$window_uuid" $STATUS_ID "$(mcp_inspect_report summary "$idx")"

    local rows
    rows=$(mcp_inspect_report tools "$idx")
    if [ -n "$rows" ]; then
        printf "%s\n" "$rows" | "$dialog" "$window_uuid" $TOOLS_TABLE_ID omc_table_set_rows_from_stdin
    fi
}

# mcp_inspect_show_tool <window_uuid> <server_index> <tool_index>
# Renders one tool: description block (description, exposed-as, gating note) and the
# pretty-printed JSON input schema. Multi-line content is piped in via stdin so no
# shell quoting can mangle it.
mcp_inspect_show_tool() {
    local window_uuid="$1" srv="$2" tool="$3"

    if [ -z "$tool" ]; then
        "$dialog" "$window_uuid" $DESC_EDITOR_ID "Select a tool to see its description."
        "$dialog" "$window_uuid" $SCHEMA_EDITOR_ID ""
        return 0
    fi
    if [ -z "$srv" ]; then
        "$dialog" "$window_uuid" $DESC_EDITOR_ID "Selection is out of date - refresh the server list."
        "$dialog" "$window_uuid" $SCHEMA_EDITOR_ID ""
        return 0
    fi

    mcp_inspect_report desc "$srv" "$tool" | \
        "$dialog" "$window_uuid" $DESC_EDITOR_ID omc_set_value_from_stdin
    mcp_inspect_report schema "$srv" "$tool" | \
        "$dialog" "$window_uuid" $SCHEMA_EDITOR_ID omc_set_value_from_stdin
}
