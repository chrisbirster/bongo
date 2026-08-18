const std = @import("std");
const bongo = @import("bongo");

test "23 - configured write concern applies to collection writes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try bongo.Client.connect(
        io,
        allocator,
        .{
            .username = "admin",
            .password = "secretpassword",
            .write_concern = .{
                .w = .majority,
                .journal = true,
                .wtimeout_ms = 1000,
            },
        },
    );
    defer client.deinit();

    const users = client.database("test").collection("bongo_write_concern");
    _ = try users.deleteMany(.{});

    const inserted = try users.insertOne(.{
        ._id = "write-concern",
        .score = @as(i32, 1),
    });
    try std.testing.expectEqual(@as(i64, 1), inserted.inserted_count);

    var updated = try users.updateOne(
        .{ ._id = "write-concern" },
        .{ .@"$set" = .{ .score = @as(i32, 2) } },
    );
    defer updated.deinit();
    try std.testing.expectEqual(@as(i64, 1), updated.matched_count);

    const deleted = try users.deleteOne(.{ ._id = "write-concern" });
    try std.testing.expectEqual(@as(i64, 1), deleted.deleted_count);
}
