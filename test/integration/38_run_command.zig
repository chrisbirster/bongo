const std = @import("std");
const bongo = @import("bongo");

test "38 - runCommand executes arbitrary commands and surfaces failures" {
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

    const database = client.database("test");

    var response = try bongo.runCommand(
        database,
        .{
            .ping = @as(i32, 1),
            .comment = "bongo runCommand integration",
        },
    );
    defer response.deinit();

    const ok = (try bongo.bson.Reader.get(response.bytes, "ok")) orelse
        return error.MissingOk;
    try std.testing.expect(commandSucceeded(ok));

    if (bongo.runCommand(
        database,
        .{ .bongoCommandThatDoesNotExist = @as(i32, 1) },
    )) |unexpected_value| {
        var unexpected = unexpected_value;
        unexpected.deinit();
        return error.ExpectedCommandFailure;
    } else |err| {
        try std.testing.expect(err == error.CommandFailed);
    }

    try std.testing.expectError(
        error.EmptyDatabase,
        bongo.runCommand(
            client.database(""),
            .{ .ping = @as(i32, 1) },
        ),
    );

    try std.testing.expectError(
        error.EmptyCommand,
        bongo.runCommand(database, .{}),
    );

    try std.testing.expectError(
        error.ReservedDatabaseField,
        bongo.runCommand(
            database,
            .{
                .ping = @as(i32, 1),
                .@"$db" = "admin",
            },
        ),
    );
}

fn commandSucceeded(value: bongo.bson.Value) bool {
    return switch (value) {
        .double => |number| number == 1.0,
        .int32 => |number| number == 1,
        .int64 => |number| number == 1,
        else => false,
    };
}
