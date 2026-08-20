const std = @import("std");
const Connection = @import("connection.zig").Connection;
const TlsConnection = @import("tls_connection.zig").TlsConnection;

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Request-capable MongoDB transport used by the managed/runtime client.
///
/// TCP is stored inline. TLS is heap-owned because Zig's TLS client retains
/// pointers to the socket reader/writer interfaces and therefore requires a
/// stable address for the surrounding `TlsConnection`.
pub const Transport = union(enum) {
    tcp: Connection,
    tls: *TlsConnection,

    pub fn deinit(self: *Transport) void {
        switch (self.*) {
            .tcp => |*connection| connection.deinit(),
            .tls => |connection| connection.deinit(),
        }
        self.* = undefined;
    }

    pub fn request(
        self: *Transport,
        allocator: Allocator,
        request_bytes: []const u8,
    ) ![]u8 {
        return switch (self.*) {
            .tcp => |*connection| connection.request(allocator, request_bytes),
            .tls => |connection| connection.request(allocator, request_bytes),
        };
    }

    pub fn requestWithTimeoutMs(
        self: *Transport,
        allocator: Allocator,
        request_bytes: []const u8,
        timeout_ms: ?u64,
    ) ![]u8 {
        return switch (self.*) {
            .tcp => |*connection| connection.requestWithTimeoutMs(
                allocator,
                request_bytes,
                timeout_ms,
            ),
            .tls => |connection| connection.requestWithTimeoutMs(
                allocator,
                request_bytes,
                timeout_ms,
            ),
        };
    }

    pub fn io(self: *Transport) Io {
        return switch (self.*) {
            .tcp => |*connection| connection.io,
            .tls => |connection| connection.io,
        };
    }
};
