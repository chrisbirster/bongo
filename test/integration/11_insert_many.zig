const std = @import("std");
const bongo = @import("bongo");

test "11 - insertMany inserts multiple documents" {
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
        .collection("bongo_insert_many");

    _ = try users.deleteOne(.{ ._id = "bongo-0008-a" });
    _ = try users.deleteOne(.{ ._id = "bongo-0008-b" });

    const Document = struct {
        _id: []const u8,
        kind: []const u8,
        index: i32,
    };
    const documents = [_]Document{
        .{
            ._id = "bongo-0008-a",
            .kind = "bongo-0008",
            .index = 1,
        },
        .{
            ._id = "bongo-0008-b",
            .kind = "bongo-0008",
            .index = 2,
        },
    };

    const result = try users.insertMany(&documents);
    try std.testing.expectEqual(@as(i64, 2), result.inserted_count);

    var cursor = try users.find(.{ .kind = "bongo-0008" });
    defer cursor.deinit();

    var count: usize = 0;
    while (try cursor.next()) |_| count += 1;

    try std.testing.expectEqual(@as(usize, 2), count);
}
