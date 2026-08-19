const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const net = Io.net;
const uri_options = @import("uri_options.zig");

const default_max_message_size = 48 * 1024 * 1024;
const tls_buffer_size = std.crypto.tls.Client.min_buffer_len;

pub const Error = error{
    TlsDisabled,
    CaFileMustBeAbsolute,
    ClientCertificateUnsupported,
    MessageTooShort,
    InvalidMessageLength,
    ResponseTooLarge,
};

pub const Options = struct {
    verify_certificate: bool = true,
    verify_hostname: bool = true,
    ca_file: ?[]const u8 = null,
    certificate_key_file: ?[]const u8 = null,
    certificate_key_file_password: ?[]const u8 = null,

    pub fn fromConnectionOptions(options: uri_options.Options) Error!Options {
        if (options.tls != true) return error.TlsDisabled;

        var result: Options = .{
            .ca_file = options.tls_ca_file,
            .certificate_key_file = options.tls_certificate_key_file,
            .certificate_key_file_password = options.tls_certificate_key_file_password,
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

/// Heap-owned TLS MongoDB transport.
///
/// `std.crypto.tls.Client` stores pointers to the socket reader/writer
/// interfaces supplied during initialization, so the surrounding object must
/// remain pointer-stable for the entire connection lifetime.
pub const TlsConnection = struct {
    allocator: Allocator,
    io: Io,
    stream: net.Stream,
    stream_reader: net.Stream.Reader,
    stream_writer: net.Stream.Writer,
    tls_client: std.crypto.tls.Client,
    ca_bundle: std.crypto.Certificate.Bundle,

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
            // Zig 0.16's std.crypto.tls.Client does not expose a client
            // certificate callback. X.509/mTLS is handled separately by
            // BONGO-0044 rather than silently ignoring certificate options.
            return error.ClientCertificateUnsupported;
        }

        const host_name = try net.HostName.init(host);
        const now = Io.Clock.real.now(io);

        var ca_bundle: std.crypto.Certificate.Bundle = .{};
        errdefer ca_bundle.deinit(allocator);

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
        errdefer allocator.free(socket_read_buffer);
        const socket_write_buffer = try allocator.alloc(u8, tls_buffer_size);
        errdefer allocator.free(socket_write_buffer);
        const tls_read_buffer = try allocator.alloc(u8, tls_buffer_size);
        errdefer allocator.free(tls_read_buffer);
        const tls_write_buffer = try allocator.alloc(u8, tls_buffer_size);
        errdefer allocator.free(tls_write_buffer);

        var stream = try host_name.connect(io, port, .{
            .mode = .stream,
            .protocol = .tcp,
        });
        errdefer stream.close(io);

        const self = try allocator.create(TlsConnection);
        errdefer allocator.destroy(self);

        // Initialize all address-stable fields before constructing the TLS
        // client. Its reader/writer pointers target these exact fields.
        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .stream_reader = stream.reader(io, socket_read_buffer),
            .stream_writer = stream.writer(io, socket_write_buffer),
            .tls_client = undefined,
            .ca_bundle = ca_bundle,
            .socket_read_buffer = socket_read_buffer,
            .socket_write_buffer = socket_write_buffer,
            .tls_read_buffer = tls_read_buffer,
            .tls_write_buffer = tls_write_buffer,
        };

        var initialized = false;
        errdefer if (!initialized) {
            self.stream.close(io);
            self.ca_bundle.deinit(allocator);
            allocator.free(self.socket_read_buffer);
            allocator.free(self.socket_write_buffer);
            allocator.free(self.tls_read_buffer);
            allocator.free(self.tls_write_buffer);
        };

        // Ownership of the CA bundle and allocated buffers has moved into
        // `self`, so disable the pre-handoff cleanup paths.
        ca_bundle = .{};

        var entropy: [176]u8 = undefined;
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
                    .{ .bundle = self.ca_bundle }
                else
                    .no_verification,
                .read_buffer = self.tls_read_buffer,
                .write_buffer = self.tls_write_buffer,
                .entropy = &entropy,
                .realtime_now_seconds = now.toSeconds(),
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

    pub fn send(self: *TlsConnection, bytes: []const u8) !void {
        try self.tls_client.writer.writeAll(bytes);
        try self.tls_client.writer.flush();
        try self.stream_writer.interface.flush();
    }

    pub fn receive(self: *TlsConnection, allocator: Allocator) ![]u8 {
        var header: [4]u8 = undefined;
        try self.tls_client.reader.readSliceAll(&header);

        const message_len_signed = std.mem.readInt(i32, &header, .little);
        if (message_len_signed < 4) return error.InvalidMessageLength;

        const message_len: usize = @intCast(message_len_signed);
        if (message_len > default_max_message_size) return error.ResponseTooLarge;

        const result = try allocator.alloc(u8, message_len);
        errdefer allocator.free(result);
        @memcpy(result[0..4], &header);
        try self.tls_client.reader.readSliceAll(result[4..]);
        return result;
    }

    pub fn request(
        self: *TlsConnection,
        allocator: Allocator,
        request_bytes: []const u8,
    ) ![]u8 {
        if (request_bytes.len < 4) return error.MessageTooShort;
        try self.send(request_bytes);
        return self.receive(allocator);
    }
};

test "URI TLS settings map to verification controls" {
    var options = try uri_options.parse(
        std.testing.allocator,
        "mongodb://localhost?tls=true&tlsAllowInvalidHostnames=true",
    );
    defer options.deinit();

    const tls_options = try Options.fromConnectionOptions(options);
    try std.testing.expect(tls_options.verify_certificate);
    try std.testing.expect(!tls_options.verify_hostname);
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

    try std.testing.expectError(
        error.TlsDisabled,
        Options.fromConnectionOptions(options),
    );
}
