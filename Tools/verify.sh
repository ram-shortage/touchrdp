#!/bin/bash
# Full-package verification (F-22).
#
# Builds EVERY target — including ValidateLive, which `swift run ValidateCore`
# alone never compiles — then runs the headless ValidateCore assertion harness.
# This is the standard pre-commit verify step; a shared-protocol change that
# breaks an unbuilt target fails here instead of landing silently.
#
# Usage: ./Tools/verify.sh          (debug build + ValidateCore)
#        CONFIG=release ./Tools/verify.sh
set -euo pipefail
cd "$(dirname "$0")/.."

export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-/opt/homebrew/lib/pkgconfig}"
CONFIG="${CONFIG:-debug}"

echo ">> swift build ($CONFIG, all targets)…"
swift build -c "$CONFIG"

# Belt-and-braces: name the harness targets explicitly so a SwiftPM behavior
# change (e.g. product-only builds) can never silently drop them again.
echo ">> swift build --product ValidateLive…"
swift build -c "$CONFIG" --product ValidateLive
echo ">> swift build --product ValidateCore…"
swift build -c "$CONFIG" --product ValidateCore

echo ">> swift run ValidateCore…"
swift run -c "$CONFIG" ValidateCore

echo ""
echo "ALL VERIFY STEPS PASSED"
