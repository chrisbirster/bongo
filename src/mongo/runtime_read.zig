const std = @import("std");
const auth_transport = @import("auth_transport.zig");
const bson = @import("../bson.zig");
const command_response = @import("command_response.zig");
const error_response = @import("error_response.zig");
const Connection = @import("connection.zig").Connection;
const find_options = @import("find_options.zig");
const op_msg = @import("op_msg.zig");
const operation_timeout = @import("operation_timeout.zig");
const pool_mod = @import("pool.zig");
const pool_wait = @import("pool_wait.zig");
const sdam_monitor = @import("sdam_monitor.zig");
const topology = @import("topology.zig");
const TlsConnection = @import("tls_connection.zig").TlsConnection;
const TlsOptions = @import("tls_connection.zig").Options;
const Transport = @import("transport.zig").Transport;
const uri_options = @import("uri_options.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Pool = pool_mod.Pool;
const PoolHandle = pool_mod.Handle;

pub const Error = error{
    ClientClosed,
    ActiveHandles,
    EmptyDatabase,
    EmptyCollection,
    UnexpectedResponse,
    InvalidCursorResponse,
    CommandFailed,
    RetryableRead,
    UnsupportedAuthMechanism,
};

const ServerPool = struct {
    allocator: Allocator,
    address: []u8,
    host: []u8,
    port: u16,
    pool: Pool,

    fn deinit(self: *ServerPool) void {
        self.pool.deinit();
        self.allocator.free(self.address);
        self.allocator.free(self.host);
        self.allocator.destroy(self);
    }
};

pub const Runtime = struct {
    allocator: Allocator,
    io: Io,
    connection_options: *const uri_options.Options,
    min_pool_size: usize,
    max_pool_size: usize,
    max_connecting: usize,
    max_idle_time_ms: u64,
    mutex: Io.Mutex = Io.Mutex.init,
    pools: std.ArrayList(*ServerPool) = .empty,
    next_request_id: i32 = 1,
    active_handles: usize = 0,
    closing: bool = false,

    pub fn init(
        allocator: Allocator,
        io: Io,
        connection_options: *const uri_options.Options,
        pool_stats: pool_mod.Stats,
    ) Runtime {
        return .{
            .allocator = allocator,
            .io = io,
            .connection_options = connection_options,
            .min_pool_size = pool_stats.min_size,
            .max_pool_size = pool_stats.max_size,
            .max_connecting = pool_stats.max_connecting,
            .max_idle_time_ms = pool_stats.max_idle_time_ms,
        };
    }

    pub fn deinitChecked(self: *Runtime) Error!void {
        self.mutex.lockUncancelable(self.io);
        if (self.active_handles != 0) {
            self.mutex.unlock(self.io);
            return error.ActiveHandles;
        }
        self.closing = true;
        var pools = self.pools;
        self.pools = .empty;
        self.mutex.unlock(self.io);

        for (pools.items) |server_pool| server_pool.deinit();
        pools.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn requestShutdown(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        for (self.pools.items) |server_pool| server_pool.pool.close();
        self.mutex.unlock(self.io);
    }

    pub fn clearForRetry(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.pools.items) |*server_pool| {
            server_pool.pool.clear() catch {};
            server_pool.pool.ready() catch {};
        }
    }

    pub fn find(
        self: *Runtime,
        server: sdam_monitor.ServerSnapshot,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        options: anytype,
    ) !Cursor {
        try validateNamespace(database_name, collection_name);
        const server_pool = try self.getOrCreatePool(server);
        var transport: ?PoolHandle = try self.checkout(server_pool);
        errdefer self.releaseTransport(server_pool, &transport);
        const request_id = self.takeRequestId();
        const request = try find_options.encodeFindWithReadPreference(
            self.allocator,
            request_id,
            database_name,
            collection_name,
            filter,
            options,
            null,
            .secondary,
        );
        defer self.allocator.free(request);
        const response = try self.requestCheckedOut(server_pool, &transport, request);
        const cursor = try Cursor.init(
            self,
            server_pool,
            transport.?,
            response,
            request_id,
            database_name,
            collection_name,
            "firstBatch",
        );
        transport = null;
        return cursor;
    }

    fn getOrCreatePool(self: *Runtime, server: sdam_monitor.ServerSnapshot) !*ServerPool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closing) return error.ClientClosed;
        for (self.pools.items) |existing| {
            if (std.mem.eql(u8, existing.address, server.address)) return existing;
        }

        const server_pool = try self.allocator.create(ServerPool);
        errdefer self.allocator.destroy(server_pool);
        const address = try self.allocator.dupe(u8, server.address);
        errdefer self.allocator.free(address);
        const host = try self.allocator.dupe(u8, server.host);
        errdefer self.allocator.free(host);
        var pool = try Pool.initWithOptions(self.io, self.allocator, .{
            .min_size = self.min_pool_size,
            .max_size = self.max_pool_size,
            .max_connecting = self.max_connecting,
            .max_idle_time_ms = self.max_idle_time_ms,
        });
        errdefer pool.deinit();
        try pool.ready();
        server_pool.* = .{
            .allocator = self.allocator,
            .address = address,
            .host = host,
            .port = server.port,
            .pool = pool,
        };
        try self.pools.append(self.allocator, server_pool);
        return server_pool;
    }

    fn checkout(self: *Runtime, server_pool: *ServerPool) !PoolHandle {
        const budget = try operation_timeout.Budget.start(
            self.io,
            self.connection_options.timeout_ms,
        );
        while (true) {
            if (server_pool.pool.take()) |handle| return handle;
            const permit = server_pool.pool.tryStartCreate() catch |err| switch (err) {
                error.PoolExhausted, error.ConnectLimitReached => {
                    try pool_wait.waitForAvailabilityUntil(&server_pool.pool, budget.deadline);
                    continue;
                },
                else => return err,
            };

            var transport = self.openTransport(server_pool) catch |err| {
                server_pool.pool.cancelCreate(permit);
                return err;
            };
            _ = topology.handshake(
                &transport,
                self.allocator,
                self.takeRequestId(),
                .{
                    .app_name = self.connection_options.app_name,
                    .load_balanced = self.connection_options.load_balanced == true,
                },
            ) catch |err| {
                transport.deinit();
                server_pool.pool.cancelCreate(permit);
                return err;
            };
            self.authenticate(&transport) catch |err| {
                transport.deinit();
                server_pool.pool.cancelCreate(permit);
                return err;
            };
            server_pool.pool.finishCreate(permit) catch |err| {
                transport.deinit();
                if (err == error.PoolCleared) continue;
                if (err == error.PoolExhausted) {
                    try pool_wait.waitForAvailabilityUntil(&server_pool.pool, budget.deadline);
                    continue;
                }
                return err;
            };
            return .{ .transport = transport, .generation = permit.generation };
        }
    }

    fn checkin(self: *Runtime, server_pool: *ServerPool, handle: PoolHandle) void {
        server_pool.pool.put(handle) catch {
            self.discard(server_pool, handle);
        };
    }

    fn discard(self: *Runtime, server_pool: *ServerPool, handle: PoolHandle) void {
        _ = self;
        var doomed = handle.transport;
        doomed.deinit();
        server_pool.pool.noteDiscarded();
    }

    fn releaseTransport(
        self: *Runtime,
        server_pool: *ServerPool,
        transport: *?PoolHandle,
    ) void {
        const owned = transport.* orelse return;
        transport.* = null;
        self.checkin(server_pool, owned);
    }

    fn discardTransport(
        self: *Runtime,
        server_pool: *ServerPool,
        transport: *?PoolHandle,
    ) void {
        const owned = transport.* orelse return;
        transport.* = null;
        self.discard(server_pool, owned);
    }

    fn requestCheckedOut(
        self: *Runtime,
        server_pool: *ServerPool,
        transport: *?PoolHandle,
        request_bytes: []const u8,
    ) ![]u8 {
        if (transport.*) |*owned| {
            return owned.transport.request(self.allocator, request_bytes) catch |err| {
                self.discardTransport(server_pool, transport);
                return err;
            };
        }
        return error.UnexpectedResponse;
    }

    fn openTransport(self: *Runtime, server_pool: *ServerPool) !Transport {
        if (self.connection_options.tls == true) {
            const tls_options = try TlsOptions.fromConnectionOptions(self.connection_options.*);
            return .{ .tls = try TlsConnection.connect(
                self.io,
                self.allocator,
                server_pool.host,
                server_pool.port,
                tls_options,
            ) };
        }
        return .{ .tcp = try Connection.connectWithOptions(
            self.io,
            server_pool.host,
            server_pool.port,
            .{
                .connect_timeout_ms = self.connection_options.connect_timeout_ms,
                .socket_timeout_ms = self.connection_options.socket_timeout_ms,
                .operation_timeout_ms = self.connection_options.timeout_ms,
            },
        ) };
    }

    fn authenticate(self: *Runtime, transport: *Transport) !void {
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

    fn takeRequestId(self: *Runtime) i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.next_request_id;
        self.next_request_id = if (result == std.math.maxInt(i32)) 1 else result + 1;
        return result;
    }

    fn retainHandle(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.active_handles += 1;
    }

    fn releaseHandle(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.active_handles > 0);
        self.active_handles -= 1;
    }
};

pub const Cursor = struct {
    runtime: *Runtime,
    server_pool: *ServerPool,
    transport: ?PoolHandle,
    database_name: []u8,
    collection_name: []u8,
    response_bytes: []u8,
    batch_reader: bson.Reader,
    cursor_id: i64,
    closed: bool = false,

    fn init(
        runtime: *Runtime,
        server_pool: *ServerPool,
        transport: PoolHandle,
        response_bytes: []u8,
        expected_response_to: i32,
        database_name: []const u8,
        collection_name: []const u8,
        batch_field: []const u8,
    ) !Cursor {
        errdefer runtime.allocator.free(response_bytes);
        const parsed = try parseCursorResponse(
            response_bytes,
            expected_response_to,
            database_name,
            collection_name,
            batch_field,
        );
        const owned_db = try runtime.allocator.dupe(u8, database_name);
        errdefer runtime.allocator.free(owned_db);
        const owned_collection = try runtime.allocator.dupe(u8, collection_name);
        errdefer runtime.allocator.free(owned_collection);
        var cursor: Cursor = .{
            .runtime = runtime,
            .server_pool = server_pool,
            .transport = transport,
            .database_name = owned_db,
            .collection_name = owned_collection,
            .response_bytes = response_bytes,
            .batch_reader = try bson.Reader.init(parsed.batch),
            .cursor_id = parsed.cursor_id,
        };
        if (cursor.cursor_id == 0) runtime.releaseTransport(server_pool, &cursor.transport);
        runtime.retainHandle();
        return cursor;
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
            const request_id = self.runtime.takeRequestId();
            const cursor_ids = [_]i64{self.cursor_id};
            const request = try op_msg.encodeCommand(
                self.runtime.allocator,
                .{
                    .killCursors = self.collection_name,
                    .cursors = cursor_ids,
                    .@"$db" = self.database_name,
                },
                .{ .request_id = request_id },
            );
            defer self.runtime.allocator.free(request);
            const response = self.runtime.requestCheckedOut(
                self.server_pool,
                &self.transport,
                request,
            ) catch |err| {
                self.cursor_id = 0;
                return err;
            };
            defer self.runtime.allocator.free(response);
            _ = try command_response.validate(response, request_id);
            self.cursor_id = 0;
        }
    }

    pub fn deinit(self: *Cursor) void {
        self.close() catch {};
        self.runtime.allocator.free(self.response_bytes);
        self.runtime.allocator.free(self.database_name);
        self.runtime.allocator.free(self.collection_name);
        self.runtime.releaseTransport(self.server_pool, &self.transport);
        self.runtime.releaseHandle();
        self.* = undefined;
    }

    fn fetchNextBatch(self: *Cursor) !void {
        const request_id = self.runtime.takeRequestId();
        const request = try op_msg.encodeCommand(
            self.runtime.allocator,
            .{
                .getMore = self.cursor_id,
                .collection = self.collection_name,
                .@"$db" = self.database_name,
            },
            .{ .request_id = request_id },
        );
        defer self.runtime.allocator.free(request);
        const response = self.runtime.requestCheckedOut(
            self.server_pool,
            &self.transport,
            request,
        ) catch |err| {
            self.closed = true;
            self.cursor_id = 0;
            return err;
        };
        errdefer self.runtime.allocator.free(response);
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
        self.runtime.allocator.free(old);
        if (self.cursor_id == 0) self.runtime.releaseTransport(self.server_pool, &self.transport);
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
    const status = try error_response.inspectBody(body);
    if (!status.ok) {
        if (status.retryableRead()) return error.RetryableRead;
        return error.CommandFailed;
    }
    const cursor_value = (try bson.Reader.get(body, "cursor")) orelse return error.InvalidCursorResponse;
    const cursor = switch (cursor_value) {
        .document => |value| value,
        else => return error.InvalidCursorResponse,
    };
    const id_value = (try bson.Reader.get(cursor, "id")) orelse return error.InvalidCursorResponse;
    const cursor_id = switch (id_value) {
        .int64 => |value| value,
        else => return error.InvalidCursorResponse,
    };
    const ns_value = (try bson.Reader.get(cursor, "ns")) orelse return error.InvalidCursorResponse;
    const ns = switch (ns_value) {
        .string => |value| value,
        else => return error.InvalidCursorResponse,
    };
    if (!namespaceMatches(ns, database_name, collection_name)) return error.InvalidCursorResponse;
    const batch_value = (try bson.Reader.get(cursor, batch_field)) orelse return error.InvalidCursorResponse;
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

fn namespaceMatches(namespace_name: []const u8, database_name: []const u8, collection_name: []const u8) bool {
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
