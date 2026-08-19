const std = @import("std");
const uri_options = @import("uri_options.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = Io.net;

const dns_type_txt: u16 = 16;
const dns_type_srv: u16 = 33;
const dns_class_in: u16 = 1;
const default_service = "mongodb";

pub const Error = uri_options.Error || error{
    UnsupportedScheme,
    MissingHost,
    MultipleHosts,
    PortNotAllowed,
    InvalidSrvHost,
    InvalidSrvServiceName,
    InvalidSrvMaxHosts,
    DnsQueryFailed,
    InvalidDnsResponse,
    NoSrvRecords,
    InvalidSrvTarget,
    InvalidSrvPort,
    MultipleTxtRecords,
    InvalidTxtRecord,
    InvalidTxtOption,
    IncompatibleSrvOptions,
};

const SrvUri = struct {
    userinfo: ?[]const u8,
    host: []const u8,
    database: ?[]const u8,
    had_slash: bool,
    query: ?[]const u8,
    service_name: []u8,
    max_hosts: u32,

    fn deinit(self: *SrvUri, allocator: Allocator) void {
        allocator.free(self.service_name);
        self.* = undefined;
    }
};

const SrvRecord = struct {
    host: []u8,
    port: u16,

    fn deinit(self: SrvRecord, allocator: Allocator) void {
        allocator.free(self.host);
    }
};

const Lookup = struct {
    srv: []SrvRecord,
    txt: ?[]u8,

    fn deinit(self: *Lookup, allocator: Allocator) void {
        for (self.srv) |record| record.deinit(allocator);
        allocator.free(self.srv);
        if (self.txt) |txt| allocator.free(txt);
        self.* = undefined;
    }
};

/// Resolve a `mongodb+srv://` URI into the same owned, normalized option model
/// returned by `parseConnectionOptions` for a normal `mongodb://` URI.
///
/// Discovery is complete before this function returns: SRV hosts are validated
/// against the original parent domain, TXT defaults are merged, SRV-only
/// options are consumed, and TLS is enabled implicitly unless the URI says
/// otherwise. The caller owns the returned options and must call `deinit()`.
pub fn resolve(
    io: Io,
    allocator: Allocator,
    connection_string: []const u8,
) (Allocator.Error || Error || net.Socket.BindError || net.Socket.SendError || net.Socket.ReceiveTimeoutError || net.HostName.ResolvConf.InitError)!uri_options.Options {
    var parsed = try parseSrvUri(allocator, connection_string);
    defer parsed.deinit(allocator);

    var lookup = try lookupDns(io, allocator, parsed.host, parsed.service_name);
    defer lookup.deinit(allocator);

    if (lookup.srv.len == 0) return error.NoSrvRecords;
    for (lookup.srv) |record| {
        if (record.port == 0) return error.InvalidSrvPort;
        if (!validTarget(parsed.host, record.host)) return error.InvalidSrvTarget;
    }

    if (parsed.max_hosts > 0 and parsed.max_hosts < lookup.srv.len) {
        shuffle(io, lookup.srv);
        const keep: usize = @intCast(parsed.max_hosts);
        for (lookup.srv[keep..]) |record| record.deinit(allocator);
        lookup.srv = try allocator.realloc(lookup.srv, keep);
    }

    const synthesized = try synthesizeConnectionString(
        allocator,
        parsed,
        lookup.srv,
        lookup.txt,
    );
    defer allocator.free(synthesized);

    var options = try uri_options.parse(allocator, synthesized);
    errdefer options.deinit();

    if (parsed.max_hosts > 0 and
        (options.replica_set != null or options.load_balanced == true))
    {
        return error.IncompatibleSrvOptions;
    }

    return options;
}

/// Parent-domain validation required by the MongoDB Initial DNS Seedlist
/// Discovery specification.
pub fn validTarget(original_host: []const u8, target: []const u8) bool {
    if (original_host.len == 0 or target.len == 0) return false;

    const original_labels = labelCount(original_host);
    const domain = if (original_labels >= 3)
        original_host[(std.mem.indexOfScalar(u8, original_host, '.') orelse return false) + 1 ..]
    else
        original_host;

    if (std.ascii.eqlIgnoreCase(target, domain)) {
        return original_labels >= 3;
    }
    if (target.len <= domain.len) return false;
    if (!std.ascii.endsWithIgnoreCase(target, domain)) return false;
    if (target[target.len - domain.len - 1] != '.') return false;

    if (original_labels < 3 and labelCount(target) <= original_labels) {
        return false;
    }
    return true;
}

fn parseSrvUri(allocator: Allocator, connection_string: []const u8) (Allocator.Error || Error)!SrvUri {
    const prefix = "mongodb+srv://";
    if (!std.mem.startsWith(u8, connection_string, prefix)) {
        return error.UnsupportedScheme;
    }

    const remainder = connection_string[prefix.len..];
    if (remainder.len == 0) return error.MissingHost;

    const question = std.mem.indexOfScalar(u8, remainder, '?');
    const before_query = if (question) |i| remainder[0..i] else remainder;
    const query = if (question) |i| remainder[i + 1 ..] else null;

    const slash = std.mem.indexOfScalar(u8, before_query, '/');
    const authority = if (slash) |i| before_query[0..i] else before_query;
    const database = if (slash) |i| before_query[i + 1 ..] else null;
    if (authority.len == 0) return error.MissingHost;

    const at = std.mem.lastIndexOfScalar(u8, authority, '@');
    const userinfo = if (at) |i| authority[0..i] else null;
    const host = if (at) |i| authority[i + 1 ..] else authority;
    if (host.len == 0) return error.MissingHost;
    if (std.mem.indexOfScalar(u8, host, ',') != null) return error.MultipleHosts;
    if (std.mem.indexOfScalar(u8, host, ':') != null or
        std.mem.indexOfScalar(u8, host, '[') != null or
        std.mem.indexOfScalar(u8, host, ']') != null)
    {
        return error.PortNotAllowed;
    }
    if (std.mem.indexOfScalar(u8, host, '/') != null or
        std.mem.indexOfScalar(u8, host, '\\') != null)
    {
        return error.InvalidSrvHost;
    }

    var service_name = try allocator.dupe(u8, default_service);
    errdefer allocator.free(service_name);
    var max_hosts: u32 = 0;
    var saw_service = false;
    var saw_max_hosts = false;

    if (query) |raw_query| {
        var it = std.mem.splitScalar(u8, raw_query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=');
            const name = if (eq) |i| pair[0..i] else pair;
            const raw_value = if (eq) |i| pair[i + 1 ..] else "";

            if (std.ascii.eqlIgnoreCase(name, "srvServiceName")) {
                if (saw_service) return error.DuplicateOption;
                saw_service = true;
                const decoded = try decodeComponent(allocator, raw_value);
                errdefer allocator.free(decoded);
                if (!validServiceName(decoded)) return error.InvalidSrvServiceName;
                allocator.free(service_name);
                service_name = decoded;
            } else if (std.ascii.eqlIgnoreCase(name, "srvMaxHosts")) {
                if (saw_max_hosts) return error.DuplicateOption;
                saw_max_hosts = true;
                const decoded = try decodeComponent(allocator, raw_value);
                defer allocator.free(decoded);
                if (decoded.len == 0) return error.InvalidSrvMaxHosts;
                max_hosts = std.fmt.parseInt(u32, decoded, 10) catch
                    return error.InvalidSrvMaxHosts;
            }
        }
    }

    return .{
        .userinfo = userinfo,
        .host = host,
        .database = database,
        .had_slash = slash != null,
        .query = query,
        .service_name = service_name,
        .max_hosts = max_hosts,
    };
}

fn lookupDns(io: Io, allocator: Allocator, host: []const u8, service: []const u8) !Lookup {
    const srv_name = try std.fmt.allocPrint(
        allocator,
        "_{s}._tcp.{s}",
        .{ service, host },
    );
    defer allocator.free(srv_name);

    const srv_packet = try queryDns(io, allocator, srv_name, dns_type_srv);
    defer allocator.free(srv_packet);
    const srv = try parseSrvResponse(allocator, srv_packet);
    errdefer {
        for (srv) |record| record.deinit(allocator);
        allocator.free(srv);
    }

    const txt_packet = queryDns(io, allocator, host, dns_type_txt) catch |err| switch (err) {
        error.DnsQueryFailed => return .{ .srv = srv, .txt = null },
        else => |e| return e,
    };
    defer allocator.free(txt_packet);
    const txt = try parseTxtResponse(allocator, txt_packet);

    return .{ .srv = srv, .txt = txt };
}

fn queryDns(io: Io, allocator: Allocator, name: []const u8, record_type: u16) ![]u8 {
    var id_bytes: [2]u8 = undefined;
    io.random(&id_bytes);
    const transaction_id = std.mem.readInt(u16, &id_bytes, .little);

    const request = try encodeDnsQuery(allocator, transaction_id, name, record_type);
    defer allocator.free(request);

    var resolv = try net.HostName.ResolvConf.init(io);
    const nameservers = resolv.nameservers();
    if (nameservers.len == 0) return error.DnsQueryFailed;

    var response_buffer: [4096]u8 = undefined;
    var attempt: u32 = 0;
    while (attempt < @max(resolv.attempts, 1)) : (attempt += 1) {
        for (nameservers) |nameserver| {
            var bind_address: net.IpAddress = switch (nameserver) {
                .ip4 => .{ .ip4 = .unspecified(0) },
                .ip6 => .{ .ip6 = .unspecified(0) },
            };
            const socket = bind_address.bind(io, .{
                .mode = .dgram,
                .protocol = .udp,
            }) catch continue;
            defer socket.close(io);

            socket.send(io, &nameserver, request) catch continue;
            const incoming = socket.receiveTimeout(
                io,
                &response_buffer,
                .{ .duration = .{
                    .raw = Io.Duration.fromSeconds(@intCast(@max(resolv.timeout_seconds, 1))),
                    .clock = .awake,
                } },
            ) catch continue;

            if (incoming.data.len < 12) continue;
            if (std.mem.readInt(u16, incoming.data[0..2], .big) != transaction_id) continue;
            const flags = std.mem.readInt(u16, incoming.data[2..4], .big);
            if (flags & 0x8000 == 0 or flags & 0x000f != 0) continue;
            return allocator.dupe(u8, incoming.data);
        }
    }
    return error.DnsQueryFailed;
}

fn encodeDnsQuery(
    allocator: Allocator,
    transaction_id: u16,
    name: []const u8,
    record_type: u16,
) (Allocator.Error || Error)![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    try bytes.resize(allocator, 12);
    @memset(bytes.items, 0);
    std.mem.writeInt(u16, bytes.items[0..2], transaction_id, .big);
    std.mem.writeInt(u16, bytes.items[2..4], 0x0100, .big); // recursion desired
    std.mem.writeInt(u16, bytes.items[4..6], 1, .big); // one question

    var labels = std.mem.splitScalar(u8, name, '.');
    var saw_label = false;
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return error.InvalidSrvHost;
        saw_label = true;
        try bytes.append(allocator, @intCast(label.len));
        try bytes.appendSlice(allocator, label);
    }
    if (!saw_label) return error.InvalidSrvHost;
    try bytes.append(allocator, 0);

    var tail: [4]u8 = undefined;
    std.mem.writeInt(u16, tail[0..2], record_type, .big);
    std.mem.writeInt(u16, tail[2..4], dns_class_in, .big);
    try bytes.appendSlice(allocator, &tail);
    return bytes.toOwnedSlice(allocator);
}

fn parseSrvResponse(allocator: Allocator, packet: []const u8) (Allocator.Error || Error)![]SrvRecord {
    var response = net.HostName.DnsResponse.init(packet) catch
        return error.InvalidDnsResponse;
    var records: std.ArrayList(SrvRecord) = .empty;
    errdefer {
        for (records.items) |record| record.deinit(allocator);
        records.deinit(allocator);
    }

    while (response.next() catch return error.InvalidDnsResponse) |answer| {
        if (@intFromEnum(answer.rr) != dns_type_srv) continue;
        if (answer.data_len < 7) return error.InvalidDnsResponse;
        const data_off: usize = answer.data_off;
        const data_end = data_off + answer.data_len;
        if (data_end > packet.len) return error.InvalidDnsResponse;

        const port = std.mem.readInt(u16, packet[data_off + 4 .. data_off + 6], .big);
        if (port == 0) return error.InvalidSrvPort;
        var name_buffer: [net.HostName.max_len]u8 = undefined;
        const expanded = net.HostName.expand(packet, data_off + 6, &name_buffer) catch
            return error.InvalidDnsResponse;
        const target = expanded[1].bytes;
        if (target.len == 0) return error.InvalidSrvTarget;

        try records.append(allocator, .{
            .host = try allocator.dupe(u8, target),
            .port = port,
        });
    }

    if (records.items.len == 0) return error.NoSrvRecords;
    return records.toOwnedSlice(allocator);
}

fn parseTxtResponse(allocator: Allocator, packet: []const u8) (Allocator.Error || Error)!?[]u8 {
    var response = net.HostName.DnsResponse.init(packet) catch
        return error.InvalidDnsResponse;
    var txt: std.ArrayList(u8) = .empty;
    errdefer txt.deinit(allocator);
    var records: usize = 0;

    while (response.next() catch return error.InvalidDnsResponse) |answer| {
        if (@intFromEnum(answer.rr) != dns_type_txt) continue;
        records += 1;
        if (records > 1) return error.MultipleTxtRecords;

        var offset: usize = answer.data_off;
        const end = offset + answer.data_len;
        if (end > packet.len) return error.InvalidDnsResponse;
        while (offset < end) {
            const len: usize = packet[offset];
            offset += 1;
            if (offset + len > end) return error.InvalidTxtRecord;
            try txt.appendSlice(allocator, packet[offset .. offset + len]);
            offset += len;
        }
    }

    if (records == 0) {
        txt.deinit(allocator);
        return null;
    }
    try validateTxtOptions(txt.items);
    return try txt.toOwnedSlice(allocator);
}

fn validateTxtOptions(txt: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, txt, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) return error.InvalidTxtRecord;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse
            return error.InvalidTxtRecord;
        const name = pair[0..eq];
        if (!(std.ascii.eqlIgnoreCase(name, "authSource") or
            std.ascii.eqlIgnoreCase(name, "replicaSet") or
            std.ascii.eqlIgnoreCase(name, "loadBalanced")))
        {
            return error.InvalidTxtOption;
        }
    }
}

fn synthesizeConnectionString(
    allocator: Allocator,
    parsed: SrvUri,
    records: []const SrvRecord,
    txt: ?[]const u8,
) (Allocator.Error || Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "mongodb://");
    if (parsed.userinfo) |userinfo| {
        try out.appendSlice(allocator, userinfo);
        try out.append(allocator, '@');
    }
    for (records, 0..) |record, i| {
        if (i != 0) try out.append(allocator, ',');
        const host = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ record.host, record.port });
        defer allocator.free(host);
        try out.appendSlice(allocator, host);
    }

    if (parsed.had_slash) {
        try out.append(allocator, '/');
        if (parsed.database) |database| try out.appendSlice(allocator, database);
    }

    var has_any_option = false;
    var explicit_tls = false;
    var explicit_names: std.ArrayList([]const u8) = .empty;
    defer explicit_names.deinit(allocator);

    if (parsed.query) |query| {
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=');
            const name = if (eq) |i| pair[0..i] else pair;
            if (std.ascii.eqlIgnoreCase(name, "srvServiceName") or
                std.ascii.eqlIgnoreCase(name, "srvMaxHosts"))
            {
                continue;
            }
            try explicit_names.append(allocator, name);
            if (std.ascii.eqlIgnoreCase(name, "tls") or
                std.ascii.eqlIgnoreCase(name, "ssl"))
            {
                explicit_tls = true;
            }
            try appendQueryPair(allocator, &out, &has_any_option, pair);
        }
    }

    if (txt) |txt_options| {
        var it = std.mem.splitScalar(u8, txt_options, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse
                return error.InvalidTxtRecord;
            const name = pair[0..eq];
            if (containsOptionName(explicit_names.items, name)) continue;
            try appendQueryPair(allocator, &out, &has_any_option, pair);
        }
    }

    if (!explicit_tls) {
        try appendQueryPair(allocator, &out, &has_any_option, "tls=true");
    }

    return out.toOwnedSlice(allocator);
}

fn appendQueryPair(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    has_any: *bool,
    pair: []const u8,
) Allocator.Error!void {
    try out.append(allocator, if (has_any.*) '&' else '?');
    try out.appendSlice(allocator, pair);
    has_any.* = true;
}

fn containsOptionName(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, needle)) return true;
    }
    return false;
}

fn shuffle(io: Io, records: []SrvRecord) void {
    if (records.len < 2) return;
    var i = records.len - 1;
    while (i > 0) : (i -= 1) {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        const random = std.mem.readInt(u64, &random_bytes, .little);
        const j: usize = @intCast(random % (i + 1));
        std.mem.swap(SrvRecord, &records[i], &records[j]);
    }
}

fn labelCount(host: []const u8) usize {
    if (host.len == 0) return 0;
    var count: usize = 1;
    for (host) |byte| if (byte == '.') count += 1;
    return count;
}

fn validServiceName(value: []const u8) bool {
    if (value.len == 0 or value.len > 62) return false;
    if (!std.ascii.isAlphanumeric(value[0]) or
        !std.ascii.isAlphanumeric(value[value.len - 1]))
    {
        return false;
    }
    var saw_letter = false;
    for (value) |byte| {
        if (std.ascii.isAlphabetic(byte)) saw_letter = true else if
            (!std.ascii.isDigit(byte) and byte != '-') return false;
    }
    return saw_letter;
}

fn decodeComponent(allocator: Allocator, raw: []const u8) (Allocator.Error || Error)![]u8 {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '%') {
            try decoded.append(allocator, raw[i]);
            i += 1;
            continue;
        }
        if (i + 2 >= raw.len) return error.InvalidPercentEncoding;
        const high = hex(raw[i + 1]) orelse return error.InvalidPercentEncoding;
        const low = hex(raw[i + 2]) orelse return error.InvalidPercentEncoding;
        try decoded.append(allocator, (high << 4) | low);
        i += 3;
    }
    if (!std.unicode.utf8ValidateSlice(decoded.items)) return error.InvalidUtf8;
    return decoded.toOwnedSlice(allocator);
}

fn hex(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test "SRV parent-domain validation" {
    try std.testing.expect(validTarget("server.mongodb.com", "db1.mongodb.com"));
    try std.testing.expect(!validTarget("server.mongodb.com", "db1.evil.com"));
    try std.testing.expect(validTarget("mongodb.local", "db.mongodb.local"));
    try std.testing.expect(!validTarget("mongodb.local", "mongodb.local"));
    try std.testing.expect(validTarget("a.b.example.com", "example.com"));
}

test "SRV URI rejects multiple hosts and ports before DNS" {
    try std.testing.expectError(
        error.MultipleHosts,
        parseSrvUri(std.testing.allocator, "mongodb+srv://a.example,b.example"),
    );
    try std.testing.expectError(
        error.PortNotAllowed,
        parseSrvUri(std.testing.allocator, "mongodb+srv://a.example:27017"),
    );
}

test "SRV synthesis merges TXT defaults and enables TLS" {
    var parsed = try parseSrvUri(
        std.testing.allocator,
        "mongodb+srv://alice:secret@cluster.example/app?authSource=explicit&srvMaxHosts=2",
    );
    defer parsed.deinit(std.testing.allocator);

    var records = [_]SrvRecord{
        .{ .host = @constCast("db1.example"), .port = 27017 },
        .{ .host = @constCast("db2.example"), .port = 27018 },
    };
    const result = try synthesizeConnectionString(
        std.testing.allocator,
        parsed,
        &records,
        "authSource=txt&replicaSet=rs0",
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        "mongodb://alice:secret@db1.example:27017,db2.example:27018/app?authSource=explicit&replicaSet=rs0&tls=true",
        result,
    );
}

test "TXT records accept only SRV defaults" {
    try validateTxtOptions("authSource=admin&replicaSet=rs0&loadBalanced=false");
    try std.testing.expectError(
        error.InvalidTxtOption,
        validateTxtOptions("tls=false"),
    );
}

test "DNS query encodes SRV qname and type" {
    const packet = try encodeDnsQuery(
        std.testing.allocator,
        0x1234,
        "_mongodb._tcp.example.com",
        dns_type_srv,
    );
    defer std.testing.allocator.free(packet);
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, packet[0..2], .big));
    try std.testing.expectEqual(@as(u16, dns_type_srv), std.mem.readInt(u16, packet[packet.len - 4 .. packet.len - 2], .big));
    try std.testing.expectEqual(@as(u16, dns_class_in), std.mem.readInt(u16, packet[packet.len - 2 ..], .big));
}
