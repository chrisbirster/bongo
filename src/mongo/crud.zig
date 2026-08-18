const std = @import("std");
const bson = @import("../bson.zig");
const op_msg = @import("op_msg.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    UnexpectedResponse,
    CommandFailed,
    WriteFailed,
    WriteConcernFailed,
    InvalidWriteErrors,
    MissingCount,
    InvalidCount,
};

pub const InsertOneResult = struct {
    inserted_count: i64,
};

pub fn encodeInsertOne(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    document: anytype,
) ![]u8 {
    const documents = [_]@TypeOf(document){document};

    return encodeInsert(
        allocator,
        request_id,
        database_name,
        collection_name,
        &documents,
        true,
    );
}

pub fn encodeInsert(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    documents: anytype,
    ordered: bool,
) ![]u8 {
    return op_msg.encodeCommand(
        allocator,
        .{
            .insert = collection_name,
            .documents = documents,
            .ordered = ordered,
            .@"$db" = database_name,
        },
        .{
            .request_id = request_id,
        },
    );
}

pub fn parseInsertOneResponse(
    response_bytes: []const u8,
    expected_response_to: i32,
) !InsertOneResult {
    const body = try validatedWriteBody(
        response_bytes,
        expected_response_to,
    );

    return .{
        .inserted_count = try requiredCount(body, "n"),
    };
}

fn validatedWriteBody(
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

    if (try bson.Reader.get(body, "writeErrors")) |value| {
        const write_errors = switch (value) {
            .array => |array| array,
            else => return error.InvalidWriteErrors,
        };

        var reader = try bson.Reader.init(write_errors);
        if ((try reader.next()) != null) return error.WriteFailed;
    }

    if ((try bson.Reader.get(body, "writeConcernError")) != null) {
        return error.WriteConcernFailed;
    }

    return body;
}

fn requiredCount(
    body: []const u8,
    name: []const u8,
) !i64 {
    const value = (try bson.Reader.get(body, name)) orelse
        return error.MissingCount;

    return switch (value) {
        .int32 => |number| number,
        .int64 => |number| number,
        else => error.InvalidCount,
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

test "insertOne command encodes one document" {
    const allocator = std.testing.allocator;

    const request = try encodeInsertOne(
        allocator,
        41,
        "test",
        "users",
        .{
            ._id = "bongo-insert-one",
            .name = "Bongo",
        },
    );
    defer allocator.free(request);

    const message = try op_msg.decode(request);
    const body = try message.body();

    try std.testing.expectEqualStrings(
        "users",
        (try bson.Reader.get(body, "insert")).?.string,
    );
    try std.testing.expectEqualStrings(
        "test",
        (try bson.Reader.get(body, "$db")).?.string,
    );
    try std.testing.expect(
        (try bson.Reader.get(body, "ordered")).?.boolean,
    );

    const documents = (try bson.Reader.get(body, "documents")).?.array;
    const document = (try bson.Reader.get(documents, "0")).?.document;

    try std.testing.expectEqualStrings(
        "bongo-insert-one",
        (try bson.Reader.get(document, "_id")).?.string,
    );
    try std.testing.expectEqualStrings(
        "Bongo",
        (try bson.Reader.get(document, "name")).?.string,
    );
}

test "insert response returns inserted count" {
    const allocator = std.testing.allocator;

    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .n = @as(i32, 1),
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 90,
            .response_to = 41,
        },
    );
    defer allocator.free(response);

    const result = try parseInsertOneResponse(response, 41);
    try std.testing.expectEqual(@as(i64, 1), result.inserted_count);
}

test "insert response surfaces write error" {
    const allocator = std.testing.allocator;

    const WriteError = struct {
        index: i32,
        code: i32,
        errmsg: []const u8,
    };

    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .n = @as(i32, 0),
            .writeErrors = [_]WriteError{
                .{
                    .index = 0,
                    .code = 11000,
                    .errmsg = "duplicate key",
                },
            },
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 91,
            .response_to = 42,
        },
    );
    defer allocator.free(response);

    try std.testing.expectError(
        error.WriteFailed,
        parseInsertOneResponse(response, 42),
    );
}
