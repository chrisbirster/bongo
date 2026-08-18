const std = @import("std");
const bongo = @import("bongo");

test "04 - authenticate with SCRAM-SHA-256 and run find" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var connection = try bongo.mongo.Connection.connect(
        io,
        "127.0.0.1",
        27017,
    );
    defer connection.deinit();

    try bongo.mongo.authenticate(
        &connection,
        allocator,
        "admin",
        "admin",
        "secretpassword",
    );

    const request = try bongo.mongo.op_msg.encodeCommand(
        allocator,
        .{
            .find = "users",
            .@"$db" = "test",
        },
        .{
            .request_id = 2000,
        },
    );
    defer allocator.free(request);

    const response = try connection.request(
        allocator,
        request,
    );
    defer allocator.free(response);

    const message = try bongo.mongo.op_msg.decode(response);
    try std.testing.expectEqual(
        @as(i32, 2000),
        message.header.response_to,
    );

    const body = try message.body();
    const ok = (try bongo.bson.Reader.get(body, "ok")) orelse
        return error.MissingOk;

    switch (ok) {
        .double => |value| {
            try std.testing.expectEqual(@as(f64, 1.0), value);
        },
        else => return error.UnexpectedOkType,
    }
}
