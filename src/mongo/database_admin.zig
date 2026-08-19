const std = @import("std");
const bson = @import("../bson.zig");
const Database = @import("client.zig").Database;
const command_cursor = @import("command_cursor.zig");
const command_response = @import("command_response.zig");
const op_msg = @import("op_msg.zig");
const write_concern = @import("write_concern.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    EmptyDatabase,
};

pub fn dropDatabase(database: Database) !void {
    const client = database.client;
    const request_id = command_cursor.takeRequestId(client);
    const request = try encodeDropDatabase(
        client.allocator,
        request_id,
        database.name,
        client.write_concern,
    );
    defer client.allocator.free(request);

    try command_response.sendVoid(client, request, request_id);
}

pub fn encodeDropDatabase(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    concern: ?write_concern.WriteConcern,
) ![]u8 {
    if (database_name.len == 0) return error.EmptyDatabase;

    if (concern) |configured| {
        const concern_document = try write_concern.encode(allocator, configured);
        defer allocator.free(concern_document);

        return op_msg.encodeCommand(
            allocator,
            .{
                .dropDatabase = @as(i32, 1),
                .writeConcern = bson.Value{ .document = concern_document },
                .@"$db" = database_name,
            },
            .{ .request_id = request_id },
        );
    }

    return op_msg.encodeCommand(
        allocator,
        .{
            .dropDatabase = @as(i32, 1),
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

test "dropDatabase encodes target database without optional concern" {
    const allocator = std.testing.allocator;
    const request = try encodeDropDatabase(
        allocator,
        86,
        "app",
        null,
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    try std.testing.expectEqual(
        @as(i32, 1),
        (try bson.Reader.get(body, "dropDatabase")).?.int32,
    );
    try std.testing.expectEqualStrings(
        "app",
        (try bson.Reader.get(body, "$db")).?.string,
    );
    try std.testing.expect((try bson.Reader.get(body, "writeConcern")) == null);
}

test "dropDatabase encodes configured write concern" {
    const allocator = std.testing.allocator;
    const request = try encodeDropDatabase(
        allocator,
        87,
        "app",
        .{
            .w = .majority,
            .journal = true,
            .wtimeout_ms = 5000,
        },
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const concern = (try bson.Reader.get(body, "writeConcern")).?.document;

    try std.testing.expectEqualStrings(
        "majority",
        (try bson.Reader.get(concern, "w")).?.string,
    );
    try std.testing.expect((try bson.Reader.get(concern, "j")).?.boolean);
    try std.testing.expectEqual(
        @as(i32, 5000),
        (try bson.Reader.get(concern, "wtimeout")).?.int32,
    );
}

test "dropDatabase rejects an empty database name" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.EmptyDatabase,
        encodeDropDatabase(allocator, 88, "", null),
    );
}
