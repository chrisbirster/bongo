const std = @import("std");
const bongo = @import("bongo");

const Disposition = enum {
    supported,
    deferred,
};

const Suite = struct {
    name: []const u8,
    disposition: Disposition,
    reason: ?[]const u8 = null,
};

/// This manifest is deliberately explicit. When upstream MongoDB fixtures are
/// wired into a suite, its disposition moves to `supported`; unsupported
/// suites remain visible instead of silently disappearing from the test run.
const suites = [_]Suite{
    .{ .name = "connection-string", .disposition = .supported },
    .{ .name = "crud", .disposition = .supported },
    .{ .name = "sessions", .disposition = .supported },
    .{ .name = "transactions", .disposition = .supported },
    .{
        .name = "sdam",
        .disposition = .deferred,
        .reason = "full SDAM monitoring is not implemented",
    },
    .{
        .name = "cmap",
        .disposition = .deferred,
        .reason = "CMAP-grade concurrency work is still in progress",
    },
};

fn deferredSuiteCount() usize {
    var count: usize = 0;
    for (suites) |suite| {
        if (suite.disposition == .deferred) count += 1;
    }
    return count;
}

test "spec harness has explicit supported and deferred suite dispositions" {
    try std.testing.expectEqual(@as(usize, 6), suites.len);
    try std.testing.expectEqual(@as(usize, 2), deferredSuiteCount());
    for (suites) |suite| {
        if (suite.disposition == .deferred) {
            try std.testing.expect(suite.reason != null);
        }
    }
}

test "connection-string spec bridge is table driven" {
    const Case = struct {
        uri: []const u8,
        host: []const u8,
        port: u16,
        tls: ?bool,
        database: ?[]const u8,
    };

    const cases = [_]Case{
        .{
            .uri = "mongodb://LOCALHOST/example",
            .host = "localhost",
            .port = 27017,
            .tls = null,
            .database = "example",
        },
        .{
            .uri = "mongodb://db.example:27018/app?tls=true",
            .host = "db.example",
            .port = 27018,
            .tls = true,
            .database = "app",
        },
        .{
            .uri = "mongodb://db.example/?connectTimeoutMS=2500&socketTimeoutMS=5000",
            .host = "db.example",
            .port = 27017,
            .tls = null,
            .database = null,
        },
    };

    for (cases) |case| {
        var options = try bongo.parseConnectionOptions(std.testing.allocator, case.uri);
        defer options.deinit();
        try std.testing.expectEqual(@as(usize, 1), options.hosts.len);
        try std.testing.expectEqualStrings(case.host, options.hosts[0].name);
        try std.testing.expectEqual(case.port, options.hosts[0].port);
        try std.testing.expectEqual(case.tls, options.tls);
        if (case.database) |database| {
            try std.testing.expectEqualStrings(database, options.database.?);
        } else {
            try std.testing.expect(options.database == null);
        }
    }
}

test "spec harness rejects conflicting normalized URI options" {
    try std.testing.expectError(
        error.ConflictingTlsOptions,
        bongo.parseConnectionOptions(
            std.testing.allocator,
            "mongodb://localhost/?tls=true&ssl=false",
        ),
    );
}
