const std = @import("std");
const bongo = @import("bongo");

test "18 - countDocuments counts matching documents with options" {
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
    const marker = "bongo-count-documents";
    _ = try users.deleteMany(.{ .marker = marker });

    _ = try users.insertMany(&[_]struct {
        marker: []const u8,
        active: bool,
    }{
        .{ .marker = marker, .active = true },
        .{ .marker = marker, .active = true },
        .{ .marker = marker, .active = true },
        .{ .marker = marker, .active = false },
    });

    try std.testing.expectEqual(
        @as(i64, 3),
        try users.countDocuments(
            .{ .marker = marker, .active = true },
            .{},
        ),
    );

    try std.testing.expectEqual(
        @as(i64, 1),
        try users.countDocuments(
            .{ .marker = marker, .active = true },
            .{ .skip = 1, .limit = 1 },
        ),
    );

    try std.testing.expectEqual(
        @as(i64, 0),
        try users.countDocuments(.{ .marker = "missing" }, .{}),
    );

    _ = try users.deleteMany(.{ .marker = marker });
}
