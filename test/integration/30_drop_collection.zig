const std = @import("std");
const bongo = @import("bongo");

test "30 - dropCollection removes an explicitly created collection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try bongo.Client.connect(
        io,
        allocator,
        .{
            .username = "admin",
            .password = "secretpassword",
            .write_concern = .{ .w = .majority },
        },
    );
    defer client.deinit();

    const database = client.database("bongo_drop_collection_test");
    const events = database.collection("events");

    bongo.dropCollection(events) catch |err| {
        if (err != error.CommandFailed) return err;
    };

    try bongo.createCollection(database, "events", .{});
    _ = try events.insertOne(.{ .name = "Bongo" });

    try bongo.dropCollection(events);

    var collections = try bongo.listCollections(
        database,
        .{ .filter = .{ .name = "events" } },
    );
    defer collections.deinit();

    try std.testing.expect((try collections.next()) == null);

    // MongoDB treats dropping an already-absent collection as success.
    try bongo.dropCollection(events);
}
