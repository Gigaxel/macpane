#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
TEST_BIN="$BUILD_DIR/SnapGeometryTests"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"
xcrun swiftc \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  "$ROOT_DIR/Sources/MacPane/SnapGeometry.swift" \
  "$ROOT_DIR/Sources/MacPane/TilingLayout.swift" \
  "$ROOT_DIR/Sources/MacPane/WindowIdentity.swift" \
  "$ROOT_DIR/Sources/MacPane/WindowLayoutIdentity.swift" \
  "$ROOT_DIR/Sources/MacPane/ScreenGeometryExtensions.swift" \
  "$ROOT_DIR/Sources/MacPane/WindowModels.swift" \
  "$ROOT_DIR/Sources/MacPane/WorkspaceStateKeys.swift" \
  "$ROOT_DIR/Sources/MacPane/WindowStateSyncPlanner.swift" \
  "$ROOT_DIR/Sources/MacPane/LayoutRestorePlanner.swift" \
  "$ROOT_DIR/Sources/MacPane/WorkspaceStateMigrator.swift" \
  "$ROOT_DIR/Sources/MacPane/WindowLayoutPlanner.swift" \
  "$ROOT_DIR/Tests/SnapGeometryTests.swift" \
  -o "$TEST_BIN"
"$TEST_BIN"
