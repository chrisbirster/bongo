const std = @import("std");
const bongo = @import("bongo");

test "09 - deleteOne deletes one matching document" {
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
        .collection("bongo_delete_one");

    _ = try users.deleteOne(.{ ._id = "bongo-0006" });

    _ = try users.insertOne(.{
        ._id = "bongo-0006",
        .name = "Bongo",
    });

    const result = try users.deleteOne(.{ ._id = "bongo-0006" });
    try std.testing.expectEqual(@as(i64, 1), result.deleted_count);

    var cursor = try users.find(.{ ._id = "bongo-0006" });
    defer cursor.deinit();

    try std.testing.expect((try cursor.next()) == null);
}
