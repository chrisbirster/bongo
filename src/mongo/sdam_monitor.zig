const std = @import("std");
const Connection = @import("connection.zig").Connection;
const read_preference = @import("read_preference.zig");
const sdam = @import("sdam.zig");
const probe = @import("sdam_probe.zig");
const srv = @import("srv.zig");
const TlsConnection = @import("tls_connection.zig").TlsConnection;
const TlsOptions = @import("tls_connection.zig").Options;
const Transport = @import("transport.zig").Transport;
const uri = @import("uri.zig");
const uri_options = @import("uri_options.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const manager_allocator = std.heap.page_allocator;

pub const Error = error{
    InvalidHeartbeatFrequency,
    InvalidServerSelectionOption,
    ServerSelectionTimeout,
};

pub const Config = struct {
    heartbeat_frequency_ms: u32 = 10_000,
    min_heartbeat_frequency_ms: u32 = 500,
    server_selection_timeout_ms: u32 = 30_000,
    local_threshold_ms: u32 = 15,
    read_mode: read_preference.Mode = .primary,
    max_staleness_seconds: ?u32 = null,
};

pub const ServerSnapshot = struct {
    allocator: Allocator,
    address: []u8,
    host: []u8,
    port: u16,
    topology_revision: u64,

    pub fn deinit(self: *ServerSnapshot) void {
        self.allocator.free(self.address);
        self.allocator.free(self.host);
        self.* = undefined;
    }
};

const WaitResult = union(enum) {
    signal: anyerror!void,
    timer: anyerror!void,
};

pub const Manager = struct {
    io: Io,
    connection_options: uri_options.Options,
    config: Config,
    topology: sdam.Topology,
    mutex: Io.Mutex = Io.Mutex.init,
    scan_mutex: Io.Mutex = Io.Mutex.init,
    condition: Io.Condition = std.mem.zeroes(Io.Condition),
    stop_requested: bool = false,
    thread: ?std.Thread = null,
    next_request_id: i32 = 1,

    pub fn create(io: Io, connection_string: []const u8) !*Manager {
        var parsed = if (std.mem.startsWith(u8, connection_string, "mongodb+srv://"))
            try srv.resolve(io, manager_allocator, connection_string)
        else
            try uri_options.parse(manager_allocator, connection_string);
        errdefer parsed.deinit();
        const config = try parseConfig(connection_string);

        const seeds = try manager_allocator.alloc(sdam.Seed, parsed.hosts.len);
        defer manager_allocator.free(seeds);
        for (parsed.hosts, 0..) |host, index| {
            seeds[index] = .{ .host = host.name, .port = host.port };
        }

        var topology = try sdam.Topology.init(
            manager_allocator,
            seeds,
            parsed.replica_set,
        );
        errdefer topology.deinit();

        const self = try manager_allocator.create(Manager);
        self.* = .{
            .io = io,
            .connection_options = parsed,
            .config = config,
            .topology = topology,
        };

        // Existing RuntimeClient construction already performs network I/O.
        // Populate the first SDAM view before returning so the legacy write
        // path and the monitor agree on the selected primary immediately.
        self.scan() catch {};
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn destroy(self: *Manager) void {
        self.stopAndJoin();
        self.topology.deinit();
        self.connection_options.deinit();
        manager_allocator.destroy(self);
    }

    pub fn stopAndJoin(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        if (!self.stop_requested) {
            self.stop_requested = true;
            self.condition.broadcast(self.io);
        }
        self.mutex.unlock(self.io);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn scan(self: *Manager) !void {
        self.scan_mutex.lockUncancelable(self.io);
        defer self.scan_mutex.unlock(self.io);

        var index: usize = 0;
        while (true) : (index += 1) {
            self.mutex.lockUncancelable(self.io);
            if (self.stop_requested or index >= self.topology.servers.items.len) {
                self.mutex.unlock(self.io);
                break;
            }
            const current = self.topology.servers.items[index];
            const address = try manager_allocator.dupe(u8, current.address);
            const host = try manager_allocator.dupe(u8, current.host);
            const port = current.port;
            self.mutex.unlock(self.io);
            defer manager_allocator.free(address);
            defer manager_allocator.free(host);

            const start = Io.Clock.Timestamp.now(self.io, .awake);
            var transport = self.openTransport(host, port) catch {
                self.mutex.lockUncancelable(self.io);
                self.topology.markUnknown(address);
                self.mutex.unlock(self.io);
                continue;
            };
            defer transport.deinit();

            var description = probe.hello(
                &transport,
                manager_allocator,
                self.takeRequestId(),
            ) catch {
                self.mutex.lockUncancelable(self.io);
                self.topology.markUnknown(address);
                self.mutex.unlock(self.io);
                continue;
            };
            defer description.deinit();
            const elapsed = start.untilNow(self.io) catch .{
                .raw = Io.Duration.fromMilliseconds(0),
                .clock = .awake,
            };
            const elapsed_ms = @max(@as(i64, 0), elapsed.raw.toMilliseconds());

            self.mutex.lockUncancelable(self.io);
            self.topology.update(
                address,
                description,
                @floatFromInt(elapsed_ms),
            ) catch |err| {
                self.mutex.unlock(self.io);
                if (err == error.SetNameMismatch) continue;
                return err;
            };
            self.mutex.unlock(self.io);
        }
    }

    pub fn selectWrite(self: *Manager, allocator: Allocator) !ServerSnapshot {
        return self.select(allocator, null);
    }

    pub fn selectRead(
        self: *Manager,
        allocator: Allocator,
        preference_override: ?read_preference.ReadPreference,
    ) !ServerSnapshot {
        return self.select(allocator, preference_override orelse .{
            .mode = self.config.read_mode,
            .max_staleness_seconds = self.config.max_staleness_seconds,
        });
    }

    pub fn topologyRevision(self: *Manager) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.topology.revision;
    }

    pub fn topologyType(self: *Manager) sdam.TopologyType {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.topology.topology_type;
    }

    pub fn serverCount(self: *Manager) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.topology.servers.items.len;
    }

    fn select(
        self: *Manager,
        allocator: Allocator,
        preference: ?read_preference.ReadPreference,
    ) !ServerSnapshot {
        const started = Io.Clock.Timestamp.now(self.io, .awake);
        const total_duration: Io.Clock.Duration = .{
            .raw = Io.Duration.fromMilliseconds(self.config.server_selection_timeout_ms),
            .clock = .awake,
        };
        const deadline = started.addDuration(total_duration);

        while (true) {
            self.mutex.lockUncancelable(self.io);
            const selected = if (preference) |read_pref|
                self.topology.selectRead(
                    read_pref,
                    self.config.local_threshold_ms,
                    self.config.heartbeat_frequency_ms,
                )
            else
                self.topology.selectWrite();
            if (selected) |index| {
                const server = self.topology.servers.items[index];
                const snapshot = ServerSnapshot{
                    .allocator = allocator,
                    .address = try allocator.dupe(u8, server.address),
                    .host = try allocator.dupe(u8, server.host),
                    .port = server.port,
                    .topology_revision = self.topology.revision,
                };
                self.mutex.unlock(self.io);
                return snapshot;
            } else |_| {
                self.mutex.unlock(self.io);
            }

            if (!Io.Clock.Timestamp.now(self.io, .awake).compare(.lt, deadline)) {
                return error.ServerSelectionTimeout;
            }

            // Multi-threaded server selection requests an immediate topology
            // check while no suitable server is available, rate-limited by the
            // SDAM minimum heartbeat frequency.
            self.scan() catch {};

            self.mutex.lockUncancelable(self.io);
            const retry = if (preference) |read_pref|
                self.topology.selectRead(
                    read_pref,
                    self.config.local_threshold_ms,
                    self.config.heartbeat_frequency_ms,
                )
            else
                self.topology.selectWrite();
            if (retry) |index| {
                const server = self.topology.servers.items[index];
                const snapshot = ServerSnapshot{
                    .allocator = allocator,
                    .address = try allocator.dupe(u8, server.address),
                    .host = try allocator.dupe(u8, server.host),
                    .port = server.port,
                    .topology_revision = self.topology.revision,
                };
                self.mutex.unlock(self.io);
                return snapshot;
            } else |_| {
                self.mutex.unlock(self.io);
            }

            const pause: Io.Clock.Duration = .{
                .raw = Io.Duration.fromMilliseconds(self.config.min_heartbeat_frequency_ms),
                .clock = .awake,
            };
            pause.sleep(self.io) catch {};
        }
    }

    fn run(self: *Manager) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const stopped = self.stop_requested;
            self.mutex.unlock(self.io);
            if (stopped) return;

            self.scan() catch {};
            self.waitForHeartbeat();
        }
    }

    fn waitForHeartbeat(self: *Manager) void {
        const now = Io.Clock.Timestamp.now(self.io, .awake);
        const duration: Io.Clock.Duration = .{
            .raw = Io.Duration.fromMilliseconds(self.config.heartbeat_frequency_ms),
            .clock = .awake,
        };
        const deadline = now.addDuration(duration);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stop_requested) return;

        var results: [2]WaitResult = undefined;
        var select: Io.Select(WaitResult) = .init(self.io, &results);
        defer select.cancelDiscard();
        select.concurrent(.signal, conditionWaitTask, .{self}) catch return;
        select.concurrent(.timer, deadlineWaitTask, .{ self.io, deadline }) catch return;
        _ = select.await() catch return;
    }

    fn openTransport(self: *Manager, host: []const u8, port: u16) !Transport {
        if (self.connection_options.tls == true) {
            const tls_options = try TlsOptions.fromConnectionOptions(self.connection_options);
            return .{ .tls = try TlsConnection.connect(
                self.io,
                manager_allocator,
                host,
                port,
                tls_options,
            ) };
        }
        return .{ .tcp = try Connection.connectWithOptions(
            self.io,
            host,
            port,
            .{
                .connect_timeout_ms = self.connection_options.connect_timeout_ms,
                .socket_timeout_ms = self.connection_options.socket_timeout_ms,
                .operation_timeout_ms = self.connection_options.timeout_ms,
            },
        ) };
    }

    fn takeRequestId(self: *Manager) i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.next_request_id;
        self.next_request_id = if (result == std.math.maxInt(i32)) 1 else result + 1;
        return result;
    }
};

fn conditionWaitTask(self: *Manager) anyerror!void {
    try self.condition.wait(self.io, &self.mutex);
}

fn deadlineWaitTask(io: Io, deadline: Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io);
}

fn parseConfig(connection_string: []const u8) !Config {
    var raw = try uri.parse(manager_allocator, connection_string);
    defer raw.deinit();
    var config: Config = .{};
    for (raw.options) |option| {
        if (std.ascii.eqlIgnoreCase(option.name, "heartbeatFrequencyMS")) {
            config.heartbeat_frequency_ms = try parseU32(option.value);
            if (config.heartbeat_frequency_ms < 500) return error.InvalidHeartbeatFrequency;
        } else if (std.ascii.eqlIgnoreCase(option.name, "serverSelectionTimeoutMS")) {
            config.server_selection_timeout_ms = try parseU32(option.value);
        } else if (std.ascii.eqlIgnoreCase(option.name, "localThresholdMS")) {
            config.local_threshold_ms = try parseU32(option.value);
        } else if (std.ascii.eqlIgnoreCase(option.name, "readPreference")) {
            config.read_mode = try parseReadMode(option.value);
        } else if (std.ascii.eqlIgnoreCase(option.name, "maxStalenessSeconds")) {
            config.max_staleness_seconds = try parseU32(option.value);
        }
    }
    try (read_preference.ReadPreference{
        .mode = config.read_mode,
        .max_staleness_seconds = config.max_staleness_seconds,
    }).validate();
    return config;
}

fn parseU32(value: []const u8) Error!u32 {
    return std.fmt.parseInt(u32, value, 10) catch error.InvalidServerSelectionOption;
}

fn parseReadMode(value: []const u8) Error!read_preference.Mode {
    if (std.ascii.eqlIgnoreCase(value, "primary")) return .primary;
    if (std.ascii.eqlIgnoreCase(value, "primaryPreferred")) return .primary_preferred;
    if (std.ascii.eqlIgnoreCase(value, "secondary")) return .secondary;
    if (std.ascii.eqlIgnoreCase(value, "secondaryPreferred")) return .secondary_preferred;
    if (std.ascii.eqlIgnoreCase(value, "nearest")) return .nearest;
    return error.InvalidServerSelectionOption;
}

test "SDAM selection defaults match MongoDB driver defaults" {
    const config = try parseConfig("mongodb://localhost:27017/test");
    try std.testing.expectEqual(@as(u32, 10_000), config.heartbeat_frequency_ms);
    try std.testing.expectEqual(@as(u32, 30_000), config.server_selection_timeout_ms);
    try std.testing.expectEqual(@as(u32, 15), config.local_threshold_ms);
    try std.testing.expectEqual(read_preference.Mode.primary, config.read_mode);
}

test "heartbeat frequency enforces the 500ms SDAM minimum" {
    try std.testing.expectError(
        error.InvalidHeartbeatFrequency,
        parseConfig("mongodb://localhost:27017/test?heartbeatFrequencyMS=499"),
    );
}
