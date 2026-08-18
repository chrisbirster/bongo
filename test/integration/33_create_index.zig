const std = @import("std");
const bongo = @import("bongo");

test "33 - createIndex creates a compound unique index" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try bongo.Client.connect(
        io,
        allocator,
        .{
            .username = "admin",
            .password = "secretpassword",
        },
    );
    defer client.deinit();

    const database = client.database("bongo_create_index_test");
    const users = database.collection("users");
    bongo.dropCollection(users) catch {};
    try bongo.createCollection(database, "users", .{});

    const result = try bongo.createIndex(
        users,
        .{
            .first = @as(i32, 1),
            .last = @as(i32, 1),
        },
        "first_last_unique",
        .{ .unique = true },
    );

    if (result.num_indexes_before) |before| {
        try std.testing.expect(before >= 1);
    }
    if (result.num_indexes_after) |after| {
        try std.testing.expect(after >= 2);
    }

    _ = try users.insertOne(.{
        .first = "Bongo",
        .last = "Cat",
    });
    try std.testing.expectError(
        error.WriteFailed,
        users.insertOne(.{
            .first = "Bongo",
            .last = "Cat",
        }),
    );

    _ = try users.insertOne(.{
        .first = "Bongo",
        .last = "Other",
    });

    try bongo.dropCollection(users);
}
