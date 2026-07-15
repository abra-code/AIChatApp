#!/bin/sh

# app.did.launch — runs once when the app finishes launching (OMC fires the reserved
# app.did.launch command from applicationDidFinishLaunching).
#
# Offers a one-time import of the v1 (WebUI) chat history into this app's native history store.
# The user is ASKED first, exactly once ever, and either answer is final:
#
#   Import       -> run the pipeline; on success the marker records it and we never ask again.
#   Don't Import -> the marker records the refusal; we never ask and never import again.
#
# Someone else's history is not ours to move without being told to, and the answer only ever
# needs asking once - so the question is asked once and the refusal is as durable as the import.
#
# The whole flow (question included) is backgrounded so launch is never blocked. That is why the
# question can appear a moment after the window: the alternative, asking on the launch path,
# stalls the app behind a dialog the user may not answer for minutes. Imported sessions land in
# $history_root and appear in the sidebar the next time it is populated (only after a model is
# picked and the chat window opens, so the import finishes well before then).
#
# Three states, two files:
#   $marker  - terminal: imported, refused, or nothing-to-import. Its presence ends the story.
#   $consent - the user said yes but the pipeline has not succeeded yet. Lets an interrupted or
#              failed run retry SILENTLY on the next launch: consent was already given, and
#              re-asking a question they already answered would be the annoying kind of correct.
# The pipeline is idempotent (webui_history_convert.py upserts by webui-<convid> and skips
# unchanged), so a retry cannot duplicate anything.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

marker="$mcp_app_support/.webui_history_imported"
consent="$mcp_app_support/.webui_import_consent"
[ -f "$marker" ] && exit 0   # asked and answered once - never again

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

# Ask, then run the proven extract -> convert pipeline, all in the background so launch is never
# blocked. The marker is written only after a successful convert, so an interrupted run simply
# retries next launch (idempotent, and silently - see the consent file above).
(
    log="$mcp_app_support/webui-import.log"

    # Ask once. Skipped when the user already said yes and a previous attempt did not finish.
    if [ ! -f "$consent" ]; then
        "$alert" --level "note" --title "$APPLET_NAME" \
            --ok "Import" --cancel "Don't Import" \
            "Import your chat history from AIChat 1.x?

This Mac has chat history from the AIChat 1.x web interface. It can be copied into this app's history sidebar, leaving the original untouched.

You will only be asked once."
        answer=$?
        # Only rc 0 (Import) and rc 1 (Don't Import) are the user speaking. Anything else -
        # the alert tool erroring (-1, i.e. 255 here), a timeout (3), no GUI session to draw
        # in - means the question was never actually put to them, and a marker written on that
        # basis would silently retire the offer forever for a dialog nobody saw. Leave both
        # files absent and ask again next launch; nothing has been touched either way.
        if [ "$answer" != 0 ] && [ "$answer" != 1 ]; then
            {
                printf '=== webui history import %s ===\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
                printf 'could not ask (alert rc=%s); no marker, will ask again next launch\n' "$answer"
            } > "$log" 2>&1
            /bin/rm -f "$lock"
            exit 0
        fi
        if [ "$answer" = 1 ]; then
            printf 'user declined the v1 WebUI history import (%s)\n' \
                "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$marker"
            {
                printf '=== webui history import %s ===\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
                printf 'user declined; marker written, will not ask or import again\n'
            } > "$log" 2>&1
            /bin/rm -f "$lock"
            exit 0
        fi
        printf 'user approved the v1 WebUI history import (%s)\n' \
            "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$consent"
    fi
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
                # Consent has done its job: the marker is now the terminal state.
                /bin/rm -f "$consent"
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
