#!/usr/bin/env bash
# Package the SwiftUI executable into a proper macOS .app bundle so the window
# server treats it as a real foreground app (and so it's distributable).
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building HTTrail ($CONFIG)…"
swift build -c "$CONFIG" --product HTTrail

BIN="$(swift build -c "$CONFIG" --product HTTrail --show-bin-path)/HTTrail"
APP="$ROOT/dist/HTTrail.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HTTrail"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# App icon (generate from branding/logo.svg if missing).
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
  "$ROOT/scripts/make_icons.sh" || true
fi
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc codesign so WKWebView / network APIs run without Gatekeeper friction.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $APP"
