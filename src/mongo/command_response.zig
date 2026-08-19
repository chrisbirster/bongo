const std = @import("std");
const bson = @import("../bson.zig");
const client_mod = @import("client.zig");
const op_msg = @import("op_msg.zig");

pub const Error = error{
    UnexpectedResponse,
    CommandFailed,
    WriteConcernFailed,
};

pub fn validate(
    response_bytes: []const u8,
    expected_response_to: i32,
) ![]const u8 {
    const message = try op_msg.decode(response_bytes);
    if (message.header.response_to != expected_response_to) {
        return error.UnexpectedResponse;
    }

    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse
        return error.CommandFailed;
    if (!commandSucceeded(ok)) return error.CommandFailed;

    if ((try bson.Reader.get(body, "writeConcernError")) != null) {
        return error.WriteConcernFailed;
    }

    return body;
}

pub fn sendVoid(
    client: *client_mod.Client,
    request: []const u8,
    request_id: i32,
) !void {
    const response = try client.connection.request(
        client.allocator,
        request,
    );
    defer client.allocator.free(response);
    _ = try validate(response, request_id);
}

pub fn sendOwned(
    client: *client_mod.Client,
    request: []const u8,
    request_id: i32,
) !client_mod.OwnedDocument {
    const response = try client.connection.request(
        client.allocator,
        request,
    );
    defer client.allocator.free(response);
    const body = try validate(response, request_id);

    return .{
        .allocator = client.allocator,
        .bytes = try client.allocator.dupe(u8, body),
    };
}

fn commandSucceeded(value: bson.Value) bool {
    return switch (value) {
        .double => |number| number == 1.0,
        .int32 => |number| number == 1,
        .int64 => |number| number == 1,
        else => false,
    };
}

test "command response accepts successful reply" {
    const allocator = std.testing.allocator;
    const response = try op_msg.encodeCommand(
        allocator,
        .{ .ok = @as(i32, 1), .value = @as(i32, 7) },
        .{ .request_id = 90, .response_to = 41 },
    );
    defer allocator.free(response);

    const body = try validate(response, 41);
    try std.testing.expectEqual(
        @as(i32, 7),
        (try bson.Reader.get(body, "value")).?.int32,
    );
}

test "command response rejects mismatched response id" {
    const allocator = std.testing.allocator;
    const response = try op_msg.encodeCommand(
        allocator,
        .{ .ok = @as(f64, 1.0) },
        .{ .request_id = 90, .response_to = 41 },
    );
    defer allocator.free(response);

    try std.testing.expectError(
        error.UnexpectedResponse,
        validate(response, 42),
    );
}

test "command response rejects missing failed and invalid ok" {
    const allocator = std.testing.allocator;

    const missing = try op_msg.encodeCommand(
        allocator,
        .{ .value = @as(i32, 1) },
        .{ .request_id = 90, .response_to = 41 },
    );
    defer allocator.free(missing);
    try std.testing.expectError(error.CommandFailed, validate(missing, 41));

    const failed = try op_msg.encodeCommand(
        allocator,
        .{ .ok = @as(i32, 0) },
        .{ .request_id = 91, .response_to = 41 },
    );
    defer allocator.free(failed);
    try std.testing.expectError(error.CommandFailed, validate(failed, 41));

    const invalid = try op_msg.encodeCommand(
        allocator,
        .{ .ok = "yes" },
        .{ .request_id = 92, .response_to = 41 },
    );
    defer allocator.free(invalid);
    try std.testing.expectError(error.CommandFailed, validate(invalid, 41));
}

test "command response surfaces write concern error" {
    const allocator = std.testing.allocator;
    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .ok = @as(f64, 1.0),
            .writeConcernError = .{
                .code = @as(i32, 64),
                .errmsg = "write concern timeout",
            },
        },
        .{ .request_id = 90, .response_to = 41 },
    );
    defer allocator.free(response);

    try std.testing.expectError(
        error.WriteConcernFailed,
        validate(response, 41),
    );
}
