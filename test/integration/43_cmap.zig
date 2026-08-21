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
    try std.testing.expectEqual(before_clear.generation +% 1, after_clear.generation);
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
