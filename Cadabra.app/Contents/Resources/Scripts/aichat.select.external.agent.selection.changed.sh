#!/bin/bash
# aichat.select.external.agent.selection.changed.sh
# Repaints the About pane, loads the row's command into the editable field, and enables OK.
#
# The command field is the contract, not the table row: whatever ends up in it is what gets
# stored and run. Selecting a row seeds it; the user is free to edit afterwards, which is the
# only way "Custom command" can work at all.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.acp.agents.library.sh"

INFO_TEXT_ID=12
COMMAND_FIELD_ID=20
RESULT_TEXT_ID=24
OK_BUTTON_ID=3
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

selected_command="$OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE"
selected_id="$OMC_ACTIONUI_TABLE_10_COLUMN_4_VALUE"

if [ -z "$selected_id" ]; then
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select an agent from the list."
    exit 0
fi

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

case "$selected_id" in
    custom)
        # Seed from the stored command ONLY when the stored selection IS the custom one.
        #
        # Blanking it unconditionally is what made a saved custom command impossible to
        # re-commit: the field was pre-filled at init, clicking the only row that keeps
        # selected_id=custom wiped it, and OK then refused with "Enter a command before
        # continuing". That case is still seeded, and is the only one that should be.
        #
        # Seeding it from ANY stored command was wrong the other way, and worse. With a
        # catalog agent configured, clicking Custom pre-filled THAT agent's command - so the
        # dialog showed, say, the Claude adapter's path under "Custom" - and pressing Use This
        # Agent then stored id=custom over a perfectly good known agent, discarding its label,
        # note and link and leaving the window titled with a bare basename.
        if [ "$(acp_agent_stored_id)" = "custom" ]; then
            "$dialog_tool" "$window_uuid" $COMMAND_FIELD_ID "$(acp_agent_stored_command)"
        else
            "$dialog_tool" "$window_uuid" $COMMAND_FIELD_ID ""
        fi
        info="**${label}**"
        append "$summary"
        append "$note"
        append "Type the command exactly as you would run it in Terminal, including any subcommand or flag that puts the agent into ACP mode. Quote a path that contains spaces."
        ;;
    *)
        [ "$selected_command" = "-" ] || "$dialog_tool" "$window_uuid" $COMMAND_FIELD_ID "$selected_command"
        info="**${label}**"
        append "$summary"
        if [ "$state" = "missing" ]; then
            append "**Not installed on this Mac.** The command below is what Cadabra would run once it is."
        fi
        append "$note"
        if [ "$state" = "missing" ]; then
            # Install instructions are COMPUTED rather than carried in the catalog, because
            # they depend on whether the package manager this agent needs is itself here.
            # Empty for a row with no package-manager install, which is most of them.
            append "$(acp_agent_install_hint "$selected_id")"
        fi
        ;;
esac

# The vendor link goes last, and only when the catalog has one. Markdown links DO survive this
# pane: the renderer flattens block structure but a link is an inline attribute, so it comes
# through as a real clickable link even after acp_md_paragraphs rewrites every line. Measured
# with AttributedString(markdown:) rather than assumed, including a URL containing parentheses.
append_link() {
    [ -n "$url" ] && [ "$url" != "-" ] || return 0
    # "Custom" is not an agent - it is the row for typing your own command - so "More about
    # Custom" would name a product that does not exist. It still gets a link, because the
    # protocol's own registry of ACP agents is exactly what someone about to type a command
    # wants; only the label changes, to describe where it actually goes.
    if [ "$selected_id" = "custom" ]; then
        info="${info}

[Browse the ACP agent registry](${url})"
    else
        info="${info}

[More about ${label}](${url})"
    fi
}
append_link

# Piped through acp_md_paragraphs: a bare blank line is a paragraph break the flattened
# renderer drops, which would run the heading straight into the note text.
"$dialog_tool" "$window_uuid" $INFO_TEXT_ID markdown "$(printf '%s' "$info" | acp_md_paragraphs)"
"$dialog_tool" "$window_uuid" $RESULT_TEXT_ID "Press Test to launch the agent and check that it answers."

# OK is enabled for every row, including a missing one: the command field is editable, so the
# user may be pointing a known-agent row at a binary we did not find on the search path. Test
# is how you check before committing; refusing to enable OK here would block that legitimate
# case to prevent a mistake the window already reports clearly.
"$dialog_tool" "$window_uuid" $OK_BUTTON_ID omc_enable
