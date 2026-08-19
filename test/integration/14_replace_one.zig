const std = @import("std");
const bongo = @import("bongo");

test "14 - replace one matching document" {
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
    _ = try users.deleteMany(.{ ._id = "bongo-replace-one" });

    _ = try users.insertOne(.{
        ._id = "bongo-replace-one",
        .name = "Bongo",
        .active = true,
    });

    const result = try users.replaceOne(
        .{ ._id = "bongo-replace-one" },
        .{
            ._id = "bongo-replace-one",
            .name = "Mango",
            .replaced = true,
        },
    );

    try std.testing.expectEqual(@as(i64, 1), result.matched_count);
    try std.testing.expectEqual(@as(i64, 1), result.modified_count);

    var document = (try users.findOne(.{
        ._id = "bongo-replace-one",
    })).?;
    defer document.deinit();

    try std.testing.expectEqualStrings(
        "Mango",
        (try bongo.bson.Reader.get(document.bytes, "name")).?.string,
    );
    try std.testing.expect(
        (try bongo.bson.Reader.get(document.bytes, "active")) == null,
    );
    try std.testing.expect(
        (try bongo.bson.Reader.get(document.bytes, "replaced")).?.boolean,
    );

    _ = try users.deleteOne(.{ ._id = "bongo-replace-one" });
}
