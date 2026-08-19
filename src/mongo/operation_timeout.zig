const std = @import("std");

const Io = std.Io;

pub const Error = error{
    InvalidTimeout,
    OperationTimeout,
};

pub const Source = enum {
    operation,
    socket,
};

pub const Limit = struct {
    deadline: Io.Clock.Timestamp,
    source: Source,
};

/// One monotonic deadline shared by every nested network step in a MongoDB
/// operation. A null deadline means the client-side operation timeout is off.
pub const Budget = struct {
    deadline: ?Io.Clock.Timestamp = null,

    pub fn start(io: Io, timeout_ms: ?u64) !Budget {
        const raw_ms = timeout_ms orelse return .{};
        if (raw_ms == 0) return .{};
        const milliseconds = std.math.cast(i64, raw_ms) orelse
            return error.InvalidTimeout;
        const now = try Io.Clock.Timestamp.now(io, .awake);
        const duration: Io.Clock.Duration = .{
            .raw = Io.Duration.fromMilliseconds(milliseconds),
            .clock = .awake,
        };
        return .{ .deadline = now.addDuration(duration) };
    }

    /// Return the next effective deadline. `socket_timeout_ms` may make a
    /// single network step expire sooner, but it can never extend the overall
    /// operation deadline.
    pub fn limit(
        self: Budget,
        io: Io,
        socket_timeout_ms: ?u32,
    ) !?Limit {
        const now = try Io.Clock.Timestamp.now(io, .awake);

        const operation_deadline = self.deadline;
        if (operation_deadline) |deadline| {
            if (!now.compare(.lt, deadline)) return error.OperationTimeout;
        }

        const socket_deadline: ?Io.Clock.Timestamp = blk: {
            const milliseconds = socket_timeout_ms orelse break :blk null;
            if (milliseconds == 0) break :blk null;
            const duration: Io.Clock.Duration = .{
                .raw = Io.Duration.fromMilliseconds(milliseconds),
                .clock = .awake,
            };
            break :blk now.addDuration(duration);
        };

        if (operation_deadline) |op| {
            if (socket_deadline) |socket| {
                if (op.compare(.le, socket)) {
                    return .{ .deadline = op, .source = .operation };
                }
                return .{ .deadline = socket, .source = .socket };
            }
            return .{ .deadline = op, .source = .operation };
        }
        if (socket_deadline) |socket| {
            return .{ .deadline = socket, .source = .socket };
        }
        return null;
    }
};

test "zero operation timeout disables budget" {
    const budget = try Budget.start(std.testing.io, 0);
    try std.testing.expect(budget.deadline == null);
}

test "operation budget wins over a longer socket timeout" {
    const budget = try Budget.start(std.testing.io, 100);
    const limit = (try budget.limit(std.testing.io, 10_000)).?;
    try std.testing.expectEqual(Source.operation, limit.source);
}
