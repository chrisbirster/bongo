const std = @import("std");
const bson = @import("../bson.zig");
const command_cursor = @import("command_cursor.zig");
const command_response = @import("command_response.zig");
const op_msg = @import("op_msg.zig");
const write_concern = @import("write_concern.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    EmptyCollection,
};

pub fn createCollection(
    database: anytype,
    name: []const u8,
    options: anytype,
) !void {
    if (name.len == 0) return error.EmptyCollection;

    const client = database.client;
    const request_id = command_cursor.takeRequestId(client);
    const request = try encodeCreate(
        client.allocator,
        request_id,
        database.name,
        name,
        options,
    );
    defer client.allocator.free(request);

    try command_response.sendVoid(client, request, request_id);
}

pub fn dropCollection(collection: anytype) !void {
    const client = collection.client;
    const request_id = command_cursor.takeRequestId(client);
    const request = try encodeDrop(
        client.allocator,
        request_id,
        collection.database_name,
        collection.name,
        client.write_concern,
    );
    defer client.allocator.free(request);

    try command_response.sendVoid(client, request, request_id);
}

pub fn renameCollection(
    collection: anytype,
    new_name: []const u8,
    drop_target: bool,
) !void {
    if (new_name.len == 0) return error.EmptyCollection;

    const client = collection.client;
    const request_id = command_cursor.takeRequestId(client);
    const request = try encodeRename(
        client.allocator,
        request_id,
        collection.database_name,
        collection.name,
        new_name,
        drop_target,
        client.write_concern,
    );
    defer client.allocator.free(request);

    try command_response.sendVoid(client, request, request_id);
}

pub fn encodeCreate(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    options: anytype,
) ![]u8 {
    const Options = @TypeOf(options);
    if (@typeInfo(Options) != .@"struct") {
        @compileError("createCollection options must be a struct");
    }

    var writer = try bson.Writer.init(allocator);
    errdefer writer.deinit();

    try writer.writeString("create", collection_name);

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

pub fn encodeDrop(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    concern: ?write_concern.WriteConcern,
) ![]u8 {
    if (concern) |configured| {
        const concern_document = try write_concern.encode(allocator, configured);
        defer allocator.free(concern_document);

        return op_msg.encodeCommand(
            allocator,
            .{
                .drop = collection_name,
                .writeConcern = bson.Value{ .document = concern_document },
                .@"$db" = database_name,
            },
            .{ .request_id = request_id },
        );
    }

    return op_msg.encodeCommand(
        allocator,
        .{
            .drop = collection_name,
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeRename(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    source_name: []const u8,
    target_name: []const u8,
    drop_target: bool,
    concern: ?write_concern.WriteConcern,
) ![]u8 {
    const source_namespace = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ database_name, source_name },
    );
    defer allocator.free(source_namespace);
    const target_namespace = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ database_name, target_name },
    );
    defer allocator.free(target_namespace);

    if (concern) |configured| {
        const concern_document = try write_concern.encode(allocator, configured);
        defer allocator.free(concern_document);

        return op_msg.encodeCommand(
            allocator,
            .{
                .renameCollection = source_namespace,
                .to = target_namespace,
                .dropTarget = drop_target,
                .writeConcern = bson.Value{ .document = concern_document },
                .@"$db" = "admin",
            },
            .{ .request_id = request_id },
        );
    }

    return op_msg.encodeCommand(
        allocator,
        .{
            .renameCollection = source_namespace,
            .to = target_namespace,
            .dropTarget = drop_target,
            .@"$db" = "admin",
        },
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

test "createCollection flattens collection options into command" {
    const allocator = std.testing.allocator;

    const request = try encodeCreate(
        allocator,
        69,
        "test",
        "events",
        .{
            .capped = true,
            .size = @as(i64, 1_048_576),
            .max = @as(i64, 1000),
            .validator = .{ .kind = "event" },
        },
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const validator = (try bson.Reader.get(body, "validator")).?.document;

    try std.testing.expectEqualStrings(
        "events",
        (try bson.Reader.get(body, "create")).?.string,
    );
    try std.testing.expect((try bson.Reader.get(body, "capped")).?.boolean);
    try std.testing.expectEqual(
        @as(i64, 1_048_576),
        (try bson.Reader.get(body, "size")).?.int64,
    );
    try std.testing.expectEqualStrings(
        "event",
        (try bson.Reader.get(validator, "kind")).?.string,
    );
}

test "dropCollection encodes optional write concern" {
    const allocator = std.testing.allocator;

    const request = try encodeDrop(
        allocator,
        70,
        "test",
        "events",
        .{
            .w = .majority,
            .journal = true,
        },
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const concern = (try bson.Reader.get(body, "writeConcern")).?.document;

    try std.testing.expectEqualStrings(
        "events",
        (try bson.Reader.get(body, "drop")).?.string,
    );
    try std.testing.expectEqualStrings(
        "majority",
        (try bson.Reader.get(concern, "w")).?.string,
    );
}

test "renameCollection uses admin and fully qualified namespaces" {
    const allocator = std.testing.allocator;

    const request = try encodeRename(
        allocator,
        72,
        "test",
        "old_name",
        "new_name",
        true,
        null,
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    try std.testing.expectEqualStrings(
        "test.old_name",
        (try bson.Reader.get(body, "renameCollection")).?.string,
    );
    try std.testing.expectEqualStrings(
        "test.new_name",
        (try bson.Reader.get(body, "to")).?.string,
    );
    try std.testing.expect((try bson.Reader.get(body, "dropTarget")).?.boolean);
    try std.testing.expectEqualStrings(
        "admin",
        (try bson.Reader.get(body, "$db")).?.string,
    );
}
