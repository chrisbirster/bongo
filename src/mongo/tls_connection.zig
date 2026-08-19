const std = @import("std");
const operation_timeout = @import("operation_timeout.zig");
const uri_options = @import("uri_options.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const net = Io.net;

const default_max_message_size = 48 * 1024 * 1024;
const tls_buffer_size = std.crypto.tls.Client.min_buffer_len;
const tls_entropy_size = 240;

const TimedTaskResult = union(enum) {
    operation: anyerror!void,
    timer: anyerror!void,
};

pub const Error = error{
    TlsDisabled,
    CaFileMustBeAbsolute,
    ClientCertificateUnsupported,
    MessageTooShort,
    InvalidMessageLength,
    MessageTooLarge,
    ConnectTimeout,
    SocketTimeout,
    OperationTimeout,
};

pub const Options = struct {
    verify_certificate: bool = true,
    verify_hostname: bool = true,
    ca_file: ?[]const u8 = null,
    certificate_key_file: ?[]const u8 = null,
    certificate_key_file_password: ?[]const u8 = null,
    connect_timeout_ms: ?u32 = null,
    socket_timeout_ms: ?u32 = null,
    operation_timeout_ms: ?u64 = null,

    pub fn fromConnectionOptions(options: uri_options.Options) Error!Options {
        if (options.tls != true) return error.TlsDisabled;

        var result: Options = .{
            .ca_file = options.tls_ca_file,
            .certificate_key_file = options.tls_certificate_key_file,
            .certificate_key_file_password = options.tls_certificate_key_file_password,
            .connect_timeout_ms = options.connect_timeout_ms,
            .socket_timeout_ms = options.socket_timeout_ms,
            .operation_timeout_ms = options.timeout_ms,
        };

        if (options.tls_insecure == true) {
            result.verify_certificate = false;
            result.verify_hostname = false;
        }
        if (options.tls_allow_invalid_certificates == true) {
            result.verify_certificate = false;
        }
        if (options.tls_allow_invalid_hostnames == true) {
            result.verify_hostname = false;
        }
        return result;
    }
};

/// Heap-owned TLS MongoDB transport backed by Zig 0.16's
/// `std.crypto.tls.Client`.
///
/// `std.crypto.tls.Client` stores pointers to the socket reader/writer and CA
/// context supplied during initialization, so this object must remain
/// pointer-stable for its entire lifetime.
pub const TlsConnection = struct {
    allocator: Allocator,
    io: Io,
    stream: net.Stream,
    stream_reader: net.Stream.Reader,
    stream_writer: net.Stream.Writer,
    tls_client: std.crypto.tls.Client,
    ca_bundle: std.crypto.Certificate.Bundle,
    ca_lock: Io.RwLock,
    socket_timeout_ms: ?u32,
    operation_timeout_ms: ?u64,

    socket_read_buffer: []u8,
    socket_write_buffer: []u8,
    tls_read_buffer: []u8,
    tls_write_buffer: []u8,

    pub fn connect(
        io: Io,
        allocator: Allocator,
        host: []const u8,
        port: u16,
        options: Options,
    ) !*TlsConnection {
        if (options.certificate_key_file != null or
            options.certificate_key_file_password != null)
        {
            // Zig 0.16 std.crypto.tls.Client cannot present a client
            // certificate/private key. See docs/zig-0.16-tls-gap.md.
            return error.ClientCertificateUnsupported;
        }

        const host_name = try net.HostName.init(host);
        const now = Io.Clock.real.now(io);

        // Before `handed_off` becomes true, locals own every resource. After
        // it becomes true, exactly one errdefer below owns cleanup through
        // `self`. This avoids the double-close/double-free bug found during the
        // original v0.3 release gate.
        var handed_off = false;

        var ca_bundle: std.crypto.Certificate.Bundle = .{
            .map = .empty,
            .bytes = .empty,
        };
        errdefer if (!handed_off) ca_bundle.deinit(allocator);

        if (options.verify_certificate) {
            if (options.ca_file) |ca_file| {
                if (!std.fs.path.isAbsolute(ca_file)) {
                    return error.CaFileMustBeAbsolute;
                }
                try ca_bundle.addCertsFromFilePathAbsolute(
                    allocator,
                    io,
                    now,
                    ca_file,
                );
            } else {
                try ca_bundle.rescan(allocator, io, now);
            }
        }

        const socket_read_buffer = try allocator.alloc(u8, tls_buffer_size);
        errdefer if (!handed_off) allocator.free(socket_read_buffer);
        const socket_write_buffer = try allocator.alloc(u8, tls_buffer_size);
        errdefer if (!handed_off) allocator.free(socket_write_buffer);
        const tls_read_buffer = try allocator.alloc(u8, tls_buffer_size);
        errdefer if (!handed_off) allocator.free(tls_read_buffer);
        const tls_write_buffer = try allocator.alloc(u8, tls_buffer_size);
        errdefer if (!handed_off) allocator.free(tls_write_buffer);

        var stream = host_name.connect(io, port, .{
            .mode = .stream,
            .protocol = .tcp,
            .timeout = timeoutFromMs(options.connect_timeout_ms),
        }) catch |err| switch (err) {
            error.Timeout => return error.ConnectTimeout,
            else => |e| return e,
        };
        errdefer if (!handed_off) stream.close(io);

        const self = try allocator.create(TlsConnection);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .stream_reader = stream.reader(io, socket_read_buffer),
            .stream_writer = stream.writer(io, socket_write_buffer),
            .tls_client = undefined,
            .ca_bundle = ca_bundle,
            .ca_lock = .init,
            .socket_timeout_ms = options.socket_timeout_ms,
            .operation_timeout_ms = options.operation_timeout_ms,
            .socket_read_buffer = socket_read_buffer,
            .socket_write_buffer = socket_write_buffer,
            .tls_read_buffer = tls_read_buffer,
            .tls_write_buffer = tls_write_buffer,
        };
        handed_off = true;

        var initialized = false;
        errdefer if (!initialized) self.cleanupUninitialized();

        var entropy: [tls_entropy_size]u8 = undefined;
        io.random(&entropy);

        self.tls_client = try std.crypto.tls.Client.init(
            &self.stream_reader.interface,
            &self.stream_writer.interface,
            .{
                .host = if (options.verify_hostname)
                    .{ .explicit = host }
                else
                    .no_verification,
                .ca = if (options.verify_certificate)
                    .{ .bundle = .{
                        .gpa = allocator,
                        .io = io,
                        .lock = &self.ca_lock,
                        .bundle = &self.ca_bundle,
                    } }
                else
                    .no_verification,
                .read_buffer = self.tls_read_buffer,
                .write_buffer = self.tls_write_buffer,
                .entropy = &entropy,
                .realtime_now = now,
                .allow_truncation_attacks = false,
            },
        );

        initialized = true;
        return self;
    }

    pub fn deinit(self: *TlsConnection) void {
        self.tls_client.end() catch {};
        self.stream_writer.interface.flush() catch {};
        self.stream.close(self.io);
        self.ca_bundle.deinit(self.allocator);
        self.allocator.free(self.socket_read_buffer);
        self.allocator.free(self.socket_write_buffer);
        self.allocator.free(self.tls_read_buffer);
        self.allocator.free(self.tls_write_buffer);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn cleanupUninitialized(self: *TlsConnection) void {
        self.stream.close(self.io);
        self.ca_bundle.deinit(self.allocator);
        self.allocator.free(self.socket_read_buffer);
        self.allocator.free(self.socket_write_buffer);
        self.allocator.free(self.tls_read_buffer);
        self.allocator.free(self.tls_write_buffer);
    }

    pub fn request(
        self: *TlsConnection,
        allocator: Allocator,
        request_bytes: []const u8,
    ) ![]u8 {
        return self.requestWithTimeoutMs(
            allocator,
            request_bytes,
            self.operation_timeout_ms,
        );
    }

    pub fn requestWithTimeoutMs(
        self: *TlsConnection,
        allocator: Allocator,
        request_bytes: []const u8,
        timeout_ms: ?u64,
    ) ![]u8 {
        if (request_bytes.len < 4) return error.MessageTooShort;
        const budget = try operation_timeout.Budget.start(self.io, timeout_ms);
        try self.sendWithin(request_bytes, budget);
        return self.receiveWithin(allocator, default_max_message_size, budget);
    }

    pub fn send(self: *TlsConnection, bytes: []const u8) !void {
        return self.sendWithin(bytes, .{});
    }

    pub fn receive(self: *TlsConnection, allocator: Allocator) ![]u8 {
        return self.receiveWithin(allocator, default_max_message_size, .{});
    }

    fn sendWithin(
        self: *TlsConnection,
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
        self: *TlsConnection,
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

    fn sendTask(self: *TlsConnection, bytes: []const u8) anyerror!void {
        try self.sendRaw(bytes);
    }

    fn receiveTask(
        self: *TlsConnection,
        allocator: Allocator,
        max_message_size: usize,
        response: *?[]u8,
    ) anyerror!void {
        response.* = try self.receiveRaw(allocator, max_message_size);
    }

    fn waitUntilTask(io: Io, deadline: Io.Clock.Timestamp) anyerror!void {
        try deadline.wait(io);
    }

    fn sendRaw(self: *TlsConnection, bytes: []const u8) !void {
        try self.tls_client.writer.writeAll(bytes);
        try self.tls_client.writer.flush();
        try self.stream_writer.interface.flush();
    }

    fn receiveRaw(
        self: *TlsConnection,
        allocator: Allocator,
        max_message_size: usize,
    ) ![]u8 {
        var length_bytes: [4]u8 = undefined;
        try self.tls_client.reader.readSliceAll(&length_bytes);

        const message_length_i32 = std.mem.readInt(i32, &length_bytes, .little);
        if (message_length_i32 < 16) return error.InvalidMessageLength;
        const message_length: usize = @intCast(message_length_i32);
        if (message_length > max_message_size) return error.MessageTooLarge;

        const message = try allocator.alloc(u8, message_length);
        errdefer allocator.free(message);
        @memcpy(message[0..4], &length_bytes);
        try self.tls_client.reader.readSliceAll(message[4..]);
        return message;
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

test "URI TLS settings map to verification and timeout controls" {
    var options = try uri_options.parse(
        std.testing.allocator,
        "mongodb://localhost?tls=true&tlsAllowInvalidHostnames=true&connectTimeoutMS=5000&socketTimeoutMS=6000&timeoutMS=7000",
    );
    defer options.deinit();

    const tls_options = try Options.fromConnectionOptions(options);
    try std.testing.expect(tls_options.verify_certificate);
    try std.testing.expect(!tls_options.verify_hostname);
    try std.testing.expectEqual(@as(u32, 5000), tls_options.connect_timeout_ms.?);
    try std.testing.expectEqual(@as(u32, 6000), tls_options.socket_timeout_ms.?);
    try std.testing.expectEqual(@as(u64, 7000), tls_options.operation_timeout_ms.?);
}

test "tlsInsecure disables certificate and hostname verification" {
    var options = try uri_options.parse(
        std.testing.allocator,
        "mongodb://localhost?tls=true&tlsInsecure=true",
    );
    defer options.deinit();

    const tls_options = try Options.fromConnectionOptions(options);
    try std.testing.expect(!tls_options.verify_certificate);
    try std.testing.expect(!tls_options.verify_hostname);
}

test "TLS transport rejects disabled URI option" {
    var options = try uri_options.parse(
        std.testing.allocator,
        "mongodb://localhost?tls=false",
    );
    defer options.deinit();

    try std.testing.expectError(error.TlsDisabled, Options.fromConnectionOptions(options));
}
