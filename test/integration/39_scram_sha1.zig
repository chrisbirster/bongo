const std = @import("std");
const bongo = @import("bongo");

test "39 - authenticate with SCRAM-SHA-1 and run ping" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var connection = try bongo.mongo.Connection.connect(
        io,
        "127.0.0.1",
        27017,
    );
    defer connection.deinit();

    try bongo.mongo.authenticateSha1(
        &connection,
        allocator,
        "admin",
        "admin",
        "secretpassword",
    );

    const request = try bongo.mongo.op_msg.encodeCommand(
        allocator,
        .{
            .ping = @as(i32, 1),
            .@"$db" = "admin",
        },
        .{ .request_id = 2100 },
    );
    defer allocator.free(request);

    const response = try connection.request(allocator, request);
    defer allocator.free(response);

    const message = try bongo.mongo.op_msg.decode(response);
    try std.testing.expectEqual(@as(i32, 2100), message.header.response_to);

    const body = try message.body();
    const ok = (try bongo.bson.Reader.get(body, "ok")) orelse
        return error.MissingOk;

    switch (ok) {
        .double => |value| try std.testing.expectEqual(@as(f64, 1.0), value),
        .int32 => |value| try std.testing.expectEqual(@as(i32, 1), value),
        .int64 => |value| try std.testing.expectEqual(@as(i64, 1), value),
        else => return error.UnexpectedOkType,
    }
}
