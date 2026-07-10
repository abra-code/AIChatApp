#!/bin/sh
# aichat.mcp.inspect.tool.selection.changed.sh
# A tool row was (de)selected. Render its JSON input schema into the read-only
# editor from the per-server cache written by the server selection handler.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.inspect.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

SCHEMA_DESC_ID=402
SCHEMA_EDITOR_ID=403

tool="$OMC_ACTIONUI_TABLE_300_COLUMN_1_VALUE"
desc="$OMC_ACTIONUI_TABLE_300_COLUMN_2_VALUE"

if [ -z "$tool" ]; then
    "$dialog" "$window_uuid" $SCHEMA_EDITOR_ID ""
    "$dialog" "$window_uuid" $SCHEMA_DESC_ID "Select a tool to inspect its JSON schema."
    exit 0
fi

cache=$(pb_get "aichatv2_mcp_cache_${window_uuid}")
if [ -z "$cache" ] || [ ! -f "$cache" ]; then
    "$dialog" "$window_uuid" $SCHEMA_DESC_ID "Tool list is unavailable — reselect the server."
    exit 0
fi

python3_bin="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
inspect_py="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/mcp_inspect.py"
packages_dir="$OMC_APP_BUNDLE_PATH/Contents/Library/Packages"
schema_file="$mcp_inspect_dir/current-schema-${window_uuid}.json"

PYTHONPATH="$packages_dir" "$python3_bin" "$inspect_py" schema "$cache" "$tool" > "$schema_file" 2>/dev/null
rc=$?

# Description label (full one-line description carried in the table's hidden column).
if [ -n "$desc" ]; then
    "$dialog" "$window_uuid" $SCHEMA_DESC_ID "$tool — $desc"
else
    "$dialog" "$window_uuid" $SCHEMA_DESC_ID "$tool"
fi

if [ "$rc" != 0 ] || [ ! -s "$schema_file" ]; then
    "$dialog" "$window_uuid" $SCHEMA_EDITOR_ID ""
    exit 0
fi

# Pipe the schema in so multi-line JSON needs no shell quoting.
/bin/cat "$schema_file" | "$dialog" "$window_uuid" $SCHEMA_EDITOR_ID omc_set_value_from_stdin
