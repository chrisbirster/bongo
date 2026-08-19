const std = @import("std");
const auth_transport = @import("auth_transport.zig");
const bson = @import("../bson.zig");
const command_response = @import("command_response.zig");
const Connection = @import("connection.zig").Connection;
const crud = @import("crud.zig");
const find_and_modify = @import("find_and_modify.zig");
const find_options = @import("find_options.zig");
const index_admin = @import("index_admin.zig");
const op_msg = @import("op_msg.zig");
const Pool = @import("pool.zig").Pool;
const session_mod = @import("session.zig");
const srv = @import("srv.zig");
const TlsConnection = @import("tls_connection.zig").TlsConnection;
const TlsOptions = @import("tls_connection.zig").Options;
const topology = @import("topology.zig");
const transaction_ops = @import("transaction.zig");
const Transport = @import("transport.zig").Transport;
const uri_options = @import("uri_options.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    NoWritableServer,
    PoolExhausted,
    UnsupportedAuthMechanism,
    SessionsUnsupported,
    TransactionsUnsupported,
    EmptyDatabase,
    EmptyCollection,
    InvalidCursorResponse,
    UnexpectedResponse,
    CommandFailed,
};

pub const Options = struct {
    max_pool_size: usize = 4,
};

pub const OwnedDocument = struct {
    allocator: Allocator,
    bytes: []u8,

    pub fn deinit(self: *OwnedDocument) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// URI-driven MongoDB client intended for application code that needs TLS,
/// SRV discovery, server selection, pooling, sessions and transactions.
///
/// The original `Client` remains source compatible for the v0.1/v0.2 API.
/// Deez should use this managed client.
pub const RuntimeClient = struct {
    allocator: Allocator,
    io: Io,
    connection_options: uri_options.Options,
    pool: Pool,
    selected_host: usize = 0,
    next_request_id: i32 = 1,
    supports_sessions: bool = false,
    supports_transactions: bool = false,

    pub fn connectUri(
        io: Io,
        allocator: Allocator,
        connection_string: []const u8,
        options: Options,
    ) !RuntimeClient {
        var parsed = if (std.mem.startsWith(u8, connection_string, "mongodb+srv://"))
            try srv.resolve(io, allocator, connection_string)
        else
            try uri_options.parse(allocator, connection_string);
        errdefer parsed.deinit();

        var pool = try Pool.init(allocator, options.max_pool_size);
        errdefer pool.deinit();

        var self: RuntimeClient = .{
            .allocator = allocator,
            .io = io,
            .connection_options = parsed,
            .pool = pool,
        };

        var selected = try self.openWritableTransport();
        errdefer selected.deinit();
        try self.pool.noteCreated();
        try self.pool.put(selected);
        return self;
    }

    pub fn deinit(self: *RuntimeClient) void {
        self.pool.deinit();
        self.connection_options.deinit();
        self.* = undefined;
    }

    pub fn databaseName(self: RuntimeClient) []const u8 {
        return self.connection_options.database orelse "deez";
    }

    pub fn insertOne(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        document: anytype,
    ) !crud.InsertOneResult {
        try validateNamespace(database_name, collection_name);
        var transport = try self.checkout();
        defer self.checkin(transport) catch transport.deinit();
        const request_id = self.takeRequestId();
        const request = try crud.encodeInsertOne(
            self.allocator,
            request_id,
            database_name,
            collection_name,
            document,
        );
        defer self.allocator.free(request);
        const response = try transport.request(self.allocator, request);
        defer self.allocator.free(response);
        return crud.parseInsertOneResponse(response, request_id);
    }

    pub fn updateOne(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        update: anytype,
        upsert: bool,
    ) !crud.UpdateResult {
        try validateNamespace(database_name, collection_name);
        var transport = try self.checkout();
        defer self.checkin(transport) catch transport.deinit();
        const request_id = self.takeRequestId();
        const request = try crud.encodeUpdate(
            self.allocator,
            request_id,
            database_name,
            collection_name,
            filter,
            update,
            false,
            upsert,
        );
        defer self.allocator.free(request);
        const response = try transport.request(self.allocator, request);
        defer self.allocator.free(response);
        return crud.parseUpdateResponse(self.allocator, response, request_id);
    }

    pub fn deleteOne(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
    ) !crud.DeleteResult {
        try validateNamespace(database_name, collection_name);
        var transport = try self.checkout();
        defer self.checkin(transport) catch transport.deinit();
        const request_id = self.takeRequestId();
        const request = try crud.encodeDeleteOne(
            self.allocator,
            request_id,
            database_name,
            collection_name,
            filter,
        );
        defer self.allocator.free(request);
        const response = try transport.request(self.allocator, request);
        defer self.allocator.free(response);
        return crud.parseDeleteResponse(response, request_id);
    }

    pub fn find(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        options: anytype,
    ) !Cursor {
        try validateNamespace(database_name, collection_name);
        var transport = try self.checkout();
        errdefer self.checkin(transport) catch transport.deinit();
        const request_id = self.takeRequestId();
        const request = try find_options.encodeFind(
            self.allocator,
            request_id,
            database_name,
            collection_name,
            filter,
            options,
            null,
        );
        defer self.allocator.free(request);
        const response = try transport.request(self.allocator, request);
        return Cursor.init(
            self,
            transport,
            response,
            request_id,
            database_name,
            collection_name,
            "firstBatch",
        );
    }

    pub fn findOne(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
    ) !?OwnedDocument {
        var cursor = try self.find(
            database_name,
            collection_name,
            filter,
            .{ .limit = @as(i64, 1) },
        );
        defer cursor.deinit();
        const document = (try cursor.next()) orelse return null;
        return .{
            .allocator = self.allocator,
            .bytes = try self.allocator.dupe(u8, document),
        };
    }

    pub fn findOneAndUpdate(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        update: anytype,
        upsert: bool,
    ) !?OwnedDocument {
        try validateNamespace(database_name, collection_name);
        var transport = try self.checkout();
        defer self.checkin(transport) catch transport.deinit();
        const request_id = self.takeRequestId();
        const request = try op_msg.encodeCommand(
            self.allocator,
            .{
                .findAndModify = collection_name,
                .query = filter,
                .update = update,
                .upsert = upsert,
                .new = true,
                .@"$db" = database_name,
            },
            .{ .request_id = request_id },
        );
        defer self.allocator.free(request);
        const response = try transport.request(self.allocator, request);
        defer self.allocator.free(response);
        const bytes = (try find_and_modify.parseDocumentResponse(
            self.allocator,
            response,
            request_id,
        )) orelse return null;
        return .{ .allocator = self.allocator, .bytes = bytes };
    }

    pub fn createIndex(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        key: anytype,
        name: []const u8,
        options: anytype,
    ) !void {
        try validateNamespace(database_name, collection_name);
        var transport = try self.checkout();
        defer self.checkin(transport) catch transport.deinit();
        const request_id = self.takeRequestId();
        const request = try index_admin.encodeCreateIndex(
            self.allocator,
            request_id,
            database_name,
            collection_name,
            key,
            name,
            options,
            null,
        );
        defer self.allocator.free(request);
        const response = try transport.request(self.allocator, request);
        defer self.allocator.free(response);
        _ = try command_response.validate(response, request_id);
    }

    pub fn beginTransaction(
        self: *RuntimeClient,
        options: session_mod.TransactionOptions,
    ) !Transaction {
        if (!self.supports_sessions) return error.SessionsUnsupported;
        if (!self.supports_transactions) return error.TransactionsUnsupported;
        var transport = try self.checkout();
        errdefer self.checkin(transport) catch transport.deinit();
        var session = session_mod.Session.init(self.io);
        try transaction_ops.begin(&session, options);
        return .{
            .client = self,
            .transport = transport,
            .session = session,
        };
    }

    fn checkout(self: *RuntimeClient) !Transport {
        if (self.pool.take()) |transport| return transport;
        if (!self.pool.canCreate()) return error.PoolExhausted;
        var transport = try self.openSelectedTransport();
        errdefer transport.deinit();
        try self.pool.noteCreated();
        return transport;
    }

    fn checkin(self: *RuntimeClient, transport: Transport) !void {
        self.pool.put(transport) catch |err| {
            var doomed = transport;
            doomed.deinit();
            self.pool.noteDiscarded();
            return err;
        };
    }

    fn openWritableTransport(self: *RuntimeClient) !Transport {
        for (self.connection_options.hosts, 0..) |_, index| {
            var transport = self.openTransport(index) catch continue;
            const description = topology.hello(
                &transport,
                self.allocator,
                self.takeRequestId(),
            ) catch {
                transport.deinit();
                continue;
            };
            const acceptable = description.usableForWrites() or
                self.connection_options.load_balanced == true;
            if (!acceptable) {
                transport.deinit();
                continue;
            }
            self.selected_host = index;
            self.supports_sessions = description.logical_session_timeout_minutes != null;
            self.supports_transactions = description.supports_transactions;
            self.authenticate(&transport) catch |err| {
                transport.deinit();
                return err;
            };
            return transport;
        }
        return error.NoWritableServer;
    }

    fn openSelectedTransport(self: *RuntimeClient) !Transport {
        var transport = try self.openTransport(self.selected_host);
        errdefer transport.deinit();
        const description = try topology.hello(
            &transport,
            self.allocator,
            self.takeRequestId(),
        );
        if (!description.usableForWrites() and
            self.connection_options.load_balanced != true)
        {
            transport.deinit();
            return self.openWritableTransport();
        }
        try self.authenticate(&transport);
        return transport;
    }

    fn openTransport(self: *RuntimeClient, host_index: usize) !Transport {
        const host = self.connection_options.hosts[host_index];
        if (self.connection_options.tls == true) {
            const tls_options = try TlsOptions.fromConnectionOptions(
                self.connection_options,
            );
            return .{ .tls = try TlsConnection.connect(
                self.io,
                self.allocator,
                host.name,
                host.port,
                tls_options,
            ) };
        }
        return .{ .tcp = try Connection.connectWithOptions(
            self.io,
            host.name,
            host.port,
            .{
                .connect_timeout_ms = self.connection_options.connect_timeout_ms,
                .socket_timeout_ms = self.connection_options.socket_timeout_ms,
                .operation_timeout_ms = self.connection_options.timeout_ms,
            },
        ) };
    }

    fn authenticate(self: *RuntimeClient, transport: *Transport) !void {
        const username = self.connection_options.username orelse return;
        const password = self.connection_options.password orelse return;
        const database = self.connection_options.auth_source orelse "admin";
        switch (self.connection_options.auth_mechanism orelse .scram_sha_256) {
            .scram_sha_256 => try auth_transport.authenticate(
                transport,
                self.allocator,
                database,
                username,
                password,
            ),
            .scram_sha_1 => try auth_transport.authenticateSha1(
                transport,
                self.allocator,
                database,
                username,
                password,
            ),
            .mongodb_x509 => return error.UnsupportedAuthMechanism,
        }
    }

    fn takeRequestId(self: *RuntimeClient) i32 {
        const result = self.next_request_id;
        self.next_request_id = if (result == std.math.maxInt(i32)) 1 else result + 1;
        return result;
    }
};

pub const Cursor = struct {
    client: *RuntimeClient,
    transport: ?Transport,
    database_name: []u8,
    collection_name: []u8,
    response_bytes: []u8,
    batch_reader: bson.Reader,
    cursor_id: i64,
    closed: bool = false,

    fn init(
        client: *RuntimeClient,
        transport: Transport,
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
            database_name,
            collection_name,
            batch_field,
        );
        const owned_db = try client.allocator.dupe(u8, database_name);
        errdefer client.allocator.free(owned_db);
        const owned_collection = try client.allocator.dupe(u8, collection_name);
        errdefer client.allocator.free(owned_collection);
        return .{
            .client = client,
            .transport = transport,
            .database_name = owned_db,
            .collection_name = owned_collection,
            .response_bytes = response_bytes,
            .batch_reader = try bson.Reader.init(parsed.batch),
            .cursor_id = parsed.cursor_id,
        };
    }

    pub fn next(self: *Cursor) !?[]const u8 {
        if (self.closed) return null;
        while (true) {
            if (try nextBatchDocument(&self.batch_reader)) |document| return document;
            if (self.cursor_id == 0) return null;
            try self.fetchNextBatch();
        }
    }

    pub fn close(self: *Cursor) !void {
        if (self.closed) return;
        self.closed = true;
        if (self.cursor_id != 0 and self.transport != null) {
            const request_id = self.client.takeRequestId();
            const cursor_ids = [_]i64{self.cursor_id};
            const request = try op_msg.encodeCommand(
                self.client.allocator,
                .{
                    .killCursors = self.collection_name,
                    .cursors = cursor_ids,
                    .@"$db" = self.database_name,
                },
                .{ .request_id = request_id },
            );
            defer self.client.allocator.free(request);
            const response = try self.transport.?.request(self.client.allocator, request);
            defer self.client.allocator.free(response);
            _ = try command_response.validate(response, request_id);
            self.cursor_id = 0;
        }
    }

    pub fn deinit(self: *Cursor) void {
        self.close() catch {};
        self.client.allocator.free(self.response_bytes);
        self.client.allocator.free(self.database_name);
        self.client.allocator.free(self.collection_name);
        if (self.transport) |transport| {
            self.client.checkin(transport) catch {
                var doomed = transport;
                doomed.deinit();
                self.client.pool.noteDiscarded();
            };
        }
        self.* = undefined;
    }

    fn fetchNextBatch(self: *Cursor) !void {
        const request_id = self.client.takeRequestId();
        const request = try op_msg.encodeCommand(
            self.client.allocator,
            .{
                .getMore = self.cursor_id,
                .collection = self.collection_name,
                .@"$db" = self.database_name,
            },
            .{ .request_id = request_id },
        );
        defer self.client.allocator.free(request);
        const response = try self.transport.?.request(self.client.allocator, request);
        errdefer self.client.allocator.free(response);
        const parsed = try parseCursorResponse(
            response,
            request_id,
            self.database_name,
            self.collection_name,
            "nextBatch",
        );
        const reader = try bson.Reader.init(parsed.batch);
        const old = self.response_bytes;
        self.response_bytes = response;
        self.batch_reader = reader;
        self.cursor_id = parsed.cursor_id;
        self.client.allocator.free(old);
    }
};

pub const Transaction = struct {
    client: *RuntimeClient,
    transport: ?Transport,
    session: session_mod.Session,
    finished: bool = false,

    pub fn insertOne(
        self: *Transaction,
        database_name: []const u8,
        collection_name: []const u8,
        document: anytype,
    ) !crud.InsertOneResult {
        return transaction_ops.insertOne(
            &self.transport.?,
            self.client.allocator,
            &self.session,
            self.client.takeRequestId(),
            database_name,
            collection_name,
            document,
        );
    }

    pub fn updateOne(
        self: *Transaction,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        update: anytype,
        upsert: bool,
    ) !crud.UpdateResult {
        return transaction_ops.updateOne(
            &self.transport.?,
            self.client.allocator,
            &self.session,
            self.client.takeRequestId(),
            database_name,
            collection_name,
            filter,
            update,
            upsert,
        );
    }

    pub fn commit(self: *Transaction) !void {
        try transaction_ops.commit(
            &self.transport.?,
            self.client.allocator,
            &self.session,
            self.client.takeRequestId(),
        );
        self.finished = true;
        try self.release();
    }

    pub fn abort(self: *Transaction) !void {
        try transaction_ops.abort(
            &self.transport.?,
            self.client.allocator,
            &self.session,
            self.client.takeRequestId(),
        );
        self.finished = true;
        try self.release();
    }

    pub fn deinit(self: *Transaction) void {
        if (!self.finished and self.transport != null) self.abort() catch {};
        if (self.transport != null) self.release() catch {};
        self.* = undefined;
    }

    fn release(self: *Transaction) !void {
        const transport = self.transport orelse return;
        self.transport = null;
        try self.client.checkin(transport);
    }
};

const ParsedCursor = struct {
    cursor_id: i64,
    batch: []const u8,
};

fn parseCursorResponse(
    response_bytes: []const u8,
    expected_response_to: i32,
    database_name: []const u8,
    collection_name: []const u8,
    batch_field: []const u8,
) !ParsedCursor {
    const message = try op_msg.decode(response_bytes);
    if (message.header.response_to != expected_response_to) return error.UnexpectedResponse;
    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse return error.CommandFailed;
    if (!commandSucceeded(ok)) return error.CommandFailed;
    const cursor_value = (try bson.Reader.get(body, "cursor")) orelse
        return error.InvalidCursorResponse;
    const cursor = switch (cursor_value) {
        .document => |value| value,
        else => return error.InvalidCursorResponse,
    };
    const id_value = (try bson.Reader.get(cursor, "id")) orelse
        return error.InvalidCursorResponse;
    const cursor_id = switch (id_value) {
        .int64 => |value| value,
        else => return error.InvalidCursorResponse,
    };
    const ns_value = (try bson.Reader.get(cursor, "ns")) orelse
        return error.InvalidCursorResponse;
    const ns = switch (ns_value) {
        .string => |value| value,
        else => return error.InvalidCursorResponse,
    };
    if (!namespaceMatches(ns, database_name, collection_name)) {
        return error.InvalidCursorResponse;
    }
    const batch_value = (try bson.Reader.get(cursor, batch_field)) orelse
        return error.InvalidCursorResponse;
    const batch = switch (batch_value) {
        .array => |value| value,
        else => return error.InvalidCursorResponse,
    };
    return .{ .cursor_id = cursor_id, .batch = batch };
}

fn nextBatchDocument(reader: *bson.Reader) !?[]const u8 {
    const element = (try reader.next()) orelse return null;
    return switch (element.value) {
        .document => |document| document,
        else => error.InvalidCursorResponse,
    };
}

fn namespaceMatches(
    namespace_name: []const u8,
    database_name: []const u8,
    collection_name: []const u8,
) bool {
    if (namespace_name.len <= database_name.len) return false;
    if (namespace_name[database_name.len] != '.') return false;
    return std.mem.eql(u8, namespace_name[0..database_name.len], database_name) and
        std.mem.eql(u8, namespace_name[database_name.len + 1 ..], collection_name);
}

fn commandSucceeded(value: bson.Value) bool {
    return switch (value) {
        .double => |number| number == 1.0,
        .int32 => |number| number == 1,
        .int64 => |number| number == 1,
        else => false,
    };
}

fn validateNamespace(database_name: []const u8, collection_name: []const u8) Error!void {
    if (database_name.len == 0) return error.EmptyDatabase;
    if (collection_name.len == 0) return error.EmptyCollection;
}
