#!/bin/sh
# Run the offline runtime test against the mock Runtime API server.
#
# Usage: scripts/run-tests.sh
#
# Concatenates the runtime library (src/runtime.zap), the mock server
# (test/mock_runtime.zap) and the test driver (test/offline_test.zap) into one
# compilation unit (build/offline_test.zap), runs it with `zap run`, and diffs
# its stdout against test/offline_test.expected. Exits non-zero on any mismatch.
#
# Printing + golden comparison (rather than in-process asserts) is how Zap tests
# string values today — string `==` does not codegen yet (see the README).
# Single-compilation-unit vendoring is the same workaround bootstrap.sh uses
# (cross-file linking pending zaplang-io/zap#69).
#
# Set $ZAP to override the zap binary (default: `zap` on PATH).
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
zap="${ZAP:-zap}"

mkdir -p "$here/build"
unit="$here/build/offline_test.zap"
got="$here/build/offline_test.out"

cat "$here/src/runtime.zap" \
    "$here/test/mock_runtime.zap" \
    "$here/test/offline_test.zap" > "$unit"

"$zap" run "$unit" > "$got"

if diff -u "$here/test/offline_test.expected" "$got"; then
    echo "offline test: PASS"
else
    echo "offline test: FAIL (actual output differs from test/offline_test.expected)" >&2
    exit 1
fi
