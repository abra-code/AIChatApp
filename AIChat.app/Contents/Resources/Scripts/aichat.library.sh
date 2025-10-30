#!/bin/sh

dialog="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
plister="$OMC_OMC_SUPPORT_PATH/plister"
filt="$OMC_OMC_SUPPORT_PATH/filt"
pasteboard="$OMC_OMC_SUPPORT_PATH/pasteboard"
next_command="$OMC_OMC_SUPPORT_PATH/omc_next_command"

# when no model is bundled with the app:
AICHAT_MODEL_PATH=""

# when a model is bundled with the app:
# AICHAT_MODEL_PATH="$OMC_APP_BUNDLE_PATH/Contents/Resources/LFM2-1.2B-F16.gguf"

prefs="/Users/$USER/Library/Preferences/com.abracode.AIChat-servers.plist"
port_num="8088"
