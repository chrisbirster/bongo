const std = @import("std");
const bongo = @import("bongo");

test "13 - deleteMany deletes every matching document" {
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

    const collection = client
        .database("test")
        .collection("bongo_delete_many");

    _ = try collection.deleteOne(.{ ._id = "bongo-0010-a" });
    _ = try collection.deleteOne(.{ ._id = "bongo-0010-b" });

    const Document = struct {
        _id: []const u8,
        kind: []const u8,
    };
    const documents = [_]Document{
        .{ ._id = "bongo-0010-a", .kind = "bongo-0010" },
        .{ ._id = "bongo-0010-b", .kind = "bongo-0010" },
    };
    _ = try collection.insertMany(&documents);

    const result = try collection.deleteMany(.{ .kind = "bongo-0010" });
    try std.testing.expectEqual(@as(i64, 2), result.deleted_count);

    var cursor = try collection.find(.{ .kind = "bongo-0010" });
    defer cursor.deinit();
    try std.testing.expect((try cursor.next()) == null);
}
