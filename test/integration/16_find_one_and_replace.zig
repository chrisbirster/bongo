const std = @import("std");
const bongo = @import("bongo");

test "16 - findOneAndReplace returns before and after documents" {
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

    const users = client.database("test").collection("users");
    _ = try users.deleteMany(.{ ._id = "bongo-find-one-replace" });

    _ = try users.insertOne(.{
        ._id = "bongo-find-one-replace",
        .name = "Bongo",
        .active = true,
    });

    var before = (try users.findOneAndReplace(
        .{ ._id = "bongo-find-one-replace" },
        .{
            ._id = "bongo-find-one-replace",
            .name = "Mango",
            .stage = @as(i32, 2),
        },
        .{ .return_document = .before },
    )).?;
    defer before.deinit();

    try std.testing.expectEqualStrings(
        "Bongo",
        (try bongo.bson.Reader.get(before.bytes, "name")).?.string,
    );

    var after = (try users.findOneAndReplace(
        .{ ._id = "bongo-find-one-replace" },
        .{
            ._id = "bongo-find-one-replace",
            .name = "Peach",
            .stage = @as(i32, 3),
        },
        .{ .return_document = .after },
    )).?;
    defer after.deinit();

    try std.testing.expectEqualStrings(
        "Peach",
        (try bongo.bson.Reader.get(after.bytes, "name")).?.string,
    );
    try std.testing.expectEqual(
        @as(i32, 3),
        (try bongo.bson.Reader.get(after.bytes, "stage")).?.int32,
    );
    try std.testing.expect(
        (try bongo.bson.Reader.get(after.bytes, "active")) == null,
    );

    try std.testing.expect(
        (try users.findOneAndReplace(
            .{ ._id = "bongo-find-one-replace-missing" },
            .{ .name = "Nobody" },
            .{},
        )) == null,
    );

    _ = try users.deleteOne(.{ ._id = "bongo-find-one-replace" });
}
