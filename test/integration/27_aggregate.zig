const std = @import("std");
const bongo = @import("bongo");

test "27 - aggregate executes a multi-stage pipeline" {
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

    const users = client.database("test").collection("bongo_aggregate");
    _ = try users.deleteMany(.{});

    const Document = struct {
        name: []const u8,
        group: []const u8,
        score: i32,
    };
    const documents = [_]Document{
        .{ .name = "low", .group = "cat", .score = 1 },
        .{ .name = "high", .group = "cat", .score = 3 },
        .{ .name = "other", .group = "dog", .score = 9 },
    };
    _ = try users.insertMany(&documents);

    var cursor = try bongo.aggregate(
        users,
        .{
            .{ .@"$match" = .{ .group = "cat" } },
            .{ .@"$sort" = .{ .score = @as(i32, -1) } },
            .{ .@"$project" = .{
                ._id = @as(i32, 0),
                .name = @as(i32, 1),
            } },
        },
    );
    defer cursor.deinit();

    const first = (try cursor.next()).?;
    try std.testing.expectEqualStrings(
        "high",
        (try bongo.bson.Reader.get(first, "name")).?.string,
    );
    const second = (try cursor.next()).?;
    try std.testing.expectEqualStrings(
        "low",
        (try bongo.bson.Reader.get(second, "name")).?.string,
    );
    try std.testing.expect((try cursor.next()) == null);

    _ = try users.deleteMany(.{});
}
