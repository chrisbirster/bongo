const std = @import("std");
const bongo = @import("bongo");

test "15 - findOneAndUpdate returns before and after documents" {
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
    _ = try users.deleteMany(.{ ._id = "bongo-find-one-update" });

    _ = try users.insertOne(.{
        ._id = "bongo-find-one-update",
        .name = "Bongo",
        .score = @as(i32, 1),
    });

    var before = (try users.findOneAndUpdate(
        .{ ._id = "bongo-find-one-update" },
        .{ .@"$set" = .{ .score = @as(i32, 2) } },
        .{ .return_document = .before },
    )).?;
    defer before.deinit();

    try std.testing.expectEqual(
        @as(i32, 1),
        (try bongo.bson.Reader.get(before.bytes, "score")).?.int32,
    );

    var after = (try users.findOneAndUpdate(
        .{ ._id = "bongo-find-one-update" },
        .{ .@"$set" = .{ .score = @as(i32, 3) } },
        .{ .return_document = .after },
    )).?;
    defer after.deinit();

    try std.testing.expectEqual(
        @as(i32, 3),
        (try bongo.bson.Reader.get(after.bytes, "score")).?.int32,
    );

    try std.testing.expect(
        (try users.findOneAndUpdate(
            .{ ._id = "bongo-find-one-update-missing" },
            .{ .@"$set" = .{ .score = @as(i32, 4) } },
            .{},
        )) == null,
    );

    _ = try users.deleteOne(.{ ._id = "bongo-find-one-update" });
}
