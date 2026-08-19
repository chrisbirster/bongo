const std = @import("std");
const bson = @import("../bson.zig");
const op_msg = @import("op_msg.zig");
const replacement_ops = @import("replacement.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    UnexpectedResponse,
    CommandFailed,
    MissingValue,
    InvalidValue,
};

pub const ReturnDocument = enum {
    before,
    after,
};

pub const UpdateOptions = struct {
    return_document: ReturnDocument = .before,
};

pub const ReplaceOptions = UpdateOptions;

pub fn encodeUpdate(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    update_document: anytype,
    return_document: ReturnDocument,
) ![]u8 {
    return op_msg.encodeCommand(
        allocator,
        .{
            .findAndModify = collection_name,
            .query = filter,
            .update = update_document,
            .new = return_document == .after,
            .@"$db" = database_name,
        },
        .{
            .request_id = request_id,
        },
    );
}

pub fn encodeReplace(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    replacement: anytype,
    return_document: ReturnDocument,
) ![]u8 {
    try replacement_ops.validateReplacement(replacement);

    return encodeUpdate(
        allocator,
        request_id,
        database_name,
        collection_name,
        filter,
        replacement,
        return_document,
    );
}

pub fn encodeDelete(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
) ![]u8 {
    return op_msg.encodeCommand(
        allocator,
        .{
            .findAndModify = collection_name,
            .query = filter,
            .remove = true,
            .@"$db" = database_name,
        },
        .{
            .request_id = request_id,
        },
    );
}

pub fn parseDocumentResponse(
    allocator: Allocator,
    response_bytes: []const u8,
    expected_response_to: i32,
) !?[]u8 {
    const message = try op_msg.decode(response_bytes);
    if (message.header.response_to != expected_response_to) {
        return error.UnexpectedResponse;
    }

    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse
        return error.CommandFailed;

    if (!commandSucceeded(ok)) return error.CommandFailed;

    const value = (try bson.Reader.get(body, "value")) orelse
        return error.MissingValue;

    return switch (value) {
        .null_value => null,
        .document => |document| try allocator.dupe(u8, document),
        else => error.InvalidValue,
    };
}

fn commandSucceeded(value: bson.Value) bool {
    return switch (value) {
        .double => |number| number == 1.0,
        .int32 => |number| number == 1,
        .int64 => |number| number == 1,
        else => false,
    };
}

test "findOneAndUpdate command controls returned document" {
    const allocator = std.testing.allocator;

    const before = try encodeUpdate(
        allocator,
        48,
        "test",
        "users",
        .{ ._id = "bongo-fam" },
        .{ .@"$set" = .{ .name = "Mango" } },
        .before,
    );
    defer allocator.free(before);

    const after = try encodeUpdate(
        allocator,
        49,
        "test",
        "users",
        .{ ._id = "bongo-fam" },
        .{ .@"$set" = .{ .name = "Mango" } },
        .after,
    );
    defer allocator.free(after);

    const before_body = try (try op_msg.decode(before)).body();
    const after_body = try (try op_msg.decode(after)).body();

    try std.testing.expect(
        !(try bson.Reader.get(before_body, "new")).?.boolean,
    );
    try std.testing.expect(
        (try bson.Reader.get(after_body, "new")).?.boolean,
    );
}

test "findOneAndReplace rejects modifiers and encodes replacement" {
    const allocator = std.testing.allocator;

    const request = try encodeReplace(
        allocator,
        50,
        "test",
        "users",
        .{ ._id = "bongo-far" },
        .{ ._id = "bongo-far", .name = "Mango" },
        .after,
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const update = (try bson.Reader.get(body, "update")).?.document;

    try std.testing.expectEqualStrings(
        "Mango",
        (try bson.Reader.get(update, "name")).?.string,
    );
    try std.testing.expect((try bson.Reader.get(body, "new")).?.boolean);

    try std.testing.expectError(
        error.InvalidReplacement,
        encodeReplace(
            allocator,
            51,
            "test",
            "users",
            .{ ._id = "bongo-far" },
            .{ .@"$set" = .{ .name = "Mango" } },
            .before,
        ),
    );
}

test "findOneAndDelete encodes remove true" {
    const allocator = std.testing.allocator;

    const request = try encodeDelete(
        allocator,
        52,
        "test",
        "users",
        .{ ._id = "bongo-fad" },
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    try std.testing.expect(
        (try bson.Reader.get(body, "remove")).?.boolean,
    );
    try std.testing.expect(
        (try bson.Reader.get(body, "update")) == null,
    );
}

test "findAndModify response returns owned document or null" {
    const allocator = std.testing.allocator;

    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .value = .{ .name = "Bongo" },
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 90,
            .response_to = 48,
        },
    );
    defer allocator.free(response);

    const document = (try parseDocumentResponse(
        allocator,
        response,
        48,
    )).?;
    defer allocator.free(document);

    try std.testing.expectEqualStrings(
        "Bongo",
        (try bson.Reader.get(document, "name")).?.string,
    );

    const null_response = try op_msg.encodeCommand(
        allocator,
        .{
            .value = bson.Null{},
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 91,
            .response_to = 49,
        },
    );
    defer allocator.free(null_response);

    try std.testing.expect(
        (try parseDocumentResponse(allocator, null_response, 49)) == null,
    );
}
