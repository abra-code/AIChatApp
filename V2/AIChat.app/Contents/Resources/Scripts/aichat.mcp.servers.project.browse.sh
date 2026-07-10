#!/bin/sh
# aichat.mcp.servers.project.browse.sh
# Opens a folder picker for the prominent "Project Workspace" path.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
PROJECT_FIELD_ID=310

# OMC presents its built-in folder picker (configured via CHOOSE_FOLDER_DIALOG in
# Command.plist) because this script references $OMC_DLG_CHOOSE_FOLDER_PATH.
chosen="$OMC_DLG_CHOOSE_FOLDER_PATH"
[ -z "$chosen" ] && exit 0

# Strip a trailing slash for consistency with how paths are stored elsewhere.
chosen="${chosen%/}"

"$dialog" "$window_uuid" $PROJECT_FIELD_ID "$chosen"
mcp_prefs_set_string servers/local/project "$chosen"
