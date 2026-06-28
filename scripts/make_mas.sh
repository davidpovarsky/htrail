#!/usr/bin/env bash
# make_mas.sh — build the SANDBOXED Mac App Store variant of HTTrail (HTTRAIL_MAS).
#
# Unlike make_app.sh (un-sandboxed Developer-ID build), this:
#   - compiles with -DHTTRAIL_MAS so SystemProxyController never spawns
#     networksetup/security/osascript (App Sandbox forbids Process);
#   - signs the .app with the App Sandbox + network + user-files entitlements;
#   - (with DISTRIBUTION=1) embeds the Mac App Store provisioning profile and
#     builds a signed installer .pkg for upload to App Store Connect.
#
# Local sandbox test (dev-signed, runs on this Mac):
#   ./scripts/make_mas.sh
# Distribution build (needs the certs/profile/app-record below):
#   DISTRIBUTION=1 ./scripts/make_mas.sh
#
# ⚠️ External gates that are NOT turn-key in this account yet (the script stops
#    with guidance when it hits them):
#   1. Bundle ID — defaults to com.1moby.httrail.mac (the runbook's suggested move
#      off the non-team com.httrail.app). Must be REGISTERED under team D62Y8JVXB9.
#   2. "3rd Party Mac Developer Installer" cert — NOT installed (only the
#      Application variant is). Needed to sign the .pkg. Create it in the portal.
#   3. A Mac App Store provisioning profile for the bundle id, saved to
#      Resources/HTTrail_MAS.provisionprofile.
#   4. A macOS app record in App Store Connect (no API — create in the UI).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${CONFIG:-release}"
BUNDLE_ID="${BUNDLE_ID:-com.1moby.httrail.mac}"
TEAM="${TEAM:-D62Y8JVXB9}"
APP="$ROOT/dist/mas/HTTrail.app"
PKG="$ROOT/dist/mas/HTTrail.pkg"
ENTS="$ROOT/Resources/HTTrail.mas.entitlements"

echo "Building HTTrail MAS ($CONFIG, $BUNDLE_ID)…"
swift build -c "$CONFIG" --product HTTrail -Xswiftc -DHTTRAIL_MAS
BIN="$(swift build -c "$CONFIG" --product HTTrail -Xswiftc -DHTTRAIL_MAS --show-bin-path)/HTTrail"

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HTTrail"

# MAS Info.plist: start from the shared one, override the bundle id and add the
# App Store category (required for MAS). Leaves Resources/Info.plist untouched.
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.developer-tools" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :LSApplicationCategoryType public.app-category.developer-tools" "$APP/Contents/Info.plist"
# iOS and macOS share a CFBundleVersion space within the app record; pick a build
# above the iOS build (1) to avoid an upload collision.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"

# Xcode-injected build metadata that App Store *processing* requires for macOS.
# A hand-bundled SPM app lacks these, so the upload is accepted but the build is
# silently dropped at intake (never reaches PROCESSING). Compute from the toolchain.
PL="$APP/Contents/Info.plist"
SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"
SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
OS_BUILD="$(sw_vers -buildVersion)"
XC_BUILD="$(xcodebuild -version | sed -n 's/^Build version //p')"
XC_VER="$(xcodebuild -version | sed -n 's/^Xcode //p')"
DTXCODE="$(echo "$XC_VER" | awk -F. '{printf "%d%d%d", $1, ($2==""?0:$2), ($3==""?0:$3)}')"
for kv in \
  "CFBundleSupportedPlatforms:array" \
  "DTPlatformName:string:macosx" \
  "DTPlatformVersion:string:$SDK_VER" \
  "DTSDKName:string:macosx$SDK_VER" \
  "DTSDKBuild:string:$SDK_BUILD" \
  "DTPlatformBuild:string:$SDK_BUILD" \
  "DTXcode:string:$DTXCODE" \
  "DTXcodeBuild:string:$XC_BUILD" \
  "DTCompiler:string:com.apple.compilers.llvm.clang.1_0" \
  "BuildMachineOSBuild:string:$OS_BUILD"; do
  key="${kv%%:*}"; rest="${kv#*:}"; typ="${rest%%:*}"; val="${rest#*:}"
  /usr/libexec/PlistBuddy -c "Delete :$key" "$PL" 2>/dev/null || true
  if [ "$typ" = "array" ]; then
    /usr/libexec/PlistBuddy -c "Add :$key array" -c "Add :$key:0 string MacOSX" "$PL"
  else
    /usr/libexec/PlistBuddy -c "Add :$key $typ $val" "$PL"
  fi
done

[ -d "$ROOT/Resources/Fonts" ] && { mkdir -p "$APP/Contents/Resources/Fonts"; cp "$ROOT/Resources/Fonts/"*.ttf "$APP/Contents/Resources/Fonts/" 2>/dev/null || true; }

# Localized UI and Info.plist strings.
if [ -d "$ROOT/Resources/Localizations" ]; then
  find "$ROOT/Resources/Localizations" -maxdepth 1 -type d -name "*.lproj" -exec cp -R {} "$APP/Contents/Resources/" \;
fi

[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# App Store REQUIRES a compiled asset catalog containing the app icon — without it
# the macOS build is rejected at intake with ITMS-90546 (Missing asset catalog).
# actool emits Assets.car (+ AppIcon.icns) and the icon Info.plist keys.
if [ -d "$ROOT/Resources/Assets.xcassets" ]; then
  ICONPLIST="$(mktemp)"
  actool "$ROOT/Resources/Assets.xcassets" --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$ICONPLIST" >/dev/null 2>&1 || true
  [ -f "$APP/Contents/Resources/Assets.car" ] || { echo "❌ actool did not produce Assets.car"; exit 1; }
  for k in CFBundleIconName CFBundleIconFile; do
    val="$(/usr/libexec/PlistBuddy -c "Print :$k" "$ICONPLIST" 2>/dev/null)" && {
      /usr/libexec/PlistBuddy -c "Delete :$k" "$APP/Contents/Info.plist" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Add :$k string $val" "$APP/Contents/Info.plist"
    }
  done
  rm -f "$ICONPLIST"
  echo "Compiled Assets.car ($(du -h "$APP/Contents/Resources/Assets.car" | cut -f1))"
fi

if [ "${DISTRIBUTION:-0}" = "1" ]; then
  APP_IDENTITY="${APP_IDENTITY:-3rd Party Mac Developer Application: 1Moby Co., Ltd. ($TEAM)}"
  PKG_IDENTITY="${PKG_IDENTITY:-3rd Party Mac Developer Installer: 1Moby Co., Ltd. ($TEAM)}"
  PROFILE="$ROOT/Resources/HTTrail_MAS.provisionprofile"
  if [ -f "$PROFILE" ]; then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  else
    echo "⚠️  No $PROFILE — a Mac App Store provisioning profile is required for distribution."
    echo "    Create one for $BUNDLE_ID (team $TEAM) and save it there, then re-run."
    exit 1
  fi
  # Mac App Store: sandbox (NOT hardened runtime) + App Store entitlements that
  # carry application-identifier/team-identifier matching the embedded profile.
  APPSTORE_ENTS="${APPSTORE_ENTS:-$ROOT/Resources/HTTrail.mas.appstore.entitlements}"
  echo "Signing app with: $APP_IDENTITY (entitlements: $APPSTORE_ENTS)"
  codesign --force --timestamp \
    --entitlements "$APPSTORE_ENTS" --sign "$APP_IDENTITY" "$APP"
  if ! security find-identity -v | grep -q "3rd Party Mac Developer Installer"; then
    echo "⚠️  '$PKG_IDENTITY' is not installed — cannot sign the .pkg."
    echo "    Create the 'Mac Installer Distribution' certificate in the Apple Developer portal."
    echo "    The signed .app is at: $APP"
    exit 1
  fi
  echo "Building installer pkg: $PKG"
  productbuild --component "$APP" /Applications --sign "$PKG_IDENTITY" "$PKG"
  echo "Built: $PKG"
  echo "Upload with:  xcrun altool --upload-app -f \"$PKG\" -t macos --apiKey CQHFLUWF22 --apiIssuer 69a6de71-ebf1-47e3-e053-5b8c7c11a4d1"
else
  # Local sandbox test: dev-sign with entitlements so the sandboxed app runs here.
  DEV_IDENTITY="${DEV_IDENTITY:-Apple Development: Anu Vimolkiattisak (7K4XLR6VD4)}"
  echo "Dev-signing (sandbox test) with: $DEV_IDENTITY"
  codesign --force --entitlements "$ENTS" --sign "$DEV_IDENTITY" "$APP" \
    || codesign --force --entitlements "$ENTS" --sign - "$APP"
  echo "Built (sandboxed, local test): $APP"
fi
