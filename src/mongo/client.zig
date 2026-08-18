const std = @import("std");
const bson = @import("../bson.zig");
const Connection = @import("connection.zig").Connection;
const authenticate = @import("auth.zig").authenticate;
const crud = @import("crud.zig");
const op_msg = @import("op_msg.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    EmptyDatabase,
    EmptyCollection,
    UnexpectedResponse,
    CommandFailed,
    MissingCursor,
    InvalidCursor,
    MissingCursorId,
    InvalidCursorId,
    MissingNamespace,
    InvalidNamespace,
    UnexpectedNamespace,
    MissingBatch,
    InvalidBatch,
    InvalidBatchDocument,
};

/// Application-facing MongoDB client.
///
/// The client owns one authenticated TCP connection and hides MongoDB OP_MSG
/// framing from normal application calls.
pub const Client = struct {
    allocator: Allocator,
    connection: Connection,
    next_request_id: i32,

    pub const Options = struct {
        username: []const u8,
        password: []const u8,
        host: []const u8 = "127.0.0.1",
        port: u16 = 27017,
        auth_database: []const u8 = "admin",
    };

    /// Connect to MongoDB and authenticate the connection with SCRAM-SHA-256.
    pub fn connect(
        io: Io,
        allocator: Allocator,
        options: Options,
    ) !Client {
        var connection = try Connection.connect(
            io,
            options.host,
            options.port,
        );
        errdefer connection.deinit();

        try authenticate(
            &connection,
            allocator,
            options.auth_database,
            options.username,
            options.password,
        );

        return .{
            .allocator = allocator,
            .connection = connection,
            .next_request_id = 1,
        };
    }

    pub fn deinit(self: *Client) void {
        self.connection.deinit();
        self.* = undefined;
    }

    /// Return a lightweight handle for one MongoDB database.
    ///
    /// The database name is borrowed; the caller must keep it alive while the
    /// handle is in use.
    pub fn database(self: *Client, name: []const u8) Database {
        return .{
            .client = self,
            .name = name,
        };
    }

    /// Run a MongoDB find command and return a cursor over all result batches.
    ///
    /// `filter` may be any Zig struct or anonymous struct supported by
    /// `bson.encode`, for example `.{ .active = true }` or `.{}`.
    pub fn find(
        self: *Client,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
    ) !Cursor {
        if (database_name.len == 0) return error.EmptyDatabase;
        if (collection_name.len == 0) return error.EmptyCollection;

        const request_id = self.takeRequestId();

        const request = try op_msg.encodeCommand(
            self.allocator,
            .{
                .find = collection_name,
                .filter = filter,
                .@"$db" = database_name,
            },
            .{
                .request_id = request_id,
            },
        );
        defer self.allocator.free(request);

        const response = try self.connection.request(
            self.allocator,
            request,
        );

        return Cursor.init(
            self,
            response,
            request_id,
            database_name,
            collection_name,
        );
    }

    /// Insert one document into a collection.
    pub fn insertOne(
        self: *Client,
        database_name: []const u8,
        collection_name: []const u8,
        document: anytype,
    ) !crud.InsertOneResult {
        if (database_name.len == 0) return error.EmptyDatabase;
        if (collection_name.len == 0) return error.EmptyCollection;

        const request_id = self.takeRequestId();
        const request = try crud.encodeInsertOne(
            self.allocator,
            request_id,
            database_name,
            collection_name,
            document,
        );
        defer self.allocator.free(request);

        const response = try self.connection.request(
            self.allocator,
            request,
        );
        defer self.allocator.free(response);

        return crud.parseInsertOneResponse(response, request_id);
    }

    /// Update one document matching a filter.
    pub fn updateOne(
        self: *Client,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        update: anytype,
    ) !crud.UpdateResult {
        if (database_name.len == 0) return error.EmptyDatabase;
        if (collection_name.len == 0) return error.EmptyCollection;

        const request_id = self.takeRequestId();
        const request = try crud.encodeUpdateOne(
            self.allocator,
            request_id,
            database_name,
            collection_name,
            filter,
            update,
        );
        defer self.allocator.free(request);

        const response = try self.connection.request(
            self.allocator,
            request,
        );
        defer self.allocator.free(response);

        return crud.parseUpdateResponse(response, request_id);
    }

    fn getMore(
        self: *Client,
        database_name: []const u8,
        collection_name: []const u8,
        cursor_id: i64,
    ) !OwnedBatch {
        std.debug.assert(cursor_id != 0);

        const request_id = self.takeRequestId();
        const request = try op_msg.encodeCommand(
            self.allocator,
            .{
                .getMore = cursor_id,
                .collection = collection_name,
                .@"$db" = database_name,
            },
            .{
                .request_id = request_id,
            },
        );
        defer self.allocator.free(request);

        const response = try self.connection.request(
            self.allocator,
            request,
        );
        errdefer self.allocator.free(response);

        const parsed = try parseCursorResponse(
            response,
            request_id,
            "nextBatch",
            database_name,
            collection_name,
        );

        return .{
            .response_bytes = response,
            .cursor_id = parsed.cursor_id,
            .batch = parsed.batch,
        };
    }

    fn killCursor(
        self: *Client,
        database_name: []const u8,
        collection_name: []const u8,
        cursor_id: i64,
    ) !void {
        std.debug.assert(cursor_id != 0);

        const request_id = self.takeRequestId();
        const cursor_ids = [_]i64{cursor_id};
        const request = try op_msg.encodeCommand(
            self.allocator,
            .{
                .killCursors = collection_name,
                .cursors = cursor_ids,
                .@"$db" = database_name,
            },
            .{
                .request_id = request_id,
            },
        );
        defer self.allocator.free(request);

        const response = try self.connection.request(
            self.allocator,
            request,
        );
        defer self.allocator.free(response);

        try validateCommandResponse(response, request_id);
    }

    fn takeRequestId(self: *Client) i32 {
        const result = self.next_request_id;

        self.next_request_id = if (result == std.math.maxInt(i32))
            1
        else
            result + 1;

        std.debug.assert(result > 0);
        std.debug.assert(self.next_request_id > 0);
        return result;
    }
};

/// Lightweight view of one database on a Client.
pub const Database = struct {
    client: *Client,
    name: []const u8,

    /// Return a lightweight handle for one collection in this database.
    ///
    /// The collection name is borrowed; the caller must keep it alive while
    /// the handle is in use.
    pub fn collection(self: Database, name: []const u8) Collection {
        return .{
            .client = self.client,
            .database_name = self.name,
            .name = name,
        };
    }
};

/// Lightweight view of one MongoDB collection.
pub const Collection = struct {
    client: *Client,
    database_name: []const u8,
    name: []const u8,

    pub fn find(self: Collection, filter: anytype) !Cursor {
        return self.client.find(
            self.database_name,
            self.name,
            filter,
        );
    }

    pub fn insertOne(
        self: Collection,
        document: anytype,
    ) !crud.InsertOneResult {
        return self.client.insertOne(
            self.database_name,
            self.name,
            document,
        );
    }

    pub fn updateOne(
        self: Collection,
        filter: anytype,
        update: anytype,
    ) !crud.UpdateResult {
        return self.client.updateOne(
            self.database_name,
            self.name,
            filter,
            update,
        );
    }
};

/// Stateful MongoDB cursor.
///
/// The cursor owns the current wire response and fetches later batches with
/// `getMore` as needed. A BSON document returned from `next()` borrows from the
/// current batch and is valid until the next call to `next()`, `close()`, or
/// `deinit()`.
///
/// A cursor must not outlive its Client.
pub const Cursor = struct {
    client: *Client,
    allocator: Allocator,
    database_name: []u8,
    collection_name: []u8,
    namespace_name: []u8,
    response_bytes: []u8,
    batch_reader: bson.Reader,
    cursor_id: i64,
    closed: bool,

    fn init(
        client: *Client,
        response_bytes: []u8,
        expected_response_to: i32,
        database_name: []const u8,
        collection_name: []const u8,
    ) !Cursor {
        errdefer client.allocator.free(response_bytes);

        const parsed = try parseCursorResponse(
            response_bytes,
            expected_response_to,
            "firstBatch",
            database_name,
            collection_name,
        );

        const owned_database = try client.allocator.dupe(u8, database_name);
        errdefer client.allocator.free(owned_database);

        const owned_collection = try client.allocator.dupe(u8, collection_name);
        errdefer client.allocator.free(owned_collection);

        const owned_namespace = try client.allocator.dupe(u8, parsed.namespace_name);
        errdefer client.allocator.free(owned_namespace);

        return .{
            .client = client,
            .allocator = client.allocator,
            .database_name = owned_database,
            .collection_name = owned_collection,
            .namespace_name = owned_namespace,
            .response_bytes = response_bytes,
            .batch_reader = try bson.Reader.init(parsed.batch),
            .cursor_id = parsed.cursor_id,
            .closed = false,
        };
    }

    /// Return the next BSON document, fetching later batches automatically.
    pub fn next(self: *Cursor) !?[]const u8 {
        if (self.closed) return null;

        while (true) {
            if (try nextBatchDocument(&self.batch_reader)) |document| {
                return document;
            }

            if (self.cursor_id == 0) return null;
            try self.fetchNextBatch();
        }
    }

    /// Compatibility helper for code written against the original FindResult.
    pub fn iterator(self: *Cursor) !*Cursor {
        return self;
    }

    /// Current server cursor id. Zero means MongoDB has exhausted the cursor.
    pub fn id(self: Cursor) i64 {
        return self.cursor_id;
    }

    /// Namespace returned by MongoDB for this cursor.
    pub fn namespace(self: Cursor) []const u8 {
        return self.namespace_name;
    }

    /// Stop iteration and release an open server-side cursor.
    pub fn close(self: *Cursor) !void {
        if (self.closed) return;
        self.closed = true;

        if (self.cursor_id == 0) return;

        const id_to_kill = self.cursor_id;
        self.cursor_id = 0;

        try self.client.killCursor(
            self.database_name,
            self.collection_name,
            id_to_kill,
        );
    }

    /// Release local cursor memory and best-effort server cursor state.
    ///
    /// Explicit callers that need to observe killCursors errors can call
    /// `close()` before `deinit()`.
    pub fn deinit(self: *Cursor) void {
        self.close() catch {};

        self.allocator.free(self.response_bytes);
        self.allocator.free(self.database_name);
        self.allocator.free(self.collection_name);
        self.allocator.free(self.namespace_name);
        self.* = undefined;
    }

    fn fetchNextBatch(self: *Cursor) !void {
        std.debug.assert(!self.closed);
        std.debug.assert(self.cursor_id != 0);

        const next_batch = try self.client.getMore(
            self.database_name,
            self.collection_name,
            self.cursor_id,
        );
        errdefer self.allocator.free(next_batch.response_bytes);

        const reader = try bson.Reader.init(next_batch.batch);
        const previous_response = self.response_bytes;

        self.response_bytes = next_batch.response_bytes;
        self.batch_reader = reader;
        self.cursor_id = next_batch.cursor_id;

        self.allocator.free(previous_response);
    }
};

/// Compatibility alias retained for the first application-facing find API.
pub const FindResult = Cursor;

const ParsedCursorBatch = struct {
    cursor_id: i64,
    namespace_name: []const u8,
    batch: []const u8,
};

const OwnedBatch = struct {
    response_bytes: []u8,
    cursor_id: i64,
    batch: []const u8,
};

fn parseCursorResponse(
    response_bytes: []const u8,
    expected_response_to: i32,
    batch_field: []const u8,
    expected_database: []const u8,
    expected_collection: []const u8,
) !ParsedCursorBatch {
    const message = try op_msg.decode(response_bytes);
    if (message.header.response_to != expected_response_to) {
        return error.UnexpectedResponse;
    }

    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse
        return error.CommandFailed;
    if (!commandSucceeded(ok)) return error.CommandFailed;

    const cursor_value = (try bson.Reader.get(body, "cursor")) orelse
        return error.MissingCursor;
    const cursor = switch (cursor_value) {
        .document => |document| document,
        else => return error.InvalidCursor,
    };

    const id_value = (try bson.Reader.get(cursor, "id")) orelse
        return error.MissingCursorId;
    const cursor_id = switch (id_value) {
        .int64 => |value| value,
        else => return error.InvalidCursorId,
    };

    const namespace_value = (try bson.Reader.get(cursor, "ns")) orelse
        return error.MissingNamespace;
    const namespace_name = switch (namespace_value) {
        .string => |value| value,
        else => return error.InvalidNamespace,
    };
    if (!namespaceMatches(
        namespace_name,
        expected_database,
        expected_collection,
    )) return error.UnexpectedNamespace;

    const batch_value = (try bson.Reader.get(cursor, batch_field)) orelse
        return error.MissingBatch;
    const batch = switch (batch_value) {
        .array => |array| array,
        else => return error.InvalidBatch,
    };
    try bson.validateArray(batch);

    return .{
        .cursor_id = cursor_id,
        .namespace_name = namespace_name,
        .batch = batch,
    };
}

fn validateCommandResponse(
    response_bytes: []const u8,
    expected_response_to: i32,
) !void {
    const message = try op_msg.decode(response_bytes);
    if (message.header.response_to != expected_response_to) {
        return error.UnexpectedResponse;
    }

    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse
        return error.CommandFailed;
    if (!commandSucceeded(ok)) return error.CommandFailed;
}

fn nextBatchDocument(reader: *bson.Reader) !?[]const u8 {
    const element = (try reader.next()) orelse return null;

    return switch (element.value) {
        .document => |document| document,
        else => error.InvalidBatchDocument,
    };
}

fn namespaceMatches(
    namespace_name: []const u8,
    database_name: []const u8,
    collection_name: []const u8,
) bool {
    if (namespace_name.len <= database_name.len) return false;
    if (namespace_name[database_name.len] != '.') return false;

    return std.mem.eql(
        u8,
        namespace_name[0..database_name.len],
        database_name,
    ) and std.mem.eql(
        u8,
        namespace_name[database_name.len + 1 ..],
        collection_name,
    );
}

fn commandSucceeded(value: bson.Value) bool {
    return switch (value) {
        .double => |number| number == 1.0,
        .int32 => |number| number == 1,
        .int64 => |number| number == 1,
        else => false,
    };
}

test "cursor response parses firstBatch state" {
    const allocator = std.testing.allocator;

    const Document = struct {
        name: []const u8,
    };

    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .cursor = .{
                .id = @as(i64, 1234),
                .ns = "test.users",
                .firstBatch = [_]Document{
                    .{ .name = "Bongo" },
                    .{ .name = "Mango" },
                },
            },
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 90,
            .response_to = 12,
        },
    );
    defer allocator.free(response);

    const parsed = try parseCursorResponse(
        response,
        12,
        "firstBatch",
        "test",
        "users",
    );

    try std.testing.expectEqual(@as(i64, 1234), parsed.cursor_id);
    try std.testing.expectEqualStrings("test.users", parsed.namespace_name);

    var reader = try bson.Reader.init(parsed.batch);
    const first = (try nextBatchDocument(&reader)).?;
    const second = (try nextBatchDocument(&reader)).?;

    try std.testing.expectEqualStrings(
        "Bongo",
        (try bson.Reader.get(first, "name")).?.string,
    );
    try std.testing.expectEqualStrings(
        "Mango",
        (try bson.Reader.get(second, "name")).?.string,
    );
    try std.testing.expect((try nextBatchDocument(&reader)) == null);
}

test "cursor response parses getMore nextBatch and exhausted id" {
    const allocator = std.testing.allocator;

    const Document = struct {
        index: i32,
    };

    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .cursor = .{
                .id = @as(i64, 0),
                .ns = "test.users",
                .nextBatch = [_]Document{
                    .{ .index = 2 },
                    .{ .index = 3 },
                },
            },
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 91,
            .response_to = 13,
        },
    );
    defer allocator.free(response);

    const parsed = try parseCursorResponse(
        response,
        13,
        "nextBatch",
        "test",
        "users",
    );

    try std.testing.expectEqual(@as(i64, 0), parsed.cursor_id);

    var reader = try bson.Reader.init(parsed.batch);
    const first = (try nextBatchDocument(&reader)).?;
    const second = (try nextBatchDocument(&reader)).?;

    try std.testing.expectEqual(
        @as(i32, 2),
        (try bson.Reader.get(first, "index")).?.int32,
    );
    try std.testing.expectEqual(
        @as(i32, 3),
        (try bson.Reader.get(second, "index")).?.int32,
    );
}

test "cursor response rejects failed command" {
    const allocator = std.testing.allocator;

    const response = try op_msg.encodeCommand(
        allocator,
        .{ .ok = @as(f64, 0.0) },
        .{
            .request_id = 92,
            .response_to = 14,
        },
    );
    defer allocator.free(response);

    try std.testing.expectError(
        error.CommandFailed,
        parseCursorResponse(
            response,
            14,
            "firstBatch",
            "test",
            "users",
        ),
    );
}

test "cursor response rejects mismatched response id" {
    const allocator = std.testing.allocator;

    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .cursor = .{
                .id = @as(i64, 0),
                .ns = "test.users",
                .firstBatch = [_]u8{},
            },
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 93,
            .response_to = 15,
        },
    );
    defer allocator.free(response);

    try std.testing.expectError(
        error.UnexpectedResponse,
        parseCursorResponse(
            response,
            99,
            "firstBatch",
            "test",
            "users",
        ),
    );
}

test "cursor response rejects unexpected namespace" {
    const allocator = std.testing.allocator;

    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .cursor = .{
                .id = @as(i64, 0),
                .ns = "other.users",
                .firstBatch = [_]u8{},
            },
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 94,
            .response_to = 16,
        },
    );
    defer allocator.free(response);

    try std.testing.expectError(
        error.UnexpectedNamespace,
        parseCursorResponse(
            response,
            16,
            "firstBatch",
            "test",
            "users",
        ),
    );
}
