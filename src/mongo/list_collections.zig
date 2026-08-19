const std = @import("std");
const bson = @import("../bson.zig");
const command_cursor = @import("command_cursor.zig");
const op_msg = @import("op_msg.zig");

const Allocator = std.mem.Allocator;

pub const Cursor = command_cursor.Cursor;

pub fn listCollections(
    database: anytype,
    options: anytype,
) !Cursor {
    const client = database.client;
    const request_id = command_cursor.takeRequestId(client);
    const request = try encode(
        client.allocator,
        request_id,
        database.name,
        options,
    );
    defer client.allocator.free(request);

    const response = try client.connection.request(
        client.allocator,
        request,
    );

    return Cursor.init(
        client,
        response,
        request_id,
        database.name,
        "$cmd.listCollections",
        "firstBatch",
    );
}

pub fn encode(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    options: anytype,
) ![]u8 {
    const Options = @TypeOf(options);
    if (@typeInfo(Options) != .@"struct") {
        @compileError("listCollections options must be a struct");
    }

    var writer = try bson.Writer.init(allocator);
    errdefer writer.deinit();

    try writer.writeInt32("listCollections", 1);

    inline for (@typeInfo(Options).@"struct".fields) |field| {
        try writeEncodedValue(
            &writer,
            allocator,
            field.name,
            @field(options, field.name),
        );
    }

    try writer.writeString("$db", database_name);

    const body = try writer.finish();
    defer allocator.free(body);
    return op_msg.encodeBody(
        allocator,
        body,
        .{ .request_id = request_id },
    );
}

fn writeEncodedValue(
    writer: *bson.Writer,
    allocator: Allocator,
    name: []const u8,
    value: anytype,
) !void {
    const holder = try bson.encode(allocator, .{ .value = value });
    defer allocator.free(holder);
    const encoded = (try bson.Reader.get(holder, "value")) orelse unreachable;
    try writer.writeValue(name, encoded);
}

test "listCollections encodes filter nameOnly and authorizedCollections" {
    const allocator = std.testing.allocator;

    const request = try encode(
        allocator,
        71,
        "test",
        .{
            .filter = .{ .name = "events" },
            .nameOnly = true,
            .authorizedCollections = true,
            .comment = "bongo list collections",
        },
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const filter = (try bson.Reader.get(body, "filter")).?.document;

    try std.testing.expectEqual(
        @as(i32, 1),
        (try bson.Reader.get(body, "listCollections")).?.int32,
    );
    try std.testing.expectEqualStrings(
        "events",
        (try bson.Reader.get(filter, "name")).?.string,
    );
    try std.testing.expect((try bson.Reader.get(body, "nameOnly")).?.boolean);
    try std.testing.expect(
        (try bson.Reader.get(body, "authorizedCollections")).?.boolean,
    );
}
