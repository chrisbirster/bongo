const std = @import("std");

const Io = std.Io;
const net = Io.net;

const TaskResult = union(enum) {
    connect: anyerror!void,
    timer: anyerror!void,
};

pub const Error = error{
    ConnectTimeout,
    InvalidTimeout,
};

/// Connect to a host without using `Io.net.ConnectOptions.timeout`.
///
/// This is a Zig 0.16.0 compatibility workaround, not a MongoDB-specific
/// timeout algorithm. `std.Io.Threaded.netConnectIpPosix` contains an explicit
/// unfinished branch for timed connects:
///
/// `if (options.timeout != .none) @panic("TODO implement netConnectIpPosix with timeout");`
///
/// In the 0.16-era stdlib source this is around
/// `lib/std/Io/Threaded.zig:9185`; exact line offsets can differ between the
/// release archive/package-manager copy. The stable upstream reference is
/// ziglang/zig#25747 ("std.Io.Threaded: implement netConnect with timeout").
///
/// Passing MongoDB `connectTimeoutMS` directly to that stdlib option would
/// therefore abort the process on the Threaded POSIX backend instead of
/// returning a timeout error. Bongo races an ordinary timeout-free connect
/// against an awake-clock deadline with `Io.Select`; the connect result wins
/// if it completes first, otherwise Bongo cancels/discards it and returns
/// `error.ConnectTimeout`. Both plain TCP and TLS use this helper so Linux and
/// macOS have the same bounded behavior without entering the unfinished Zig
/// path. Remove this workaround once Bongo's minimum Zig version implements
/// POSIX connect timeouts natively. See docs/zig-0.16-tls-gap.md.
pub fn connect(
    io: Io,
    host: []const u8,
    port: u16,
    timeout_ms: ?u32,
) !net.Stream {
    const milliseconds = activeTimeout(timeout_ms) orelse {
        const host_name = try net.HostName.init(host);
        return host_name.connect(io, port, .{
            .mode = .stream,
            .protocol = .tcp,
            .timeout = .none,
        });
    };

    const now = Io.Clock.Timestamp.now(io, .awake);
    const duration: Io.Clock.Duration = .{
        .raw = Io.Duration.fromMilliseconds(milliseconds),
        .clock = .awake,
    };
    const deadline = now.addDuration(duration);

    var stream: ?net.Stream = null;
    var results: [2]TaskResult = undefined;
    var select: Io.Select(TaskResult) = .init(io, &results);
    defer {
        select.cancelDiscard();
        if (stream) |connected| connected.close(io);
    }

    try select.concurrent(.connect, connectTask, .{ io, host, port, &stream });
    try select.concurrent(.timer, waitTask, .{ io, deadline });

    switch (try select.await()) {
        .connect => |result| {
            try result;
            const connected = stream orelse unreachable;
            stream = null;
            return connected;
        },
        .timer => |result| {
            try result;
            return error.ConnectTimeout;
        },
    }
}

fn connectTask(
    io: Io,
    host: []const u8,
    port: u16,
    stream: *?net.Stream,
) anyerror!void {
    const host_name = try net.HostName.init(host);
    stream.* = try host_name.connect(io, port, .{
        .mode = .stream,
        .protocol = .tcp,
        .timeout = .none,
    });
}

fn waitTask(io: Io, deadline: Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io);
}

fn activeTimeout(value: ?u32) ?i64 {
    const milliseconds = value orelse return null;
    if (milliseconds == 0) return null;
    return milliseconds;
}

test "zero connect timeout means unlimited" {
    try std.testing.expect(activeTimeout(null) == null);
    try std.testing.expect(activeTimeout(0) == null);
    try std.testing.expectEqual(@as(i64, 5000), activeTimeout(5000).?);
}
