const std = @import("std");
const bongo = @import("bongo");

const ports = [_]u16{ 27021, 27022, 27023 };

test "44 - discovers replica set and routes secondary reads" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const database = "bongo_sdam";
    const collection = "cards";

    var client = try bongo.RuntimeClient.connectUri(
        io,
        allocator,
        "mongodb://localhost:27021/bongo_sdam?replicaSet=rs0&heartbeatFrequencyMS=500&serverSelectionTimeoutMS=5000&localThresholdMS=15",
        .{},
    );
    defer client.deinit();

    try client.refreshTopology();
    try std.testing.expect(client.topologyType() == .replica_set_with_primary);
    try std.testing.expectEqual(@as(usize, 3), client.discoveredServerCount());

    _ = try client.deleteOne(database, collection, .{ ._id = @as(i64, 64001) });
    _ = try client.insertOne(database, collection, .{
        ._id = @as(i64, 64001),
        .value = @as(i32, 1),
    });

    var found_on_secondary = false;
    for (0..30) |_| {
        var cursor = client.findWithReadPreference(
            database,
            collection,
            .{ ._id = @as(i64, 64001) },
            .{ .limit = @as(i64, 1) },
            .{ .mode = .secondary },
        ) catch {
            sleepMs(io, 100);
            continue;
        };
        defer cursor.deinit();
        if (try cursor.next()) |_| {
            found_on_secondary = true;
            break;
        }
        sleepMs(io, 100);
    }
    try std.testing.expect(found_on_secondary);
    _ = try client.deleteOne(database, collection, .{ ._id = @as(i64, 64001) });
}

test "44 - primary stepdown clears pool and reselects without recreating client" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const database = "bongo_sdam_failover";
    const collection = "cards";

    var client = try bongo.RuntimeClient.connectUri(
        io,
        allocator,
        "mongodb://localhost:27021/bongo_sdam_failover?replicaSet=rs0&heartbeatFrequencyMS=500&serverSelectionTimeoutMS=10000",
        .{ .max_pool_size = 4 },
    );
    defer client.deinit();

    _ = try client.deleteOne(database, collection, .{ ._id = @as(i64, 64002) });
    _ = try client.insertOne(database, collection, .{
        ._id = @as(i64, 64002),
        .value = @as(i32, 1),
    });
    const generation_before = client.pool.stats().generation;
    const old_primary = try findPrimaryPort(io, allocator);

    try stepDown(io, allocator, old_primary);

    var replacement: ?u16 = null;
    for (0..40) |_| {
        client.refreshTopology() catch {};
        const current = findPrimaryPort(io, allocator) catch null;
        if (current) |port| {
            if (port != old_primary) {
                replacement = port;
                break;
            }
        }
        sleepMs(io, 250);
    }
    try std.testing.expect(replacement != null);

    var write_succeeded = false;
    for (0..20) |_| {
        client.refreshTopology() catch {};
        _ = client.updateOne(
            database,
            collection,
            .{ ._id = @as(i64, 64002) },
            .{ .@"$set" = .{ .value = @as(i32, 2) } },
            false,
        ) catch {
            sleepMs(io, 250);
            continue;
        };
        write_succeeded = true;
        break;
    }
    try std.testing.expect(write_succeeded);
    try std.testing.expect(client.pool.stats().generation > generation_before);

    _ = try client.deleteOne(database, collection, .{ ._id = @as(i64, 64002) });
}

fn findPrimaryPort(io: std.Io, allocator: std.mem.Allocator) !u16 {
    for (ports) |port| {
        var connection = bongo.mongo.Connection.connect(io, "localhost", port) catch continue;
        defer connection.deinit();
        const request = try bongo.mongo.op_msg.encodeCommand(
            allocator,
            .{ .hello = @as(i32, 1), .@"$db" = "admin" },
            .{ .request_id = @as(i32, port) },
        );
        defer allocator.free(request);
        const response = connection.request(allocator, request) catch continue;
        defer allocator.free(response);
        const message = bongo.mongo.op_msg.decode(response) catch continue;
        const body = message.body() catch continue;
        const value = (bongo.bson.Reader.get(body, "isWritablePrimary") catch null) orelse continue;
        if (value == .boolean and value.boolean) return port;
    }
    return error.NoPrimary;
}

fn stepDown(io: std.Io, allocator: std.mem.Allocator, port: u16) !void {
    var connection = try bongo.mongo.Connection.connect(io, "localhost", port);
    defer connection.deinit();
    const request = try bongo.mongo.op_msg.encodeCommand(
        allocator,
        .{
            .replSetStepDown = @as(i32, 10),
            .force = true,
            .@"$db" = "admin",
        },
        .{ .request_id = 65000 },
    );
    defer allocator.free(request);
    const response = connection.request(allocator, request) catch return;
    allocator.free(response);
}

fn sleepMs(io: std.Io, milliseconds: i64) void {
    const duration: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(milliseconds),
        .clock = .awake,
    };
    duration.sleep(io) catch {};
}
