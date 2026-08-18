const std = @import("std");
const bson = @import("../bson.zig");
const Client = @import("client.zig").Client;
const op_msg = @import("op_msg.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
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

    pub fn init(
        client: *Client,
        response_bytes: []u8,
        expected_response_to: i32,
        database_name: []const u8,
        collection_name: []const u8,
        batch_field: []const u8,
    ) !Cursor {
        errdefer client.allocator.free(response_bytes);
        const parsed = try parseCursorResponse(
            response_bytes,
            expected_response_to,
            batch_field,
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

    pub fn id(self: Cursor) i64 {
        return self.cursor_id;
    }

    pub fn namespace(self: Cursor) []const u8 {
        return self.namespace_name;
    }

    pub fn close(self: *Cursor) !void {
        if (self.closed) return;
        self.closed = true;
        if (self.cursor_id == 0) return;

        const id_to_kill = self.cursor_id;
        self.cursor_id = 0;
        try killCursor(
            self.client,
            self.database_name,
            self.collection_name,
            id_to_kill,
        );
    }

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

        const request_id = takeRequestId(self.client);
        const request = try op_msg.encodeCommand(
            self.allocator,
            .{
                .getMore = self.cursor_id,
                .collection = self.collection_name,
                .@"$db" = self.database_name,
            },
            .{ .request_id = request_id },
        );
        defer self.allocator.free(request);

        const response = try self.client.connection.request(
            self.allocator,
            request,
        );
        errdefer self.allocator.free(response);

        const parsed = try parseCursorResponse(
            response,
            request_id,
            "nextBatch",
            self.database_name,
            self.collection_name,
        );
        const reader = try bson.Reader.init(parsed.batch);
        const previous_response = self.response_bytes;

        self.response_bytes = response;
        self.batch_reader = reader;
        self.cursor_id = parsed.cursor_id;
        self.allocator.free(previous_response);
    }
};

const ParsedCursorBatch = struct {
    cursor_id: i64,
    namespace_name: []const u8,
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

fn killCursor(
    client: *Client,
    database_name: []const u8,
    collection_name: []const u8,
    cursor_id: i64,
) !void {
    const request_id = takeRequestId(client);
    const cursor_ids = [_]i64{cursor_id};
    const request = try op_msg.encodeCommand(
        client.allocator,
        .{
            .killCursors = collection_name,
            .cursors = cursor_ids,
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
    defer client.allocator.free(request);

    const response = try client.connection.request(client.allocator, request);
    defer client.allocator.free(response);

    const message = try op_msg.decode(response);
    if (message.header.response_to != request_id) return error.UnexpectedResponse;
    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse
        return error.CommandFailed;
    if (!commandSucceeded(ok)) return error.CommandFailed;
}

pub fn takeRequestId(client: *Client) i32 {
    const result = client.next_request_id;
    client.next_request_id = if (result == std.math.maxInt(i32))
        1
    else
        result + 1;
    std.debug.assert(result > 0);
    return result;
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
