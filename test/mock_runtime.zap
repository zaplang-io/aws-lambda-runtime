# A mock AWS Lambda Runtime API server for the offline test (defs only; the
# driver is test/offline_test.zap). It serves a fixed script of invocations on
# an ephemeral localhost port and reports each POST it receives back to the test.
#
# The http client sends `Connection: close`, so every Runtime API call is a
# fresh connection and the mock accepts once per request. Response headers are
# written with raw net.send because http.respond cannot set custom response
# headers (see the README "Friction" section) — and the runtime reads the
# request id, ARN, deadline and trace id off exactly those headers.

# Serve one `GET .../invocation/next`: reply 200 with the invocation metadata
# headers and the event body.
def mock_next(bytes l, str request_id, str event):
    auto c = net.accept(l)
    http.read_request(c)
    auto resp = (
        "HTTP/1.1 200 OK\r\n"
        + "Lambda-Runtime-Aws-Request-Id: " + request_id + "\r\n"
        + "Lambda-Runtime-Invoked-Function-Arn: "
        + "arn:aws:lambda:us-east-1:123456789012:function:zap-echo\r\n"
        + "Lambda-Runtime-Deadline-Ms: 1700000000000\r\n"
        + "Lambda-Runtime-Trace-Id: Root=1-5bef4de7-ad49b0e52f\r\n"
        + "Connection: close\r\n\r\n"
        + event
    )
    net.send(c, resp)
    net.close_conn(c)

# Serve one POST (.../response or .../error): report its path and body (joined by
# a space) over `reports`, then reply 202 Accepted.
def mock_collect(bytes l, channel[str] reports):
    auto c = net.accept(l)
    auto req = http.read_request(c)
    reports <- (http.path(req) + " " + http.req_body(req))
    net.send(c, "HTTP/1.1 202 Accepted\r\nConnection: close\r\n\r\n")
    net.close_conn(c)

# The scripted server: two invocation cycles (the test's first handler succeeds,
# its second raises), reporting each POST over `reports`. Publishes the bound
# port over `portch` first so the test can dial it.
def mock_server(channel[int64] portch, channel[str] reports):
    auto l = net.listen("127.0.0.1", 0)
    portch <- net.port(l)
    mock_next(l, "req-ok", "{\"name\": \"Ada\"}")
    mock_collect(l, reports)
    mock_next(l, "req-boom", "{\"name\": \"Grace\"}")
    mock_collect(l, reports)
    net.close_listener(l)
