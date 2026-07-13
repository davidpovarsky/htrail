#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ROOT_DIR/iosapp"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/unsigned-ios}"
DERIVED_DATA="$BUILD_DIR/DerivedData"
LOG_DIR="$BUILD_DIR/logs"
RESULT_BUNDLE="$LOG_DIR/HTTrailiOS.xcresult"
PROJECT_PATH="$IOS_DIR/HTTrailiOS.xcodeproj"
SCHEME="${SCHEME:-HTTrailiOS}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_DIR="$BUILD_DIR/app"
PAYLOAD_DIR="$BUILD_DIR/Payload"
IPA_PATH="$BUILD_DIR/HTTrailiOS-unsigned.ipa"

mkdir -p "$BUILD_DIR" "$LOG_DIR" "$APP_DIR"
rm -rf "$DERIVED_DATA" "$RESULT_BUNDLE" "$PAYLOAD_DIR" "$IPA_PATH"

exec > >(tee -a "$LOG_DIR/build-script.log") 2>&1

on_error() {
  local exit_code=$?
  echo "Build failed with exit code $exit_code"
  "$ROOT_DIR/scripts/collect_ios_build_diagnostics.sh" "$BUILD_DIR" || true
  exit "$exit_code"
}
trap on_error ERR

echo "== Environment =="
date -u
uname -a
xcodebuild -version
swift --version

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required but was not found"
  exit 127
fi

cd "$IOS_DIR"

echo "== Generate Xcode project =="
xcodegen generate 2>&1 | tee "$LOG_DIR/xcodegen.log"

echo "== Project metadata =="
xcodebuild -project "$PROJECT_PATH" -list 2>&1 | tee "$LOG_DIR/xcodebuild-list.log"
xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -showBuildSettings 2>&1 | tee "$LOG_DIR/build-settings.log"
xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -showdestinations 2>&1 | tee "$LOG_DIR/destinations.log"

echo "== Resolve packages =="
xcodebuild \
  -resolvePackageDependencies \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED_DATA" \
  2>&1 | tee "$LOG_DIR/resolve-packages.log"

echo "== Build unsigned device app =="
set +e
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  DEVELOPMENT_TEAM='' \
  build \
  2>&1 | tee "$LOG_DIR/xcodebuild.log"
status=${PIPESTATUS[0]}
set -e

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

PRODUCTS_DIR="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos"
APP_PATH="$PRODUCTS_DIR/HTTrailiOS.app"

if [ ! -d "$APP_PATH" ]; then
  APP_PATH="$(find "$PRODUCTS_DIR" -maxdepth 1 -type d -name '*.app' -print -quit)"
fi

if [ -z "${APP_PATH:-}" ] || [ ! -d "$APP_PATH" ]; then
  echo "Built .app bundle was not found in $PRODUCTS_DIR"
  find "$DERIVED_DATA/Build/Products" -maxdepth 3 -print || true
  exit 1
fi

echo "== Package unsigned IPA =="
mkdir -p "$PAYLOAD_DIR"
ditto "$APP_PATH" "$PAYLOAD_DIR/$(basename "$APP_PATH")"
(
  cd "$BUILD_DIR"
  /usr/bin/zip -qry "$(basename "$IPA_PATH")" Payload
)

if [ ! -s "$IPA_PATH" ]; then
  echo "IPA was not created"
  exit 1
fi

/usr/bin/codesign -dvv "$APP_PATH" > "$LOG_DIR/codesign-inspection.log" 2>&1 || true
/usr/bin/otool -L "$APP_PATH/HTTrailiOS" > "$LOG_DIR/otool-main-binary.log" 2>&1 || true
find "$APP_PATH" -maxdepth 4 -type f | sort > "$LOG_DIR/app-file-list.txt"
shasum -a 256 "$IPA_PATH" > "$IPA_PATH.sha256"

"$ROOT_DIR/scripts/collect_ios_build_diagnostics.sh" "$BUILD_DIR" || true

echo "Unsigned IPA created: $IPA_PATH"
