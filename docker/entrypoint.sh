#!/bin/sh
# Lambda container entrypoint for a Zap custom runtime.
#
# On AWS Lambda the execution environment sets AWS_LAMBDA_RUNTIME_API, so we exec
# the bootstrap directly (it is the custom runtime and talks to that endpoint).
# Locally that variable is unset, so we front the bootstrap with the AWS Runtime
# Interface Emulator, which serves the Runtime API on :8080 and lets you invoke
# the function with a plain HTTP POST (see docker/README.md).
set -e

if [ -z "${AWS_LAMBDA_RUNTIME_API:-}" ]; then
    exec /usr/local/bin/aws-lambda-rie /var/runtime/bootstrap "$@"
fi
exec /var/runtime/bootstrap "$@"
