#!/usr/bin/env bash
# Rasterize branding/logo.svg into every app-icon artifact both builds need:
#   - iOS:   iosapp/Sources/Assets.xcassets/AppIcon.appiconset (single 1024 png)
#   - macOS: Resources/AppIcon.icns (full iconset via iconutil)
#   - shared: branding/icon-1024.png master + branding/logo-preview.png
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/branding/logo.svg"
[ -f "$SVG" ] || { echo "missing $SVG"; exit 1; }

render() { rsvg-convert -w "$1" -h "$1" "$SVG" -o "$2"; }

# --- master + preview -------------------------------------------------------
render 1024 "$ROOT/branding/icon-1024.png"
render 512  "$ROOT/branding/logo-preview.png"

# --- iOS asset catalog (single-size 1024, modern Xcode format) --------------
IOS_ICONSET="$ROOT/iosapp/Sources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$IOS_ICONSET"
cp "$ROOT/branding/icon-1024.png" "$IOS_ICONSET/icon-1024.png"
cat > "$IOS_ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
cat > "$ROOT/iosapp/Sources/Assets.xcassets/Contents.json" <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON

# --- macOS .icns ------------------------------------------------------------
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
render 16   "$ICONSET/icon_16x16.png"
render 32   "$ICONSET/icon_16x16@2x.png"
render 32   "$ICONSET/icon_32x32.png"
render 64   "$ICONSET/icon_32x32@2x.png"
render 128  "$ICONSET/icon_128x128.png"
render 256  "$ICONSET/icon_128x128@2x.png"
render 256  "$ICONSET/icon_256x256.png"
render 512  "$ICONSET/icon_256x256@2x.png"
render 512  "$ICONSET/icon_512x512.png"
render 1024 "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"

echo "Icons generated:"
echo "  iOS:   $IOS_ICONSET/icon-1024.png"
echo "  macOS: $ROOT/Resources/AppIcon.icns"
echo "  master: $ROOT/branding/icon-1024.png"
