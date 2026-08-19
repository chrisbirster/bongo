const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{
    EmptyUri,
    UnsupportedScheme,
    MissingHost,
    EmptyHost,
    InvalidHost,
    InvalidIpv6Host,
    InvalidPort,
    EmptyOptionName,
};

pub const Host = struct {
    name: []const u8,
    port: ?u16 = null,
};

pub const Option = struct {
    name: []const u8,
    value: []const u8,
};

/// Owned structural representation of a `mongodb://` connection string.
///
/// String slices point into `storage`. Host and option arrays are separately
/// allocated. Percent-decoding and option normalization intentionally belong
/// to the connection-string validation layer (BONGO-0040).
pub const Parsed = struct {
    allocator: Allocator,
    storage: []u8,
    username: ?[]const u8,
    password: ?[]const u8,
    hosts: []Host,
    database: ?[]const u8,
    options: []Option,

    pub fn deinit(self: *Parsed) void {
        self.allocator.free(self.options);
        self.allocator.free(self.hosts);
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

pub fn parse(allocator: Allocator, uri: []const u8) (Allocator.Error || Error)!Parsed {
    if (uri.len == 0) return error.EmptyUri;

    const prefix = "mongodb://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.UnsupportedScheme;

    const storage = try allocator.dupe(u8, uri[prefix.len..]);
    errdefer allocator.free(storage);

    var remainder: []u8 = storage;

    const query_index = std.mem.indexOfScalar(u8, remainder, '?');
    const before_query = if (query_index) |index| remainder[0..index] else remainder;
    const query = if (query_index) |index| remainder[index + 1 ..] else null;

    const slash_index = std.mem.indexOfScalar(u8, before_query, '/');
    var authority = if (slash_index) |index| before_query[0..index] else before_query;
    const database = if (slash_index) |index| blk: {
        const raw = before_query[index + 1 ..];
        break :blk if (raw.len == 0) null else raw;
    } else null;

    if (authority.len == 0) return error.MissingHost;

    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;

    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at_index| {
        const user_info = authority[0..at_index];
        authority = authority[at_index + 1 ..];
        if (authority.len == 0) return error.MissingHost;

        if (std.mem.indexOfScalar(u8, user_info, ':')) |colon_index| {
            username = user_info[0..colon_index];
            password = user_info[colon_index + 1 ..];
        } else {
            username = user_info;
        }
    }

    var host_count: usize = 1;
    for (authority) |byte| {
        if (byte == ',') host_count += 1;
    }

    const hosts = try allocator.alloc(Host, host_count);
    errdefer allocator.free(hosts);

    var host_it = std.mem.splitScalar(u8, authority, ',');
    var host_index: usize = 0;
    while (host_it.next()) |raw_host| : (host_index += 1) {
        if (raw_host.len == 0) return error.EmptyHost;
        hosts[host_index] = try parseHost(raw_host);
    }
    std.debug.assert(host_index == hosts.len);

    var option_count: usize = 0;
    if (query) |raw_query| {
        if (raw_query.len != 0) {
            option_count = 1;
            for (raw_query) |byte| {
                if (byte == '&') option_count += 1;
            }
        }
    }

    const options = try allocator.alloc(Option, option_count);
    errdefer allocator.free(options);

    if (query) |raw_query| {
        if (raw_query.len != 0) {
            var option_it = std.mem.splitScalar(u8, raw_query, '&');
            var option_index: usize = 0;
            while (option_it.next()) |raw_option| : (option_index += 1) {
                if (raw_option.len == 0) return error.EmptyOptionName;

                if (std.mem.indexOfScalar(u8, raw_option, '=')) |equals_index| {
                    const name = raw_option[0..equals_index];
                    if (name.len == 0) return error.EmptyOptionName;
                    options[option_index] = .{
                        .name = name,
                        .value = raw_option[equals_index + 1 ..],
                    };
                } else {
                    options[option_index] = .{
                        .name = raw_option,
                        .value = "",
                    };
                }
            }
            std.debug.assert(option_index == options.len);
        }
    }

    return .{
        .allocator = allocator,
        .storage = storage,
        .username = username,
        .password = password,
        .hosts = hosts,
        .database = database,
        .options = options,
    };
}

fn parseHost(raw: []const u8) Error!Host {
    if (raw.len == 0) return error.EmptyHost;

    if (raw[0] == '[') {
        const close_index = std.mem.indexOfScalar(u8, raw, ']') orelse
            return error.InvalidIpv6Host;
        if (close_index == 1) return error.InvalidIpv6Host;

        const name = raw[1..close_index];
        const suffix = raw[close_index + 1 ..];

        if (suffix.len == 0) return .{ .name = name };
        if (suffix[0] != ':' or suffix.len == 1) return error.InvalidIpv6Host;
        if (std.mem.indexOfScalar(u8, suffix[1..], ':') != null) {
            return error.InvalidIpv6Host;
        }

        return .{
            .name = name,
            .port = try parsePort(suffix[1..]),
        };
    }

    const first_colon = std.mem.indexOfScalar(u8, raw, ':');
    if (first_colon) |colon_index| {
        if (std.mem.indexOfScalar(u8, raw[colon_index + 1 ..], ':') != null) {
            return error.InvalidHost;
        }

        const name = raw[0..colon_index];
        if (name.len == 0) return error.EmptyHost;
        const port_text = raw[colon_index + 1 ..];
        if (port_text.len == 0) return error.InvalidPort;

        return .{
            .name = name,
            .port = try parsePort(port_text),
        };
    }

    return .{ .name = raw };
}

fn parsePort(raw: []const u8) Error!u16 {
    if (raw.len == 0) return error.InvalidPort;
    return std.fmt.parseInt(u16, raw, 10) catch error.InvalidPort;
}

test "parse simple MongoDB URI" {
    var parsed = try parse(std.testing.allocator, "mongodb://localhost");
    defer parsed.deinit();

    try std.testing.expect(parsed.username == null);
    try std.testing.expect(parsed.password == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.hosts.len);
    try std.testing.expectEqualStrings("localhost", parsed.hosts[0].name);
    try std.testing.expect(parsed.hosts[0].port == null);
    try std.testing.expect(parsed.database == null);
    try std.testing.expectEqual(@as(usize, 0), parsed.options.len);
}

test "parse credentials database and query options structurally" {
    var parsed = try parse(
        std.testing.allocator,
        "mongodb://alice:secret@db.example:27018/app?retryWrites=true&authSource=admin",
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("alice", parsed.username.?);
    try std.testing.expectEqualStrings("secret", parsed.password.?);
    try std.testing.expectEqualStrings("db.example", parsed.hosts[0].name);
    try std.testing.expectEqual(@as(u16, 27018), parsed.hosts[0].port.?);
    try std.testing.expectEqualStrings("app", parsed.database.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.options.len);
    try std.testing.expectEqualStrings("retryWrites", parsed.options[0].name);
    try std.testing.expectEqualStrings("true", parsed.options[0].value);
    try std.testing.expectEqualStrings("authSource", parsed.options[1].name);
    try std.testing.expectEqualStrings("admin", parsed.options[1].value);
}

test "parse multiple seed hosts" {
    var parsed = try parse(
        std.testing.allocator,
        "mongodb://db1.example:27017,db2.example,db3.example:27019/test",
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.hosts.len);
    try std.testing.expectEqualStrings("db1.example", parsed.hosts[0].name);
    try std.testing.expectEqual(@as(u16, 27017), parsed.hosts[0].port.?);
    try std.testing.expectEqualStrings("db2.example", parsed.hosts[1].name);
    try std.testing.expect(parsed.hosts[1].port == null);
    try std.testing.expectEqualStrings("db3.example", parsed.hosts[2].name);
    try std.testing.expectEqual(@as(u16, 27019), parsed.hosts[2].port.?);
}

test "parse bracketed IPv6 safely" {
    var parsed = try parse(
        std.testing.allocator,
        "mongodb://[2001:db8::1]:27018,[::1]/admin",
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.hosts.len);
    try std.testing.expectEqualStrings("2001:db8::1", parsed.hosts[0].name);
    try std.testing.expectEqual(@as(u16, 27018), parsed.hosts[0].port.?);
    try std.testing.expectEqualStrings("::1", parsed.hosts[1].name);
    try std.testing.expect(parsed.hosts[1].port == null);
}

test "parser leaves percent encoding for BONGO-0040" {
    var parsed = try parse(
        std.testing.allocator,
        "mongodb://user%40example:p%40ss@localhost/my%2Ddb?appName=hello%20world",
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("user%40example", parsed.username.?);
    try std.testing.expectEqualStrings("p%40ss", parsed.password.?);
    try std.testing.expectEqualStrings("my%2Ddb", parsed.database.?);
    try std.testing.expectEqualStrings("hello%20world", parsed.options[0].value);
}

test "invalid URI shapes return useful errors" {
    try std.testing.expectError(error.EmptyUri, parse(std.testing.allocator, ""));
    try std.testing.expectError(error.UnsupportedScheme, parse(std.testing.allocator, "http://localhost"));
    try std.testing.expectError(error.MissingHost, parse(std.testing.allocator, "mongodb://"));
    try std.testing.expectError(error.MissingHost, parse(std.testing.allocator, "mongodb://user@"));
    try std.testing.expectError(error.EmptyHost, parse(std.testing.allocator, "mongodb://a,,b"));
    try std.testing.expectError(error.InvalidPort, parse(std.testing.allocator, "mongodb://localhost:nope"));
    try std.testing.expectError(error.InvalidPort, parse(std.testing.allocator, "mongodb://localhost:70000"));
    try std.testing.expectError(error.InvalidHost, parse(std.testing.allocator, "mongodb://2001:db8::1"));
    try std.testing.expectError(error.InvalidIpv6Host, parse(std.testing.allocator, "mongodb://[::1"));
    try std.testing.expectError(error.EmptyOptionName, parse(std.testing.allocator, "mongodb://localhost?=true"));
}
