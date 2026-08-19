const std = @import("std");
const bson = @import("../bson.zig");
const crud = @import("crud.zig");
const op_msg = @import("op_msg.zig");
const session_mod = @import("session.zig");
const Transport = @import("transport.zig").Transport;

const Allocator = std.mem.Allocator;
pub const Session = session_mod.Session;
pub const Options = session_mod.TransactionOptions;

pub const Error = error{
    UnexpectedResponse,
    CommandFailed,
    InvalidTransactionState,
};

pub fn begin(session: *Session, options: Options) !void {
    try session.beginTransaction(options);
}

/// Transactional insert used by Deez's immutable review append.
pub fn insertOne(
    transport: *Transport,
    allocator: Allocator,
    session: *Session,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    document: anytype,
) !crud.InsertOneResult {
    const documents = [_]@TypeOf(document){document};
    const first = session.isFirstTransactionCommand();
    const lsid = session.lsid();

    const request = if (first)
        try op_msg.encodeCommand(
            allocator,
            .{
                .insert = collection_name,
                .documents = &documents,
                .ordered = true,
                .lsid = lsid,
                .txnNumber = session.txn_number,
                .startTransaction = true,
                .autocommit = false,
                .readConcern = readConcernDocument(session),
                .@"$db" = database_name,
            },
            .{ .request_id = request_id },
        )
    else
        try op_msg.encodeCommand(
            allocator,
            .{
                .insert = collection_name,
                .documents = &documents,
                .ordered = true,
                .lsid = lsid,
                .txnNumber = session.txn_number,
                .autocommit = false,
                .@"$db" = database_name,
            },
            .{ .request_id = request_id },
        );
    defer allocator.free(request);

    const response = try transport.request(allocator, request);
    defer allocator.free(response);
    const result = try crud.parseInsertOneResponse(response, request_id);
    try session.markCommandSucceeded();
    return result;
}

/// Transactional single-document update/upsert used by Deez's derived
/// scheduler-state write.
pub fn updateOne(
    transport: *Transport,
    allocator: Allocator,
    session: *Session,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    update: anytype,
    upsert: bool,
) !crud.UpdateResult {
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
    const first = session.isFirstTransactionCommand();
    const lsid = session.lsid();

    const request = if (first)
        try op_msg.encodeCommand(
            allocator,
            .{
                .update = collection_name,
                .updates = &updates,
                .ordered = true,
                .lsid = lsid,
                .txnNumber = session.txn_number,
                .startTransaction = true,
                .autocommit = false,
                .readConcern = readConcernDocument(session),
                .@"$db" = database_name,
            },
            .{ .request_id = request_id },
        )
    else
        try op_msg.encodeCommand(
            allocator,
            .{
                .update = collection_name,
                .updates = &updates,
                .ordered = true,
                .lsid = lsid,
                .txnNumber = session.txn_number,
                .autocommit = false,
                .@"$db" = database_name,
            },
            .{ .request_id = request_id },
        );
    defer allocator.free(request);

    const response = try transport.request(allocator, request);
    defer allocator.free(response);
    var result = try crud.parseUpdateResponse(allocator, response, request_id);
    errdefer result.deinit();
    try session.markCommandSucceeded();
    return result;
}

pub fn commit(
    transport: *Transport,
    allocator: Allocator,
    session: *Session,
    request_id: i32,
) !void {
    switch (session.transaction_state) {
        .starting => {
            // No command ever reached the server, so there is nothing to
            // commit. Treat the local transaction as successfully empty.
            try session.markCommitted();
            return;
        },
        .in_progress => {},
        else => return error.InvalidTransactionState,
    }

    const lsid = session.lsid();
    const options = session.transaction_options;
    const request = if (options.majority_write_concern)
        if (options.max_commit_time_ms) |max_time|
            try op_msg.encodeCommand(
                allocator,
                .{
                    .commitTransaction = @as(i32, 1),
                    .lsid = lsid,
                    .txnNumber = session.txn_number,
                    .autocommit = false,
                    .writeConcern = .{ .w = "majority" },
                    .maxTimeMS = max_time,
                    .@"$db" = "admin",
                },
                .{ .request_id = request_id },
            )
        else
            try op_msg.encodeCommand(
                allocator,
                .{
                    .commitTransaction = @as(i32, 1),
                    .lsid = lsid,
                    .txnNumber = session.txn_number,
                    .autocommit = false,
                    .writeConcern = .{ .w = "majority" },
                    .@"$db" = "admin",
                },
                .{ .request_id = request_id },
            )
    else
        try op_msg.encodeCommand(
            allocator,
            .{
                .commitTransaction = @as(i32, 1),
                .lsid = lsid,
                .txnNumber = session.txn_number,
                .autocommit = false,
                .@"$db" = "admin",
            },
            .{ .request_id = request_id },
        );
    defer allocator.free(request);

    try executeCommand(transport, allocator, request, request_id);
    try session.markCommitted();
}

pub fn abort(
    transport: *Transport,
    allocator: Allocator,
    session: *Session,
    request_id: i32,
) !void {
    switch (session.transaction_state) {
        .starting => {
            try session.markAborted();
            return;
        },
        .in_progress => {},
        else => return error.InvalidTransactionState,
    }

    const lsid = session.lsid();
    const request = try op_msg.encodeCommand(
        allocator,
        .{
            .abortTransaction = @as(i32, 1),
            .lsid = lsid,
            .txnNumber = session.txn_number,
            .autocommit = false,
            .@"$db" = "admin",
        },
        .{ .request_id = request_id },
    );
    defer allocator.free(request);

    try executeCommand(transport, allocator, request, request_id);
    try session.markAborted();
}

fn readConcernDocument(session: *const Session) struct { level: []const u8 } {
    return .{
        .level = if (session.transaction_options.read_concern) |level|
            level.wireName()
        else
            "snapshot",
    };
}

fn executeCommand(
    transport: *Transport,
    allocator: Allocator,
    request: []const u8,
    request_id: i32,
) !void {
    const response = try transport.request(allocator, request);
    defer allocator.free(response);
    const message = try op_msg.decode(response);
    if (message.header.response_to != request_id) return error.UnexpectedResponse;
    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse return error.CommandFailed;
    const succeeded = switch (ok) {
        .double => |v| v == 1.0,
        .int32 => |v| v == 1,
        .int64 => |v| v == 1,
        else => false,
    };
    if (!succeeded) return error.CommandFailed;
}

test "transaction state begins locally before first command" {
    var session = Session.init(std.testing.io);
    try begin(&session, .{});
    try std.testing.expect(session.isFirstTransactionCommand());
    try std.testing.expectEqual(@as(i64, 0), session.txn_number);
}
