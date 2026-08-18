const std = @import("std");
const bson = @import("../bson.zig");
const Connection = @import("connection.zig").Connection;
const authenticate = @import("auth.zig").authenticate;
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
    MissingFirstBatch,
    InvalidFirstBatch,
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

    /// Run a MongoDB find command and return the owned first batch.
    ///
    /// `filter` may be any Zig struct or anonymous struct supported by
    /// `bson.encode`, for example `.{ .active = true }` or `.{}`.
    pub fn find(
        self: *Client,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
    ) !FindResult {
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

        return parseFindResponse(
            self.allocator,
            response,
            request_id,
        );
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

    pub fn find(self: Collection, filter: anytype) !FindResult {
        return self.client.find(
            self.database_name,
            self.name,
            filter,
        );
    }
};

/// Owned result of one find command.
///
/// Documents returned by `iterator()` borrow from `response_bytes` and remain
/// valid until `deinit()` is called.
pub const FindResult = struct {
    allocator: Allocator,
    response_bytes: []u8,
    first_batch: []const u8,

    pub fn deinit(self: *FindResult) void {
        self.allocator.free(self.response_bytes);
        self.* = undefined;
    }

    pub fn iterator(self: FindResult) !DocumentIterator {
        return .{
            .reader = try bson.Reader.init(self.first_batch),
        };
    }
};

pub const DocumentIterator = struct {
    reader: bson.Reader,

    pub fn next(self: *DocumentIterator) !?[]const u8 {
        const element = (try self.reader.next()) orelse return null;

        return switch (element.value) {
            .document => |document| document,
            else => error.InvalidBatchDocument,
        };
    }
};

/// Parse one MongoDB find response and take ownership of `response_bytes`.
fn parseFindResponse(
    allocator: Allocator,
    response_bytes: []u8,
    expected_response_to: i32,
) !FindResult {
    errdefer allocator.free(response_bytes);

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

    const batch_value = (try bson.Reader.get(cursor, "firstBatch")) orelse
        return error.MissingFirstBatch;

    const first_batch = switch (batch_value) {
        .array => |array| array,
        else => return error.InvalidFirstBatch,
    };

    try bson.validateArray(first_batch);

    return .{
        .allocator = allocator,
        .response_bytes = response_bytes,
        .first_batch = first_batch,
    };
}

fn commandSucceeded(value: bson.Value) bool {
    return switch (value) {
        .double => |number| number == 1.0,
        .int32 => |number| number == 1,
        .int64 => |number| number == 1,
        else => false,
    };
}

test "find response exposes first-batch BSON documents" {
    const allocator = std.testing.allocator;

    const Document = struct {
        name: []const u8,
        active: bool,
    };

    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .cursor = .{
                .id = @as(i64, 0),
                .ns = "test.users",
                .firstBatch = [_]Document{
                    .{ .name = "Bongo", .active = true },
                    .{ .name = "Mango", .active = false },
                },
            },
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 90,
            .response_to = 12,
        },
    );

    var result = try parseFindResponse(
        allocator,
        response,
        12,
    );
    defer result.deinit();

    var documents = try result.iterator();

    const first = (try documents.next()).?;
    try std.testing.expectEqualStrings(
        "Bongo",
        (try bson.Reader.get(first, "name")).?.string,
    );
    try std.testing.expect(
        (try bson.Reader.get(first, "active")).?.boolean,
    );

    const second = (try documents.next()).?;
    try std.testing.expectEqualStrings(
        "Mango",
        (try bson.Reader.get(second, "name")).?.string,
    );
    try std.testing.expect(
        !(try bson.Reader.get(second, "active")).?.boolean,
    );

    try std.testing.expect((try documents.next()) == null);
}

test "find response rejects failed command" {
    const allocator = std.testing.allocator;

    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .ok = @as(f64, 0.0),
        },
        .{
            .request_id = 91,
            .response_to = 13,
        },
    );

    try std.testing.expectError(
        error.CommandFailed,
        parseFindResponse(
            allocator,
            response,
            13,
        ),
    );
}

test "find response rejects mismatched response id" {
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
            .request_id = 92,
            .response_to = 14,
        },
    );

    try std.testing.expectError(
        error.UnexpectedResponse,
        parseFindResponse(
            allocator,
            response,
            99,
        ),
    );
}
