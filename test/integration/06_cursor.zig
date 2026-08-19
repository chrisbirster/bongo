const std = @import("std");
const bongo = @import("bongo");

const document_count = 150;
const database_name = "bongo_cursor_test";
const collection_name = "items";

test "06 - cursor fetches multiple batches and closes cleanly" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fixture_connection = try bongo.mongo.Connection.connect(
        io,
        "127.0.0.1",
        27017,
    );
    defer fixture_connection.deinit();

    try bongo.mongo.authenticate(
        &fixture_connection,
        allocator,
        "admin",
        "admin",
        "secretpassword",
    );

    try dropFixtureCollection(
        &fixture_connection,
        allocator,
        3000,
    );

    const FixtureDocument = struct {
        index: i32,
        group: []const u8,
    };

    var fixture_documents: [document_count]FixtureDocument = undefined;
    for (&fixture_documents, 0..) |*document, index| {
        document.* = .{
            .index = @intCast(index),
            .group = "cursor-test",
        };
    }

    const insert_response = try runRawCommand(
        &fixture_connection,
        allocator,
        3001,
        .{
            .insert = collection_name,
            .documents = fixture_documents,
            .@"$db" = database_name,
        },
    );
    defer allocator.free(insert_response);
    try expectCommandSucceeded(insert_response, 3001);

    var client = try bongo.Client.connect(
        io,
        allocator,
        .{
            .username = "admin",
            .password = "secretpassword",
        },
    );
    defer client.deinit();

    const items = client
        .database(database_name)
        .collection(collection_name);

    var cursor = try items.find(.{ .group = "cursor-test" });
    defer cursor.deinit();

    try std.testing.expect(cursor.id() != 0);
    try std.testing.expectEqualStrings(
        "bongo_cursor_test.items",
        cursor.namespace(),
    );

    var seen = [_]bool{false} ** document_count;
    var count: usize = 0;

    while (try cursor.next()) |document| {
        const index_value = (try bongo.bson.Reader.get(
            document,
            "index",
        )) orelse return error.MissingFixtureIndex;

        const index = switch (index_value) {
            .int32 => |value| value,
            else => return error.InvalidFixtureIndex,
        };

        if (index < 0 or index >= document_count) {
            return error.InvalidFixtureIndex;
        }

        const position: usize = @intCast(index);
        try std.testing.expect(!seen[position]);
        seen[position] = true;
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, document_count), count);
    try std.testing.expectEqual(@as(i64, 0), cursor.id());

    var early_close = try items.find(.{ .group = "cursor-test" });
    defer early_close.deinit();

    try std.testing.expect(early_close.id() != 0);
    try early_close.close();
    try std.testing.expectEqual(@as(i64, 0), early_close.id());

    try dropFixtureCollection(
        &fixture_connection,
        allocator,
        3002,
    );
}

fn runRawCommand(
    connection: *bongo.mongo.Connection,
    allocator: std.mem.Allocator,
    request_id: i32,
    command: anytype,
) ![]u8 {
    const request = try bongo.mongo.op_msg.encodeCommand(
        allocator,
        command,
        .{ .request_id = request_id },
    );
    defer allocator.free(request);

    return connection.request(allocator, request);
}

fn expectCommandSucceeded(
    response: []const u8,
    expected_response_to: i32,
) !void {
    const message = try bongo.mongo.op_msg.decode(response);
    try std.testing.expectEqual(
        expected_response_to,
        message.header.response_to,
    );

    const body = try message.body();
    const ok = (try bongo.bson.Reader.get(body, "ok")) orelse
        return error.MissingOk;

    const succeeded = switch (ok) {
        .double => |value| value == 1.0,
        .int32 => |value| value == 1,
        .int64 => |value| value == 1,
        else => false,
    };

    try std.testing.expect(succeeded);
}

fn dropFixtureCollection(
    connection: *bongo.mongo.Connection,
    allocator: std.mem.Allocator,
    request_id: i32,
) !void {
    const response = try runRawCommand(
        connection,
        allocator,
        request_id,
        .{
            .drop = collection_name,
            .@"$db" = database_name,
        },
    );
    defer allocator.free(response);

    // NamespaceNotFound is harmless when preparing a clean fixture. The OP_MSG
    // response itself is still decoded to ensure the exchange was well formed.
    const message = try bongo.mongo.op_msg.decode(response);
    try std.testing.expectEqual(
        request_id,
        message.header.response_to,
    );
}
