const std = @import("std");
const bson = @import("../bson.zig");
const Client = @import("client.zig").Client;
const command_cursor = @import("command_cursor.zig");
const command_response = @import("command_response.zig");
const op_msg = @import("op_msg.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    MissingDatabases,
    InvalidDatabases,
    InvalidDatabaseDocument,
};

pub const Result = struct {
    allocator: Allocator,
    response_bytes: []u8,
    reader: bson.Reader,

    pub fn next(self: *Result) !?[]const u8 {
        const element = (try self.reader.next()) orelse return null;
        return switch (element.value) {
            .document => |document| document,
            else => error.InvalidDatabaseDocument,
        };
    }

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.response_bytes);
        self.* = undefined;
    }
};

pub fn listDatabases(
    client: *Client,
    options: anytype,
) !Result {
    const request_id = command_cursor.takeRequestId(client);
    const request = try encode(
        client.allocator,
        request_id,
        options,
    );
    defer client.allocator.free(request);

    const response = try client.connection.request(
        client.allocator,
        request,
    );

    return parse(
        client.allocator,
        response,
        request_id,
    );
}

pub fn encode(
    allocator: Allocator,
    request_id: i32,
    options: anytype,
) ![]u8 {
    const Options = @TypeOf(options);
    if (@typeInfo(Options) != .@"struct") {
        @compileError("listDatabases options must be a struct");
    }

    var writer = try bson.Writer.init(allocator);
    errdefer writer.deinit();

    try writer.writeInt32("listDatabases", 1);

    inline for (@typeInfo(Options).@"struct".fields) |field| {
        try writeEncodedValue(
            &writer,
            allocator,
            field.name,
            @field(options, field.name),
        );
    }

    try writer.writeString("$db", "admin");

    const body = try writer.finish();
    defer allocator.free(body);
    return op_msg.encodeBody(
        allocator,
        body,
        .{ .request_id = request_id },
    );
}

pub fn parse(
    allocator: Allocator,
    response_bytes: []u8,
    expected_response_to: i32,
) !Result {
    errdefer allocator.free(response_bytes);

    const body = try command_response.validate(
        response_bytes,
        expected_response_to,
    );
    const databases_value = (try bson.Reader.get(body, "databases")) orelse
        return error.MissingDatabases;
    const databases = switch (databases_value) {
        .array => |array| array,
        else => return error.InvalidDatabases,
    };
    try bson.validateArray(databases);

    return .{
        .allocator = allocator,
        .response_bytes = response_bytes,
        .reader = try bson.Reader.init(databases),
    };
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

test "listDatabases encodes filter nameOnly authorization and admin database" {
    const allocator = std.testing.allocator;

    const request = try encode(
        allocator,
        80,
        .{
            .filter = .{ .name = "app" },
            .nameOnly = true,
            .authorizedDatabases = true,
            .comment = "bongo list databases",
        },
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const filter = (try bson.Reader.get(body, "filter")).?.document;

    try std.testing.expectEqual(
        @as(i32, 1),
        (try bson.Reader.get(body, "listDatabases")).?.int32,
    );
    try std.testing.expectEqualStrings(
        "app",
        (try bson.Reader.get(filter, "name")).?.string,
    );
    try std.testing.expect((try bson.Reader.get(body, "nameOnly")).?.boolean);
    try std.testing.expect(
        (try bson.Reader.get(body, "authorizedDatabases")).?.boolean,
    );
    try std.testing.expectEqualStrings(
        "admin",
        (try bson.Reader.get(body, "$db")).?.string,
    );
}

test "listDatabases response streams raw database metadata" {
    const allocator = std.testing.allocator;
    const DatabaseInfo = struct {
        name: []const u8,
        sizeOnDisk: i64,
        empty: bool,
    };
    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .databases = [_]DatabaseInfo{
                .{ .name = "alpha", .sizeOnDisk = 10, .empty = false },
                .{ .name = "beta", .sizeOnDisk = 20, .empty = true },
            },
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 90,
            .response_to = 80,
        },
    );

    var result = try parse(allocator, response, 80);
    defer result.deinit();

    const first = (try result.next()).?;
    try std.testing.expectEqualStrings(
        "alpha",
        (try bson.Reader.get(first, "name")).?.string,
    );
    try std.testing.expectEqual(
        @as(i64, 10),
        (try bson.Reader.get(first, "sizeOnDisk")).?.int64,
    );

    const second = (try result.next()).?;
    try std.testing.expectEqualStrings(
        "beta",
        (try bson.Reader.get(second, "name")).?.string,
    );
    try std.testing.expect((try result.next()) == null);
}

test "listDatabases rejects missing and invalid database arrays" {
    const allocator = std.testing.allocator;

    const missing = try op_msg.encodeCommand(
        allocator,
        .{ .ok = @as(f64, 1.0) },
        .{ .request_id = 90, .response_to = 81 },
    );
    try std.testing.expectError(
        error.MissingDatabases,
        parse(allocator, missing, 81),
    );

    const invalid = try op_msg.encodeCommand(
        allocator,
        .{
            .databases = "not-an-array",
            .ok = @as(f64, 1.0),
        },
        .{ .request_id = 91, .response_to = 82 },
    );
    try std.testing.expectError(
        error.InvalidDatabases,
        parse(allocator, invalid, 82),
    );
}

test "listDatabases rejects non-document array entries" {
    const allocator = std.testing.allocator;
    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .databases = [_][]const u8{"invalid"},
            .ok = @as(f64, 1.0),
        },
        .{ .request_id = 92, .response_to = 83 },
    );

    var result = try parse(allocator, response, 83);
    defer result.deinit();
    try std.testing.expectError(
        error.InvalidDatabaseDocument,
        result.next(),
    );
}

test "listDatabases rejects mismatched response ids" {
    const allocator = std.testing.allocator;
    const EmptyInfo = struct { name: []const u8 };
    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .databases = [_]EmptyInfo{},
            .ok = @as(f64, 1.0),
        },
        .{ .request_id = 93, .response_to = 84 },
    );

    try std.testing.expectError(
        error.UnexpectedResponse,
        parse(allocator, response, 85),
    );
}
