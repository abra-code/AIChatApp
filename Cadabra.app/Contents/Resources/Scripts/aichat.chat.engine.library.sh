#!/bin/sh
# aichat.chat.engine.library.sh
# One question, asked by everything that changes what a chat window is talking to: what has to
# happen before this window can talk?
#
# It was the tail of aichat.chat.init.sh, and it moved out the day a window could open with no
# model at all. Three entry points need every word of it now - the window that launches WITH a
# model, the empty window handed one afterwards (aichat.chat.load.model.sh), and the window whose
# conversation is moved to another model (chat_engine_switch, below) - and the four engine
# branches are exactly the kind of code that goes wrong when it exists twice: the escape hatch,
# the availability gate, the port pinning and the "refusing to inject an empty transport" checks
# each guard a failure that is invisible until a user hits it. So they live here once, in
# chat_engine_transport_config, and every entry point reaches the same code rather than a copy.
#
# WHY A LATE ENGINE WORKS AT ALL, AND WHY A SWITCH DOES TOO. The Chat element defers building its
# transport until states["config"] lands - so a window that never received one is not broken, it
# is waiting, and its composer stays disabled until this library speaks. It does not FREEZE what
# it built: re-injecting an identical config is ignored, and a different viable one re-configures
# the element in place - the old agent is stopped, a new one is built from the new argv and
# primed from the transcript on screen. That is the whole mechanism behind chat_engine_switch,
# and it is why every pair of local engines is reachable and not just gguf-to-gguf.
[ -n "${__AICHAT_CHAT_ENGINE_LIB:-}" ] && return 0
__AICHAT_CHAT_ENGINE_LIB=1

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.server.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh"
# For history_marker_lead: a window that can answer holds a line saying what is answering it,
# ready for its first message. Both callers already source this; the guard inside makes that free.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"

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

# chat_engine_physical_mlx_dir <model-path> - resolve an MLX model directory to its PHYSICAL path,
# left in CHAT_ENGINE_MODEL_PATH. 0 when it resolved, 1 after alerting when it did not.
#
# mlx-swift-lm's weight loader fails to map sharded or quantized tensors when handed a SYMLINKED
# model dir (it reports "Key model.norm.weight not found"), which reads as a corrupt model rather
# than a symlink problem. The result is re-checked because a dir that vanished between the engine
# detection and here makes `cd` fail and `pwd -P` yield "" - and an empty --model must never be
# injected.
#
# Same reason as the refusal above: both the first load and the switch resolve before they stamp,
# because the stamp has to name the path that was actually loaded.
CHAT_ENGINE_MODEL_PATH=""
chat_engine_physical_mlx_dir() {
	local alert_message
	CHAT_ENGINE_MODEL_PATH=$(cd "$1" 2>/dev/null && pwd -P)
	if [ -z "$CHAT_ENGINE_MODEL_PATH" ] || [ ! -d "$CHAT_ENGINE_MODEL_PATH" ]; then
		CHAT_ENGINE_MODEL_PATH=""
		alert_message="The selected model folder is no longer available."
		echo "$alert_message"
		"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" "$alert_message"
		return 1
	fi
	return 0
}

# chat_engine_remember_recent <model-path> - remember a model that lives outside the standard
# caches, so the picker can offer it again.
#
# Its own function because a first load and an in-place switch remember a model for exactly the
# same reason, and the only decision here - whether this path is worth remembering at all - is
# the kind that must not exist in two places to be disagreed with later.
chat_engine_remember_recent() {
	local model_path="$1"
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
}

# chat_engine_transport_config <win> <engine> <model-path> <use-tools> <external-command> [port]
#   Everything ONE engine needs to exist before the window can talk, ending in the ACP transport
#   JSON: the availability gate on foundation, the resolved directory on mlx, the llama-server
#   launch on gguf, the configured command line on external.
#
#   Split out of chat_engine_load for the in-place model switch, which prepares exactly the same
#   four engines for a window that already has one. What stayed behind in the load is what only a
#   FIRST load does: claiming the window's port, stamping it, and minting the line the
#   conversation opens with.
#
#   CALL IT AS A PLAIN COMMAND, NEVER IN $( ). It returns 0 with the JSON in CHAT_ENGINE_CONFIG,
#   or 1 with CHAT_ENGINE_CONFIG empty - and every path that returns 1 has already put an alert
#   in front of the user. It cannot hand the JSON back on stdout: the branches below, and
#   launch_model_on_port under them, log their progress there and that log is the handler's own
#   record of what happened. A command substitution would capture those lines in front of the
#   JSON, the element would reject the value it was given, and the load would look like a silent
#   no-op on the old engine. The gguf branch also reports its label out of band, in
#   LAUNCHED_MODEL_LABEL, which a subshell would lose along with everything else it set.
CHAT_ENGINE_CONFIG=""
chat_engine_transport_config() {
	local win="$1" engine="$2" model_path="$3" use_tools="$4" external_command="$5" port_num="$6"
	local agent_bin base_url engine_ready
	local fm_probe fm_reason fm_summary
	# All four engines end at the same place - one ACP transport in states["config"] - and differ
	# only in what has to exist first, and therefore in what can fail. The element builds its
	# transport when this config lands, so the composer enables exactly when the engine is ready;
	# on a switch it REPLACES the transport it has, which is the same moment for the same reason.
	agent_bin="$OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent"
	CHAT_ENGINE_CONFIG=""

	# Dispatched on the ENGINE alone - "external" is one of its values here, set by the caller,
	# rather than the separate external_active flag chat_engine_load is handed. A switch has no
	# such flag to pass, and one variable saying what is being prepared is what lets every caller
	# reach the same four branches.
	if [ "$engine" = "external" ]; then
		# An ACP agent the user configured instead of the bundled one - opencode, the Claude
		# Code ACP adapter, anything that speaks ACP over stdio. It is checked FIRST, and the model
		# path it is handed is ignored: the picker's engine describes which weights mlx-agent would
		# load, and on this path mlx-agent is not in the picture at all - the external agent brings
		# its own model, its own provider credentials and its own tool loop.
		#
		# Nothing is launched or health-checked out here. There is no server to own (that is the
		# agent's business) and no weights to find, so the transport is complete as soon as there
		# is a command to run - exactly like the mlx branch, and for the same reason. A bad
		# command surfaces as an ACP launch error in the window, which is where the user can see
		# and fix it, rather than as an alert out here that cannot say much more than "it failed".
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
			CHAT_ENGINE_CONFIG=$(aichat_acp_transport_json "$agent_bin" external "$external_command" "$win" "$use_tools")
			if [ -n "$CHAT_ENGINE_CONFIG" ]; then
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
			CHAT_ENGINE_CONFIG=$(aichat_acp_transport_json "$agent_bin" foundation "" "$win" "$use_tools")
			# Injecting "" would leave the composer disabled under a title claiming a loaded
			# model, and nothing on this path would inject again.
			if [ -n "$CHAT_ENGINE_CONFIG" ]; then
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
		CHAT_ENGINE_CONFIG=$(aichat_acp_transport_json "$agent_bin" mlx "$model_path" "$win" "$use_tools")
		# There is no health probe on this path, so the transport JSON is the ONLY thing that can
		# be wrong before injection. Injecting "" would leave the composer disabled under a title
		# claiming the model is loaded, and nothing on this path would inject again - failing
		# silently in the one place with no server to blame.
		if [ -n "$CHAT_ENGINE_CONFIG" ]; then
			engine_ready=0
		else
			engine_ready=1
			echo "mlx engine: transport JSON came back empty; refusing to inject"
			"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" \
				"Could not prepare the MLX engine for this model."
		fi
	else
		# The port belongs to the WINDOW, not to this call, and the CALLER is what claims it: a
		# first load takes a free one from the range (see aichat.library.sh) and stamps it; a
		# gguf-to-gguf switch hands back the port that window already owns, which is why its agent
		# never has to be replaced; and a switch arriving from an engine that had no server claims
		# one of its own. Other windows keep their own servers on their own ports throughout.
		if [ -z "$port_num" ]; then
			# A caller is expected to claim a port before it calls, and to say so in its own words
			# when it cannot. This is here because the alternative to refusing is a baseURL with no
			# port in it - built, injected and accepted - which is the one failure on this path that
			# nothing downstream would report. It alerts like every other refusal here, rather than
			# leaving the window titled "failed to load model" with the reason only in the log.
			engine_ready=1
			echo "gguf engine: no port to launch on; refusing to inject"
			"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" \
				"Could not prepare the llama-server engine for this model."
		else
			base_url="http://127.0.0.1:${port_num}/v1"

			echo "Starting llama-server on port $port_num..."
			launch_model_on_port "$model_path" "$win" "$port_num"
			engine_ready=$?
		fi

		if [ "$engine_ready" = 0 ]; then
			if [ "$AICHAT_FORCE_OPENAI_SSE" = "1" ]; then
				# Escape hatch: talk to llama-server directly, no agent, no tools. Kept only to
				# isolate an ACP-vs-server problem during the transition; removed in a later phase.
				CHAT_ENGINE_CONFIG=$(/usr/bin/printf '{"protocol":"openai-sse","transport":{"baseURL":"%s","model":"auto","params":{"reasoning_format":"auto","stream_options":{"include_usage":true}}}}' "$base_url")
				echo "AICHAT_FORCE_OPENAI_SSE=1: injecting the legacy openai-sse transport"
			else
				# All-ACP: the window speaks ACP to the bundled mlx-agent, which runs the tool loop
				# and the MCP stdio servers and generates through the llama-server we just launched
				# (--backend openai --base-url). The applet keeps FULL ownership of llama-server;
				# mlx-agent only talks to it, which is why the agent gets no --model here.
				CHAT_ENGINE_CONFIG=$(aichat_acp_transport_json "$agent_bin" openai "$base_url" "$win" "$use_tools")
			fi
			# The same refusal the other three branches make, and the only one with a RUNNING
			# server behind it. Injecting "" would leave the composer permanently disabled under a
			# title claiming the model is loaded, and llama-server would go on holding the weights
			# for a window that can never reach it. So the caller undoes the launch, exactly as it
			# does for a launch that never came up: a first load stops the server and rolls its
			# stamps back.
			if [ -z "$CHAT_ENGINE_CONFIG" ]; then
				engine_ready=1
				echo "gguf engine: transport JSON came back empty; refusing to inject"
				"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" \
					"Could not prepare the llama-server engine for this model."
			fi
		fi
	fi
	return $engine_ready
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
	local engine model_label chat_config engine_ready
	local external_command port_num

	chat_engine_title "$win" "loading model…"

	# ── A clean slate before anything of ours is launched ────────────────────────
	# Both callers need this and neither should have to remember it, which is why it sits
	# inside the load rather than in front of the two calls to it. It also has to come AFTER
	# the title above: reaping walks every process on the machine and can spend a TERM, a
	# sleep and a KILL on each orphan it finds, and while that runs the window would otherwise
	# sit under its plain name saying nothing at all.
	[ -f "$prefs" ] && "$plister" delete "$prefs" "/server-windows" 2>/dev/null

	stop_orphaned_servers

	# Safety net: kill any of this bundle's llama-server / MCP server / mlx-agent processes that
	# a previous session orphaned onto launchd. Pairs with the registry-based
	# stop_orphaned_servers above, and runs before this session launches its server.
	reap_orphaned_bundle_processes

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
		model_alert_not_loadable "$model_path"
		return 1
	fi

	# The external check joins the two guards above for the same reason they have it: this branch
	# can abort the launch over a model the external path was never going to load, and it exits
	# before BOTH per-window stamps below, leaving the window with no engine identity at all.
	if [ "$engine" = "mlx" ] && [ "$external_active" != "true" ]; then
		chat_engine_physical_mlx_dir "$model_path" || return 1
		model_path="$CHAT_ENGINE_MODEL_PATH"
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

	# WHAT THIS WINDOW CLAIMED BEFORE WE TOUCHED IT, so a load that fails can put it back. The
	# stamps below go in BEFORE the five branches that can fail (no free port, a launch that
	# never answers, a transport that comes back empty on mlx / external / foundation), and a
	# window left stamped with a model it never loaded is not merely untidy - it is stuck. The
	# picker reads exactly this pair to decide a window is still empty, so the retry is refused
	# as "model unchanged", and a retry with a DIFFERENT gguf is routed to the in-place switch,
	# which relaunches a server under a Chat element that never received a config: a window
	# naming a loaded model over a composer that can never enable.
	#
	# aichat.chat.switch.model.sh has carried this rollback since the day a failed switch could
	# strand a window; a first load needs it for the same reason and could not have it until the
	# stamps started naming the right window.
	local prev_model_path prev_agent prev_port prev_tools
	prev_model_path=$(pb_get "aichatv2_modelpath_${win}")
	prev_agent=$(pb_get "aichatv2_agent_${win}")
	prev_port=$(pb_get "aichatv2_port_${win}")
	prev_tools=$(pb_get "aichatv2_tools_${win}")

	# Stamp the model path for this window so the history entry handler (aichat.chat.entry.sh)
	# can record it in the session's meta.json (list display + info line) and so the model
	# switch handler can compare against the currently-loaded model. Stamped AFTER the mlx
	# symlink resolution above, so the comparison is against the path actually loaded.
	pb_set "aichatv2_modelpath_${win}" "$model_path"

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
		pb_set "aichatv2_agent_${win}" "$model_label"
		# And blank the model path, so the exclusivity the readers rely on is ENFORCED here rather
		# than merely documented. AICHAT_MODEL_PATH is normally already empty on this path, but it
		# is resolved after the explicit-model-wins override above, so a stale legacy pasteboard
		# value could still reach this line and produce a meta.json claiming both a model and an
		# agent. The agent is what actually ran; the model path would be a lie about a file that
		# was never loaded.
		#
		# DO NOT REMOVE AS REDUNDANT. It also carries a second property, further away: the pair is
		# how every reader tells an agent's window from a model's, and the switch is the reader with
		# teeth - it refuses an agent's window outright (a conversation cannot be moved from an agent
		# to a local model) and decides the whole engine matrix from these two stamps plus the port.
		# A stale model path here would present an agent's window as a model's, and the switch would
		# respawn its agent as a local model - leaving the agent stamp attached to a conversation the
		# local model produced.
		pb_set "aichatv2_modelpath_${win}" ""
	else
		pb_set "aichatv2_agent_${win}" ""
	fi

	# WHAT THIS WINDOW RUNS WITH, kept because nothing else remembers it. The tools decision is
	# made once per window - in the picker, or in the MCP servers dialog behind it - and then lives
	# only in the agent's argv, where no handler can read it back. The model bar's next pick needs
	# it: without this the picker offers an unchecked box, and a switch would answer "no tools" for
	# a conversation that has been using them, silently rebuilding the agent without its servers.
	pb_set "aichatv2_tools_${win}" "$use_tools"

	chat_engine_remember_recent "$model_path"

	chat_loading_overlay_show "$win" "$model_label"

	# The engine itself, prepared by the same function the in-place switch calls. Everything
	# above this line is what makes a window ready to RECEIVE an engine; everything below is what
	# a window does once it has one.
	if [ "$external_active" = "true" ]; then
		# So the ready/failed lines at the bottom name what actually ran. $engine still holds the
		# engine of whatever model the picker last selected, which is not what is being launched.
		engine="external"
		external_command=$(acp_agent_stored_command)
	fi

	engine_ready=0
	if [ "$engine" = "gguf" ]; then
		# Multi-model: claim a free port for THIS window from the range (see aichat.library.sh)
		# and stash it, so the in-place switch handler relaunches on the same port. Claimed out
		# here because allocating one is what a FIRST load does: a switch either reuses this
		# stamp or, arriving from an engine that never had a server, claims its own.
		port_num=$(find_free_port_in "$LLAMA_PORT_RANGE_START" "$LLAMA_PORT_RANGE_END")
		if [ -z "$port_num" ]; then
			engine_ready=1
			echo "no free llama-server port in ${LLAMA_PORT_RANGE_START}-${LLAMA_PORT_RANGE_END}"
			"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" \
				"Too many models are already running. Close a model window and try again."
		else
			pb_set "aichatv2_port_${win}" "$port_num"
		fi
	fi

	if [ "$engine_ready" = 0 ]; then
		chat_engine_transport_config "$win" "$engine" "$model_path" "$use_tools" \
			"$external_command" "$port_num"
		engine_ready=$?
		chat_config="$CHAT_ENGINE_CONFIG"
	fi

	if [ "$engine_ready" = 0 ]; then
		"$dialog" "$win" "$CHAT_ELEMENT_ID" omc_set_state config "$chat_config"
		chat_model_bar_set "$win" "$model_label"
		chat_engine_title "$win" "$model_label"
		echo "chat ready ($engine, $model_label) - injected states[config]"
		# THE CONVERSATION'S OPENING LINE, minted at the moment its model becomes known - this
		# window can answer as of the line above - and HELD for the first message, which is the
		# only place it can lead the conversation instead of interrupting it. Displayed and
		# recorded by that message, and by nothing else: a window that is only read shows no line
		# and records none. See the marker section in aichat.history.library.sh.
		#
		# "resumed" when a saved conversation is already loaded here. That is the empty window
		# opened to READ one, now being handed its first model: the click that loaded the
		# conversation could not mint a marker, because there was no engine yet to name in it.
		#
		# DECIDED BY WHAT THE WINDOW IS SHOWING, not by what the sidebar armed, because the two can
		# disagree. A click whose conversation fails to load clears the arm and leaves the PREVIOUS
		# one displayed and bound (aichat.history.selection.changed.sh), so a window reading the arm
		# would announce a fresh start at the bottom of a conversation it is still showing.
		#
		# And the arm is re-set from the binding, so the marker shown here is one a turn can
		# actually record: aichat.chat.entry.sh commits only for the conversation the arm names.
		# In the ordinary path this writes back the value that is already there.
		local resume_sid
		resume_sid=$(pb_get "aichatv2_session_${win}")
		if [ -n "$resume_sid" ]; then
			pb_set "aichatv2_resume_pending_${win}" "$resume_sid"
			history_marker_lead "$win" "$CHAT_ELEMENT_ID" resumed "$model_label"
		else
			history_marker_lead "$win" "$CHAT_ELEMENT_ID" started "$model_label"
		fi
	else
		# Every path that sets engine_ready=1 has already alerted: wait_for_server /
		# report_server_launch_failure / the no-port branch on gguf, the empty-transport check on
		# each of the four engines, and the availability refusal on foundation.
		#
		# The server first, when there is one to stop. A gguf launch that came up and was then
		# refused an empty transport leaves llama-server running and REGISTERED to this window,
		# holding the whole model in memory for a conversation that never started. It would go on
		# doing that until the window closes, and a second attempt would claim a different port and
		# launch a second server beside it. Nothing to stop on the other engines (they launch no
		# server) or when the port claim itself failed, and stop_window_server says so and returns.
		[ -n "$port_num" ] && stop_window_server "$win" "ENGINE-LOAD-FAILED"
		# Un-claim the window next. Nothing was injected, so it is driving nothing, and the
		# stamps are what every other handler reads to decide what it is driving - leaving them
		# set describes a model that is not loaded and locks the window out of a second attempt.
		# The port goes back too: it was claimed before the launch that failed, and a stamped
		# port is what lets the in-place switch believe this window has a server to restart.
		pb_set "aichatv2_modelpath_${win}" "$prev_model_path"
		pb_set "aichatv2_agent_${win}" "$prev_agent"
		pb_set "aichatv2_port_${win}" "$prev_port"
		pb_set "aichatv2_tools_${win}" "$prev_tools"
		chat_engine_title "$win" "failed to load model"
		echo "engine load failed (engine=$engine, engine_ready=$engine_ready)"
	fi

	# Load finished (success or failure): remove the loading spinner overlay.
	chat_loading_overlay_hide "$win"

	return $engine_ready
}

# chat_engine_switch <win> <model-path> <use-tools>
#   Change the model of an OPEN conversation, in place. The window keeps its transcript, its
#   session binding and its title; what changes is what answers the next message.
#
#   Returns 0 when the window is talking to the new model, 1 when it is still talking to the old
#   one - and every path that returns 1 has already alerted, or had nothing to say that the user
#   could act on (an external agent's window, which the picker refuses before it ever chains here).
#
#   THE MATRIX, and why there is one. What a model IS decides what has to happen to change it:
#
#     current  target        what changes                                       re-inject?
#     gguf     gguf          llama-server restarts on the window's own port      only if the
#                                                                                tools decision
#                                                                                changed
#     gguf     mlx/found.    the agent's argv, and the server is no longer ours   yes, then stop it
#     mlx/f.   gguf          a server has to exist before the agent asks for it   yes, after launch
#     mlx/f.   mlx/found.    the agent's argv                                     yes
#
#   Only the first cell can be done under the SAME agent process: llama-server serves whichever
#   model it has loaded, the agent's argv never mentions it, and the agent's own conversation
#   array survives the restart - which is the semantics that cell wants. Every other cell changes
#   the argv, so the agent must be replaced, and replacing it is exactly what re-injecting
#   states["config"] does: ChatStore stops the old transport (SIGTERM, SIGKILL after a grace),
#   attaches the new one and re-primes it from the transcript on screen, so the conversation
#   carries over to a process that never saw it. The element was long believed to freeze its
#   transport on the first config; it does not, and never did (ChatStore.reconcileConfig).
#
#   WHAT THE WINDOW HAS decides the current side, not model_engine of its stamped path: a model
#   deleted from disk since it was loaded reports no engine at all, and that window is still
#   running it. A stamped port is a server; no port is mlx or the on-device model, which are the
#   same thing on the way out (nothing to stop).
chat_engine_switch() {
	local win="$1" model_path="$2" use_tools="$3"
	local current_agent prev_model_path prev_port prev_tools target_engine model_label
	local port_num engine_ready inject_needed

	# Defense, not a policy: aichat.select.local.model.ok.sh refuses an agent window with the
	# "Open in a New Window?" alert and never chains here. A conversation cannot be moved from an
	# agent to a local model - the agent owns the session, the context and the tool loop, and none
	# of it is portable - so if one ever arrives, leave it exactly as it is.
	current_agent=$(pb_get "aichatv2_agent_${win}")
	if [ -n "$current_agent" ]; then
		echo "window $win runs the external agent \"$current_agent\"; not switching it to a local model"
		return 1
	fi

	target_engine=$(model_engine "$model_path")
	if [ -z "$target_engine" ]; then
		model_alert_not_loadable "$model_path"
		return 1
	fi
	if [ "$target_engine" = "mlx" ]; then
		chat_engine_physical_mlx_dir "$model_path" || return 1
		model_path="$CHAT_ENGINE_MODEL_PATH"
	fi
	model_label=$(model_display_label "$model_path")

	prev_model_path=$(pb_get "aichatv2_modelpath_${win}")
	prev_port=$(pb_get "aichatv2_port_${win}")
	prev_tools=$(pb_get "aichatv2_tools_${win}")

	# The model this window is already running, picked again. The picker refuses that as "model
	# unchanged", but it compares the path it LISTED against the path this window stamped, and for
	# an MLX model reached through a symlink those differ - the stamp is the physical directory,
	# which is what mlx-swift-lm has to be given. Comparing after the resolution is what makes the
	# two agree, and what stops a pick that changes nothing from killing the agent, respawning it
	# and re-priming the whole conversation.
	# An EMPTY previous decision counts as unchanged here, exactly as it does in the gguf-to-gguf
	# rebuild test below and in the picker's own gate. A window loaded before the stamp existed has
	# no recorded decision to have changed, and reading "unknown" as "changed" would respawn its
	# agent - or restart its server, minutes on a large model - for a pick that asked for nothing.
	if [ "$model_path" = "$prev_model_path" ] && \
	   { [ -z "$prev_tools" ] || [ "$use_tools" = "$prev_tools" ]; }; then
		# The title is re-set on the way out because a FAILED switch leaves "failed to load model"
		# there, and the model bar still naming the running model. Re-picking that model is one of
		# the few gestures that lands here, and it should repair the window rather than leave it
		# describing a failure it has recovered from.
		chat_engine_title "$win" "$model_label"
		echo "window $win already runs $model_label; nothing to switch"
		return 0
	fi
	echo "switching window $win to $model_label ($target_engine)"

	# The TITLE is the conversation's, when there is one. chat_engine_title is what keeps that
	# true here: this handler used to overwrite it with the model at every step, so switching
	# models inside a named conversation left the model's name where the user's title had been,
	# until they clicked the row again to get it back. The model has a place of its own now, and
	# it is updated below; a switch in progress shows in the loading overlay.
	chat_engine_title "$win" "loading model…"
	chat_loading_overlay_show "$win" "$model_label"
	# Stamped BEFORE the engine work because that work can run for minutes (up to a 300 s wait for
	# a large --no-mmap model) and other handlers in this window read the stamp while it is in
	# flight. Nothing between here and the launch reads it - the overlay and the button are passed
	# their labels - so the early stamp is about concurrency, not about this script.
	#
	# Rolled back below when the preparation fails. Leaving a failed model stamped used to be
	# invisible; it is not any more, because the resume marker reads this label at send time and
	# would name a model that never loaded.
	pb_set "aichatv2_modelpath_${win}" "$model_path"

	engine_ready=1
	inject_needed=0
	CHAT_ENGINE_CONFIG=""
	if [ -n "$prev_port" ] && [ "$target_engine" = "gguf" ]; then
		# ── gguf -> gguf: the cell that usually has nothing to re-inject ──────
		# The agent's argv names the PORT, not the model, so restarting llama-server under it is
		# the whole switch: launch_model_on_port frees this window's own port first (TERMing the
		# outgoing server and waiting for it to exit), and the agent's conversation array carries
		# over untouched to re-prefill against the new model on the next turn. That carry-over is
		# this cell's one real advantage, and it is worth keeping.
		#
		# Unless the TOOLS decision changed, which is the one part of the argv a switch can alter
		# here (--mcp-config appears or goes). Then the agent has to be replaced like anywhere else,
		# and building the transport is what replaces it.
		#
		# DECIDED BEFORE THE BUILD, not after. Building a transport is not a question: it
		# regenerates this window's MCP config from current preferences, or deletes it, as a side
		# effect of being asked - so a cell that keeps its agent must not ask. An empty previous
		# value is a window loaded before this stamp existed; that counts as unchanged, rather than
		# reading "unknown" as "changed" and rebuilding an agent that was fine.
		if [ -n "$prev_tools" ] && [ "$use_tools" != "$prev_tools" ]; then
			echo "tools decision changed ($prev_tools -> $use_tools); the agent is rebuilt with it"
			chat_engine_transport_config "$win" gguf "$model_path" "$use_tools" "" "$prev_port"
			engine_ready=$?
			if [ "$engine_ready" = 0 ]; then
				model_label="$LAUNCHED_MODEL_LABEL"
				inject_needed=1
			fi
		else
			launch_model_on_port "$model_path" "$win" "$prev_port"
			engine_ready=$?
			[ "$engine_ready" = 0 ] && model_label="$LAUNCHED_MODEL_LABEL"
		fi
		# ONE RESIDUAL, NAMED. If the launch above succeeds and the transport build after it does
		# not, the rollback below puts the model stamp back to the model this window WAS running -
		# but the server on its port is now serving the new one, and the old agent is still pointed
		# at that port, so the window would answer as the new model while every label named the old.
		# Not reachable in practice: on this engine the transport builder writes JSON on every path
		# it can take, including the one where the bundled Python is missing. Left as it is rather
		# than branched around, because the branch would be a second definition of "failed" in the
		# one cell that already has the most.
	elif [ "$target_engine" = "gguf" ]; then
		# ── mlx / on-device -> gguf: a server has to exist before the agent asks ──
		# ORDER IS FORCED, and it costs something. The new agent health-checks llama-server during
		# session/new and gives up after about seven seconds, which is far less than a model load,
		# so the server must be up BEFORE the injection - and that means the window's outgoing
		# mlx-agent is still resident while the server is sized and started. compute_server_memory_args
		# counts it as a live sibling and llama.cpp's --fit measures the memory it is holding, so
		# this server is sized conservatively for the rest of its life. Accepted for now: injecting
		# first would free those weights but land the new agent on a server that is not listening
		# yet, which surfaces as an error in the conversation rather than a slightly smaller context.
		port_num=$(find_free_port_in "$LLAMA_PORT_RANGE_START" "$LLAMA_PORT_RANGE_END")
		if [ -z "$port_num" ]; then
			echo "no free llama-server port in ${LLAMA_PORT_RANGE_START}-${LLAMA_PORT_RANGE_END}"
			"$alert" --level "stop" --title "$APPLET_NAME" --ok "OK" \
				"Too many models are already running. Close a model window and try again."
		else
			pb_set "aichatv2_port_${win}" "$port_num"
			chat_engine_transport_config "$win" gguf "$model_path" "$use_tools" "" "$port_num"
			engine_ready=$?
			if [ "$engine_ready" = 0 ]; then
				model_label="$LAUNCHED_MODEL_LABEL"
				inject_needed=1
			else
				# The server may be UP and registered to this window: the launch succeeded and the
				# transport was refused after it. Nothing will ever talk to it, and the close handler
				# stops one server per window, so a later gguf-to-gguf switch on a fresh port would
				# strand this one until the app quits. A launch that never came up leaves nothing
				# registered and this says so and returns.
				stop_window_server "$win" "SWITCH-FAILED"
			fi
		fi
	else
		# ── anything -> mlx / on-device: the argv, and nothing else to build ──
		# The old agent is still answering until the injection below replaces it, so a failure here
		# costs nothing: nothing has been stopped, and the conversation continues on the old model.
		chat_engine_transport_config "$win" "$target_engine" "$model_path" "$use_tools" ""
		engine_ready=$?
		[ "$engine_ready" = 0 ] && inject_needed=1
	fi

	if [ "$engine_ready" != 0 ]; then
		# Put the window back the way it was found. On the gguf-to-gguf cell the previous server is
		# ALREADY GONE - launch_model_on_port frees the port before it spawns anything - so the
		# stamp goes back to the model the model bar is still showing, the only model this window
		# can honestly claim.
		#
		# THE TIMEOUT IS NOT AN EXCEPTION, though it looks like one. wait_for_server's 13 is a
		# /health poll that never checks the pid, so a model that died during tensor load reports
		# exactly like one still loading. And a server that timed out never reaches
		# register_started_server, so it is unprotected: the next chat window to open reaps it.
		# Keeping it stamped would name a model that is unregistered, unreachable and about to be
		# killed - and would leave prev_model_path pointing at it, so the NEXT failed switch would
		# roll back to a model that never loaded either.
		pb_set "aichatv2_modelpath_${win}" "$prev_model_path"
		pb_set "aichatv2_port_${win}" "$prev_port"
		chat_engine_title "$win" "failed to load model"
		echo "switch failed (target=$target_engine); window $win stays on $prev_model_path"
		chat_loading_overlay_hide "$win"
		return 1
	fi

	if [ "$inject_needed" = 1 ] && [ -n "$CHAT_ENGINE_CONFIG" ]; then
		# THE SWITCH ITSELF, for every cell that needed a different agent. The element stops the
		# process it has, attaches one built from this argv and primes it from the transcript on
		# screen; the conversation the user is looking at is what the new model is handed.
		"$dialog" "$win" "$CHAT_ELEMENT_ID" omc_set_state config "$CHAT_ENGINE_CONFIG"
		echo "injected states[config] for $target_engine"
		# THE OUTGOING SERVER, and only an outgoing one. The stamped port names the server this
		# window is LEAVING - unless the target is gguf, where the same port now carries the server
		# just launched for the model being switched TO. Without the second test, a gguf-to-gguf
		# switch that rebuilt its agent (a changed tools decision) would kill the server it had
		# just started, report success, and leave a live composer pointed at a dead port.
		if [ -n "$prev_port" ] && [ "$target_engine" != "gguf" ]; then
			# Stopped AFTER the injection and never before it. The injection is
			# what ends the old agent, and until it returns that agent may be mid-request against
			# this server: stopping it first would fail that request, and the failure would reach the
			# transcript as an error item and the journal as an error entry, moments before the agent
			# was going to be replaced anyway. Its memory overlaps the new agent's load only for the
			# time between the call above returning and the TERM below.
			stop_window_server "$win" "SWITCH"
			pb_set "aichatv2_port_${win}" ""
		fi
	fi

	pb_set "aichatv2_tools_${win}" "$use_tools"
	chat_engine_remember_recent "$model_path"
	chat_model_bar_set "$win" "$model_label"
	chat_engine_title "$win" "$model_label"

	# The handover, recorded in the conversation it happened in. This is the case the info pane
	# cannot describe at all: it names the model the session STARTED with, and an in-place switch
	# keeps the same session, so without a marker the transcript has two stretches of assistant
	# turns written by different models and nothing saying where one ends.
	#
	# It reaches the display NOW, through the element's append state: the transcript is never
	# re-injected by a switch (the cells that respawn the agent re-prime it from what is already
	# on screen), and re-injecting purely to show a marker would replace the display with the
	# journal's version of itself.
	#
	# Unless this window is still holding the marker that OPENS its next stretch of conversation -
	# minted when the window became able to answer, and still waiting because nothing has been said
	# into it since. Then the switch queues behind that marker instead of being recorded on its
	# own: both lead the first message, and the pair is recorded together by the turn that finally
	# arrives (aichat.chat.entry.sh). Recording it here could not work anyway - a brand-new window
	# has no session directory to record into yet - and this is what keeps the transcript agreeing
	# with what the user watched happen in the window.
	if [ -n "$(history_marker_pending "$win")" ]; then
		history_marker_lead "$win" "$CHAT_ELEMENT_ID" modelChanged "$model_label"
	else
		# The ordinary case: a conversation that has been spoken to, being handed to another model
		# between turns. The end of the transcript is exactly where this belongs, so it is recorded
		# and shown in one step.
		#
		# The armed-resume check stays as a floor under the queue. A conversation opened in a
		# window that had no engine to name shows no marker and queues nothing, so the queue alone
		# would read that state as "spoken to" and record a switch into a transcript nothing has
		# happened in - which is what this check has always been here to refuse.
		local switch_sid
		switch_sid=$(pb_get "aichatv2_session_${win}")
		if [ -n "$switch_sid" ] && \
		   [ "$(pb_get "aichatv2_resume_pending_${win}")" != "$switch_sid" ]; then
			history_mark_and_show "$win" "$CHAT_ELEMENT_ID" "$switch_sid" modelChanged "$model_label"
		fi
	fi

	echo "switched to $model_label"
	chat_loading_overlay_hide "$win"
	return 0
}
