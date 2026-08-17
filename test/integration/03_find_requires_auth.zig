const std = @import("std");
const bongo = @import("bongo");

test "03 - find reaches MongoDB but requires authentication" {
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
    // MongoDB command:
    //
    // {
    //     find: "users",
    //     filter: {
    //         name: "John"
    //     },
    //     $db: "test"
    // }
    // ---------------------------------------------------------

    const request =
        try bongo.mongo.op_msg.encodeCommand(
            allocator,
            .{
                .find = "users",

                .filter = .{
                    .name = "John",
                },

                .@"$db" = "test",
            },
            .{
                .request_id = 2,
            },
        );

    defer allocator.free(request);

    // ---------------------------------------------------------
    // Send the command to MongoDB.
    // ---------------------------------------------------------

    const response =
        try connection.request(
            allocator,
            request,
        );

    defer allocator.free(response);

    // ---------------------------------------------------------
    // Decode OP_MSG.
    // ---------------------------------------------------------

    const message =
        try bongo.mongo.op_msg.decode(
            response,
        );

    try std.testing.expectEqual(
        @as(i32, 2),
        message.header.response_to,
    );

    const body =
        try message.body();

    // ---------------------------------------------------------
    // MongoDB should return:
    //
    // {
    //     ok: 0,
    //     errmsg: "... authentication ...",
    //     ...
    // }
    //
    // because Bongo has not authenticated yet.
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
                @as(f64, 0.0),
                value,
            );
        },

        else => {
            return error.UnexpectedOkType;
        },
    }

    // MongoDB should also give us an error message.
    const errmsg =
        (try bongo.bson.Reader.get(
            body,
            "errmsg",
        )) orelse {
            return error.MissingErrorMessage;
        };

    switch (errmsg) {
        .string => |value| {
            try std.testing.expect(
                value.len > 0,
            );
        },

        else => {
            return error.UnexpectedErrorMessageType;
        },
    }
}
