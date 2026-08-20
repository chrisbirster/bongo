const std = @import("std");
const connect_timeout = @import("connect_timeout.zig");
const operation_timeout = @import("operation_timeout.zig");

const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;

const TimedTaskResult = union(enum) {
    operation: anyerror!void,
    timer: anyerror!void,
};

pub const Connection = struct {
    io: Io,
    stream: net.Stream,
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
        const stream = connect_timeout.connect(
            io,
            host,
            port,
            options.connect_timeout_ms,
        ) catch |err| switch (err) {
            error.ConnectTimeout => return error.ConnectTimeout,
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

    /// Execute one command request with this connection's configured timeoutMS.
    /// The deadline starts before send and is shared by send + receive.
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
        try self.sendWithin(request_bytes, budget);
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

        var result_buffer: [2]TimedTaskResult = undefined;
        var select: Io.Select(TimedTaskResult) = .init(self.io, &result_buffer);
        defer select.cancelDiscard();

        try select.concurrent(.operation, sendTask, .{ self, bytes });
        try select.concurrent(.timer, waitUntilTask, .{ self.io, limit.deadline });

        switch (try select.await()) {
            .operation => |result| return result,
            .timer => |result| {
                try result;
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

        var response: ?[]u8 = null;
        var result_buffer: [2]TimedTaskResult = undefined;
        var select: Io.Select(TimedTaskResult) = .init(self.io, &result_buffer);
        defer {
            select.cancelDiscard();
            if (response) |bytes| allocator.free(bytes);
        }

        try select.concurrent(
            .operation,
            receiveTask,
            .{ self, allocator, max_message_size, &response },
        );
        try select.concurrent(.timer, waitUntilTask, .{ self.io, limit.deadline });

        switch (try select.await()) {
            .operation => |result| {
                try result;
                const bytes = response orelse unreachable;
                response = null;
                return bytes;
            },
            .timer => |result| {
                try result;
                return switch (limit.source) {
                    .operation => error.OperationTimeout,
                    .socket => error.SocketTimeout,
                };
            },
        }
    }

    fn sendTask(self: *Connection, bytes: []const u8) anyerror!void {
        try self.sendRaw(bytes);
    }

    fn receiveTask(
        self: *Connection,
        allocator: Allocator,
        max_message_size: usize,
        response: *?[]u8,
    ) anyerror!void {
        response.* = try self.receiveRaw(allocator, max_message_size);
    }

    fn waitUntilTask(io: Io, deadline: Io.Clock.Timestamp) anyerror!void {
        try waitUntil(io, deadline);
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
        return message;
    }

    fn waitUntil(io: Io, deadline: Io.Clock.Timestamp) !void {
        try deadline.wait(io);
    }
};
