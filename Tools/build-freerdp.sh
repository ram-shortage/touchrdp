#!/bin/bash
# build-freerdp.sh — build a PINNED FreeRDP from source, with VideoToolbox H.264
# decoding, and install it under Vendor/freerdp (git-ignored).
#
# Why:
#   * The Homebrew freerdp bottle is built without -DWITH_VIDEOTOOLBOX=ON, so every
#     AVC420/AVC444 (H.264) GFX frame is decoded in software by libavcodec. FreeRDP
#     3.31's ffmpeg backend has a VideoToolbox path, but only when compiled in; once
#     it is, the decoder uses the hardware unconditionally and falls back to software
#     if the VT session can't be created. No app code needs to opt in.
#   * A from-source build pins the exact FreeRDP release (sha256-verified tarball) and
#     drops the bottle's experimental/debug flags (WITH_VERBOSE_WINPR_ASSERT, the
#     "might crash" banner), which the security review flagged.
#
# Package.swift prefers Vendor/freerdp automatically when it exists (or set
# TOUCHRDP_FREERDP_PREFIX=/path to point anywhere). Tools/vendor-libs.sh bundles
# from the same prefix. Delete Vendor/freerdp to go back to Homebrew.
#
# Usage:
#   ./Tools/build-freerdp.sh            # build + install + verify
#   FREERDP_VERSION=3.31.1 FREERDP_SHA256=<tarball sha256> ./Tools/build-freerdp.sh
#
# Deps (Homebrew): cmake pkgconf openssl@3 ffmpeg jpeg-turbo. FFmpeg's Homebrew build
# enables --enable-videotoolbox, which is what FreeRDP's VT path calls into.
set -euo pipefail
cd "$(dirname "$0")/.."

# Pin. The tarball is the GitHub release archive (same URL + sha256 Homebrew pins).
FREERDP_VERSION="${FREERDP_VERSION:-3.32.1}"
FREERDP_SHA256="${FREERDP_SHA256:-8803dd26ec9660550252f255cf2d672a785ddd8f544bb475834993e96807c87f}"

PREFIX="$(pwd)/Vendor/freerdp"
WORK="${FREERDP_BUILD_DIR:-$(pwd)/.build/freerdp}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix 2>/dev/null || echo /opt/homebrew)}"
MACOS_TARGET="${MACOS_TARGET:-14.0}"
# SDK: must not be NEWER than the macOS this build will run on. CMake's symbol
# probes (check_symbol_exists) trust the SDK headers, so a newer SDK can turn on
# e.g. WINPR_HAVE_PIPE2; the symbol then becomes a weak import that resolves to
# NULL on the older OS and winpr_event_init jumps to 0x0 at the first CreateEvent
# (SIGSEGV in rdpbridge_create). Command Line Tools may default to a beta SDK, so
# pin one with SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX<ver>.sdk
# (the same value build-app.sh / swift build honour).
SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null || echo "")}"

# --- 0. dependencies ----------------------------------------------------------
missing=()
for dep in cmake pkgconf openssl@3 ffmpeg jpeg-turbo; do
    brew list --versions "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: missing Homebrew packages: ${missing[*]}"
    echo "       brew install ${missing[*]}"
    exit 1
fi
if ! otool -L "$BREW_PREFIX/opt/ffmpeg/lib/libavcodec.dylib" 2>/dev/null | grep -q VideoToolbox; then
    echo "error: Homebrew ffmpeg's libavcodec does not link VideoToolbox.framework;"
    echo "       FreeRDP's hardware path needs an ffmpeg built with --enable-videotoolbox."
    exit 1
fi

# --- 1. fetch + verify the pinned source -------------------------------------
mkdir -p "$WORK"
TARBALL="$WORK/FreeRDP-$FREERDP_VERSION.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
    echo ">> downloading FreeRDP $FREERDP_VERSION"
    curl -fsSL -o "$TARBALL" \
        "https://github.com/FreeRDP/FreeRDP/archive/refs/tags/$FREERDP_VERSION.tar.gz"
fi
echo ">> verifying sha256"
echo "$FREERDP_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null
SRC="$WORK/FreeRDP-$FREERDP_VERSION"
rm -rf "$SRC"
tar -xzf "$TARBALL" -C "$WORK"
[[ -f "$SRC/CMakeLists.txt" ]] || { echo "error: unexpected tarball layout"; exit 1; }

# TouchRDP patches (Tools/freerdp-patches/*.patch, applied in name order against the
# pristine tree). Keep each one tiny and documented in its own header; the bridge must
# keep working WITHOUT them (it dlsym()s anything they add) so Homebrew stays a fallback.
for p in "$(pwd)/Tools/freerdp-patches"/*.patch; do
    [[ -e "$p" ]] || continue
    echo ">> applying $(basename "$p")"
    patch -p1 -d "$SRC" --forward --silent < "$p"
done

# --- 2. configure -------------------------------------------------------------
# Client libraries + client channel plugins only: no xfreerdp/SDL binaries, no
# server/shadow/proxy, no samples/tests/manpages. Everything TouchRDP's bridge uses
# stays on: GFX/H.264 via ffmpeg (+VideoToolbox), progressive/RFX/NSC/ClearCodec,
# cliprdr, disp, rdpsnd (mac backend), rdpdr drive + printer (CUPS), rdpgfx.
#
# WITH_INTERNAL_MD4 / WITH_INTERNAL_RC4: use WinPR's compiled-in MD4 and RC4 rather
# than OpenSSL's. OpenSSL 3 only has them in its "legacy" provider — a separate module
# libcrypto dlopens at runtime from the absolute MODULESDIR baked in at OpenSSL's build
# (/opt/homebrew/Cellar/openssl@3/<version>/lib/ossl-modules). vendor-libs.sh bundles
# libcrypto but not that module, so the app silently depended on that exact Homebrew
# OpenSSL version staying installed. NTLM hashes the password with MD4, so when a
# Homebrew upgrade removed the old version every NLA sign-in failed:
#   "OpenSSL LEGACY provider failed to load, no md4 support available!"
#   -> "Failed to initialize digest md4" -> SEC_E_NO_CREDENTIALS.
# Compiled in, sign-in no longer touches any file outside the bundle. RC4 has the same
# dependency (licensing, RDP security, auto-reconnect cookies).
echo ">> configuring (VideoToolbox H.264 decode ON; SDK: ${SDKROOT:-cmake default}; host macOS $(sw_vers -productVersion))"
sdk_version="$(plutil -extract Version raw "${SDKROOT:-/nonexistent}/SDKSettings.plist" 2>/dev/null || true)"
host_major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ -n "$sdk_version" && "${sdk_version%%.*}" -gt "$host_major" ]]; then
    echo "warning: SDK $sdk_version is newer than host macOS $(sw_vers -productVersion); the result"
    echo "         may crash at runtime (weak-imported symbols). Set SDKROOT to a matching SDK:"
    ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.*.sdk 2>/dev/null | sed 's/^/           /'
fi
rm -rf "$WORK/build"   # the SDK is baked into the cache; never reuse it across SDK switches
cmake -S "$SRC" -B "$WORK/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_TARGET" \
    ${SDKROOT:+-DCMAKE_OSX_SYSROOT="$SDKROOT"} \
    -DCMAKE_PREFIX_PATH="$BREW_PREFIX/opt/openssl@3;$BREW_PREFIX/opt/ffmpeg;$BREW_PREFIX/opt/jpeg-turbo" \
    -DOPENSSL_ROOT_DIR="$BREW_PREFIX/opt/openssl@3" \
    -DBUILD_SHARED_LIBS=ON \
    -DWITH_VIDEOTOOLBOX=ON -DWITH_FFMPEG_HWACCEL=ON \
    -DWITH_FFMPEG=ON -DWITH_VIDEO_FFMPEG=ON -DWITH_DSP_FFMPEG=ON -DWITH_SWSCALE=ON \
    -DWITH_OPENH264=OFF \
    -DWITH_JPEG=ON \
    -DWITH_MACAUDIO=ON \
    -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT=OFF \
    -DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_SDL2=OFF -DWITH_CLIENT_SDL3=OFF \
    -DWITH_X11=OFF -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF \
    -DWITH_MANPAGES=OFF -DWITH_WEBVIEW=OFF -DBUILD_TESTING=OFF -DWITH_WINPR_TOOLS=OFF \
    -DCHANNEL_URBDRC=OFF -DCHANNEL_RDPEWA=OFF \
    -DWITH_AAD=OFF \
    -DWITH_VERBOSE_WINPR_ASSERT=OFF \
    -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON \
    -Wno-dev

# --- 3. build + install -------------------------------------------------------
echo ">> building with $JOBS jobs"
cmake --build "$WORK/build" -j"$JOBS"
rm -rf "$PREFIX"
cmake --install "$WORK/build" >/dev/null

# --- 4. verify what we got ----------------------------------------------------
CORE="$PREFIX/lib/libfreerdp3.dylib"
CLIENT="$PREFIX/lib/libfreerdp-client3.dylib"
for f in "$CORE" "$CLIENT" "$PREFIX/lib/libwinpr3.dylib" \
         "$PREFIX/include/freerdp3/freerdp/freerdp.h" "$PREFIX/include/winpr3/winpr/winpr.h"; do
    [[ -e "$f" ]] || { echo "error: expected $f after install"; exit 1; }
done
# freerdp_get_build_config() embeds "WITH_<opt>=<value>" for every option; the bridge
# reads the same string at runtime (rdpbridge_h264_hw_decode_available).
# (grep reads from a file, not a pipe: with pipefail, `strings | grep -q` fails on a
# match because grep exits early and strings dies with SIGPIPE.)
CORE_STRINGS="$WORK/libfreerdp3.strings"
strings "$CORE" > "$CORE_STRINGS"
if grep -q "WITH_VIDEOTOOLBOX=ON" "$CORE_STRINGS"; then
    echo ">> OK: libfreerdp3 built with WITH_VIDEOTOOLBOX=ON"
else
    echo "error: libfreerdp3 does not report WITH_VIDEOTOOLBOX=ON (check the cmake output"
    echo "       for 'VideoToolbox' — it needs WITH_VIDEO_FFMPEG and an Apple target)"
    exit 1
fi
if grep -q "WITH_VERBOSE_WINPR_ASSERT=ON" "$CORE_STRINGS"; then
    echo "warning: WITH_VERBOSE_WINPR_ASSERT is still ON"
fi
# NTLM's MD4 (and RC4) must be compiled in, never borrowed from OpenSSL's legacy
# provider — see the configure note above. A hard error: without it NLA sign-in
# breaks the moment Homebrew's OpenSSL version changes.
for opt in WITH_INTERNAL_MD4 WITH_INTERNAL_RC4; do
    if grep -q "$opt=ON" "$CORE_STRINGS"; then
        echo ">> OK: $opt=ON (no runtime dependency on OpenSSL's legacy provider)"
    else
        echo "error: libfreerdp3 does not report $opt=ON — NTLM sign-in would depend on"
        echo "       Homebrew's OpenSSL legacy module at runtime"
        exit 1
    fi
done
# Weak-undefined libSystem imports are symbols the SDK declared but the deployment
# target can't guarantee; each one is NULL (-> SIGSEGV on call) on a host older than
# the SDK. Seen with pipe2 (macOS 27 SDK on a 26 host). Empty output is the goal.
weak="$(nm -m "$PREFIX/lib/libwinpr3.dylib" "$CORE" "$CLIENT" 2>/dev/null \
        | grep "(undefined) weak external" | grep "from libSystem" | awk '{print $(NF-2)}' | sort -u || true)"
if [[ -n "$weak" ]]; then
    echo "warning: weak-imported libSystem symbols (NULL on a host older than the SDK):"
    echo "$weak" | sed 's/^/   /'
fi
# All client channels + subsystems (cliprdr, rdpsnd/mac, rdpgfx, disp, rdpdr, drive,
# printer/cups) are OBJECT libraries compiled INTO libfreerdp-client3 in 3.x shared
# builds — nothing is dlopen'd from lib/freerdp3, so vendor-libs.sh's otool walk
# captures everything. Show the ffmpeg linkage the VT path relies on.
echo ">> libfreerdp3 links:"
otool -L "$CORE" | grep -E "avcodec|avutil|swscale" | sed 's/^/   /'

# SwiftPM caches the evaluated manifest; nudge it so the prefix switch is picked up.
touch Package.swift
echo ""
echo "Installed FreeRDP $FREERDP_VERSION -> $PREFIX"
echo "Next: ./Tools/build-app.sh   (Package.swift now links Vendor/freerdp instead of Homebrew)"
echo "      run with TOUCHRDP_VERBOSE=1 and look for 'Using videotoolbox [...] for accelerated H264 decoding'"
