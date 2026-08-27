#!/bin/bash
# update-llama-cpp.sh
# Downloads and installs the latest (or specified) llama.cpp release into the app bundle.
# Supports arm64 and x86_64 — matching the separate per-arch app releases.
#
# Target bundle: this script serves the WebUI-based apps — the V1 AIChat.app in this repo,
# and single-app repos like Enoch. It is NOT for Cadabra.app, which has a native chat UI and
# its own ./update-cadabra.sh; a llama.cpp drop here would also try to patch a WebUI dir
# Cadabra does not have. Since this repo root holds both bundles, AIChat.app is named
# explicitly rather than globbed — see resolve_app_bundle().

set -uo pipefail

RED=$(printf '\033[91m')
GREEN=$(printf '\033[92m')
RESET=$(printf '\033[0m')

VERSION="auto"
ARCH="auto"
SIGNING_IDENTITY="-"
APP_BUNDLE=""   # empty = resolve from SCRIPT_DIR; --app=PATH overrides

# The bundle this script owns in a multi-app repo. Cadabra.app is deliberately not a
# candidate: it is native-chat and belongs to ./update-cadabra.sh.
PREFERRED_APP_NAME="AIChat.app"

# Set by prepare()
ASSET_NAME=""
DOWNLOAD_URL=""
WORK_DIR=""
TARBALL=""
EXTRACT_DIR=""

# Set by update_webui()
WEBUI_STATUS=""   # "ok", "patched-with-warnings", "download-failed", "skipped"

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" >/dev/null 2>&1 && pwd)"

WEBUI_SED_DIR="$SCRIPT_DIR/WebUI"

# Picks the bundle to update, in priority order:
#   1. --app=PATH, if the caller named one
#   2. $SCRIPT_DIR/$PREFERRED_APP_NAME, if present (this repo: AIChat.app, never Cadabra.app)
#   3. the sole *.app in SCRIPT_DIR (single-app repos such as Enoch)
# More than one candidate with no preferred name and no --app is an error, not a coin flip:
# the old code globbed and took the first match, which only picked AIChat.app over
# Cadabra.app because "A" sorts before "C".
resolve_app_bundle() {
    if [ -n "$APP_BUNDLE" ]; then
        APP_BUNDLE="${APP_BUNDLE%/}"
        [ -d "$APP_BUNDLE" ] || { echo "${RED}--app bundle not found: $APP_BUNDLE${RESET}" >&2; exit 1; }
        return 0
    fi

    if [ -d "$SCRIPT_DIR/$PREFERRED_APP_NAME" ]; then
        APP_BUNDLE="$SCRIPT_DIR/$PREFERRED_APP_NAME"
        return 0
    fi

    local candidates=()
    local _candidate
    for _candidate in "$SCRIPT_DIR"/*.app; do
        [ -d "$_candidate" ] || continue
        candidates+=("$_candidate")
    done

    case "${#candidates[@]}" in
        0) echo "${RED}No .app bundle found in $SCRIPT_DIR${RESET}" >&2; exit 1 ;;
        1) APP_BUNDLE="${candidates[0]}" ;;
        *)
            echo "${RED}Multiple .app bundles in $SCRIPT_DIR and no $PREFERRED_APP_NAME to pin to:${RESET}" >&2
            for _candidate in "${candidates[@]}"; do
                echo "  $(/usr/bin/basename "$_candidate")" >&2
            done
            echo "Pass --app=PATH to name the target explicitly." >&2
            exit 1
            ;;
    esac
}

# Cadabra.app has no Contents/Resources/WebUI — update_webui() would patch nothing and the
# app would keep running whatever llama.cpp build update-cadabra.sh put there. Refuse rather
# than half-update it, however the bundle was chosen.
reject_native_chat_bundle() {
    [ "$(/usr/bin/basename "$APP_BUNDLE")" = "Cadabra.app" ] || return 0
    echo "${RED}$(/usr/bin/basename "$APP_BUNDLE") is the native-chat app and is not served by this script.${RESET}" >&2
    echo "Use ./update-cadabra.sh instead (it installs llama.cpp, mlx-agent and pdfutil)." >&2
    exit 1
}

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Downloads the specified (or latest) llama.cpp macOS release and installs it
into <AppName>.app/Contents/Support/Llama.cpp/, then patches the app's WebUI.

Target bundle: $PREFERRED_APP_NAME in the directory containing this script, if present;
otherwise the sole *.app there. Cadabra.app is never a target - it has a native chat
UI and its own ./update-cadabra.sh.

Options:
  --version=VERSION   llama.cpp build tag to install (e.g. b8797), or:
                        auto     the newest official release (default; upstream tags these
                                 vX.Y.Z and points them at the build carrying the binaries)
                        nightly  the newest build, released or not
  --arch=ARCH         Architecture: arm64 or x86_64 (default: auto-detect from host)
  --identity=CERT     Signing identity for codesign (default: - for ad-hoc)
  --app=PATH          App bundle to update (default: $PREFERRED_APP_NAME beside this script)
  --help              Show this help message

Examples:
  ./update-llama-cpp.sh
  ./update-llama-cpp.sh --version=b8797 --arch=arm64
  ./update-llama-cpp.sh --version=nightly
  ./update-llama-cpp.sh --version=b8797 --arch=x86_64
  ./update-llama-cpp.sh --app=/path/to/Enoch.app
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --help) show_help ;;
        --version=*) VERSION="${1#*=}" ;;
        --version) shift; VERSION="${1:-}" ;;
        --arch=*) ARCH="${1#*=}" ;;
        --arch) shift; ARCH="$1" ;;
        --identity=*) SIGNING_IDENTITY="${1#*=}" ;;
        --identity) shift; SIGNING_IDENTITY="$1" ;;
        --app=*) APP_BUNDLE="${1#*=}" ;;
        --app) shift; APP_BUNDLE="$1" ;;
        *) echo "Unknown option: $1"; show_help ;;
    esac
    shift
done

resolve_app_bundle
reject_native_chat_bundle
echo "Target app bundle: $APP_BUNDLE"

INSTALL_DIR="$APP_BUNDLE/Contents/Support/Llama.cpp"
WEBUI_DIR="$APP_BUNDLE/Contents/Resources/WebUI"

detect_arch() {
    local host_arch
    host_arch=$(/usr/bin/uname -m)
    if [ "$host_arch" = "arm64" ]; then
        ARCH="arm64"
    else
        ARCH="x86_64"
    fi
    echo "  Detected host architecture: $ARCH"
}

# llama.cpp changed its release scheme in August 2026. The macOS binaries still ship on the
# bNNNN build tags under unchanged asset names, but those tags are now all marked prerelease,
# and /releases/latest resolves to an official semver release (v0.3.0 as of this writing)
# whose only asset is nightly-tag.txt, naming the build the release was cut from. Reading a
# bNNNN tag straight off /releases/latest therefore matches nothing - that is what broke
# detection. Resolving "latest" is now two hops.
#
# We deliberately follow the official release rather than the head of the build list, and
# never silently fall back from one to the other: an unresolvable release is an error the
# caller has to answer, because quietly installing the newest untagged build is exactly the
# behavior the official releases exist to end. VERSION=nightly opts into that head build.

# Echoes the tag_name of the newest official (non-prerelease) release, or nothing.
latest_release_tag() {
    local _json="$(/usr/bin/curl -s --fail --max-time 10 \
        "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" 2>/dev/null)"
    # grep -o emits its matches in document order, so head -1 is the first tag_name in the
    # document whether or not the JSON is pretty-printed. A greedy sed would instead collapse
    # a minified (single-line) document down to its LAST occurrence.
    local _tag="$(echo "$_json" \
        | /usr/bin/grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | /usr/bin/head -1 | /usr/bin/sed -E 's/.*"([^"]+)"$/\1/')"
    if [ -n "$_tag" ]; then
        echo "$_tag"
        return 0
    fi

    # API unreachable or rate-limited (60 anonymous requests/hour): read the tag out of the
    # /releases/latest redirect instead, which is not rate-limited.
    local _redirect="$(/usr/bin/curl -s -I -o /dev/null -w '%{redirect_url}' --max-time 10 \
        "https://github.com/ggml-org/llama.cpp/releases/latest" 2>/dev/null)"
    echo "$_redirect" | /usr/bin/sed -n -E 's#.*/releases/tag/([^/?\#[:space:]]+)$#\1#p'
}

# Echoes the bNNNN build tag an official release points at, or nothing. $1 = release tag.
nightly_tag_of_release() {
    local _txt="$(/usr/bin/curl -sL --fail --max-time 10 \
        "https://github.com/ggml-org/llama.cpp/releases/download/$1/nightly-tag.txt" 2>/dev/null)"
    echo "$_txt" | /usr/bin/tr -d '[:space:]' | /usr/bin/grep -oE '^b[0-9]+$'
}

# Echoes the newest bNNNN tag in the releases list (build tags are prereleases now, so the
# list is the only place they appear). The list is newest-first.
newest_build_tag() {
    local _json="$(/usr/bin/curl -s --fail --max-time 15 \
        "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30" 2>/dev/null)"
    # Document order via grep -o, as in latest_release_tag: with a greedy sed, a minified
    # response would silently yield the OLDEST build in the page instead of the newest.
    echo "$_json" \
        | /usr/bin/grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"b[0-9]+"' \
        | /usr/bin/head -1 | /usr/bin/grep -oE 'b[0-9]+'
}

detect_latest_version() {
    local _tag
    if [ "$VERSION" = "nightly" ]; then
        echo "Detecting newest llama.cpp build..."
        _tag="$(newest_build_tag)"
        if [ -z "$_tag" ]; then
            echo "${RED}No bNNNN tag in the llama.cpp releases list - github.com unreachable, or the API rate-limited this host.${RESET}" >&2
            echo "Specify --version=bNNNN explicitly." >&2
            exit 1
        fi
        VERSION="$_tag"
        echo "  Newest build: $VERSION"
        return 0
    fi

    echo "Detecting latest llama.cpp release..."
    local _release="$(latest_release_tag)"
    if [ -z "$_release" ]; then
        echo "${RED}Could not read a tag from github.com/ggml-org/llama.cpp/releases/latest - unreachable, or the API rate-limited this host.${RESET}" >&2
        echo "Specify --version=bNNNN explicitly." >&2
        exit 1
    fi

    case "$_release" in
        b|b*[!0-9]*)
            # b-prefixed but not a bare build number (say b10-rc1): a release tag, not a
            # build tag. Fall through to the nightly-tag.txt hop rather than build a URL.
            ;;
        b[0-9]*)
            # Upstream tagging official releases bNNNN directly (the pre-v0.1.2 scheme).
            VERSION="$_release"
            echo "  Latest release: $VERSION"
            return 0
            ;;
    esac

    _tag="$(nightly_tag_of_release "$_release")"
    if [ -z "$_tag" ]; then
        echo "${RED}Release $_release has no readable nightly-tag.txt, so the build tag carrying the macOS binaries is unknown - the release scheme has changed again.${RESET}" >&2
        echo "Check https://github.com/ggml-org/llama.cpp/releases and pass --version=bNNNN, or --version=nightly for the newest build." >&2
        exit 1
    fi
    VERSION="$_tag"
    echo "  Latest release $_release -> build $VERSION"
}

prepare() {
    echo
    echo "==== Preparing llama.cpp update ===="
    echo

    if [ "$ARCH" = "auto" ]; then
        detect_arch
    fi

    case "$ARCH" in
        arm64|x86_64) ;;
        *) echo "Invalid --arch: $ARCH (must be arm64 or x86_64)"; exit 1 ;;
    esac

    case "$VERSION" in
        auto|nightly) detect_latest_version ;;
    esac

    case "$VERSION" in
        b[0-9]*) ;;
        *) echo "Invalid --version: $VERSION (expected auto, nightly, or a build tag bNNNN)"; exit 1 ;;
    esac

    if [ ! -d "$INSTALL_DIR" ]; then
    	/bin/mkdir -vp "$INSTALL_DIR"
	fi
	
    if [ ! -d "$INSTALL_DIR" ]; then
        echo "Install directory not found and could not be created: $INSTALL_DIR"
        echo "Expected path: $INSTALL_DIR"
        exit 1
    fi

    if [ "$ARCH" = "arm64" ]; then
        ASSET_NAME="llama-${VERSION}-bin-macos-arm64.tar.gz"
    else
        ASSET_NAME="llama-${VERSION}-bin-macos-x64.tar.gz"
    fi

    DOWNLOAD_URL="https://github.com/ggml-org/llama.cpp/releases/download/${VERSION}/${ASSET_NAME}"
    WORK_DIR="$(/usr/bin/mktemp -d "$TMPDIR/update-llama-cpp.XXXXXX")"
    TARBALL="$WORK_DIR/$ASSET_NAME"
    EXTRACT_DIR="$WORK_DIR/extracted"

    echo
    echo "  Version     : $VERSION"
    echo "  Architecture: $ARCH"
    echo "  Asset       : $ASSET_NAME"
    echo "  Install dir : $INSTALL_DIR"
    echo "  Work dir    : $WORK_DIR"
    echo
}

download_release() {
    echo "==== Downloading llama.cpp $VERSION ($ARCH) ===="
    echo

    echo "  $DOWNLOAD_URL"
    /usr/bin/curl -L --fail --show-error --progress-bar -o "$TARBALL" "$DOWNLOAD_URL"
    local curl_result=$?
    if [ "$curl_result" != 0 ]; then
        echo "${RED}Download failed (curl exit code: $curl_result)${RESET}"
        /bin/rm -rf "$WORK_DIR"
        exit 1
    fi

    echo
    echo "  Saved: $TARBALL"
    echo
}

extract_and_install() {
    echo "==== Extracting archive ===="
    echo

    /bin/mkdir -p "$EXTRACT_DIR"
    /usr/bin/tar -xzf "$TARBALL" -C "$EXTRACT_DIR"
    local tar_result=$?
    if [ "$tar_result" != 0 ]; then
        echo "${RED}Extraction failed${RESET}"
        /bin/rm -rf "$WORK_DIR"
        exit 1
    fi

    # Locate llama-server inside the extracted tree
    local found_binary
    found_binary=$(/usr/bin/find "$EXTRACT_DIR" -name "llama-server" ! -type d 2>/dev/null | head -1)
    if [ -z "$found_binary" ]; then
        echo "${RED}llama-server not found in extracted archive${RESET}"
        /bin/rm -rf "$WORK_DIR"
        exit 1
    fi

    local src_dir="$(/usr/bin/dirname "$found_binary")"
    echo "  Archive content dir: $src_dir"
    echo

    echo "==== Installing into $INSTALL_DIR ===="
    echo

    # Remove existing dylibs and LICENSE files so stale files from prior versions
    # don't linger.
    # Use [ -e ] || [ -L ] to catch both valid files/symlinks and dangling symlinks
    # ([ -e ] follows symlinks, so it returns false if the target no longer exists).
    echo "  Removing existing dylibs..."
    local old_dylib
    for old_dylib in "$INSTALL_DIR"/*.dylib; do
        [ -e "$old_dylib" ] || [ -L "$old_dylib" ] || continue
        /bin/rm -f "$old_dylib"
    done

    echo "  Removing existing LICENSE files..."
    local old_license
    for old_license in "$INSTALL_DIR"/LICENSE*; do
        [ -f "$old_license" ] || continue
        /bin/rm -f "$old_license"
    done
    echo

    # Install llama-server binary
    echo "  llama-server"
    /bin/cp "$src_dir/llama-server" "$INSTALL_DIR/llama-server"
    /bin/chmod +x "$INSTALL_DIR/llama-server"

    # Determine the required dylibs via otool -L on the server binary.
    # Only @rpath references need to be shipped — system frameworks come from the OS.
    local otool_out
    otool_out=$(/usr/bin/otool -L "$src_dir/llama-server")
    local required_dylibs
    required_dylibs=$(echo "$otool_out" | /usr/bin/grep -oE '@rpath/[^ ]+\.dylib' | /usr/bin/sed 's|@rpath/||' | /usr/bin/sort -u)

    if [ -z "$required_dylibs" ]; then
        echo "${RED}otool -L found no @rpath dylib dependencies — archive may be malformed${RESET}"
        /bin/rm -rf "$WORK_DIR"
        exit 1
    fi

    # install_dylib copies a dylib by name from src_dir into INSTALL_DIR.
    # If the file is a symlink, it also recursively installs the target so the
    # chain (e.g. libfoo.0.dylib -> libfoo.0.9.11.dylib) is fully intact.
    install_dylib() {
        local name="$1"
        local src="$src_dir/$name"
        local dest="$INSTALL_DIR/$name"

        if [ ! -e "$src" ]; then
            echo "    ${RED}MISSING in archive: $name${RESET}"
            return 1
        fi

        # Skip if already installed (handles diamond-shaped symlink graphs)
        if [ -e "$dest" ]; then
            return 0
        fi

        echo "    $name"
        /bin/cp -P "$src" "$dest"

        # If it was a symlink, also install the file it points to
        local target
        target=$(/usr/bin/readlink "$src" 2>/dev/null || echo "")
        if [ -n "$target" ]; then
            install_dylib "$target"
        fi
    }

    echo "  dylibs (from otool -L, with symlink targets):"
    local install_ok="yes"
    local dylib_name
    while IFS= read -r dylib_name; do
        [ -z "$dylib_name" ] && continue
        install_dylib "$dylib_name"
        local dylib_result=$?
        if [ "$dylib_result" != 0 ]; then
            install_ok="no"
        fi
    done <<EOF
$required_dylibs
EOF

    if [ "$install_ok" != "yes" ]; then
        /bin/rm -rf "$WORK_DIR"
        exit 1
    fi

    # Install LICENSE files
    echo "  LICENSE files:"
    local license_path
    for license_path in "$src_dir"/LICENSE*; do
        [ -f "$license_path" ] || continue
        local license_name
        license_name=$(/usr/bin/basename "$license_path")
        echo "    $license_name"
        /bin/cp "$license_path" "$INSTALL_DIR/$license_name"
    done

    echo
}

codesign_app() {
    echo "==== Codesigning app bundle ===="
    echo

    local codesign_script="$SCRIPT_DIR/codesign_applet.sh"
    if [ ! -f "$codesign_script" ]; then
        echo "${RED}codesign_applet.sh not found at $codesign_script${RESET}"
        exit 1
    fi

    "$codesign_script" "$APP_BUNDLE" "$SIGNING_IDENTITY"
    local result=$?
    if [ "$result" != 0 ]; then
        echo "${RED}Codesigning failed (exit $result)${RESET}"
        exit 1
    fi
    echo
}

verify_install() {
    echo "==== Verifying installation ===="
    echo

    local server_path="$INSTALL_DIR/llama-server"

    if [ ! -f "$server_path" ]; then
        echo "${RED}llama-server missing after install${RESET}"
        exit 1
    fi

    local file_info
    file_info=$(/usr/bin/file "$server_path")
    echo "  Binary: $file_info"

    local version_out
    version_out=$("$server_path" --version 2>&1 | head -1 || echo "")
    if [ -z "$version_out" ]; then
        echo "${RED}llama-server --version produced no output — dylib issue?${RESET}"
        exit 1
    fi
    echo "  Version: $version_out"

    # Smoke-test: run --help to confirm all dylibs load and the binary is functional.
    # Output is discarded; only the exit code matters.
    echo "  Running --help smoke test..."
    "$server_path" --help >/dev/null 2>&1
    local help_result=$?
    if [ "$help_result" != 0 ]; then
        echo "${RED}llama-server --help exited with code $help_result — possible dylib load failure${RESET}"
        exit 1
    fi

    echo "  ${GREEN}OK${RESET}"
    echo
}

# verify_welcome_dom checks that the welcome-screen from_html() template in bundle.js
# has the exact DOM child order that Svelte 5's compiled traversal expects.
# The compiled code does: sibling(child(root_div), 2) to reach <p>.
# Any whitespace text-node between </h1> and <img>, or between <img/> and <p>,
# shifts that offset and causes a blank screen.  See WebUI/WebUI.txt for full details.
verify_welcome_dom() {
    local patched_file="$1"
    local ok="yes"

    /usr/bin/grep -qF 'AIChat</h1><img src="./AIChat.png"' "$patched_file" || {
        echo "    ${RED}DOM BROKEN: text-node after </h1> shifts Svelte sibling offset (blank screen)${RESET}"
        ok="no"
    }
    /usr/bin/grep -qF 'height:128px;order:1"/><p ' "$patched_file" || {
        echo "    ${RED}DOM BROKEN: text-node after <img/> shifts Svelte sibling offset (blank screen)${RESET}"
        ok="no"
    }

    if [ "$ok" = "yes" ]; then
        echo "    ${GREEN}DOM structure OK: h1 → img → p (no text-nodes between them)${RESET}"
        return 0
    fi
    return 1
}

# verify_webui_patches checks that each replacement string from a sed command file
# is present in the patched output file.  Returns 0 if all found, 1 if any missing.
# Replacement strings are extracted from field 3 of each s|pattern|replacement|flags
# line in the sed file.  Trailing backslashes are stripped before matching — they
# appear in JS patterns as line-continuation anchors but are not useful for verification.
verify_webui_patches() {
    local sed_file="$1"
    local patched_file="$2"
    local ok="yes"
    local line

    while IFS= read -r line; do
        # Strip sed comments and blank lines before extracting the replacement.
        # A comment (first non-blank char '#') or blank line carries no '|', and
        # `cut -d'|' -f3` echoes a delimiter-less line back unchanged — which
        # would make the whole comment look like a replacement and report a bogus
        # MISSING. Skipping comments (rather than allowlisting an `s|` prefix)
        # leaves every real substitution line verifiable, including future ones.
        local stripped="${line#"${line%%[![:space:]]*}"}"   # drop leading blanks
        case "$stripped" in
            ''|'#'*) continue ;;
        esac
        local replacement
        replacement=$(printf '%s' "$line" | /usr/bin/cut -d'|' -f3)
        [ -z "$replacement" ] && continue
        # Strip trailing backslashes
        while [ "${replacement%\\}" != "$replacement" ]; do
            replacement="${replacement%\\}"
        done
        # Strip sed backreferences (\1, \2, …) — they are not literal strings
        replacement=$(printf '%s' "$replacement" | /usr/bin/sed 's/\\[0-9]//g')
        [ -z "$replacement" ] && continue
        /usr/bin/grep -qFe "$replacement" "$patched_file" || {
            echo "    ${RED}MISSING: $replacement${RESET}"
            ok="no"
        }
    done < "$sed_file"

    if [ "$ok" = "yes" ]; then
        echo "    ${GREEN}All patches verified${RESET}"
        return 0
    fi
    return 1
}

update_webui() {
    echo "==== Updating WebUI ===="
    echo

    if [ ! -d "$WEBUI_DIR" ]; then
        echo "  ${RED}WebUI directory not found: $WEBUI_DIR${RESET}"
        return 1
    fi

    local webui_work="$WORK_DIR/webui"
    /bin/mkdir -p "$webui_work"

    # Resolve which HF version to use. The UI files are published to the HF
    # bucket by a separate CI job that may lag behind or break (e.g. when the
    # repo renames internal paths). Probe the version-specific tag first; if
    # absent, fall back to the "latest" pointer which always tracks the last
    # successful publish.
    local hf_version="$VERSION"
    local probe_code
    probe_code=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" --max-time 10 --max-redirs 5 \
        "https://huggingface.co/buckets/ggml-org/llama-ui/resolve/${VERSION}/checksums.txt" 2>/dev/null)
    if [ "$probe_code" != "200" ] && [ "$probe_code" != "302" ]; then
        echo "  ${RED}WebUI for ${VERSION} not in HF bucket (HTTP ${probe_code}) — falling back to latest${RESET}"
        hf_version="latest"
    fi

    local base_url="https://huggingface.co/buckets/ggml-org/llama-ui/resolve/${hf_version}"

    # Download the three WebUI files
    echo "  Downloading WebUI files (${hf_version})..."
    local download_ok="yes"
    local f
    for f in index.html bundle.js bundle.css; do
        printf "    %-12s" "$f"
        /usr/bin/curl -s --fail --show-error --max-time 120 -L \
            "${base_url}/${f}" -o "${webui_work}/${f}" 2>&1
        local curl_result=$?
        if [ "$curl_result" != 0 ]; then
            echo "  ${RED}FAILED (curl exit $curl_result)${RESET}"
            download_ok="no"
        else
            /usr/bin/stat -f "%z bytes" "${webui_work}/${f}"
        fi
    done

    if [ "$download_ok" != "yes" ]; then
        echo "  ${RED}WebUI download failed — skipping WebUI update${RESET}"
        WEBUI_STATUS="download-failed"
        return 1
    fi

    # Remove any previous originals zip and save a fresh one for the new version.
    local old_zip
    for old_zip in "${WEBUI_SED_DIR}"/WebUI-*.zip; do
        [ -f "$old_zip" ] || continue
        /bin/rm -f "$old_zip"
        echo "  Removed old originals: $(/usr/bin/basename "$old_zip")"
    done
    local orig_zip="${WEBUI_SED_DIR}/WebUI-${VERSION}.zip"
    echo "  Saving originals to $(basename "$orig_zip")..."
    /usr/bin/zip -j "$orig_zip" \
        "${webui_work}/index.html" \
        "${webui_work}/bundle.js" \
        "${webui_work}/bundle.css" > /dev/null
    local zip_result=$?
    if [ "$zip_result" != 0 ]; then
        echo "  ${RED}zip failed (exit $zip_result) — originals not saved${RESET}"
    else
        /usr/bin/stat -f "    %z bytes" "$orig_zip"
    fi
    echo

    # Apply CSS patches (colors)
    local css_sed="$WEBUI_SED_DIR/webui-bundle-css.sed"
    local css_ok="yes"
    if [ -f "$css_sed" ]; then
        echo "  Patching bundle.css..."
        /usr/bin/sed -E -f "$css_sed" "${webui_work}/bundle.css" > "${webui_work}/bundle.css.patched"
        /bin/mv "${webui_work}/bundle.css.patched" "${webui_work}/bundle.css"
        verify_webui_patches "$css_sed" "${webui_work}/bundle.css"
        css_ok=$( [ $? = 0 ] && echo "yes" || echo "no" )
    else
        echo "  No CSS sed file at $css_sed — skipping CSS patches"
    fi

    # Apply JS patches (branding + logo)
    local js_sed="$WEBUI_SED_DIR/webui-bundle-js.sed"
    local js_ok="yes"
    if [ -f "$js_sed" ]; then
        echo "  Patching bundle.js..."
        /usr/bin/sed -E -f "$js_sed" "${webui_work}/bundle.js" > "${webui_work}/bundle.js.patched"
        /bin/mv "${webui_work}/bundle.js.patched" "${webui_work}/bundle.js"
        verify_webui_patches "$js_sed" "${webui_work}/bundle.js"
        local patches_result=$?
        echo "  Verifying welcome screen DOM structure..."
        verify_welcome_dom "${webui_work}/bundle.js"
        local dom_result=$?
        js_ok=$( [ "$patches_result" = 0 ] && [ "$dom_result" = 0 ] && echo "yes" || echo "no" )
    else
        echo "  No JS sed file at $js_sed — skipping JS patches"
    fi

    if [ "$css_ok" != "yes" ] || [ "$js_ok" != "yes" ]; then
        echo
        echo "  ${RED}One or more patches failed — WebUI HTML structure may have changed.${RESET}"
        echo "  ${RED}Review webui-bundle-css.sed / webui-bundle-js.sed and update patterns.${RESET}"
        echo "  Installing unpatched files so the UI still works."
        WEBUI_STATUS="patched-with-warnings"
    else
        WEBUI_STATUS="ok"
    fi

    # Inject ?v=VERSION into bundle.css and bundle.js references in index.html.
    # WKWebView caches by URL; changing the query string forces it to fetch the
    # updated files instead of serving stale cached content from a prior version.
    echo "  Patching index.html (cache-busting + mcp-seed.js injection)..."
    /usr/bin/sed -E \
        -e "s|\./bundle\.css\"|\./bundle.css?v=${VERSION}\"|g" \
        -e "s|\./bundle\.js\"|\./bundle.js?v=${VERSION}\"|g" \
        -e "s|<div style=\"display: contents\">|<script src=\"./mcp-seed.js?v=${VERSION}\"></script>\n\t\t<div style=\"display: contents\">|" \
        "${webui_work}/index.html" > "${webui_work}/index.html.versioned"
    /bin/mv "${webui_work}/index.html.versioned" "${webui_work}/index.html"

    # Install index.html, bundle.js, bundle.css — leave custom files untouched
    echo "  Installing to $WEBUI_DIR..."
    for f in index.html bundle.js bundle.css; do
        /bin/cp "${webui_work}/${f}" "${WEBUI_DIR}/${f}"
        echo "    $f"
    done

    # Write version file so aichat.init.sh can append ?v=VERSION to the dialog URL,
    # ensuring WKWebView re-fetches index.html instead of serving a cached copy.
    printf '%s' "$VERSION" > "${WEBUI_DIR}/version"
    echo "    version ($VERSION)"
    echo
}

cleanup() {
    echo "==== Cleaning up ===="
    /bin/rm -rf "$WORK_DIR"
    echo "  Removed work directory: $WORK_DIR"
    echo
}

print_summary() {
    echo "==== Update complete ===="
    echo
    echo "  llama.cpp $VERSION ($ARCH) installed to:"
    echo "  $INSTALL_DIR"
    echo
    echo "  WebUI ($VERSION):"
    case "$WEBUI_STATUS" in
        ok)
            echo "  ${GREEN}All patches applied successfully${RESET}"
            echo "  $WEBUI_DIR"
            ;;
        patched-with-warnings)
            echo "  ${RED}Installed with patch warnings — review sed files${RESET}"
            echo "  $WEBUI_DIR"
            ;;
        download-failed)
            echo "  ${RED}Download failed — WebUI not updated${RESET}"
            ;;
        *)
            echo "  Not updated"
            ;;
    esac
    echo
}

main() {
    prepare
    download_release
    extract_and_install
    update_webui
    codesign_app
    verify_install
    cleanup
    print_summary
}

main
