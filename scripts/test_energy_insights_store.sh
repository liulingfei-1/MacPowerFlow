#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/macpowerflow-energy-insights.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -default-isolation MainActor -parse-as-library \
    "$project_root/PowerFlow/Core/PowerMetricsCore.swift" \
    "$project_root/PowerFlow/Core/BatteryStateCore.swift" \
    "$project_root/PowerFlow/BatteryReader.swift" \
    "$project_root/PowerFlow/Core/EnergyInsightsCore.swift" \
    "$project_root/PowerFlow/EnergyInsightsStore.swift" \
    "$project_root/PowerFlow/PowerControls.swift" \
    "$project_root/Tests/EnergyInsightsStoreTests/main.swift" \
    -o "$test_build/EnergyInsightsStoreTests"
"$test_build/EnergyInsightsStoreTests" "$@"
