const std = @import("std");
const bson = @import("../bson.zig");
const op_msg = @import("op_msg.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    EmptyKey,
    UnexpectedResponse,
    CommandFailed,
    MissingValues,
    InvalidValues,
};

pub const Result = struct {
    allocator: Allocator,
    response_bytes: []u8,
    reader: bson.Reader,

    pub fn next(self: *Result) !?bson.Value {
        const element = (try self.reader.next()) orelse return null;
        return element.value;
    }

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.response_bytes);
        self.* = undefined;
    }
};

pub fn encode(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    key: []const u8,
    filter: anytype,
) ![]u8 {
    if (key.len == 0) return error.EmptyKey;

    return op_msg.encodeCommand(
        allocator,
        .{
            .distinct = collection_name,
            .key = key,
            .query = filter,
            .@"$db" = database_name,
        },
        .{
            .request_id = request_id,
        },
    );
}

pub fn parse(
    allocator: Allocator,
    response_bytes: []u8,
    expected_response_to: i32,
) !Result {
    errdefer allocator.free(response_bytes);

    const message = try op_msg.decode(response_bytes);
    if (message.header.response_to != expected_response_to) {
        return error.UnexpectedResponse;
    }

    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse
        return error.CommandFailed;
    if (!commandSucceeded(ok)) return error.CommandFailed;

    const values = (try bson.Reader.get(body, "values")) orelse
        return error.MissingValues;
    const array = switch (values) {
        .array => |value| value,
        else => return error.InvalidValues,
    };
    try bson.validateArray(array);

    return .{
        .allocator = allocator,
        .response_bytes = response_bytes,
        .reader = try bson.Reader.init(array),
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

fn expectParseError(expected: anyerror, body: anytype) !void {
    const allocator = std.testing.allocator;
    const response = try op_msg.encodeCommand(
        allocator,
        body,
        .{ .request_id = 90, .response_to = 57 },
    );

    if (parse(allocator, response, 57)) |result_value| {
        var result = result_value;
        result.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expect(err == expected);
    }
}

test "distinct encodes key and filter" {
    const allocator = std.testing.allocator;

    const request = try encode(
        allocator,
        57,
        "test",
        "users",
        "category",
        .{ .active = true },
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const query = (try bson.Reader.get(body, "query")).?.document;

    try std.testing.expectEqualStrings(
        "users",
        (try bson.Reader.get(body, "distinct")).?.string,
    );
    try std.testing.expectEqualStrings(
        "category",
        (try bson.Reader.get(body, "key")).?.string,
    );
    try std.testing.expect(
        (try bson.Reader.get(query, "active")).?.boolean,
    );
}

test "distinct rejects empty key" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.EmptyKey,
        encode(
            allocator,
            57,
            "test",
            "users",
            "",
            .{},
        ),
    );
}

test "distinct response streams values" {
    const allocator = std.testing.allocator;

    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .values = [_][]const u8{ "a", "b" },
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 90,
            .response_to = 57,
        },
    );

    var result = try parse(allocator, response, 57);
    defer result.deinit();

    try std.testing.expectEqualStrings("a", (try result.next()).?.string);
    try std.testing.expectEqualStrings("b", (try result.next()).?.string);
    try std.testing.expect((try result.next()) == null);
}

test "distinct response rejects mismatched response id" {
    const allocator = std.testing.allocator;
    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .values = [_][]const u8{"a"},
            .ok = @as(i32, 1),
        },
        .{ .request_id = 90, .response_to = 57 },
    );

    if (parse(allocator, response, 58)) |result_value| {
        var result = result_value;
        result.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expect(err == error.UnexpectedResponse);
    }
}

test "distinct response rejects command and values shape errors" {
    try expectParseError(error.CommandFailed, .{ .ok = @as(i32, 0) });
    try expectParseError(
        error.CommandFailed,
        .{ .values = [_][]const u8{"a"} },
    );
    try expectParseError(error.MissingValues, .{ .ok = @as(i32, 1) });
    try expectParseError(
        error.InvalidValues,
        .{ .values = "not an array", .ok = @as(i32, 1) },
    );
}
