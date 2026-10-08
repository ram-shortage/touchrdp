#!/bin/bash
# vendor-libs.sh — bundle the Homebrew FreeRDP dylib closure into TouchRDP.app (M4).
#
# Copies every non-system dylib the app binary (transitively) links into
# Contents/Frameworks, rewrites all load commands to @rpath, adds the rpath,
# then re-signs everything inside-out. After this the app runs on machines
# without Homebrew/FreeRDP installed (same arch + macOS >= the build's target).
#
# Usage:
#   ./Tools/vendor-libs.sh TouchRDP.app
#   SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./Tools/vendor-libs.sh TouchRDP.app
#
# Without SIGN_IDENTITY the result is ad-hoc signed (runs locally only).
# With SIGN_IDENTITY it signs with hardened runtime + Tools/TouchRDP-dev.entitlements.
# NOTE: the vendored tree is whatever Homebrew built — arm64-only, and FFmpeg
# pulls in GPL codecs (x264/x265); fine for personal use, revisit before public distribution.
set -euo pipefail

APP="${1:?usage: vendor-libs.sh <path/to/TouchRDP.app>}"
BIN="$APP/Contents/MacOS/TouchRDP"
FRAMEWORKS="$APP/Contents/Frameworks"
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"
ENTITLEMENTS="$(dirname "$0")/TouchRDP-dev.entitlements"
[[ -x "$BIN" ]] || { echo "error: $BIN not found (build the app first)"; exit 1; }

# PERF-8: the FreeRDP libs come from the pinned from-source build (Vendor/freerdp,
# Tools/build-freerdp.sh — VideoToolbox H.264 decode) when the binary links it, else
# from Homebrew. FFmpeg/OpenSSL/JPEG still come from Homebrew in both cases, so both
# prefixes take part in the closure walk below. Detected from the binary itself so
# this script can't disagree with what Package.swift linked.
FREERDP_PREFIX="${FREERDP_PREFIX:-}"
if [[ -z "$FREERDP_PREFIX" ]]; then
    linked=$(otool -L "$BIN" | awk '/libfreerdp-client3/ {print $1; exit}')
    case "$linked" in
        "$BREW_PREFIX"/*|"") FREERDP_PREFIX="$BREW_PREFIX" ;;
        *) FREERDP_PREFIX="${linked%/lib/*}" ;;
    esac
fi

# --- 0. freshness check: the vendored copy freezes FreeRDP, so ship current bits.
if [[ "$FREERDP_PREFIX" != "$BREW_PREFIX" ]]; then
    ver=$(strings "$FREERDP_PREFIX/lib/libfreerdp3.dylib" 2>/dev/null | grep -m1 -E '^3\.[0-9]+\.[0-9]+' || true)
    echo ">> vendoring pinned from-source FreeRDP ${ver:-?} from $FREERDP_PREFIX"
    # Process substitution, not a pipe: under pipefail `strings | grep -q` reports
    # failure on a match (grep exits early, strings dies with SIGPIPE).
    if grep -q "WITH_VIDEOTOOLBOX=ON" <(strings "$FREERDP_PREFIX/lib/libfreerdp3.dylib" 2>/dev/null); then
        echo "   (VideoToolbox H.264 decode: ON)"
    else
        echo "WARNING: this FreeRDP was NOT built with WITH_VIDEOTOOLBOX=ON (software H.264 decode)"
    fi
    echo "   Check Tools/build-freerdp.sh's FREERDP_VERSION pin against upstream releases"
    echo "   before shipping — security fixes ship in point releases."
elif command -v brew >/dev/null; then
    echo ">> vendoring Homebrew FreeRDP $(brew list --versions freerdp 2>/dev/null | awk '{print $2}')"
    echo "   (no VideoToolbox H.264 decode — run Tools/build-freerdp.sh for the hardware path)"
    outdated=$(brew outdated --quiet freerdp 2>/dev/null || true)
    if [[ -n "$outdated" ]]; then
        echo "WARNING: Homebrew has a newer freerdp (security fixes ship in point releases)."
        echo "         Run 'brew update && brew upgrade freerdp', rebuild, then re-vendor."
        echo "         (Ctrl-C to abort, or continuing in 5s with the installed version...)"
        sleep 5
    fi
fi

# --- 0b. sign-in must not depend on anything outside the bundle ---------------
# NTLM (NLA) hashes the password with MD4. A FreeRDP built without WITH_INTERNAL_MD4
# takes MD4 from OpenSSL 3's legacy provider, which libcrypto dlopens at runtime from
# the absolute Homebrew Cellar path baked into it — a module this script does NOT
# bundle. Such an app signs in only while that exact Homebrew OpenSSL version stays
# installed, and breaks on the next `brew upgrade` (seen with v1.4.3:
# "OpenSSL LEGACY provider failed to load, no md4 support available!").
# Tools/build-freerdp.sh compiles MD4/RC4 in; the Homebrew bottle does not.
if ! grep -q "WITH_INTERNAL_MD4=ON" <(strings "$FREERDP_PREFIX/lib/libfreerdp3.dylib" 2>/dev/null); then
    echo "error: the FreeRDP being vendored ($FREERDP_PREFIX) takes MD4 from OpenSSL's"
    echo "       legacy provider, which is NOT bundled — the app's NLA sign-in would break"
    echo "       whenever Homebrew's OpenSSL changes. Build FreeRDP with Tools/build-freerdp.sh"
    echo "       (WITH_INTERNAL_MD4=ON), rebuild the app, then re-vendor."
    if [[ "${ALLOW_EXTERNAL_MD4:-}" == "1" ]]; then
        echo "       ALLOW_EXTERNAL_MD4=1 set — continuing anyway (local testing only)."
    else
        exit 1
    fi
fi

# --- 1. compute the transitive closure of non-system dylibs -------------------
# Emits "referenced-basename<TAB>real-path" per vendored lib. Libs are stored
# under the exact basename other Mach-Os reference them by (the compat-version
# name, e.g. libavcodec.62.dylib), so every load command maps 1:1 to a file.
# (macOS bash 3.2 has no associative arrays, so the graph walk lives in python.)
CLOSURE=$(BIN="$BIN" BREW_PREFIX="$BREW_PREFIX" FREERDP_PREFIX="$FREERDP_PREFIX" python3 <<'PY'
import os, subprocess

prefixes = tuple(dict.fromkeys(p for p in (os.environ["FREERDP_PREFIX"], os.environ["BREW_PREFIX"]) if p))

def deps(path):
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout
    return [l.split()[0] for l in out.splitlines()[1:] if l.strip()]

def resolve(dep):
    if dep.startswith(prefixes):
        return dep if os.path.exists(dep) else None
    if dep.startswith(("@rpath/", "@loader_path/")):
        for p in prefixes:
            cand = os.path.join(p, "lib", os.path.basename(dep))
            if os.path.exists(cand):
                return cand
        # FreeRDP's channel plugins live one level down (lib/freerdp3/…).
        for p in prefixes:
            cand = os.path.join(p, "lib", "freerdp3", os.path.basename(dep))
            if os.path.exists(cand):
                return cand
        return None
    return None

found = {}   # referenced basename -> realpath
queue = [os.environ["BIN"]]
walked = {os.path.realpath(queue[0])}
while queue:
    for dep in deps(queue.pop()):
        src = resolve(dep)
        if not src:
            continue
        real = os.path.realpath(src)
        found[os.path.basename(dep)] = real
        if real not in walked:
            walked.add(real)
            queue.append(real)
for base, real in sorted(found.items()):
    print(f"{base}\t{real}")
PY
)
COUNT=$(printf '%s\n' "$CLOSURE" | wc -l | tr -d ' ')
echo ">> vendoring $COUNT dylibs into Contents/Frameworks"

# --- 2. copy + rewrite -------------------------------------------------------
rm -rf "$FRAMEWORKS"; mkdir -p "$FRAMEWORKS"
while IFS=$'\t' read -r base real; do
    cp "$real" "$FRAMEWORKS/$base"
    chmod u+w "$FRAMEWORKS/$base"
done <<<"$CLOSURE"

# Rewrite one Mach-O: every load command whose target we vendored -> @rpath/<basename>.
rewrite() {
    local file="$1" dep base args=()
    while IFS= read -r dep; do
        base=$(basename "$dep")
        [[ -e "$FRAMEWORKS/$base" ]] || continue
        [[ "$dep" == "@rpath/$base" ]] && continue
        args+=(-change "$dep" "@rpath/$base")
    done < <(otool -L "$file" | tail -n +2 | awk '{print $1}')
    [[ ${#args[@]} -gt 0 ]] && install_name_tool "${args[@]}" "$file" 2>/dev/null
    return 0
}

while IFS=$'\t' read -r base real; do
    install_name_tool -id "@rpath/$base" "$FRAMEWORKS/$base" 2>/dev/null
    rewrite "$FRAMEWORKS/$base"
done <<<"$CLOSURE"
rewrite "$BIN"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" 2>/dev/null || true

# --- 3. verify nothing still points at Homebrew or the build prefix -----------
leftovers=$(otool -L "$BIN" "$FRAMEWORKS"/*.dylib | grep -c -e "$BREW_PREFIX" -e "$FREERDP_PREFIX" || true)
if [[ "$leftovers" -gt 0 ]]; then
    echo "error: $leftovers load command(s) still reference $BREW_PREFIX or $FREERDP_PREFIX:"
    otool -L "$BIN" "$FRAMEWORKS"/*.dylib | grep -B1 -e "$BREW_PREFIX" -e "$FREERDP_PREFIX" | head -20
    exit 1
fi

# --- 4. re-sign inside-out ---------------------------------------------------
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo ">> signing vendored libs + app with: $SIGN_IDENTITY"
    for lib in "$FRAMEWORKS"/*.dylib; do
        codesign --force --sign "$SIGN_IDENTITY" "$lib" >/dev/null 2>&1
    done
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$APP"
else
    echo ">> ad-hoc signing vendored libs + app"
    for lib in "$FRAMEWORKS"/*.dylib; do
        codesign --force --sign - "$lib" >/dev/null 2>&1
    done
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo ">> done: $APP is self-contained ($(du -sh "$FRAMEWORKS" | awk '{print $1}') of vendored libs)"
