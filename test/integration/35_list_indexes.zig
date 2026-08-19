const std = @import("std");
const bongo = @import("bongo");

test "35 - listIndexes enumerates index metadata across cursor batches" {
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

    const database = client.database("bongo_list_indexes_test");
    const users = database.collection("users");
    bongo.dropCollection(users) catch {};
    try bongo.createCollection(database, "users", .{});

    _ = try bongo.createIndex(
        users,
        .{ .name = @as(i32, 1) },
        "name_1",
        .{},
    );
    _ = try bongo.createIndex(
        users,
        .{ .score = @as(i32, -1) },
        "score_desc",
        .{},
    );

    var cursor = try bongo.listIndexes(
        users,
        .{ .cursor = .{ .batchSize = @as(i32, 1) } },
    );
    defer cursor.deinit();

    var count: usize = 0;
    var saw_id = false;
    var saw_name = false;
    var saw_score = false;

    while (try cursor.next()) |document| {
        count += 1;
        const name = (try bongo.bson.Reader.get(document, "name")).?.string;

        if (std.mem.eql(u8, name, "_id_")) saw_id = true;
        if (std.mem.eql(u8, name, "name_1")) saw_name = true;
        if (std.mem.eql(u8, name, "score_desc")) saw_score = true;

        try std.testing.expect(
            (try bongo.bson.Reader.get(document, "key")) != null,
        );
    }

    try std.testing.expect(count >= 3);
    try std.testing.expect(saw_id);
    try std.testing.expect(saw_name);
    try std.testing.expect(saw_score);

    try bongo.dropCollection(users);

    try std.testing.expectError(
        error.CommandFailed,
        bongo.listIndexes(users, .{}),
    );
}
