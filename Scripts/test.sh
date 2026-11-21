#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_ROOT:-$ROOT_DIR/build}"
TEST_BIN="$BUILD_DIR/TilingTests"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

# Every source file except the app entry point, so the tests can never drift from the app.
SOURCES=()
for source in "$ROOT_DIR"/Sources/MacPane/*.swift; do
  [[ "$(basename "$source")" == "main.swift" ]] || SOURCES+=("$source")
done

xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework SwiftUI \
  "${SOURCES[@]}" \
  "$ROOT_DIR"/Tests/*.swift \
  -o "$TEST_BIN"
"$TEST_BIN"
