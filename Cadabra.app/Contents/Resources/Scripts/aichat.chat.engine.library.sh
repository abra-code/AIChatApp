#!/bin/sh
# aichat.chat.engine.library.sh
# ONE function, and it answers one question: what has to happen before this window can talk.
#
# It was the tail of aichat.chat.init.sh, and it moved out the day a window could open with no
# model at all. Two callers now need every word of it - the window that launches WITH a model,
# and the empty window that is handed one afterwards (aichat.chat.load.model.sh) - and the four
# engine branches below are exactly the kind of code that goes wrong when it exists twice: the
# escape hatch, the availability gate, the port pinning and the three "refusing to inject an
# empty transport" checks each guard a failure that is invisible until a user hits it. So they
# live here once, and both entry points reach the same code rather than a copy of it.
#
# WHY A LATE ENGINE WORKS AT ALL. The Chat element defers building its transport until
# states["config"] lands and FREEZES it then - so a window that never received one is not
# broken, it is waiting, and its composer stays disabled until this function speaks. That is
# also what makes the empty window's first model unrestricted where the in-place SWITCH is
# gguf-to-gguf only: a switch has to keep an already-frozen transport pointing somewhere valid,
# while a first load has nothing frozen yet and can pick any of the four engines.
[ -n "${__AICHAT_CHAT_ENGINE_LIB:-}" ] && return 0
__AICHAT_CHAT_ENGINE_LIB=1

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.server.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh"

# The chat window's own ids, named here because this library writes to all three.
CHAT_ELEMENT_ID=1
CHAT_MODEL_BTN_ID=542

# chat_model_bar_set <win> <label> - name what is driving this window in the model bar.
#
# There is no "and nothing is driving it" call, deliberately. That state is DECLARED in
# aichat.chat.json - the button ships saying "Choose a Model" - so a window that opens without
# an engine is already correct and its init writes nothing at all. Which is the point: that
# branch finishes within milliseconds of the window being created, far sooner than any path
# before it, and a write that early is a write that can outrun its own window.
chat_model_bar_set() {
	"$dialog" "$1" "$CHAT_MODEL_BTN_ID" omc_set_property "title" "$2"
}

# chat_engine_title <win> <status> - retitle the window, unless a saved conversation is loaded
# in it. A window that adopts its first model while showing a conversation keeps the
# conversation's name - that is what the title is for, and the model now has a place of its own
# to be shown in. A window with nothing loaded has nothing better to say than what is answering.
chat_engine_title() {
	[ -n "$(pb_get "aichatv2_session_${1}")" ] && return 0
	chat_window_set_status "$1" "$2"
}

# chat_engine_load <win> <model-path> <use-tools> <external-active>
#   Prepares the engine for <win> and injects the ACP transport into the Chat element's
#   states["config"], which is the moment the composer comes alive. Stamps the per-window model
#   / agent keys, remembers the model as a recent, names it in the model bar, and raises and
#   drops the loading overlay around the whole thing.
#
#   Returns 0 when the window can talk, 1 when it cannot - and every path that returns 1 has
#   already put an alert in front of the user, because out here there is nothing left to say
#   about it that they could act on.
chat_engine_load() {
	local win="$1" model_path="$2" use_tools="$3" external_active="$4"
	local engine model_label alert_message agent_bin chat_config engine_ready
	local fm_probe fm_reason fm_summary external_command port_num base_url

	chat_engine_title "$win" "loading model…"

	# ── Which engine? ─────────────────────────────────────────────────────────────
	# The model's SHAPE decides, not a setting: a .gguf FILE runs on llama-server (this applet
	# owns the server; mlx-agent reaches it with --backend openai), while a safetensors
	# DIRECTORY is loaded in-process by mlx-agent itself (--model, no server anywhere). Detect
	# once, here, and branch on it below - the picker made the same call using the same helper.
	engine=$(model_engine "$model_path")
	if [ -z "$engine" ] && [ "$external_active" = "true" ]; then
		# Expected on this path and not a problem: there may be no model path at all, and even if
		# a stale one is still queued from a previous pick, mlx-agent is not what is being
		# launched. The dispatch below ignores $engine entirely when the external agent is on.
		echo "external agent active: skipping model/engine detection"
	elif [ -z "$engine" ]; then
		alert_message="This is not a model Cadabra can load:

$model_path

Expected either a .gguf file, or a folder containing config.json and .safetensors shards."
		echo "$alert_message"
		"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$alert_message"
		return 1
	fi

	# The external check joins the two guards above for the same reason they have it: this branch
	# can abort the launch over a model the external path was never going to load, and it exits
	# before BOTH per-window stamps below, leaving the window with no engine identity at all.
	if [ "$engine" = "mlx" ] && [ "$external_active" != "true" ]; then
		# Resolve to the PHYSICAL directory: mlx-swift-lm's weight loader fails to map sharded
		# or quantized tensors when handed a SYMLINKED model dir (it reports "Key
		# model.norm.weight not found"), which reads as a corrupt model rather than a symlink
		# problem. Re-check the result: if the dir vanished between the detect above and here,
		# cd fails and pwd -P yields "" - never inject an empty --model.
		model_path=$(cd "$model_path" 2>/dev/null && pwd -P)
		if [ -z "$model_path" ] || [ ! -d "$model_path" ]; then
			alert_message="The selected model folder is no longer available."
			echo "$alert_message"
			"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$alert_message"
			return 1
		fi
	fi

	# One label for both engines: for a gguf this is the filename minus .gguf (exactly what the
	# server library's LAUNCHED_MODEL_LABEL used to produce), for an mlx dir it is <org>/<name>
	# rather than the snapshot hash.
	if [ "$external_active" = "true" ]; then
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
		model_label=$(model_display_label "$model_path")
	fi
	echo "engine = $engine, model_label = $model_label"

	# Stamp the model path for this window so the history entry handler (aichat.chat.entry.sh)
	# can record it in the session's meta.json (list display + info line) and so the model
	# switch handler can compare against the currently-loaded model. Stamped AFTER the mlx
	# symlink resolution above, so the comparison is against the path actually loaded.
	pb_set "aichatv2_modelpath_${chat_window_uuid}" "$model_path"

	# The same stamp for the other kind of conversation. An external agent has no model path, so
	# without this the entry handler recorded an EMPTY model into meta.json and every external
	# conversation showed a blank where every other row names its model - in the history list, in
	# the info strip, and in the preview. Empty for a local model, which is what keeps the two
	# mutually exclusive downstream.
	if [ "$external_active" = "true" ]; then
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
	case "$model_path" in
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
			# The list, the dedup and the cap belong to model_recents_add - see the note there
			# for why this moved out of the com.abracode.Cadabra domain. What stays here is the
			# only part that is this handler's business: deciding that this path is worth
			# remembering at all.
			model_recents_add "$model_path"
			echo "saved recent model ($(model_recents_list | /usr/bin/grep -c . | /usr/bin/tr -d ' ') entries)"
			;;
	esac

	chat_loading_overlay_show "$win" "$model_label"

	# Both engines end at the same place - one ACP transport injected into states["config"] -
	# and differ only in what has to exist first, and therefore in what can fail. The Chat
	# element defers building its transport until this config lands, then FREEZES it, so the
	# composer enables exactly when the engine is actually ready.
	agent_bin="$OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent"
	chat_config=""

	if [ "$external_active" = "true" ]; then
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
			chat_config=$(aichat_acp_transport_json "$agent_bin" external "$external_command" "$win" "$use_tools")
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
			chat_config=$(aichat_acp_transport_json "$agent_bin" foundation "" "$win" "$use_tools")
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
		echo "mlx engine: mlx-agent loads $model_path in-process; no llama-server"
		chat_config=$(aichat_acp_transport_json "$agent_bin" mlx "$model_path" "$win" "$use_tools")
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
			launch_model_on_port "$model_path" "$win" "$port_num"
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
				chat_config=$(aichat_acp_transport_json "$agent_bin" openai "$base_url" "$win" "$use_tools")
			fi
		fi
	fi

	if [ "$engine_ready" = 0 ]; then
		"$dialog" "$win" "$CHAT_ELEMENT_ID" omc_set_state config "$chat_config"
		chat_model_bar_set "$win" "$model_label"
		chat_engine_title "$win" "$model_label"
		echo "chat ready ($engine, $model_label) - injected states[config]"
	else
		# Every path that sets engine_ready=1 has already alerted: wait_for_server /
		# report_server_launch_failure / the no-port branch on gguf, the empty-transport check on
		# mlx, and the availability refusal or empty-transport check on foundation.
		chat_engine_title "$win" "failed to load model"
		echo "engine load failed (engine=$engine, engine_ready=$engine_ready)"
	fi

	# Load finished (success or failure): remove the loading spinner overlay.
	chat_loading_overlay_hide "$win"

	return $engine_ready
}
