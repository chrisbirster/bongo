const std = @import("std");
const bongo = @import("bongo");

test "28 - explain find returns query planner information" {
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

    const users = client.database("test").collection("bongo_explain");
    _ = try users.deleteMany(.{});
    _ = try users.insertOne(.{
        ._id = "explain-find",
        .name = "Bongo",
    });

    var explanation = try bongo.explainFind(
        users,
        .{ .name = "Bongo" },
        .query_planner,
    );
    defer explanation.deinit();

    try std.testing.expect(
        (try bongo.bson.Reader.get(explanation.bytes, "queryPlanner")) != null,
    );

    _ = try users.deleteMany(.{});
}
