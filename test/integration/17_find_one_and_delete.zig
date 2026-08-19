const std = @import("std");
const bongo = @import("bongo");

test "17 - findOneAndDelete returns deleted document" {
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
    _ = try users.deleteMany(.{ ._id = "bongo-find-one-delete" });

    _ = try users.insertOne(.{
        ._id = "bongo-find-one-delete",
        .name = "Bongo",
    });

    var deleted = (try users.findOneAndDelete(.{
        ._id = "bongo-find-one-delete",
    })).?;
    defer deleted.deinit();

    try std.testing.expectEqualStrings(
        "Bongo",
        (try bongo.bson.Reader.get(deleted.bytes, "name")).?.string,
    );

    try std.testing.expect(
        (try users.findOne(.{ ._id = "bongo-find-one-delete" })) == null,
    );
    try std.testing.expect(
        (try users.findOneAndDelete(.{
            ._id = "bongo-find-one-delete-missing",
        })) == null,
    );
}
