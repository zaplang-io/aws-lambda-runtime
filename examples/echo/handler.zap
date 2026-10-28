# Example Lambda handler: a small typed JSON transform.
#
# This is a handler *fragment* — it supplies the handler function and `main()`,
# and is concatenated with ../../src/runtime.zap to form one compilation unit
# that builds to the `bootstrap` executable:
#
#   scripts/bootstrap.sh examples/echo/handler.zap
#
# It decodes the event into a typed struct (an absent `name` is handled via
# `Optional`), greets that name, and returns a typed response. Decoding into a
# `@derive(Json)` struct is the idiomatic, safe way to read optional fields:
# poking the dynamic `json.loads` DOM for a key that might be absent currently
# aborts (see the README "Friction" section).

# The event shape this handler accepts. `name` is optional: an absent key or an
# explicit null decodes to `None`.
@derive(Json)
struct EchoEvent:
    Optional[str] name

# The response shape this handler returns.
@derive(Json)
struct EchoResponse:
    str message
    str request_id

# A handler has type `fn(str, LambdaContext) -> str`: it takes the raw event
# JSON and the invocation context and returns the response JSON.
def handle(str event, LambdaContext ctx) -> str:
    auto req = EchoEvent.from_json(event)
    str name = "world"
    if req.name.is_some():
        name = req.name.unwrap()
    auto resp = EchoResponse(message="Hello, " + name + "!", request_id=ctx.request_id)
    return resp.to_json()

def main():
    lambda_run(handle)
