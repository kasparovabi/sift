#!/bin/bash
# Render the app icon and assemble AppIcon.icns into packaging/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="/tmp/claudeos_icon_1024.png"
ICONSET="/tmp/ClaudeOS.iconset"
OUT="$ROOT/packaging/AppIcon.icns"

swift "$ROOT/scripts/icon.swift"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size"            "$MASTER" --out "$ICONSET/icon_${size}x${size}.png"   >/dev/null
    sips -z $((size*2)) $((size*2))    "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "Wrote $OUT"
