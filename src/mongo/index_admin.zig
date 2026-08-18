const std = @import("std");
const bson = @import("../bson.zig");
const command_cursor = @import("command_cursor.zig");
const command_response = @import("command_response.zig");
const op_msg = @import("op_msg.zig");
const write_concern = @import("write_concern.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    EmptyIndexName,
    InvalidIndexCount,
};

pub const CreateIndexResult = struct {
    num_indexes_before: ?i64,
    num_indexes_after: ?i64,
    created_collection_automatically: ?bool,
};

pub fn createIndex(
    collection: anytype,
    key: anytype,
    name: []const u8,
    options: anytype,
) !CreateIndexResult {
    if (name.len == 0) return error.EmptyIndexName;

    const client = collection.client;
    const request_id = command_cursor.takeRequestId(client);
    const request = try encodeCreateIndex(
        client.allocator,
        request_id,
        collection.database_name,
        collection.name,
        key,
        name,
        options,
        client.write_concern,
    );
    defer client.allocator.free(request);

    const response = try client.connection.request(
        client.allocator,
        request,
    );
    defer client.allocator.free(response);

    const body = try command_response.validate(response, request_id);
    return parseCreateIndexResult(body);
}

pub fn encodeCreateIndex(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    key: anytype,
    name: []const u8,
    options: anytype,
    concern: ?write_concern.WriteConcern,
) ![]u8 {
    const spec = try encodeIndexSpec(allocator, key, name, options);
    defer allocator.free(spec);

    var indexes_writer = try bson.Writer.init(allocator);
    errdefer indexes_writer.deinit();
    try indexes_writer.writeDocument("0", spec);
    const indexes = try indexes_writer.finish();
    defer allocator.free(indexes);

    if (concern) |configured| {
        const concern_document = try write_concern.encode(allocator, configured);
        defer allocator.free(concern_document);

        return op_msg.encodeCommand(
            allocator,
            .{
                .createIndexes = collection_name,
                .indexes = bson.Value{ .array = indexes },
                .writeConcern = bson.Value{ .document = concern_document },
                .@"$db" = database_name,
            },
            .{ .request_id = request_id },
        );
    }

    return op_msg.encodeCommand(
        allocator,
        .{
            .createIndexes = collection_name,
            .indexes = bson.Value{ .array = indexes },
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

fn encodeIndexSpec(
    allocator: Allocator,
    key: anytype,
    name: []const u8,
    options: anytype,
) ![]u8 {
    const Options = @TypeOf(options);
    if (@typeInfo(Options) != .@"struct") {
        @compileError("createIndex options must be a struct");
    }

    var writer = try bson.Writer.init(allocator);
    errdefer writer.deinit();

    const key_document = try bson.encode(allocator, key);
    defer allocator.free(key_document);
    try writer.writeDocument("key", key_document);
    try writer.writeString("name", name);

    inline for (@typeInfo(Options).@"struct".fields) |field| {
        try writeEncodedValue(
            &writer,
            allocator,
            field.name,
            @field(options, field.name),
        );
    }

    return writer.finish();
}

fn parseCreateIndexResult(body: []const u8) !CreateIndexResult {
    return .{
        .num_indexes_before = try optionalCount(body, "numIndexesBefore"),
        .num_indexes_after = try optionalCount(body, "numIndexesAfter"),
        .created_collection_automatically = try optionalBool(
            body,
            "createdCollectionAutomatically",
        ),
    };
}

fn optionalCount(body: []const u8, name: []const u8) !?i64 {
    const value = (try bson.Reader.get(body, name)) orelse return null;
    return switch (value) {
        .int32 => |number| number,
        .int64 => |number| number,
        else => error.InvalidIndexCount,
    };
}

fn optionalBool(body: []const u8, name: []const u8) !?bool {
    const value = (try bson.Reader.get(body, name)) orelse return null;
    return switch (value) {
        .boolean => |boolean| boolean,
        else => error.InvalidIndexCount,
    };
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

test "createIndex encodes compound key name options and write concern" {
    const allocator = std.testing.allocator;

    const request = try encodeCreateIndex(
        allocator,
        73,
        "test",
        "users",
        .{
            .category = @as(i32, 1),
            .score = @as(i32, -1),
        },
        "category_score",
        .{
            .unique = true,
            .sparse = true,
        },
        .{ .w = .majority },
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const indexes = (try bson.Reader.get(body, "indexes")).?.array;
    const spec = (try bson.Reader.get(indexes, "0")).?.document;
    const key = (try bson.Reader.get(spec, "key")).?.document;

    try std.testing.expectEqual(
        @as(i32, 1),
        (try bson.Reader.get(key, "category")).?.int32,
    );
    try std.testing.expectEqual(
        @as(i32, -1),
        (try bson.Reader.get(key, "score")).?.int32,
    );
    try std.testing.expectEqualStrings(
        "category_score",
        (try bson.Reader.get(spec, "name")).?.string,
    );
    try std.testing.expect((try bson.Reader.get(spec, "unique")).?.boolean);
    try std.testing.expect((try bson.Reader.get(body, "writeConcern")) != null);
}

test "createIndex result parses index counts" {
    const allocator = std.testing.allocator;
    const body = try bson.encode(
        allocator,
        .{
            .numIndexesBefore = @as(i32, 1),
            .numIndexesAfter = @as(i32, 2),
            .createdCollectionAutomatically = false,
        },
    );
    defer allocator.free(body);

    const result = try parseCreateIndexResult(body);
    try std.testing.expectEqual(@as(?i64, 1), result.num_indexes_before);
    try std.testing.expectEqual(@as(?i64, 2), result.num_indexes_after);
    try std.testing.expectEqual(false, result.created_collection_automatically.?);
}
