#!/bin/sh
# aichat.chat.window.sh
# File > New Chat Window: open the chat window with no model at all.
#
# Two lines of work, and the second one is the whole reason this is a command of its own
# rather than the menu item pointing straight at aichat.chat. A model pick that has not been
# consumed yet sits in the launch queue for up to LAUNCH_QUEUE_TTL seconds, and chat init
# consumes whatever it finds - so a user who picked a model, was routed through the MCP
# servers dialog, and then reached for File > New Chat Window would get that model's window
# instead of the empty one they asked for. Clearing the queue makes the gesture mean what it
# says: this window, no model.
#
# An external ACP agent is NOT cleared, and that is not an oversight. It is a standing choice
# about what drives this app's windows rather than a queued one-off, so a window opened while
# one is configured opens on that agent - which is exactly the engine such a user expects, and
# the model bar names it. Someone who wants the empty window instead turns the agent off under
# Tools, the same switch that turned it on.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

launch_queue_clear
"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.chat"
