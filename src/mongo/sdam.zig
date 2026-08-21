const std = @import("std");
const bson = @import("../bson.zig");
const read_preference = @import("read_preference.zig");
const probe = @import("sdam_probe.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    SetNameMismatch,
    NoSuitableServer,
    InvalidAddress,
};

pub const TopologyType = enum {
    unknown,
    single,
    replica_set_no_primary,
    replica_set_with_primary,
    sharded,
    load_balanced,
};

pub const ServerType = enum {
    unknown,
    standalone,
    rs_primary,
    rs_secondary,
    rs_arbiter,
    rs_other,
    mongos,
};

pub const Seed = struct {
    host: []const u8,
    port: u16 = 27017,
};

pub const Server = struct {
    allocator: Allocator,
    address: []u8,
    host: []u8,
    port: u16,
    server_type: ServerType = .unknown,
    rtt_ms: ?f64 = null,
    tags: ?[]u8 = null,
    last_write_date_ms: ?i64 = null,
    logical_session_timeout_minutes: ?i64 = null,
    min_wire_version: ?i32 = null,
    max_wire_version: ?i32 = null,

    pub fn deinit(self: *Server) void {
        self.allocator.free(self.address);
        self.allocator.free(self.host);
        if (self.tags) |tags| self.allocator.free(tags);
        self.* = undefined;
    }

    pub fn suitableForWrites(self: Server) bool {
        return self.server_type == .rs_primary or
            self.server_type == .standalone or
            self.server_type == .mongos;
    }

    pub fn suitableForReads(self: Server) bool {
        return self.server_type == .rs_primary or
            self.server_type == .rs_secondary or
            self.server_type == .standalone or
            self.server_type == .mongos;
    }
};

pub const Topology = struct {
    allocator: Allocator,
    topology_type: TopologyType = .unknown,
    requested_set_name: ?[]u8 = null,
    discovered_set_name: ?[]u8 = null,
    servers: std.ArrayList(Server) = .empty,
    revision: u64 = 0,
    selection_counter: usize = 0,

    pub fn init(
        allocator: Allocator,
        seeds: []const Seed,
        requested_set_name: ?[]const u8,
    ) !Topology {
        var self: Topology = .{ .allocator = allocator };
        errdefer self.deinit();
        if (requested_set_name) |name| {
            self.requested_set_name = try allocator.dupe(u8, name);
            self.topology_type = .replica_set_no_primary;
        }
        for (seeds) |seed| {
            _ = try self.ensureHostPort(seed.host, seed.port);
        }
        return self;
    }

    pub fn deinit(self: *Topology) void {
        for (self.servers.items) |*server| server.deinit();
        self.servers.deinit(self.allocator);
        if (self.requested_set_name) |name| self.allocator.free(name);
        if (self.discovered_set_name) |name| self.allocator.free(name);
        self.* = undefined;
    }

    pub fn update(
        self: *Topology,
        address: []const u8,
        description: probe.Description,
        sample_rtt_ms: f64,
    ) !void {
        const index = try self.ensureAddress(address);

        if (self.requested_set_name) |expected| {
            const actual = description.set_name orelse {
                self.markUnknownByIndex(index);
                return error.SetNameMismatch;
            };
            if (!std.mem.eql(u8, expected, actual)) {
                self.markUnknownByIndex(index);
                return error.SetNameMismatch;
            }
        }

        if (description.set_name) |set_name| {
            if (self.discovered_set_name == null) {
                self.discovered_set_name = try self.allocator.dupe(u8, set_name);
            }
        }

        try self.ensureAddresses(description.hosts);
        try self.ensureAddresses(description.passives);
        try self.ensureAddresses(description.arbiters);
        if (description.primary) |primary| _ = try self.ensureAddress(primary);
        if (description.me) |me| _ = try self.ensureAddress(me);

        var server = &self.servers.items[index];
        server.server_type = classify(description);
        server.rtt_ms = smoothRtt(server.rtt_ms, sample_rtt_ms);
        if (server.tags) |tags| self.allocator.free(tags);
        server.tags = if (description.tags) |tags|
            try self.allocator.dupe(u8, tags)
        else
            null;
        server.last_write_date_ms = description.last_write_date_ms;
        server.logical_session_timeout_minutes = description.logical_session_timeout_minutes;
        server.min_wire_version = description.min_wire_version;
        server.max_wire_version = description.max_wire_version;

        if (server.server_type == .rs_primary) {
            for (self.servers.items, 0..) |*other, other_index| {
                if (other_index != index and other.server_type == .rs_primary) {
                    other.server_type = .unknown;
                }
            }
        }

        self.recomputeTopologyType();
        self.revision +%= 1;
    }

    pub fn markUnknown(self: *Topology, address: []const u8) void {
        const index = self.find(address) orelse return;
        self.markUnknownByIndex(index);
        self.recomputeTopologyType();
        self.revision +%= 1;
    }

    pub fn primaryIndex(self: *const Topology) ?usize {
        for (self.servers.items, 0..) |server, index| {
            if (server.server_type == .rs_primary or
                server.server_type == .standalone or
                server.server_type == .mongos)
            {
                return index;
            }
        }
        return null;
    }

    pub fn selectWrite(self: *Topology) Error!usize {
        return self.primaryIndex() orelse error.NoSuitableServer;
    }

    pub fn selectRead(
        self: *Topology,
        preference: read_preference.ReadPreference,
        local_threshold_ms: u32,
        heartbeat_frequency_ms: u32,
    ) !usize {
        try preference.validate();

        if (preference.mode == .primary) return self.selectWrite();
        if (preference.mode == .primary_preferred) {
            if (self.primaryIndex()) |index| return index;
        }

        const has_secondary = self.hasEligibleSecondary(preference, heartbeat_frequency_ms);
        if (preference.mode == .secondary_preferred and !has_secondary) {
            if (self.primaryIndex()) |index| return index;
        }

        var fastest: ?f64 = null;
        for (self.servers.items, 0..) |server, index| {
            if (!self.readModeAllows(index, preference.mode, has_secondary)) continue;
            if (!self.serverMatchesReadConstraints(index, preference, heartbeat_frequency_ms)) continue;
            const rtt = server.rtt_ms orelse continue;
            if (fastest == null or rtt < fastest.?) fastest = rtt;
        }
        const min_rtt = fastest orelse return error.NoSuitableServer;
        const threshold: f64 = @floatFromInt(local_threshold_ms);
        const window = min_rtt + threshold;

        var eligible_count: usize = 0;
        for (self.servers.items, 0..) |server, index| {
            if (!self.readModeAllows(index, preference.mode, has_secondary)) continue;
            if (!self.serverMatchesReadConstraints(index, preference, heartbeat_frequency_ms)) continue;
            const rtt = server.rtt_ms orelse continue;
            if (rtt <= window) eligible_count += 1;
        }
        if (eligible_count == 0) return error.NoSuitableServer;

        const chosen = self.selection_counter % eligible_count;
        self.selection_counter +%= 1;
        var seen: usize = 0;
        for (self.servers.items, 0..) |server, index| {
            if (!self.readModeAllows(index, preference.mode, has_secondary)) continue;
            if (!self.serverMatchesReadConstraints(index, preference, heartbeat_frequency_ms)) continue;
            const rtt = server.rtt_ms orelse continue;
            if (rtt > window) continue;
            if (seen == chosen) return index;
            seen += 1;
        }
        unreachable;
    }

    pub fn find(self: *const Topology, address: []const u8) ?usize {
        for (self.servers.items, 0..) |server, index| {
            if (std.ascii.eqlIgnoreCase(server.address, address)) return index;
        }
        return null;
    }

    pub fn ensureAddress(self: *Topology, address: []const u8) !usize {
        if (self.find(address)) |index| return index;
        const parsed = try parseAddress(address);
        return self.ensureHostPort(parsed.host, parsed.port);
    }

    fn ensureAddresses(self: *Topology, addresses: [][]u8) !void {
        for (addresses) |address| _ = try self.ensureAddress(address);
    }

    fn ensureHostPort(self: *Topology, host: []const u8, port: u16) !usize {
        const address = try canonicalAddress(self.allocator, host, port);
        errdefer self.allocator.free(address);
        if (self.find(address)) |index| {
            self.allocator.free(address);
            return index;
        }
        const owned_host = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(owned_host);
        for (owned_host) |*byte| byte.* = std.ascii.toLower(byte.*);
        try self.servers.append(self.allocator, .{
            .allocator = self.allocator,
            .address = address,
            .host = owned_host,
            .port = port,
        });
        self.revision +%= 1;
        return self.servers.items.len - 1;
    }

    fn markUnknownByIndex(self: *Topology, index: usize) void {
        var server = &self.servers.items[index];
        server.server_type = .unknown;
        server.rtt_ms = null;
        if (server.tags) |tags| self.allocator.free(tags);
        server.tags = null;
        server.last_write_date_ms = null;
    }

    fn recomputeTopologyType(self: *Topology) void {
        var has_primary = false;
        var has_replica_member = false;
        var has_mongos = false;
        var has_standalone = false;
        for (self.servers.items) |server| {
            switch (server.server_type) {
                .rs_primary => {
                    has_primary = true;
                    has_replica_member = true;
                },
                .rs_secondary, .rs_arbiter, .rs_other => has_replica_member = true,
                .mongos => has_mongos = true,
                .standalone => has_standalone = true,
                .unknown => {},
            }
        }
        if (has_mongos) {
            self.topology_type = .sharded;
        } else if (has_replica_member or self.requested_set_name != null or self.discovered_set_name != null) {
            self.topology_type = if (has_primary)
                .replica_set_with_primary
            else
                .replica_set_no_primary;
        } else if (has_standalone and self.servers.items.len == 1) {
            self.topology_type = .single;
        } else {
            self.topology_type = .unknown;
        }
    }

    fn hasEligibleSecondary(
        self: *Topology,
        preference: read_preference.ReadPreference,
        heartbeat_frequency_ms: u32,
    ) bool {
        for (self.servers.items, 0..) |server, index| {
            if (server.server_type != .rs_secondary) continue;
            if (self.serverMatchesReadConstraints(index, preference, heartbeat_frequency_ms)) return true;
        }
        return false;
    }

    fn readModeAllows(
        self: *const Topology,
        index: usize,
        mode: read_preference.Mode,
        has_secondary: bool,
    ) bool {
        const server_type = self.servers.items[index].server_type;
        return switch (mode) {
            .primary => server_type == .rs_primary or server_type == .standalone or server_type == .mongos,
            .primary_preferred => server_type == .rs_secondary,
            .secondary => server_type == .rs_secondary,
            .secondary_preferred => if (has_secondary)
                server_type == .rs_secondary
            else
                server_type == .rs_primary or server_type == .standalone or server_type == .mongos,
            .nearest => server_type == .rs_primary or server_type == .rs_secondary or server_type == .standalone or server_type == .mongos,
        };
    }

    fn serverMatchesReadConstraints(
        self: *Topology,
        index: usize,
        preference: read_preference.ReadPreference,
        heartbeat_frequency_ms: u32,
    ) bool {
        const server = self.servers.items[index];
        if (!server.suitableForReads()) return false;
        if (server.server_type == .rs_secondary and preference.max_staleness_seconds != null) {
            if (self.stalenessMs(index, heartbeat_frequency_ms)) |staleness| {
                const max_seconds: i64 = @intCast(preference.max_staleness_seconds.?);
                const max_ms = max_seconds * 1000;
                if (staleness > max_ms) return false;
            } else return false;
        }
        return matchesAnyTagSet(server.tags, preference.tag_sets);
    }

    fn stalenessMs(self: *const Topology, index: usize, heartbeat_frequency_ms: u32) ?i64 {
        const secondary = self.servers.items[index];
        const secondary_last = secondary.last_write_date_ms orelse return null;
        const heartbeat_ms: i64 = @intCast(heartbeat_frequency_ms);
        if (self.primaryIndex()) |primary_index| {
            const primary_last = self.servers.items[primary_index].last_write_date_ms orelse return null;
            return @max(@as(i64, 0), primary_last - secondary_last) + heartbeat_ms;
        }
        var newest: ?i64 = null;
        for (self.servers.items) |server| {
            if (server.server_type != .rs_secondary) continue;
            const last = server.last_write_date_ms orelse continue;
            if (newest == null or last > newest.?) newest = last;
        }
        const newest_last = newest orelse return null;
        return @max(@as(i64, 0), newest_last - secondary_last) + heartbeat_ms;
    }
};

fn classify(description: probe.Description) ServerType {
    if (description.is_mongos) return .mongos;
    if (description.set_name == null) {
        if (description.is_writable_primary) return .standalone;
        return .unknown;
    }
    if (description.is_writable_primary) return .rs_primary;
    if (description.secondary) return .rs_secondary;
    if (description.arbiter_only) return .rs_arbiter;
    return .rs_other;
}

fn smoothRtt(previous: ?f64, sample: f64) f64 {
    const old = previous orelse return sample;
    return old * 0.8 + sample * 0.2;
}

fn matchesAnyTagSet(server_tags: ?[]u8, tag_sets: []const read_preference.TagSet) bool {
    if (tag_sets.len == 0) return true;
    for (tag_sets) |tag_set| {
        if (tagSetMatches(server_tags, tag_set.document)) return true;
    }
    return false;
}

fn tagSetMatches(server_tags: ?[]u8, desired: []const u8) bool {
    var desired_reader = bson.Reader.init(desired) catch return false;
    var had_tag = false;
    while (desired_reader.next() catch return false) |element| {
        had_tag = true;
        const tags = server_tags orelse return false;
        const actual_optional = bson.Reader.get(tags, element.name) catch return false;
        const actual = actual_optional orelse return false;
        if (!valueEqual(actual, element.value)) return false;
    }
    return !had_tag or server_tags != null;
}

fn valueEqual(a: bson.Value, b: bson.Value) bool {
    return switch (a) {
        .string => |value| switch (b) {
            .string => |other| std.mem.eql(u8, value, other),
            else => false,
        },
        .int32 => |value| switch (b) {
            .int32 => |other| value == other,
            .int64 => |other| value == other,
            else => false,
        },
        .int64 => |value| switch (b) {
            .int32 => |other| value == other,
            .int64 => |other| value == other,
            else => false,
        },
        .boolean => |value| switch (b) {
            .boolean => |other| value == other,
            else => false,
        },
        else => false,
    };
}

const ParsedAddress = struct {
    host: []const u8,
    port: u16,
};

fn parseAddress(address: []const u8) Error!ParsedAddress {
    if (address.len == 0) return error.InvalidAddress;
    if (address[0] == '[') {
        const close = std.mem.indexOfScalar(u8, address, ']') orelse return error.InvalidAddress;
        const host = address[1..close];
        if (close + 1 == address.len) return .{ .host = host, .port = 27017 };
        if (address[close + 1] != ':') return error.InvalidAddress;
        const port = std.fmt.parseInt(u16, address[close + 2 ..], 10) catch return error.InvalidAddress;
        return .{ .host = host, .port = port };
    }
    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse
        return .{ .host = address, .port = 27017 };
    if (std.mem.indexOfScalar(u8, address[0..colon], ':') != null) {
        return error.InvalidAddress;
    }
    const port = std.fmt.parseInt(u16, address[colon + 1 ..], 10) catch return error.InvalidAddress;
    return .{ .host = address[0..colon], .port = port };
}

fn canonicalAddress(allocator: Allocator, host: []const u8, port: u16) ![]u8 {
    const address = if (std.mem.indexOfScalar(u8, host, ':') != null)
        try std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ host, port })
    else
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
    for (address) |*byte| byte.* = std.ascii.toLower(byte.*);
    return address;
}

test "topology discovers replica-set members and primary" {
    const allocator = std.testing.allocator;
    var topology = try Topology.init(allocator, &.{.{ .host = "db1", .port = 27017 }}, "rs0");
    defer topology.deinit();

    const hosts = [_][]const u8{ "db1:27017", "db2:27017", "db3:27017" };
    const body = try bson.encode(allocator, .{
        .ok = @as(i32, 1),
        .isWritablePrimary = true,
        .setName = "rs0",
        .primary = "db1:27017",
        .hosts = hosts,
    });
    defer allocator.free(body);
    var description = try probe.parseOwned(allocator, body);
    defer description.deinit();
    try topology.update("db1:27017", description, 2.0);

    try std.testing.expectEqual(TopologyType.replica_set_with_primary, topology.topology_type);
    try std.testing.expectEqual(@as(usize, 3), topology.servers.items.len);
    try std.testing.expectEqualStrings("db1:27017", topology.servers.items[(try topology.selectWrite())].address);
}

test "latency window filters slow read candidates" {
    const allocator = std.testing.allocator;
    var topology = try Topology.init(allocator, &.{
        .{ .host = "db1", .port = 27017 },
        .{ .host = "db2", .port = 27017 },
        .{ .host = "db3", .port = 27017 },
    }, "rs0");
    defer topology.deinit();

    const bodies = [_][]u8{
        try bson.encode(allocator, .{ .ok = @as(i32, 1), .isWritablePrimary = true, .setName = "rs0", .lastWrite = .{ .lastWriteDate = bson.DateTime{ .milliseconds = 10_000 } } }),
        try bson.encode(allocator, .{ .ok = @as(i32, 1), .secondary = true, .setName = "rs0", .lastWrite = .{ .lastWriteDate = bson.DateTime{ .milliseconds = 9_999 } } }),
        try bson.encode(allocator, .{ .ok = @as(i32, 1), .secondary = true, .setName = "rs0", .lastWrite = .{ .lastWriteDate = bson.DateTime{ .milliseconds = 9_999 } } }),
    };
    defer {
        for (bodies) |body| allocator.free(body);
    }
    const addresses = [_][]const u8{ "db1:27017", "db2:27017", "db3:27017" };
    const rtts = [_]f64{ 2.0, 5.0, 40.0 };
    for (bodies, addresses, rtts) |body, address, rtt| {
        var description = try probe.parseOwned(allocator, body);
        defer description.deinit();
        try topology.update(address, description, rtt);
    }

    const selected = try topology.selectRead(.{ .mode = .nearest }, 15, 10_000);
    try std.testing.expect(!std.mem.eql(u8, topology.servers.items[selected].address, "db3:27017"));
}
