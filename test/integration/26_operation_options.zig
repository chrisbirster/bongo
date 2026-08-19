const std = @import("std");
const bongo = @import("bongo");

test "26 - advanced find options execute against MongoDB" {
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

    const users = client.database("test").collection("bongo_operation_options");
    _ = try users.deleteMany(.{});
    _ = try users.insertOne(.{
        ._id = "advanced-options",
        .name = "Bongo",
    });

    var cursor = try bongo.findWithOptions(
        users,
        .{ ._id = "advanced-options" },
        .{
            .collation = .{ .locale = "en", .strength = @as(i32, 2) },
            .hint = "_id_",
            .comment = "bongo integration option test",
            .maxTimeMS = @as(i64, 5000),
            .let = .{ .unused = @as(i32, 1) },
        },
    );
    defer cursor.deinit();

    const document = (try cursor.next()).?;
    try std.testing.expectEqualStrings(
        "Bongo",
        (try bongo.bson.Reader.get(document, "name")).?.string,
    );
    try std.testing.expect((try cursor.next()) == null);

    _ = try users.deleteMany(.{});
}
