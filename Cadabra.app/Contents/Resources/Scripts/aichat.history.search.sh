#!/bin/sh
# aichat.history.search.sh
# The sidebar's search field changed (the Table's "searchable" property fires this with the raw
# text as the trigger context, on every keystroke). Two things follow from one term: the sidebar
# narrows to the conversations that mention it, most matches first, and the conversation open in
# this window - if there is one - lights the same term through the Chat element's find, which
# presents its bar without taking the keyboard focus away from this field. Clearing the field
# restores the full list and dismisses the find.
#
# The term is remembered per window (pasteboard) so a later repopulation of the list - a rename, a
# delete, a new conversation's first turn - keeps the filter, and so a row clicked while the filter
# is up can re-light the term in the conversation it opens (aichat.history.selection.changed.sh).
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"

win="$OMC_ACTIONUI_WINDOW_UUID"
CHAT_VIEW_ID=1
TABLE_ID=510

# The raw field text; leading / trailing whitespace is not a term.
query=$(printf '%s' "$OMC_ACTIONUI_TRIGGER_CONTEXT" | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

pb_set "${CAD_SEARCH_PREFIX}${win}" "$query"
history_populate_table "$win" "$TABLE_ID"

# Only a window showing a conversation has anything to light; an empty window's element would
# just present an empty find bar over nothing.
bound_session=$(pb_get "aichatv2_session_${win}")
if [ -n "$bound_session" ]; then
    history_search_state "$win" "$CHAT_VIEW_ID" "$query"
fi
