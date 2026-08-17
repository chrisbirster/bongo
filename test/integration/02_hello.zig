const std = @import("std");
const bongo = @import("bongo");

test "02 - send MongoDB hello command" {
    const allocator =
        std.testing.allocator;

    const io =
        std.testing.io;

    var connection =
        try bongo.mongo.Connection.connect(
            io,
            "127.0.0.1",
            27017,
        );

    defer connection.deinit();

    // ---------------------------------------------------------
    // 1. Create:
    //
    // {
    //     hello: 1,
    //     $db: "admin"
    // }
    //
    // Then:
    //
    // Zig struct
    //   ↓
    // BSON
    //   ↓
    // OP_MSG
    // ---------------------------------------------------------

    const request =
        try bongo.mongo.op_msg.encodeCommand(
            allocator,
            .{
                .hello = @as(i32, 1),
                .@"$db" = "admin",
            },
            .{
                .request_id = 1,
            },
        );

    defer allocator.free(request);

    // ---------------------------------------------------------
    // 2. Send OP_MSG over TCP.
    //
    // Then wait for one complete MongoDB response.
    // ---------------------------------------------------------

    const response =
        try connection.request(
            allocator,
            request,
        );

    defer allocator.free(response);

    // ---------------------------------------------------------
    // 3. Decode MongoDB's OP_MSG response.
    // ---------------------------------------------------------

    const message =
        try bongo.mongo.op_msg.decode(
            response,
        );

    // MongoDB should be responding to request 1.
    try std.testing.expectEqual(
        @as(i32, 1),
        message.header.response_to,
    );

    // ---------------------------------------------------------
    // 4. Extract the BSON document from OP_MSG.
    // ---------------------------------------------------------

    const body =
        try message.body();

    // ---------------------------------------------------------
    // 5. Read:
    //
    // {
    //     ...
    //     ok: 1.0
    // }
    // ---------------------------------------------------------

    const ok =
        (try bongo.bson.Reader.get(
            body,
            "ok",
        )) orelse {
            return error.MissingOk;
        };

    switch (ok) {
        .double => |value| {
            try std.testing.expectEqual(
                @as(f64, 1.0),
                value,
            );
        },

        else => {
            return error.UnexpectedOkType;
        },
    }

    // ---------------------------------------------------------
    // 6. Verify another value from hello.
    // ---------------------------------------------------------

    const max_message_size =
        (try bongo.bson.Reader.get(
            body,
            "maxMessageSizeBytes",
        )) orelse {
            return error.MissingMaxMessageSize;
        };

    switch (max_message_size) {
        .int32 => |value| {
            try std.testing.expect(
                value > 0,
            );
        },

        else => {
            return error.UnexpectedMaxMessageSizeType;
        },
    }
}
