#!/bin/sh
# Build the Lambda container image and invoke it through the AWS Runtime
# Interface Emulator — the full build -> package -> invoke path, locally.
#
# Usage: scripts/docker-smoke.sh
# Env:
#   ZAP_IMAGE  prebuilt Zap toolchain image (default ghcr.io/zaplang-io/zap:latest)
#   IMAGE      tag to build (default zap-lambda-echo:smoke)
#   PORT       host port for the RIE (default 9100)
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
image="${IMAGE:-zap-lambda-echo:smoke}"
zap_image="${ZAP_IMAGE:-ghcr.io/zaplang-io/zap:latest}"
port="${PORT:-9100}"

echo "building $image (toolchain: $zap_image)"
docker build -f "$here/docker/Dockerfile" \
    --build-arg ZAP_IMAGE="$zap_image" \
    -t "$image" "$here"

name="zap-lambda-smoke-$$"
docker run -d --name "$name" -p "$port:8080" "$image" >/dev/null
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT

# Wait for the RIE to come up, then invoke with a sample event.
got=""
i=0
while [ "$i" -lt 30 ]; do
    got=$(curl -s "http://localhost:$port/2015-03-31/functions/function/invocations" \
          -d '{"name":"Zap"}' 2>/dev/null || true)
    [ -n "$got" ] && break
    i=$((i + 1))
    sleep 0.5
done

echo "invoke {\"name\":\"Zap\"} -> $got"
case "$got" in
    *'"message":"Hello, Zap!"'*)
        echo "docker smoke: PASS"
        ;;
    *)
        echo "docker smoke: FAIL (unexpected response)" >&2
        docker logs "$name" >&2 2>&1 || true
        exit 1
        ;;
esac
