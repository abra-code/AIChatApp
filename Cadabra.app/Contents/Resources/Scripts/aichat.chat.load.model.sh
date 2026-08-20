#!/bin/sh
# aichat.chat.load.model.sh
# An EMPTY chat window is handed its first model: prepare the engine and inject the transport
# into the window that is already open, rather than opening a second one.
#
# NOT A SWITCH, which is the whole reason this is a separate handler from
# aichat.chat.switch.model.sh. A switch has to keep a transport that is already FROZEN
# pointing at something valid, which is why it is gguf-to-gguf only and why it reuses the
# window's pinned port. This window has no transport yet - the Chat element builds one the
# first time states["config"] arrives - so any of the four engines is fair game and there is
# nothing to preserve. It is the same code path a brand-new window runs, aimed at a window
# that happens to already exist.
#
# Reached two ways, both from the model picker's OK handler: directly when tools are off, and
# by way of the MCP servers dialog's Start when they are on (that dialog holds the launch for
# as long as the user needs, then hands it back). Either way the model and its tools decision
# arrive in the launch queue and the window in the load target.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.chat.engine.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"

echo "[$(/usr/bin/basename "$0")]"

target_win=$(load_target_consume)
[ -n "$target_win" ] || { echo "no target window for a first model load"; exit 0; }

# SHAPED LIKE A WINDOW UUID. This value comes off the pasteboard and is interpolated into a
# filesystem path downstream - the agent's per-session config dir, which the tools-off path
# removes - so it is checked here for the same reason session ids are, and with the same rule:
# nothing with a slash, a "..", or a leading dot. Every window uuid the engine mints passes.
case "$target_win" in
	*/*|*..*|.*)
		echo "refusing a target window that is not shaped like a window: $target_win"
		# Dropping the launch with it, like the two refusals below. The target was consumed
		# above, so a queue left armed here is a model with nowhere to go that the next
		# window to open would inherit.
		launch_queue_clear
		exit 0 ;;
esac

# STILL THERE? A launch routed through the MCP servers dialog can be parked for minutes, and
# that dialog holds it in its own scope where the closing window's disarm cannot reach it. This
# is not a cosmetic check: chat_engine_load would launch a real llama-server for a window that
# is gone, and nothing would ever tear it down. Dropping the queued launch with it, so it
# cannot be inherited by the next window to open.
if ! chat_window_is_open "$target_win"; then
	echo "window $target_win closed while its model was being chosen - dropping the launch"
	launch_queue_clear
	exit 0
fi

# STILL EMPTY? The other half of the same question, and it needs asking for the same reason:
# neither the picker nor the MCP servers dialog is modal, so the window is live and usable the
# whole time a launch is being decided for it. Pick a model with tools ON, leave that dialog
# open, pick a second model with tools off in the same window - and the first launch arrives
# afterwards, at a window that now has a frozen transport. Injecting a second config would be
# ignored (the element freezes on the first), but chat_engine_load would still claim a port and
# start a second llama-server that nothing owns and nothing tears down.
#
# The window's own stamps are the authority, read HERE rather than trusted from when the pick
# was made. Exactly the pair aichat.select.local.model.ok.sh reads to decide this is a first
# load at all - by the time delivery happens that decision can simply have expired.
if [ -n "$(pb_get "aichatv2_modelpath_${target_win}")" ] || \
   [ -n "$(pb_get "aichatv2_agent_${target_win}")" ]; then
	echo "window $target_win already has an engine - dropping the launch it no longer needs"
	launch_queue_clear
	exit 0
fi

queued=$(launch_queue_consume)
[ -n "$queued" ] || { echo "no queued model for window $target_win"; exit 0; }
model_path=$(launch_queue_model "$queued")
use_tools=$(launch_queue_tools "$queued")
[ -n "$model_path" ] || { echo "queued launch for window $target_win carries no model"; exit 0; }

echo "loading $model_path into window $target_win (use_tools=$use_tools)"

chat_engine_load "$target_win" "$model_path" "$use_tools" "false"

# The facts line, in case a conversation was already being read in this window while it had no
# engine - which is a normal thing to have been doing here, and is why the window opens
# without one at all.
chat_info_refresh "$target_win"
