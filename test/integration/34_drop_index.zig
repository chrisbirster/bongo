const std = @import("std");
const bongo = @import("bongo");

test "34 - dropIndex removes a named index and surfaces missing-index errors" {
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

    const database = client.database("bongo_drop_index_test");
    const users = database.collection("users");
    bongo.dropCollection(users) catch {};
    try bongo.createCollection(database, "users", .{});

    _ = try bongo.createIndex(
        users,
        .{ .email = @as(i32, 1) },
        "email_unique",
        .{ .unique = true },
    );

    _ = try users.insertOne(.{ .email = "bongo@example.com" });
    try std.testing.expectError(
        error.WriteFailed,
        users.insertOne(.{ .email = "bongo@example.com" }),
    );

    try bongo.dropIndex(users, "email_unique");

    _ = try users.insertOne(.{ .email = "bongo@example.com" });

    try std.testing.expectError(
        error.CommandFailed,
        bongo.dropIndex(users, "email_unique"),
    );

    _ = try bongo.createIndex(
        users,
        .{ .name = @as(i32, 1) },
        "name_1",
        .{},
    );
    _ = try bongo.createIndex(
        users,
        .{ .score = @as(i32, 1) },
        "score_1",
        .{},
    );

    try bongo.dropIndex(users, "*");
    try std.testing.expectError(
        error.CommandFailed,
        bongo.dropIndex(users, "name_1"),
    );

    try bongo.dropCollection(users);
}
