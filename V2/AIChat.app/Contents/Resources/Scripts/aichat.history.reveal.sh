#!/bin/sh
# aichat.history.reveal.sh
# Reveal the selected session's directory in Finder (files: journal.jsonl, meta.json).
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"

sid="$OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE"
[ -n "$sid" ] || exit 0
dir=$(history_session_dir "$sid") || exit 0
[ -d "$dir" ] && /usr/bin/open -R "$dir"
