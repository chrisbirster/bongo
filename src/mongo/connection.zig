const std = @import("std");

const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;

pub const Connection = struct {
    io: Io,
    stream: net.Stream,

    pub const Error = error{
        InvalidMessageLength,
        MessageTooLarge,
    };

    /// Until `hello` tells us MongoDB's actual maxMessageSizeBytes,
    /// keep a defensive local limit.
    pub const default_max_message_size: usize = 48 * 1024 * 1024;

    pub fn connect(
        io: Io,
        host: []const u8,
        port: u16,
    ) !Connection {
        const address = try net.IpAddress.parse(host, port);

        const stream = try address.connect(io, .{
            .mode = .stream,
            .protocol = .tcp,
        });

        return .{
            .io = io,
            .stream = stream,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close(self.io);
        self.* = undefined;
    }

    /// Send one MongoDB wire message and read one MongoDB wire response.
    ///
    /// Caller owns the returned slice.
    pub fn request(
        self: *Connection,
        allocator: Allocator,
        request_bytes: []const u8,
    ) ![]u8 {
        try self.send(request_bytes);

        return self.receive(
            allocator,
            default_max_message_size,
        );
    }

    pub fn send(
        self: *Connection,
        bytes: []const u8,
    ) !void {
        var write_buffer: [4096]u8 = undefined;

        var stream_writer = self.stream.writer(
            self.io,
            &write_buffer,
        );

        try stream_writer.interface.writeAll(bytes);
        try stream_writer.interface.flush();
    }

    pub fn receive(
        self: *Connection,
        allocator: Allocator,
        max_message_size: usize,
    ) ![]u8 {
        var read_buffer: [4096]u8 = undefined;

        var stream_reader = self.stream.reader(
            self.io,
            &read_buffer,
        );

        //
        // MongoDB message header:
        //
        // int32 messageLength
        // int32 requestID
        // int32 responseTo
        // int32 opCode
        //
        // So first read messageLength.
        //

        var length_bytes: [4]u8 = undefined;

        try stream_reader.interface.readSliceAll(
            &length_bytes,
        );

        const message_length_i32 = std.mem.readInt(
            i32,
            &length_bytes,
            .little,
        );

        if (message_length_i32 < 16) {
            return error.InvalidMessageLength;
        }

        const message_length: usize =
            @intCast(message_length_i32);

        if (message_length > max_message_size) {
            return error.MessageTooLarge;
        }

        //
        // We already consumed the first four bytes, but op_msg.decode()
        // expects the complete MongoDB message.
        //

        const message = try allocator.alloc(
            u8,
            message_length,
        );
        errdefer allocator.free(message);

        @memcpy(
            message[0..4],
            &length_bytes,
        );

        try stream_reader.interface.readSliceAll(
            message[4..],
        );

        return message;
    }
};
