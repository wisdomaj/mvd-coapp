#!/bin/bash
set -e

# ==============================================================================
# dev-install-mac.sh — Build, package, and install mvd-coapp on Apple Silicon Mac
#
# Produces a self-contained DMG installer with all bundled binaries.
#
# Usage:
#   ./dev-install-mac.sh              # build + dist (DMG) + install
#   ./dev-install-mac.sh build        # build only
#   ./dev-install-mac.sh dist         # build + create DMG
#   ./dev-install-mac.sh install      # install from existing build (no DMG)
#   ./dev-install-mac.sh uninstall    # remove native messaging host registrations
#   ./dev-install-mac.sh ffmpeg       # build FFmpeg with SVT-AV1 from source
#
# Prerequisites:
#   - Node.js (brew install node)
#   - Xcode Command Line Tools (xcode-select --install)
#   - create-dmg (brew install create-dmg) — only for DMG packaging
#   - FFmpeg binaries in bin/mac-arm64/ (ffmpeg, ffprobe)
#     Build from source:  ./dev-install-mac.sh ffmpeg
#     Prereqs for FFmpeg: brew install cmake nasm pkg-config automake autoconf libtool meson
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="mac-arm64"
BIN_SRC="$ROOT_DIR/bin/$TARGET"
BUILD_DIR="$ROOT_DIR/build/$TARGET"
DIST_DIR="$ROOT_DIR/dist"
BINARY="$BUILD_DIR/mvdcoapp"

log_info()  { echo -e "\033[32m[INFO]\033[0m  $1"; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m  $1"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }

check_prerequisites() {
    local missing=0

    if ! command -v node &>/dev/null; then
        log_error "Node.js not found. Install: brew install node"
        missing=1
    fi

    if ! command -v xcrun &>/dev/null || ! xcrun --find clang++ &>/dev/null 2>&1; then
        log_error "Xcode Command Line Tools not found. Install: xcode-select --install"
        missing=1
    fi

    if [ ! -f "$BIN_SRC/ffmpeg" ] || [ ! -f "$BIN_SRC/ffprobe" ]; then
        log_error "FFmpeg binaries not found at $BIN_SRC/"
        log_error ""
        log_error "Build FFmpeg from source (includes SVT-AV1):"
        log_error "  ./dev-install-mac.sh ffmpeg"
        log_error ""
        log_error "Requires: brew install cmake nasm pkg-config automake autoconf libtool meson"
        log_error ""
        missing=1
    fi

    [ $missing -eq 1 ] && exit 1
}

do_build() {
    check_prerequisites

    if [ ! -d "$ROOT_DIR/node_modules" ]; then
        log_info "Installing npm dependencies..."
        cd "$ROOT_DIR" && npm install
    fi

    log_info "Building for $TARGET..."
    cd "$ROOT_DIR" && ./build-coapp.sh build "$TARGET"

    if [ ! -f "$BINARY" ]; then
        log_error "Build failed — binary not found at $BINARY"
        exit 1
    fi

    log_info "Build complete: $BINARY"
}

do_dist() {
    do_build

    if ! command -v create-dmg &>/dev/null; then
        log_error "create-dmg not found. Install: brew install create-dmg"
        exit 1
    fi

    log_info "Creating DMG installer..."
    cd "$ROOT_DIR" && ./build-coapp.sh dist "$TARGET"

    local dmg_path="$DIST_DIR/mvdcoapp-${TARGET}.dmg"
    if [ -f "$dmg_path" ]; then
        log_info "DMG ready: $dmg_path"
        log_info ""
        log_info "To install:"
        log_info "  open \"$dmg_path\""
        log_info "  # Drag mvdcoapp.app to /Applications"
        log_info "  xattr -dr com.apple.quarantine /Applications/mvdcoapp.app"
        log_info "  open /Applications/mvdcoapp.app"
    else
        log_error "DMG was not created"
        exit 1
    fi
}

do_install() {
    if [ ! -f "$BINARY" ]; then
        log_error "Binary not found at $BINARY — run './dev-install-mac.sh build' first"
        exit 1
    fi

    log_info "Installing native messaging host for all detected browsers..."
    "$BINARY" --install

    log_info "Install complete. Restart your browser for changes to take effect."
}

do_uninstall() {
    if [ ! -f "$BINARY" ]; then
        log_error "Binary not found at $BINARY — nothing to uninstall with"
        exit 1
    fi

    log_info "Uninstalling native messaging host..."
    "$BINARY" --uninstall
}

do_ffmpeg() {
    log_info "Building FFmpeg with SVT-AV1 from source..."
    log_info "This will take a while (compiling all dependencies + FFmpeg)."
    log_info ""
    "$ROOT_DIR/tools/build-ffmpeg-mac.sh"
}

case "${1:-all}" in
    build)
        do_build
        ;;
    dist)
        do_dist
        ;;
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    ffmpeg)
        do_ffmpeg
        ;;
    all)
        do_dist
        do_install
        ;;
    *)
        echo "Usage: $0 [build|dist|install|uninstall|ffmpeg]"
        echo ""
        echo "  (no args)  build + create DMG + install"
        echo "  build      build coapp binary only"
        echo "  dist       build + create DMG"
        echo "  install    register native messaging host (build must exist)"
        echo "  uninstall  remove native messaging host registrations"
        echo "  ffmpeg     build FFmpeg with SVT-AV1 from source"
        exit 1
        ;;
esac
