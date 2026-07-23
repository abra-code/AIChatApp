#!/bin/bash
# aichat.hf.browse.source.changed.sh
# Fires when the Source segmented control (Any | MLX | GGUF, view 205) changes. Reloads the
# model list for the new source, honouring the current sort and any active search. Delegates
# to sort.changed, which already handles both "search active -> re-run search" and "reload by
# sort" (both read the source via aichat.hf.browse.library.sh).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")] source=${OMC_ACTIONUI_VIEW_205_VALUE:-any}"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Force a reload: clear the last-query cache so search.sh (if a query is active) does not
# treat the re-run as an unchanged-query no-op.
pb_set "hf_last_query_${window_uuid}" ""
"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.hf.browse.sort.changed"
