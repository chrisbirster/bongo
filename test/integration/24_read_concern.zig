const std = @import("std");
const bongo = @import("bongo");

test "24 - configured local read concern applies to reads" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try bongo.Client.connect(
        io,
        allocator,
        .{
            .username = "admin",
            .password = "secretpassword",
            .read_concern = .{ .level = .local },
        },
    );
    defer client.deinit();

    const users = client.database("test").collection("bongo_read_concern");
    _ = try users.deleteMany(.{});
    _ = try users.insertOne(.{
        ._id = "read-concern",
        .category = "cat",
    });

    var document = (try users.findOne(.{ ._id = "read-concern" })).?;
    defer document.deinit();
    try std.testing.expectEqualStrings(
        "cat",
        (try bongo.bson.Reader.get(document.bytes, "category")).?.string,
    );

    try std.testing.expectEqual(
        @as(i64, 1),
        try users.countDocuments(.{ .category = "cat" }, .{}),
    );

    var distinct = try users.distinct("category", .{});
    defer distinct.deinit();
    try std.testing.expectEqualStrings(
        "cat",
        (try distinct.next()).?.string,
    );

    _ = try users.deleteMany(.{});
}
