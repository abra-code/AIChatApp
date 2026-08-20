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

queued=$(launch_queue_consume)
[ -n "$queued" ] || { echo "no queued model for window $target_win"; exit 0; }
model_path=$(launch_queue_model "$queued")
use_tools=$(launch_queue_tools "$queued")
[ -n "$model_path" ] || { echo "queued launch for window $target_win carries no model"; exit 0; }

echo "loading $model_path into window $target_win (use_tools=$use_tools)"

# The same clean slate a new window gets before it launches a server. This window skipped it
# at init, because at init there was nothing to launch.
stop_orphaned_servers
reap_orphaned_bundle_processes

chat_engine_load "$target_win" "$model_path" "$use_tools" "false"

# The facts line, in case a conversation was already being read in this window while it had no
# engine - which is a normal thing to have been doing here, and is why the window opens
# without one at all.
chat_info_refresh "$target_win"
