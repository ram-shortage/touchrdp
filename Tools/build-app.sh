#!/bin/bash
# Build TouchRDP.app — a runnable, ad-hoc-signed local bundle (Tier-2 vault).
#
# Default (local dev):   ./Tools/build-app.sh
#   -> release build, assembles TouchRDP.app, ad-hoc signs with NO entitlements
#      (Tier-2 app-gated Touch ID vault — see docs/SECURITY.md).
#
# Secure-Enclave (Tier 1): SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./Tools/build-app.sh
#   -> signs with your identity + Tools/TouchRDP-signed.entitlements (keychain-access-groups),
#      enabling OS-enforced biometric Keychain. See docs/ENABLE_SECURE_ENCLAVE.md.
set -euo pipefail
cd "$(dirname "$0")/.."

export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-/opt/homebrew/lib/pkgconfig}"
CONFIG="${CONFIG:-release}"
APP="TouchRDP.app"
# Stable local signing identity (self-signed "MyCodeSign" cert in the login keychain):
# keeps the app's code-signing identity constant across rebuilds, so keychain items
# (saved passwords) and endpoint-security/firewall verdicts survive a rebuild. Ad-hoc
# signatures are per-binary (cdhash) and orphan saved passwords on EVERY rebuild.
# Falls back to ad-hoc when the cert is absent. Not a distribution identity.
LOCAL_SIGN_IDENTITY="${LOCAL_SIGN_IDENTITY:-MyCodeSign}"
local_identity_usable() {
    local t rc; t="$(mktemp)"; cp /usr/bin/true "$t"
    codesign --force --sign "$LOCAL_SIGN_IDENTITY" "$t" >/dev/null 2>&1; rc=$?
    rm -f "$t"; return $rc
}
# Assemble + sign in a hidden staging bundle, then swap into $APP at the very
# end. Launching $APP mid-build must never map a half-signed binary (the kernel
# SIGKILLs with "Code Signature Invalid" if mapped pages change under dyld).
STAGING=".TouchRDP.staging.app"
CONTENTS="$STAGING/Contents"

# PERF-8: say which FreeRDP this build links (Package.swift picks Vendor/freerdp when
# Tools/build-freerdp.sh has installed it; that build has VideoToolbox H.264 decode).
if [[ -n "${TOUCHRDP_FREERDP_PREFIX:-}" ]]; then
    echo ">> FreeRDP: $TOUCHRDP_FREERDP_PREFIX (TOUCHRDP_FREERDP_PREFIX)"
elif [[ -f Vendor/freerdp/lib/libfreerdp-client3.dylib ]]; then
    echo ">> FreeRDP: Vendor/freerdp (pinned from-source build, VideoToolbox decode)"
else
    echo ">> FreeRDP: Homebrew (software H.264 decode — see Tools/build-freerdp.sh)"
fi
# SDK sanity: Command Line Tools can default to a beta SDK newer than the host OS.
# Symptoms: `SwiftUIMacros.StateMacro ... plugin not found` here, and NULL weak
# imports (SIGSEGV) in Tools/build-freerdp.sh. Pin with
# SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX<host major>.<minor>.sdk
sdk="${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null || true)}"
sdk_version="$(plutil -extract Version raw "${sdk:-/nonexistent}/SDKSettings.plist" 2>/dev/null || true)"
if [[ -n "$sdk_version" && "${sdk_version%%.*}" -gt "$(sw_vers -productVersion | cut -d. -f1)" ]]; then
    echo "warning: SDK $sdk_version is newer than host macOS $(sw_vers -productVersion) — set SDKROOT to one of:"
    ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.*.sdk 2>/dev/null | sed 's/^/           /'
fi
echo ">> swift build ($CONFIG; SDK ${sdk_version:-?})…"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo ">> assembling ${APP}..."
rm -rf "$STAGING"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_PATH/TouchRDP" "$CONTENTS/MacOS/TouchRDP"
cp Tools/Info.plist "$CONTENTS/Info.plist"

# App icon: build a multi-resolution AppIcon.icns from Sources/TouchRDP/Icon.png
# (single source of truth). Skipped gracefully if the source PNG is absent.
ICON_SRC="Sources/TouchRDP/Icon.png"
if [[ -f "$ICON_SRC" ]]; then
    echo ">> generating AppIcon.icns from $ICON_SRC..."
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size"        "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png"      >/dev/null 2>&1
        sips -z $((size*2)) $((size*2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png"   >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
else
    echo ">> (no $ICON_SRC found — building without an app icon)"
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo ">> signing (Tier 1) with identity: $SIGN_IDENTITY"
    codesign --force --options runtime \
        --entitlements Tools/TouchRDP-signed.entitlements \
        --sign "$SIGN_IDENTITY" "$STAGING"
elif local_identity_usable; then
    echo ">> signing (Tier 2) with stable local identity: ${LOCAL_SIGN_IDENTITY}…"
    codesign --force --sign "$LOCAL_SIGN_IDENTITY" "$STAGING"
else
    echo ">> ad-hoc signing (Tier 2, no entitlements)…"
    codesign --force --sign - "$STAGING"
fi

echo ">> verifying signature…"
codesign -dvvv "$STAGING" 2>&1 | grep -E "Identifier|Signature|Authority" || true

# Swap the fully-signed bundle into place (replace, never mutate, the live app).
rm -rf "$APP"
mv "$STAGING" "$APP"

echo ""
echo "Built: $(pwd)/$APP"
echo "Run:   open $(pwd)/$APP   (or:  ./$APP/Contents/MacOS/TouchRDP for console logs)"
