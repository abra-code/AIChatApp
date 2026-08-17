#!/bin/bash
# aichat.select.external.agent.command.changed.sh
# The Command field: save the command into the agent the detail pane is showing.
#
# The counterpart to the rename, and it exists for the same reason. This editor has no Save
# button, so both of its fields have to write through on their own - and until this handler
# existed only the name did. A saved agent's name stuck the moment you clicked away while its
# command silently did not, which is the worst possible split: the two fields sit one above the
# other, look identical, and behaved differently.
#
# ONLY A SAVED AGENT IS WRITTEN THROUGH. Editing the command under a built-in row means "run
# something else instead", which is an ad-hoc command with no record to put it in - the OK
# handler decides what that becomes, and it reads the field directly.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.select.external.agent.library.sh"

# The pane owner, for the reason the rename uses it: this fires on focus loss, so it commonly
# runs alongside the selection change that caused it, and the highlighted row is not a fixed
# thing for the length of this script. An empty owner means a repaint is in flight and the
# field beside it belongs to nobody nameable yet.
edit_id=$(agent_pane_owner)

case "$edit_id" in
    custom:*) ;;
    *) exit 0 ;;
esac

# Cleaned exactly as the OK handler cleans it, so the record holds the same bytes whichever
# path saved it. Trims the ends and neutralizes tabs, and deliberately leaves interior runs
# alone - spacing inside a quoted argument is part of the argument.
new_command=$(acp_clean_one_line "${OMC_ACTIONUI_VIEW_20_VALUE:-}")
current_command=$(acp_custom_get "$edit_id" command)

# An EMPTY command is allowed here, unlike an empty name. A saved agent with nothing typed into
# it yet is a real state - it is what + creates - and the list says "Not set" for exactly that.
# So clearing the field is an edit like any other, not something to refuse.
[ "$new_command" = "$current_command" ] && exit 0

# The same saver the buttons use, with an empty name meaning "leave the name alone" - so the
# read-back discipline and the two failure diagnoses live in ONE place rather than being
# reimplemented per handler and drifting.
#
# BOTH failures are reported. Returning quietly was the old behavior and it is the wrong one
# here: the user typed a command, clicked away, and every visible thing agrees it was accepted
# while the record has no idea. The Test Result box is the only place this handler can say so,
# and it carries no identity, so a message landing late is stale text and nothing worse.
agent_save_pane_edits "$edit_id" "" "$new_command"
case $? in
    1)  "$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "This agent is no longer in the list, so the command was not saved. It was removed in another window, or the settings file was edited by hand."
        # Repaint keyed on the vanished id, which matches no row - so the phantom row goes and
        # the selection is left exactly where it is rather than being forced onto a neighbor.
        agent_refresh_list $TABLE_ID "$edit_id"
        exit 0
        ;;
    2)  "$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Could not save this command. Check that ~/Library/Application Support/Cadabra is writable."
        exit 0
        ;;
esac
saved_command="$new_command"

# The cleaned value is NOT written back into the field, for the reason the rename does not write
# its name back: this handler holds no claim on the pane, so that write is unserialized, and
# landing late it would drop this agent's command into another agent's signed editor - where the
# next blur or OK commits it. The record holds the cleaned value and the next repaint of the
# pane shows it. Only the rare pasted-tab case is visibly stale, and only until the next click.

# Repaint the list, because the command is not invisible in it: the Status column is computed
# from the command, so an agent that was "Not set" becomes "Ready" or "Not found" the moment one
# is typed. Leaving the row alone would show "Not set" beside a command that is saved and about
# to run. Same division of labor as the rename - the rows and the highlight, never the detail
# pane and never the pane owner, so those keep exactly one writer.
agent_refresh_list $TABLE_ID "$edit_id"

# CONTINUE IS DELIBERATELY LEFT ALONE, including when the field was just cleared. Disabling it
# on an empty command looks tidier and breaks the button: this handler runs on focus loss, so
# typing a command and clicking straight on Continue would arrive at a button that was still
# disabled when the click landed, and a disabled button does not receive it. The user would have
# to click twice, once to commit the field and once to press the button they already pressed.
# The empty command is refused by the Continue handler instead, which says so where they look.
