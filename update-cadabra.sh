#!/bin/bash
# update-cadabra.sh
# Updates the git-excluded runtime engines inside Cadabra.app (the native-chat V2,
# rebranded from V2/AIChat.app):
#   1. llama.cpp  - llama-server + its dylibs, from a GitHub release (the GGUF engine)
#   2. mlx-agent  - built from source with xcodebuild, Release (the ACP agent + MLX engine)
#   3. pdfutil    - built from source with ./build.sh (the PDF MCP server)
#   4. replay     - built from source with xcodebuild (the local files/shell MCP server)
#   5. packages   - the Python MCP servers, pip-installed into Contents/Library/Packages
# then codesigns the bundle and verifies the engines actually launch.
#
# Stage 5 absorbs what update-mcp-servers.py did as a separate manual step. Folding it in
# means one codesign pass instead of two (that script signed, then this one signed again)
# and it means the Python servers cannot silently rot: generate_mcp_configs.py now PROBES
# every server at launch and drops any that fails to answer, so a stale or missing
# Packages dir no longer shows up as a broken server - it shows up as no server at all.
#
# Relationship to ./update-llama-cpp.sh: that script serves the V1 app (and Enoch), which
# renders its UI from llama.cpp's WebUI and therefore has to download and sed-patch
# bundle.js/bundle.css/index.html on every update. Cadabra has NO Contents/Resources/WebUI -
# the chat UI is native (ActionUI Chat element over ACP) - so ALL of that machinery is dead
# weight here and is deliberately absent rather than skipped by a flag. Cadabra also embeds
# mlx-agent, which V1 does not, so the two scripts do not converge.
#
# arm64 only for the agent: mlx-agent is Metal/MLX and does not build for x86_64. The
# llama.cpp half still accepts --arch=x86_64 (pass --skip-agent with it). pdfutil and
# replay build for either arch, so both are deployed on the arm64 and x86_64 paths.
#
# The bundle is Cadabra.app next to this script - NOT auto-globbed: the repo root also
# holds the V1 AIChat.app, which this script must never touch.

set -uo pipefail

# Applies to every invocation of the bundle's embedded interpreter in this script - the
# pip --version probe, pip install itself, and the post-codesign import checks.
#
# The app itself does NOT need this and must not set it: the OMC applet runtime exports
# PYTHONPYCACHEPREFIX (Abracode's setPythonPycachePrefixIfEmbedded), which redirects
# bytecode for the embedded interpreter out of the bundle entirely. Scripts INSIDE
# Contents/Resources/Scripts therefore run with caching already handled.
#
# Maintenance scripts like this one run outside that environment, so they get no such
# redirect and would write .pyc straight into Contents/Library. Before signing that
# silently bloats the sealed payload (40 stdlib cache directories, just from running
# `pip --version`); after signing it invalidates the seal and `codesign --verify` reports
# "a sealed resource is missing or invalid". pip's --no-compile does not help: that
# governs the packages being installed, not the interpreter's own stdlib caching.
export PYTHONDONTWRITEBYTECODE=1

RED=$(printf '\033[91m'); GREEN=$(printf '\033[92m')
YELLOW=$(printf '\033[93m'); RESET=$(printf '\033[0m')

VERSION="auto"
ARCH="auto"
SIGNING_IDENTITY="-"
AGENT_REPO="${AGENT_REPO:-}"
PDFUTIL_REPO="${PDFUTIL_REPO:-}"
REPLAY_REPO="${REPLAY_REPO:-}"
DO_LLAMA="yes"
DO_AGENT="yes"
DO_PDFUTIL="yes"
DO_REPLAY="yes"
DO_PACKAGES="yes"
DO_AGENT_PACKAGE_UPDATE="yes"
DO_BUILD="yes"
DO_CODESIGN="yes"
CLEAN_PACKAGES="no"

# The Python MCP servers. Two lists because the name pip installs is not the name that
# gets imported, and they must stay index-aligned.
#
# MCP_MODULES holds the module generate_mcp_configs.py actually LAUNCHES with
# `python3 -m`, which is not always the top-level package - the search server is started
# as duckduckgo_mcp_server.server. Verifying the package instead would be near-worthless:
# its __init__.py is 22 bytes of __version__ and imports nothing, so a broken dependency
# tree would pass. Importing the launched module pulls the real dependency graph in, and
# is safe to do because that module guards its entry point with `if __name__ ==
# "__main__"`, so nothing starts serving.
#
# Kept in sync with generate_mcp_configs.py - adding one here without teaching that
# script about it installs dead weight, and the reverse leaves a configured server with
# nothing to import.
MCP_PACKAGES=("mcp-server-time" "duckduckgo-mcp-server")
MCP_MODULES=("mcp_server_time" "duckduckgo_mcp_server.server")
[ "${#MCP_PACKAGES[@]}" -eq "${#MCP_MODULES[@]}" ] \
    || { echo "MCP_PACKAGES and MCP_MODULES must be index-aligned" >&2; exit 1; }
# bash 3.2 (which is what /bin/bash is on macOS) treats "${empty[@]}" as an unbound
# variable under `set -u`. The list is meant to be edited, so refuse it explicitly
# instead of dying with a confusing error three functions later.
[ "${#MCP_PACKAGES[@]}" -gt 0 ] \
    || { echo "MCP_PACKAGES is empty; use --skip-packages instead" >&2; exit 1; }

# Set by prepare()
ASSET_NAME=""; DOWNLOAD_URL=""; WORK_DIR=""; TARBALL=""; EXTRACT_DIR=""
AGENT_BUILD_DIR=""
AGENT_RESOLVED=""
# Set by update_agent_packages while mlx-agent's Package.resolved is moved aside. Globals
# rather than locals because the INT/TERM trap has to see them (see restore_agent_pins).
AGENT_PINS_DIR=""
AGENT_PINS_BACKUP=""
PDFUTIL_BUILD_BIN=""
REPLAY_BUILD_BIN=""
LLAMA_STATUS="skipped"; AGENT_STATUS="skipped"; PDFUTIL_STATUS="skipped"
REPLAY_STATUS="skipped"; PACKAGES_STATUS="skipped"

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" >/dev/null 2>&1 && pwd)"

fail() { echo "${RED}$*${RESET}" >&2; cleanup; exit 1; }

# A dependency repo is missing: offer to git-clone it into the sibling location and continue.
# Interactive runs only - without a TTY (CI, piped stdin) this declines silently and the
# caller's fail() fires with the manual instructions. $1 = repo URL, $2 = destination dir.
offer_clone() {
    [ -t 0 ] || return 1
    printf "%s  %s not found. Clone %s\n  into %s now? [y/N] %s" \
        "$YELLOW" "$(/usr/bin/basename "$2")" "$1" "$2" "$RESET"
    local _ans
    IFS= read -r _ans
    case "$_ans" in [yY]|[yY][eE][sS]) ;; *) return 1 ;; esac
    /usr/bin/git clone "$1" "$2"
}

# Pinned to Cadabra.app: the repo root also holds the V1 AIChat.app, so a *.app glob
# would grab the wrong bundle.
APP_BUNDLE="$SCRIPT_DIR/Cadabra.app"
[ -d "$APP_BUNDLE" ] || { echo "${RED}No Cadabra.app found in $SCRIPT_DIR${RESET}"; exit 1; }

INSTALL_DIR="$APP_BUNDLE/Contents/Support/Llama.cpp"
MLX_DIR="$APP_BUNDLE/Contents/Support/MLX"
PDFUTIL_BIN="$APP_BUNDLE/Contents/Support/pdfutil"
REPLAY_BIN="$APP_BUNDLE/Contents/Support/replay"

# The Python tier lives under Contents/Library, not Contents/Support: Support holds the
# native engines this script builds, Library holds the embedded interpreter and the
# packages tier.
#
# BUNDLED_PYTHON is installed by AppletBuilder, not by this script - `appletbuilder
# create --python` for a new applet, `appletbuilder build --update-python` to refresh an
# existing one. Stage 5 therefore checks for it and points at that tool rather than
# falling back to the system python, whose site-packages would not travel with the app.
#
# Packages go in Contents/Library/Packages and never in the runtime's own site-packages:
# AppletBuilder replaces Contents/Library/Python wholesale when it updates the runtime,
# which would wipe anything installed inside it, whereas Packages/ survives. OMC also
# prepends Packages/ to PYTHONPATH for every handler, so it is the supported location.
PYTHON_DIR="$APP_BUNDLE/Contents/Library/Python"
BUNDLED_PYTHON="$PYTHON_DIR/bin/python3"
PACKAGES_DIR="$APP_BUNDLE/Contents/Library/Packages"
# Where --clean-packages builds the new tree before swapping it in. Kept beside the live
# directory so the swap is a rename rather than a 44 MB copy across filesystems, and
# swept by codesign_app so an interrupted run can never seal a duplicate into the bundle.
PACKAGES_STAGING="$APP_BUNDLE/Contents/Library/Packages.staging"
# Written into the staging dir only once the install AND the strip have both succeeded.
# Its presence is the sole signal that a staging tree is complete and safe to swap in.
STAGING_SENTINEL=".install-complete"

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Updates the runtime engines in $(/usr/bin/basename "$APP_BUNDLE"):
  llama.cpp -> Contents/Support/Llama.cpp/   (downloaded release, no WebUI - Cadabra is native)
  mlx-agent -> Contents/Support/MLX/         (built from source, xcodebuild -configuration Release)
  pdfutil   -> Contents/Support/pdfutil      (built from source with ./build.sh)
  replay    -> Contents/Support/replay       (built from source with xcodebuild)
  packages  -> Contents/Library/Packages     (pip install with the bundle's own python3)

Options:
  --version=VERSION   llama.cpp build tag (e.g. b8797, default: auto-detect latest)
  --arch=ARCH         arm64 or x86_64 (default: host). x86_64 requires --skip-agent.
  --identity=CERT     codesign identity (default: - for ad-hoc)
  --agent-repo=PATH   mlx-agent repo (default: ../mlx-agent sibling checkout)
  --pdfutil-repo=PATH pdfutil repo (default: ../pdfutil sibling checkout)
  --replay-repo=PATH  replay repo (default: ../replay sibling checkout)
  --skip-llama        leave llama.cpp untouched
  --skip-agent        leave mlx-agent untouched
  --skip-pdfutil      leave pdfutil untouched
  --skip-replay       leave replay untouched
  --skip-packages     leave the Python MCP packages untouched
  --clean-packages    wipe Contents/Library/Packages before installing (drops orphans)
  --skip-agent-package-update
                      build mlx-agent against its committed Package.resolved instead of
                      re-resolving its SPM dependencies to the newest allowed versions
  --skip-build        deploy the existing build products without rebuilding
  --skip-codesign     do not codesign
  --help              show this message

Examples:
  ./update-cadabra.sh
  ./update-cadabra.sh --version=b8797
  ./update-cadabra.sh --skip-llama                 # rebuild + redeploy the agent + MCP servers
  ./update-cadabra.sh --skip-agent                 # refresh llama.cpp + the MCP servers
  ./update-cadabra.sh --skip-llama --skip-agent    # rebuild + redeploy just pdfutil + replay
  ./update-cadabra.sh --skip-llama --skip-agent --skip-pdfutil   # just replay + packages
  ./update-cadabra.sh --skip-llama --skip-agent --skip-pdfutil --skip-replay   # just packages
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --help) show_help ;;
        --version=*) VERSION="${1#*=}" ;;
        --version) shift; VERSION="${1:-}" ;;
        --arch=*) ARCH="${1#*=}" ;;
        --arch) shift; ARCH="${1:-}" ;;
        --identity=*) SIGNING_IDENTITY="${1#*=}" ;;
        --identity) shift; SIGNING_IDENTITY="${1:-}" ;;
        --agent-repo=*) AGENT_REPO="${1#*=}" ;;
        --agent-repo) shift; AGENT_REPO="${1:-}" ;;
        --pdfutil-repo=*) PDFUTIL_REPO="${1#*=}" ;;
        --pdfutil-repo) shift; PDFUTIL_REPO="${1:-}" ;;
        --replay-repo=*) REPLAY_REPO="${1#*=}" ;;
        --replay-repo) shift; REPLAY_REPO="${1:-}" ;;
        --skip-llama) DO_LLAMA="no" ;;
        --skip-agent) DO_AGENT="no" ;;
        --skip-pdfutil) DO_PDFUTIL="no" ;;
        --skip-replay) DO_REPLAY="no" ;;
        --skip-packages) DO_PACKAGES="no" ;;
        --clean-packages) CLEAN_PACKAGES="yes" ;;
        --skip-agent-package-update) DO_AGENT_PACKAGE_UPDATE="no" ;;
        --skip-build) DO_BUILD="no" ;;
        --skip-codesign) DO_CODESIGN="no" ;;
        *) echo "Unknown option: $1"; show_help ;;
    esac
    shift
done

# Refuse contradictory combinations rather than silently honouring one of them: with
# --skip-build the packages stage reuses what is deployed and never runs pip, so
# --clean-packages would be quietly discarded and the user would be told "reusing
# existing packages" after asking for a wipe-and-reinstall.
if [ "$CLEAN_PACKAGES" = "yes" ]; then
    [ "$DO_BUILD" = "yes" ] \
        || { echo "${RED}--clean-packages cannot be combined with --skip-build: a clean install has to run pip.${RESET}" >&2; exit 1; }
    [ "$DO_PACKAGES" = "yes" ] \
        || { echo "${RED}--clean-packages cannot be combined with --skip-packages.${RESET}" >&2; exit 1; }
fi

cleanup() {
    # Only ever remove the mktemp dir this run created; never an inherited/empty value.
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        /bin/rm -rf "$WORK_DIR"
    fi
    # The Package.resolved backup + resolve log. Removed last, and only ever after any
    # restore has already run (the trap restores before calling cleanup).
    if [ -n "$AGENT_PINS_DIR" ] && [ -d "$AGENT_PINS_DIR" ]; then
        /bin/rm -rf "$AGENT_PINS_DIR"
    fi
}

detect_latest_version() {
    echo "  Detecting latest llama.cpp release..."
    # Strategy 1: follow the /releases/latest redirect and read the tag out of the URL.
    local redirect_url tag
    redirect_url=$(/usr/bin/curl -s --head -w '%{redirect_url}' --max-time 10 \
        "https://github.com/ggml-org/llama.cpp/releases/latest" 2>/dev/null || echo "")
    tag=$(echo "$redirect_url" | /usr/bin/grep -oE '/tag/(b[0-9]+)$' | /usr/bin/grep -oE 'b[0-9]+')
    if [ -n "$tag" ]; then VERSION="$tag"; echo "    from redirect: $VERSION"; return 0; fi

    # Strategy 2: the releases API.
    local api_json
    api_json=$(/usr/bin/curl -s --fail --max-time 10 \
        "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" 2>/dev/null || echo "")
    tag=$(echo "$api_json" | /usr/bin/grep -oE '"tag_name":[[:space:]]*"b[0-9]+"' | /usr/bin/grep -oE 'b[0-9]+')
    if [ -n "$tag" ]; then VERSION="$tag"; echo "    from API: $VERSION"; return 0; fi

    fail "Version detection failed. Specify --version=bNNNN explicitly."
}

# ── 0. Prepare ────────────────────────────────────────────────────────────────
prepare() {
    local _cand
    echo
    echo "==== Updating $(/usr/bin/basename "$APP_BUNDLE") ===="
    echo

    [ "$ARCH" = "auto" ] && ARCH=$(/usr/bin/uname -m)
    case "$ARCH" in
        arm64) ;;
        x86_64)
            [ "$DO_AGENT" = "yes" ] && fail "mlx-agent is arm64-only (Metal/MLX). Re-run with --skip-agent for an x86_64 llama.cpp-only update."
            ;;
        *) fail "Invalid --arch: $ARCH (must be arm64 or x86_64)" ;;
    esac

    if [ "$DO_LLAMA" = "yes" ]; then
        [ "$VERSION" = "auto" ] && detect_latest_version
        case "$VERSION" in
            b[0-9]*) ;;
            *) fail "Invalid --version: $VERSION (expected format: bNNNN)" ;;
        esac
        if [ "$ARCH" = "arm64" ]; then
            ASSET_NAME="llama-${VERSION}-bin-macos-arm64.tar.gz"
        else
            ASSET_NAME="llama-${VERSION}-bin-macos-x64.tar.gz"
        fi
        DOWNLOAD_URL="https://github.com/ggml-org/llama.cpp/releases/download/${VERSION}/${ASSET_NAME}"
        WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/update-aichat.XXXXXX")" || fail "mktemp failed"
        TARBALL="$WORK_DIR/$ASSET_NAME"
        EXTRACT_DIR="$WORK_DIR/extracted"
    fi

    if [ "$DO_AGENT" = "yes" ]; then
        # Locate the mlx-agent repo (github.com/abra-code/mlx-agent, Apache 2.0) by its Xcode
        # PROJECT: the repo has no Package.swift since it moved to an XcodeGen-generated
        # project (Metal shaders force xcodebuild anyway). When missing, offer to clone it
        # into the sibling location and continue.
        # ../mlx-agent is the current sibling layout (this script sits at the repo root
        # since the Cadabra rebrand); ../../mlx-agent is kept as a fallback for checkouts
        # still laid out the pre-rebrand way, when this script lived one level deeper.
        if [ -z "$AGENT_REPO" ]; then
            for _cand in "$SCRIPT_DIR/../mlx-agent" "$SCRIPT_DIR/../../mlx-agent"; do
                [ -d "$_cand/mlx-agent.xcodeproj" ] && { AGENT_REPO="$(cd "$_cand" && pwd)"; break; }
            done
        fi
        if [ -z "$AGENT_REPO" ]; then
            offer_clone "https://github.com/abra-code/mlx-agent" "$(cd "$SCRIPT_DIR/.." && pwd)/mlx-agent" \
                && [ -d "$SCRIPT_DIR/../mlx-agent/mlx-agent.xcodeproj" ] \
                && AGENT_REPO="$(cd "$SCRIPT_DIR/../mlx-agent" && pwd)"
        fi
        [ -n "$AGENT_REPO" ] && [ -d "$AGENT_REPO/mlx-agent.xcodeproj" ] \
            || fail "mlx-agent repo not found (looked for mlx-agent.xcodeproj); clone github.com/abra-code/mlx-agent or pass --agent-repo=PATH."
        # Release, not Debug: this is the binary users run, so it is built -O/wholemodule
        # rather than -Onone. The configuration is passed to xcodebuild explicitly (see
        # update_agent) instead of relying on the scheme, which keeps run/test on Debug for
        # development - so this path must match that flag, not the scheme.
        AGENT_BUILD_DIR="$AGENT_REPO/build/Build/Products/Release"
        # The SPM pins for the Xcode project live here (there is no Package.swift in that
        # repo - see the header of mlx-agent/project.yml for why).
        AGENT_RESOLVED="$AGENT_REPO/mlx-agent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    fi

    if [ "$DO_PDFUTIL" = "yes" ]; then
        # Locate the pdfutil repo (github.com/abra-code/pdfutil, Apache 2.0) by its
        # build.sh: it is a plain-swiftc build (no Xcode project, no Package.swift), so
        # build.sh is the identifying marker. When missing, offer to clone it into the
        # sibling location and continue.
        # Same sibling-then-legacy candidate order as mlx-agent above.
        if [ -z "$PDFUTIL_REPO" ]; then
            for _cand in "$SCRIPT_DIR/../pdfutil" "$SCRIPT_DIR/../../pdfutil"; do
                [ -f "$_cand/build.sh" ] && { PDFUTIL_REPO="$(cd "$_cand" && pwd)"; break; }
            done
        fi
        if [ -z "$PDFUTIL_REPO" ]; then
            offer_clone "https://github.com/abra-code/pdfutil" "$(cd "$SCRIPT_DIR/.." && pwd)/pdfutil" \
                && [ -f "$SCRIPT_DIR/../pdfutil/build.sh" ] \
                && PDFUTIL_REPO="$(cd "$SCRIPT_DIR/../pdfutil" && pwd)"
        fi
        [ -n "$PDFUTIL_REPO" ] && [ -f "$PDFUTIL_REPO/build.sh" ] \
            || fail "pdfutil repo not found (looked for build.sh); clone github.com/abra-code/pdfutil or pass --pdfutil-repo=PATH."
        # build.sh always writes the (single- or universal-arch) binary here.
        PDFUTIL_BUILD_BIN="$PDFUTIL_REPO/build/pdfutil"
    fi

    if [ "$DO_REPLAY" = "yes" ]; then
        # Locate the replay repo (github.com/abra-code/replay, Apache 2.0) by its Xcode
        # PROJECT: the repo does ship a Package.swift, but the xcodeproj is what this
        # script builds (see update_replay), so it is the marker that matters. Same
        # sibling-then-legacy candidate order as mlx-agent and pdfutil above.
        if [ -z "$REPLAY_REPO" ]; then
            for _cand in "$SCRIPT_DIR/../replay" "$SCRIPT_DIR/../../replay"; do
                [ -d "$_cand/replay.xcodeproj" ] && { REPLAY_REPO="$(cd "$_cand" && pwd)"; break; }
            done
        fi
        if [ -z "$REPLAY_REPO" ]; then
            offer_clone "https://github.com/abra-code/replay" "$(cd "$SCRIPT_DIR/.." && pwd)/replay" \
                && [ -d "$SCRIPT_DIR/../replay/replay.xcodeproj" ] \
                && REPLAY_REPO="$(cd "$SCRIPT_DIR/../replay" && pwd)"
        fi
        [ -n "$REPLAY_REPO" ] && [ -d "$REPLAY_REPO/replay.xcodeproj" ] \
            || fail "replay repo not found (looked for replay.xcodeproj); clone github.com/abra-code/replay or pass --replay-repo=PATH."
        # The project keeps SYMROOT inside the repo, so Release products land here.
        REPLAY_BUILD_BIN="$REPLAY_REPO/build/Release/replay"
    fi

    if [ "$DO_PACKAGES" = "yes" ]; then
        # Fail here rather than inside the stage: this is the one input the repo cannot
        # produce for you, so saying so before any building starts saves a full llama.cpp
        # download and two Xcode builds.
        [ -x "$BUNDLED_PYTHON" ] \
            || fail "No bundled interpreter at $BUNDLED_PYTHON. Install it with 'appletbuilder build \"$APP_BUNDLE\" --update-python' (AppletBuilder.app/Contents/Resources/Agents/appletbuilder), or re-run with --skip-packages."
        "$BUNDLED_PYTHON" -m pip --version >/dev/null 2>&1 \
            || fail "The bundled interpreter has no pip module; cannot install MCP packages. Re-run with --skip-packages."
    fi

    # Resolve a staging tree left by an interrupted --clean-packages run. Deliberately
    # OUTSIDE the DO_PACKAGES check: codesign_app runs regardless of --skip-packages, and
    # a stranded staging dir would otherwise be sealed into the bundle as a ~44 MB
    # duplicate of the whole package tree, .so files individually signed and all.
    #
    # The sentinel decides it, with no guessing. Present means pip and the strip both
    # finished and only the swap was missed, so the tree is complete and better than what
    # is live - swap it in. Absent means the install died partway, so it is junk and the
    # live packages were never touched - delete it. This is the payoff of staging over
    # rename-aside: with a backup there is no way to tell a complete copy from a
    # half-removed one, and the wrong guess destroys the good tree.
    if [ -d "$PACKAGES_STAGING" ]; then
        if [ -f "$PACKAGES_STAGING/$STAGING_SENTINEL" ]; then
            echo "  ${YELLOW}Completing an interrupted --clean-packages run (staged tree is complete)${RESET}"
            swap_in_staged_packages
        else
            echo "  ${YELLOW}Discarding an incomplete staged package tree from an interrupted run${RESET}"
            /bin/rm -rf "${PACKAGES_STAGING:?}" || fail "Could not remove $PACKAGES_STAGING"
        fi
    fi

    echo "  App bundle : $APP_BUNDLE"
    echo "  Arch       : $ARCH"
    echo "  llama.cpp  : $([ "$DO_LLAMA" = yes ] && echo "$VERSION" || echo "<skipped>")"
    # Spells out the SPM re-resolve: it is on by default, it touches a tracked file in a
    # DIFFERENT repo, and it goes to the network for minutes - the most surprising thing this
    # script does by default should be visible before it runs, not only in hindsight.
    echo "  mlx-agent  : $([ "$DO_AGENT" = yes ] && echo "${AGENT_REPO}$([ "$DO_BUILD" = no ] && echo " (no rebuild)")$([ "$DO_BUILD" = yes ] && [ "$DO_AGENT_PACKAGE_UPDATE" = yes ] && echo " (+ SPM re-resolve)")" || echo "<skipped>")"
    echo "  pdfutil    : $([ "$DO_PDFUTIL" = yes ] && echo "${PDFUTIL_REPO}$([ "$DO_BUILD" = no ] && echo " (no rebuild)")" || echo "<skipped>")"
    echo "  replay     : $([ "$DO_REPLAY" = yes ] && echo "${REPLAY_REPO}$([ "$DO_BUILD" = no ] && echo " (no rebuild)")" || echo "<skipped>")"
    echo "  packages   : $([ "$DO_PACKAGES" = yes ] && echo "${MCP_PACKAGES[*]}$([ "$CLEAN_PACKAGES" = yes ] && echo " (clean install)")" || echo "<skipped>")"
    echo "  Codesign   : $([ "$DO_CODESIGN" = yes ] && echo "$SIGNING_IDENTITY" || echo "<skipped>")"
    echo
}

# ── 1. llama.cpp ──────────────────────────────────────────────────────────────
update_llama() {
    echo "==== llama.cpp $VERSION ($ARCH) ===="
    echo

    /bin/mkdir -p "$INSTALL_DIR" || fail "Could not create $INSTALL_DIR"

    echo "  Downloading $ASSET_NAME"
    /usr/bin/curl -L --fail --show-error --progress-bar -o "$TARBALL" "$DOWNLOAD_URL" \
        || fail "Download failed: $DOWNLOAD_URL"

    /bin/mkdir -p "$EXTRACT_DIR"
    /usr/bin/tar -xzf "$TARBALL" -C "$EXTRACT_DIR" || fail "Extraction failed"

    local found_binary
    found_binary=$(/usr/bin/find "$EXTRACT_DIR" -name "llama-server" ! -type d 2>/dev/null | head -1)
    [ -n "$found_binary" ] || fail "llama-server not found in the extracted archive"
    local src_dir
    src_dir="$(/usr/bin/dirname "$found_binary")"

    # Clear stale dylibs/LICENSEs so a prior version cannot linger beside the new one.
    # [ -e ] || [ -L ] catches dangling symlinks too ([ -e ] follows the link).
    local old
    for old in "$INSTALL_DIR"/*.dylib; do
        [ -e "$old" ] || [ -L "$old" ] || continue
        /bin/rm -f "$old"
    done
    for old in "$INSTALL_DIR"/LICENSE*; do
        [ -f "$old" ] || continue
        /bin/rm -f "$old"
    done

    echo "  Installing llama-server"
    /bin/cp "$src_dir/llama-server" "$INSTALL_DIR/llama-server"
    /bin/chmod +x "$INSTALL_DIR/llama-server"

    # Ship exactly what the binary asks for: only @rpath references need to travel with it,
    # system frameworks come from the OS.
    local required_dylibs
    required_dylibs=$(/usr/bin/otool -L "$src_dir/llama-server" \
        | /usr/bin/grep -oE '@rpath/[^ ]+\.dylib' | /usr/bin/sed 's|@rpath/||' | /usr/bin/sort -u)
    [ -n "$required_dylibs" ] || fail "otool -L found no @rpath dylibs - archive may be malformed"

    # Copies one dylib by name, then follows a symlink chain (libfoo.0.dylib ->
    # libfoo.0.9.11.dylib) so the whole chain lands intact.
    install_dylib() {
        local name="$1" src="$src_dir/$1" dest="$INSTALL_DIR/$1"
        [ -e "$src" ] || { echo "    ${RED}MISSING in archive: $name${RESET}"; return 1; }
        [ -e "$dest" ] && return 0   # already done (diamond-shaped symlink graphs)
        echo "    $name"
        /bin/cp -P "$src" "$dest"
        local target
        target=$(/usr/bin/readlink "$src" 2>/dev/null || echo "")
        [ -n "$target" ] && install_dylib "$target"
        return 0
    }

    echo "  dylibs (from otool -L, with symlink targets):"
    local install_ok="yes"
    local dylib_name
    while IFS= read -r dylib_name; do
        [ -z "$dylib_name" ] && continue
        install_dylib "$dylib_name" || install_ok="no"
    done <<EOF
$required_dylibs
EOF
    [ "$install_ok" = "yes" ] || fail "One or more required dylibs were missing from the archive"

    local license_path
    for license_path in "$src_dir"/LICENSE*; do
        [ -f "$license_path" ] || continue
        /bin/cp "$license_path" "$INSTALL_DIR/$(/usr/bin/basename "$license_path")"
    done

    LLAMA_STATUS="$VERSION"
    echo "  ${GREEN}Installed${RESET} llama.cpp $VERSION"
    echo
}

# ── 2. mlx-agent ──────────────────────────────────────────────────────────────

# Re-resolve mlx-agent's SPM dependencies to the newest versions its project.yml pins allow,
# so a shipped build never quietly carries a months-old MLX because Package.resolved froze it.
#
# Why the file has to be deleted: there is no `xcodebuild -updatePackages`.
# -resolvePackageDependencies HONOURS Package.resolved and keeps a stale revision that still
# satisfies the version rules, and `swift package update` needs a Package.swift, which that
# repo deliberately does not have (Metal shaders force xcodebuild; see project.yml's header).
# Resolving with the file absent is the only CLI path that actually upgrades.
#
# The old file is copied aside first and restored if resolution fails, so a network outage or
# a yanked upstream tag leaves the checkout exactly as it was rather than pin-less. On success
# the update lands as a git diff in the mlx-agent repo - deliberately: Package.resolved is
# committed there precisely so new versions get reviewed, and this script must not be the
# thing that quietly changes them without saying so.
#
# The backup lives in a TEMP DIR, not beside the original as a .bak, and a signal handler
# restores it. Both details matter and neither is theoretical: the resolution is
# network-bound and takes minutes on a cold checkout, so Ctrl-C lands inside the window
# where the file is deleted. A signal kills bash outright - the failure branches below
# never run - which would leave the sibling repo showing a DELETED tracked file, and a .bak
# beside it that mlx-agent's .gitignore does not cover, i.e. one `git add -A` from
# committing both. (Same reasoning as the packages staging tree further down.)

# One "<identity> <version>" line per pin of a Package.resolved. Anchored on `"version" : "`
# so the trailing `"version" : 3` format marker at the end of the file (an int, not a string)
# is not mistaken for a package version. A pin with no version (branch/revision pinned) falls
# back to its revision, so a revision move is NOT reported as "versions unchanged" - the whole
# point of the function is answering "did any pin actually move?", which is not the same
# question as "did the file change": a re-resolution rewrites originHash even when every pin
# lands on the byte-identical version.
# The revision is printed in full rather than abbreviated: this output is COMPARED, not just
# displayed, and two revisions sharing a short prefix would compare equal.
agent_pin_versions() {
    /usr/bin/awk -F'"' '
        function emit() { if (id != "") printf "    %-24s %s\n", id, (ver != "" ? ver : "rev " rev) }
        /"identity"/ { emit(); id = $4; ver = ""; rev = "" }
        /"revision"[[:space:]]*:[[:space:]]*"/ { rev = $4 }
        /"version"[[:space:]]*:[[:space:]]*"/  { ver = $4 }
        END { emit() }' "$1"
}

# Put back the pins we moved aside. Returns 0 if they are in place afterwards.
#
# It always discards whatever the interrupted/failed resolution wrote, rather than keeping a
# file that happens to exist: SwiftPM writes Package.resolved in place (no temp-and-rename)
# and writes it before the checkouts finish, so "the file is there" does not mean "the
# resolution completed" - a signal can leave it truncated. Re-running a resolution is cheap;
# telling the user their pins are fine when the file is corrupt is not.
#
# The copy lands on a temp name in the same directory and is renamed into place, so the real
# path is never a partially-written file: a SECOND signal arriving inside this handler (bash
# does not re-enter for the SAME signal, but does for a different one) would otherwise be able
# to interrupt the copy mid-write, and the re-entered pass would find a truncated file. The
# rename is atomic on the same volume, and a re-entered pass simply redoes the whole copy.
restore_agent_pins() {
    [ -n "$AGENT_PINS_BACKUP" ] && [ -f "$AGENT_PINS_BACKUP" ] || return 1
    local staged="$AGENT_RESOLVED.restoring.$$"
    /bin/cp -f "$AGENT_PINS_BACKUP" "$staged" || return 1
    /bin/mv -f "$staged" "$AGENT_RESOLVED"
}

# INT/TERM/HUP/QUIT while the pins are moved aside. HUP and QUIT are in the set deliberately:
# the window is minutes long on a cold checkout, which is exactly long enough for a terminal
# to be closed or an ssh session to drop, and those deliver HUP - not INT.
agent_pins_interrupted() {
    echo >&2
    if restore_agent_pins; then
        echo "${YELLOW}Interrupted - restored mlx-agent Package.resolved (this run's resolution discarded)${RESET}" >&2
    else
        echo "${RED}Interrupted - could NOT restore $AGENT_RESOLVED; recover it with: git -C '$AGENT_REPO' checkout -- mlx-agent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved${RESET}" >&2
    fi
    cleanup
    exit 130
}

update_agent_packages() {
    local resolved="$AGENT_RESOLVED"

    echo "  Re-resolving SPM dependencies to the newest versions project.yml allows..."

    AGENT_PINS_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/update-cadabra-pins.XXXXXX")"
    [ -d "$AGENT_PINS_DIR" ] || fail "mktemp failed"
    local resolve_log="$AGENT_PINS_DIR/resolve.log"
    local backup=""

    if [ -f "$resolved" ]; then
        backup="$AGENT_PINS_DIR/Package.resolved"
        /bin/cp -f "$resolved" "$backup" || fail "Could not back up $resolved"
        # Armed only for the window in which the file is gone; disarmed at the end.
        AGENT_PINS_BACKUP="$backup"
        trap agent_pins_interrupted INT TERM HUP QUIT
        /bin/rm -f "$resolved"
    fi

    if ! ( cd "$AGENT_REPO" && /usr/bin/xcodebuild \
            -project mlx-agent.xcodeproj \
            -scheme mlx-agent \
            -derivedDataPath build \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            -resolvePackageDependencies ) >"$resolve_log" 2>&1; then
        restore_agent_pins
        # A version conflict is the informative failure here and the one where project.yml
        # needs a human, so show what xcodebuild said instead of only that it failed.
        /usr/bin/tail -20 "$resolve_log" >&2
        fail "xcodebuild -resolvePackageDependencies failed (Package.resolved restored). Re-run with --skip-agent-package-update to build against the committed pins."
    fi

    if [ ! -f "$resolved" ]; then
        restore_agent_pins
        fail "Resolution wrote no Package.resolved (restored the previous one). Re-run with --skip-agent-package-update."
    fi

    # Existence is not enough: a resolution that died mid-write leaves a file that parses to
    # nothing, and an empty pin table would then compare unequal to the old one and be
    # announced as a perfectly ordinary "VERSIONS changed" - with no versions under it.
    # Checked while the trap is still armed and the backup still valid, so it can be undone.
    local new_pins="$(agent_pin_versions "$resolved")"
    if [ -z "$new_pins" ]; then
        restore_agent_pins
        fail "Resolution produced an unreadable Package.resolved - no pins in it (restored the previous one). Re-run, or use --skip-agent-package-update."
    fi

    trap - INT TERM HUP QUIT
    AGENT_PINS_BACKUP=""

    printf '%s\n' "$new_pins"

    if [ -z "$backup" ]; then
        echo "  ${YELLOW}Resolved from scratch (no previous Package.resolved) - review and commit it in $AGENT_REPO${RESET}"
    elif [ "$new_pins" != "$(agent_pin_versions "$backup")" ]; then
        echo "  ${YELLOW}Package VERSIONS changed - review and commit Package.resolved in $AGENT_REPO${RESET}"
    elif ! /usr/bin/cmp -s "$backup" "$resolved"; then
        # Every pin landed on the same version, but the file is not byte-identical: SwiftPM
        # rewrote originHash (it hashes the dependency declarations, and a from-scratch
        # resolution recomputes it). Worth saying out loud, because the git diff that shows
        # up in the agent repo is otherwise indistinguishable from a real upgrade.
        echo "  Package versions unchanged (already newest allowed); only Package.resolved metadata was rewritten"
    else
        echo "  Package.resolved unchanged (already at the newest allowed versions)"
    fi
}

update_agent() {
    echo "==== mlx-agent ===="
    echo

    if [ "$DO_BUILD" = "yes" ]; then
        # MLX's Metal shaders need the Metal toolchain (a separate Xcode component). Without
        # it default.metallib never compiles and the agent aborts at runtime.
        /usr/bin/xcrun --find metal >/dev/null 2>&1 \
            || fail "Metal toolchain missing. Install once: xcodebuild -downloadComponent MetalToolchain"

        if [ "$DO_AGENT_PACKAGE_UPDATE" = "yes" ]; then
            update_agent_packages
        else
            # Without a Package.resolved the build below resolves from scratch - i.e. performs
            # exactly the upgrade this flag exists to prevent, and writes a new pin set on the
            # way past. Refuse rather than print the opposite of what is about to happen.
            [ -f "$AGENT_RESOLVED" ] \
                || fail "--skip-agent-package-update was given, but there is no $AGENT_RESOLVED - the build would resolve from scratch and upgrade anyway. Restore it (git -C '$AGENT_REPO' checkout -- mlx-agent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) or drop the flag."
            echo "  --skip-agent-package-update: building against the committed Package.resolved"
        fi

        # Release, not Debug: this binary ships inside the app, so it is built -O /
        # wholemodule. The flag is what selects it - the scheme keeps run/test on Debug so
        # development in Xcode is unaffected - which is why AGENT_BUILD_DIR above must track
        # this value and not the scheme's.
        echo "  Building (xcodebuild -configuration Release - compiles the Metal shaders; never 'swift build')..."
        ( cd "$AGENT_REPO" && /usr/bin/xcodebuild \
            -project mlx-agent.xcodeproj \
            -scheme mlx-agent \
            -destination "platform=macOS,arch=$ARCH" \
            -derivedDataPath build \
            -configuration Release \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            build ) 2>&1 | /usr/bin/grep -iE "error:|BUILD (SUCCEEDED|FAILED)" | /usr/bin/tail -10
        [ "${PIPESTATUS[0]}" = 0 ] || fail "xcodebuild failed."
    else
        echo "  --skip-build: reusing existing build products"
    fi

    [ -x "$AGENT_BUILD_DIR/mlx-agent" ] \
        || fail "No built mlx-agent at $AGENT_BUILD_DIR (drop --skip-build, or build it yourself - note this deploys the RELEASE product, so a Debug-only build tree will not do)."

    /bin/mkdir -p "$MLX_DIR" || fail "Could not create $MLX_DIR"
    /bin/cp -f "$AGENT_BUILD_DIR/mlx-agent" "$MLX_DIR/mlx-agent"
    /bin/chmod +x "$MLX_DIR/mlx-agent"

    # Prove the deployed binary IS the one just built. This has to happen HERE, before
    # codesigning: signing rewrites the signature blob in place, so afterwards the deployed
    # file legitimately differs from the build product and a byte-compare can never match.
    /usr/bin/cmp -s "$AGENT_BUILD_DIR/mlx-agent" "$MLX_DIR/mlx-agent" \
        || fail "Deployed mlx-agent differs from the build product - copy did not take."

    # The metallib bundle must travel with the binary it was built against; a stale one is a
    # runtime abort, so it is replaced wholesale rather than merged.
    local required_bundle="mlx-swift_Cmlx.bundle"
    [ -d "$AGENT_BUILD_DIR/$required_bundle" ] || fail "Required metallib bundle missing: $required_bundle"
    local b
    for b in "$required_bundle" swift-crypto_Crypto.bundle swift-transformers_Hub.bundle; do
        if [ -d "$AGENT_BUILD_DIR/$b" ]; then
            /bin/rm -rf "${MLX_DIR:?}/$b"
            /bin/cp -Rf "$AGENT_BUILD_DIR/$b" "$MLX_DIR/$b"
        fi
    done
    [ -f "$MLX_DIR/$required_bundle/Contents/Resources/default.metallib" ] \
        || fail "default.metallib not found after copy."
    [ -f "$AGENT_REPO/LICENSE" ] && /bin/cp -f "$AGENT_REPO/LICENSE" "$MLX_DIR/mlx-agent.LICENSE"

    AGENT_STATUS="deployed (Release)"
    echo "  ${GREEN}Deployed${RESET} mlx-agent + metallib"
    echo
}

# ── 3. pdfutil ────────────────────────────────────────────────────────────────
update_pdfutil() {
    echo "==== pdfutil ===="
    echo

    if [ "$DO_BUILD" = "yes" ]; then
        # build.sh is a plain `xcrun swiftc -O` build (zero third-party deps - only macOS
        # system frameworks), so no Metal/Xcode-project machinery is needed. Pass the app's
        # arch so the deployed slice matches the rest of the bundle (build.sh accepts
        # arm64|x86_64; bare it would build a universal binary). It ad-hoc signs its output,
        # which the bundle-wide codesign below overwrites anyway.
        echo "  Building (./build.sh $ARCH)..."
        ( cd "$PDFUTIL_REPO" && ./build.sh "$ARCH" ) 2>&1 | /usr/bin/tail -5
        [ "${PIPESTATUS[0]}" = 0 ] || fail "pdfutil build.sh failed."
    else
        echo "  --skip-build: reusing existing build product"
    fi

    [ -x "$PDFUTIL_BUILD_BIN" ] \
        || fail "No built pdfutil at $PDFUTIL_BUILD_BIN (build first, or drop --skip-build)."

    /bin/mkdir -p "$(/usr/bin/dirname "$PDFUTIL_BIN")" || fail "Could not create Support dir for pdfutil"
    /bin/cp -f "$PDFUTIL_BUILD_BIN" "$PDFUTIL_BIN"
    /bin/chmod +x "$PDFUTIL_BIN"

    # Prove the deployed binary IS the one just built - BEFORE codesigning, since signing
    # rewrites the signature blob in place and a byte-compare could never match afterwards
    # (same ordering rationale as update_agent).
    /usr/bin/cmp -s "$PDFUTIL_BUILD_BIN" "$PDFUTIL_BIN" \
        || fail "Deployed pdfutil differs from the build product - copy did not take."

    [ -f "$PDFUTIL_REPO/LICENSE" ] && /bin/cp -f "$PDFUTIL_REPO/LICENSE" "${PDFUTIL_BIN}.LICENSE"

    PDFUTIL_STATUS="deployed"
    echo "  ${GREEN}Deployed${RESET} pdfutil"
    echo
}

# ── 3b. replay ────────────────────────────────────────────────────────────────
update_replay() {
    echo "==== replay ===="
    echo

    if [ "$DO_BUILD" = "yes" ]; then
        # The repo's own ./build.sh builds all four tools (replay, dispatch, fingerprint,
        # gate); only replay is bundled, so drive its scheme directly instead. ARCHS +
        # ONLY_ACTIVE_ARCH=NO pins the slice to the app's arch, matching the rationale in
        # update_pdfutil - on an arm64 host a bare build would never produce x86_64.
        # replay is portable C++ (no Metal/MLX), so unlike mlx-agent both arches are fine.
        echo "  Building (xcodebuild -scheme replay -configuration Release, $ARCH)..."
        ( cd "$REPLAY_REPO" && /usr/bin/xcodebuild -project replay.xcodeproj -scheme replay \
            -configuration Release ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO build ) 2>&1 | /usr/bin/tail -5
        [ "${PIPESTATUS[0]}" = 0 ] || fail "replay xcodebuild failed."
    else
        echo "  --skip-build: reusing existing build product"
    fi

    [ -x "$REPLAY_BUILD_BIN" ] \
        || fail "No built replay at $REPLAY_BUILD_BIN (build first, or drop --skip-build)."

    /bin/mkdir -p "$(/usr/bin/dirname "$REPLAY_BIN")" || fail "Could not create Support dir for replay"
    /bin/cp -f "$REPLAY_BUILD_BIN" "$REPLAY_BIN"
    /bin/chmod +x "$REPLAY_BIN"

    # Same pre-signing freshness proof as update_pdfutil: signing rewrites the signature
    # blob in place, so a byte-compare afterwards could never match.
    /usr/bin/cmp -s "$REPLAY_BUILD_BIN" "$REPLAY_BIN" \
        || fail "Deployed replay differs from the build product - copy did not take."

    [ -f "$REPLAY_REPO/LICENSE" ] && /bin/cp -f "$REPLAY_REPO/LICENSE" "${REPLAY_BIN}.LICENSE"

    REPLAY_STATUS="deployed"
    echo "  ${GREEN}Deployed${RESET} replay"
    echo
}

# ── 3c. Python MCP packages ───────────────────────────────────────────────────
update_packages() {
    echo "==== Python MCP packages ===="
    echo

    # --skip-build means "reuse what is already deployed" in every other stage; honour the
    # same reading here so a fast redeploy does not silently reach for the network.
    if [ "$DO_BUILD" = "no" ]; then
        [ -d "$PACKAGES_DIR" ] \
            || fail "No packages at $PACKAGES_DIR (install them first, or drop --skip-build)."
        echo "  --skip-build: reusing existing packages"
        PACKAGES_STATUS="reused"
        echo
        return 0
    fi

    echo "  Python   : $("$BUNDLED_PYTHON" --version 2>&1)"
    echo "  Target   : $PACKAGES_DIR"
    echo "  Packages : ${MCP_PACKAGES[*]}"
    echo

    # pip --target --upgrade never REMOVES anything, so a dir that has been upgraded across
    # dependency changes accumulates orphaned packages that are still importable and still
    # signed into the bundle. --clean-packages is the escape hatch.
    #
    # It builds the new tree in a STAGING directory and only swaps it in once the install
    # and the stripping have both succeeded. The obvious alternative - rename the live dir
    # aside, install in its place, move it back on failure - was written first and is a
    # trap: the "is there a backup?" state is not atomic, so a signal at the wrong moment
    # leaves a partially-removed backup that later gets mistaken for the good copy, and the
    # interrupt handler needed to delete the live tree before it could restore anything.
    # Every one of those windows is minutes long, because pip is network-bound.
    #
    # Staging inverts the risk: the live tree is untouched for the whole slow part, and the
    # only dangerous window is the final two renames, which take microseconds. Nothing has
    # to be restored on failure because nothing was taken away.
    local install_target="$PACKAGES_DIR"
    if [ "$CLEAN_PACKAGES" = "yes" ]; then
        # prepare() resolved any staging dir from an earlier run before we got here.
        /bin/rm -rf "${PACKAGES_STAGING:?}" || fail "Could not clear $PACKAGES_STAGING"
        install_target="$PACKAGES_STAGING"
        echo "  Clean install: building a fresh tree in $(/usr/bin/basename "$PACKAGES_STAGING")"
    fi

    /bin/mkdir -p "$install_target" || fail "Could not create $install_target"

    # --no-compile: .pyc files are regenerated on demand anyway, and baking them in both
    # inflates the signed payload and embeds absolute build-time paths.
    "$BUNDLED_PYTHON" -m pip install \
        --target "$install_target" \
        --no-compile --upgrade --no-input --disable-pip-version-check \
        "${MCP_PACKAGES[@]}" \
        || fail "pip install failed (network down, or a package no longer resolves).$([ "$CLEAN_PACKAGES" = yes ] && echo " The installed packages were left untouched.")"
    echo

    # Strip what should not be signed into the bundle: bytecode caches, pip's RECORD
    # manifests (they list files by hash and go stale the moment anything is stripped), and
    # the packages' own test suites. -prune stops find from descending into a directory it
    # is about to delete.
    echo "  Stripping __pycache__, RECORD, and test dirs..."
    /usr/bin/find "$install_target" -type d -name '__pycache__' -prune -exec /bin/rm -rf {} + 2>/dev/null
    /usr/bin/find "$install_target" -type f -name 'RECORD' -path '*.dist-info/*' -delete 2>/dev/null
    /usr/bin/find "$install_target" -type d \( -name tests -o -name test \) -prune -exec /bin/rm -rf {} + 2>/dev/null

    if [ "$CLEAN_PACKAGES" = "yes" ]; then
        # The sentinel is what makes recovery decidable. Written only after pip AND the
        # strip have succeeded, so prepare() can tell "complete tree waiting to be swapped
        # in" from "pip died halfway" without guessing - which is exactly the distinction
        # the rename-aside version could not make.
        : > "$PACKAGES_STAGING/$STAGING_SENTINEL" \
            || fail "Could not mark $PACKAGES_STAGING complete"
        swap_in_staged_packages
    fi

    PACKAGES_STATUS="installed"
    echo "  ${GREEN}Installed${RESET} ${MCP_PACKAGES[*]}"
    echo
}

# Replace the live packages with the completed staging tree. Split out because prepare()
# needs exactly this when a previous run was killed after the sentinel was written.
# Deliberately no trap: both renames are metadata-only, so the window where neither
# directory is in place is microseconds rather than the minutes a network install takes,
# and a kill inside it still leaves the staging tree with its sentinel for the next run.
swap_in_staged_packages() {
    /bin/rm -rf "${PACKAGES_DIR:?}" \
        || fail "Could not remove $PACKAGES_DIR to swap in the new packages. The complete new tree is at $PACKAGES_STAGING."
    /bin/mv "$PACKAGES_STAGING" "$PACKAGES_DIR" \
        || fail "Could not move $PACKAGES_STAGING into place. The complete new tree is still there - move it by hand."
    # Drop the marker only after the rename succeeded; removing it earlier would leave a
    # complete tree that the next run could no longer recognise as complete. A stray
    # zero-byte dotfile here would otherwise be signed into the bundle.
    /bin/rm -f "$PACKAGES_DIR/$STAGING_SENTINEL"
}

# ── 4. Codesign ───────────────────────────────────────────────────────────────
codesign_app() {
    echo "==== Codesigning ===="
    echo

    # Sweep stray bytecode out of every part of the bundle that Python touches, and do it
    # here rather than in update_packages so it runs no matter which stages were skipped.
    # Anything present now gets sealed in permanently.
    #
    # These caches never come from the app: the OMC runtime redirects them via
    # PYTHONPYCACHEPREFIX. They come from running the bundle's interpreter OUTSIDE that
    # environment - this script before the export above existed, a debugging session, a
    # test harness, someone poking at Contents/Library/Packages by hand. That is exactly
    # the kind of residue nobody notices until codesign seals it in, so sweep rather than
    # trust that no one ever did it.
    #
    # Two roots because the caches land in two different places: under Contents/Library
    # for the interpreter and the installed packages, and under Contents/Resources/Scripts
    # when a script there imports a SIBLING module, which puts the cache next to the
    # scripts rather than under Library at all.
    # prepare() resolves any staging tree before this runs, so reaching here with one is a
    # bug. Refuse rather than seal a ~44 MB duplicate of the package tree into the bundle.
    [ -e "$PACKAGES_STAGING" ] \
        && fail "$PACKAGES_STAGING still exists at signing time - refusing to seal a duplicate package tree into the bundle."

    # Contents/Library covers both PYTHON_DIR and PACKAGES_DIR in one walk; each root is
    # passed quoted so a bundle path containing spaces survives.
    local stale_pyc
    stale_pyc=$(/usr/bin/find "$APP_BUNDLE/Contents/Library" "$APP_BUNDLE/Contents/Resources/Scripts" \
        -type d -name '__pycache__' 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    if [ "$stale_pyc" != "0" ]; then
        echo "  Removing $stale_pyc stray __pycache__ dir(s) before sealing"
        /usr/bin/find "$APP_BUNDLE/Contents/Library" "$APP_BUNDLE/Contents/Resources/Scripts" \
            -type d -name '__pycache__' -prune -exec /bin/rm -rf {} + 2>/dev/null
    fi

    # Beside this script at the repo root since the Cadabra rebrand; ../ is the
    # pre-rebrand location, kept as a fallback.
    local codesign_script="$SCRIPT_DIR/codesign_applet.sh"
    [ -f "$codesign_script" ] || codesign_script="$SCRIPT_DIR/../codesign_applet.sh"
    [ -f "$codesign_script" ] || fail "codesign_applet.sh not found at $codesign_script"
    "$codesign_script" "$APP_BUNDLE" "$SIGNING_IDENTITY" || fail "Codesigning failed"
    echo
}

# ── 5. Verify ─────────────────────────────────────────────────────────────────
verify() {
    echo "==== Verifying ===="
    echo

    if [ "$DO_LLAMA" = "yes" ]; then
        local server="$INSTALL_DIR/llama-server"
        [ -x "$server" ] || fail "llama-server missing after install"
        local version_out
        version_out=$("$server" --version 2>&1 | head -1 || echo "")
        [ -n "$version_out" ] || fail "llama-server --version produced no output - dylib load failure?"
        echo "  llama-server: $version_out"
        # --help exercises the full dylib load; only the exit code matters.
        "$server" --help >/dev/null 2>&1 || fail "llama-server --help failed - possible dylib load failure"
        echo "  ${GREEN}OK${RESET} llama-server launches"
    fi

    if [ "$DO_AGENT" = "yes" ]; then
        # Freshness is already proven by the cmp in update_agent, which runs BEFORE signing.
        # What is left to prove here is that the binary still loads once signed - i.e. the
        # signature and the metallib bundle beside it agree.
        #
        # --version reports what was actually deployed (the same string the agent puts in its
        # ACP agentInfo), so the log names a version rather than just "deployed". It answers
        # before any model, config or MLX work, so anything other than a version means the
        # process did not get that far - which is exactly what a post-signing probe isolates.
        #
        # stderr is DISCARDED, not merged: dyld writes "Library not loaded: ..." there and
        # exits nonzero, so a `2>&1` capture would be non-empty and a mere -n test would
        # report a load failure as the version. The answer is matched for shape instead.
        local agent_version="$( cd "$MLX_DIR" && ./mlx-agent --version 2>/dev/null | /usr/bin/head -1 )"
        case "$agent_version" in
            "mlx-agent "*) ;;
            *) fail "mlx-agent --version did not report a version (got: \"${agent_version:-<no output>}\") - a metallib/dylib load failure, or a broken signature." ;;
        esac
        echo "  mlx-agent: $agent_version"
        # --help additionally exercises the full startup path; only the exit code matters.
        ( cd "$MLX_DIR" && ./mlx-agent --help >/dev/null 2>&1 ) \
            || fail "mlx-agent --help failed - a metallib/dylib load failure, or a broken signature."
        echo "  ${GREEN}OK${RESET} mlx-agent launches (post-signing)"
    fi

    if [ "$DO_PDFUTIL" = "yes" ]; then
        # Freshness is already proven by the cmp in update_pdfutil (pre-signing). What is
        # left to prove is that the binary still loads once signed. --version is a full
        # process launch that exits 0.
        local pdfutil_version
        pdfutil_version=$("$PDFUTIL_BIN" --version 2>&1 | head -1 || echo "")
        [ -n "$pdfutil_version" ] || fail "pdfutil --version produced no output - load failure or broken signature?"
        echo "  pdfutil: $pdfutil_version"
        echo "  ${GREEN}OK${RESET} pdfutil launches (post-signing)"
    fi

    if [ "$DO_REPLAY" = "yes" ]; then
        # Freshness is proven by the cmp in update_replay (pre-signing); this proves the
        # binary still loads once signed.
        local replay_version
        replay_version=$("$REPLAY_BIN" --version 2>&1 | head -1 || echo "")
        [ -n "$replay_version" ] || fail "replay --version produced no output - load failure or broken signature?"
        echo "  replay: $replay_version"
        # replay is bundled for ONE job - being Cadabra's local files/shell MCP server - and
        # the app derives its permission prompts from the annotations in this reply, so a
        # binary that cannot answer tools/list is useless even if it launches.
        #
        # Capture the output and match the STRING rather than piping into grep. Two traps
        # avoided, both of which would report a healthy replay as broken:
        #   - `grep -c` prints 0 AND exits 1 on no-match, so a `|| echo 0` fallback captures
        #     "0\n0" and a numeric test then errors out instead of comparing.
        #   - `grep -q` exits the moment it matches, so replay takes SIGPIPE on anything it
        #     writes afterwards and exits 141; with `set -o pipefail` that 141 becomes the
        #     pipeline's status and the success path is never taken. Harmless only while
        #     tools/list stays under the pipe buffer, which is not a property worth relying on.
        # perl's alarm bounds the run: replay exits on stdin EOF today, but an MCP server
        # that answers and then lingers is exactly what the launch-path probe was rewritten
        # to survive, and this script should not be the thing that hangs instead.
        local tools_out
        tools_out=$(printf '%s\n' \
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"update-cadabra","version":"1"}}}' \
            '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
            '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
            | /usr/bin/perl -e 'alarm 20; exec @ARGV or exit 127' \
              "$REPLAY_BIN" --mcp-server --allow-write "${TMPDIR:-/tmp}" 2>/dev/null)
        case "$tools_out" in
            *'"readOnlyHint"'*) ;;
            *) fail "replay answered no annotated tools/list - the MCP server mode is broken, it hung, or this build predates tool annotations." ;;
        esac
        echo "  ${GREEN}OK${RESET} replay launches and serves annotated tools (post-signing)"
    fi

    if [ "$DO_PACKAGES" = "yes" ]; then
        # Import each module the way the app will: the bundle's own interpreter with
        # PYTHONPATH pointing at Packages, matching how generate_mcp_configs.py spawns
        # them. A package that pip reports as installed can still fail to import - a
        # missing native wheel for this arch is the usual cause - and the launch probe
        # would then silently drop that server from the config rather than complain.
        #
        # See MCP_MODULES at the top for why these are the launched module names rather
        # than the top-level packages, and why importing them does not start a server.
        #
        # This is the invocation that MUST NOT write bytecode: it runs after codesign_app,
        # so a single .pyc here breaks the seal just applied. -B is passed explicitly on
        # top of the script-wide export because this is the one call site where losing it
        # is not a size regression but a broken signature - and unlike the app, this runs
        # outside the OMC environment, so nothing else is redirecting the cache.
        # The module name is passed as argv, never interpolated into the source, so a name
        # with a quote in it cannot become code.
        local module failed_modules=""
        for module in "${MCP_MODULES[@]}"; do
            if PYTHONPATH="$PACKAGES_DIR" \
                "$BUNDLED_PYTHON" -B -c '
import importlib, importlib.util, sys
name = sys.argv[1]
mod = importlib.import_module(name)          # proves the dependency graph resolves
# `python3 -m pkg` runs pkg/__main__.py, which importing the package never touches - so a
# package missing __main__.py imports fine here and dies at launch with "cannot be
# directly executed". Only packages need the check; plain modules are their own entry.
if getattr(mod, "__path__", None) is not None and importlib.util.find_spec(name + ".__main__") is None:
    sys.exit(1)
' "$module" >/dev/null 2>&1
            then
                echo "  ${GREEN}OK${RESET} $module imports"
            else
                failed_modules="$failed_modules $module"
            fi
        done
        [ -z "$failed_modules" ] || fail "Python MCP modules failed to import:$failed_modules"
    fi

    # Last, and only when we signed: prove the bundle the user is about to run still
    # satisfies its own seal. Every check above EXECUTES something inside the bundle,
    # and anything that writes a file there (bytecode caches being the classic) silently
    # invalidates the signature while every individual check still reports OK. Without
    # this the script's final word would be "ready" on a bundle that codesign rejects,
    # which is fatal for Developer ID and notarization and easy to miss locally.
    if [ "$DO_CODESIGN" = "yes" ]; then
        /usr/bin/codesign --verify --deep "$APP_BUNDLE" 2>/dev/null \
            || fail "$(/usr/bin/basename "$APP_BUNDLE") no longer satisfies its code signature - something written into the bundle after signing (stray __pycache__?). Run: codesign --verify --verbose=2 '$APP_BUNDLE'"
        echo "  ${GREEN}OK${RESET} code signature still valid after verification"
    fi
    echo
}

print_summary() {
    echo "==== Done ===="
    echo
    echo "  llama.cpp : $LLAMA_STATUS"
    echo "  mlx-agent : $AGENT_STATUS"
    echo "  pdfutil   : $PDFUTIL_STATUS"
    echo "  replay    : $REPLAY_STATUS"
    echo "  packages  : $PACKAGES_STATUS"
    echo
    echo "  ${GREEN}$(/usr/bin/basename "$APP_BUNDLE") is ready.${RESET}"
    echo
}

main() {
    prepare
    [ "$DO_LLAMA" = "yes" ] && update_llama
    [ "$DO_AGENT" = "yes" ] && update_agent
    [ "$DO_PDFUTIL" = "yes" ] && update_pdfutil
    [ "$DO_REPLAY" = "yes" ] && update_replay
    # Before codesign, deliberately: the packages land inside the bundle, so installing
    # them afterwards would invalidate the seal that was just applied.
    [ "$DO_PACKAGES" = "yes" ] && update_packages
    [ "$DO_CODESIGN" = "yes" ] && codesign_app
    verify
    cleanup
    print_summary
}

main
