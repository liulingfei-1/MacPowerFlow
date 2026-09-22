#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/MPFHardwareTests.XXXXXX")"
trap 'find "$test_dir" -depth -delete' EXIT
xcrun clang -fobjc-arc -fmodules -framework Foundation -framework IOKit \
  "$project_dir/Tests/HardwareSamplerTests/main.m" -o "$test_dir/fixture-tests"
"$test_dir/fixture-tests"
if [[ "${1:-}" == "--live" ]]; then
  xcrun clang -fobjc-arc -fmodules -framework Foundation -framework IOKit -weak-lIOReport \
    "$project_dir/Tests/HardwareSamplerTests/live.m" \
    "$project_dir/PowerFlow/SMC.c" -o "$test_dir/live-tests"
  "$test_dir/live-tests"
fi
