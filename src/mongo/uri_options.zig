const std = @import("std");

test "retryReads and retryWrites default true and parse explicitly" {
    var defaults = try parse(std.testing.allocator, "mongodb://localhost/app");
    defer defaults.deinit();
    try std.testing.expect(defaults.retry_reads);
    try std.testing.expect(defaults.retry_writes);

    var disabled = try parse(
        std.testing.allocator,
        "mongodb://localhost/app?retryReads=false&retryWrites=false",
    );
    defer disabled.deinit();
    try std.testing.expect(!disabled.retry_reads);
    try std.testing.expect(!disabled.retry_writes);
}
const uri = @import("uri.zig");

const Allocator = std.mem.Allocator;

pub const Error = uri.Error || error{
    InvalidPercentEncoding,
    InvalidUtf8,
    UnescapedUserInfoDelimiter,
    InvalidDatabase,
    InvalidBoolean,
    InvalidInteger,
    DuplicateOption,
    UnsupportedAuthMechanism,
    EmptyAuthSource,
    MissingUsername,
    EmptyUsername,
    MissingPassword,
    PasswordNotAllowed,
    InvalidAuthSource,
    InvalidOptionValue,
    UnsupportedHostType,
    ConflictingTlsOptions,
    IncompatibleOptions,
    SrvOptionRequiresSrv,
};

pub const AuthMechanism = enum {
    scram_sha_1,
    scram_sha_256,
    mongodb_x509,
};

pub const Compressor = enum {
    snappy,
    zlib,
    zstd,
};

pub const Host = struct {
    name: []u8,
    port: u16 = 27017,
};

/// Fully owned, normalized subset of MongoDB URI options used by Bongo's
/// connection layer. Unknown options are ignored as required by the MongoDB
/// connection-string specification.
pub const Options = struct {
    allocator: Allocator,

    username: ?[]u8 = null,
    password: ?[]u8 = null,
    hosts: []Host,
    database: ?[]u8 = null,

    auth_source: ?[]u8 = null,
    auth_mechanism: ?AuthMechanism = null,

    app_name: ?[]u8 = null,
    replica_set: ?[]u8 = null,
    direct_connection: ?bool = null,
    load_balanced: ?bool = null,

    tls: ?bool = null,
    tls_insecure: ?bool = null,
    tls_allow_invalid_certificates: ?bool = null,
    tls_allow_invalid_hostnames: ?bool = null,
    tls_disable_ocsp_endpoint_check: ?bool = null,
    tls_disable_certificate_revocation_check: ?bool = null,
    tls_ca_file: ?[]u8 = null,
    tls_certificate_key_file: ?[]u8 = null,
    tls_certificate_key_file_password: ?[]u8 = null,

    connect_timeout_ms: ?u32 = null,
    socket_timeout_ms: ?u32 = null,
    timeout_ms: ?u64 = null,

    // Retryable reads and writes are enabled by default by the MongoDB driver specs.
    retry_reads: bool = true,
    retry_writes: bool = true,

    // CMAP connection-pool controls. A max_pool_size of zero means unlimited.
    min_pool_size: ?u32 = null,
    max_pool_size: ?u32 = null,
    max_connecting: ?u32 = null,
    max_idle_time_ms: ?u64 = null,

    compressors: []Compressor,

    srv_service_name: ?[]u8 = null,
    srv_max_hosts: ?u32 = null,

    pub fn deinit(self: *Options) void {
        freeOptional(self.allocator, self.username);
        freeOptional(self.allocator, self.password);
        for (self.hosts) |host| self.allocator.free(host.name);
        self.allocator.free(self.hosts);
        freeOptional(self.allocator, self.database);
        freeOptional(self.allocator, self.auth_source);
        freeOptional(self.allocator, self.app_name);
        freeOptional(self.allocator, self.replica_set);
        freeOptional(self.allocator, self.tls_ca_file);
        freeOptional(self.allocator, self.tls_certificate_key_file);
        freeOptional(self.allocator, self.tls_certificate_key_file_password);
        self.allocator.free(self.compressors);
        freeOptional(self.allocator, self.srv_service_name);
        self.* = undefined;
    }
};

const Seen = struct {
    auth_source: bool = false,
    auth_mechanism: bool = false,
    app_name: bool = false,
    replica_set: bool = false,
    direct_connection: bool = false,
    load_balanced: bool = false,
    tls_insecure: bool = false,
    tls_allow_invalid_certificates: bool = false,
    tls_allow_invalid_hostnames: bool = false,
    tls_disable_ocsp_endpoint_check: bool = false,
    tls_disable_certificate_revocation_check: bool = false,
    tls_ca_file: bool = false,
    tls_certificate_key_file: bool = false,
    tls_certificate_key_file_password: bool = false,
    connect_timeout_ms: bool = false,
    socket_timeout_ms: bool = false,
    timeout_ms: bool = false,
    retry_reads: bool = false,
    retry_writes: bool = false,
    min_pool_size: bool = false,
    max_pool_size: bool = false,
    max_connecting: bool = false,
    max_idle_time_ms: bool = false,
    compressors: bool = false,
    srv_service_name: bool = false,
    srv_max_hosts: bool = false,
};

pub fn parse(allocator: Allocator, connection_string: []const u8) (Allocator.Error || Error)!Options {
    var raw = try uri.parse(allocator, connection_string);
    defer raw.deinit();

    const hosts = try allocator.alloc(Host, raw.hosts.len);
    var initialized_hosts: usize = 0;
    var hosts_handed_off = false;
    errdefer if (!hosts_handed_off) {
        for (hosts[0..initialized_hosts]) |host| allocator.free(host.name);
        allocator.free(hosts);
    };

    for (raw.hosts, 0..) |raw_host, index| {
        const decoded = try decodeComponent(allocator, raw_host.name);
        errdefer allocator.free(decoded);

        if (std.mem.indexOfScalar(u8, decoded, '/') != null or
            std.mem.indexOfScalar(u8, decoded, '\\') != null or
            std.mem.endsWith(u8, decoded, ".sock"))
        {
            return error.UnsupportedHostType;
        }

        for (decoded) |*byte| byte.* = std.ascii.toLower(byte.*);

        hosts[index] = .{
            .name = decoded,
            .port = raw_host.port orelse 27017,
        };
        initialized_hosts += 1;
    }

    const compressors = try allocator.alloc(Compressor, 0);
    var compressors_handed_off = false;
    errdefer if (!compressors_handed_off) allocator.free(compressors);

    var result = Options{
        .allocator = allocator,
        .hosts = hosts,
        .compressors = compressors,
    };
    hosts_handed_off = true;
    compressors_handed_off = true;
    errdefer result.deinit();

    if (raw.username) |raw_username| {
        try validateRawUserInfo(raw_username);
        result.username = try decodeComponent(allocator, raw_username);
    }
    if (raw.password) |raw_password| {
        try validateRawUserInfo(raw_password);
        result.password = try decodeComponent(allocator, raw_password);
    }
    if (raw.database) |raw_database| {
        const decoded = try decodeComponent(allocator, raw_database);
        errdefer allocator.free(decoded);
        try validateDatabase(decoded);
        result.database = decoded;
    }

    var seen: Seen = .{};

    for (raw.options) |raw_option| {
        const name = raw_option.name;

        if (optionName(name, "authSource")) {
            try markSeen(&seen.auth_source);
            const decoded = try decodeComponent(allocator, raw_option.value);
            errdefer allocator.free(decoded);
            if (decoded.len == 0) return error.EmptyAuthSource;
            result.auth_source = decoded;
        } else if (optionName(name, "authMechanism")) {
            try markSeen(&seen.auth_mechanism);
            const decoded = try decodeComponent(allocator, raw_option.value);
            defer allocator.free(decoded);
            result.auth_mechanism = try parseAuthMechanism(decoded);
        } else if (optionName(name, "appName")) {
            try markSeen(&seen.app_name);
            result.app_name = try decodeComponent(allocator, raw_option.value);
        } else if (optionName(name, "replicaSet")) {
            try markSeen(&seen.replica_set);
            const decoded = try decodeComponent(allocator, raw_option.value);
            errdefer allocator.free(decoded);
            if (decoded.len == 0) return error.InvalidOptionValue;
            result.replica_set = decoded;
        } else if (optionName(name, "directConnection")) {
            try markSeen(&seen.direct_connection);
            result.direct_connection = try parseBooleanOption(allocator, raw_option.value);
        } else if (optionName(name, "loadBalanced")) {
            try markSeen(&seen.load_balanced);
            result.load_balanced = try parseBooleanOption(allocator, raw_option.value);
        } else if (optionName(name, "tls") or optionName(name, "ssl")) {
            const value = try parseBooleanOption(allocator, raw_option.value);
            if (result.tls) |existing| {
                if (existing != value) return error.ConflictingTlsOptions;
            } else {
                result.tls = value;
            }
        } else if (optionName(name, "tlsInsecure")) {
            try markSeen(&seen.tls_insecure);
            result.tls_insecure = try parseBooleanOption(allocator, raw_option.value);
        } else if (optionName(name, "tlsAllowInvalidCertificates")) {
            try markSeen(&seen.tls_allow_invalid_certificates);
            result.tls_allow_invalid_certificates = try parseBooleanOption(allocator, raw_option.value);
        } else if (optionName(name, "tlsAllowInvalidHostnames")) {
            try markSeen(&seen.tls_allow_invalid_hostnames);
            result.tls_allow_invalid_hostnames = try parseBooleanOption(allocator, raw_option.value);
        } else if (optionName(name, "tlsDisableOCSPEndpointCheck")) {
            try markSeen(&seen.tls_disable_ocsp_endpoint_check);
            result.tls_disable_ocsp_endpoint_check = try parseBooleanOption(allocator, raw_option.value);
        } else if (optionName(name, "tlsDisableCertificateRevocationCheck")) {
            try markSeen(&seen.tls_disable_certificate_revocation_check);
            result.tls_disable_certificate_revocation_check = try parseBooleanOption(allocator, raw_option.value);
        } else if (optionName(name, "tlsCAFile")) {
            try markSeen(&seen.tls_ca_file);
            result.tls_ca_file = try decodeComponent(allocator, raw_option.value);
        } else if (optionName(name, "tlsCertificateKeyFile")) {
            try markSeen(&seen.tls_certificate_key_file);
            result.tls_certificate_key_file = try decodeComponent(allocator, raw_option.value);
        } else if (optionName(name, "tlsCertificateKeyFilePassword")) {
            try markSeen(&seen.tls_certificate_key_file_password);
            result.tls_certificate_key_file_password = try decodeComponent(allocator, raw_option.value);
        } else if (optionName(name, "connectTimeoutMS")) {
            try markSeen(&seen.connect_timeout_ms);
            result.connect_timeout_ms = try parseU32Option(allocator, raw_option.value);
        } else if (optionName(name, "socketTimeoutMS")) {
            try markSeen(&seen.socket_timeout_ms);
            result.socket_timeout_ms = try parseU32Option(allocator, raw_option.value);
        } else if (optionName(name, "timeoutMS")) {
            try markSeen(&seen.timeout_ms);
            result.timeout_ms = try parseU64Option(allocator, raw_option.value);
        } else if (optionName(name, "retryReads")) {
            try markSeen(&seen.retry_reads);
            result.retry_reads = try parseBooleanOption(allocator, raw_option.value);
        } else if (optionName(name, "retryWrites")) {
            try markSeen(&seen.retry_writes);
            result.retry_writes = try parseBooleanOption(allocator, raw_option.value);
        } else if (optionName(name, "minPoolSize")) {
            try markSeen(&seen.min_pool_size);
            result.min_pool_size = try parseU32Option(allocator, raw_option.value);
        } else if (optionName(name, "maxPoolSize")) {
            try markSeen(&seen.max_pool_size);
            result.max_pool_size = try parseU32Option(allocator, raw_option.value);
        } else if (optionName(name, "maxConnecting")) {
            try markSeen(&seen.max_connecting);
            const value = try parseU32Option(allocator, raw_option.value);
            if (value == 0) return error.InvalidOptionValue;
            result.max_connecting = value;
        } else if (optionName(name, "maxIdleTimeMS")) {
            try markSeen(&seen.max_idle_time_ms);
            result.max_idle_time_ms = try parseU64Option(allocator, raw_option.value);
        } else if (optionName(name, "compressors")) {
            try markSeen(&seen.compressors);
            const decoded = try decodeComponent(allocator, raw_option.value);
            defer allocator.free(decoded);
            allocator.free(result.compressors);
            result.compressors = try parseCompressors(allocator, decoded);
        } else if (optionName(name, "srvServiceName")) {
            try markSeen(&seen.srv_service_name);
            result.srv_service_name = try decodeComponent(allocator, raw_option.value);
        } else if (optionName(name, "srvMaxHosts")) {
            try markSeen(&seen.srv_max_hosts);
            result.srv_max_hosts = try parseU32Option(allocator, raw_option.value);
        }
    }

    try validateTlsConflicts(result);
    try validateTopologyOptions(result);
    try validatePoolOptions(result);
    try validateAuthentication(allocator, &result);

    if (result.srv_service_name != null or result.srv_max_hosts != null) {
        return error.SrvOptionRequiresSrv;
    }

    return result;
}

fn validateRawUserInfo(raw: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, raw, '@') != null or
        std.mem.indexOfScalar(u8, raw, ':') != null)
    {
        return error.UnescapedUserInfoDelimiter;
    }
}

fn validateDatabase(database: []const u8) Error!void {
    for (database) |byte| {
        switch (byte) {
            '/', '\\', ' ', '"', '$' => return error.InvalidDatabase,
            else => {},
        }
    }
}

fn validateTlsConflicts(options: Options) Error!void {
    if (options.tls_insecure != null and
        (options.tls_allow_invalid_certificates != null or
            options.tls_allow_invalid_hostnames != null or
            options.tls_disable_ocsp_endpoint_check != null or
            options.tls_disable_certificate_revocation_check != null))
    {
        return error.ConflictingTlsOptions;
    }

    if (options.tls_allow_invalid_certificates != null and
        (options.tls_disable_ocsp_endpoint_check != null or
            options.tls_disable_certificate_revocation_check != null))
    {
        return error.ConflictingTlsOptions;
    }

    if (options.tls_disable_ocsp_endpoint_check != null and
        options.tls_disable_certificate_revocation_check != null)
    {
        return error.ConflictingTlsOptions;
    }
}

fn validateTopologyOptions(options: Options) Error!void {
    if (options.direct_connection == true and options.hosts.len != 1) {
        return error.IncompatibleOptions;
    }

    if (options.load_balanced == true) {
        if (options.hosts.len != 1 or
            options.direct_connection == true or
            options.replica_set != null)
        {
            return error.IncompatibleOptions;
        }
    }
}

fn validatePoolOptions(options: Options) Error!void {
    if (options.max_pool_size) |max_size| {
        if (max_size > 0 and options.min_pool_size != null and
            options.min_pool_size.? > max_size)
        {
            return error.InvalidOptionValue;
        }
    }
}

fn validateAuthentication(allocator: Allocator, options: *Options) (Allocator.Error || Error)!void {
    const userinfo_present = options.username != null or options.password != null;

    if (options.auth_mechanism == .mongodb_x509) {
        if (options.password != null) return error.PasswordNotAllowed;
        if (options.auth_source) |source| {
            if (!std.mem.eql(u8, source, "$external")) return error.InvalidAuthSource;
        } else {
            options.auth_source = try allocator.dupe(u8, "$external");
        }
        return;
    }

    if (options.auth_mechanism != null or userinfo_present) {
        const username = options.username orelse return error.MissingUsername;
        if (username.len == 0) return error.EmptyUsername;
        if (options.password == null) return error.MissingPassword;

        if (options.auth_source == null) {
            if (options.database) |database| {
                options.auth_source = try allocator.dupe(u8, database);
            } else {
                options.auth_source = try allocator.dupe(u8, "admin");
            }
        }
    }
}

fn parseAuthMechanism(value: []const u8) Error!AuthMechanism {
    if (std.mem.eql(u8, value, "SCRAM-SHA-1")) return .scram_sha_1;
    if (std.mem.eql(u8, value, "SCRAM-SHA-256")) return .scram_sha_256;
    if (std.mem.eql(u8, value, "MONGODB-X509")) return .mongodb_x509;
    return error.UnsupportedAuthMechanism;
}

fn parseCompressors(allocator: Allocator, value: []const u8) (Allocator.Error || Error)![]Compressor {
    if (value.len == 0) return allocator.alloc(Compressor, 0);

    var count: usize = 1;
    for (value) |byte| {
        if (byte == ',') count += 1;
    }

    const compressors = try allocator.alloc(Compressor, count);
    errdefer allocator.free(compressors);

    var it = std.mem.splitScalar(u8, value, ',');
    var index: usize = 0;
    while (it.next()) |name| : (index += 1) {
        if (std.mem.eql(u8, name, "snappy")) {
            compressors[index] = .snappy;
        } else if (std.mem.eql(u8, name, "zlib")) {
            compressors[index] = .zlib;
        } else if (std.mem.eql(u8, name, "zstd")) {
            compressors[index] = .zstd;
        } else {
            return error.InvalidOptionValue;
        }
    }

    return compressors;
}

fn parseBooleanOption(allocator: Allocator, raw: []const u8) (Allocator.Error || Error)!bool {
    const decoded = try decodeComponent(allocator, raw);
    defer allocator.free(decoded);
    return parseBoolean(decoded);
}

fn parseU32Option(allocator: Allocator, raw: []const u8) (Allocator.Error || Error)!u32 {
    const decoded = try decodeComponent(allocator, raw);
    defer allocator.free(decoded);
    return parseU32(decoded);
}

fn parseU64Option(allocator: Allocator, raw: []const u8) (Allocator.Error || Error)!u64 {
    const decoded = try decodeComponent(allocator, raw);
    defer allocator.free(decoded);
    return parseU64(decoded);
}

fn parseBoolean(raw: []const u8) Error!bool {
    if (std.ascii.eqlIgnoreCase(raw, "true")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    return error.InvalidBoolean;
}

fn parseU32(raw: []const u8) Error!u32 {
    if (raw.len == 0) return error.InvalidInteger;
    return std.fmt.parseInt(u32, raw, 10) catch error.InvalidInteger;
}

fn parseU64(raw: []const u8) Error!u64 {
    if (raw.len == 0) return error.InvalidInteger;
    return std.fmt.parseInt(u64, raw, 10) catch error.InvalidInteger;
}

fn optionName(actual: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(actual, expected);
}

fn markSeen(seen: *bool) Error!void {
    if (seen.*) return error.DuplicateOption;
    seen.* = true;
}

fn decodeComponent(allocator: Allocator, raw: []const u8) (Allocator.Error || Error)![]u8 {
    var decoded_len = raw.len;
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] == '%') {
            if (index + 2 >= raw.len) return error.InvalidPercentEncoding;
            _ = hexValue(raw[index + 1]) orelse return error.InvalidPercentEncoding;
            _ = hexValue(raw[index + 2]) orelse return error.InvalidPercentEncoding;
            decoded_len -= 2;
            index += 3;
        } else {
            index += 1;
        }
    }

    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);

    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < raw.len) {
        if (raw[read_index] == '%') {
            const high = hexValue(raw[read_index + 1]).?;
            const low = hexValue(raw[read_index + 2]).?;
            decoded[write_index] = (high << 4) | low;
            read_index += 3;
        } else {
            decoded[write_index] = raw[read_index];
            read_index += 1;
        }
        write_index += 1;
    }
    std.debug.assert(write_index == decoded.len);

    if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidUtf8;
    return decoded;
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn freeOptional(allocator: Allocator, value: ?[]u8) void {
    if (value) |bytes| allocator.free(bytes);
}

test "percent decodes credentials database and option values" {
    var options = try parse(
        std.testing.allocator,
        "mongodb://user%40example:p%3Ass@LOCALHOST/my%2Ddb?appName=hello%20world",
    );
    defer options.deinit();

    try std.testing.expectEqualStrings("user@example", options.username.?);
    try std.testing.expectEqualStrings("p:ss", options.password.?);
    try std.testing.expectEqualStrings("localhost", options.hosts[0].name);
    try std.testing.expectEqualStrings("my-db", options.database.?);
    try std.testing.expectEqualStrings("hello world", options.app_name.?);
    try std.testing.expectEqualStrings("my-db", options.auth_source.?);
}

test "typed option values are percent decoded before parsing" {
    var options = try parse(
        std.testing.allocator,
        "mongodb://alice:secret@localhost?tls=%74rue&connectTimeoutMS=%35%30%30%30",
    );
    defer options.deinit();

    try std.testing.expectEqual(true, options.tls.?);
    try std.testing.expectEqual(@as(u32, 5000), options.connect_timeout_ms.?);
}

test "parses booleans integers pool sizing compressors and auth mechanism" {
    var options = try parse(
        std.testing.allocator,
        "mongodb://alice:secret@localhost/admin?authMechanism=SCRAM-SHA-256&tls=true&directConnection=true&connectTimeoutMS=5000&socketTimeoutMS=6000&timeoutMS=7000&minPoolSize=2&maxPoolSize=10&maxConnecting=3&maxIdleTimeMS=8000&compressors=zlib,zstd",
    );
    defer options.deinit();

    try std.testing.expectEqual(AuthMechanism.scram_sha_256, options.auth_mechanism.?);
    try std.testing.expectEqual(true, options.tls.?);
    try std.testing.expectEqual(true, options.direct_connection.?);
    try std.testing.expectEqual(@as(u32, 5000), options.connect_timeout_ms.?);
    try std.testing.expectEqual(@as(u32, 6000), options.socket_timeout_ms.?);
    try std.testing.expectEqual(@as(u64, 7000), options.timeout_ms.?);
    try std.testing.expectEqual(@as(u32, 2), options.min_pool_size.?);
    try std.testing.expectEqual(@as(u32, 10), options.max_pool_size.?);
    try std.testing.expectEqual(@as(u32, 3), options.max_connecting.?);
    try std.testing.expectEqual(@as(u64, 8000), options.max_idle_time_ms.?);
    try std.testing.expectEqualSlices(Compressor, &.{ .zlib, .zstd }, options.compressors);
}

test "pool sizing URI validation follows CMAP bounds" {
    var unlimited = try parse(
        std.testing.allocator,
        "mongodb://localhost?minPoolSize=20&maxPoolSize=0&maxConnecting=2",
    );
    defer unlimited.deinit();
    try std.testing.expectEqual(@as(u32, 0), unlimited.max_pool_size.?);

    try std.testing.expectError(
        error.InvalidOptionValue,
        parse(std.testing.allocator, "mongodb://localhost?minPoolSize=3&maxPoolSize=2"),
    );
    try std.testing.expectError(
        error.InvalidOptionValue,
        parse(std.testing.allocator, "mongodb://localhost?maxConnecting=0"),
    );
}

test "tls and ssl aliases may repeat only with the same value" {
    var options = try parse(
        std.testing.allocator,
        "mongodb://localhost?tls=true&ssl=true",
    );
    defer options.deinit();
    try std.testing.expectEqual(true, options.tls.?);

    try std.testing.expectError(
        error.ConflictingTlsOptions,
        parse(std.testing.allocator, "mongodb://localhost?tls=true&ssl=false"),
    );
}

test "duplicate recognized scalar options are deterministic errors" {
    try std.testing.expectError(
        error.DuplicateOption,
        parse(std.testing.allocator, "mongodb://localhost?connectTimeoutMS=1&connectTimeoutMS=2"),
    );
    try std.testing.expectError(
        error.DuplicateOption,
        parse(std.testing.allocator, "mongodb://localhost?maxPoolSize=1&maxPoolSize=2"),
    );
}

test "topology option conflicts are rejected" {
    try std.testing.expectError(
        error.IncompatibleOptions,
        parse(std.testing.allocator, "mongodb://a,b?directConnection=true"),
    );
    try std.testing.expectError(
        error.IncompatibleOptions,
        parse(std.testing.allocator, "mongodb://a,b?loadBalanced=true"),
    );
    try std.testing.expectError(
        error.IncompatibleOptions,
        parse(std.testing.allocator, "mongodb://a?loadBalanced=true&replicaSet=rs0"),
    );
}

test "authentication options validate required fields and defaults" {
    var scram = try parse(
        std.testing.allocator,
        "mongodb://alice:secret@localhost/app?authMechanism=SCRAM-SHA-1",
    );
    defer scram.deinit();
    try std.testing.expectEqualStrings("app", scram.auth_source.?);

    try std.testing.expectError(
        error.MissingPassword,
        parse(std.testing.allocator, "mongodb://alice@localhost"),
    );

    var x509 = try parse(
        std.testing.allocator,
        "mongodb://localhost?authMechanism=MONGODB-X509",
    );
    defer x509.deinit();
    try std.testing.expectEqualStrings("$external", x509.auth_source.?);

    try std.testing.expectError(
        error.PasswordNotAllowed,
        parse(std.testing.allocator, "mongodb://alice:secret@localhost?authMechanism=MONGODB-X509"),
    );
}

test "invalid percent encoding and database characters fail" {
    try std.testing.expectError(
        error.InvalidPercentEncoding,
        parse(std.testing.allocator, "mongodb://user%ZZ:secret@localhost"),
    );
    try std.testing.expectError(
        error.InvalidDatabase,
        parse(std.testing.allocator, "mongodb://alice:secret@localhost/bad%20db"),
    );
}

test "conflicting insecure TLS options fail during normalization" {
    try std.testing.expectError(
        error.ConflictingTlsOptions,
        parse(std.testing.allocator, "mongodb://localhost?tlsInsecure=false&tlsAllowInvalidCertificates=false"),
    );
}

test "standard mongodb URIs reject SRV-only options" {
    try std.testing.expectError(
        error.SrvOptionRequiresSrv,
        parse(std.testing.allocator, "mongodb://localhost?srvMaxHosts=2"),
    );
}
