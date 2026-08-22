const std = @import("std");
const bongo = @import("bongo");

const ports = [_]u16{ 27021, 27022, 27023 };

test "45 - retryable find survives upstream retryable-read server error" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const database = "bongo_retry_read";
    const collection = "cards";

    var client = try bongo.RuntimeClient.connectUri(
        io,
        allocator,
        "mongodb://localhost:27021/bongo_retry_read?replicaSet=rs0&heartbeatFrequencyMS=500&serverSelectionTimeoutMS=5000&retryReads=true",
        .{},
    );
    defer client.deinit();

    _ = try client.deleteOne(database, collection, .{ ._id = @as(i64, 66001) });
    _ = try client.insertOne(database, collection, .{
        ._id = @as(i64, 66001),
        .value = @as(i32, 1),
    });

    const primary = try findPrimaryPort(io, allocator);
    try failNextRead(io, allocator, primary, 91);

    var cursor = try client.find(
        database,
        collection,
        .{ ._id = @as(i64, 66001) },
        .{ .limit = @as(i64, 1) },
    );
    defer cursor.deinit();
    try std.testing.expect((try cursor.next()) != null);
}

test "45 - retryable insert reuses logical write identity and succeeds" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const database = "bongo_retry_write";
    const collection = "cards";

    var client = try bongo.RuntimeClient.connectUri(
        io,
        allocator,
        "mongodb://localhost:27021/bongo_retry_write?replicaSet=rs0&heartbeatFrequencyMS=500&serverSelectionTimeoutMS=5000&retryWrites=true",
        .{},
    );
    defer client.deinit();

    _ = try client.deleteOne(database, collection, .{ ._id = @as(i64, 66002) });
    const primary = try findPrimaryPort(io, allocator);
    try failNextWrite(io, allocator, primary, "insert", 91, "RetryableWriteError");

    _ = try client.insertOne(database, collection, .{
        ._id = @as(i64, 66002),
        .value = @as(i32, 2),
    });
    var found = try client.find(
        database,
        collection,
        .{ ._id = @as(i64, 66002) },
        .{ .limit = @as(i64, 1) },
    );
    defer found.deinit();
    try std.testing.expect((try found.next()) != null);
}

test "45 - commit retries UnknownTransactionCommitResult with same transaction" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const database = "bongo_retry_commit";
    const collection = "cards";

    var client = try bongo.RuntimeClient.connectUri(
        io,
        allocator,
        "mongodb://localhost:27021/bongo_retry_commit?replicaSet=rs0&heartbeatFrequencyMS=500&serverSelectionTimeoutMS=5000",
        .{},
    );
    defer client.deinit();

    _ = try client.deleteOne(database, collection, .{ ._id = @as(i64, 66003) });
    var transaction = try client.beginTransaction(.{});
    defer transaction.deinit();
    _ = try transaction.insertOne(database, collection, .{
        ._id = @as(i64, 66003),
        .value = @as(i32, 3),
    });

    const primary = try findPrimaryPort(io, allocator);
    try failNextWrite(
        io,
        allocator,
        primary,
        "commitTransaction",
        91,
        "UnknownTransactionCommitResult",
    );
    try transaction.commit();

    var found = try client.find(
        database,
        collection,
        .{ ._id = @as(i64, 66003) },
        .{ .limit = @as(i64, 1) },
    );
    defer found.deinit();
    try std.testing.expect((try found.next()) != null);
}

fn failNextRead(
    io: std.Io,
    allocator: std.mem.Allocator,
    port: u16,
    code: i32,
) !void {
    try runAdminCommand(io, allocator, port, .{
        .configureFailPoint = "failCommand",
        .mode = .{ .times = @as(i32, 1) },
        .data = .{
            .failCommands = [_][]const u8{"find"},
            .errorCode = code,
        },
        .@"$db" = "admin",
    });
}

fn failNextWrite(
    io: std.Io,
    allocator: std.mem.Allocator,
    port: u16,
    command_name: []const u8,
    code: i32,
    label: []const u8,
) !void {
    try runAdminCommand(io, allocator, port, .{
        .configureFailPoint = "failCommand",
        .mode = .{ .times = @as(i32, 1) },
        .data = .{
            .failCommands = [_][]const u8{command_name},
            .errorCode = code,
            .errorLabels = [_][]const u8{label},
        },
        .@"$db" = "admin",
    });
}

fn runAdminCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    port: u16,
    command: anytype,
) !void {
    var connection = try bongo.mongo.Connection.connect(io, "localhost", port);
    defer connection.deinit();
    const request_id: i32 = @intCast(67000 + port - 27021);
    const request = try bongo.mongo.op_msg.encodeCommand(
        allocator,
        command,
        .{ .request_id = request_id },
    );
    defer allocator.free(request);
    const response = try connection.request(allocator, request);
    defer allocator.free(response);
    const status = try bongo.inspectMongoError(response, request_id);
    if (!status.ok) return error.CommandFailed;
}

fn findPrimaryPort(io: std.Io, allocator: std.mem.Allocator) !u16 {
    for (ports) |port| {
        var connection = bongo.mongo.Connection.connect(io, "localhost", port) catch continue;
        defer connection.deinit();
        const request = try bongo.mongo.op_msg.encodeCommand(
            allocator,
            .{ .hello = @as(i32, 1), .@"$db" = "admin" },
            .{ .request_id = @as(i32, port) },
        );
        defer allocator.free(request);
        const response = connection.request(allocator, request) catch continue;
        defer allocator.free(response);
        const message = bongo.mongo.op_msg.decode(response) catch continue;
        const body = message.body() catch continue;
        const value = (bongo.bson.Reader.get(body, "isWritablePrimary") catch null) orelse continue;
        switch (value) {
            .boolean => |is_primary| if (is_primary) return port,
            else => {},
        }
    }
    return error.NoPrimary;
}
