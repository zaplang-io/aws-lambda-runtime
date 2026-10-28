# aws-lambda-runtime

The official **AWS Lambda custom runtime for [Zap](https://github.com/zaplang-io/zap)** —
write your Lambda handler in Zap and deploy it as the `bootstrap` executable an
AWS [custom runtime](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-custom.html)
expects.

This package implements the AWS **Lambda Runtime API** contract (the
`next` / `response` / `error` protocol over the local runtime endpoint). It
needs no SigV4 and no AWS SDK — only the `http`, `net`, `json` and `os` standard
library modules. It is the I#89a deliverable from the Zap AWS design
([`design/0011-aws-sdk.md`](https://github.com/zaplang-io/zap/blob/main/design/0011-aws-sdk.md),
D-0011), independent of the SDK that *calls* AWS services.

Status: **v1, hand-written, runnable.** The invocation loop, the typed handler
API and an offline test against a mock Runtime API all work end to end.

---

## Quick start

A handler is a first-class function value of type `fn(str, LambdaContext) -> str`:
it receives the raw event JSON and the invocation context, and returns the
response JSON. `main()` hands it to `lambda_run`, which loops forever processing
invocations.

```zap
# handler.zap
@derive(Json)
struct Event:
    Optional[str] name

@derive(Json)
struct Reply:
    str message
    str request_id

def handle(str event, LambdaContext ctx) -> str:
    auto req = Event.from_json(event)
    str name = "world"
    if req.name.is_some():
        name = req.name.unwrap()
    return Reply(message="Hello, " + name + "!", request_id=ctx.request_id).to_json()

def main():
    lambda_run(handle)
```

Build the deployable `bootstrap`:

```bash
ZAP=/path/to/zap scripts/bootstrap.sh path/to/handler.zap -o bootstrap
```

See [`examples/echo/handler.zap`](examples/echo/handler.zap) for the worked
example this ships with.

---

## The API

Defined in [`src/runtime.zap`](src/runtime.zap):

| Symbol | Purpose |
|---|---|
| `lambda_run(handler)` | The entrypoint. Loops forever: poll `next`, dispatch, report. Call from `main()`. |
| `lambda_poll_once(base, handler) -> str` | Process exactly one invocation (the loop body); returns the request id. Used by the offline test. |
| `report_init_error(error_type, message)` | Report a one-time initialization failure to Lambda (call before `lambda_run`). |
| `struct LambdaContext` | Per-invocation metadata from the `next` response headers. |
| `struct LambdaError` | The AWS error payload shape (`{"errorType":…,"errorMessage":…}`). |

`LambdaContext` fields (all strings — their wire form):
`request_id`, `invoked_function_arn`, `deadline_ms` (epoch millis),
`trace_id`, `client_context`, `cognito_identity`.

**Errors:** a handler fails an invocation by `raise`-ing. The loop catches it and
POSTs an AWS error payload to `…/invocation/{id}/error`; the loop continues with
the next invocation.

### Runtime API contract implemented

All calls target `http://$AWS_LAMBDA_RUNTIME_API/2018-06-01/runtime` (the
local-only endpoint Lambda injects):

- `GET  /invocation/next` — long-poll for the next event; request id, ARN,
  deadline and trace id are read from the response headers.
- `POST /invocation/{id}/response` — a successful result.
- `POST /invocation/{id}/error` — a handler failure.
- `POST /init/error` — an initialization failure.

---

## Building the Zap toolchain

Zap compiles AOT via LLVM, so you need a `zap` built with codegen (LLVM 18).
From a checkout of [`zaplang-io/zap`](https://github.com/zaplang-io/zap):

```bash
# In the LLVM 18 dev container (recommended — see that repo's CONTRIBUTING.md):
make docker-build          # once
cargo build --release -p zapc --features llvm --bin zap
# -> target/release/zap   (or target-docker/... in the container)
```

Point `$ZAP` at that binary for the scripts below. AWS Lambda runs **Linux
x86_64**, so build `bootstrap` on that target (the dev container already is).

---

## Running the offline test

The offline test drives the runtime loop against a **mock Runtime API server**
(stdlib `net`/`http`, localhost only) through two invocation cycles — one that
succeeds (`→ …/response`) and one whose handler raises (`→ …/error`) — and diffs
the output against [`test/offline_test.expected`](test/offline_test.expected).
Deterministic; no real Lambda.

```bash
ZAP=/path/to/zap scripts/run-tests.sh
# -> offline test: PASS
```

How it works: [`test/mock_runtime.zap`](test/mock_runtime.zap) is the mock
server, [`test/offline_test.zap`](test/offline_test.zap) is the driver, and
[`scripts/run-tests.sh`](scripts/run-tests.sh) concatenates them with the runtime
into one compilation unit (see "Packaging" below), runs it, and compares stdout.

---

## Packaging & deploying to AWS

1. Build `bootstrap` for Linux x86_64 (above).
2. Zip it at the archive root: `zip function.zip bootstrap`.
3. Create the function on the **OS-only** runtime (`provided.al2023`) with
   handler name `bootstrap`, e.g.:

   ```bash
   aws lambda create-function \
     --function-name zap-echo \
     --runtime provided.al2023 \
     --handler bootstrap \
     --role "$ROLE_ARN" \
     --zip-file fileb://function.zip
   ```

Lambda sets `AWS_LAMBDA_RUNTIME_API` in the execution environment; the runtime
reads it automatically.

---

## Package layout

```
zap.toml                 # package manifest (official-tier package, D-0056)
src/runtime.zap          # the runtime library: loop + handler contract + error shape
examples/echo/handler.zap# example handler fragment (+ main)
test/mock_runtime.zap    # mock Runtime API server (defs)
test/offline_test.zap    # offline test driver (+ main)
test/offline_test.expected
scripts/bootstrap.sh     # handler fragment -> bootstrap executable
scripts/run-tests.sh     # run the offline test (concat + run + diff)
.github/workflows/ci.yml # hygiene gate (always) + opt-in full compile/test
```

### Why the "fragment + concatenate" build?

Cross-file / cross-package linking is **not wired in the toolchain yet** (the
package manager, [zaplang-io/zap#69](https://github.com/zaplang-io/zap/issues/69),
is staged): today only a single `src/main.zap` — or the file passed to
`zap build` — compiles, and `import` of another module is a no-op. So v1 ships
the runtime as **source** and the build step concatenates `src/runtime.zap` with
your handler fragment into one compilation unit. When module linking lands, this
becomes an ordinary `[dependencies]` entry and you build your handler project
directly. The scripts localize that workaround.

---

## Friction found while dogfooding

Building this surfaced several Zap language/stdlib gaps (a primary goal of the
exercise). Filed against `zaplang-io/zap`; the high-impact ones:

1. **`str == str` does not codegen**
   ([#278](https://github.com/zaplang-io/zap/issues/278)) — any string equality
   (`a == b`, in an `if` or an `assert`) errors with *"unsupported operation on a
   reference type (only str + str)"*. String `+` works; `==` does not. This is
   why the offline test prints and diffs rather than asserting in-process.
   **High impact** for writing any string-handling logic or tests.
2. **HTTP server cannot set response headers**
   ([#279](https://github.com/zaplang-io/zap/issues/279)) — `http.respond(conn,
   status, body)` emits a fixed header set (Content-Length, text/plain, close).
   The Runtime API is header-driven (`Lambda-Runtime-Aws-Request-Id` et al.), so
   the mock server had to hand-write raw HTTP responses over `net.send`.
3. **HTTP client cannot set request headers**
   ([#280](https://github.com/zaplang-io/zap/issues/280)) — `http.get/post/request`
   take no headers, so the runtime cannot send the recommended
   `Lambda-Runtime-Function-Error-Type` header on the error POST (the error JSON
   body still carries the type), nor set `Content-Type`.
4. **`dict` has no membership or safe get**
   ([#281](https://github.com/zaplang-io/zap/issues/281)) — `in` is set-only, and
   a missing-key lookup on a `dict` (including the `json.loads` DOM `Object`)
   aborts. Reading a possibly-absent JSON field from the dynamic DOM isn't
   expressible; you must decode into a `@derive(Json)` struct with `Optional[T]`
   (which is what the example does, and is the nicer path anyway).
5. **No public string↔int conversion**
   ([#282](https://github.com/zaplang-io/zap/issues/282)) — `deadline_ms` can
   only be surfaced as a string; computing "time remaining" needs a `str`→`int`
   parse the stdlib does not expose (`json` has an internal `_i64_str`, not
   public).

Known, already-tracked constraints this v1 lives with rather than re-files:
cross-module linking ([#69](https://github.com/zaplang-io/zap/issues/69)), a
distributable toolchain / release ([#207](https://github.com/zaplang-io/zap/issues/207)),
HTTP keep-alive (deferred in the net/http work), and `zap fmt` (not yet
implemented, so there is no fmt gate here yet).

Minor: `ch <- a + b` needs parentheses around the value (`<-` binds tighter than
`+`); line continuation only works inside parentheses (expected, Pythonic).

---

## Follow-ups

- Promote the full compile+test CI job to always-on once a distributable `zap`
  toolchain exists (today it is `workflow_dispatch`-only — building the compiler
  from source with LLVM 18 is heavy).
- Become a real `[dependencies]` package (drop the concatenation) when module
  linking lands.
- A typed `deadline` accessor and a `Lambda-Runtime-Function-Error-Type` header
  on errors, once the underlying stdlib gaps above are closed.

## License

Apache-2.0 — see [LICENSE](LICENSE).
