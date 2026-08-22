const std = @import("std");
const auth_transport = @import("auth_transport.zig");
const bson = @import("../bson.zig");
const command_response = @import("command_response.zig");
const error_response = @import("error_response.zig");
const Connection = @import("connection.zig").Connection;
const crud = @import("crud.zig");
const find_and_modify = @import("find_and_modify.zig");
const find_options = @import("find_options.zig");
const index_admin = @import("index_admin.zig");
const op_msg = @import("op_msg.zig");
const operation_timeout = @import("operation_timeout.zig");
const pool_mod = @import("pool.zig");
const pool_wait = @import("pool_wait.zig");
const retryable_write = @import("retryable_write.zig");
const Pool = pool_mod.Pool;
const PoolHandle = pool_mod.Handle;
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
    ActiveHandles,
    ClientBusy,
    ClientClosed,
    EmptyDatabase,
    EmptyCollection,
    InvalidCursorResponse,
    UnexpectedResponse,
    CommandFailed,
    RetryableRead,
    RetryableWrite,
};

/// Programmatic CMAP overrides. Null fields inherit from the connection string,
/// then from CMAP defaults (min=0, max=100, maxConnecting=2, maxIdleTimeMS=0).
pub const Options = struct {
    min_pool_size: ?usize = null,
    max_pool_size: ?usize = null,
    max_connecting: ?usize = null,
    max_idle_time_ms: ?u64 = null,
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
/// Shared mutable RuntimeClient state and the underlying pool are synchronized
/// for concurrent callers. Cursor and Transaction values remain single-owner
/// handles; callers must not concurrently mutate the same handle value.
pub const RuntimeClient = struct {
    allocator: Allocator,
    io: Io,
    connection_options: uri_options.Options,
    pool: Pool,
    state_mutex: Io.Mutex = Io.Mutex.init,
    selected_host: usize = 0,
    next_request_id: i32 = 1,
    supports_sessions: bool = false,
    supports_transactions: bool = false,
    capabilities_initialized: bool = false,
    active_handles: usize = 0,
    active_operations: usize = 0,
    closing: bool = false,

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

        const uri_min_pool_size: usize = if (parsed.min_pool_size) |value| @intCast(value) else 0;
        const uri_max_pool_size: usize = if (parsed.max_pool_size) |value| @intCast(value) else 100;
        const uri_max_connecting: usize = if (parsed.max_connecting) |value| @intCast(value) else 2;
        const uri_max_idle_time_ms: u64 = parsed.max_idle_time_ms orelse 0;
        var pool = try Pool.initWithOptions(io, allocator, .{
            .min_size = options.min_pool_size orelse uri_min_pool_size,
            .max_size = options.max_pool_size orelse uri_max_pool_size,
            .max_connecting = options.max_connecting orelse uri_max_connecting,
            .max_idle_time_ms = options.max_idle_time_ms orelse uri_max_idle_time_ms,
        });
        errdefer pool.deinit();

        var self: RuntimeClient = .{
            .allocator = allocator,
            .io = io,
            .connection_options = parsed,
            .pool = pool,
        };
        try self.pool.ready();

        const permit = try self.pool.tryStartCreate();
        var selected = self.openWritableTransport() catch |err| {
            self.pool.cancelCreate(permit);
            return err;
        };
        errdefer selected.deinit();
        try self.pool.finishCreate(permit);
        self.pool.put(.{
            .transport = selected,
            .generation = permit.generation,
        }) catch |err| {
            self.pool.noteDiscarded();
            return err;
        };

        try self.ensureMinPool();
        return self;
    }

    pub fn deinit(self: *RuntimeClient) void {
        self.deinitChecked() catch @panic(
            "RuntimeClient.deinit called while the client is busy or child handles are active",
        );
    }

    pub fn deinitChecked(self: *RuntimeClient) Error!void {
        self.state_mutex.lockUncancelable(self.io);
        if (self.active_handles != 0) {
            self.state_mutex.unlock(self.io);
            return error.ActiveHandles;
        }
        if (self.active_operations != 0) {
            self.state_mutex.unlock(self.io);
            return error.ClientBusy;
        }
        self.closing = true;
        self.state_mutex.unlock(self.io);

        self.pool.deinit();
        self.connection_options.deinit();
        self.* = undefined;
    }

    /// Stop accepting new work and wake any operations blocked in the pool wait
    /// queue. Existing operations/handles retain ownership until they unwind;
    /// call `deinitChecked` after they have completed.
    pub fn requestShutdown(self: *RuntimeClient) void {
        self.state_mutex.lockUncancelable(self.io);
        self.closing = true;
        self.state_mutex.unlock(self.io);
        self.pool.close();
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
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
        const request_id = self.takeRequestId();
        const request = try crud.encodeInsertOne(
            self.allocator,
            request_id,
            database_name,
            collection_name,
            document,
        );
        defer self.allocator.free(request);
        const response = try self.requestCheckedOut(&transport, request);
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
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
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
        const response = try self.requestCheckedOut(&transport, request);
        defer self.allocator.free(response);
        return crud.parseUpdateResponse(self.allocator, response, request_id);
    }

    pub fn deleteOne(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
    ) !crud.DeleteResult {
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
        const request_id = self.takeRequestId();
        const request = try crud.encodeDeleteOne(
            self.allocator,
            request_id,
            database_name,
            collection_name,
            filter,
        );
        defer self.allocator.free(request);
        const response = try self.requestCheckedOut(&transport, request);
        defer self.allocator.free(response);
        return crud.parseDeleteResponse(response, request_id);
    }

    /// Execute one retryable insert attempt. The caller owns `session` and
    /// reuses it unchanged for any retry so MongoDB can enforce at-most-once
    /// behavior for the logical write.
    pub fn insertOneRetryableAttempt(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        document: anytype,
        session: *const session_mod.Session,
    ) !crud.InsertOneResult {
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
        const request_id = self.takeRequestId();
        const request = try retryable_write.encodeInsertOne(
            self.allocator,
            request_id,
            session,
            database_name,
            collection_name,
            document,
        );
        defer self.allocator.free(request);
        const response = self.requestCheckedOut(&transport, request) catch |err| {
            if (error_response.isRetryableTransportError(err)) return error.RetryableWrite;
            return err;
        };
        defer self.allocator.free(response);
        const status = try error_response.inspect(response, request_id);
        if (status.retryableWrite()) return error.RetryableWrite;
        if (!status.ok) return error.CommandFailed;
        return crud.parseInsertOneResponse(response, request_id);
    }

    pub fn updateOneRetryableAttempt(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        update: anytype,
        upsert: bool,
        session: *const session_mod.Session,
    ) !crud.UpdateResult {
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
        const request_id = self.takeRequestId();
        const request = try retryable_write.encodeUpdateOne(
            self.allocator,
            request_id,
            session,
            database_name,
            collection_name,
            filter,
            update,
            upsert,
        );
        defer self.allocator.free(request);
        const response = self.requestCheckedOut(&transport, request) catch |err| {
            if (error_response.isRetryableTransportError(err)) return error.RetryableWrite;
            return err;
        };
        defer self.allocator.free(response);
        const status = try error_response.inspect(response, request_id);
        if (status.retryableWrite()) return error.RetryableWrite;
        if (!status.ok) return error.CommandFailed;
        return crud.parseUpdateResponse(self.allocator, response, request_id);
    }

    pub fn deleteOneRetryableAttempt(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        session: *const session_mod.Session,
    ) !crud.DeleteResult {
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
        const request_id = self.takeRequestId();
        const request = try retryable_write.encodeDeleteOne(
            self.allocator,
            request_id,
            session,
            database_name,
            collection_name,
            filter,
        );
        defer self.allocator.free(request);
        const response = self.requestCheckedOut(&transport, request) catch |err| {
            if (error_response.isRetryableTransportError(err)) return error.RetryableWrite;
            return err;
        };
        defer self.allocator.free(response);
        const status = try error_response.inspect(response, request_id);
        if (status.retryableWrite()) return error.RetryableWrite;
        if (!status.ok) return error.CommandFailed;
        return crud.parseDeleteResponse(response, request_id);
    }

    pub fn find(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        options: anytype,
    ) !Cursor {
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        errdefer self.releaseTransport(&transport);
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
        const response = try self.requestCheckedOut(&transport, request);
        const cursor = try Cursor.init(
            self,
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

    pub fn findOne(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
    ) !?OwnedDocument {
        try self.beginOperation();
        defer self.endOperation();
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
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
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
        const response = try self.requestCheckedOut(&transport, request);
        defer self.allocator.free(response);
        const bytes = (try find_and_modify.parseDocumentResponse(
            self.allocator,
            response,
            request_id,
        )) orelse return null;
        return .{ .allocator = self.allocator, .bytes = bytes };
    }

    pub fn findOneAndUpdateRetryableAttempt(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        update: anytype,
        upsert: bool,
        session: *const session_mod.Session,
    ) !?OwnedDocument {
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
        const request_id = self.takeRequestId();
        const request = try retryable_write.encodeFindOneAndUpdate(
            self.allocator,
            request_id,
            session,
            database_name,
            collection_name,
            filter,
            update,
            upsert,
        );
        defer self.allocator.free(request);
        const response = self.requestCheckedOut(&transport, request) catch |err| {
            if (error_response.isRetryableTransportError(err)) return error.RetryableWrite;
            return err;
        };
        defer self.allocator.free(response);
        const status = try error_response.inspect(response, request_id);
        if (status.retryableWrite()) return error.RetryableWrite;
        if (!status.ok) return error.CommandFailed;
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
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
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
        const response = try self.requestCheckedOut(&transport, request);
        defer self.allocator.free(response);
        _ = try command_response.validate(response, request_id);
    }

    pub fn beginTransaction(
        self: *RuntimeClient,
        options: session_mod.TransactionOptions,
    ) !Transaction {
        try self.beginOperation();
        defer self.endOperation();
        if (!self.supports_sessions) return error.SessionsUnsupported;
        if (!self.supports_transactions) return error.TransactionsUnsupported;
        var transport: ?PoolHandle = try self.checkout();
        errdefer self.releaseTransport(&transport);
        var session = session_mod.Session.init(self.io);
        try transaction_ops.begin(&session, options);
        const owned_transport = transport.?;
        transport = null;
        self.retainHandle();
        return .{
            .client = self,
            .transport = owned_transport,
            .session = session,
        };
    }

    fn beginOperation(self: *RuntimeClient) Error!void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.closing) return error.ClientClosed;
        self.active_operations += 1;
    }

    fn endOperation(self: *RuntimeClient) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        std.debug.assert(self.active_operations > 0);
        self.active_operations -= 1;
    }

    fn checkout(self: *RuntimeClient) !PoolHandle {
        const budget = try operation_timeout.Budget.start(
            self.io,
            self.connection_options.timeout_ms,
        );
        const deadline = budget.deadline;

        while (true) {
            if (self.pool.take()) |transport| return transport;

            const permit = self.pool.tryStartCreate() catch |err| switch (err) {
                error.PoolExhausted, error.ConnectLimitReached => {
                    try pool_wait.waitForAvailabilityUntil(&self.pool, deadline);
                    continue;
                },
                else => return err,
            };

            var transport = self.openSelectedTransport() catch |err| {
                self.pool.cancelCreate(permit);
                return err;
            };
            self.pool.finishCreate(permit) catch |err| switch (err) {
                error.PoolCleared => {
                    transport.deinit();
                    continue;
                },
                error.PoolExhausted => {
                    transport.deinit();
                    try pool_wait.waitForAvailabilityUntil(&self.pool, deadline);
                    continue;
                },
                else => {
                    transport.deinit();
                    return err;
                },
            };
            return .{
                .transport = transport,
                .generation = permit.generation,
            };
        }
    }

    fn ensureMinPool(self: *RuntimeClient) !void {
        while (self.pool.needsMinConnections()) {
            const permit = self.pool.tryStartCreate() catch |err| switch (err) {
                error.PoolExhausted, error.ConnectLimitReached => {
                    try self.pool.waitForAvailability();
                    continue;
                },
                else => return err,
            };

            var transport = self.openSelectedTransport() catch |err| {
                self.pool.cancelCreate(permit);
                return err;
            };
            self.pool.finishCreate(permit) catch |err| {
                transport.deinit();
                if (err == error.PoolCleared) continue;
                return err;
            };
            const handle: PoolHandle = .{
                .transport = transport,
                .generation = permit.generation,
            };
            self.pool.put(handle) catch |err| {
                self.discard(handle);
                return err;
            };
        }
    }

    /// Return a healthy checked-out transport to the idle pool. After a normal
    /// check-in, best-effort maintenance restores minPoolSize if idle pruning
    /// removed older connections.
    fn checkin(self: *RuntimeClient, transport: PoolHandle) void {
        self.pool.put(transport) catch {
            self.discard(transport);
            return;
        };
        self.ensureMinPool() catch {};
    }

    fn releaseTransport(self: *RuntimeClient, transport: *?PoolHandle) void {
        const owned = transport.* orelse return;
        transport.* = null;
        self.checkin(owned);
    }

    fn discard(self: *RuntimeClient, transport: PoolHandle) void {
        var doomed = transport.transport;
        doomed.deinit();
        self.pool.noteDiscarded();
    }

    fn discardTransport(self: *RuntimeClient, transport: *?PoolHandle) void {
        const owned = transport.* orelse return;
        transport.* = null;
        self.discard(owned);
    }

    fn retainHandle(self: *RuntimeClient) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        std.debug.assert(!self.closing);
        self.active_handles += 1;
    }

    fn releaseHandle(self: *RuntimeClient) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        std.debug.assert(self.active_handles > 0);
        self.active_handles -= 1;
    }

    /// A request error can leave a stream partially written or with an unread
    /// response still pending. Never return such a transport to the pool,
    /// including after a client-side operation timeout.
    fn requestCheckedOut(
        self: *RuntimeClient,
        transport: *?PoolHandle,
        request_bytes: []const u8,
    ) ![]u8 {
        if (transport.*) |*owned| {
            return owned.transport.request(self.allocator, request_bytes) catch |err| {
                self.discardTransport(transport);
                return err;
            };
        }
        return error.UnexpectedResponse;
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
            self.authenticate(&transport) catch |err| {
                transport.deinit();
                return err;
            };
            self.recordSelection(index, description);
            return transport;
        }
        return error.NoWritableServer;
    }

    fn openSelectedTransport(self: *RuntimeClient) !Transport {
        const selected_host = self.selectedHost();
        var transport: ?Transport = self.openTransport(selected_host) catch
            return self.openWritableTransport();
        errdefer if (transport) |*owned| owned.deinit();

        const description = topology.hello(
            &transport.?,
            self.allocator,
            self.takeRequestId(),
        ) catch {
            var stale = transport.?;
            transport = null;
            stale.deinit();
            return self.openWritableTransport();
        };
        if (!description.usableForWrites() and
            self.connection_options.load_balanced != true)
        {
            var stale = transport.?;
            transport = null;
            stale.deinit();
            return self.openWritableTransport();
        }

        try self.authenticate(&transport.?);
        return transport.?;
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

    fn selectedHost(self: *RuntimeClient) usize {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.selected_host;
    }

    fn recordSelection(
        self: *RuntimeClient,
        index: usize,
        description: topology.ServerDescription,
    ) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.selected_host = index;
        if (!self.capabilities_initialized) {
            self.supports_sessions = description.logical_session_timeout_minutes != null;
            self.supports_transactions = description.supports_transactions;
            self.capabilities_initialized = true;
        }
    }

    fn takeRequestId(self: *RuntimeClient) i32 {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const result = self.next_request_id;
        self.next_request_id = if (result == std.math.maxInt(i32)) 1 else result + 1;
        return result;
    }
};

pub const Cursor = struct {
    client: *RuntimeClient,
    transport: ?PoolHandle,
    database_name: []u8,
    collection_name: []u8,
    response_bytes: []u8,
    batch_reader: bson.Reader,
    cursor_id: i64,
    closed: bool = false,

    fn init(
        client: *RuntimeClient,
        transport: PoolHandle,
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
        var cursor: Cursor = .{
            .client = client,
            .transport = transport,
            .database_name = owned_db,
            .collection_name = owned_collection,
            .response_bytes = response_bytes,
            .batch_reader = try bson.Reader.init(parsed.batch),
            .cursor_id = parsed.cursor_id,
        };
        if (cursor.cursor_id == 0) {
            client.releaseTransport(&cursor.transport);
        }
        client.retainHandle();
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
            const response = self.client.requestCheckedOut(
                &self.transport,
                request,
            ) catch |err| {
                self.cursor_id = 0;
                return err;
            };
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
        self.client.releaseTransport(&self.transport);
        self.client.releaseHandle();
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
        const response = self.client.requestCheckedOut(
            &self.transport,
            request,
        ) catch |err| {
            self.closed = true;
            self.cursor_id = 0;
            return err;
        };
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
        if (self.cursor_id == 0) {
            self.client.releaseTransport(&self.transport);
        }
    }
};

pub const Transaction = struct {
    client: *RuntimeClient,
    transport: ?PoolHandle,
    session: session_mod.Session,
    finished: bool = false,
    commit_unknown: bool = false,

    pub fn insertOne(
        self: *Transaction,
        database_name: []const u8,
        collection_name: []const u8,
        document: anytype,
    ) !crud.InsertOneResult {
        const transport = if (self.transport) |*owned| &owned.transport else
            return error.InvalidTransactionState;
        var transport_failed = false;
        return transaction_ops.insertOne(
            transport,
            self.client.allocator,
            &self.session,
            self.client.takeRequestId(),
            database_name,
            collection_name,
            document,
            &transport_failed,
        ) catch |err| {
            if (transport_failed) self.client.discardTransport(&self.transport);
            return err;
        };
    }

    pub fn updateOne(
        self: *Transaction,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        update: anytype,
        upsert: bool,
    ) !crud.UpdateResult {
        const transport = if (self.transport) |*owned| &owned.transport else
            return error.InvalidTransactionState;
        var transport_failed = false;
        return transaction_ops.updateOne(
            transport,
            self.client.allocator,
            &self.session,
            self.client.takeRequestId(),
            database_name,
            collection_name,
            filter,
            update,
            upsert,
            &transport_failed,
        ) catch |err| {
            if (transport_failed) self.client.discardTransport(&self.transport);
            return err;
        };
    }

    pub fn commit(self: *Transaction) !void {
        var retried = false;
        while (true) {
            if (self.transport == null) {
                self.client.pool.clear() catch {};
                self.client.pool.ready() catch {};
                self.transport = self.client.checkout() catch {
                    self.commit_unknown = true;
                    return error.UnknownTransactionCommitResult;
                };
            }
            const transport = &self.transport.?.transport;
            var transport_failed = false;
            transaction_ops.commit(
                transport,
                self.client.allocator,
                &self.session,
                self.client.takeRequestId(),
                &transport_failed,
            ) catch |err| {
                if (transport_failed) self.client.discardTransport(&self.transport);
                if (err == error.UnknownTransactionCommitResult and !retried) {
                    retried = true;
                    // A retried commit uses majority write concern regardless
                    // of the original transaction write concern.
                    self.session.transaction_options.majority_write_concern = true;
                    continue;
                }
                if (err == error.UnknownTransactionCommitResult) self.commit_unknown = true;
                return err;
            };
            self.finished = true;
            self.commit_unknown = false;
            self.release();
            return;
        }
    }

    pub fn abort(self: *Transaction) !void {
        const transport = if (self.transport) |*owned| &owned.transport else
            return error.InvalidTransactionState;
        var transport_failed = false;
        transaction_ops.abort(
            transport,
            self.client.allocator,
            &self.session,
            self.client.takeRequestId(),
            &transport_failed,
        ) catch |err| {
            if (transport_failed) self.client.discardTransport(&self.transport);
            return err;
        };
        self.finished = true;
        self.release();
    }

    pub fn deinit(self: *Transaction) void {
        if (!self.finished and !self.commit_unknown and self.transport != null) self.abort() catch {};
        if (self.transport != null) self.release();
        self.client.releaseHandle();
        self.* = undefined;
    }

    fn release(self: *Transaction) void {
        self.client.releaseTransport(&self.transport);
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
