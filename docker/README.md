# Docker image for a Zap Lambda function

[`docker/Dockerfile`](Dockerfile) builds a **Lambda-ready container image** from a
Zap handler: a multi-stage build that compiles the handler into a `bootstrap`
with the Zap toolchain and installs it on a base that can run it, with the AWS
Runtime Interface Emulator (RIE) bundled for local testing. The handler is baked
in and the image implements the Lambda Runtime API itself (via the runtime in
this repo), so it needs no AWS Runtime Interface Client.

## Build

From the repo root:

```bash
docker build -f docker/Dockerfile -t zap-lambda-echo .
```

Build a different handler, or pin a toolchain tag:

```bash
docker build -f docker/Dockerfile \
  --build-arg HANDLER=examples/echo/handler.zap \
  --build-arg ZAP_IMAGE=ghcr.io/zaplang-io/zap:0.0.1 \
  -t my-fn .
```

`ZAP_IMAGE` (default `ghcr.io/zaplang-io/zap:latest`) is the prebuilt Zap
toolchain image ([zaplang-io/zap#277](https://github.com/zaplang-io/zap/pull/277));
it carries the LLVM/clang link toolchain `zap build` invokes, so no LLVM build
happens in this Dockerfile.

### Until the toolchain image is published

If `ghcr.io/zaplang-io/zap` is not available yet, build a local toolchain image
from a checkout of `zaplang-io/zap` (its own `Dockerfile`), then point the build
at it:

```bash
docker build -t zap-local /path/to/zap            # the zap repo's Dockerfile
docker build -f docker/Dockerfile --build-arg ZAP_IMAGE=zap-local -t zap-lambda-echo .
```

## Run & invoke locally (RIE)

The entrypoint fronts the bootstrap with the RIE when `AWS_LAMBDA_RUNTIME_API`
is unset (i.e. not on real Lambda):

```bash
docker run --rm -p 9000:8080 zap-lambda-echo
# in another shell:
curl -s "http://localhost:9000/2015-03-31/functions/function/invocations" \
  -d '{"name":"Zap"}'
# -> {"message":"Hello, Zap!","request_id":"<uuid>"}
```

Or run the whole build + invoke smoke test:

```bash
scripts/docker-smoke.sh          # ZAP_IMAGE=... to override the toolchain image
# -> docker smoke: PASS
```

## Deploy to AWS Lambda (container image)

```bash
aws ecr create-repository --repository-name zap-lambda-echo
docker tag zap-lambda-echo:latest "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/zap-lambda-echo:latest"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
docker push "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/zap-lambda-echo:latest"

aws lambda create-function \
  --function-name zap-echo \
  --package-type Image \
  --code ImageUri="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/zap-lambda-echo:latest" \
  --role "$ROLE_ARN"
```

On Lambda, `AWS_LAMBDA_RUNTIME_API` is set, so the entrypoint execs the bootstrap
directly and the RIE is not used.

## Why not the AWS `provided.al2023` base image?

The Zap toolchain image is **Ubuntu 24.04**-based (glibc 2.39), and `zap build`
emits a dynamically linked binary against that base (`libstdc++`, OpenSSL 3,
PCRE2, zlib, `libpython3.12`, …). Amazon Linux 2023 — the AWS `provided.al2023`
base — ships an **older glibc (2.34)**, so an Ubuntu-built bootstrap fails to
start there (it exits 127 under the RIE). Installing the libraries on top does
not help: the mismatch is glibc symbol versions, set at link time.

Lambda runs **any** Linux image whose process speaks the Runtime API, which this
bootstrap does, so the image shares the toolchain's base (Ubuntu 24.04) and
installs just the runtime libraries the bootstrap needs. Using the AWS base image
is a follow-up gated on an Amazon-Linux-2023 (or static / musl) Zap toolchain
that emits AL2023-compatible binaries — tracked as
[zaplang-io/zap#287](https://github.com/zaplang-io/zap/issues/287).
