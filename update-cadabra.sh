#!/bin/bash
# update-cadabra.sh
# Updates the git-excluded runtime engines inside Cadabra.app (the native-chat V2,
# rebranded from V2/AIChat.app):
#   1. llama.cpp  - llama-server + its dylibs, from a GitHub release (the GGUF engine)
#   2. mlx-agent  - built from source with xcodebuild (the ACP agent + MLX engine)
#   3. pdfutil    - built from source with ./build.sh (the PDF MCP server)
# then codesigns the bundle and verifies the engines actually launch.
#
# Relationship to ./update-llama-cpp.sh: that script serves the V1 app (and Enoch), which
# renders its UI from llama.cpp's WebUI and therefore has to download and sed-patch
# bundle.js/bundle.css/index.html on every update. Cadabra has NO Contents/Resources/WebUI -
# the chat UI is native (ActionUI Chat element over ACP) - so ALL of that machinery is dead
# weight here and is deliberately absent rather than skipped by a flag. Cadabra also embeds
# mlx-agent, which V1 does not, so the two scripts do not converge.
#
# arm64 only for the agent: mlx-agent is Metal/MLX and does not build for x86_64. The
# llama.cpp half still accepts --arch=x86_64 (pass --skip-agent with it). pdfutil builds
# for either arch, so it is deployed on both the arm64 and x86_64 paths.
#
# The bundle is Cadabra.app next to this script - NOT auto-globbed: the repo root also
# holds the V1 AIChat.app, which this script must never touch.

set -uo pipefail

RED=$(printf '\033[91m'); GREEN=$(printf '\033[92m')
YELLOW=$(printf '\033[93m'); RESET=$(printf '\033[0m')

VERSION="auto"
ARCH="auto"
SIGNING_IDENTITY="-"
AGENT_REPO="${AGENT_REPO:-}"
PDFUTIL_REPO="${PDFUTIL_REPO:-}"
DO_LLAMA="yes"
DO_AGENT="yes"
DO_PDFUTIL="yes"
DO_BUILD="yes"
DO_CODESIGN="yes"

# Set by prepare()
ASSET_NAME=""; DOWNLOAD_URL=""; WORK_DIR=""; TARBALL=""; EXTRACT_DIR=""
AGENT_BUILD_DIR=""
PDFUTIL_BUILD_BIN=""
LLAMA_STATUS="skipped"; AGENT_STATUS="skipped"; PDFUTIL_STATUS="skipped"

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" >/dev/null 2>&1 && pwd)"

fail() { echo "${RED}$*${RESET}" >&2; cleanup; exit 1; }

# A dependency repo is missing: offer to git-clone it into the sibling location and continue.
# Interactive runs only - without a TTY (CI, piped stdin) this declines silently and the
# caller's fail() fires with the manual instructions. $1 = repo URL, $2 = destination dir.
offer_clone() {
    [ -t 0 ] || return 1
    printf "%s  %s not found. Clone %s\n  into %s now? [y/N] %s" \
        "$YELLOW" "$(/usr/bin/basename "$2")" "$1" "$2" "$RESET"
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

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Updates the runtime engines in $(/usr/bin/basename "$APP_BUNDLE"):
  llama.cpp -> Contents/Support/Llama.cpp/   (downloaded release, no WebUI - Cadabra is native)
  mlx-agent -> Contents/Support/MLX/         (built from source with xcodebuild)
  pdfutil   -> Contents/Support/pdfutil      (built from source with ./build.sh)

Options:
  --version=VERSION   llama.cpp build tag (e.g. b8797, default: auto-detect latest)
  --arch=ARCH         arm64 or x86_64 (default: host). x86_64 requires --skip-agent.
  --identity=CERT     codesign identity (default: - for ad-hoc)
  --agent-repo=PATH   mlx-agent repo (default: ../mlx-agent sibling checkout)
  --pdfutil-repo=PATH pdfutil repo (default: ../pdfutil sibling checkout)
  --skip-llama        leave llama.cpp untouched
  --skip-agent        leave mlx-agent untouched
  --skip-pdfutil      leave pdfutil untouched
  --skip-build        deploy the agent's & pdfutil's existing build products without rebuilding
  --skip-codesign     do not codesign
  --help              show this message

Examples:
  ./update-cadabra.sh
  ./update-cadabra.sh --version=b8797
  ./update-cadabra.sh --skip-llama                 # rebuild + redeploy just the agent + pdfutil
  ./update-cadabra.sh --skip-agent                 # refresh llama.cpp + pdfutil
  ./update-cadabra.sh --skip-llama --skip-agent    # rebuild + redeploy just pdfutil
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
        --skip-llama) DO_LLAMA="no" ;;
        --skip-agent) DO_AGENT="no" ;;
        --skip-pdfutil) DO_PDFUTIL="no" ;;
        --skip-build) DO_BUILD="no" ;;
        --skip-codesign) DO_CODESIGN="no" ;;
        *) echo "Unknown option: $1"; show_help ;;
    esac
    shift
done

cleanup() {
    # Only ever remove the mktemp dir this run created; never an inherited/empty value.
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        /bin/rm -rf "$WORK_DIR"
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
        # Debug config: what the repo's own scheme ships (see mlx-agent/project.yml).
        AGENT_BUILD_DIR="$AGENT_REPO/build/Build/Products/Debug"
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

    echo "  App bundle : $APP_BUNDLE"
    echo "  Arch       : $ARCH"
    echo "  llama.cpp  : $([ "$DO_LLAMA" = yes ] && echo "$VERSION" || echo "<skipped>")"
    echo "  mlx-agent  : $([ "$DO_AGENT" = yes ] && echo "${AGENT_REPO}$([ "$DO_BUILD" = no ] && echo " (no rebuild)")" || echo "<skipped>")"
    echo "  pdfutil    : $([ "$DO_PDFUTIL" = yes ] && echo "${PDFUTIL_REPO}$([ "$DO_BUILD" = no ] && echo " (no rebuild)")" || echo "<skipped>")"
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
    while IFS= read -r dylib_name; do
        [ -z "$dylib_name" ] && continue
        install_dylib "$dylib_name" || install_ok="no"
    done <<EOF
$required_dylibs
EOF
    [ "$install_ok" = "yes" ] || fail "One or more required dylibs were missing from the archive"

    for license_path in "$src_dir"/LICENSE*; do
        [ -f "$license_path" ] || continue
        /bin/cp "$license_path" "$INSTALL_DIR/$(/usr/bin/basename "$license_path")"
    done

    LLAMA_STATUS="$VERSION"
    echo "  ${GREEN}Installed${RESET} llama.cpp $VERSION"
    echo
}

# ── 2. mlx-agent ──────────────────────────────────────────────────────────────
update_agent() {
    echo "==== mlx-agent ===="
    echo

    if [ "$DO_BUILD" = "yes" ]; then
        # MLX's Metal shaders need the Metal toolchain (a separate Xcode component). Without
        # it default.metallib never compiles and the agent aborts at runtime.
        /usr/bin/xcrun --find metal >/dev/null 2>&1 \
            || fail "Metal toolchain missing. Install once: xcodebuild -downloadComponent MetalToolchain"

        echo "  Building (xcodebuild - compiles the Metal shaders; never 'swift build')..."
        ( cd "$AGENT_REPO" && /usr/bin/xcodebuild \
            -project mlx-agent.xcodeproj \
            -scheme mlx-agent \
            -destination "platform=macOS,arch=$ARCH" \
            -derivedDataPath build \
            -configuration Debug \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            build ) 2>&1 | /usr/bin/grep -iE "error:|BUILD (SUCCEEDED|FAILED)" | /usr/bin/tail -10
        [ "${PIPESTATUS[0]}" = 0 ] || fail "xcodebuild failed."
    else
        echo "  --skip-build: reusing existing build products"
    fi

    [ -x "$AGENT_BUILD_DIR/mlx-agent" ] \
        || fail "No built mlx-agent at $AGENT_BUILD_DIR (build first, or drop --skip-build)."

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
    for b in "$required_bundle" swift-crypto_Crypto.bundle swift-transformers_Hub.bundle; do
        if [ -d "$AGENT_BUILD_DIR/$b" ]; then
            /bin/rm -rf "${MLX_DIR:?}/$b"
            /bin/cp -Rf "$AGENT_BUILD_DIR/$b" "$MLX_DIR/$b"
        fi
    done
    [ -f "$MLX_DIR/$required_bundle/Contents/Resources/default.metallib" ] \
        || fail "default.metallib not found after copy."
    [ -f "$AGENT_REPO/LICENSE" ] && /bin/cp -f "$AGENT_REPO/LICENSE" "$MLX_DIR/mlx-agent.LICENSE"

    AGENT_STATUS="deployed"
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

# ── 4. Codesign ───────────────────────────────────────────────────────────────
codesign_app() {
    echo "==== Codesigning ===="
    echo
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
    echo
}

print_summary() {
    echo "==== Done ===="
    echo
    echo "  llama.cpp : $LLAMA_STATUS"
    echo "  mlx-agent : $AGENT_STATUS"
    echo "  pdfutil   : $PDFUTIL_STATUS"
    echo
    echo "  ${GREEN}$(/usr/bin/basename "$APP_BUNDLE") is ready.${RESET}"
    echo
}

main() {
    prepare
    [ "$DO_LLAMA" = "yes" ] && update_llama
    [ "$DO_AGENT" = "yes" ] && update_agent
    [ "$DO_PDFUTIL" = "yes" ] && update_pdfutil
    [ "$DO_CODESIGN" = "yes" ] && codesign_app
    verify
    cleanup
    print_summary
}

main
