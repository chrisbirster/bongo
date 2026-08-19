const std = @import("std");
const bson = @import("../bson.zig");
const op_msg = @import("op_msg.zig");
const uri_options = @import("uri_options.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    WrongMechanism,
    TlsRequired,
    InvalidAuthSource,
    PasswordNotAllowed,
    MissingClientCertificate,
    UnexpectedResponse,
    CommandFailed,
};

pub const Credentials = struct {
    username: ?[]const u8,
    certificate_key_file: []const u8,

    pub fn fromConnectionOptions(options: uri_options.Options) Error!Credentials {
        if (options.auth_mechanism != .mongodb_x509) return error.WrongMechanism;
        if (options.tls != true) return error.TlsRequired;
        if (options.password != null) return error.PasswordNotAllowed;
        if (options.auth_source) |source| {
            if (!std.mem.eql(u8, source, "$external")) return error.InvalidAuthSource;
        }

        return .{
            .username = options.username,
            .certificate_key_file = options.tls_certificate_key_file orelse
                return error.MissingClientCertificate,
        };
    }
};

/// Authenticate an already-established mutual-TLS transport with MongoDB's
/// MONGODB-X509 `authenticate` command.
///
/// The transport is generic on purpose: the authentication command itself is
/// independent of the TLS backend. Zig 0.16's `std.crypto.tls.Client` does not
/// currently expose client-certificate presentation, so Bongo's standard
/// `TlsConnection` rejects client cert configuration rather than pretending
/// mutual TLS was established.
pub fn authenticate(
    connection: anytype,
    allocator: Allocator,
    username: ?[]const u8,
) !void {
    const request_id: i32 = 1100;
    const request = if (username) |user|
        try op_msg.encodeCommand(
            allocator,
            .{
                .authenticate = @as(i32, 1),
                .mechanism = "MONGODB-X509",
                .user = user,
                .@"$db" = "$external",
            },
            .{ .request_id = request_id },
        )
    else
        try op_msg.encodeCommand(
            allocator,
            .{
                .authenticate = @as(i32, 1),
                .mechanism = "MONGODB-X509",
                .@"$db" = "$external",
            },
            .{ .request_id = request_id },
        );
    defer allocator.free(request);

    const response = try connection.request(allocator, request);
    defer allocator.free(response);
    try validateResponse(response, request_id);
}

pub fn validateResponse(response: []const u8, expected_response_to: i32) !void {
    const message = try op_msg.decode(response);
    if (message.header.response_to != expected_response_to) {
        return error.UnexpectedResponse;
    }

    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse
        return error.CommandFailed;

    const succeeded = switch (ok) {
        .double => |value| value == 1.0,
        .int32 => |value| value == 1,
        .int64 => |value| value == 1,
        else => false,
    };
    if (!succeeded) return error.CommandFailed;
}

pub fn encodeCommand(
    allocator: Allocator,
    request_id: i32,
    username: ?[]const u8,
) ![]u8 {
    return if (username) |user|
        op_msg.encodeCommand(
            allocator,
            .{
                .authenticate = @as(i32, 1),
                .mechanism = "MONGODB-X509",
                .user = user,
                .@"$db" = "$external",
            },
            .{ .request_id = request_id },
        )
    else
        op_msg.encodeCommand(
            allocator,
            .{
                .authenticate = @as(i32, 1),
                .mechanism = "MONGODB-X509",
                .@"$db" = "$external",
            },
            .{ .request_id = request_id },
        );
}

test "X.509 command uses $external and includes configured username" {
    const bytes = try encodeCommand(
        std.testing.allocator,
        77,
        "CN=client,O=Bongo",
    );
    defer std.testing.allocator.free(bytes);

    const message = try op_msg.decode(bytes);
    const body = try message.body();
    try std.testing.expectEqualStrings(
        "MONGODB-X509",
        (try bson.Reader.get(body, "mechanism")).?.string,
    );
    try std.testing.expectEqualStrings(
        "$external",
        (try bson.Reader.get(body, "$db")).?.string,
    );
    try std.testing.expectEqualStrings(
        "CN=client,O=Bongo",
        (try bson.Reader.get(body, "user")).?.string,
    );
}

test "X.509 command may omit username" {
    const bytes = try encodeCommand(std.testing.allocator, 78, null);
    defer std.testing.allocator.free(bytes);

    const message = try op_msg.decode(bytes);
    const body = try message.body();
    try std.testing.expect((try bson.Reader.get(body, "user")) == null);
}

test "X.509 connection options require TLS and client certificate" {
    var missing_tls = try uri_options.parse(
        std.testing.allocator,
        "mongodb://localhost?authMechanism=MONGODB-X509",
    );
    defer missing_tls.deinit();
    try std.testing.expectError(
        error.TlsRequired,
        Credentials.fromConnectionOptions(missing_tls),
    );

    var missing_cert = try uri_options.parse(
        std.testing.allocator,
        "mongodb://localhost?authMechanism=MONGODB-X509&tls=true",
    );
    defer missing_cert.deinit();
    try std.testing.expectError(
        error.MissingClientCertificate,
        Credentials.fromConnectionOptions(missing_cert),
    );

    var valid = try uri_options.parse(
        std.testing.allocator,
        "mongodb://localhost?authMechanism=MONGODB-X509&tls=true&tlsCertificateKeyFile=%2Ftmp%2Fclient.pem",
    );
    defer valid.deinit();
    const credentials = try Credentials.fromConnectionOptions(valid);
    try std.testing.expectEqualStrings("/tmp/client.pem", credentials.certificate_key_file);
}
