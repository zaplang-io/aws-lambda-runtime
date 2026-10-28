#!/bin/sh
# Build a deployable AWS Lambda `bootstrap` from a Zap handler fragment.
#
# Usage: scripts/bootstrap.sh <handler.zap> [-o OUTPUT]
#
# Concatenates the runtime library (src/runtime.zap) with the handler fragment
# into a single compilation unit (build/bootstrap_main.zap) and compiles it to a
# native executable named `bootstrap` (the name an AWS custom runtime requires).
# Cross-package / cross-file linking is not wired in the toolchain yet
# (zaplang-io/zap#69), so the runtime source is vendored into the handler's
# compilation unit here. When that lands, this becomes a plain dependency and
# `zap build` on the handler project alone.
#
# Set $ZAP to override the zap binary (default: `zap` on PATH). AWS Lambda runs
# Linux x86_64, so build on (or in a container matching) that target.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
zap="${ZAP:-zap}"

handler="${1:?usage: scripts/bootstrap.sh <handler.zap> [-o OUTPUT]}"
out="bootstrap"
shift
if [ "${1:-}" = "-o" ]; then
    out="$2"
fi

mkdir -p "$here/build"
unit="$here/build/bootstrap_main.zap"

# Runtime defs first, then the handler fragment (which ends with main()), so
# every symbol is defined before it is used.
cat "$here/src/runtime.zap" "$handler" > "$unit"

"$zap" build "$unit" -o "$out"
echo "built '$out' from $handler (compilation unit: $unit)"
