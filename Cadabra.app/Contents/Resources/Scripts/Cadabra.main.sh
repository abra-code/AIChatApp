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

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "AICHAT_MODEL_PATH = $AICHAT_MODEL_PATH"
echo "OMC_OBJ_PATH = $OMC_OBJ_PATH"

# The branch is why this command chains imperatively with omc_next_command rather than
# declaratively with NEXT_COMMAND_ID the way the batch-conversion applets do: the two
# outcomes are different WINDOWS, so the choice cannot be made after one of them has opened.
if [ -n "$AICHAT_MODEL_PATH" ] || [ -n "$OMC_OBJ_PATH" ]; then
	# a model file bundled, or a file or folder dropped on the app icon
	"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.chat"
else
	# Nothing to open yet, so present the Local Models dialog - picking a model is the
	# thing a user launching Cadabra came to do. It needs no input to open: its init
	# scans the model directories and seeds the recents list on its own.
	"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.select.local.model"
fi
