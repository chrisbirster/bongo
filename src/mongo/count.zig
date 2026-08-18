const std = @import("std");
const bson = @import("../bson.zig");
const op_msg = @import("op_msg.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidSkip,
    InvalidLimit,
    UnexpectedResponse,
    CommandFailed,
    MissingCount,
    InvalidCount,
};

pub const Options = struct {
    skip: i64 = 0,
    limit: i64 = 0,
};

pub fn encodeCountDocuments(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    options: Options,
) ![]u8 {
    if (options.skip < 0) return error.InvalidSkip;
    if (options.limit < 0) return error.InvalidLimit;

    return op_msg.encodeCommand(
        allocator,
        .{
            .count = collection_name,
            .query = filter,
            .skip = options.skip,
            .limit = options.limit,
            .@"$db" = database_name,
        },
        .{
            .request_id = request_id,
        },
    );
}

pub fn parseCountResponse(
    response_bytes: []const u8,
    expected_response_to: i32,
) !i64 {
    const message = try op_msg.decode(response_bytes);
    if (message.header.response_to != expected_response_to) {
        return error.UnexpectedResponse;
    }

    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse
        return error.CommandFailed;
    if (!commandSucceeded(ok)) return error.CommandFailed;

    const value = (try bson.Reader.get(body, "n")) orelse
        return error.MissingCount;

    return switch (value) {
        .int32 => |number| number,
        .int64 => |number| number,
        else => error.InvalidCount,
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

test "countDocuments encodes query skip and limit" {
    const allocator = std.testing.allocator;

    const request = try encodeCountDocuments(
        allocator,
        53,
        "test",
        "users",
        .{ .active = true },
        .{
            .skip = 2,
            .limit = 5,
        },
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const query = (try bson.Reader.get(body, "query")).?.document;

    try std.testing.expectEqualStrings(
        "users",
        (try bson.Reader.get(body, "count")).?.string,
    );
    try std.testing.expect(
        (try bson.Reader.get(query, "active")).?.boolean,
    );
    try std.testing.expectEqual(
        @as(i64, 2),
        (try bson.Reader.get(body, "skip")).?.int64,
    );
    try std.testing.expectEqual(
        @as(i64, 5),
        (try bson.Reader.get(body, "limit")).?.int64,
    );
}

test "countDocuments rejects negative options" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.InvalidSkip,
        encodeCountDocuments(
            allocator,
            54,
            "test",
            "users",
            .{},
            .{ .skip = -1 },
        ),
    );

    try std.testing.expectError(
        error.InvalidLimit,
        encodeCountDocuments(
            allocator,
            55,
            "test",
            "users",
            .{},
            .{ .limit = -1 },
        ),
    );
}

test "count response returns integer n" {
    const allocator = std.testing.allocator;

    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .n = @as(i64, 12),
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 90,
            .response_to = 53,
        },
    );
    defer allocator.free(response);

    try std.testing.expectEqual(
        @as(i64, 12),
        try parseCountResponse(response, 53),
    );
}
