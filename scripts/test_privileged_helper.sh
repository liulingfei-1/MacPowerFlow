#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/MPFHelperTests.XXXXXX")"
trap 'find "$test_dir" -depth -delete' EXIT
python3 - "$project_dir" "$test_dir" <<'PY'
import sys
from pathlib import Path
root,out=map(Path,sys.argv[1:])
source=(root/'Helper/MacPowerFlowHelperMain.swift').read_text()
source=source[:source.index('@main\nprivate enum MacPowerFlowHelperMain')]
(out/'HelperChecks.swift').write_text(source+(root/'Tests/PrivilegedHelperTests/checks.swift').read_text())
PY
xcrun swiftc -swift-version 5 -parse-as-library \
  -import-objc-header "$project_dir/Shared/PrivilegedMetricsXPCProtocol.h" \
  "$project_dir/Shared/MPFPrivilegedService.swift" "$test_dir/HelperChecks.swift" \
  -o "$test_dir/helper-tests"
"$test_dir/helper-tests" "$@"
xcrun clang -fobjc-arc -fmodules -c "$project_dir/PowerFlow/PrivilegedMetricsRunner.m" -o "$test_dir/runner.o"
xcrun swiftc -swift-version 5 -parse-as-library \
  -import-objc-header "$project_dir/PowerFlow/PowerFlow-Bridging-Header.h" \
  "$project_dir/PowerFlow/Core/PowerMetricsCore.swift" \
  "$project_dir/PowerFlow/Core/PowerMetricsFrameDecoder.swift" \
  "$project_dir/PowerFlow/PrivilegedPowerSampler.swift" \
  "$project_dir/Tests/PrivilegedHelperTests/sampler-checks.swift" \
  "$test_dir/runner.o" -framework Security -framework Foundation \
  -o "$test_dir/sampler-tests"
"$test_dir/sampler-tests"
