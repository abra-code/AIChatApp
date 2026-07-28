#!/bin/sh
# aichat.mcp.servers.toggle.pdf.sh
# Handles the "PDF" server checkbox. Persists the flag and, in the live dialog, enables
# or disables the nested "Allow PDF editing" toggle so it is visually clear that the
# mutating tools cannot be served when the PDF server itself is off (its stored value is
# kept and restored when PDF is re-enabled). The actual gating - pdfutil's --writable
# flag and the gatedTools list - is applied in generate_mcp_configs.py.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"

echo "[$(/usr/bin/basename "$0")]"

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

PDF_WRITABLE_TOGGLE_ID=261

pdf_enabled="${OMC_ACTIONUI_VIEW_260_VALUE:-true}"

mcp_prefs_init_if_missing
mcp_prefs_set_bool servers/pdf/enabled "$pdf_enabled"

if [ "$pdf_enabled" = "true" ]; then
    "$dialog" "$window_uuid" $PDF_WRITABLE_TOGGLE_ID omc_enable
else
    "$dialog" "$window_uuid" $PDF_WRITABLE_TOGGLE_ID omc_disable
fi

echo "saved servers/pdf/enabled=$pdf_enabled"
