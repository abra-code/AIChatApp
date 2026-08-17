#!/bin/bash
# aichat.select.external.agent.name.changed.sh
# The Name field: rename the agent the detail pane is showing.
#
# Fires on Return AND on losing focus, which is the ActionUI TextField contract on macOS and
# the classic AppKit one - clicking away commits. That is what makes the editor work with no
# Save button and no dialog: there is no moment where a typed name is only on screen.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.select.external.agent.library.sh"

# The PANE OWNER, not the selected row. Committing on focus loss means the commonest way to
# finish a rename is to click another row, and that click also moves the selection - so by the
# time this script has a snapshot, the highlight may already name a different agent while the
# Name field still holds what was typed for this one. Renaming by selection puts the typed name
# on whichever record the user happened to click. The pane owner is written by the pane painter
# and is the identity the field on screen actually belongs to. See the note in the library.
edit_id=$(agent_pane_owner)
new_label="${OMC_ACTIONUI_VIEW_53_VALUE:-}"

case "$edit_id" in
    custom:*) ;;
    # Empty owner means a repaint is in flight and the field beside it cannot be trusted to
    # belong to anyone. A built-in agent has no name to change.
    *) exit 0 ;;
esac

# An empty name is refused rather than stored. The list would still show something - it falls
# back to the command's basename and then to the id - but that fallback exists for a record
# damaged some other way, not as a thing to offer the user by letting them erase the field.
#
# The refusal is REPORTED rather than repaired. Putting the old name back into the field reads
# better and is not safe: this handler owns no claim on the pane, so that write is unserialized,
# and if it lands after a concurrent selection change has repainted the editor it plants this
# agent's name in another agent's signed pane - where the next blur commits it as a rename. The
# Test Result box carries no identity, so a late message is stale text and nothing worse. The
# field itself is corrected by the next repaint, which the click that caused this blur triggers.
# LC_ALL=C for the same reason acp_clean_one_line uses it: tr is byte-oriented and truncates at
# the first byte that is not valid in the current locale.
current_label=$(acp_custom_get "$edit_id" label)
if [ -z "$(printf '%s' "$new_label" | LC_ALL=C /usr/bin/tr -d '[:space:]')" ]; then
    "$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "An agent needs a name. Keeping \"$current_label\"."
    exit 0
fi

# Nothing typed, just focus moving through the field: do not repaint the table for it. This
# handler fires on every focus loss, and rebuilding the list runs the whole scan, which stats
# every catalog agent across every search directory.
[ "$new_label" = "$current_label" ] && exit 0

# The same saver the buttons use. The command it is handed is the record's OWN command, so that
# half is a no-op: this handler renames and must not touch what the user may be part-way through
# typing in the other field. Going through the shared saver anyway keeps one implementation of
# the read-back discipline and of the difference between "this record is gone" and "this file
# could not be written" - which need opposite answers and are easy to conflate.
#
# BOTH failures are reported rather than returned quietly. A rename that silently did nothing,
# with the typed name still sitting in the field, is indistinguishable from one that worked.
agent_save_pane_edits "$edit_id" "$new_label" "$(acp_custom_get "$edit_id" command)"
case $? in
    1)  "$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "This agent is no longer in the list, so the new name was not saved. It was removed in another window, or the settings file was edited by hand."
        # Keyed on the vanished id, which matches no row: the phantom row goes and the selection
        # is left where it is rather than being forced onto a neighbor nobody chose.
        agent_refresh_list $TABLE_ID "$edit_id"
        exit 0
        ;;
    2)  "$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Could not save this name. Check that ~/Library/Application Support/Cadabra is writable."
        exit 0
        ;;
esac

# The cleaned value is NOT written back into the field, even when cleaning changed something -
# a name pasted with a tab or a line break in it. That write would be worth very little and is
# unserialized for the same reason as the refusal above: landing late, it plants this agent's
# name in whatever pane is on screen by then, and a later blur commits it onto that record. The
# record already holds the cleaned value, the LIST below shows it, and the next repaint of the
# pane corrects the field. A cosmetically stale field for one keystroke is the cheap half of
# this trade.

# The list, which is the point of the exercise: a rename the sidebar does not show reads as a
# rename that did not happen.
#
# This rebuilds the rows and puts the highlight back on the renamed agent. It deliberately does
# NOT repaint the detail pane, and does not touch the pane owner. That division is what keeps a
# concurrent selection change from turning into a mislabeled window: the pane and its owner have
# exactly one writer - the code that paints them - so if the user's click has already switched
# the pane to another agent, this leaves that alone and only the highlight can end up on the
# wrong row. A wrong highlight is cosmetic and one click away from correct; a pane describing
# one agent while the buttons act on another is not.
agent_refresh_list $TABLE_ID "$edit_id"
