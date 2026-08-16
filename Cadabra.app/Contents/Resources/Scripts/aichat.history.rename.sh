#!/bin/sh
# aichat.history.rename.sh
# Prompt for a new title (AppleScript dialog) and write it into the session's meta.json,
# then refresh the list. The current title is passed as an argv to osascript so quotes /
# backslashes in it cannot break the script.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.history.library.sh"

sid="$OMC_ACTIONUI_TABLE_510_COLUMN_2_VALUE"
[ -n "$sid" ] || exit 0
dir=$(history_session_dir "$sid") || exit 0

current=$(history_title "$sid")

new_title=$(/usr/bin/osascript - "$current" <<'APPLESCRIPT'
on run argv
    set cur to item 1 of argv
    try
        return text returned of (display dialog "Rename chat" default answer cur with title "Cadabra")
    end try
    return ""
end run
APPLESCRIPT
)

# Cancel or empty -> no change.
[ -n "$new_title" ] || exit 0

# Merge title into meta.json (JSON-safe, atomic write so a concurrent index scan never sees
# a torn file).
"$history_py" -c 'import json, os, sys
p, title = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(p))
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
d["title"] = title
tmp = p + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, ensure_ascii=False)
os.replace(tmp, p)' "$dir/meta.json" "$new_title"

# Rebuild the sidebar list so the new title shows.
"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.history.refresh"
