const std = @import("std");
const compression = @import("compression.zig");
const operation_timeout = @import("operation_timeout.zig");

const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;

pub const Connection = struct {
    io: Io,
    stream: net.Stream,
    compressor: ?compression.Compressor = null,
    socket_timeout_ms: ?u32 = null,
    operation_timeout_ms: ?u64 = null,

    pub const Error = error{
        InvalidMessageLength,
        MessageTooLarge,
        ConnectTimeout,
        SocketTimeout,
        OperationTimeout,
    };

    pub const Options = struct {
        connect_timeout_ms: ?u32 = null,
        socket_timeout_ms: ?u32 = null,
        /// One budget for a complete request. `0` means no client-side
        /// operation timeout, matching MongoDB `timeoutMS` semantics.
        operation_timeout_ms: ?u64 = null,
    };

    pub const default_max_message_size: usize = 48 * 1024 * 1024;

    pub fn connect(io: Io, host: []const u8, port: u16) !Connection {
        return connectWithOptions(io, host, port, .{});
    }

    pub fn connectWithOptions(
        io: Io,
        host: []const u8,
        port: u16,
        options: Options,
    ) !Connection {
        const host_name = try net.HostName.init(host);
        const stream = host_name.connect(io, port, .{
            .mode = .stream,
            .protocol = .tcp,
            .timeout = timeoutFromMs(options.connect_timeout_ms),
        }) catch |err| switch (err) {
            error.Timeout => return error.ConnectTimeout,
            else => |e| return e,
        };
        return .{
            .io = io,
            .stream = stream,
            .socket_timeout_ms = options.socket_timeout_ms,
            .operation_timeout_ms = options.operation_timeout_ms,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close(self.io);
        self.* = undefined;
    }

    pub fn setCompressor(self: *Connection, compressor: ?compression.Compressor) void {
        self.compressor = compressor;
    }

    /// Execute one command request with this connection's configured timeoutMS.
    /// The deadline starts before compression and is shared by send + receive.
    pub fn request(
        self: *Connection,
        allocator: Allocator,
        request_bytes: []const u8,
    ) ![]u8 {
        return self.requestWithTimeoutMs(
            allocator,
            request_bytes,
            self.operation_timeout_ms,
        );
    }

    /// Execute one request with an explicit client-side timeout override.
    /// `null` and `0` disable the operation budget while preserving any
    /// configured per-socket timeout.
    pub fn requestWithTimeoutMs(
        self: *Connection,
        allocator: Allocator,
        request_bytes: []const u8,
        timeout_ms: ?u64,
    ) ![]u8 {
        const budget = try operation_timeout.Budget.start(self.io, timeout_ms);

        if (self.compressor) |compressor| {
            const compressed = try compression.compressMessage(
                allocator,
                request_bytes,
                compressor,
            );
            defer allocator.free(compressed);
            try self.sendWithin(compressed, budget);
        } else {
            try self.sendWithin(request_bytes, budget);
        }
        return self.receiveWithin(
            allocator,
            default_max_message_size,
            budget,
        );
    }

    /// Direct send using only socketTimeoutMS. Normal command code should use
    /// `request`, which carries a shared operation budget across both steps.
    pub fn send(self: *Connection, bytes: []const u8) !void {
        return self.sendWithin(bytes, .{});
    }

    /// Direct receive using only socketTimeoutMS.
    pub fn receive(
        self: *Connection,
        allocator: Allocator,
        max_message_size: usize,
    ) ![]u8 {
        return self.receiveWithin(allocator, max_message_size, .{});
    }

    fn sendWithin(
        self: *Connection,
        bytes: []const u8,
        budget: operation_timeout.Budget,
    ) !void {
        const limit = budget.limit(self.io, self.socket_timeout_ms) catch |err| switch (err) {
            error.OperationTimeout => return error.OperationTimeout,
            else => |e| return e,
        } orelse return self.sendRaw(bytes);

        var operation = self.io.async(sendRaw, .{ self, bytes });
        var timer = self.io.async(waitUntil, .{ self.io, limit.deadline });
        switch (try Io.select(self.io, .{
            .operation = &operation,
            .timer = &timer,
        })) {
            .operation => |result| {
                _ = timer.cancel(self.io) catch {};
                return result;
            },
            .timer => |result| {
                try result;
                _ = operation.cancel(self.io) catch {};
                return switch (limit.source) {
                    .operation => error.OperationTimeout,
                    .socket => error.SocketTimeout,
                };
            },
        }
    }

    fn receiveWithin(
        self: *Connection,
        allocator: Allocator,
        max_message_size: usize,
        budget: operation_timeout.Budget,
    ) ![]u8 {
        const limit = budget.limit(self.io, self.socket_timeout_ms) catch |err| switch (err) {
            error.OperationTimeout => return error.OperationTimeout,
            else => |e| return e,
        } orelse return self.receiveRaw(allocator, max_message_size);

        var operation = self.io.async(receiveRaw, .{ self, allocator, max_message_size });
        var timer = self.io.async(waitUntil, .{ self.io, limit.deadline });
        switch (try Io.select(self.io, .{
            .operation = &operation,
            .timer = &timer,
        })) {
            .operation => |result| {
                _ = timer.cancel(self.io) catch {};
                return result;
            },
            .timer => |result| {
                try result;
                const canceled = operation.cancel(self.io);
                if (canceled) |late_response| {
                    allocator.free(late_response);
                } else |_| {}
                return switch (limit.source) {
                    .operation => error.OperationTimeout,
                    .socket => error.SocketTimeout,
                };
            },
        }
    }

    fn sendRaw(self: *Connection, bytes: []const u8) !void {
        var write_buffer: [4096]u8 = undefined;
        var stream_writer = self.stream.writer(self.io, &write_buffer);
        try stream_writer.interface.writeAll(bytes);
        try stream_writer.interface.flush();
    }

    fn receiveRaw(
        self: *Connection,
        allocator: Allocator,
        max_message_size: usize,
    ) ![]u8 {
        var read_buffer: [4096]u8 = undefined;
        var stream_reader = self.stream.reader(self.io, &read_buffer);
        var length_bytes: [4]u8 = undefined;
        try stream_reader.interface.readSliceAll(&length_bytes);

        const message_length_i32 = std.mem.readInt(i32, &length_bytes, .little);
        if (message_length_i32 < 16) return error.InvalidMessageLength;
        const message_length: usize = @intCast(message_length_i32);
        if (message_length > max_message_size) return error.MessageTooLarge;

        const message = try allocator.alloc(u8, message_length);
        errdefer allocator.free(message);
        @memcpy(message[0..4], &length_bytes);
        try stream_reader.interface.readSliceAll(message[4..]);

        if (!compression.isCompressed(message)) return message;
        const decompressed = try compression.decompressMessage(
            allocator,
            message,
            max_message_size,
        );
        allocator.free(message);
        return decompressed;
    }

    fn waitUntil(io: Io, deadline: Io.Clock.Timestamp) !void {
        try deadline.wait(io);
    }

    fn timeoutFromMs(value: ?u32) Io.Timeout {
        const milliseconds = activeTimeout(value) orelse return .none;
        return .{ .duration = .{
            .raw = Io.Duration.fromMilliseconds(milliseconds),
            .clock = .awake,
        } };
    }

    fn activeTimeout(value: ?u32) ?u32 {
        const milliseconds = value orelse return null;
        return if (milliseconds == 0) null else milliseconds;
    }
};

test "network timeout option maps zero to unlimited" {
    try std.testing.expect(Connection.activeTimeout(null) == null);
    try std.testing.expect(Connection.activeTimeout(0) == null);
    try std.testing.expectEqual(@as(u32, 5000), Connection.activeTimeout(5000).?);
}
