#!/bin/bash
set -e

# ==============================================================================
# build-ffmpeg-mac.sh — Build FFmpeg with SVT-AV1 for macOS Apple Silicon
#
# Compiles SVT-AV1 and all other required libraries as static dependencies,
# then builds FFmpeg with the same flags as the official mvd-coapp release
# plus --enable-libsvtav1.
#
# Output: bin/mac-arm64/ffmpeg, bin/mac-arm64/ffprobe
#
# Prerequisites (auto-installed if missing):
#   Homebrew, Xcode Command Line Tools
#   cmake, nasm, pkg-config, automake, autoconf, libtool, meson (installed via brew)
#
# Usage:
#   ./tools/build-ffmpeg-mac.sh              # full build (all deps + ffmpeg)
#   ./tools/build-ffmpeg-mac.sh --deps-only  # build dependencies only
#   ./tools/build-ffmpeg-mac.sh --ffmpeg-only # build ffmpeg only (deps must exist)
#   ./tools/build-ffmpeg-mac.sh --clean       # remove build artifacts
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="arm64"
TARGET="mac-arm64"
NPROC=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

# Directories
BUILD_DIR="$ROOT_DIR/ffmpeg-build"
SRC_DIR="$BUILD_DIR/src"
PREFIX="$BUILD_DIR/prefix"
OUTPUT_DIR="$ROOT_DIR/bin/$TARGET"

# FFmpeg source
FFMPEG_REPO="https://github.com/wisdomaj/FFmpeg.git"
FFMPEG_BRANCH="master"

# Dependency versions
SVTAV1_VERSION="v4.1.0"
X264_REPO="https://code.videolan.org/videolan/x264.git"
X265_REPO="https://bitbucket.org/multicoreware/x265_git.git"
LIBVPX_VERSION="v1.15.0"
OPUS_VERSION="v1.5.2"
LAME_VERSION="3.100"
VORBIS_VERSION="v1.3.7"
OGG_VERSION="v1.3.5"

log_info()  { echo -e "\033[32m[INFO]\033[0m  $1"; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m  $1"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig"
export PATH="$PREFIX/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="11.0"

# ==============================================================================
# Prerequisites
# ==============================================================================

check_prerequisites() {
    # Ensure Homebrew is available
    if ! command -v brew &>/dev/null; then
        log_error "Homebrew not found. Install from https://brew.sh"
        exit 1
    fi

    # Ensure Xcode Command Line Tools are installed
    if ! command -v xcrun &>/dev/null || ! xcrun --find clang &>/dev/null 2>&1; then
        log_info "Installing Xcode Command Line Tools..."
        xcode-select --install 2>/dev/null || true
        log_error "Xcode Command Line Tools are required. Please complete the installation and re-run."
        exit 1
    fi

    # Install all required brew packages (skips already-installed ones)
    local brew_deps=(cmake nasm pkg-config automake autoconf libtool meson create-dmg)
    local to_install=()
    for dep in "${brew_deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            to_install+=("$dep")
        fi
    done

    if [ ${#to_install[@]} -gt 0 ]; then
        log_info "Installing missing dependencies: ${to_install[*]}"
        brew install "${to_install[@]}"
    fi

    # Verify critical tools are now available
    for tool in cmake nasm pkg-config meson git make; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "Required tool '$tool' still not found after install attempt."
            exit 1
        fi
    done
}

# ==============================================================================
# Dependency Builders
# ==============================================================================

build_svtav1() {
    log_info "Building SVT-AV1 $SVTAV1_VERSION..."
    local src="$SRC_DIR/SVT-AV1"
    if [ ! -d "$src" ]; then
        git clone --depth 1 --branch "$SVTAV1_VERSION" https://gitlab.com/AOMediaCodec/SVT-AV1.git "$src"
    fi
    mkdir -p "$src/build" && cd "$src/build"
    cmake .. \
        -G "Unix Makefiles" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_APPS=OFF \
        -DBUILD_DEC=OFF \
        -DBUILD_TESTING=OFF \
        -DENABLE_NASM=ON
    make -j"$NPROC"
    make install
    log_info "SVT-AV1 done."
}

build_x264() {
    log_info "Building x264..."
    local src="$SRC_DIR/x264"
    if [ ! -d "$src" ]; then
        git clone --depth 1 "$X264_REPO" "$src"
    fi
    cd "$src"
    ./configure \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --disable-cli \
        --host="aarch64-apple-darwin" \
        --extra-cflags="-arch $ARCH" \
        --extra-ldflags="-arch $ARCH"
    make -j"$NPROC"
    make install
    log_info "x264 done."
}

build_x265() {
    log_info "Building x265..."
    local src="$SRC_DIR/x265"
    if [ ! -d "$src" ]; then
        git clone --depth 1 "$X265_REPO" "$src"
    fi
    mkdir -p "$src/bld" && cd "$src/bld"
    cmake ../source \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DENABLE_SHARED=OFF \
        -DENABLE_CLI=OFF
    make -j"$NPROC"
    make install
    log_info "x265 done."
}

build_libvpx() {
    log_info "Building libvpx $LIBVPX_VERSION..."
    local src="$SRC_DIR/libvpx"
    if [ ! -d "$src" ]; then
        git clone --depth 1 --branch "$LIBVPX_VERSION" https://chromium.googlesource.com/webm/libvpx.git "$src"
    fi
    cd "$src"
    # arm64-darwin-gcc targets iOS; use arm64-darwin20-gcc for macOS 11+
    ./configure \
        --prefix="$PREFIX" \
        --target=arm64-darwin20-gcc \
        --enable-static \
        --disable-shared \
        --disable-examples \
        --disable-tools \
        --disable-unit-tests \
        --disable-docs \
        --enable-vp9-highbitdepth \
        --extra-cflags="-isysroot $(xcrun --show-sdk-path)"
    make -j"$NPROC"
    make install
    log_info "libvpx done."
}

build_opus() {
    log_info "Building libopus $OPUS_VERSION..."
    local src="$SRC_DIR/opus"
    if [ ! -d "$src" ]; then
        git clone --depth 1 --branch "$OPUS_VERSION" https://gitlab.xiph.org/xiph/opus.git "$src"
    fi
    cd "$src"
    autoreconf -fiv 2>/dev/null || true
    ./configure \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --disable-doc \
        --disable-extra-programs \
        --host="aarch64-apple-darwin"
    make -j"$NPROC"
    make install
    log_info "libopus done."
}

build_lame() {
    log_info "Building libmp3lame $LAME_VERSION..."
    local src="$SRC_DIR/lame"
    if [ ! -d "$src" ]; then
        curl -sL "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" | tar xz -C "$SRC_DIR"
        mv "$SRC_DIR/lame-$LAME_VERSION" "$src"
    fi
    cd "$src"
    ./configure \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --disable-frontend \
        --disable-decoder \
        --host="aarch64-apple-darwin"
    make -j"$NPROC"
    make install
    log_info "libmp3lame done."
}

build_ogg() {
    log_info "Building libogg $OGG_VERSION..."
    local src="$SRC_DIR/ogg"
    if [ ! -d "$src" ]; then
        git clone --depth 1 --branch "$OGG_VERSION" https://github.com/xiph/ogg.git "$src"
    fi
    cd "$src"
    autoreconf -fiv 2>/dev/null || true
    sed -i '' 's/-force_cpusubtype_ALL//g' configure 2>/dev/null || true
    ./configure \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --host="aarch64-apple-darwin"
    make -j"$NPROC"
    make install
    log_info "libogg done."
}

build_vorbis() {
    log_info "Building libvorbis $VORBIS_VERSION..."
    local src="$SRC_DIR/vorbis"
    if [ ! -d "$src" ]; then
        git clone --depth 1 --branch "$VORBIS_VERSION" https://github.com/xiph/vorbis.git "$src"
    fi
    cd "$src"
    autoreconf -fiv 2>/dev/null || true
    # Patch: newer Xcode linker removed -force_cpusubtype_ALL
    sed -i '' 's/-force_cpusubtype_ALL//g' configure 2>/dev/null || true
    ./configure \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --host="aarch64-apple-darwin" \
        --with-ogg="$PREFIX"
    make -j"$NPROC"
    make install
    log_info "libvorbis done."
}

build_dav1d() {
    log_info "Building dav1d (AV1 decoder)..."
    local src="$SRC_DIR/dav1d"
    if [ ! -d "$src" ]; then
        git clone --depth 1 https://code.videolan.org/videolan/dav1d.git "$src"
    fi
    if ! command -v meson &>/dev/null; then
        log_warn "meson not found, skipping dav1d. Install: brew install meson"
        return 0
    fi
    cd "$src"
    meson setup build \
        --prefix="$PREFIX" \
        --default-library=static \
        --buildtype=release \
        -Denable_tools=false \
        -Denable_tests=false
    ninja -C build
    ninja -C build install
    log_info "dav1d done."
}

build_all_deps() {
    mkdir -p "$SRC_DIR" "$PREFIX"

    build_svtav1
    build_x264
    build_x265
    build_libvpx
    build_opus
    build_lame
    build_ogg
    build_vorbis
    build_dav1d
}

# ==============================================================================
# FFmpeg
# ==============================================================================

build_ffmpeg() {
    log_info "Building FFmpeg with SVT-AV1 support..."
    local src="$SRC_DIR/ffmpeg"
    if [ ! -d "$src" ]; then
        git clone --depth 1 --branch "$FFMPEG_BRANCH" "$FFMPEG_REPO" "$src"
    fi
    cd "$src"

    # Clean previous build if any
    make distclean 2>/dev/null || true

    local sdk_path
    sdk_path="$(xcrun --show-sdk-path)"

    ./configure \
        --arch="$ARCH" \
        --target-os=darwin \
        --cc="$(xcrun --find clang)" \
        --cxx="$(xcrun --find clang++)" \
        --host-cc="$(xcrun --find clang)" \
        --host-cflags="-isysroot $sdk_path" \
        --host-ldflags="-isysroot $sdk_path" \
        --ar=ar \
        --nm=nm \
        --prefix="$BUILD_DIR/dist" \
        --pkg-config=pkg-config \
        --pkg-config-flags=--static \
        --extra-cflags="-I$PREFIX/include -arch $ARCH -isysroot $sdk_path" \
        --extra-ldflags="-L$PREFIX/lib -arch $ARCH -isysroot $sdk_path" \
        --disable-ffplay \
        --disable-autodetect \
        --enable-version3 \
        --enable-runtime-cpudetect \
        --disable-indev=sndio \
        --disable-outdev=sndio \
        --enable-gpl \
        --enable-openssl \
        --enable-zlib \
        --enable-ffprobe \
        --disable-doc \
        --enable-libxml2 \
        --enable-pthreads \
        --disable-w32threads \
        --enable-libvpx \
        --enable-libvorbis \
        --enable-libopus \
        --enable-libx264 \
        --enable-libx265 \
        --enable-libaom \
        --enable-libdav1d \
        --enable-libsvtav1 \
        --enable-libmp3lame \
        --enable-neon

    make -j"$NPROC"

    # Copy to output
    mkdir -p "$OUTPUT_DIR"
    cp ffmpeg "$OUTPUT_DIR/ffmpeg"
    cp ffprobe "$OUTPUT_DIR/ffprobe"
    chmod +x "$OUTPUT_DIR/ffmpeg" "$OUTPUT_DIR/ffprobe"

    log_info "FFmpeg built successfully!"
    log_info "  ffmpeg:  $OUTPUT_DIR/ffmpeg"
    log_info "  ffprobe: $OUTPUT_DIR/ffprobe"

    # Verify SVT-AV1 is included
    if "$OUTPUT_DIR/ffmpeg" -encoders 2>&1 | grep -q libsvtav1; then
        log_info "  libsvtav1: YES"
    else
        log_warn "  libsvtav1: NOT FOUND — check build logs"
    fi
}

# ==============================================================================
# Main
# ==============================================================================

do_clean() {
    log_info "Cleaning build artifacts..."
    rm -rf "$BUILD_DIR"
    log_info "Cleaned: $BUILD_DIR"
}

case "${1:---all}" in
    --deps-only)
        check_prerequisites
        build_all_deps
        ;;
    --ffmpeg-only)
        check_prerequisites
        build_ffmpeg
        ;;
    --clean)
        do_clean
        ;;
    --all|"")
        check_prerequisites
        build_all_deps
        build_ffmpeg
        ;;
    *)
        echo "Usage: $0 [--deps-only|--ffmpeg-only|--clean]"
        echo ""
        echo "  (no args)     build all dependencies + FFmpeg"
        echo "  --deps-only   build dependencies only"
        echo "  --ffmpeg-only build FFmpeg only (deps must already be built)"
        echo "  --clean       remove all build artifacts"
        exit 1
        ;;
esac
