#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/MPFRunnerTests.XXXXXX")"
trap 'find "$test_dir" -depth -delete' EXIT
xcrun clang -fobjc-arc -fmodules -framework Foundation -framework Security \
  "$project_dir/PowerFlow/PrivilegedMetricsRunner.m" \
  "$project_dir/Tests/PrivilegedRunnerTests/main.m" -o "$test_dir/runner-tests"
"$test_dir/runner-tests"
