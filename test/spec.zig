const std = @import("std");
\ntest "pinned upstream retryable read fixture is executable input" {\n    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, upstream_retryable_reads, .{});\n    defer parsed.deinit();\n    const root = parsed.value.object;\n    try std.testing.expectEqualStrings("find-serverErrors", root.get("description").?.string);\n    const tests = root.get("tests").?.array.items;\n    var found_shutdown = false;\n    var found_not_primary = false;\n    for (tests) |case| {\n        const description = case.object.get("description").?.string;\n        if (std.mem.indexOf(u8, description, "ShutdownInProgress") != null) found_shutdown = true;\n        if (std.mem.indexOf(u8, description, "NotWritablePrimary") != null) found_not_primary = true;\n    }\n    try std.testing.expect(found_shutdown);\n    try std.testing.expect(found_not_primary);\n}\n\ntest "pinned upstream retryable write fixture is executable input" {\n    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, upstream_retryable_writes, .{});\n    defer parsed.deinit();\n    const root = parsed.value.object;\n    try std.testing.expectEqualStrings("insertOne", root.get("description").?.string);\n    try std.testing.expect(root.get("tests").?.array.items.len > 0);\n}\nconst bongo = @import("bongo");

const upstream_retryable_reads = @embedFile("spec-fixtures/retryable-reads/find-serverErrors.json");
const upstream_retryable_writes = @embedFile("spec-fixtures/retryable-writes/insertOne.json");

const Disposition = enum {
    supported,
    local_bridge,
    deferred,
};

const Suite = struct {
    name: []const u8,
    disposition: Disposition,
    reason: ?[]const u8 = null,
};

/// The early harness distinguishes upstream-backed coverage from deterministic
/// Bongo bridge coverage. Moving a suite to `local_bridge` means its 0.5
/// behavior is actively gated; it does not claim that every upstream MongoDB
/// fixture has been ingested yet.
const suites = [_]Suite{
    .{ .name = "connection-string", .disposition = .supported },
    .{ .name = "crud", .disposition = .supported },
    .{ .name = "sessions", .disposition = .supported },
    .{ .name = "transactions", .disposition = .supported },
    .{
        .name = "cmap",
        .disposition = .local_bridge,
        .reason = "CMAP generation, sizing, wait-queue and monitoring are gated locally; upstream fixture ingestion remains incremental",
    },
    .{
        .name = "sdam",
        .disposition = .local_bridge,
        .reason = "SDAM discovery, selection, RTT window and failover are gated locally; full upstream fixture ingestion remains incremental",
    },
};

fn dispositionCount(disposition: Disposition) usize {
    var count: usize = 0;
    for (suites) |suite| {
        if (suite.disposition == disposition) count += 1;
    }
    return count;
}

test "spec harness reports upstream and local bridge coverage explicitly" {
    try std.testing.expectEqual(@as(usize, 6), suites.len);
    try std.testing.expectEqual(@as(usize, 4), dispositionCount(.supported));
    try std.testing.expectEqual(@as(usize, 2), dispositionCount(.local_bridge));
    try std.testing.expectEqual(@as(usize, 0), dispositionCount(.deferred));
    for (suites) |suite| {
        if (suite.disposition != .supported) {
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

test "CMAP bridge clears generations and pauses before ready" {
    var pool = try bongo.mongo.Pool.init(std.testing.io, std.testing.allocator, 2);
    defer pool.deinit();
    try pool.ready();

    const first_generation = pool.generationSnapshot();
    const permit = try pool.tryStartCreate();
    try pool.finishCreate(permit);
    pool.noteDiscarded();

    try pool.clear();
    const snapshot = pool.stats();
    try std.testing.expectEqual(first_generation +% 1, snapshot.generation);
    try std.testing.expectEqual(.paused, snapshot.state);
    try std.testing.expectError(error.PoolCleared, pool.tryStartCreate());
    try pool.ready();
    try std.testing.expectEqual(.ready, pool.stats().state);
}

test "server-selection bridge validates read preference constraints" {
    const allocator = std.testing.allocator;
    const tag_document = try bongo.bson.encode(allocator, .{ .region = "east" });
    defer allocator.free(tag_document);
    const tags = [_]bongo.ReadPreferenceTagSet{.{ .document = tag_document }};

    try (bongo.ReadPreference{
        .mode = .nearest,
        .tag_sets = &tags,
        .max_staleness_seconds = 120,
    }).validate();
    try std.testing.expectError(
        error.PrimaryWithTagSets,
        (bongo.ReadPreference{
            .mode = .primary,
            .tag_sets = &tags,
        }).validate(),
    );
}

test "RuntimeClient exposes the 0.5 SDAM control surface" {
    try std.testing.expect(@hasDecl(bongo.RuntimeClient, "refreshTopology"));
    try std.testing.expect(@hasDecl(bongo.RuntimeClient, "topologyType"));
    try std.testing.expect(@hasDecl(bongo.RuntimeClient, "discoveredServerCount"));
    try std.testing.expect(@hasDecl(bongo.RuntimeClient, "findWithReadPreference"));
}
