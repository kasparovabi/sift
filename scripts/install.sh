#!/bin/bash
# Build a release, assemble + sign the bundle, and install to /Applications.
#
# Signing: defaults to ad-hoc (runs locally, no keychain prompt). For a stable
# identity or distribution, export CLAUDEOS_SIGN_IDENTITY="Developer ID Application: …"
# (or an Apple Development identity) and re-run; you may need to approve a keychain
# prompt the first time. Notarization additionally requires a Developer ID cert.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/ClaudeOS.app"
DEST="/Applications/Claude OS.app"

IDENTITY="${CLAUDEOS_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
fi

echo "==> Building release (this can take a minute)"
swift build -c release --package-path "$ROOT"

echo "==> Assembling bundle"
"$ROOT/scripts/make-app.sh" release

if [ -n "$IDENTITY" ]; then
    echo "==> Signing with: $IDENTITY"
    codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
else
    echo "==> Ad-hoc signing (local use)"
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --verbose=2 "$APP" 2>&1 | tail -2 || true

echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST" || true

echo "Installed: $DEST"
