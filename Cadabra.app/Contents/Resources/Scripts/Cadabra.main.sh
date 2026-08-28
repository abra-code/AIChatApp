#!/bin/sh
# Cadabra.main.sh - the main command's script, and the whole of what happens at launch.
#
# THE FILENAME IS THE WIRING. The main command is the first entry in COMMAND_LIST and has
# no COMMAND_ID, so the engine resolves its script from the command's NAME:
# OmcExecutor.cp builds "<NAME>.main" and falls back to a literal "main". NAME is "Cadabra",
# so this file must be Cadabra.main.sh. Renaming the app without renaming this file is not
# an error anyone sees - CreateScriptPathAndShell logs "unable to find script file" and
# returns, so the applet launches, opens nothing, and reports nothing. That is exactly what
# happened between the AIChat -> Cadabra rename and this comment: the file was still called
# AIChat.main.sh. Tests/98-command-wiring.test.sh now asserts the binding for every command.
#
# ACTIVATION_MODE is absent and therefore act_always, which is what lets this run on a bare
# double-click with no file context.

echo "[$(/usr/bin/basename "$0")]"
echo "OMC_CURRENT_COMMAND_GUID: ${OMC_CURRENT_COMMAND_GUID}"

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

echo "AICHAT_MODEL_PATH = $AICHAT_MODEL_PATH"
echo "OMC_OBJ_PATH = $OMC_OBJ_PATH"

# The branch is why this command chains imperatively with omc_next_command rather than
# declaratively with NEXT_COMMAND_ID the way the batch-conversion applets do: the two
# outcomes are different WINDOWS, so the choice cannot be made after one of them has opened.
# Whatever this launch turns out to be, it is not the one that armed the first-run handoff
# before it - the pasteboard outlives the app, so an arm stranded by a crash before the browser
# could claim it is still here. Cleared unconditionally, and re-armed below only if this launch
# earns it, which makes this command the single writer of that key. See hf_first_run_arm.
hf_first_run_clear

if [ -n "$AICHAT_MODEL_PATH" ] || [ -n "$OMC_OBJ_PATH" ]; then
	# a model file bundled, or a file or folder dropped on the app icon
	"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.chat"
else
	# Nothing to open yet, so the window that opens is the one that answers "what do I do
	# now", and that depends on whether this Mac has a model at all. Asked HERE rather than
	# inside the picker, because the answer picks a different WINDOW - the same reason this
	# command chains imperatively at all.
	#
	# The check is the disk scan the picker's own init would do a moment later (one shared
	# root list, model_scan_roots), stopped at the first hit. It counts downloaded GGUF and
	# MLX models only; see model_any_installed for why Apple's on-device model is not one.
	model_any_installed
	has_models=$?

	if [ "$has_models" -eq 0 ]; then
		# Present the Local Models dialog - picking a model is the thing a user launching
		# Cadabra came to do. It needs no input to open: its init scans the model
		# directories and seeds the recents list on its own.
		"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.select.local.model"
	else
		# Nothing installed. The picker would open on a list holding at most the on-device
		# row, offering nothing to pick and no hint of where models come from, so open the
		# Hugging Face browser instead: downloading one is the only move available, and it
		# is the move this window exists for. The arm below is what makes closing that
		# browser hand back to the picker rather than to an empty screen.
		hf_first_run_arm
		"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.hf.browse"
	fi
fi
