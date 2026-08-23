const std = @import("std");
const crud = @import("crud.zig");
const error_response = @import("error_response.zig");
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
    TransientTransactionError,
    UnknownTransactionCommitResult,
    RetryableWrite,
};

const RequestKind = enum {
    operation,
    commit,
    abort,
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
    transport_failed: *bool,
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

    const response = transport.request(allocator, request) catch |err| {
        return mapRequestError(transport_failed, err, .operation);
    };
    defer allocator.free(response);
    try validateTransactionOperation(response, request_id);
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
    transport_failed: *bool,
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

    const response = transport.request(allocator, request) catch |err| {
        return mapRequestError(transport_failed, err, .operation);
    };
    defer allocator.free(response);
    try validateTransactionOperation(response, request_id);
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
    transport_failed: *bool,
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

    const response = transport.request(allocator, request) catch |err| {
        return mapRequestError(transport_failed, err, .commit);
    };
    defer allocator.free(response);
    const status = try error_response.inspect(response, request_id);
    if (!status.ok) {
        if (status.unknown_transaction_commit or status.retryable_write) {
            return error.UnknownTransactionCommitResult;
        }
        if (status.transient_transaction) {
            return error.TransientTransactionError;
        }
        return error.CommandFailed;
    }
    try session.markCommitted();
}

pub fn abort(
    transport: *Transport,
    allocator: Allocator,
    session: *Session,
    request_id: i32,
    transport_failed: *bool,
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

    const response = transport.request(allocator, request) catch |err| {
        return mapRequestError(transport_failed, err, .abort);
    };
    defer allocator.free(response);
    const status = try error_response.inspect(response, request_id);
    if (status.retryableWrite()) return error.RetryableWrite;
    if (!status.ok) return error.CommandFailed;
    try session.markAborted();
}

fn mapRequestError(
    transport_failed: *bool,
    err: anyerror,
    kind: RequestKind,
) anyerror {
    // Any request-level error means the stream may be partially written or may
    // have an unread response queued. It must not return to the pool, even when
    // the operation itself is not retryable (for example timeoutMS expiry).
    transport_failed.* = true;
    return switch (kind) {
        .operation => if (error_response.isRetryableTransportError(err))
            error.TransientTransactionError
        else
            err,
        .commit => if (error_response.isRetryableTransportError(err))
            error.UnknownTransactionCommitResult
        else
            err,
        .abort => err,
    };
}

fn readConcernDocument(session: *const Session) struct { level: []const u8 } {
    return .{
        .level = if (session.transaction_options.read_concern) |level|
            level.wireName()
        else
            "snapshot",
    };
}

fn validateTransactionOperation(
    response: []const u8,
    request_id: i32,
) !void {
    const status = try error_response.inspect(response, request_id);
    if (status.ok) return;
    if (status.transient_transaction) return error.TransientTransactionError;
    return error.CommandFailed;
}

test "transaction state begins locally before first command" {
    var session = Session.init(std.testing.io);
    try begin(&session, .{});
    try std.testing.expect(session.isFirstTransactionCommand());
    try std.testing.expectEqual(@as(i64, 0), session.txn_number);
}

test "transaction response preserves transient error labels" {
    const body = try @import("../bson.zig").encode(std.testing.allocator, .{
        .ok = @as(i32, 0),
        .errorLabels = [_][]const u8{"TransientTransactionError"},
    });
    defer std.testing.allocator.free(body);
    const status = try error_response.inspectBody(body);
    try std.testing.expect(status.transient_transaction);
}

test "request errors mark pinned transaction transport unusable" {
    var transport_failed = false;
    try std.testing.expectEqual(
        error.TransientTransactionError,
        mapRequestError(&transport_failed, error.SocketTimeout, .operation),
    );
    try std.testing.expect(transport_failed);

    transport_failed = false;
    try std.testing.expectEqual(
        error.OperationTimeout,
        mapRequestError(&transport_failed, error.OperationTimeout, .operation),
    );
    try std.testing.expect(transport_failed);

    transport_failed = false;
    try std.testing.expectEqual(
        error.UnknownTransactionCommitResult,
        mapRequestError(&transport_failed, error.EndOfStream, .commit),
    );
    try std.testing.expect(transport_failed);
}
