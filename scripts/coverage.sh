#!/bin/bash
# Coverage of Sources/WinBar from the test suite (snapshot tests + SelfTest), via LLVM source-based coverage.
# Fails if line coverage is below COVERAGE_MIN (default 90). HTML report: COVERAGE_HTML=1.
# Same toolchain and scratch path as scripts/test.sh; extra arguments go to `swift test`.
set -euo pipefail
trap 'exit 1' ERR # any failing step (tests, llvm-cov) exits 1, same as the coverage gate
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
min="${COVERAGE_MIN:-90}"
build=.build/xcode
swift test --scratch-path "$build" --enable-code-coverage "$@"
bin="$build/debug/WinBarTests.xctest/Contents/MacOS/WinBarTests" # Xcode 26's swift-build layout; WinBar is linked in
prof="$build/debug/codecov/default.profdata"
ignore='(\.build|Tests)/|SelfTest\.swift' # dependencies, tests, and test code living in Sources
xcrun llvm-cov report "$bin" -instr-profile="$prof" -ignore-filename-regex="$ignore" | tee "$build/coverage.txt"
if [[ -n "${COVERAGE_HTML:-}" ]]; then
    xcrun llvm-cov show "$bin" -instr-profile="$prof" -ignore-filename-regex="$ignore" -format=html -output-dir="$build/coverage"
    echo "HTML: $build/coverage/index.html"
fi
pct=$(awk '/^TOTAL/ { sub("%", "", $10); print $10 }' "$build/coverage.txt") # Lines Cover column
awk -v p="$pct" -v m="$min" 'BEGIN { exit !(p >= m) }' || { echo "coverage: lines ${pct}% < ${min}%"; exit 1; }
echo "coverage: lines ${pct}% ≥ ${min}%"
