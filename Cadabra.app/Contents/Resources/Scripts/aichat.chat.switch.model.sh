#!/bin/sh
# aichat.chat.switch.model.sh
# In-place model switch: change the model of an OPEN conversation, targeting the ORIGINAL chat
# window (its UUID and the chosen model were stashed by the selector's OK handler in switch mode).
# The window keeps its transcript, its session binding and its title; what changes is what answers
# the next message.
#
# The work is chat_engine_switch, in the engine library, because it is the same four engine
# preparations a first load does and they must not exist twice. What lives here is the handoff:
# reading it, validating it, and clearing it so nothing can fire twice.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.chat.engine.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.server.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"
# For history_mark_session: the switch is recorded in the conversation's own transcript.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"


target_win=$(pb_get "aichatv2_switch_target")
pb_set "aichatv2_switch_target" ""
model_path=$("$pasteboard" "AICHATV2_MODEL_PATH" get)
"$pasteboard" "AICHATV2_MODEL_PATH" set ""
# The tools decision travels with the pick, because every cell except gguf-to-gguf replaces the
# agent process and can therefore honor a changed one. Read and cleared here with the rest of the
# handoff so a stale value cannot ride the next switch.
use_tools=$(pb_get "aichatv2_switch_tools")
pb_set "aichatv2_switch_tools" ""

[ -n "$target_win" ] || { echo "no target window for switch"; exit 0; }
# And it has to still be there. The selector is modeless and now owns its arm for its whole
# life, so the window that asked for the switch can be closed while the user is still choosing.
# The stashed keys outlive the window, so without this the switch would prepare an engine for
# nobody - and on a gguf target that means a llama-server registered to a host that is alive,
# therefore protected from the orphan reaper, and freed only when the app quits.
chat_window_is_open "$target_win" || { echo "window $target_win is gone; not switching"; exit 0; }
[ -n "$model_path" ] || { echo "no model for switch"; exit 0; }

chat_engine_switch "$target_win" "$model_path" "${use_tools:-false}"
