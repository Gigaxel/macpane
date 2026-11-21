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

# macOS ties the Accessibility grant to the app's signature. An ad-hoc signature changes with every
# build, so the grant is lost each time; a signing identity keeps it. Set CODESIGN_IDENTITY to pick
# one, or leave it unset to use the first development identity in the keychain.
if [[ "${CODESIGN:-1}" == "1" ]] && command -v codesign >/dev/null 2>&1; then
  IDENTITY="${CODESIGN_IDENTITY:-}"
  if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
  fi
  if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$APP_BUNDLE" >/dev/null 2>&1; then
    echo "Signed with $IDENTITY"
  else
    codesign --force --sign - "$APP_BUNDLE" >/dev/null
    echo "Signed ad hoc"
  fi
fi

echo "Built $APP_BUNDLE"
