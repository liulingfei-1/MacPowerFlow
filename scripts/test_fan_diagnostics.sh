#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mpf-fan-checks.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
xcrun clang -c PowerFlow/SMC.c -o "$BUILD_DIR/SMC.o"
xcrun clang -fobjc-arc -fmodules -c PowerFlow/IOReportWrapper.m -o "$BUILD_DIR/IOReport.o"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -import-objc-header PowerFlow/PowerFlow-Bridging-Header.h \
  PowerFlow/Core/PowerMetricsCore.swift PowerFlow/Core/BatteryStateCore.swift \
  PowerFlow/BatteryReader.swift PowerFlow/HardwareSampler.swift \
  Tests/FanDiagnosticsTests/main.swift "$BUILD_DIR/SMC.o" "$BUILD_DIR/IOReport.o" \
  -framework Foundation -framework IOKit -Xlinker -weak-lIOReport -o "$BUILD_DIR/checks"
"$BUILD_DIR/checks" "$@"
