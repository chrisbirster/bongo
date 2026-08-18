const std = @import("std");
const bongo = @import("bongo");

test "05 - client collection authenticates and runs find" {
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
        .collection("users");

    var result = try users.find(.{});
    defer result.deinit();

    var documents = try result.iterator();
    while (try documents.next()) |document| {
        try bongo.bson.validateDocument(document);
    }
}
