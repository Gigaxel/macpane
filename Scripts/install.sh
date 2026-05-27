#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MacPane"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build}"
INSTALL_DIR="${INSTALL_DIR:-${MACPANE_INSTALL_DIR:-$HOME/Applications}}"
SOURCE_APP="$BUILD_ROOT/$APP_NAME.app"
DEST_APP="$INSTALL_DIR/$APP_NAME.app"

"$ROOT_DIR/Scripts/build-app.sh" "$@"
if [[ ! -d "$SOURCE_APP" ]]; then
  echo "error: expected built app at $SOURCE_APP" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
if [[ -d "$DEST_APP" ]]; then
  echo "Replacing $DEST_APP..."
  rm -rf "$DEST_APP"
fi

echo "Installing $DEST_APP..."
ditto "$SOURCE_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
echo "Installed $DEST_APP"

if [[ "${OPEN_AFTER_INSTALL:-0}" == "1" ]]; then
  open "$DEST_APP"
fi
