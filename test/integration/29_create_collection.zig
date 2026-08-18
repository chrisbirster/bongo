const std = @import("std");
const bongo = @import("bongo");

test "29 - createCollection explicitly creates a collection" {
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

    const database_name = "bongo_create_collection_test";
    try dropDatabaseRaw(&client, allocator, database_name, 3000);

    const database = client.database(database_name);
    try bongo.createCollection(
        database,
        "events",
        .{
            .capped = true,
            .size = @as(i64, 1_048_576),
        },
    );

    try std.testing.expectError(
        error.CommandFailed,
        bongo.createCollection(database, "events", .{}),
    );

    const events = database.collection("events");
    const result = try events.insertOne(.{ .name = "Bongo" });
    try std.testing.expectEqual(@as(i64, 1), result.inserted_count);

    try dropDatabaseRaw(&client, allocator, database_name, 3001);
}

fn dropDatabaseRaw(
    client: *bongo.Client,
    allocator: std.mem.Allocator,
    database_name: []const u8,
    request_id: i32,
) !void {
    const request = try bongo.mongo.op_msg.encodeCommand(
        allocator,
        .{
            .dropDatabase = @as(i32, 1),
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
    defer allocator.free(request);

    const response = try client.connection.request(allocator, request);
    defer allocator.free(response);
}
