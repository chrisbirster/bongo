const std = @import("std");
const bson = @import("../bson.zig");
const op_msg = @import("op_msg.zig");
const read_concern = @import("read_concern.zig");

const Allocator = std.mem.Allocator;
const ReadConcern = read_concern.ReadConcern;

pub fn encodeFind(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    concern: ReadConcern,
) ![]u8 {
    const concern_document = try read_concern.encode(allocator, concern);
    defer allocator.free(concern_document);

    return op_msg.encodeCommand(
        allocator,
        .{
            .find = collection_name,
            .filter = filter,
            .readConcern = bson.Value{ .document = concern_document },
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeFindOne(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    concern: ReadConcern,
) ![]u8 {
    const concern_document = try read_concern.encode(allocator, concern);
    defer allocator.free(concern_document);

    return op_msg.encodeCommand(
        allocator,
        .{
            .find = collection_name,
            .filter = filter,
            .limit = @as(i32, 1),
            .singleBatch = true,
            .readConcern = bson.Value{ .document = concern_document },
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeCountDocuments(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    skip: i64,
    limit: i64,
    concern: ReadConcern,
) ![]u8 {
    const concern_document = try read_concern.encode(allocator, concern);
    defer allocator.free(concern_document);

    return op_msg.encodeCommand(
        allocator,
        .{
            .count = collection_name,
            .query = filter,
            .skip = skip,
            .limit = limit,
            .readConcern = bson.Value{ .document = concern_document },
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeEstimatedDocumentCount(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    concern: ReadConcern,
) ![]u8 {
    const concern_document = try read_concern.encode(allocator, concern);
    defer allocator.free(concern_document);

    return op_msg.encodeCommand(
        allocator,
        .{
            .count = collection_name,
            .readConcern = bson.Value{ .document = concern_document },
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeDistinct(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    key: []const u8,
    filter: anytype,
    concern: ReadConcern,
) ![]u8 {
    const concern_document = try read_concern.encode(allocator, concern);
    defer allocator.free(concern_document);

    return op_msg.encodeCommand(
        allocator,
        .{
            .distinct = collection_name,
            .key = key,
            .query = filter,
            .readConcern = bson.Value{ .document = concern_document },
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

test "read command attaches readConcern document" {
    const allocator = std.testing.allocator;

    const request = try encodeFind(
        allocator,
        61,
        "test",
        "users",
        .{ .active = true },
        .{ .level = .majority },
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const concern = (try bson.Reader.get(body, "readConcern")).?.document;

    try std.testing.expectEqualStrings(
        "majority",
        (try bson.Reader.get(concern, "level")).?.string,
    );
}
