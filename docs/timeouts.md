# Timeouts

Bongo v0.3 separates **connection establishment** limits from **socket I/O** limits.

At the low-level transport API:

```zig
var connection = try bongo.mongo.Connection.connectWithOptions(
    io,
    "db.example",
    27017,
    .{
        .connect_timeout_ms = 10_000,
        .socket_timeout_ms = 30_000,
    },
);
defer connection.deinit();
```

`connect_timeout_ms` bounds DNS/TCP connection establishment through Zig's native `Io.Timeout` support. Bongo now uses `HostName.connect`, so normal DNS hostnames (including SRV-discovered hosts) are accepted in addition to numeric IP addresses. A connect deadline is reported as `error.ConnectTimeout`.

`socket_timeout_ms` bounds each send and receive operation. Bongo races the cancelable Zig I/O operation against the monotonic `awake` clock and cancels the losing future. A stalled write or read is reported as `error.SocketTimeout`.

For both settings, `null` and `0` mean no timeout, matching MongoDB URI semantics. `parseConnectionOptions` already exposes `connectTimeoutMS` and `socketTimeoutMS` in the normalized URI model.

These are **per-network-step limits**. BONGO-0048 adds `timeoutMS` as a single client-side budget spanning the complete request so a send followed by a receive cannot each consume a fresh full operation timeout.
