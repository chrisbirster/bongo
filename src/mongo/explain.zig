const std = @import("std");
const bson = @import("../bson.zig");
const client_mod = @import("client.zig");
const command_cursor = @import("command_cursor.zig");
const op_msg = @import("op_msg.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    UnexpectedResponse,
    CommandFailed,
};

pub const Verbosity = enum {
    query_planner,
    execution_stats,
    all_plans_execution,

    pub fn wireName(verbosity: Verbosity) []const u8 {
        return switch (verbosity) {
            .query_planner => "queryPlanner",
            .execution_stats => "executionStats",
            .all_plans_execution => "allPlansExecution",
        };
    }
};

pub fn explainFind(
    collection: anytype,
    filter: anytype,
    verbosity: Verbosity,
) !client_mod.OwnedDocument {
    const client = collection.client;
    const request_id = command_cursor.takeRequestId(client);
    const request = try encodeFindExplain(
        client.allocator,
        request_id,
        collection.database_name,
        collection.name,
        filter,
        verbosity,
    );
    defer client.allocator.free(request);

    const response = try client.connection.request(
        client.allocator,
        request,
    );
    defer client.allocator.free(response);

    const body = try validatedBody(response, request_id);
    return .{
        .allocator = client.allocator,
        .bytes = try client.allocator.dupe(u8, body),
    };
}

pub fn encodeFindExplain(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    verbosity: Verbosity,
) ![]u8 {
    const inner = try bson.encode(
        allocator,
        .{
            .find = collection_name,
            .filter = filter,
        },
    );
    defer allocator.free(inner);

    return op_msg.encodeCommand(
        allocator,
        .{
            .explain = bson.Value{ .document = inner },
            .verbosity = verbosity.wireName(),
            .@"$db" = database_name,
        },
        .{ .request_id = request_id },
    );
}

fn validatedBody(
    response_bytes: []const u8,
    expected_response_to: i32,
) ![]const u8 {
    const message = try op_msg.decode(response_bytes);
    if (message.header.response_to != expected_response_to) {
        return error.UnexpectedResponse;
    }

    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse
        return error.CommandFailed;
    if (!commandSucceeded(ok)) return error.CommandFailed;
    return body;
}

fn commandSucceeded(value: bson.Value) bool {
    return switch (value) {
        .double => |number| number == 1.0,
        .int32 => |number| number == 1,
        .int64 => |number| number == 1,
        else => false,
    };
}

test "explain wraps find command with requested verbosity" {
    const allocator = std.testing.allocator;

    const request = try encodeFindExplain(
        allocator,
        68,
        "test",
        "users",
        .{ .active = true },
        .execution_stats,
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const explained = (try bson.Reader.get(body, "explain")).?.document;
    const filter = (try bson.Reader.get(explained, "filter")).?.document;

    try std.testing.expectEqualStrings(
        "users",
        (try bson.Reader.get(explained, "find")).?.string,
    );
    try std.testing.expect(
        (try bson.Reader.get(filter, "active")).?.boolean,
    );
    try std.testing.expectEqualStrings(
        "executionStats",
        (try bson.Reader.get(body, "verbosity")).?.string,
    );
}

test "explain verbosity names match MongoDB command values" {
    try std.testing.expectEqualStrings(
        "queryPlanner",
        Verbosity.query_planner.wireName(),
    );
    try std.testing.expectEqualStrings(
        "executionStats",
        Verbosity.execution_stats.wireName(),
    );
    try std.testing.expectEqualStrings(
        "allPlansExecution",
        Verbosity.all_plans_execution.wireName(),
    );
}
