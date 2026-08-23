const std = @import("std");
const builtin = @import("builtin");
const bson = @import("../bson.zig");
const op_msg = @import("op_msg.zig");
const Transport = @import("transport.zig").Transport;

const Allocator = std.mem.Allocator;

pub const Error = error{
    UnexpectedResponse,
    CommandFailed,
    InvalidHelloField,
};

pub const HandshakeOptions = struct {
    app_name: ?[]const u8 = null,
    load_balanced: bool = false,
};

pub const ServerDescription = struct {
    is_writable_primary: bool = false,
    secondary: bool = false,
    min_wire_version: ?i32 = null,
    max_wire_version: ?i32 = null,
    max_bson_object_size: ?i32 = null,
    max_message_size_bytes: ?i32 = null,
    max_write_batch_size: ?i32 = null,
    logical_session_timeout_minutes: ?i64 = null,
    replica_set_name: ?[]const u8 = null,
    connection_id: ?i64 = null,
    is_mongos: bool = false,
    hello_ok: bool = false,
    supports_transactions: bool = false,

    pub fn usableForWrites(self: ServerDescription) bool {
        return self.is_writable_primary or self.is_mongos;
    }

    pub fn supportsSessions(self: ServerDescription) bool {
        return self.logical_session_timeout_minutes != null;
    }

    pub fn supportsOpMsg(self: ServerDescription) bool {
        return (self.max_wire_version orelse 0) >= 6;
    }
};

/// Perform the first command on a newly established MongoDB socket.
///
/// The MongoDB handshake specification requires client metadata and
/// `backpressure: "2"` on the initial handshake. Without Stable API Bongo uses
/// the legacy `isMaster` spelling with `helloOk: true`; load-balanced mode uses
/// modern `hello`. Both are encoded as OP_MSG.
pub fn handshake(
    transport: *Transport,
    allocator: Allocator,
    request_id: i32,
    options: HandshakeOptions,
) !ServerDescription {
    const request = try encodeHandshake(allocator, request_id, options);
    defer allocator.free(request);
    return requestDescription(transport, allocator, request, request_id);
}

/// Backward-compatible name used by RuntimeClient for a newly-created socket.
/// Background SDAM monitoring uses dedicated subsequent `hello` probes.
pub fn hello(
    transport: *Transport,
    allocator: Allocator,
    request_id: i32,
) !ServerDescription {
    return handshake(transport, allocator, request_id, .{});
}

/// Issue a subsequent topology `hello` without initial-handshake metadata.
pub fn monitorHello(
    transport: *Transport,
    allocator: Allocator,
    request_id: i32,
) !ServerDescription {
    const request = try op_msg.encodeCommand(
        allocator,
        .{
            .hello = @as(i32, 1),
            .@"$db" = "admin",
        },
        .{ .request_id = request_id },
    );
    defer allocator.free(request);
    return requestDescription(transport, allocator, request, request_id);
}

fn encodeHandshake(
    allocator: Allocator,
    request_id: i32,
    options: HandshakeOptions,
) ![]u8 {
    const driver = .{
        .name = "bongo",
        .version = "0.6.0",
    };
    const os = .{
        .@"type" = osType(),
        .architecture = @tagName(builtin.cpu.arch),
    };
    const platform = "Zig " ++ builtin.zig_version_string;

    if (options.load_balanced) {
        if (options.app_name) |app_name| {
            return op_msg.encodeCommand(
                allocator,
                .{
                    .hello = @as(i32, 1),
                    .loadBalanced = true,
                    .backpressure = "2",
                    .client = .{
                        .application = .{ .name = app_name },
                        .driver = driver,
                        .os = os,
                        .platform = platform,
                    },
                    .@"$db" = "admin",
                },
                .{ .request_id = request_id },
            );
        }
        return op_msg.encodeCommand(
            allocator,
            .{
                .hello = @as(i32, 1),
                .loadBalanced = true,
                .backpressure = "2",
                .client = .{
                    .driver = driver,
                    .os = os,
                    .platform = platform,
                },
                .@"$db" = "admin",
            },
            .{ .request_id = request_id },
        );
    }

    if (options.app_name) |app_name| {
        return op_msg.encodeCommand(
            allocator,
            .{
                .isMaster = @as(i32, 1),
                .helloOk = true,
                .backpressure = "2",
                .client = .{
                    .application = .{ .name = app_name },
                    .driver = driver,
                    .os = os,
                    .platform = platform,
                },
                .@"$db" = "admin",
            },
            .{ .request_id = request_id },
        );
    }

    return op_msg.encodeCommand(
        allocator,
        .{
            .isMaster = @as(i32, 1),
            .helloOk = true,
            .backpressure = "2",
            .client = .{
                .driver = driver,
                .os = os,
                .platform = platform,
            },
            .@"$db" = "admin",
        },
        .{ .request_id = request_id },
    );
}

fn requestDescription(
    transport: *Transport,
    allocator: Allocator,
    request: []const u8,
    request_id: i32,
) !ServerDescription {
    const response = try transport.request(allocator, request);
    defer allocator.free(response);

    const message = try op_msg.decode(response);
    if (message.header.response_to != request_id) return error.UnexpectedResponse;
    const body = try message.body();
    if (!try commandSucceeded(body)) return error.CommandFailed;
    return parseHelloBody(body);
}

fn parseHelloBody(body: []const u8) !ServerDescription {
    var result: ServerDescription = .{};
    if (try bson.Reader.get(body, "isWritablePrimary")) |value| {
        result.is_writable_primary = try boolValue(value);
    } else if (try bson.Reader.get(body, "ismaster")) |value| {
        result.is_writable_primary = try boolValue(value);
    }

    if (try bson.Reader.get(body, "secondary")) |value| {
        result.secondary = try boolValue(value);
    }
    if (try bson.Reader.get(body, "helloOk")) |value| {
        result.hello_ok = try boolValue(value);
    }
    if (try bson.Reader.get(body, "minWireVersion")) |value| {
        result.min_wire_version = try int32Value(value);
    }
    if (try bson.Reader.get(body, "maxWireVersion")) |value| {
        result.max_wire_version = try int32Value(value);
    }
    if (try bson.Reader.get(body, "maxBsonObjectSize")) |value| {
        result.max_bson_object_size = try int32Value(value);
    }
    if (try bson.Reader.get(body, "maxMessageSizeBytes")) |value| {
        result.max_message_size_bytes = try int32Value(value);
    }
    if (try bson.Reader.get(body, "maxWriteBatchSize")) |value| {
        result.max_write_batch_size = try int32Value(value);
    }
    if (try bson.Reader.get(body, "logicalSessionTimeoutMinutes")) |value| {
        result.logical_session_timeout_minutes = try int64Value(value);
    }
    if (try bson.Reader.get(body, "connectionId")) |value| {
        result.connection_id = try int64Value(value);
    }
    if (try bson.Reader.get(body, "setName")) |value| {
        result.replica_set_name = switch (value) {
            .string => |v| v,
            else => return error.InvalidHelloField,
        };
    }
    if (try bson.Reader.get(body, "msg")) |value| {
        const msg = switch (value) {
            .string => |v| v,
            else => return error.InvalidHelloField,
        };
        result.is_mongos = std.mem.eql(u8, msg, "isdbgrid");
    }

    result.supports_transactions =
        result.supportsSessions() and
        (result.replica_set_name != null or result.is_mongos);
    return result;
}

fn boolValue(value: bson.Value) !bool {
    return switch (value) {
        .boolean => |v| v,
        else => error.InvalidHelloField,
    };
}

fn int32Value(value: bson.Value) !i32 {
    return switch (value) {
        .int32 => |v| v,
        .int64 => |v| std.math.cast(i32, v) orelse return error.InvalidHelloField,
        else => error.InvalidHelloField,
    };
}

fn int64Value(value: bson.Value) !i64 {
    return switch (value) {
        .int32 => |v| v,
        .int64 => |v| v,
        else => error.InvalidHelloField,
    };
}

fn osType() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "Linux",
        .macos => "Darwin",
        .windows => "Windows",
        .freebsd, .netbsd, .openbsd, .dragonfly => "BSD",
        else => "unknown",
    };
}

fn commandSucceeded(body: []const u8) !bool {
    const ok = (try bson.Reader.get(body, "ok")) orelse return false;
    return switch (ok) {
        .double => |v| v == 1.0,
        .int32 => |v| v == 1,
        .int64 => |v| v == 1,
        else => false,
    };
}

test "initial handshake includes driver metadata and backpressure version" {
    const bytes = try encodeHandshake(
        std.testing.allocator,
        700,
        .{ .app_name = "deez" },
    );
    defer std.testing.allocator.free(bytes);

    const message = try op_msg.decode(bytes);
    const body = try message.body();
    try std.testing.expectEqual(
        @as(i32, 1),
        (try bson.Reader.get(body, "isMaster")).?.int32,
    );
    try std.testing.expect((try bson.Reader.get(body, "helloOk")).?.boolean);
    try std.testing.expectEqualStrings(
        "2",
        (try bson.Reader.get(body, "backpressure")).?.string,
    );
    const client = (try bson.Reader.get(body, "client")).?.document;
    const driver = (try bson.Reader.get(client, "driver")).?.document;
    try std.testing.expectEqualStrings(
        "bongo",
        (try bson.Reader.get(driver, "name")).?.string,
    );
    const application = (try bson.Reader.get(client, "application")).?.document;
    try std.testing.expectEqualStrings(
        "deez",
        (try bson.Reader.get(application, "name")).?.string,
    );
}

test "hello parser records server capability limits" {
    const body = try bson.encode(std.testing.allocator, .{
        .ok = @as(i32, 1),
        .isWritablePrimary = true,
        .helloOk = true,
        .minWireVersion = @as(i32, 0),
        .maxWireVersion = @as(i32, 21),
        .maxBsonObjectSize = @as(i32, 16777216),
        .maxMessageSizeBytes = @as(i32, 48000000),
        .maxWriteBatchSize = @as(i32, 100000),
        .logicalSessionTimeoutMinutes = @as(i32, 30),
        .connectionId = @as(i64, 44),
        .setName = "rs0",
    });
    defer std.testing.allocator.free(body);

    const description = try parseHelloBody(body);
    try std.testing.expect(description.usableForWrites());
    try std.testing.expect(description.supportsSessions());
    try std.testing.expect(description.supports_transactions);
    try std.testing.expect(description.supportsOpMsg());
    try std.testing.expectEqual(@as(?i32, 16777216), description.max_bson_object_size);
    try std.testing.expectEqual(@as(?i32, 48000000), description.max_message_size_bytes);
    try std.testing.expectEqual(@as(?i32, 100000), description.max_write_batch_size);
    try std.testing.expectEqual(@as(?i64, 44), description.connection_id);
}
