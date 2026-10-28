# syntax=docker/dockerfile:1
#
# Deployable AWS Lambda container image for a Zap handler.
#
# Multi-stage: the `builder` stage compiles the handler into a `bootstrap`
# executable with the Zap toolchain; the final stage installs that bootstrap on
# a base that can run it and bundles the AWS Runtime Interface Emulator for local
# testing. The result is a Lambda-ready container image — deploy it directly
# (container-image packaging) or run it locally (see docker/README.md).
#
# Build from the repo root:
#   docker build -f docker/Dockerfile -t zap-lambda-echo .
#
# Build a different handler, or pin a toolchain tag:
#   docker build -f docker/Dockerfile \
#     --build-arg HANDLER=examples/echo/handler.zap \
#     --build-arg ZAP_IMAGE=ghcr.io/zaplang-io/zap:0.0.1 \
#     -t my-fn .
#
# ZAP_IMAGE is the prebuilt Zap toolchain image (zaplang-io/zap#277); it carries
# the LLVM/clang link toolchain `zap build` invokes, so no LLVM build happens
# here. Until it is published you can point ZAP_IMAGE at a locally built
# toolchain image (see docker/README.md).

ARG ZAP_IMAGE=ghcr.io/zaplang-io/zap:latest

# --- builder: compile the handler fragment into `bootstrap` ------------------
FROM ${ZAP_IMAGE} AS builder
ARG HANDLER=examples/echo/handler.zap
WORKDIR /src
COPY src/runtime.zap runtime.zap
COPY ${HANDLER} handler.zap
# Runtime defs first, then the handler fragment (which ends with main()), into
# one compilation unit — the same vendoring scripts/bootstrap.sh does, since
# cross-file linking is not wired yet (zaplang-io/zap#69).
RUN cat runtime.zap handler.zap > bootstrap_main.zap \
    && zap build bootstrap_main.zap -o /bootstrap

# --- runtime: a base that can run the bootstrap + the RIE --------------------
# The bootstrap is dynamically linked against the Zap toolchain image's base
# (Ubuntu 24.04 / glibc 2.39 + libstdc++, OpenSSL 3, PCRE2, zlib, libpython).
# Amazon Linux 2023 (AWS `provided.al2023`) ships an older glibc, so an
# Ubuntu-built binary will not start there — the image must share the toolchain's
# base ABI. Lambda runs any Linux image that speaks the Runtime API, which the
# bootstrap does, so we base on the same Ubuntu and install just the runtime
# libraries the bootstrap needs. (A follow-up: an AL2023 / static toolchain so
# the AWS base image can be used — see docker/README.md.)
FROM ubuntu:24.04
ARG RIE_VERSION=v1.21
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       libstdc++6 libgcc-s1 libpcre2-8-0 zlib1g libssl3 libpython3.12 libexpat1 \
       ca-certificates curl \
    && curl -fsSL -o /usr/local/bin/aws-lambda-rie \
       "https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/download/${RIE_VERSION}/aws-lambda-rie-x86_64" \
    && chmod +x /usr/local/bin/aws-lambda-rie \
    && rm -rf /var/lib/apt/lists/*

ENV LAMBDA_RUNTIME_DIR=/var/runtime
COPY --from=builder /bootstrap /var/runtime/bootstrap
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# RIE listens on 8080 when AWS_LAMBDA_RUNTIME_API is unset (local runs).
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
