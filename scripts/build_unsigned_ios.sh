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
IPA_PATH="$BUILD_DIR/HT