const std = @import("std");
const bongo = @import("bongo");

test "20 - distinct returns unique filtered values" {
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

    const users = client.database("test").collection("bongo_distinct");
    const marker = "bongo-distinct";
    _ = try users.deleteMany(.{ .marker = marker });

    const Document = struct {
        marker: []const u8,
        category: []const u8,
    };
    const documents = [_]Document{
        .{ .marker = marker, .category = "a" },
        .{ .marker = marker, .category = "b" },
        .{ .marker = marker, .category = "a" },
    };
    _ = try users.insertMany(&documents);

    var result = try users.distinct("category", .{ .marker = marker });
    defer result.deinit();

    var found_a = false;
    var found_b = false;
    var count: usize = 0;

    while (try result.next()) |value| {
        const category = switch (value) {
            .string => |string| string,
            else => return error.UnexpectedDistinctValue,
        };

        if (std.mem.eql(u8, category, "a")) found_a = true;
        if (std.mem.eql(u8, category, "b")) found_b = true;
        count += 1;
    }

    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
    try std.testing.expectEqual(@as(usize, 2), count);

    _ = try users.deleteMany(.{ .marker = marker });
}
