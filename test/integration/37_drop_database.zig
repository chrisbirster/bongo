const std = @import("std");
const bongo = @import("bongo");

test "37 - dropDatabase removes a database and honors public validation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try bongo.Client.connect(
        io,
        allocator,
        .{
            .username = "admin",
            .password = "secretpassword",
            .write_concern = .{
                .w = .majority,
                .journal = true,
                .wtimeout_ms = 5000,
            },
        },
    );
    defer client.deinit();

    const database_name = "bongo_drop_database_test";
    const database = client.database(database_name);

    var existing = try bongo.listDatabases(
        &client,
        .{
            .filter = .{ .name = database_name },
            .nameOnly = true,
        },
    );
    const already_exists = (try existing.next()) != null;
    existing.deinit();
    if (already_exists) try bongo.dropDatabase(database);

    _ = try database.collection("probe").insertOne(.{ .name = "Bongo" });

    var before = try bongo.listDatabases(
        &client,
        .{
            .filter = .{ .name = database_name },
            .nameOnly = true,
        },
    );
    const before_document = (try before.next()) orelse
        return error.DatabaseWasNotCreated;
    try std.testing.expectEqualStrings(
        database_name,
        (try bongo.bson.Reader.get(before_document, "name")).?.string,
    );
    before.deinit();

    try bongo.dropDatabase(database);

    var after = try bongo.listDatabases(
        &client,
        .{
            .filter = .{ .name = database_name },
            .nameOnly = true,
        },
    );
    defer after.deinit();
    try std.testing.expect((try after.next()) == null);

    try std.testing.expectError(
        error.EmptyDatabase,
        bongo.dropDatabase(client.database("")),
    );
}
