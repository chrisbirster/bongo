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
