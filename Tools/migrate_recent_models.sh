#!/bin/sh
# migrate_recent_models.sh - move a pre-release "recently opened models" list into Cadabra's
# settings file, once, from outside the app.
#
# WHY THIS IS NOT IN THE APP. Cadabra's recents used to live in the com.abracode.Cadabra
# preferences domain under the key recentModelPaths; they now live in the app's own settings
# file, under /recent-models, alongside /servers and /agents. Cadabra has not shipped, so the
# only people with a list in the old place are the ones who built it. A migration carried
# inside the app would run on every launch of every copy, forever, for a case that stops
# existing at release - so it runs here instead, by hand, and is deleted when it stops being
# useful to anyone.
#
# WHAT IT DOES NOT DO: it does not remove the old key. That would mean writing a cfprefsd-owned
# domain behind cfprefsd's back, which is the very thing the move was for. The old list is
# harmless where it is - nothing reads it any more.
#
# Idempotent: it refuses once /recent-models exists, so a second run cannot resurrect paths the
# user has since removed. --force overrides that, replacing whatever is there.
#
# Usage:
#   Tools/migrate_recent_models.sh [--dry-run] [--force] [--app <Cadabra.app>]
#
# POSIX sh. Validate with "sh -n", never "bash -n".

set -u

KEY="recent-models"
LEGACY_KEY="recentModelPaths"
MAX=10

dry_run=0
force=0
app=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1; shift ;;
        --force)   force=1; shift ;;
        --app)     [ $# -ge 2 ] || { printf 'migrate_recent_models: --app needs a path\n' >&2; exit 2; }
                   app="$2"; shift 2 ;;
        -h|--help) /usr/bin/sed -n '2,25p' "$0"; exit 0 ;;
        *)         printf 'migrate_recent_models: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# The app is only needed for its plister, which is the tool that speaks this plist dialect.
if [ -z "$app" ]; then
    app="$(/usr/bin/dirname "$0")/../Cadabra.app"
fi
plister="$app/Contents/Frameworks/Abracode.framework/Versions/A/Support/plister"
[ -x "$plister" ] || plister="$app/Contents/Frameworks/Abracode.framework/Support/plister"
if [ ! -x "$plister" ]; then
    printf 'migrate_recent_models: no plister under %s (use --app <Cadabra.app>)\n' "$app" >&2
    exit 1
fi

settings="$HOME/Library/Application Support/Cadabra/settings.plist"
# Read through plister at an explicit PATH rather than through `defaults`: the path form is the
# file this script is actually talking about, and `defaults` would ask cfprefsd, which may be
# holding a different version of it in memory.
legacy="$HOME/Library/Preferences/com.abracode.Cadabra.plist"

if [ ! -f "$legacy" ]; then
    printf 'Nothing to migrate: %s does not exist.\n' "$legacy"
    exit 0
fi

# Counted from the array, never from the text. `iterate get string` prints one entry per line,
# and a path may contain a newline on every filesystem macOS mounts - so a line count would
# report one such model as two, and the verification at the end would then "confirm" the
# corruption it caused. The entries themselves are copied by INDEX below for the same reason.
total=$("$plister" get count "$legacy" "/$LEGACY_KEY" 2>/dev/null)
case "${total:-}" in ''|*[!0-9]*) total=0 ;; esac
if [ "$total" -eq 0 ]; then
    printf 'Nothing to migrate: %s has no %s.\n' "$legacy" "$LEGACY_KEY"
    exit 0
fi

if [ "$force" -eq 0 ] && "$plister" get type "$settings" "/$KEY" >/dev/null 2>&1; then
    printf 'Already migrated: %s already has /%s. Use --force to replace it.\n' "$settings" "$KEY"
    exit 0
fi

printf 'From: %s  (/%s)\n' "$legacy" "$LEGACY_KEY"
printf 'To:   %s  (/%s)\n' "$settings" "$KEY"

# Staged in a scratch plist and installed in ONE write. Two reasons, and both matter: entries
# are copied by index so a path containing a newline or a tab survives intact, and the settings
# file has three owners (/servers, /agents, /recent-models) with no locking anywhere, so a
# dozen sequential whole-file rewrites is a dozen chances to lose somebody else's write.
stage="${TMPDIR:-/tmp}/cadabra-migrate-recents-$$.plist"
/bin/rm -f "$stage"
"$plister" set dict "$stage" / >/dev/null 2>&1 || { printf 'FAILED: cannot write %s\n' "$stage" >&2; exit 1; }
"$plister" insert list array "$stage" / >/dev/null 2>&1

n=0
i=0
while [ "$i" -lt "$total" ]; do
    p=$("$plister" get string "$legacy" "/$LEGACY_KEY/$i" 2>/dev/null)
    i=$((i + 1))
    [ -n "$p" ] || continue
    if [ "$n" -ge "$MAX" ]; then
        printf '  skipped (over the %s-entry cap): %s\n' "$MAX" "$p"
        continue
    fi
    # Reported, not filtered. A model that is not there right now may be on a volume that is
    # simply not mounted, and dropping it silently is how a list quietly empties itself.
    if [ -e "$p" ]; then printf '  %s\n' "$p"; else printf '  %s   (not on disk right now)\n' "$p"; fi
    "$plister" append string "$p" "$stage" /list >/dev/null 2>&1
    n=$((n + 1))
done

staged=$("$plister" get count "$stage" /list 2>/dev/null)
case "${staged:-}" in ''|*[!0-9]*) staged=-1 ;; esac
if [ "$staged" -ne "$n" ]; then
    printf '\nFAILED: staged %s of %s entries - nothing was written.\n' "$staged" "$n" >&2
    /bin/rm -f "$stage"
    exit 1
fi

if [ "$dry_run" -eq 1 ]; then
    printf '\nDry run: nothing was written. %s entr%s would move.\n' "$n" "$([ "$n" -eq 1 ] && echo y || echo ies)"
    /bin/rm -f "$stage"
    exit 0
fi

# plister cannot create the file it inserts into; only `set dict <file> /` can. Without this a
# fresh profile takes every write as a silent no-op that still reports success.
if [ ! -f "$settings" ]; then
    /bin/mkdir -p "$(/usr/bin/dirname "$settings")" || exit 1
    "$plister" set dict "$settings" / >/dev/null 2>&1
fi
# ONE SUBTREE OF THREE, in ONE write. /servers and /agents belong to other parts of the app and
# share this file, so this replaces its own key and never the file. `set copy` handles both the
# present and the absent key, so no remove-then-insert window exists where the list is gone.
"$plister" set copy "$stage" /list "$settings" "/$KEY" >/dev/null 2>&1 \
    || "$plister" insert "$KEY" copy "$stage" /list "$settings" / >/dev/null 2>&1
/bin/rm -f "$stage"

written=$("$plister" get count "$settings" "/$KEY" 2>/dev/null)
case "${written:-}" in
    ''|*[!0-9]*) printf '\nFAILED: could not read back /%s from %s\n' "$KEY" "$settings" >&2; exit 1 ;;
esac
if [ "$written" -ne "$n" ]; then
    printf '\nFAILED: wrote %s of %s entries\n' "$written" "$n" >&2
    exit 1
fi
printf '\nMigrated %s entr%s. The old %s is left in place, unread.\n' \
    "$written" "$([ "$written" -eq 1 ] && echo y || echo ies)" "$LEGACY_KEY"
