const std = @import("std");
const bongo = @import("bongo");

test "25 - find options apply projection sort skip and limit" {
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

    const users = client.database("test").collection("bongo_find_options");
    _ = try users.deleteMany(.{});

    const Document = struct {
        name: []const u8,
        score: i32,
    };
    const documents = [_]Document{
        .{ .name = "low", .score = 1 },
        .{ .name = "middle", .score = 2 },
        .{ .name = "high", .score = 3 },
    };
    _ = try users.insertMany(&documents);

    var cursor = try bongo.findWithOptions(
        users,
        .{},
        .{
            .projection = .{
                ._id = @as(i32, 0),
                .name = @as(i32, 1),
            },
            .sort = .{ .score = @as(i32, -1) },
            .skip = @as(i64, 1),
            .limit = @as(i64, 1),
        },
    );
    defer cursor.deinit();

    const document = (try cursor.next()).?;
    try std.testing.expectEqualStrings(
        "middle",
        (try bongo.bson.Reader.get(document, "name")).?.string,
    );
    try std.testing.expect((try bongo.bson.Reader.get(document, "score")) == null);
    try std.testing.expect((try cursor.next()) == null);

    _ = try users.deleteMany(.{});
}
