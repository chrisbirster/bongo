const std = @import("std");
const bson = @import("../bson.zig");
const find_and_modify = @import("find_and_modify.zig");
const op_msg = @import("op_msg.zig");
const replacement_ops = @import("replacement.zig");
const write_concern = @import("write_concern.zig");

const Allocator = std.mem.Allocator;
const WriteConcern = write_concern.WriteConcern;

pub fn encodeInsertOne(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    document: anytype,
    concern: WriteConcern,
) ![]u8 {
    const documents = [_]@TypeOf(document){document};
    return encodeInsert(
        allocator,
        request_id,
        database_name,
        collection_name,
        &documents,
        true,
        concern,
    );
}

pub fn encodeInsert(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    documents: anytype,
    ordered: bool,
    concern: WriteConcern,
) ![]u8 {
    const concern_document = try write_concern.encode(allocator, concern);
    defer allocator.free(concern_document);

    return op_msg.encodeCommand(
        allocator,
        .{
            .insert = collection_name,
            .documents = documents,
            .ordered = ordered,
            .writeConcern = bson.Value{ .document = concern_document },
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeUpdate(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    update_document: anytype,
    multi: bool,
    upsert: bool,
    concern: WriteConcern,
) ![]u8 {
    const UpdateSpec = struct {
        q: @TypeOf(filter),
        u: @TypeOf(update_document),
        multi: bool,
        upsert: bool,
    };
    const updates = [_]UpdateSpec{.{
        .q = filter,
        .u = update_document,
        .multi = multi,
        .upsert = upsert,
    }};

    const concern_document = try write_concern.encode(allocator, concern);
    defer allocator.free(concern_document);

    return op_msg.encodeCommand(
        allocator,
        .{
            .update = collection_name,
            .updates = &updates,
            .ordered = true,
            .writeConcern = bson.Value{ .document = concern_document },
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeReplaceOne(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    replacement: anytype,
    upsert: bool,
    concern: WriteConcern,
) ![]u8 {
    try replacement_ops.validateReplacement(replacement);
    return encodeUpdate(
        allocator,
        request_id,
        database_name,
        collection_name,
        filter,
        replacement,
        false,
        upsert,
        concern,
    );
}

pub fn encodeDelete(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    limit: i32,
    concern: WriteConcern,
) ![]u8 {
    std.debug.assert(limit == 0 or limit == 1);

    const DeleteSpec = struct {
        q: @TypeOf(filter),
        limit: i32,
    };
    const deletes = [_]DeleteSpec{.{
        .q = filter,
        .limit = limit,
    }};

    const concern_document = try write_concern.encode(allocator, concern);
    defer allocator.free(concern_document);

    return op_msg.encodeCommand(
        allocator,
        .{
            .delete = collection_name,
            .deletes = &deletes,
            .ordered = true,
            .writeConcern = bson.Value{ .document = concern_document },
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeFindAndModifyUpdate(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    update_document: anytype,
    return_document: find_and_modify.ReturnDocument,
    concern: WriteConcern,
) ![]u8 {
    const concern_document = try write_concern.encode(allocator, concern);
    defer allocator.free(concern_document);

    return op_msg.encodeCommand(
        allocator,
        .{
            .findAndModify = collection_name,
            .query = filter,
            .update = update_document,
            .new = return_document == .after,
            .writeConcern = bson.Value{ .document = concern_document },
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeFindAndModifyReplace(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    replacement: anytype,
    return_document: find_and_modify.ReturnDocument,
    concern: WriteConcern,
) ![]u8 {
    try replacement_ops.validateReplacement(replacement);
    return encodeFindAndModifyUpdate(
        allocator,
        request_id,
        database_name,
        collection_name,
        filter,
        replacement,
        return_document,
        concern,
    );
}

pub fn encodeFindAndModifyDelete(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    concern: WriteConcern,
) ![]u8 {
    const concern_document = try write_concern.encode(allocator, concern);
    defer allocator.free(concern_document);

    return op_msg.encodeCommand(
        allocator,
        .{
            .findAndModify = collection_name,
            .query = filter,
            .remove = true,
            .writeConcern = bson.Value{ .document = concern_document },
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

test "write command attaches writeConcern document" {
    const allocator = std.testing.allocator;

    const request = try encodeUpdate(
        allocator,
        60,
        "test",
        "users",
        .{ ._id = "write-concern" },
        .{ .@"$set" = .{ .name = "Bongo" } },
        false,
        false,
        .{
            .w = .majority,
            .journal = true,
            .wtimeout_ms = 1000,
        },
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const concern = (try bson.Reader.get(body, "writeConcern")).?.document;

    try std.testing.expectEqualStrings(
        "majority",
        (try bson.Reader.get(concern, "w")).?.string,
    );
    try std.testing.expect((try bson.Reader.get(concern, "j")).?.boolean);
    try std.testing.expectEqual(
        @as(i32, 1000),
        (try bson.Reader.get(concern, "wtimeout")).?.int32,
    );
}
