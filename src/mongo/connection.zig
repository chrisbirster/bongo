const std = @import("std");
const compression = @import("compression.zig");

const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;

pub const Connection = struct {
    io: Io,
    stream: net.Stream,
    compressor: ?compression.Compressor = null,
    socket_timeout_ms: ?u32 = null,

    pub const Error = error{
        InvalidMessageLength,
        MessageTooLarge,
        ConnectTimeout,
        SocketTimeout,
    };

    pub const Options = struct {
        /// Time allowed for DNS/TCP connection establishment. `0` means no
        /// timeout, matching MongoDB URI semantics.
        connect_timeout_ms: ?u32 = null,
        /// Per socket send/receive limit. `0` means no timeout.
        socket_timeout_ms: ?u32 = null,
    };

    /// Until `hello` tells us MongoDB's actual maxMessageSizeBytes,
    /// keep a defensive local limit.
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
        };
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close(self.io);
        self.* = undefined;
    }

    pub fn setCompressor(self: *Connection, compressor: ?compression.Compressor) void {
        self.compressor = compressor;
    }

    pub fn request(
        self: *Connection,
        allocator: Allocator,
        request_bytes: []const u8,
    ) ![]u8 {
        if (self.compressor) |compressor| {
            const compressed = try compression.compressMessage(allocator, request_bytes, compressor);
            defer allocator.free(compressed);
            try self.send(compressed);
        } else {
            try self.send(request_bytes);
        }
        return self.receive(allocator, default_max_message_size);
    }

    pub fn send(self: *Connection, bytes: []const u8) !void {
        const timeout_ms = activeTimeout(self.socket_timeout_ms) orelse
            return self.sendRaw(bytes);

        var operation = self.io.async(sendRaw, .{ self, bytes });
        var timer = self.io.async(Io.sleep, .{
            self.io,
            Io.Duration.fromMilliseconds(timeout_ms),
            Io.Clock.awake,
        });

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
                return error.SocketTimeout;
            },
        }
    }

    pub fn receive(
        self: *Connection,
        allocator: Allocator,
        max_message_size: usize,
    ) ![]u8 {
        const timeout_ms = activeTimeout(self.socket_timeout_ms) orelse
            return self.receiveRaw(allocator, max_message_size);

        var operation = self.io.async(receiveRaw, .{ self, allocator, max_message_size });
        var timer = self.io.async(Io.sleep, .{
            self.io,
            Io.Duration.fromMilliseconds(timeout_ms),
            Io.Clock.awake,
        });

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
                return error.SocketTimeout;
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
