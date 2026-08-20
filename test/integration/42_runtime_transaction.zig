const std = @import("std");
const bongo = @import("bongo");

fn expectInt(document: []const u8, field: []const u8, expected: i64) !void {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return error.MissingField;
    const actual: i64 = switch (value) {
        .int32 => |number| number,
        .int64 => |number| number,
        else => return error.InvalidField,
    };
    try std.testing.expectEqual(expected, actual);
}

test "42 - runtime client commits and aborts Deez-shaped transactions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try bongo.RuntimeClient.connectUri(
        io,
        allocator,
        "mongodb://localhost:27019/bongo_deez?replicaSet=rs0",
        .{ .max_pool_size = 2 },
    );
    defer client.deinit();

    try std.testing.expect(client.supports_sessions);
    try std.testing.expect(client.supports_transactions);

    const database = "bongo_deez";
    _ = try client.deleteOne(database, "cards", .{ ._id = @as(i64, 42001) });
    _ = try client.deleteOne(database, "reviews", .{ ._id = @as(i64, 43001) });

    _ = try client.insertOne(database, "cards", .{
        ._id = @as(i64, 42001),
        .deck_id = @as(i64, 7),
        .due_at_ms = @as(i64, 0),
    });

    {
        var transaction = try client.beginTransaction(.{});
        defer transaction.deinit();

        _ = try transaction.insertOne(database, "reviews", .{
            ._id = @as(i64, 43001),
            .card_id = @as(i64, 42001),
            .rating = @as(i32, 3),
            .reviewed_at_ms = @as(i64, 100),
        });

        var update = try transaction.updateOne(
            database,
            "cards",
            .{ ._id = @as(i64, 42001) },
            bongo.query.set(.{ .due_at_ms = @as(i64, 900) }),
            false,
        );
        defer update.deinit();
        try transaction.commit();
    }

    var committed_card = (try client.findOne(
        database,
        "cards",
        .{ ._id = @as(i64, 42001) },
    )).?;
    defer committed_card.deinit();
    try expectInt(committed_card.bytes, "due_at_ms", 900);

    var committed_review = (try client.findOne(
        database,
        "reviews",
        .{ ._id = @as(i64, 43001) },
    )).?;
    defer committed_review.deinit();
    try expectInt(committed_review.bytes, "card_id", 42001);

    {
        var transaction = try client.beginTransaction(.{});
        defer transaction.deinit();
        var update = try transaction.updateOne(
            database,
            "cards",
            .{ ._id = @as(i64, 42001) },
            bongo.query.set(.{ .due_at_ms = @as(i64, 12345) }),
            false,
        );
        defer update.deinit();
        try transaction.abort();
    }

    var aborted_card = (try client.findOne(
        database,
        "cards",
        .{ ._id = @as(i64, 42001) },
    )).?;
    defer aborted_card.deinit();
    try expectInt(aborted_card.bytes, "due_at_ms", 900);

    _ = try client.deleteOne(database, "reviews", .{ ._id = @as(i64, 43001) });
    _ = try client.deleteOne(database, "cards", .{ ._id = @as(i64, 42001) });
}

test "42 - runtime client reselects when remembered host is unreachable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const database = "bongo_failover";

    var client = try bongo.RuntimeClient.connectUri(
        io,
        allocator,
        "mongodb://127.0.0.1:1,localhost:27019/bongo_failover?replicaSet=rs0&connectTimeoutMS=50",
        .{ .max_pool_size = 2 },
    );
    defer client.deinit();

    // connectUri skips the dead first seed and selects localhost:27019. Force
    // the remembered index back to the dead seed so the next newly-created
    // connection must recover by probing the configured seed list again.
    client.selected_host = 0;

    var transaction = try client.beginTransaction(.{});
    defer transaction.deinit();

    _ = try client.deleteOne(database, "failover", .{ ._id = @as(i64, 42002) });
    _ = try client.insertOne(database, "failover", .{
        ._id = @as(i64, 42002),
        .ok = true,
    });

    var found = (try client.findOne(
        database,
        "failover",
        .{ ._id = @as(i64, 42002) },
    )).?;
    defer found.deinit();

    _ = try client.deleteOne(database, "failover", .{ ._id = @as(i64, 42002) });
}
