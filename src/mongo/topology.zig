const std = @import("std");
const bson = @import("../bson.zig");
const op_msg = @import("op_msg.zig");
const Transport = @import("transport.zig").Transport;

const Allocator = std.mem.Allocator;

pub const Error = error{
    UnexpectedResponse,
    CommandFailed,
    InvalidHelloField,
};

pub const ServerDescription = struct {
    is_writable_primary: bool = false,
    secondary: bool = false,
    max_wire_version: ?i32 = null,
    logical_session_timeout_minutes: ?i64 = null,
    replica_set_name: ?[]const u8 = null,
    is_mongos: bool = false,
    supports_transactions: bool = false,

    pub fn usableForWrites(self: ServerDescription) bool {
        return self.is_writable_primary or self.is_mongos;
    }
};

/// Probe one connected server with `hello` before authentication. MongoDB
/// permits this command pre-auth and drivers use it for server selection.
pub fn hello(
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

    const response = try transport.request(allocator, request);
    defer allocator.free(response);

    const message = try op_msg.decode(response);
    if (message.header.response_to != request_id) return error.UnexpectedResponse;
    const body = try message.body();
    if (!try commandSucceeded(body)) return error.CommandFailed;

    var result: ServerDescription = .{};
    if (try bson.Reader.get(body, "isWritablePrimary")) |value| {
        result.is_writable_primary = switch (value) {
            .boolean => |v| v,
            else => return error.InvalidHelloField,
        };
    } else if (try bson.Reader.get(body, "ismaster")) |value| {
        result.is_writable_primary = switch (value) {
            .boolean => |v| v,
            else => return error.InvalidHelloField,
        };
    }

    if (try bson.Reader.get(body, "secondary")) |value| {
        result.secondary = switch (value) {
            .boolean => |v| v,
            else => return error.InvalidHelloField,
        };
    }
    if (try bson.Reader.get(body, "maxWireVersion")) |value| {
        result.max_wire_version = switch (value) {
            .int32 => |v| v,
            .int64 => |v| std.math.cast(i32, v) orelse return error.InvalidHelloField,
            else => return error.InvalidHelloField,
        };
    }
    if (try bson.Reader.get(body, "logicalSessionTimeoutMinutes")) |value| {
        result.logical_session_timeout_minutes = switch (value) {
            .int32 => |v| v,
            .int64 => |v| v,
            else => return error.InvalidHelloField,
        };
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

    // Multi-document transactions require sessions and either a replica set
    // or mongos. A standalone can expose logical sessions but cannot run a
    // transaction.
    result.supports_transactions =
        result.logical_session_timeout_minutes != null and
        (result.replica_set_name != null or result.is_mongos);
    return result;
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
