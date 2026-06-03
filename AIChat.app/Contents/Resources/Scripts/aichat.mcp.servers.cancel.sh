#!/bin/sh
# aichat.mcp.servers.cancel.sh
# User closed the dialog without confirming. Discard any queued model path so
# the next selector flow doesn't accidentally inherit it.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

"$pasteboard" "AICHAT_MODEL_PATH" set ""
"$pasteboard" "AICHAT_USE_TOOLS" set ""
