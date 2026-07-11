#!/bin/sh

# app.did.launch — runs once when the app finishes launching (OMC fires the reserved
# app.did.launch command from applicationDidFinishLaunching).
#
# One-time automatic import of the v1 (WebUI) chat history into this app's native history store.
# It runs exactly once ever - guarded by a persistent marker - and never prompts. The pipeline is
# idempotent (webui_history_convert.py upserts by webui-<convid> and skips unchanged), so a re-run
# after an interrupted first attempt is safe. Imported sessions land in $history_root and appear
# in the sidebar the next time it is populated (which happens only after the user picks a model and
# opens the chat window, so a background run finishes well before then and never blocks launch).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

marker="$mcp_app_support/.webui_history_imported"
[ -f "$marker" ] && exit 0   # already imported once - never again

py="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
scripts_dir="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts"
v1_webkit="$HOME/Library/WebKit/com.abracode.AIChat/WebsiteData/Default"

/bin/mkdir -p "$mcp_app_support"

# Nothing to import if v1 was never installed here - record the marker so we do not rescan on
# every launch, and stop.
if [ ! -d "$v1_webkit" ]; then
    printf 'no v1 WebUI data at %s - nothing to import (%s)\n' \
        "$v1_webkit" "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$marker"
    exit 0
fi

# Best-effort single-run lock: if a prior launch's import is still running, do not start a second
# concurrent one. (The convert step is already corruption-safe under concurrency - per-pid temp
# files + a journal-completeness guard - so this only avoids wasted duplicate work; a stale lock
# from a crashed run is detected by the dead-pid check and ignored.)
lock="$mcp_app_support/.webui_import.lock"
if [ -f "$lock" ]; then
    lpid="$(/bin/cat "$lock" 2>/dev/null)"
    if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
        exit 0
    fi
fi

# Run the proven extract -> convert pipeline in the background so launch is never blocked. The
# marker is written only after a successful convert, so an interrupted run simply retries next
# launch (idempotent).
(
    log="$mcp_app_support/webui-import.log"
    staging="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/aichat-webui-import.XXXXXX")"
    /bin/mkdir -p "$history_root"

    {
        printf '=== webui history import %s ===\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
        "$py" "$scripts_dir/webui_history_extract.py" "$staging" --webkit-root "$v1_webkit"
        extract_rc=$?
        if [ "$extract_rc" -eq 0 ]; then
            "$py" "$scripts_dir/webui_history_convert.py" "$staging" "$history_root"
            convert_rc=$?
            if [ "$convert_rc" -eq 0 ]; then
                printf 'imported v1 WebUI history (%s)\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$marker"
                printf 'import OK; marker written\n'
            else
                printf 'convert failed rc=%s - will retry next launch\n' "$convert_rc"
            fi
        else
            printf 'extract failed rc=%s - will retry next launch\n' "$extract_rc"
        fi
    } > "$log" 2>&1

    /bin/rm -rf "$staging"
    /bin/rm -f "$lock"
) &

printf '%s\n' "$!" > "$lock"

exit 0
