const std = @import("std");
const bongo = @import("bongo");

test "07 - insertOne inserts a document that can be found" {
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
        .collection("bongo_insert_one");

    const result = try users.insertOne(.{
        .kind = "bongo-0004",
        .name = "Bongo",
    });

    try std.testing.expectEqual(@as(i64, 1), result.inserted_count);

    var cursor = try users.find(.{
        .kind = "bongo-0004",
        .name = "Bongo",
    });
    defer cursor.deinit();

    const document = (try cursor.next()) orelse
        return error.InsertedDocumentNotFound;

    try std.testing.expectEqualStrings(
        "Bongo",
        (try bongo.bson.Reader.get(document, "name")).?.string,
    );
}
