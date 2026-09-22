#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mpf-history-checks.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}" xcrun swiftc \
  -swift-version 6 -strict-concurrency=complete \
  PowerFlow/Core/PowerHistoryCore.swift PowerFlow/PowerHistoryStore.swift \
  Tests/HistoryStoreTests/HistoryStoreChecks.swift -o "$BUILD_DIR/checks"
"$BUILD_DIR/checks"
