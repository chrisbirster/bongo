const std = @import("std");
const bongo = @import("bongo");

test "19 - estimatedDocumentCount returns collection count" {
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

    const users = client
        .database("test")
        .collection("bongo_estimated_count");

    _ = try users.deleteMany(.{});

    const Document = struct { index: i32 };
    const documents = [_]Document{
        .{ .index = 1 },
        .{ .index = 2 },
        .{ .index = 3 },
    };

    _ = try users.insertMany(&documents);

    try std.testing.expectEqual(
        @as(i64, 3),
        try users.estimatedDocumentCount(),
    );

    _ = try users.deleteMany(.{});
}
