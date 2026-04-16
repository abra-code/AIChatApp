#!/bin/sh
# aichat.select.local.model.reveal.sh
# Reveals the selected model file in Finder.

selected_path="$OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE"
if [ -n "$selected_path" ]; then
    /usr/bin/open -R "$selected_path"
fi
