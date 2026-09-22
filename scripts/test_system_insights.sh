#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/macpowerflow-insights-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -default-isolation MainActor -parse-as-library \
    "$project_root/PowerFlow/SystemInsights.swift" \
    "$project_root/Tests/SystemInsightsTests/main.swift" \
    -o "$test_build/SystemInsightsTests"
"$test_build/SystemInsightsTests" "$@"
