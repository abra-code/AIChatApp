#!/bin/sh
# aichat.select.local.model.reveal.sh
# Reveals the selected model file in Finder.

# Column 5 (hidden) holds the full model path - the picker draws four (format icon, Model,
# tools icon, Size) and carries this one past them. See aichat.select.local.model.init.sh.
selected_path="$OMC_ACTIONUI_TABLE_10_COLUMN_5_VALUE"
if [ -n "$selected_path" ]; then
    /usr/bin/open -R "$selected_path"
fi
