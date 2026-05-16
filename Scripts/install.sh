#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SOURCE="$ROOT_DIR/build/MacPane.app"
INSTALL_DIR="${MACPANE_INSTALL_DIR:-$HOME/Applications}"
APP_TARGET="$INSTALL_DIR/MacPane.app"
"$ROOT_DIR/Scripts/build.sh" >/dev/null
mkdir -p "$INSTALL_DIR"
rm -rf "$APP_TARGET"
cp -R "$APP_SOURCE" "$APP_TARGET"
echo "$APP_TARGET"
