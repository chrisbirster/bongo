const std = @import("std");
const bongo = @import("bongo");

test "01 - connect to MongoDB over TCP" {
    const io = std.testing.io;

    var connection =
        try bongo.mongo.Connection.connect(
            io,
            "127.0.0.1",
            27017,
        );

    defer connection.deinit();
}
