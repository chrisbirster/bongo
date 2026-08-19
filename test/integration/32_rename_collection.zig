const std = @import("std");
const bongo = @import("bongo");

test "32 - renameCollection moves collection and preserves documents" {
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

    const database = client.database("bongo_rename_collection_test");
    const old_collection = database.collection("old_name");
    const new_collection = database.collection("new_name");

    bongo.dropCollection(old_collection) catch {};
    bongo.dropCollection(new_collection) catch {};

    try bongo.createCollection(database, "old_name", .{});
    _ = try old_collection.insertOne(.{
        ._id = "rename-me",
        .name = "Bongo",
    });

    try bongo.renameCollection(old_collection, "new_name", false);

    var document = (try new_collection.findOne(.{ ._id = "rename-me" })).?;
    defer document.deinit();
    try std.testing.expectEqualStrings(
        "Bongo",
        (try bongo.bson.Reader.get(document.bytes, "name")).?.string,
    );

    var old_cursor = try bongo.listCollections(
        database,
        .{ .filter = .{ .name = "old_name" }, .nameOnly = true },
    );
    defer old_cursor.deinit();
    try std.testing.expect((try old_cursor.next()) == null);

    var new_cursor = try bongo.listCollections(
        database,
        .{ .filter = .{ .name = "new_name" }, .nameOnly = true },
    );
    defer new_cursor.deinit();
    try std.testing.expect((try new_cursor.next()) != null);

    try bongo.dropCollection(new_collection);
}
