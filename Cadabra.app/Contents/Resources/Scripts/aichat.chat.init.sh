#!/bin/sh

# Merged chat + history window init (V2). Prepares the selected model's ENGINE, then INJECTS
# the Chat element's ACP transport into states["config"] via omc_set_state once that engine
# is ready. The Chat element defers building its transport until the config lands, then
# FREEZES it, and the composer auto-enables on isConfigured - so injecting only at the end
# gates the composer on real readiness (no manual enable). aichat.chat.json carries only
# "properties" (no static config).
#
# TWO ENGINES, one transport. The window always speaks ACP to the bundled mlx-agent
# (Contents/Support/MLX), which runs the tool loop + MCP stdio servers. What differs is how
# the tokens get generated, and that is decided by the model's SHAPE (see model_engine):
#   - .gguf FILE -> this applet launches llama-server on the pinned port and keeps FULL
#     ownership of it (launch, /health, registry, orphan reaping); the agent is a child that
#     only talks to it (--backend openai --base-url), so it gets no --model.
#   - safetensors DIRECTORY -> no server exists at all; mlx-agent maps the weights itself
#     (--model). Nothing to health-check, register or reap on this path.
# AICHAT_FORCE_OPENAI_SSE=1 restores the pre-ACP direct-to-llama-server transport (temporary
# escape hatch); it is gguf-only by construction and is ignored on the mlx path.
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
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh"

# Decided once, up front, because it changes what this script is even allowed to require. An
# external ACP agent brings its own model, so on that path there is no model path to demand
# and no engine to detect - and the two guards below would otherwise refuse the launch with
# "Model path not specified" before the dispatch that knows better is ever reached.
external_agent_active=$(acp_agent_enabled)

# An explicit model THIS launch beats a stored agent preference. The external branch below
# ignores $engine entirely, so without this a user who had configured opencode and then
# dropped a .gguf on the app icon would watch their model silently discarded and opencode
# open instead - and the drop path (AIChat.main.sh chains straight to aichat.chat) never goes
# near the model picker, so the flag that the picker clears is still set.
#
# Scoped to this launch on purpose: the drop is a one-off, so the stored preference stays for
# the next plain launch rather than being silently forgotten by a gesture that never mentioned
# it. Note the external agent's own OK handler arms the launch queue with an EMPTY model path,
# so a normal external launch never trips this.
if [ "$external_agent_active" = "true" ] && [ -n "${AICHAT_MODEL_PATH:-}${OMC_OBJ_PATH:-}" ]; then
	echo "external agent configured, but a model was given for this launch - using the model"
	external_agent_active="false"
fi

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

if [ -z "$AICHAT_MODEL_PATH" ] && [ "$external_agent_active" != "true" ]; then
	alert_message="Model path not specified"
	echo "$alert_message"
	"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$alert_message"
	exit 1
fi

echo "AICHAT_MODEL_PATH = $AICHAT_MODEL_PATH"

# ── Which engine? ─────────────────────────────────────────────────────────────
# The model's SHAPE decides, not a setting: a .gguf FILE runs on llama-server (this applet
# owns the server; mlx-agent reaches it with --backend openai), while a safetensors
# DIRECTORY is loaded in-process by mlx-agent itself (--model, no server anywhere). Detect
# once, here, and branch on it below - the picker made the same call using the same helper.
engine=$(model_engine "$AICHAT_MODEL_PATH")
if [ -z "$engine" ] && [ "$external_agent_active" = "true" ]; then
	# Expected on this path and not a problem: there may be no model path at all, and even if
	# a stale one is still queued from a previous pick, mlx-agent is not what is being
	# launched. The dispatch below ignores $engine entirely when the external agent is on.
	echo "external agent active: skipping model/engine detection"
elif [ -z "$engine" ]; then
	alert_message="This is not a model Cadabra can load:

$AICHAT_MODEL_PATH

Expected either a .gguf file, or a folder containing config.json and .safetensors shards."
	echo "$alert_message"
	"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$alert_message"
	exit 1
fi

# The external check joins the two guards above for the same reason they have it: this branch
# can abort the launch over a model the external path was never going to load, and it exits
# before BOTH per-window stamps below, leaving the window with no engine identity at all.
if [ "$engine" = "mlx" ] && [ "$external_agent_active" != "true" ]; then
	# Resolve to the PHYSICAL directory: mlx-swift-lm's weight loader fails to map sharded
	# or quantized tensors when handed a SYMLINKED model dir (it reports "Key
	# model.norm.weight not found"), which reads as a corrupt model rather than a symlink
	# problem. Re-check the result: if the dir vanished between the detect above and here,
	# cd fails and pwd -P yields "" - never inject an empty --model.
	AICHAT_MODEL_PATH=$(cd "$AICHAT_MODEL_PATH" 2>/dev/null && pwd -P)
	if [ -z "$AICHAT_MODEL_PATH" ] || [ ! -d "$AICHAT_MODEL_PATH" ]; then
		alert_message="The selected model folder is no longer available."
		echo "$alert_message"
		"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$alert_message"
		exit 1
	fi
fi

# One label for both engines: for a gguf this is the filename minus .gguf (exactly what the
# server library's LAUNCHED_MODEL_LABEL used to produce), for an mlx dir it is <org>/<name>
# rather than the snapshot hash.
if [ "$external_agent_active" = "true" ]; then
	# Named here rather than in the dispatch below, because the loading overlay is raised
	# before it and would otherwise be labeled with the empty string that
	# model_display_label returns for an absent model path.
	#
	# acp_agent_display_label, not the bare acp_agent_stored_label: this value is ALSO what
	# the aichatv2_agent_ stamp below carries, and the title and the stamp are read by
	# different code paths. When they disagreed the window opened titled "opencode" and
	# silently became "opencode 1.17.13" the moment the user pressed New Chat. init cannot
	# call chat_engine_label itself - it runs before its own stamps exist - so computing the
	# richer label once here and reusing it is what keeps the two in step.
	model_label=$(acp_agent_display_label)
else
	model_label=$(model_display_label "$AICHAT_MODEL_PATH")
fi
echo "engine = $engine, model_label = $model_label"

# Stamp the model path for this window so the history entry handler (aichat.chat.entry.sh)
# can record it in the session's meta.json (list display + info line) and so the model
# switch handler can compare against the currently-loaded model. Stamped AFTER the mlx
# symlink resolution above, so the comparison is against the path actually loaded.
pb_set "aichatv2_modelpath_${chat_window_uuid}" "$AICHAT_MODEL_PATH"

# The same stamp for the other kind of conversation. An external agent has no model path, so
# without this the entry handler recorded an EMPTY model into meta.json and every external
# conversation showed a blank where every other row names its model - in the history list, in
# the info strip, and in the preview. Empty for a local model, which is what keeps the two
# mutually exclusive downstream.
if [ "$external_agent_active" = "true" ]; then
	# Reuses the value computed above rather than calling the label function a second time.
	# Not just to save the forks: two independent reads of a MUTABLE plist can disagree, and
	# the Test dialog writes verifiedVersion, so a badly timed press between them would
	# reintroduce exactly the title-versus-stamp mismatch this pairing exists to prevent. One
	# read, one value, and the agreement is structural instead of coincidental.
	pb_set "aichatv2_agent_${chat_window_uuid}" "$model_label"
	# And blank the model path, so the exclusivity the readers rely on is ENFORCED here rather
	# than merely documented. AICHAT_MODEL_PATH is normally already empty on this path, but it
	# is resolved after the explicit-model-wins override above, so a stale legacy pasteboard
	# value could still reach this line and produce a meta.json claiming both a model and an
	# agent. The agent is what actually ran; the model path would be a lie about a file that
	# was never loaded.
	#
	# DO NOT REMOVE AS REDUNDANT. It also carries a second property, further away: the in-place
	# model switch reads this key as the currently-loaded model, and an empty value makes
	# model_engine return "" so the gguf-to-gguf hot-swap guard fails and the user is routed to
	# the new-window path, where acp_agent_disable runs. Without the blanking, a stale value
	# could let an external window hot-swap in place, leaving the agent stamp attached to a
	# conversation the local model produced.
	pb_set "aichatv2_modelpath_${chat_window_uuid}" ""
else
	pb_set "aichatv2_agent_${chat_window_uuid}" ""
fi

# Persist model path as a recent if it lives outside the standard caches.
# The model selector init script reads this list and deduplicates against cache results.
case "$AICHAT_MODEL_PATH" in
	# The on-device model is not a path and is never "recent": the picker lists it
	# unconditionally, from its own probe. Letting the sentinel into this list would put a
	# second, unbadged copy of the row in the picker on the next open.
	"$FOUNDATION_MODEL_ID") ;;
	"$HOME/Library/Application Support/Cadabra/Models/"*|\
	"$HOME/.cache/huggingface/"*|"$HOME/.lmstudio/"*|\
	"$HOME/.ollama/"*|"$HOME/.localai/"*|\
	"$HOME/Library/Application Support/Jan/"*|\
	"$HOME/Library/Application Support/nomic.ai/"*) ;;
	*)
		_prefs_domain="com.abracode.Cadabra"
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

# Safety net: kill any of this bundle's llama-server / MCP server / mlx-agent processes that a
# previous session orphaned onto launchd. Pairs with the registry-based stop_orphaned_servers
# above, and runs before this session launches its server for a clean slate.
reap_orphaned_bundle_processes

chat_loading_overlay_show "$chat_window_uuid" "$model_label"

# Both engines end at the same place - one ACP transport injected into states["config"] -
# and differ only in what has to exist first, and therefore in what can fail. The Chat
# element defers building its transport until this config lands, then FREEZES it, so the
# composer enables exactly when the engine is actually ready.
agent_bin="$OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent"
chat_config=""

if [ "$external_agent_active" = "true" ]; then
	# An ACP agent the user configured instead of the bundled one - opencode, the Claude
	# Code ACP adapter, anything that speaks ACP over stdio. It is checked FIRST and ignores
	# $engine entirely, because the model picker's engine describes which weights mlx-agent
	# would load, and on this path mlx-agent is not in the picture at all: the external agent
	# brings its own model, its own provider credentials and its own tool loop.
	#
	# Nothing is launched or health-checked out here. There is no server to own (that is the
	# agent's business) and no weights to find, so the transport is complete as soon as there
	# is a command to run - exactly like the mlx branch, and for the same reason. A bad
	# command surfaces as an ACP launch error in the window, which is where the user can see
	# and fix it, rather than as an alert out here that cannot say much more than "it failed".
	external_command=$(acp_agent_stored_command)
	# So the ready/failed lines at the bottom name what actually ran. $engine still holds the
	# engine of whatever model the picker last selected, which is not what is being launched.
	engine="external"
	echo "external agent: $external_command"
	if [ "$AICHAT_FORCE_OPENAI_SSE" = "1" ]; then
		# Same as the other no-server paths: the escape hatch IS the direct-to-llama-server
		# transport, and this path runs no llama-server.
		echo "AICHAT_FORCE_OPENAI_SSE=1 ignored: an external ACP agent runs no llama-server"
	fi
	if [ -z "$external_command" ]; then
		engine_ready=1
		echo "external agent: no command configured"
		"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" \
			"No external agent command is configured.

Choose one under Tools > External ACP Agent, or pick a local model instead."
	else
		chat_config=$(aichat_acp_transport_json "$agent_bin" external "$external_command" "$chat_window_uuid" "$use_tools")
		if [ -n "$chat_config" ]; then
			engine_ready=0
		else
			engine_ready=1
			echo "external agent: transport JSON came back empty; refusing to inject"
			"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" \
				"Could not prepare the external agent for this conversation."
		fi
	fi
elif [ "$engine" = "foundation" ]; then
	# The lightest path of the three: no server to launch, no weights to map, no model to
	# name. The model belongs to the OS, so mlx-agent is handed a backend and nothing else -
	# passing --model here would be refused, since there is only one model and it is not ours.
	#
	# This is also THE LAST AVAILABILITY GATE, and it cannot be left to the picker. The
	# picker's check is not the last thing before launch: with tools on, the user is routed
	# through the MCP servers dialog first and may spend minutes there (its Start handler
	# re-arms the launch queue with a fresh epoch for exactly that reason), and this window
	# can also open from the launch queue or a restored session, neither of which probed at
	# all. Apple Intelligence can be switched off in any of those gaps.
	#
	# Without a gate here the failure lands badly. Building this transport cannot realistically
	# fail, so the window would open looking ready - real title, enabled composer - and then
	# mlx-agent would exit 2 at spawn with its reason on stderr, leaving a dead composer or a
	# raw transport error where the app already knows how to show an actionable alert.
	if [ "$AICHAT_FORCE_OPENAI_SSE" = "1" ]; then
		# Same reasoning as the mlx branch: that escape hatch IS the direct-to-llama-server
		# transport, and there is no server on this path. Say it is ignored rather than
		# pointing the window at a port nothing is listening on.
		echo "AICHAT_FORCE_OPENAI_SSE=1 ignored: the foundation engine runs no llama-server"
	fi
	echo "foundation engine: mlx-agent uses Apple's on-device model; no llama-server, no weights"
	fm_probe=$(foundation_probe)
	fm_reason=$(printf '%s' "$fm_probe" | /usr/bin/cut -f1)
	fm_summary=$(printf '%s' "$fm_probe" | /usr/bin/cut -f2)
	if [ "$fm_reason" != "available" ]; then
		engine_ready=1
		echo "foundation engine: not usable ($fm_reason: $fm_summary)"
		"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" \
			"The on-device model is not available right now.

${fm_summary}"
	else
		chat_config=$(aichat_acp_transport_json "$agent_bin" foundation "" "$chat_window_uuid" "$use_tools")
		# Injecting "" would freeze the Chat element on an empty config and leave the composer
		# permanently disabled under a title claiming a loaded model.
		if [ -n "$chat_config" ]; then
			engine_ready=0
		else
			engine_ready=1
			echo "foundation engine: transport JSON came back empty; refusing to inject"
			"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" \
				"Could not prepare the on-device model for this conversation."
		fi
	fi
elif [ "$engine" = "mlx" ]; then
	# No server on this path. mlx-agent maps the weights itself, so there is nothing to
	# launch, health-check, register or reap, and nothing to be ready FOR: the transport is
	# complete the moment we can name the model directory. A bad or unloadable model surfaces
	# as an ACP error in the window instead of a failed health probe out here.
	if [ "$AICHAT_FORCE_OPENAI_SSE" = "1" ]; then
		# The escape hatch is llama-server-only by construction (it IS the direct-to-server
		# transport). There is no server on the mlx path, so honour it would mean pointing the
		# window at a dead port. Say so rather than failing mysteriously.
		echo "AICHAT_FORCE_OPENAI_SSE=1 ignored: the mlx engine runs no llama-server"
	fi
	echo "mlx engine: mlx-agent loads $AICHAT_MODEL_PATH in-process; no llama-server"
	chat_config=$(aichat_acp_transport_json "$agent_bin" mlx "$AICHAT_MODEL_PATH" "$chat_window_uuid" "$use_tools")
	# There is no health probe on this path, so the transport JSON is the ONLY thing that can
	# be wrong before injection. Injecting "" would freeze the element on an empty config and
	# leave the composer permanently disabled under a title claiming the model is loaded -
	# failing silently in the one place with no server to blame.
	if [ -n "$chat_config" ]; then
		engine_ready=0
	else
		engine_ready=1
		echo "mlx engine: transport JSON came back empty; refusing to inject"
		"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" \
			"Could not prepare the MLX engine for this model."
	fi
else
	# Multi-model: claim a free port for THIS window from the range (see aichat.library.sh),
	# stash it so the in-place switch handler relaunches on the same port, and freeze the
	# injected baseURL to it. Other windows keep their own servers on their own ports.
	port_num=$(find_free_port_in "$LLAMA_PORT_RANGE_START" "$LLAMA_PORT_RANGE_END")
	if [ -z "$port_num" ]; then
		engine_ready=1
		echo "no free llama-server port in ${LLAMA_PORT_RANGE_START}-${LLAMA_PORT_RANGE_END}"
		"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" \
			"Too many models are already running. Close a model window and try again."
	else
		pb_set "aichatv2_port_${chat_window_uuid}" "$port_num"
		base_url="http://127.0.0.1:${port_num}/v1"

		echo "Starting llama-server on port $port_num..."
		launch_model_on_port "$AICHAT_MODEL_PATH" "$chat_window_uuid" "$port_num"
		engine_ready=$?
	fi

	if [ "$engine_ready" = 0 ]; then
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
			chat_config=$(aichat_acp_transport_json "$agent_bin" openai "$base_url" "$chat_window_uuid" "$use_tools")
		fi
	fi
fi

if [ "$engine_ready" = 0 ]; then
	"$dialog" "$chat_window_uuid" "$CHAT_VIEW_ID" omc_set_state config "$chat_config"
	"$dialog" "$chat_window_uuid" "$MODEL_BTN_ID" omc_set_property "title" "$model_label"
	set_chat_status "$model_label"
	echo "chat ready ($engine, $model_label) - injected states[config]"
else
	# Every path that sets engine_ready=1 has already alerted: wait_for_server /
	# report_server_launch_failure / the no-port branch on gguf, the empty-transport check on
	# mlx, and the availability refusal or empty-transport check on foundation.
	set_chat_status "failed to load model"
	echo "chat init failed (engine=$engine, engine_ready=$engine_ready)"
fi

# Load finished (success or failure): remove the loading spinner overlay.
chat_loading_overlay_hide "$chat_window_uuid"
