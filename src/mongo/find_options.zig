const std = @import("std");
const bson = @import("../bson.zig");
const command_cursor = @import("command_cursor.zig");
const op_msg = @import("op_msg.zig");
const read_concern = @import("read_concern.zig");
const read_preference = @import("read_preference.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidSkip,
    InvalidLimit,
    InvalidMaxTime,
};

pub const Cursor = command_cursor.Cursor;

/// Run a find command with an anonymous options struct.
///
/// Supported fields are `projection`, `sort`, `skip`, `limit`, `collation`,
/// `hint`, `comment`, `maxTimeMS`, and `let`. Omitted fields are not sent.
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
    return encodeFindWithReadPreference(
        allocator,
        request_id,
        database_name,
        collection_name,
        filter,
        options,
        concern,
        null,
    );
}

/// Encode a find command for a server already selected by SDAM.
///
/// OP_MSG has no SecondaryOk flag. For any non-primary mode MongoDB requires
/// the `$readPreference` global command argument so a replica-set member can
/// validate that its role still matches the driver's selection decision.
pub fn encodeFindWithReadPreference(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    options: anytype,
    concern: ?read_concern.ReadConcern,
    preference_mode: ?read_preference.Mode,
) ![]u8 {
    const Options = @TypeOf(options);

    var writer = try bson.Writer.init(allocator);
    errdefer writer.deinit();

    try writer.writeString("find", collection_name);

    const filter_document = try bson.encode(allocator, filter);
    defer allocator.free(filter_document);
    try writer.writeDocument("filter", filter_document);

    if (comptime @hasField(Options, "projection")) {
        try writeEncodedValue(
            &writer,
            allocator,
            "projection",
            options.projection,
        );
    }

    if (comptime @hasField(Options, "sort")) {
        try writeEncodedValue(&writer, allocator, "sort", options.sort);
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

    if (comptime @hasField(Options, "collation")) {
        try writeEncodedValue(
            &writer,
            allocator,
            "collation",
            options.collation,
        );
    }

    if (comptime @hasField(Options, "hint")) {
        try writeEncodedValue(&writer, allocator, "hint", options.hint);
    }

    if (comptime @hasField(Options, "comment")) {
        try writeEncodedValue(&writer, allocator, "comment", options.comment);
    }

    if (comptime @hasField(Options, "maxTimeMS")) {
        const timeout: i64 = @intCast(options.maxTimeMS);
        if (timeout < 0) return error.InvalidMaxTime;
        try writer.writeInt64("maxTimeMS", timeout);
    }

    if (comptime @hasField(Options, "let")) {
        try writeEncodedValue(&writer, allocator, "let", options.let);
    }

    if (concern) |configured| {
        const document = try read_concern.encode(allocator, configured);
        defer allocator.free(document);
        try writer.writeDocument("readConcern", document);
    }

    if (preference_mode) |mode| {
        if (mode != .primary) {
            const document = try bson.encode(allocator, .{
                .mode = mode.wireName(),
            });
            defer allocator.free(document);
            try writer.writeDocument("$readPreference", document);
        }
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

fn writeEncodedValue(
    writer: *bson.Writer,
    allocator: Allocator,
    name: []const u8,
    value: anytype,
) !void {
    const holder = try bson.encode(allocator, .{ .value = value });
    defer allocator.free(holder);
    const encoded = (try bson.Reader.get(holder, "value")) orelse
        unreachable;
    try writer.writeValue(name, encoded);
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

test "advanced find options are encoded only when supplied" {
    const allocator = std.testing.allocator;

    const request = try encodeFind(
        allocator,
        65,
        "test",
        "users",
        .{},
        .{
            .collation = .{ .locale = "en", .strength = @as(i32, 2) },
            .hint = "_id_",
            .comment = "bongo advanced options",
            .maxTimeMS = @as(i64, 1000),
            .let = .{ .threshold = @as(i32, 2) },
        },
        null,
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const collation = (try bson.Reader.get(body, "collation")).?.document;
    const variables = (try bson.Reader.get(body, "let")).?.document;

    try std.testing.expectEqualStrings(
        "en",
        (try bson.Reader.get(collation, "locale")).?.string,
    );
    try std.testing.expectEqualStrings(
        "_id_",
        (try bson.Reader.get(body, "hint")).?.string,
    );
    try std.testing.expectEqualStrings(
        "bongo advanced options",
        (try bson.Reader.get(body, "comment")).?.string,
    );
    try std.testing.expectEqual(
        @as(i64, 1000),
        (try bson.Reader.get(body, "maxTimeMS")).?.int64,
    );
    try std.testing.expectEqual(
        @as(i32, 2),
        (try bson.Reader.get(variables, "threshold")).?.int32,
    );
    try std.testing.expect((try bson.Reader.get(body, "sort")) == null);
}

test "non-primary find encodes OP_MSG read preference" {
    const allocator = std.testing.allocator;

    const request = try encodeFindWithReadPreference(
        allocator,
        67,
        "test",
        "users",
        .{},
        .{},
        null,
        .secondary,
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const preference = (try bson.Reader.get(body, "$readPreference")).?.document;
    try std.testing.expectEqualStrings(
        "secondary",
        (try bson.Reader.get(preference, "mode")).?.string,
    );
}

test "primary find omits OP_MSG read preference" {
    const allocator = std.testing.allocator;

    const request = try encodeFindWithReadPreference(
        allocator,
        68,
        "test",
        "users",
        .{},
        .{},
        null,
        .primary,
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    try std.testing.expect((try bson.Reader.get(body, "$readPreference")) == null);
}

test "find options reject negative numeric controls" {
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
    try std.testing.expectError(
        error.InvalidMaxTime,
        encodeFind(
            allocator,
            66,
            "test",
            "users",
            .{},
            .{ .maxTimeMS = @as(i64, -1) },
            null,
        ),
    );
}
