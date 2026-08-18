const std = @import("std");
const bongo = @import("bongo");

test "10 - findOne returns one owned document or null" {
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
        .collection("bongo_find_one");

    _ = try users.deleteOne(.{ ._id = "bongo-0007" });
    _ = try users.insertOne(.{
        ._id = "bongo-0007",
        .name = "Bongo",
    });

    var found = (try users.findOne(.{ ._id = "bongo-0007" })) orelse
        return error.DocumentNotFound;
    defer found.deinit();

    try std.testing.expectEqualStrings(
        "Bongo",
        (try bongo.bson.Reader.get(found.bytes, "name")).?.string,
    );

    const missing = try users.findOne(.{ ._id = "bongo-0007-missing" });
    try std.testing.expect(missing == null);
}
