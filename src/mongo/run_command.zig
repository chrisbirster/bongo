const std = @import("std");
const bson = @import("../bson.zig");
const client_mod = @import("client.zig");
const command_cursor = @import("command_cursor.zig");
const command_response = @import("command_response.zig");
const op_msg = @import("op_msg.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    EmptyDatabase,
    EmptyCommand,
    ReservedDatabaseField,
};

/// Run an arbitrary MongoDB database command and return the validated response
/// body as owned BSON.
///
/// The first field in `command` must be the MongoDB command name. Bongo
/// preserves command field order and appends `$db` from the supplied Database.
pub fn runCommand(
    database: client_mod.Database,
    command: anytype,
) !client_mod.OwnedDocument {
    if (database.name.len == 0) return error.EmptyDatabase;

    // Build and validate the command body before consuming a request id or
    // performing network I/O. This keeps caller-controlled errors local.
    const body = try buildBody(
        database.client.allocator,
        database.name,
        command,
    );
    defer database.client.allocator.free(body);

    const request_id = command_cursor.takeRequestId(database.client);
    const request = try op_msg.encodeBody(
        database.client.allocator,
        body,
        .{ .request_id = request_id },
    );
    defer database.client.allocator.free(request);

    return command_response.sendOwned(
        database.client,
        request,
        request_id,
    );
}

/// Encode a command into a complete OP_MSG packet.
///
/// This is public primarily so command framing can be tested independently of
/// the network path.
pub fn encode(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    command: anytype,
) ![]u8 {
    const body = try buildBody(
        allocator,
        database_name,
        command,
    );
    defer allocator.free(body);

    return op_msg.encodeBody(
        allocator,
        body,
        .{ .request_id = request_id },
    );
}

fn buildBody(
    allocator: Allocator,
    database_name: []const u8,
    command: anytype,
) ![]u8 {
    if (database_name.len == 0) return error.EmptyDatabase;

    const encoded_command = try bson.encode(allocator, command);
    defer allocator.free(encoded_command);

    var reader = try bson.Reader.init(encoded_command);
    const first = (try reader.next()) orelse return error.EmptyCommand;
    if (std.mem.eql(u8, first.name, "$db")) {
        return error.ReservedDatabaseField;
    }

    var writer = try bson.Writer.init(allocator);
    errdefer writer.deinit();

    try writer.writeValue(first.name, first.value);

    while (try reader.next()) |element| {
        if (std.mem.eql(u8, element.name, "$db")) {
            return error.ReservedDatabaseField;
        }
        try writer.writeValue(element.name, element.value);
    }

    try writer.writeString("$db", database_name);
    return writer.finish();
}

test "runCommand encoding preserves command order and appends database" {
    const allocator = std.testing.allocator;

    const request = try encode(
        allocator,
        91,
        "admin",
        .{
            .ping = @as(i32, 1),
            .comment = "bongo runCommand",
        },
    );
    defer allocator.free(request);

    const message = try op_msg.decode(request);
    try std.testing.expectEqual(@as(i32, 91), message.header.request_id);

    const body = try message.body();
    var reader = try bson.Reader.init(body);

    const command = (try reader.next()).?;
    try std.testing.expectEqualStrings("ping", command.name);
    try std.testing.expectEqual(@as(i32, 1), command.value.int32);

    const comment = (try reader.next()).?;
    try std.testing.expectEqualStrings("comment", comment.name);
    try std.testing.expectEqualStrings("bongo runCommand", comment.value.string);

    const database = (try reader.next()).?;
    try std.testing.expectEqualStrings("$db", database.name);
    try std.testing.expectEqualStrings("admin", database.value.string);
    try std.testing.expect((try reader.next()) == null);
}

test "runCommand encoding rejects invalid caller-controlled command shape" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.EmptyDatabase,
        encode(allocator, 92, "", .{ .ping = @as(i32, 1) }),
    );

    try std.testing.expectError(
        error.EmptyCommand,
        encode(allocator, 93, "admin", .{}),
    );

    try std.testing.expectError(
        error.ReservedDatabaseField,
        encode(
            allocator,
            94,
            "admin",
            .{
                .ping = @as(i32, 1),
                .@"$db" = "other",
            },
        ),
    );
}
