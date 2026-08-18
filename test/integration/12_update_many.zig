const std = @import("std");
const bongo = @import("bongo");

test "12 - updateMany updates matching documents" {
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
        .collection("bongo_update_many");

    _ = try collection.deleteOne(.{ ._id = "bongo-0009-a" });
    _ = try collection.deleteOne(.{ ._id = "bongo-0009-b" });

    const Document = struct {
        _id: []const u8,
        kind: []const u8,
        status: []const u8,
    };
    const documents = [_]Document{
        .{ ._id = "bongo-0009-a", .kind = "bongo-0009", .status = "before" },
        .{ ._id = "bongo-0009-b", .kind = "bongo-0009", .status = "before" },
    };
    _ = try collection.insertMany(&documents);

    const result = try collection.updateMany(
        .{ .kind = "bongo-0009", .status = "before" },
        .{ .@"$set" = .{ .status = "after" } },
    );

    try std.testing.expectEqual(@as(i64, 2), result.matched_count);
    try std.testing.expectEqual(@as(i64, 2), result.modified_count);

    var cursor = try collection.find(.{
        .kind = "bongo-0009",
        .status = "after",
    });
    defer cursor.deinit();

    var count: usize = 0;
    while (try cursor.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}
