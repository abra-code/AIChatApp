#!/bin/sh

# Merged chat + history window init (V2). Starts llama-server for the selected model on the
# pinned port, then INJECTS the Chat element's ACP transport into states["config"] via
# omc_set_state once /health passes. The Chat element defers building its transport until
# that config lands, then FREEZES it, and the composer auto-enables on isConfigured - so
# injecting only after the health probe gates the composer on server readiness (no manual
# enable needed). aichat.chat.json carries only "properties" (no static config).
#
# The window speaks ACP to the bundled mlx-agent (Contents/Support/MLX), which runs the tool
# loop + MCP stdio servers and generates through llama-server's OpenAI endpoint. The applet
# keeps FULL ownership of llama-server (launch on the pinned port, /health, registry, orphan
# reaping); the agent is a child that only talks to it. AICHAT_FORCE_OPENAI_SSE=1 restores
# the pre-ACP direct-to-llama-server transport (temporary escape hatch).
#
# This is the app's single main surface: a NavigationSplitView with a collapsible history
# sidebar (Table id 510) beside the Chat element (id 1). Init also fills the sidebar list
# from the history store and stamps the toolbar Model button (id 530). Selecting a row loads
# that conversation in place (aichat.history.selection.changed.sh); New Chat clears it
# (aichat.chat.new.sh); the Model button hot-swaps the model without closing the window.
# The per-window server launch / registration / reaping lives in the server library; RAM
# helpers in the model library; history read-model in the history library.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.server.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"

echo "[$(/usr/bin/basename "$0")]"

# The native chat surface is the ActionUI Chat element (id 1); the sidebar list is Table 510.
chat_window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
CHAT_VIEW_ID=1
TABLE_ID=510
MODEL_BTN_ID=530

# set_chat_status <title-suffix> — reflect load state in this window's title.
set_chat_status() { chat_window_set_status "$chat_window_uuid" "$1"; }

# ── Populate the history sidebar (independent of model load) ───────────────────
history_populate_table "$chat_window_uuid" "$TABLE_ID"

set_chat_status "loading model…"

echo "OMC_CURRENT_COMMAND_GUID: ${OMC_CURRENT_COMMAND_GUID}"
echo "chat_window_uuid: ${chat_window_uuid}"
echo "OMC_FRONT_PROCESS_ID: ${OMC_FRONT_PROCESS_ID}"
echo "AICHAT_MODEL_PATH: $AICHAT_MODEL_PATH"

# use_tools is this session's agentic decision, fixed for the life of the window: the ACP
# transport freezes once injected, so the agent argv (--mcp-config or not) cannot be
# re-decided later. Default OFF: only an explicit opt-in turns tools on. An entry point with
# no checkbox to offer (a gguf dropped on the app icon) is a "just chat with this model"
# gesture, and matches the selector's own unchecked default - spawning the MCP servers
# behind it would be a surprise the user cannot undo without reopening the window.
# NOTE: must be a literal "false", not "" - aichat_acp_transport_json defaults an
# empty/omitted value to "true" (its MLXChat-inherited "prefs decide" contract).
use_tools="false"

if [ -z "${AICHAT_MODEL_PATH}" ] && [ -n "${OMC_OBJ_PATH}" ]; then
	# a gguf file dropped on the app icon
	AICHAT_MODEL_PATH="$OMC_OBJ_PATH"
	echo "GGUF file dropped on app: AICHAT_MODEL_PATH: $AICHAT_MODEL_PATH"
elif [ -z "$AICHAT_MODEL_PATH" ]; then
	# Handed over by the model selector: one epoch-stamped entry carrying the model AND its
	# tools decision (see launch_queue_arm). Falls back to the bare V2-namespaced path key,
	# which the selector no longer arms but other entry points may.
	queued=$(launch_queue_consume)
	if [ -n "$queued" ]; then
		AICHAT_MODEL_PATH=$(launch_queue_model "$queued")
		use_tools=$(launch_queue_tools "$queued")
		echo "GGUF from launch queue: AICHAT_MODEL_PATH: $AICHAT_MODEL_PATH (use_tools=$use_tools)"
	else
		AICHAT_MODEL_PATH=$("$pasteboard" "AICHATV2_MODEL_PATH" get);
		echo "GGUF from model selector: AICHAT_MODEL_PATH: $AICHAT_MODEL_PATH"
		"$pasteboard" "AICHATV2_MODEL_PATH" set ""
	fi
fi

if [ -z "$AICHAT_MODEL_PATH" ]; then
	alert_message="Model path not specified"
	echo "$alert_message"
	"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$alert_message"
	exit 1
fi

echo "AICHAT_MODEL_PATH = $AICHAT_MODEL_PATH"

# Stamp the model path for this window so the history entry handler (aichat.chat.entry.sh)
# can record it in the session's meta.json (list display + info line) and so the model
# switch handler can compare against the currently-loaded model.
pb_set "aichatv2_modelpath_${chat_window_uuid}" "$AICHAT_MODEL_PATH"

# Persist model path as a recent if it lives outside the standard caches.
# The model selector init script reads this list and deduplicates against cache results.
case "$AICHAT_MODEL_PATH" in
	"$HOME/.cache/huggingface/"*|"$HOME/.lmstudio/"*|\
	"$HOME/.ollama/"*|"$HOME/.localai/"*|\
	"$HOME/Library/Application Support/Jan/"*|\
	"$HOME/Library/Application Support/nomic.ai/"*) ;;
	*)
		_prefs_domain="com.abracode.AIChatV2"
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

# Remove stale keys left by older schema versions (no-op when already absent).
[ -f "$prefs" ] && "$plister" delete "$prefs" "/server-windows" 2>/dev/null

stop_orphaned_servers

# Safety net: kill any of this bundle's llama-server / mcp-proxy / replay processes that a
# previous session orphaned onto launchd. Pairs with the registry-based stop_orphaned_servers
# above, and runs before this session launches its server for a clean slate.
reap_orphaned_bundle_processes

# V2 pins a single server port (see aichat.library.sh); the injected config's baseURL
# matches. One active model at a time on the pinned port.
base_url="http://127.0.0.1:${port_num}/v1"

chat_loading_overlay_show "$chat_window_uuid" "$(/usr/bin/basename "$AICHAT_MODEL_PATH" .gguf)"

echo "Starting llama-server on pinned port $port_num..."
launch_model_on_pinned_port "$AICHAT_MODEL_PATH" "$chat_window_uuid"
server_result=$?

if [ "$server_result" = 0 ]; then
	# Server is healthy. Inject the Chat element's transport into states["config"]; the
	# element builds + freezes its transport and auto-enables the composer on isConfigured.
	# Injecting only now ties composer enablement to server readiness (no manual enable).
	if [ "$AICHAT_FORCE_OPENAI_SSE" = "1" ]; then
		# Escape hatch: talk to llama-server directly, no agent, no tools. Kept only to
		# isolate an ACP-vs-server problem during the transition; removed in a later phase.
		chat_config=$(/usr/bin/printf '{"protocol":"openai-sse","transport":{"baseURL":"%s","model":"auto","params":{"reasoning_format":"auto","stream_options":{"include_usage":true}}}}' "$base_url")
		echo "AICHAT_FORCE_OPENAI_SSE=1: injecting the legacy openai-sse transport"
	else
		# All-ACP: the window speaks ACP to the bundled mlx-agent, which runs the tool loop
		# and the MCP stdio servers and generates through the llama-server we just launched
		# (--backend openai --base-url). The applet keeps FULL ownership of llama-server;
		# mlx-agent only talks to it, which is why the agent gets no --model here.
		agent_bin="$OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent"
		chat_config=$(aichat_acp_transport_json "$agent_bin" openai "$base_url" "$chat_window_uuid" "$use_tools")
	fi
	"$dialog" "$chat_window_uuid" "$CHAT_VIEW_ID" omc_set_state config "$chat_config"
	"$dialog" "$chat_window_uuid" "$MODEL_BTN_ID" omc_set_property "title" "$LAUNCHED_MODEL_LABEL"
	set_chat_status "$LAUNCHED_MODEL_LABEL"
	echo "chat ready on $base_url ($LAUNCHED_MODEL_LABEL) - injected states[config]"
else
	# wait_for_pinned_server / report_server_launch_failure already showed an alert.
	set_chat_status "failed to load model"
	echo "chat init failed (server_result=$server_result)"
fi

# Load finished (success or failure): remove the loading spinner overlay.
chat_loading_overlay_hide "$chat_window_uuid"
