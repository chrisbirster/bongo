const std = @import("std");
const op_msg = @import("op_msg.zig");
const session_mod = @import("session.zig");

const Allocator = std.mem.Allocator;
const Session = session_mod.Session;

pub fn encodeInsertOne(
    allocator: Allocator,
    request_id: i32,
    session: *const Session,
    database_name: []const u8,
    collection_name: []const u8,
    document: anytype,
) ![]u8 {
    const documents = [_]@TypeOf(document){document};
    return op_msg.encodeCommand(
        allocator,
        .{
            .insert = collection_name,
            .documents = &documents,
            .ordered = true,
            .lsid = session.lsid(),
            .txnNumber = session.txn_number,
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeUpdateOne(
    allocator: Allocator,
    request_id: i32,
    session: *const Session,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    update: anytype,
    upsert: bool,
) ![]u8 {
    const UpdateSpec = struct {
        q: @TypeOf(filter),
        u: @TypeOf(update),
        multi: bool,
        upsert: bool,
    };
    const updates = [_]UpdateSpec{.{
        .q = filter,
        .u = update,
        .multi = false,
        .upsert = upsert,
    }};
    return op_msg.encodeCommand(
        allocator,
        .{
            .update = collection_name,
            .updates = &updates,
            .ordered = true,
            .lsid = session.lsid(),
            .txnNumber = session.txn_number,
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeDeleteOne(
    allocator: Allocator,
    request_id: i32,
    session: *const Session,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
) ![]u8 {
    const DeleteSpec = struct {
        q: @TypeOf(filter),
        limit: i32,
    };
    const deletes = [_]DeleteSpec{.{ .q = filter, .limit = 1 }};
    return op_msg.encodeCommand(
        allocator,
        .{
            .delete = collection_name,
            .deletes = &deletes,
            .ordered = true,
            .lsid = session.lsid(),
            .txnNumber = session.txn_number,
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeFindOneAndUpdate(
    allocator: Allocator,
    request_id: i32,
    session: *const Session,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    update: anytype,
    upsert: bool,
) ![]u8 {
    return op_msg.encodeCommand(
        allocator,
        .{
            .findAndModify = collection_name,
            .query = filter,
            .update = update,
            .upsert = upsert,
            .new = true,
            .lsid = session.lsid(),
            .txnNumber = session.txn_number,
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

test "retryable write command carries lsid and txnNumber" {
    var session = Session.init(std.testing.io);
    session.txn_number = 7;
    const request = try encodeInsertOne(
        std.testing.allocator,
        11,
        &session,
        "app",
        "cards",
        .{ ._id = @as(i64, 1) },
    );
    defer std.testing.allocator.free(request);

    const message = try op_msg.decode(request);
    const body = try message.body();
    try std.testing.expect((try @import("../bson.zig").Reader.get(body, "lsid")) != null);
    const txn = (try @import("../bson.zig").Reader.get(body, "txnNumber")).?;
    try std.testing.expectEqual(@as(i64, 7), txn.int64);
}
