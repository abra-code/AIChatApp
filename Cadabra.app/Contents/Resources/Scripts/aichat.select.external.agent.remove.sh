#!/bin/bash
# aichat.select.external.agent.remove.sh
# The - button: delete the selected agent of the user's own.
#
# Only a saved agent can be deleted - a built-in row is not the user's to remove - and the
# button is disabled for everything else, so the guard below is a second check rather than the
# only one. A button that is dead when it should be live is a bug the user can see; one that
# acts when it should not is a row silently gone.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.select.external.agent.library.sh"

# The agent the pane is showing, not the row that is highlighted. They are the same thing except
# while a repaint is in flight, and this button deletes a record - the one operation where acting
# on a stale identity is unrecoverable. An empty owner falls through the guard below and does
# nothing, which is the right answer for "the dialog is mid-repaint, ask again".
selected_id=$(agent_pane_owner)

case "$selected_id" in
    custom:*) ;;
    *) exit 0 ;;
esac

# A removal that finds nothing to remove still repaints, rather than returning quietly. The row
# came from the list, so if its record is not there the LIST is what is wrong - deleted by
# another window, or the settings file edited by hand - and returning early leaves the phantom
# row on screen, selectable, with a button that does nothing to it every time it is pressed.
# Repainting makes it disappear, which is both the truth and the fix.
if acp_custom_remove "$selected_id"; then
    # The record is gone, but the LIVE SELECTION may still name it, and a stored id pointing at
    # nothing would leave the agent named by a bare basename for no visible reason. Demote
    # it to the bare "custom" id, which means precisely this: a command with no record behind
    # it. The command itself is untouched, so a setup already running this way keeps working -
    # deleting a row from a list should not quietly switch the user back to the bundled agent.
    if [ "$(acp_agent_stored_id)" = "$selected_id" ]; then
        acp_agent_store custom "$(acp_agent_stored_command)"
    fi
fi

# Repaint on the configured agent rather than on the neighboring row. Programmatic selection
# does not fire the selection-changed action, so landing on a neighbor would mean reproducing
# that handler's work for a row the user never chose - and getting it subtly wrong is how a pane
# ends up describing one agent while the field holds another's command. Going back to what is
# configured is a state this dialog already knows how to paint exactly.
agent_restore_configured_view $TABLE_ID
