const std = @import("std");
const bongo = @import("bongo");

test "08 - updateOne updates one matching document" {
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
        .collection("bongo_update_one");

    _ = try users.insertOne(.{
        .kind = "bongo-0005",
        .status = "before",
    });

    const result = try users.updateOne(
        .{
            .kind = "bongo-0005",
            .status = "before",
        },
        .{
            .@"$set" = .{
                .status = "after",
            },
        },
    );

    try std.testing.expectEqual(@as(i64, 1), result.matched_count);
    try std.testing.expectEqual(@as(i64, 1), result.modified_count);

    var cursor = try users.find(.{
        .kind = "bongo-0005",
        .status = "after",
    });
    defer cursor.deinit();

    const document = (try cursor.next()) orelse
        return error.UpdatedDocumentNotFound;

    try std.testing.expectEqualStrings(
        "after",
        (try bongo.bson.Reader.get(document, "status")).?.string,
    );
}
