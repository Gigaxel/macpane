#!/usr/bin/env bash
# Runs the real tiler against real windows that the test process opens itself. Needs a logged-in
# desktop session, and moves only its own windows. It does not need Accessibility permission: the
# test moves its windows directly, because a process cannot reach its own through Accessibility.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_ROOT:-$ROOT_DIR/build}"
TEST_BIN="$BUILD_DIR/IntegrationTests"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

SOURCES=()
for source in "$ROOT_DIR"/Sources/MacPane/*.swift; do
  [[ "$(basename "$source")" == "main.swift" ]] || SOURCES+=("$source")
done

xcrun swiftc \
  -O \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework SwiftUI \
  "${SOURCES[@]}" \
  "$ROOT_DIR"/Tests/Integration/*.swift \
  -o "$TEST_BIN"
"$TEST_BIN" "$@"
# Once more on the public APIs alone, as on a macOS release without the private calls.
MACPANE_DISABLE_SKYLIGHT=1 "$TEST_BIN" "$@"
