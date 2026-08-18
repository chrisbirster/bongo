const std = @import("std");
const bongo = @import("bongo");

test "21 - bulkWrite executes mixed ordered and unordered models" {
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

    const users = client.database("test").collection("bongo_bulk_write");
    _ = try users.deleteMany(.{});

    const result = try users.bulkWrite(
        .{
            .{ .insert_one = .{ .document = .{
                ._id = "bulk-a",
                .group = "bulk-x",
                .score = @as(i32, 1),
            } } },
            .{ .insert_one = .{ .document = .{
                ._id = "bulk-b",
                .group = "bulk-x",
                .score = @as(i32, 1),
            } } },
            .{ .insert_one = .{ .document = .{
                ._id = "bulk-c",
                .group = "bulk-many",
                .score = @as(i32, 1),
            } } },
            .{ .update_one = .{
                .filter = .{ ._id = "bulk-a" },
                .update = .{ .@"$set" = .{ .score = @as(i32, 2) } },
            } },
            .{ .update_many = .{
                .filter = .{ .group = "bulk-x" },
                .update = .{ .@"$set" = .{ .flagged = true } },
            } },
            .{ .replace_one = .{
                .filter = .{ ._id = "bulk-b" },
                .replacement = .{
                    ._id = "bulk-b",
                    .group = "bulk-x",
                    .score = @as(i32, 3),
                },
            } },
            .{ .delete_one = .{ .filter = .{ ._id = "bulk-a" } } },
            .{ .delete_many = .{ .filter = .{ .group = "bulk-many" } } },
        },
        .{},
    );

    try std.testing.expectEqual(@as(i64, 3), result.inserted_count);
    try std.testing.expectEqual(@as(i64, 4), result.matched_count);
    try std.testing.expectEqual(@as(i64, 4), result.modified_count);
    try std.testing.expectEqual(@as(i64, 2), result.deleted_count);
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
    try std.testing.expect(!result.stopped_early);

    try std.testing.expect((try users.findOne(.{ ._id = "bulk-a" })) == null);

    var remaining = (try users.findOne(.{ ._id = "bulk-b" })).?;
    defer remaining.deinit();
    try std.testing.expectEqual(
        @as(i32, 3),
        (try bongo.bson.Reader.get(remaining.bytes, "score")).?.int32,
    );

    const unordered = try users.bulkWrite(
        .{
            .{ .insert_one = .{ .document = .{
                ._id = "bulk-b",
                .name = "duplicate",
            } } },
            .{ .insert_one = .{ .document = .{
                ._id = "bulk-unordered",
                .name = "continued",
            } } },
        },
        .{ .ordered = false },
    );

    try std.testing.expectEqual(@as(usize, 1), unordered.error_count);
    try std.testing.expectEqual(@as(?usize, 0), unordered.first_error_index);
    try std.testing.expect(unordered.first_error.? == error.WriteFailed);
    try std.testing.expectEqual(@as(i64, 1), unordered.inserted_count);
    try std.testing.expect(!unordered.stopped_early);

    var unordered_document = (try users.findOne(.{
        ._id = "bulk-unordered",
    })).?;
    defer unordered_document.deinit();

    const ordered = try users.bulkWrite(
        .{
            .{ .insert_one = .{ .document = .{
                ._id = "bulk-b",
                .name = "duplicate",
            } } },
            .{ .insert_one = .{ .document = .{
                ._id = "bulk-ordered",
                .name = "must-not-run",
            } } },
        },
        .{ .ordered = true },
    );

    try std.testing.expectEqual(@as(usize, 1), ordered.error_count);
    try std.testing.expect(ordered.stopped_early);
    try std.testing.expectEqual(@as(i64, 0), ordered.inserted_count);
    try std.testing.expect(
        (try users.findOne(.{ ._id = "bulk-ordered" })) == null,
    );

    _ = try users.deleteMany(.{});
}
