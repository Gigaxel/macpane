#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MacPane"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build}"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="$BUILD_ROOT/ModuleCache"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-13.0}"
TARGET_TRIPLE="$(uname -m)-apple-macosx$DEPLOYMENT_TARGET"

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

echo "Building $APP_NAME..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"

SOURCES=("$ROOT_DIR"/Sources/MacPane/*.swift)
xcrun swiftc \
  -O \
  -whole-module-optimization \
  -parse-as-library \
  -target "$TARGET_TRIPLE" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework SwiftUI \
  "${SOURCES[@]}" \
  -o "$MACOS_DIR/$APP_NAME"

echo "Packaging $APP_BUNDLE..."
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Assets/MacPaneIcon.png" "$RESOURCES_DIR/MacPaneIcon.png"
cp "$ROOT_DIR/Assets/MacPane.icns" "$RESOURCES_DIR/MacPane.icns"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

if [[ "${CODESIGN:-1}" == "1" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

echo "Built $APP_BUNDLE"
