const std = @import("std");
const bongo = @import("bongo");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var connection =
        try bongo.mongo.Connection.connect(
            io,
            "127.0.0.1",
            27017,
        );
    defer connection.deinit();

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

    const response =
        try connection.request(
            allocator,
            request,
        );
    defer allocator.free(response);

    const message =
        try bongo.mongo.op_msg.decode(
            response,
        );

    const body = try message.body();

    var reader = try bongo.bson.decode(body);

    while (try reader.next()) |element| {
        std.debug.print(
            "{s}: {s}\n",
            .{
                element.name,
                @tagName(element.value),
            },
        );
    }
}
