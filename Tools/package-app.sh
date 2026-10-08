#!/bin/bash
# Build a REDISTRIBUTABLE TouchRDP.app + .dmg that runs on another Mac with no
# Homebrew / FreeRDP installed.
#
# The normal build (Tools/build-app.sh) links FreeRDP from /opt/homebrew, so the
# bundle only runs on a machine that has the exact Homebrew libs. This script:
#   1. builds the app (release, ad-hoc signed),
#   2. copies the FULL non-system dylib closure (FreeRDP + ffmpeg + OpenSSL + …)
#      into TouchRDP.app/Contents/Frameworks,
#   3. rewrites every load command to @executable_path/@loader_path so nothing
#      points at /opt/homebrew any more,
#   4. re-signs every dylib and the app (ad-hoc), and
#   5. packages a drag-to-install DMG with a README.
#
# Result: TouchRDP.dmg — self-contained, ~22 MB. It is ad-hoc signed (NOT signed
# with a Developer ID nor notarized), so the recipient must clear quarantine once
# (see the README bundled in the DMG). Set SIGN_IDENTITY=... to sign Tier-1.
#
# PORTABILITY CEILING: the bundled Homebrew FreeRDP/ffmpeg/OpenSSL dylibs are
# arm64-only and built with minos = macOS 26.0, so the TARGET Mac must be Apple
# Silicon on macOS 26.0+. (This supersedes the older Tools/package-portable.sh,
# which required the external `dylibbundler` tool and produced a zip.)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="TouchRDP.app"
# All mutation (stamping, dylib bundling, load-path rewrites, re-signing)
# happens on a hidden working copy, swapped into $APP only once fully signed.
# Mutating the live bundle in place means anyone launching it mid-package gets
# SIGKILLed by the kernel ("Code Signature Invalid") — and an interrupted run
# leaves a permanently broken app.
WORK=".TouchRDP.packaging.app"
FRAMEWORKS="$WORK/Contents/Frameworks"
BIN="$WORK/Contents/MacOS/TouchRDP"

# Version stamp so each redistributable is identifiable at a glance. Marketing
# version comes from Info.plist; the build stamp is the git commit date + short
# hash (falls back gracefully outside git). Format: v<ver>-<YYYY.MM.DD>-g<hash>.
PLIST="Tools/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo 0.0.0)"
if git rev-parse --git-dir >/dev/null 2>&1; then
    GIT_HASH="$(git rev-parse --short HEAD)"
    GIT_DATE="$(git show -s --format=%cd --date=format:%Y.%m.%d HEAD)"
    BUILD_NUM="$(git rev-list --count HEAD)"
    [ -z "$(git status --porcelain)" ] && DIRTY="" || DIRTY="-dirty"
else
    GIT_HASH="nogit"; GIT_DATE="00000000"; BUILD_NUM="0"; DIRTY=""
fi
STAMP="v${VERSION}-${GIT_DATE}-g${GIT_HASH}${DIRTY}"
DMG="TouchRDP-${STAMP}.dmg"

# 1) Build the app bundle (reuses the standard builder + signing choice),
#    then take a working copy to mutate — the live $APP stays untouched until
#    the fully-signed swap at the end.
echo ">> building app bundle (${STAMP})…"
CONFIG="${CONFIG:-release}" ./Tools/build-app.sh
rm -rf "$WORK"
cp -R "$APP" "$WORK"

# 1b) Stamp the build into the bundle's Info.plist so About/Finder shows it too.
#     (Patched before the final re-sign below so the signature stays valid.)
BUNDLE_PLIST="$WORK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion ${BUILD_NUM}" "$BUNDLE_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString ${VERSION} (${GIT_DATE} ${GIT_HASH}${DIRTY})" "$BUNDLE_PLIST" 2>/dev/null || true

# 1c) Refuse to package a FreeRDP whose NLA sign-in depends on a file this script
#     does not bundle. NTLM hashes the password with MD4; without WITH_INTERNAL_MD4,
#     FreeRDP takes it from OpenSSL 3's legacy provider, which the bundled libcrypto
#     dlopens from the absolute Homebrew Cellar path baked in at its build. The app
#     then signs in only while that exact Homebrew OpenSSL version stays installed —
#     v1.4.3 shipped like this and every connect failed after a `brew upgrade`
#     ("OpenSSL LEGACY provider failed to load, no md4 support available!").
#     Tools/build-freerdp.sh compiles MD4/RC4 in; the Homebrew bottle does not.
LINKED_FREERDP="$(otool -L "$BIN" | awk '/libfreerdp3\./ {print $1; exit}')"
if ! grep -q "WITH_INTERNAL_MD4=ON" <(strings "$LINKED_FREERDP" 2>/dev/null); then
    echo "error: the linked FreeRDP (${LINKED_FREERDP:-not found}) takes MD4 from OpenSSL's"
    echo "       legacy provider, which is not bundled — NLA sign-in would break whenever"
    echo "       Homebrew's OpenSSL changes. Run Tools/build-freerdp.sh (WITH_INTERNAL_MD4=ON)"
    echo "       and package again."
    if [[ "${ALLOW_EXTERNAL_MD4:-}" == "1" ]]; then
        echo "       ALLOW_EXTERNAL_MD4=1 set — continuing anyway (local testing only)."
    else
        rm -rf "$WORK"; exit 1
    fi
fi

# 2+3) Bundle the dylib closure and rewrite load paths.
echo ">> bundling dylib closure into ${FRAMEWORKS}…"
rm -rf "$FRAMEWORKS"
mkdir -p "$FRAMEWORKS"

python3 - "$BIN" "$FRAMEWORKS" <<'PY'
import os, re, shutil, subprocess, sys
binpath, fw = sys.argv[1], sys.argv[2]

def otool_deps(path):
    out = subprocess.check_output(["otool", "-L", path], text=True, stderr=subprocess.DEVNULL)
    deps = []
    for line in out.splitlines()[1:]:               # line 0 is the "path:" header
        m = re.match(r'\s+(\S+)\s+\(', line)
        if m:
            deps.append(m.group(1))
    return deps

def is_system(p):
    return p.startswith("/usr/lib") or p.startswith("/System")

# --- Build the transitive closure of non-system dylibs (keyed by realpath) ---
seeds = [d for d in otool_deps(binpath) if not is_system(d) and not d.startswith("@")]
real2base = {}          # realpath -> basename we copy it under
queue = list(seeds)
while queue:
    ref = queue.pop()
    real = os.path.realpath(ref)
    if real in real2base:
        continue
    if is_system(real):
        continue
    real2base[real] = os.path.basename(real)
    for d in otool_deps(real):
        if is_system(d) or d.startswith("@"):
            continue
        queue.append(d)

# Guard against basename collisions (different libs, same file name).
bases = {}
for real, base in real2base.items():
    bases.setdefault(base, []).append(real)
for base, reals in bases.items():
    if len(reals) > 1:
        sys.exit(f"ERROR: basename collision for {base}: {reals}")

# --- Copy every lib into Frameworks/ (writable) ---
for real, base in real2base.items():
    dst = os.path.join(fw, base)
    shutil.copy2(real, dst)
    os.chmod(dst, 0o644)

def resolve_base(ref):
    """Map a literal load-command path to the basename we bundled it as (or None)."""
    return real2base.get(os.path.realpath(ref))

def rewrite(path, is_main):
    own_real = None if is_main else os.path.realpath(path)
    for ref in otool_deps(path):
        if is_system(ref) or ref.startswith("@"):
            continue
        base = resolve_base(ref)
        if base is None:
            continue
        # Skip a dylib's own id entry (handled separately below).
        if not is_main and os.path.realpath(ref) == own_real:
            continue
        newref = (f"@executable_path/../Frameworks/{base}" if is_main
                  else f"@loader_path/{base}")
        subprocess.check_call(["install_name_tool", "-change", ref, newref, path])
    if not is_main:
        subprocess.check_call(["install_name_tool", "-id",
                               f"@rpath/{os.path.basename(path)}", path])

for base in real2base.values():
    rewrite(os.path.join(fw, base), is_main=False)
rewrite(binpath, is_main=True)

print(f"   bundled {len(real2base)} dylibs")
PY

# 4) Re-sign every dylib (install_name_tool invalidated them), then the app last.
#    Same identity ladder as build-app.sh: Tier-1 identity > stable local self-signed
#    cert (keeps saved passwords + endpoint-security verdicts across rebuilds) > ad-hoc.
echo ">> re-signing bundled dylibs + app…"
LOCAL_SIGN_IDENTITY="${LOCAL_SIGN_IDENTITY:-MyCodeSign}"
local_identity_usable() {
    local t rc; t="$(mktemp)"; cp /usr/bin/true "$t"
    codesign --force --sign "$LOCAL_SIGN_IDENTITY" "$t" >/dev/null 2>&1; rc=$?
    rm -f "$t"; return $rc
}
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGN_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY")
    APP_SIGN_ARGS=(--force --options runtime --entitlements Tools/TouchRDP-signed.entitlements --sign "$SIGN_IDENTITY")
elif local_identity_usable; then
    SIGN_ARGS=(--force --sign "$LOCAL_SIGN_IDENTITY")
    APP_SIGN_ARGS=(--force --sign "$LOCAL_SIGN_IDENTITY")
else
    SIGN_ARGS=(--force --sign -)
    APP_SIGN_ARGS=(--force --sign -)
fi
find "$FRAMEWORKS" -name '*.dylib' -exec codesign "${SIGN_ARGS[@]}" {} \;
codesign "${APP_SIGN_ARGS[@]}" "$WORK"

# Verify NOTHING still points at Homebrew (the whole point).
echo ">> verifying the bundle is self-contained…"
LEAKS=$( { otool -L "$BIN"; find "$FRAMEWORKS" -name '*.dylib' -exec otool -L {} \; ; } \
         | grep -c '/opt/homebrew' || true )
if [[ "$LEAKS" -ne 0 ]]; then
    echo "ERROR: $LEAKS load command(s) still reference /opt/homebrew — not redistributable." >&2
    exit 1
fi
codesign --verify --deep --strict "$WORK" && echo "   signature OK; no /opt/homebrew references."

# Swap the fully-signed, self-contained bundle into place.
rm -rf "$APP"
mv "$WORK" "$APP"

# 5) Package a drag-to-install DMG with a README.
echo ">> building ${DMG}…"
STAGE="$(mktemp -d)/TouchRDP"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
TouchRDP — install
==================
REQUIREMENTS (important): this build runs only on
  * Apple Silicon Macs (M-series), AND
  * macOS 26.0 or newer.
The bundled FreeRDP libraries are arm64-only and built against macOS 26. It will
NOT launch on an Intel Mac or on macOS 15 or earlier.

1. Drag TouchRDP to the Applications folder shown here.

2. First launch (required once): this build is ad-hoc signed, not notarized by
   Apple, so macOS Gatekeeper will block it by default. To allow it, open Terminal
   and run:

       xattr -dr com.apple.quarantine /Applications/TouchRDP.app

   then double-click TouchRDP normally. (Alternatively: right-click the app →
   Open → Open — but the xattr command is the reliable route if you see
   "TouchRDP is damaged" after downloading.)

Everything TouchRDP needs (FreeRDP and its libraries) is bundled inside the app —
no Homebrew or other install is required.
TXT

# Drop any older DMGs (stale unversioned + prior stamps) so the newest is unambiguous.
rm -f TouchRDP.dmg TouchRDP-v*.dmg
hdiutil create -volname "TouchRDP ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

echo ""
echo "Built redistributable: $(pwd)/$DMG  ($(du -h "$DMG" | cut -f1))"
echo "Version: ${VERSION}  build ${BUILD_NUM}  (${GIT_DATE} ${GIT_HASH}${DIRTY})"
echo "Share this .dmg. The recipient drags TouchRDP to Applications and runs the"
echo "one-time xattr command in 'READ ME FIRST.txt' to clear Gatekeeper quarantine."
