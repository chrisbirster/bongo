const std = @import("std");
const bongo = @import("bongo");

test "22 - update and replacement upserts create missing documents" {
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

    const users = client.database("test").collection("bongo_upsert");
    _ = try users.deleteMany(.{});

    var update_one = try users.updateOneWithOptions(
        .{ ._id = "upsert-one" },
        .{ .@"$set" = .{ .name = "Bongo" } },
        .{ .upsert = true },
    );
    defer update_one.deinit();

    try std.testing.expectEqual(@as(i64, 0), update_one.matched_count);
    try std.testing.expectEqual(@as(i64, 0), update_one.modified_count);
    try std.testing.expectEqual(@as(i64, 1), update_one.upserted_count);
    try std.testing.expectEqualStrings(
        "upsert-one",
        update_one.upserted_id.?.value.string,
    );

    var update_many = try users.updateManyWithOptions(
        .{ ._id = "upsert-many" },
        .{ .@"$set" = .{ .name = "Mango" } },
        .{ .upsert = true },
    );
    defer update_many.deinit();

    try std.testing.expectEqual(@as(i64, 0), update_many.matched_count);
    try std.testing.expectEqual(@as(i64, 1), update_many.upserted_count);
    try std.testing.expectEqualStrings(
        "upsert-many",
        update_many.upserted_id.?.value.string,
    );

    var replacement = try users.replaceOneWithOptions(
        .{ ._id = "upsert-replace" },
        .{
            ._id = "upsert-replace",
            .name = "Peach",
            .replaced = true,
        },
        .{ .upsert = true },
    );
    defer replacement.deinit();

    try std.testing.expectEqual(@as(i64, 0), replacement.matched_count);
    try std.testing.expectEqual(@as(i64, 1), replacement.upserted_count);
    try std.testing.expectEqualStrings(
        "upsert-replace",
        replacement.upserted_id.?.value.string,
    );

    var document = (try users.findOne(.{ ._id = "upsert-replace" })).?;
    defer document.deinit();
    try std.testing.expectEqualStrings(
        "Peach",
        (try bongo.bson.Reader.get(document.bytes, "name")).?.string,
    );

    _ = try users.deleteMany(.{});
}
