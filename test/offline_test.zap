# Offline test driver: run the runtime loop against the mock Runtime API server
# and print what it observes, for comparison against test/offline_test.expected
# (scripts/run-tests.sh diffs the two).
#
# Printing + golden comparison is how Zap exercises string values today: string
# `==` does not codegen yet, so in-process string assertions are not available
# (see the README "Friction" section). This is also how the Zap compiler's own
# golden suite works.
#
# Two invocation cycles against the mock: the first handler returns a result
# (-> POST .../invocation/{id}/response), the second raises (-> POST
# .../invocation/{id}/error with the AWS error JSON). The mock reports the path
# and body of each POST it receives. Deterministic — localhost only, no real
# Lambda.
#
# This is a test *fragment*: scripts/run-tests.sh concatenates it with
# ../src/runtime.zap and ../test/mock_runtime.zap into one compilation unit.

# A handler that returns a fixed JSON result (the happy path).
def ok_handler(str event, LambdaContext ctx) -> str:
    return "{\"ok\": true}"

# A handler that always fails (the error path).
def boom_handler(str event, LambdaContext ctx) -> str:
    raise "kaboom"

def main():
    auto portch = channel[int64]()
    auto reports = channel[str](4)
    spawn mock_server(portch, reports)
    auto port = <-portch
    auto base = http.url("127.0.0.1", port, "/2018-06-01/runtime")

    # Cycle 1: success -> the runtime POSTs the result to .../response.
    auto id1 = lambda_poll_once(base, ok_handler)
    print(id1)
    auto r1 = <-reports
    print(r1)

    # Cycle 2: failure -> the runtime POSTs the AWS error JSON to .../error.
    auto id2 = lambda_poll_once(base, boom_handler)
    print(id2)
    auto r2 = <-reports
    print(r2)
