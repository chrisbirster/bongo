# Timeouts

Bongo v0.3 separates **connection establishment**, **socket I/O**, and **client-side operation** limits.

At the low-level transport API:

```zig
var connection = try bongo.mongo.Connection.connectWithOptions(
    io,
    "db.example",
    27017,
    .{
        .connect_timeout_ms = 10_000,
        .socket_timeout_ms = 30_000,
        .operation_timeout_ms = 5_000,
    },
);
defer connection.deinit();
```

`connect_timeout_ms` bounds DNS/TCP connection establishment through Zig's native `Io.Timeout` support. Bongo uses `HostName.connect`, so normal DNS hostnames, including SRV-discovered hosts, are accepted in addition to numeric IP addresses. A connect deadline is reported as `error.ConnectTimeout`.

`socket_timeout_ms` bounds an individual send or receive step. Bongo races cancelable Zig I/O against the monotonic `awake` clock and cancels the losing future. A stalled write or read is reported as `error.SocketTimeout`.

`operation_timeout_ms` implements the transport-level behavior for MongoDB `timeoutMS`. Bongo creates one monotonic absolute deadline before the send starts and carries that same deadline through the send and receive. The receive therefore gets only the time remaining after the send; the timeout is not reset for each nested step. An exhausted operation budget is reported as `error.OperationTimeout`.

When both operation and socket limits are configured, the earlier deadline wins. A short `socketTimeoutMS` can fail one network step before the overall operation budget, but it can never extend `timeoutMS`.

For all three settings, `null` means no configured limit. MongoDB's URI semantics also treat `0` as unlimited for `connectTimeoutMS`, `socketTimeoutMS`, and `timeoutMS`.

The normalized connection-string layer exposes all three URI fields. Low-level callers may also override the operation budget for a single request:

```zig
const response = try connection.requestWithTimeoutMs(
    allocator,
    request_bytes,
    2_000,
);
defer allocator.free(response);
```

Bongo v0.3 still has one connection per `Client` and no topology/server-selection loop. At this milestone, a complete operation budget spans one full `Connection.request` including send and receive. The exported `OperationTimeoutBudget` is intentionally reusable so later pooling, server selection, retries, and cursor work can propagate the same remaining deadline instead of creating new timeout windows.
