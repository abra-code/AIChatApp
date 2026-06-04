#!/bin/sh
# aichat.model.help.init.sh
# INIT_SUBCOMMAND for the Model Guide help window (NIB_NAME AIChatHelp).
# Loads the bundled guide into the viewer's OMCWebKitView (tag 2).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

WEBVIEW_ID=2
# NIB dialogs expose their window via OMC_NIB_DLG_GUID (ActionUI windows use the
# OMC_ACTIONUI_WINDOW_UUID); fall back accordingly.
window_uuid="${OMC_ACTIONUI_WINDOW_UUID:-$OMC_NIB_DLG_GUID}"

html="$OMC_APP_BUNDLE_PATH/Contents/Resources/Help/model_guide.html"

# Build a proper percent-encoded file:// URL (handles spaces in the install path).
python3="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
url=$("$python3" -c 'import sys, pathlib; print(pathlib.Path(sys.argv[1]).as_uri())' "$html" 2>/dev/null)
[ -z "$url" ] && url="file://$html"

"$dialog" "$window_uuid" $WEBVIEW_ID "$url"
