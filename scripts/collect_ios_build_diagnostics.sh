#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/unsigned-ios}"
LOG_DIR="$BUILD_DIR/logs"
DIAG_DIR="$BUILD_DIR/diagnostics"
PROJECT="$ROOT_DIR/iosapp/HTTrailiOS.xcodeproj"
SCHEME="${SCHEME:-HTTrailiOS}"

mkdir -p "$DIAG_DIR"

{
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Commit: ${GITHUB_SHA:-unknown}"
  echo "Runner OS: ${RUNNER_OS:-unknown}"
  echo
  xcodebuild -version || true
  swift --version || true
  xcodegen --version || true
} > "$DIAG_DIR/toolchain.txt" 2>&1

xcodebuild -list -project "$PROJECT" > "$DIAG_DIR/xcodebuild-list.txt" 2>&1 || true
xcodebuild -showdestinations -project "$PROJECT" -scheme "$SCHEME" > "$DIAG_DIR/show-destinations.txt" 2>&1 || true
xcodebuild -showBuildSettings -project "$PROJECT" -scheme "$SCHEME" -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO > "$DIAG_DIR/build-settings.txt" 2>&1 || true

find "$ROOT_DIR" -name Package.resolved -type f -print -exec cp {} "$DIAG_DIR/" \; 2>/dev/null || true

if [ -d "$LOG_DIR" ]; then
  cp -R "$LOG_DIR" "$DIAG_DIR/logs" || true
fi

if [ -d "$BUILD_DIR/DerivedData/Logs" ]; then
  cp -R "$BUILD_DIR/DerivedData/Logs" "$DIAG_DIR/DerivedData-Logs" || true
fi

if [ -d "$HOME/Library/Logs/DiagnosticReports" ]; then
  mkdir -p "$DIAG_DIR/DiagnosticReports"
  find "$HOME/Library/Logs/DiagnosticReports" -type f -mtime -1 -maxdepth 1 -exec cp {} "$DIAG_DIR/DiagnosticReports/" \; 2>/dev/null || true
fi

{
  echo "Repository root files:"
  find "$ROOT_DIR" -maxdepth 2 -type f | sort
  echo
  echo "Build directory:"
  find "$BUILD_DIR" -maxdepth 4 -print 2>/dev/null | sort
} > "$DIAG_DIR/file-inventory.txt" 2>&1

cd "$BUILD_DIR"
/usr/bin/zip -qry diagnostics.zip diagnostics
printf '%s\n' "$BUILD_DIR/diagnostics.zip"
