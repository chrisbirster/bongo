const std = @import("std");
const bongo = @import("bongo");

test "43 - pool clear invalidates checked-out generation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const database = "bongo_cmap";
    const collection = "cards";

    var client = try bongo.RuntimeClient.connectUri(
        io,
        allocator,
        "mongodb://localhost:27019/bongo_cmap?replicaSet=rs0",
        .{ .max_pool_size = 1 },
    );
    defer client.deinit();

    _ = try client.deleteOne(database, collection, .{ ._id = @as(i64, 63001) });
    _ = try client.deleteOne(database, collection, .{ ._id = @as(i64, 63002) });

    var transaction = try client.beginTransaction(.{});
    _ = try transaction.insertOne(database, collection, .{
        ._id = @as(i64, 63001),
        .value = @as(i32, 1),
    });

    const before_clear = client.pool.stats();
    try std.testing.expectEqual(@as(usize, 1), before_clear.total);
    try std.testing.expectEqual(@as(usize, 1), before_clear.checked_out);
    try std.testing.expectEqual(@as(usize, 0), before_clear.idle);

    try client.pool.clear();
    const after_clear = client.pool.stats();
    try std.testing.expectEqual(@as(u64, before_clear.generation +% 1), after_clear.generation);
    try std.testing.expectEqual(.paused, after_clear.state);
    try std.testing.expectEqual(@as(usize, 1), after_clear.total);
    try std.testing.expectEqual(@as(usize, 1), after_clear.checked_out);
    try std.testing.expectEqual(@as(usize, 0), after_clear.idle);

    // Returning the old-generation transaction connection must destroy it,
    // not make it available to the next checkout.
    transaction.deinit();
    const after_stale_return = client.pool.stats();
    try std.testing.expectEqual(@as(usize, 0), after_stale_return.total);
    try std.testing.expectEqual(@as(usize, 0), after_stale_return.checked_out);
    try std.testing.expectEqual(@as(usize, 0), after_stale_return.idle);

    // SDAM owns this transition in the production path. The focused CMAP test
    // drives it directly so a fresh generation can service the next checkout.
    try client.pool.ready();
    _ = try client.insertOne(database, collection, .{
        ._id = @as(i64, 63002),
        .value = @as(i32, 2),
    });
    const after_fresh_operation = client.pool.stats();
    try std.testing.expectEqual(after_clear.generation, after_fresh_operation.generation);
    try std.testing.expectEqual(@as(usize, 1), after_fresh_operation.total);
    try std.testing.expectEqual(@as(usize, 0), after_fresh_operation.checked_out);
    try std.testing.expectEqual(@as(usize, 1), after_fresh_operation.idle);

    _ = try client.deleteOne(database, collection, .{ ._id = @as(i64, 63001) });
    _ = try client.deleteOne(database, collection, .{ ._id = @as(i64, 63002) });
}

test "43 - minPoolSize is established during RuntimeClient connect" {
    var client = try bongo.RuntimeClient.connectUri(
        std.testing.io,
        std.testing.allocator,
        "mongodb://localhost:27019/bongo_cmap_min?replicaSet=rs0",
        .{
            .min_pool_size = 3,
            .max_pool_size = 3,
            .max_connecting = 2,
        },
    );
    defer client.deinit();

    const snapshot = client.pool.stats();
    try std.testing.expectEqual(.ready, snapshot.state);
    try std.testing.expectEqual(@as(usize, 3), snapshot.min_size);
    try std.testing.expectEqual(@as(usize, 3), snapshot.max_size);
    try std.testing.expectEqual(@as(usize, 3), snapshot.total);
    try std.testing.expectEqual(@as(usize, 3), snapshot.idle);
    try std.testing.expectEqual(@as(usize, 0), snapshot.checked_out);
    try std.testing.expectEqual(@as(usize, 0), snapshot.connecting);
}

test "43 - maxPoolSize zero is unlimited" {
    var client = try bongo.RuntimeClient.connectUri(
        std.testing.io,
        std.testing.allocator,
        "mongodb://localhost:27019/bongo_cmap_unlimited?replicaSet=rs0",
        .{ .max_pool_size = 0 },
    );
    defer client.deinit();

    var first = try client.beginTransaction(.{});
    defer first.deinit();
    var second = try client.beginTransaction(.{});
    defer second.deinit();
    var third = try client.beginTransaction(.{});
    defer third.deinit();

    const snapshot = client.pool.stats();
    try std.testing.expectEqual(@as(usize, 0), snapshot.max_size);
    try std.testing.expectEqual(@as(usize, 3), snapshot.total);
    try std.testing.expectEqual(@as(usize, 3), snapshot.checked_out);
}
