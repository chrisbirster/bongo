const std = @import("std");
const core_mod = @import("runtime_client_core.zig");
const pool_mod = @import("pool.zig");
const read_preference = @import("read_preference.zig");
const read_runtime_mod = @import("runtime_read.zig");
const sdam = @import("sdam.zig");
const sdam_monitor = @import("sdam_monitor.zig");
const session_mod = @import("session.zig");
const uri_options = @import("uri_options.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const CoreRuntimeClient = core_mod.RuntimeClient;
const Pool = pool_mod.Pool;

pub const Error = core_mod.Error || error{
    ServerSelectionTimeout,
    ReadRuntimeActiveHandles,
};

/// v0.5 keeps the v0.4 CMAP override surface source-compatible. Read
/// preference is configured by URI (`readPreference`, `maxStalenessSeconds`)
/// or explicitly per read through `findWithReadPreference`.
pub const Options = struct {
    min_pool_size: ?usize = null,
    max_pool_size: ?usize = null,
    max_connecting: ?usize = null,
    max_idle_time_ms: ?u64 = null,
};

pub const OwnedDocument = core_mod.OwnedDocument;
pub const Transaction = core_mod.Transaction;

pub const Cursor = union(enum) {
    primary: core_mod.Cursor,
    selected_read: read_runtime_mod.Cursor,

    pub fn next(self: *Cursor) !?[]const u8 {
        return switch (self.*) {
            .primary => |*cursor| cursor.next(),
            .selected_read => |*cursor| cursor.next(),
        };
    }

    pub fn close(self: *Cursor) !void {
        return switch (self.*) {
            .primary => |*cursor| cursor.close(),
            .selected_read => |*cursor| cursor.close(),
        };
    }

    pub fn deinit(self: *Cursor) void {
        switch (self.*) {
            .primary => |*cursor| cursor.deinit(),
            .selected_read => |*cursor| cursor.deinit(),
        }
        self.* = undefined;
    }
};

/// v0.5 production-oriented replica-set facade.
///
/// The validated v0.4 implementation is heap-stable behind `core`. SDAM owns
/// dedicated heartbeat connections and an owned topology model. Primary changes
/// clear the application CMAP generation before the core begins using the new
/// member. Reads selected to non-primary members use per-server read pools.
pub const RuntimeClient = struct {
    allocator: Allocator,
    io: Io,
    core: *CoreRuntimeClient,
    /// Source-compatible public access to the primary application pool.
    pool: *Pool,
    sdam_manager: *sdam_monitor.Manager,
    read_runtime: read_runtime_mod.Runtime,
    route_mutex: Io.Mutex = Io.Mutex.init,
    state_mutex: Io.Mutex = Io.Mutex.init,
    active_operations: usize = 0,
    closing: bool = false,
    supports_sessions: bool = false,
    supports_transactions: bool = false,
    selected_host: usize = 0,

    pub fn connectUri(
        io: Io,
        allocator: Allocator,
        connection_string: []const u8,
        options: Options,
    ) !RuntimeClient {
        const core = try allocator.create(CoreRuntimeClient);
        errdefer allocator.destroy(core);
        core.* = try CoreRuntimeClient.connectUri(
            io,
            allocator,
            connection_string,
            .{
                .min_pool_size = options.min_pool_size,
                .max_pool_size = options.max_pool_size,
                .max_connecting = options.max_connecting,
                .max_idle_time_ms = options.max_idle_time_ms,
            },
        );
        errdefer core.deinit();

        const manager = try sdam_monitor.Manager.create(io, connection_string);
        errdefer manager.destroy();

        var self: RuntimeClient = .{
            .allocator = allocator,
            .io = io,
            .core = core,
            .pool = &core.pool,
            .sdam_manager = manager,
            .read_runtime = read_runtime_mod.Runtime.init(
                allocator,
                io,
                &core.connection_options,
                core.pool.stats(),
            ),
            .supports_sessions = core.supports_sessions,
            .supports_transactions = core.supports_transactions,
            .selected_host = core.selected_host,
        };
        try self.syncWriteTarget();
        return self;
    }

    pub fn deinit(self: *RuntimeClient) void {
        self.deinitChecked() catch @panic(
            "RuntimeClient.deinit called while the client is busy or child handles are active",
        );
    }

    pub fn deinitChecked(self: *RuntimeClient) Error!void {
        self.state_mutex.lockUncancelable(self.io);
        if (self.active_operations != 0) {
            self.state_mutex.unlock(self.io);
            return error.ClientBusy;
        }
        self.state_mutex.unlock(self.io);

        self.core.state_mutex.lockUncancelable(self.io);
        const core_handles = self.core.active_handles;
        const core_operations = self.core.active_operations;
        self.core.state_mutex.unlock(self.io);
        if (core_handles != 0) return error.ActiveHandles;
        if (core_operations != 0) return error.ClientBusy;

        self.read_runtime.mutex.lockUncancelable(self.io);
        const read_handles = self.read_runtime.active_handles;
        self.read_runtime.mutex.unlock(self.io);
        if (read_handles != 0) return error.ReadRuntimeActiveHandles;

        self.state_mutex.lockUncancelable(self.io);
        self.closing = true;
        self.state_mutex.unlock(self.io);
        self.sdam_manager.stopAndJoin();
        try self.read_runtime.deinitChecked();
        try self.core.deinitChecked();
        self.allocator.destroy(self.core);
        self.sdam_manager.destroy();
        self.* = undefined;
    }

    /// Graceful shutdown is deterministic: stop and join heartbeat work first,
    /// reject new facade operations, wake read-pool waiters, then close the
    /// validated primary pool. Child cursors/transactions retain ownership
    /// until they unwind and `deinitChecked` is called.
    pub fn requestShutdown(self: *RuntimeClient) void {
        self.state_mutex.lockUncancelable(self.io);
        if (self.closing) {
            self.state_mutex.unlock(self.io);
            return;
        }
        self.closing = true;
        self.state_mutex.unlock(self.io);
        self.sdam_manager.stopAndJoin();
        self.read_runtime.requestShutdown();
        self.core.requestShutdown();
    }

    pub fn databaseName(self: RuntimeClient) []const u8 {
        return self.core.databaseName();
    }

    pub fn topologyType(self: *RuntimeClient) sdam.TopologyType {
        return self.sdam_manager.topologyType();
    }

    pub fn discoveredServerCount(self: *RuntimeClient) usize {
        return self.sdam_manager.serverCount();
    }

    pub fn refreshTopology(self: *RuntimeClient) !void {
        try self.sdam_manager.scan();
        try self.syncWriteTarget();
    }

    pub fn insertOne(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        document: anytype,
    ) !@import("crud.zig").InsertOneResult {
        try self.beginOperation();
        defer self.endOperation();
        try self.syncWriteTarget();
        return self.core.insertOne(database_name, collection_name, document) catch |err| {
            self.notePrimaryOperationFailure();
            return err;
        };
    }

    pub fn updateOne(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        update: anytype,
        upsert: bool,
    ) !@import("crud.zig").UpdateResult {
        try self.beginOperation();
        defer self.endOperation();
        try self.syncWriteTarget();
        return self.core.updateOne(database_name, collection_name, filter, update, upsert) catch |err| {
            self.notePrimaryOperationFailure();
            return err;
        };
    }

    pub fn deleteOne(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
    ) !@import("crud.zig").DeleteResult {
        try self.beginOperation();
        defer self.endOperation();
        try self.syncWriteTarget();
        return self.core.deleteOne(database_name, collection_name, filter) catch |err| {
            self.notePrimaryOperationFailure();
            return err;
        };
    }

    pub fn find(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        options: anytype,
    ) !Cursor {
        return self.findWithReadPreference(
            database_name,
            collection_name,
            filter,
            options,
            null,
        );
    }

    pub fn findWithReadPreference(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        options: anytype,
        preference: ?read_preference.ReadPreference,
    ) !Cursor {
        try self.beginOperation();
        defer self.endOperation();

        var selected = try self.sdam_manager.selectRead(self.allocator, preference);
        defer selected.deinit();

        var primary = self.sdam_manager.selectWrite(self.allocator) catch null;
        defer if (primary) |*snapshot| snapshot.deinit();
        if (primary) |snapshot| {
            if (std.mem.eql(u8, snapshot.address, selected.address)) {
                try self.syncWriteTargetSnapshot(selected);
                return .{ .primary = try self.core.find(
                    database_name,
                    collection_name,
                    filter,
                    options,
                ) };
            }
        }

        return .{ .selected_read = try self.read_runtime.find(
            selected,
            database_name,
            collection_name,
            filter,
            options,
        ) };
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
        try self.beginOperation();
        defer self.endOperation();
        try self.syncWriteTarget();
        return self.core.findOneAndUpdate(
            database_name,
            collection_name,
            filter,
            update,
            upsert,
        ) catch |err| {
            self.notePrimaryOperationFailure();
            return err;
        };
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
        try self.syncWriteTarget();
        return self.core.createIndex(database_name, collection_name, key, name, options) catch |err| {
            self.notePrimaryOperationFailure();
            return err;
        };
    }

    pub fn beginTransaction(
        self: *RuntimeClient,
        options: session_mod.TransactionOptions,
    ) !Transaction {
        try self.beginOperation();
        defer self.endOperation();
        try self.syncWriteTarget();
        return self.core.beginTransaction(options);
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

    fn syncWriteTarget(self: *RuntimeClient) !void {
        var selected = try self.sdam_manager.selectWrite(self.allocator);
        defer selected.deinit();
        try self.syncWriteTargetSnapshot(selected);
    }

    fn syncWriteTargetSnapshot(
        self: *RuntimeClient,
        selected: sdam_monitor.ServerSnapshot,
    ) !void {
        self.route_mutex.lockUncancelable(self.io);
        defer self.route_mutex.unlock(self.io);

        const host_index = try self.ensureCoreHost(selected.host, selected.port);
        self.core.state_mutex.lockUncancelable(self.io);
        const previous = self.core.selected_host;
        self.core.state_mutex.unlock(self.io);

        if (previous != host_index) {
            self.core.pool.clear() catch |err| switch (err) {
                error.PoolClosed => return error.ClientClosed,
                else => return err,
            };
            try self.core.pool.ready();
            self.core.state_mutex.lockUncancelable(self.io);
            self.core.selected_host = host_index;
            self.core.state_mutex.unlock(self.io);
        }
        self.selected_host = host_index;
    }

    fn ensureCoreHost(self: *RuntimeClient, host: []const u8, port: u16) !usize {
        for (self.core.connection_options.hosts, 0..) |existing, index| {
            if (existing.port == port and std.ascii.eqlIgnoreCase(existing.name, host)) {
                return index;
            }
        }

        const owned_host = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(owned_host);
        const old_len = self.core.connection_options.hosts.len;
        const grown = try self.allocator.realloc(
            self.core.connection_options.hosts,
            old_len + 1,
        );
        self.core.connection_options.hosts = grown;
        grown[old_len] = uri_options.Host{
            .name = owned_host,
            .port = port,
        };
        return old_len;
    }

    fn notePrimaryOperationFailure(self: *RuntimeClient) void {
        self.core.pool.clear() catch {};
        self.sdam_manager.scan() catch {};
        self.core.pool.ready() catch {};
    }
};
