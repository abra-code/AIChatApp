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
# THE MODEL IS OPTIONAL HERE. Every route into this window used to carry one and the guard
# below refused the launch without it; File > New Chat Window carries none on purpose. So a
# missing model is a state the window HAS rather than a launch it refuses: sidebar, transcript
# and a disabled composer, with the model bar's button offering to fix it. See the section
# below, and aichat.chat.load.model.sh for what happens when the offer is taken.
#
# This is the app's single main surface: a NavigationSplitView with a collapsible history
# sidebar (Table id 510) beside the Chat element (id 1). Init also fills the sidebar list
# from the history store and names the engine in the model bar (button id 542, under the
# toolbar). Selecting a row loads that conversation in place
# (aichat.history.selection.changed.sh); New Chat clears it (aichat.chat.new.sh); the model
# bar's button changes models without closing the window.
# The per-window server launch / registration / reaping lives in the server library; RAM
# helpers in the model library; history read-model in the history library; everything between
# "which engine is this" and "the composer is alive" in the chat engine library.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.chat.engine.library.sh"
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
# open instead - and the drop path (Cadabra.main.sh chains straight to aichat.chat) never goes
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

# ── Populate the history sidebar (independent of model load) ───────────────────
# Before the engine, and deliberately: the sidebar is the half of this window that works
# without one. An empty window opens straight into it.
history_populate_table "$chat_window_uuid" "$TABLE_ID"

# Before anything that can fail, because everything below this line leaves the window ON SCREEN
# whether it succeeds or not - an alert about an unloadable model does not close it. What reads
# this is a launch arriving later for a window that may since have been closed.
chat_window_open_mark "$chat_window_uuid"

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

# ── No model, and that is a state rather than a failure ───────────────────────
# This used to be a stop alert reading "Model path not specified", which was the right answer
# while every route into this window carried a model. File > New Chat Window does not: it is
# the route for someone who wants the window first and will choose the model from inside it,
# and for someone who only wants to READ a saved conversation, which needs no engine at all.
#
# So the window opens with its sidebar, its transcript view and a disabled composer. Nothing
# else has to know: the Chat element leaves the composer disabled until states["config"]
# arrives (it defers building the transport until then), and the model bar's button carries
# the invitation. aichat.chat.load.model.sh is what finishes the job later.
#
# AND NOTHING IS WRITTEN HERE. Everything this state needs to say is already declared in
# aichat.chat.json and in the command's WINDOW_TITLE - the button reads "Choose a Model", the
# facts line reads "New conversation", the window is called Cadabra - so the correct branch is
# an empty one. That is not only tidiness. This is the shortest path there has ever been
# between a chat window being created and its init finishing, and a write issued in that gap
# can be refused ("error sending request to dialog port") by a window that is not serving yet.
# Every other branch below spends seconds loading an engine first, which is why nothing has
# had to think about it before.
if [ -z "$AICHAT_MODEL_PATH" ] && [ "$external_agent_active" != "true" ]; then
	echo "no model and no external agent - opening an empty chat window"
	exit 0
fi

echo "AICHAT_MODEL_PATH = $AICHAT_MODEL_PATH"

# Remove stale keys left by older schema versions (no-op when already absent).
[ -f "$prefs" ] && "$plister" delete "$prefs" "/server-windows" 2>/dev/null

stop_orphaned_servers

# Safety net: kill any of this bundle's llama-server / MCP server / mlx-agent processes that a
# previous session orphaned onto launchd. Pairs with the registry-based stop_orphaned_servers
# above, and runs before this session launches its server for a clean slate.
reap_orphaned_bundle_processes

# Everything that has to be true before this window can talk, in one place - the same code the
# empty window runs when it is handed its first model (aichat.chat.load.model.sh).
chat_engine_load "$chat_window_uuid" "$AICHAT_MODEL_PATH" "$use_tools" "$external_agent_active"

# The facts line under the model name. A window opening fresh has no conversation bound yet, so
# this reads "New conversation" until the first turn mints one or a sidebar row is clicked.
chat_info_refresh "$chat_window_uuid"
