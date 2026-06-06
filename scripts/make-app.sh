#!/bin/bash
# Assemble a double-clickable ClaudeOS.app from the built executable.
# Usage: scripts/make-app.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
BIN="$ROOT/.build/$CONFIG/claudeos"
APP="$ROOT/ClaudeOS.app"

if [ ! -f "$BIN" ]; then
    echo "Executable not found at $BIN — run: swift build${CONFIG:+ -c $CONFIG}" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeOS"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/packaging/AppIcon.icns" ]; then
    cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "Assembled $APP ($CONFIG)"
