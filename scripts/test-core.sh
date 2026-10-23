#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_BUILD_DIR="$PROJECT_ROOT/.build/core-checks"
mkdir -p "$CHECK_BUILD_DIR"

# Run without XCTest, so Apple's Command Line Tools are sufficient.
xcrun swiftc -parse-as-library \
  "$PROJECT_ROOT/Sources/ClipCore/ClipboardItem.swift" \
  "$PROJECT_ROOT/Sources/ClipCore/HistoryRepository.swift" \
  "$PROJECT_ROOT/scripts/check-core.swift" \
  -o "$CHECK_BUILD_DIR/check-core"

"$CHECK_BUILD_DIR/check-core"
