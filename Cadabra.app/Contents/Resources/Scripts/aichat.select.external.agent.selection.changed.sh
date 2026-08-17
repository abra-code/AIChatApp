#!/bin/bash
# aichat.select.external.agent.selection.changed.sh
# Swaps the detail pane for the kind of row that was picked, loads its command into the
# editable field, and enables OK.
#
# The command field is the contract, not the table row: whatever ends up in it is what gets
# stored and run. Selecting a row seeds it; the user is free to edit afterwards.
#
# Two kinds of row, two panes. A built-in agent gets the About text - what it is, whether it is
# here, how to install it, where to read more - and none of that is editable, because it
# describes somebody else's product. An agent the user saved gets the editor, and gets it
# WITHOUT having to ask for it: there is no Edit button, selecting the row is the edit.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.select.external.agent.library.sh"

selected_command="$OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE"
selected_id="$OMC_ACTIONUI_TABLE_10_COLUMN_4_VALUE"

# This handler is the pane's writer, so it claims the pane before touching it and signs it once
# everything beside it is painted. Between those two calls the pane belongs to nobody, and a
# rename or an OK whose snapshot lands in that window declines rather than acting on a
# half-painted editor.
#
# The claim is taken as LATE as possible on every path below - after the catalog scan, after the
# record reads - never here at the top. Clicking two rows in quick succession runs two of these
# at once, and while one painter inside its bracket is provably consistent, two overlapping
# brackets are not: they can interleave their writes and leave one agent's fields under another
# agent's signature. A short bracket does not make that impossible, it makes it improbable.

if [ -z "$selected_id" ]; then
    agent_pane_begin
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select an agent from the list."
    agent_show_about_pane
    agent_sync_remove_button ""
    agent_pane_commit ""
    exit 0
fi

agent_sync_remove_button "$selected_id"

# A saved agent is edited in place. Its name and command both come out of the record, so this
# pane says the same thing however it was reached - a click here, the + button, or a rename.
case "$selected_id" in
    custom:*)
        agent_paint_custom_pane "$selected_id"
        agent_show_custom_pane
        "$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Press Test to launch the agent and check that it answers."
        "$dialog_tool" "$window_uuid" $OK_BUTTON_ID omc_enable
        agent_pane_commit "$selected_id"
        exit 0
        ;;
esac

# Re-read the catalog rather than carrying the note through the table: notes are prose and a
# single tab in one would shift every hidden column after it.
note=""
state=""
label=""
url=""
summary=""
while IFS='	' read -r id row_label row_state row_argv row_url row_summary row_note; do
    if [ "$id" = "$selected_id" ]; then
        label="$row_label"
        state="$row_state"
        url="$row_url"
        summary="$row_summary"
        note="$row_note"
        break
    fi
done <<EOF
$(acp_agent_scan)
EOF

# The pane is assembled in ONE place, in a fixed order, rather than per branch: what it is,
# then whether it is here, then what Cadabra knows about it, then how to get it, then where to
# read more. Building it per branch is what let an earlier version show the note on one path
# and not another. "-" is the catalog's spelling of "absent" and just drops the section.
append() { [ -n "$1" ] && [ "$1" != "-" ] && info="${info}

$1"; return 0; }

info="**${label}**"
append "$summary"
if [ "$state" = "missing" ]; then
    append "**Not installed on this Mac.** The command below is what Cadabra would run once it is."
fi
append "$note"
if [ "$state" = "missing" ]; then
    # Install instructions are COMPUTED rather than carried in the catalog, because they depend
    # on whether the package manager this agent needs is itself here. Empty for a row with no
    # package-manager install, which is most of them.
    append "$(acp_agent_install_hint "$selected_id")"
fi

# The vendor link goes last, and only when the catalog has one. Markdown links DO survive this
# pane: the renderer flattens block structure but a link is an inline attribute, so it comes
# through as a real clickable link even after acp_md_paragraphs rewrites every line. Measured
# with AttributedString(markdown:) rather than assumed, including a URL containing parentheses.
if [ -n "$url" ] && [ "$url" != "-" ]; then
    info="${info}

[More about ${label}](${url})"
fi

# Piped through acp_md_paragraphs: a bare blank line is a paragraph break the flattened
# renderer drops, which would run the heading straight into the note text. Rendered before the
# claim, like everything else expensive on this path.
info=$(printf '%s' "$info" | acp_md_paragraphs)

# The claimed span starts here, once the scan, the install hint and the markdown are all done.
agent_pane_begin
# The command field is seeded from the row, and it is a PANE field - so it belongs inside the
# bracket with the rest of the editor, not above it where a late-landing write could drop this
# agent's command into the next one's signed pane.
[ "$selected_command" = "-" ] || "$dialog_tool" "$window_uuid" $COMMAND_FIELD_ID "$selected_command"
"$dialog_tool" "$window_uuid" $INFO_TEXT_ID markdown "$info"
agent_show_about_pane
"$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Press Test to launch the agent and check that it answers."

# OK is enabled for every row, including a missing one: the command field is editable, so the
# user may be pointing a known-agent row at a binary we did not find on the search path. Test
# is how you check before committing; refusing to enable OK here would block that legitimate
# case to prevent a mistake the window already reports clearly.
"$dialog_tool" "$window_uuid" $OK_BUTTON_ID omc_enable

agent_pane_commit "$selected_id"
