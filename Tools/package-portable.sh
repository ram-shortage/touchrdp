#!/bin/bash
# Produce a SELF-CONTAINED, copyable TouchRDP.app that does NOT require Homebrew /
# FreeRDP on the target machine. Bundles all non-system dylibs inside the .app,
# rewrites their load paths, re-signs ad-hoc, and zips the result.
#
#   ./Tools/package-portable.sh
#
# PORTABILITY CEILING (important): the bundled FreeRDP dylibs are built with
# minos = macOS 26.0, so the target Mac must be **Apple Silicon, macOS 26.0+**.
set -euo pipefail
cd "$(dirname "$0")/.."

export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-/opt/homebrew/lib/pkgconfig}"
APP="TouchRDP.app"
LIBS="$APP/Contents/libs"
MAIN="$APP/Contents/MacOS/TouchRDP"

echo ">> 1. building + assembling base bundle (ad-hoc, Tier-2 vault)…"
./Tools/build-app.sh

echo ">> 2. bundling dylibs into $LIBS and rewriting load paths…"
# dylibbundler recursively copies every non-system dependency, rewrites install
# names to @executable_path/../libs, and fixes the main binary.
rm -rf "$LIBS"; mkdir -p "$LIBS"
dylibbundler -of -b -cd \
    -x "$MAIN" \
    -d "$LIBS" \
    -p "@executable_path/../libs/" \
    -s /opt/homebrew/lib

echo ">> 2b. de-duplicating LC_RPATH (dylibbundler can create duplicates dyld rejects)…"
# dylibbundler rewrites every existing rpath to the same value, producing duplicate
# LC_RPATH entries that make dyld abort ("duplicate LC_RPATH"). Swift runtime libs
# are referenced by absolute /usr/lib/swift paths (present on every macOS), so the
# only rpath we need is the bundled-libs dir. Strip them all, add exactly one.
while otool -l "$MAIN" | grep -q "LC_RPATH"; do
    rp=$(otool -l "$MAIN" | awk '/cmd LC_RPATH/{f=1} f && $1=="path"{print $2; exit}')
    [ -z "$rp" ] && break
    install_name_tool -delete_rpath "$rp" "$MAIN" 2>/dev/null || break
done
install_name_tool -add_rpath "@executable_path/../libs/" "$MAIN"
echo "   rpaths now: $(otool -l "$MAIN" | awk '/cmd LC_RPATH/{f=1} f && $1=="path"{print $2; f=0}' | tr '\n' ' ')"

echo ">> 3. re-signing (ad-hoc) bundled libs + app…"
find "$LIBS" -type f \( -name "*.dylib" -o -name "*.so" \) -exec codesign --force --sign - {} \; 2>/dev/null || true
codesign --force --sign - "$APP"

echo ">> 4. verifying no Homebrew/absolute paths remain in the main binary…"
if otool -L "$MAIN" | grep -E "/opt/homebrew|/usr/local" ; then
    echo "   !! WARNING: absolute Homebrew paths still present above — not fully portable."
else
    echo "   OK: main binary references only @executable_path / system libs."
fi
echo "   bundled lib count: $(ls -1 "$LIBS" 2>/dev/null | wc -l | tr -d ' ')"

echo ">> 5. writing INSTALL note + zipping…"
cat > TouchRDP-INSTALL.txt <<'EOF'
TouchRDP — portable local build
================================
Requirements on the target Mac:
  * Apple Silicon (arm64)
  * macOS 26.0 or newer   (hard requirement — bundled FreeRDP needs it)

Install / run:
  1. Copy TouchRDP.app to /Applications (or anywhere).
  2. Because this is an ad-hoc-signed local build, Gatekeeper will block it on
     first launch. Do ONE of:
       a) Right-click the app -> Open -> Open (confirm the dialog), OR
       b) In Terminal:  xattr -dr com.apple.quarantine /path/to/TouchRDP.app
  3. Launch it. Add a connection, enter the password once (stored under Touch ID),
     then Connect.

Vault tier: this build is ad-hoc-signed, so it uses the Tier-2 "Touch ID gated"
vault (works without an Apple Developer account). See docs/ENABLE_SECURE_ENCLAVE.md
to upgrade to Secure-Enclave (Tier 1).

GPO / "always prompt for password" hosts:
  Credentials are injected at the NLA layer. If the host's Group Policy forces an
  interactive prompt (e.g. "Always prompt for password upon connection") the
  Windows logon/lock screen will appear INSIDE the session for you to complete —
  that is expected behavior, not a failure.
EOF

rm -f TouchRDP-portable.zip
ditto -c -k --keepParent "$APP" TouchRDP-portable.zip

echo ""
echo "DONE."
echo "  App:  $(pwd)/$APP   (self-contained)"
echo "  Zip:  $(pwd)/TouchRDP-portable.zip   ($(du -h TouchRDP-portable.zip | cut -f1))"
echo "  Note: $(pwd)/TouchRDP-INSTALL.txt"
