#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
alert_check_dir=$(mktemp -d "${TMPDIR:-/tmp}/mpf-alert-checks.XXXXXX")
trap 'rm -rf "$alert_check_dir"' EXIT
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}" xcrun swiftc \
  -parse-as-library -swift-version 6 -strict-concurrency=complete \
  PowerFlow/Core/PowerAlertRules.swift PowerFlow/PowerAlerts.swift \
  Tests/PowerAlertsPreferenceTests/main.swift -o "$alert_check_dir/checks"
"$alert_check_dir/checks"
