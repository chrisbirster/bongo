const std = @import("std");
const bson = @import("../bson.zig");
const command_cursor = @import("command_cursor.zig");
const op_msg = @import("op_msg.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    EmptyDatabase,
    EmptyCollection,
};

pub const Cursor = command_cursor.Cursor;

pub fn listIndexes(
    collection: anytype,
    options: anytype,
) !Cursor {
    const client = collection.client;
    const request_id = command_cursor.takeRequestId(client);
    const request = try encode(
        client.allocator,
        request_id,
        collection.database_name,
        collection.name,
        options,
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

pub fn encode(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    options: anytype,
) ![]u8 {
    if (database_name.len == 0) return error.EmptyDatabase;
    if (collection_name.len == 0) return error.EmptyCollection;

    const Options = @TypeOf(options);
    if (@typeInfo(Options) != .@"struct") {
        @compileError("listIndexes options must be a struct");
    }

    var writer = try bson.Writer.init(allocator);
    errdefer writer.deinit();

    try writer.writeString("listIndexes", collection_name);

    inline for (@typeInfo(Options).@"struct".fields) |field| {
        try writeEncodedValue(
            &writer,
            allocator,
            field.name,
            @field(options, field.name),
        );
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
    const encoded = (try bson.Reader.get(holder, "value")) orelse unreachable;
    try writer.writeValue(name, encoded);
}

test "listIndexes encodes collection cursor batch size and comment" {
    const allocator = std.testing.allocator;

    const request = try encode(
        allocator,
        77,
        "test",
        "users",
        .{
            .cursor = .{ .batchSize = @as(i32, 1) },
            .comment = "bongo list indexes",
        },
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const cursor = (try bson.Reader.get(body, "cursor")).?.document;

    try std.testing.expectEqualStrings(
        "users",
        (try bson.Reader.get(body, "listIndexes")).?.string,
    );
    try std.testing.expectEqual(
        @as(i32, 1),
        (try bson.Reader.get(cursor, "batchSize")).?.int32,
    );
    try std.testing.expectEqualStrings(
        "bongo list indexes",
        (try bson.Reader.get(body, "comment")).?.string,
    );
    try std.testing.expectEqualStrings(
        "test",
        (try bson.Reader.get(body, "$db")).?.string,
    );
}

test "listIndexes rejects empty database and collection names" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.EmptyDatabase,
        encode(allocator, 78, "", "users", .{}),
    );
    try std.testing.expectError(
        error.EmptyCollection,
        encode(allocator, 79, "test", "", .{}),
    );
}
