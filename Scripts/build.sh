#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/MacPane.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
DEPLOYMENT_TARGET="13.0"
TARGET_TRIPLE="$(uname -m)-apple-macosx$DEPLOYMENT_TARGET"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"
xcrun swiftc \
  -O \
  -whole-module-optimization \
  -parse-as-library \
  -target "$TARGET_TRIPLE" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  "$ROOT_DIR/Sources/MacPane/SnapGeometry.swift" \
  "$ROOT_DIR/Sources/MacPane/TilingLayout.swift" \
  "$ROOT_DIR/Sources/MacPane/WindowIdentity.swift" \
  "$ROOT_DIR/Sources/MacPane/WindowLayoutIdentity.swift" \
  "$ROOT_DIR/Sources/MacPane/main.swift" \
  -o "$MACOS_DIR/MacPane"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Assets/MacPaneIcon.png" "$RESOURCES_DIR/MacPaneIcon.png"
cp "$ROOT_DIR/Assets/MacPane.icns" "$RESOURCES_DIR/MacPane.icns"
codesign --force --deep --sign - "$APP_DIR" >/dev/null
echo "$APP_DIR"
