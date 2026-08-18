const std = @import("std");
const crud = @import("crud.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidReplacement,
};

pub fn encodeReplaceOne(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    replacement: anytype,
) ![]u8 {
    return encodeReplaceOneWithOptions(
        allocator,
        request_id,
        database_name,
        collection_name,
        filter,
        replacement,
        false,
    );
}

pub fn encodeReplaceOneWithOptions(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    replacement: anytype,
    upsert: bool,
) ![]u8 {
    try validateReplacement(replacement);

    return crud.encodeUpdate(
        allocator,
        request_id,
        database_name,
        collection_name,
        filter,
        replacement,
        false,
        upsert,
    );
}

pub fn validateReplacement(replacement: anytype) Error!void {
    const T = @TypeOf(replacement);

    if (@typeInfo(T) != .@"struct") {
        @compileError("replacement must be a struct document");
    }

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.name.len > 0 and field.name[0] == '$') {
            return error.InvalidReplacement;
        }
    }
}

test "replaceOne encodes replacement with multi false" {
    const allocator = std.testing.allocator;
    const bson = @import("../bson.zig");
    const op_msg = @import("op_msg.zig");

    const request = try encodeReplaceOne(
        allocator,
        46,
        "test",
        "users",
        .{ ._id = "bongo-replace" },
        .{
            ._id = "bongo-replace",
            .name = "Mango",
        },
    );
    defer allocator.free(request);

    const message = try op_msg.decode(request);
    const body = try message.body();
    const updates = (try bson.Reader.get(body, "updates")).?.array;
    const spec = (try bson.Reader.get(updates, "0")).?.document;
    const replacement = (try bson.Reader.get(spec, "u")).?.document;

    try std.testing.expect(
        !(try bson.Reader.get(spec, "multi")).?.boolean,
    );
    try std.testing.expect(
        !(try bson.Reader.get(spec, "upsert")).?.boolean,
    );
    try std.testing.expectEqualStrings(
        "Mango",
        (try bson.Reader.get(replacement, "name")).?.string,
    );
}

test "replaceOne encodes upsert true" {
    const allocator = std.testing.allocator;
    const bson = @import("../bson.zig");
    const op_msg = @import("op_msg.zig");

    const request = try encodeReplaceOneWithOptions(
        allocator,
        48,
        "test",
        "users",
        .{ ._id = "bongo-replace" },
        .{ ._id = "bongo-replace", .name = "Mango" },
        true,
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const updates = (try bson.Reader.get(body, "updates")).?.array;
    const spec = (try bson.Reader.get(updates, "0")).?.document;

    try std.testing.expect((try bson.Reader.get(spec, "upsert")).?.boolean);
}

test "replaceOne rejects modifier-style replacement" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.InvalidReplacement,
        encodeReplaceOne(
            allocator,
            47,
            "test",
            "users",
            .{ ._id = "bongo-replace" },
            .{ .@"$set" = .{ .name = "Mango" } },
        ),
    );
}
