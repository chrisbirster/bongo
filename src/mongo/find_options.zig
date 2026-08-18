const std = @import("std");
const bson = @import("../bson.zig");
const command_cursor = @import("command_cursor.zig");
const op_msg = @import("op_msg.zig");
const read_concern = @import("read_concern.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidSkip,
    InvalidLimit,
};

pub const Cursor = command_cursor.Cursor;

/// Run a find command with an anonymous options struct.
///
/// Supported fields in this milestone are `projection`, `sort`, `skip`, and
/// `limit`. Omitted fields are not sent to MongoDB.
pub fn findWithOptions(
    collection: anytype,
    filter: anytype,
    options: anytype,
) !Cursor {
    const client = collection.client;
    const request_id = command_cursor.takeRequestId(client);
    const request = try encodeFind(
        client.allocator,
        request_id,
        collection.database_name,
        collection.name,
        filter,
        options,
        client.read_concern,
    );
    defer client.allocator.free(request);

    const response = try client.connection.request(
        client.allocator,
        request,
    );

    return Cursor.init(
        client,
        response,
        request_id,
        collection.database_name,
        collection.name,
        "firstBatch",
    );
}

pub fn encodeFind(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    options: anytype,
    concern: ?read_concern.ReadConcern,
) ![]u8 {
    const Options = @TypeOf(options);

    var writer = try bson.Writer.init(allocator);
    errdefer writer.deinit();

    try writer.writeString("find", collection_name);

    const filter_document = try bson.encode(allocator, filter);
    defer allocator.free(filter_document);
    try writer.writeDocument("filter", filter_document);

    if (comptime @hasField(Options, "projection")) {
        const document = try bson.encode(allocator, options.projection);
        defer allocator.free(document);
        try writer.writeDocument("projection", document);
    }

    if (comptime @hasField(Options, "sort")) {
        const document = try bson.encode(allocator, options.sort);
        defer allocator.free(document);
        try writer.writeDocument("sort", document);
    }

    if (comptime @hasField(Options, "skip")) {
        const skip: i64 = @intCast(options.skip);
        if (skip < 0) return error.InvalidSkip;
        try writer.writeInt64("skip", skip);
    }

    if (comptime @hasField(Options, "limit")) {
        const limit: i64 = @intCast(options.limit);
        if (limit < 0) return error.InvalidLimit;
        try writer.writeInt64("limit", limit);
    }

    if (concern) |configured| {
        const document = try read_concern.encode(allocator, configured);
        defer allocator.free(document);
        try writer.writeDocument("readConcern", document);
    }

    try writer.writeString("$db", database_name);

    const body = try writer.finish();
    defer allocator.free(body);
    return op_msg.encodeBody(
        allocator,
        body,
        .{ .request_id = request_id },
    );
}

test "find options encode projection sort skip and limit" {
    const allocator = std.testing.allocator;

    const request = try encodeFind(
        allocator,
        62,
        "test",
        "users",
        .{ .active = true },
        .{
            .projection = .{ .name = @as(i32, 1), ._id = @as(i32, 0) },
            .sort = .{ .score = @as(i32, -1) },
            .skip = @as(i64, 2),
            .limit = @as(i64, 5),
        },
        null,
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const projection = (try bson.Reader.get(body, "projection")).?.document;
    const sort = (try bson.Reader.get(body, "sort")).?.document;

    try std.testing.expectEqual(
        @as(i32, 1),
        (try bson.Reader.get(projection, "name")).?.int32,
    );
    try std.testing.expectEqual(
        @as(i32, -1),
        (try bson.Reader.get(sort, "score")).?.int32,
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

test "find options reject negative skip and limit" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.InvalidSkip,
        encodeFind(
            allocator,
            63,
            "test",
            "users",
            .{},
            .{ .skip = @as(i64, -1) },
            null,
        ),
    );
    try std.testing.expectError(
        error.InvalidLimit,
        encodeFind(
            allocator,
            64,
            "test",
            "users",
            .{},
            .{ .limit = @as(i64, -1) },
            null,
        ),
    );
}
