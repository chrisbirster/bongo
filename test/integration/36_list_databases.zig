const std = @import("std");
const bongo = @import("bongo");

test "36 - listDatabases enumerates filtered name-only database metadata" {
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

    const database_name = "bongo_list_databases_test";
    try dropDatabaseRaw(&client, allocator, database_name, 4000);

    const probe = client.database(database_name).collection("probe");
    _ = try probe.insertOne(.{ .name = "Bongo" });

    var result = try bongo.listDatabases(
        &client,
        .{
            .filter = .{ .name = database_name },
            .nameOnly = true,
        },
    );

    const document = (try result.next()) orelse
        return error.DatabaseNotFound;
    try std.testing.expectEqualStrings(
        database_name,
        (try bongo.bson.Reader.get(document, "name")).?.string,
    );
    try std.testing.expect(
        (try bongo.bson.Reader.get(document, "sizeOnDisk")) == null,
    );
    try std.testing.expect((try result.next()) == null);
    result.deinit();

    try dropDatabaseRaw(&client, allocator, database_name, 4001);
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

    const message = try bongo.mongo.op_msg.decode(response);
    if (message.header.response_to != request_id) return error.UnexpectedResponse;

    const body = try message.body();
    const ok = (try bongo.bson.Reader.get(body, "ok")) orelse
        return error.CommandFailed;
    if (!commandSucceeded(ok)) return error.CommandFailed;
}

fn commandSucceeded(value: bongo.bson.Value) bool {
    return switch (value) {
        .double => |number| number == 1.0,
        .int32 => |number| number == 1,
        .int64 => |number| number == 1,
        else => false,
    };
}
