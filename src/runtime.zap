# aws-lambda-runtime — the AWS Lambda Runtime API client for Zap.
#
# I#89a / design 0011-aws-sdk.md (D-0011). This is the custom-runtime loop: it
# long-polls the local Runtime API for the next invocation, dispatches a user
# handler, and reports the result (or the failure) back to Lambda. It needs no
# SigV4 and no SDK — only the `http`, `net`, `json` and `os` stdlib modules.
#
# This file is the runtime *library*; it defines no `main()`. A deployable
# `bootstrap` executable is produced by concatenating this file with a handler
# fragment that supplies `main()` (see scripts/bootstrap.sh and the README).
# Cross-file / cross-package linking is not wired in the toolchain yet (pkg
# manager, zaplang-io/zap#69), so v1 vendors the runtime source into the
# handler's single compilation unit.
#
# The custom-runtime contract (AWS Lambda Runtime API, version 2018-06-01):
#
#   GET  /runtime/invocation/next           -> next event body + metadata headers
#   POST /runtime/invocation/{id}/response  <- a successful handler result
#   POST /runtime/invocation/{id}/error     <- a handler failure (AWS error JSON)
#   POST /runtime/init/error                <- an initialization failure
#
# Every call targets the local-only endpoint named by $AWS_LAMBDA_RUNTIME_API
# (a "host:port" the Lambda execution environment injects), over plain HTTP.

# ---------------------------------------------------------------------------
# The handler contract
# ---------------------------------------------------------------------------
# A handler is a first-class function value:
#
#   fn(str, LambdaContext) -> str
#
# It receives the raw event payload as a JSON string plus the per-invocation
# context, and returns the response payload as a JSON string. Working at the
# string boundary keeps the runtime independent of any particular event schema;
# a handler parses the event and builds its response with the `json` module (see
# examples/echo/handler.zap). To fail an invocation, a handler raises; the loop
# catches it and reports the error to Lambda.

# The per-invocation context AWS delivers as response headers on `next`.
# Fields are kept as strings (their wire form). `deadline_ms` is epoch
# milliseconds as a decimal string — there is no string->int parse helper in the
# stdlib yet, so a typed accessor is a follow-up (see the README "Friction"
# section). An absent header reads as the empty string.
struct LambdaContext:
    str request_id
    str invoked_function_arn
    str deadline_ms
    str trace_id
    str client_context
    str cognito_identity

# The AWS error payload shape (POSTed to .../error and .../init/error). The wire
# keys are `errorType` and `errorMessage`; the field names are those keys
# verbatim, since `@derive(Json)` uses the field name as the JSON key.
@derive(Json)
struct LambdaError:
    str errorType
    str errorMessage

# ---------------------------------------------------------------------------
# Endpoint URLs
# ---------------------------------------------------------------------------

# The Runtime API base URL, e.g. "http://127.0.0.1:9001/2018-06-01/runtime".
# Reads $AWS_LAMBDA_RUNTIME_API, which the Lambda environment always sets.
def api_base() -> str:
    return "http://" + os.getenv("AWS_LAMBDA_RUNTIME_API") + "/2018-06-01/runtime"

def next_url(str base) -> str:
    return base + "/invocation/next"

def response_url(str base, str request_id) -> str:
    return base + "/invocation/" + request_id + "/response"

def error_url(str base, str request_id) -> str:
    return base + "/invocation/" + request_id + "/error"

def init_error_url(str base) -> str:
    return base + "/init/error"

# ---------------------------------------------------------------------------
# The invocation loop
# ---------------------------------------------------------------------------

# Build the context from the metadata headers on a `next` response.
def context_of(bytes next_resp) -> LambdaContext:
    return LambdaContext(
        request_id=http.header(next_resp, "Lambda-Runtime-Aws-Request-Id"),
        invoked_function_arn=http.header(next_resp, "Lambda-Runtime-Invoked-Function-Arn"),
        deadline_ms=http.header(next_resp, "Lambda-Runtime-Deadline-Ms"),
        trace_id=http.header(next_resp, "Lambda-Runtime-Trace-Id"),
        client_context=http.header(next_resp, "Lambda-Runtime-Client-Context"),
        cognito_identity=http.header(next_resp, "Lambda-Runtime-Cognito-Identity"),
    )

# Poll for and process exactly one invocation against the Runtime API at `base`:
# GET the next event, run the handler, and POST either the result or (if the
# handler raises) an AWS error payload. Returns the request id handled, so tests
# and logs can observe progress. Factored out of `lambda_run` so the loop body
# is directly testable one cycle at a time.
def lambda_poll_once(str base, fn(str, LambdaContext) -> str handler) -> str:
    auto next_resp = http.get(next_url(base))
    LambdaContext ctx = context_of(next_resp)
    auto event = http.body(next_resp)
    try:
        auto result = handler(event, ctx)
        http.post(response_url(base, ctx.request_id), result)
    except Exception as e:
        auto payload = LambdaError(errorType="Handler.Error", errorMessage=e).to_json()
        http.post(error_url(base, ctx.request_id), payload)
    return ctx.request_id

# The custom-runtime entrypoint: loop forever, processing one invocation per
# iteration. A handler fragment's `main()` calls this after any one-time init:
#
#   def main():
#       lambda_run(handle)
#
# The `next` poll is a long poll — it blocks until Lambda has an event — so the
# loop idles without busy-waiting between invocations.
def lambda_run(fn(str, LambdaContext) -> str handler):
    auto base = api_base()
    while True:
        lambda_poll_once(base, handler)

# Report an initialization failure to Lambda and stop. Call this from `main()`
# (before `lambda_run`) when one-time setup fails, so the platform sees an
# Init error rather than a silent exit.
def report_init_error(str error_type, str message):
    auto payload = LambdaError(errorType=error_type, errorMessage=message).to_json()
    http.post(init_error_url(api_base()), payload)
