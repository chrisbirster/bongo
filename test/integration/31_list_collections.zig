const std = @import("std");
const bongo = @import("bongo");

test "31 - listCollections returns filtered collection information" {
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

    const database = client.database("bongo_list_collections_test");
    const alpha = database.collection("alpha");
    const beta = database.collection("beta");

    bongo.dropCollection(alpha) catch {};
    bongo.dropCollection(beta) catch {};
    try bongo.createCollection(database, "alpha", .{});
    try bongo.createCollection(database, "beta", .{});

    var cursor = try bongo.listCollections(
        database,
        .{
            .filter = .{ .name = "alpha" },
            .nameOnly = true,
        },
    );
    defer cursor.deinit();

    const document = (try cursor.next()).?;
    try std.testing.expectEqualStrings(
        "alpha",
        (try bongo.bson.Reader.get(document, "name")).?.string,
    );
    try std.testing.expectEqualStrings(
        "collection",
        (try bongo.bson.Reader.get(document, "type")).?.string,
    );
    try std.testing.expect((try cursor.next()) == null);

    try bongo.dropCollection(alpha);
    try bongo.dropCollection(beta);
}
