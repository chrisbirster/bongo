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
    InvalidUpserted,
    MissingUpsertedId,
};

pub const InsertOneResult = struct {
    inserted_count: i64,
};

pub const InsertManyResult = struct {
    inserted_count: i64,
};

pub const UpsertedId = struct {
    allocator: Allocator,
    value: bson.Value,
    owned_a: ?[]u8 = null,
    owned_b: ?[]u8 = null,

    pub fn deinit(self: *UpsertedId) void {
        if (self.owned_a) |bytes| self.allocator.free(bytes);
        if (self.owned_b) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }
};

pub const UpdateResult = struct {
    matched_count: i64,
    modified_count: i64,
    upserted_count: i64 = 0,
    upserted_id: ?UpsertedId = null,

    pub fn deinit(self: *UpdateResult) void {
        if (self.upserted_id) |*id| id.deinit();
        self.* = undefined;
    }
};

pub const DeleteResult = struct {
    deleted_count: i64,
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

pub fn encodeUpdateOne(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    update: anytype,
) ![]u8 {
    return encodeUpdate(
        allocator,
        request_id,
        database_name,
        collection_name,
        filter,
        update,
        false,
        false,
    );
}

pub fn encodeUpdate(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    update: anytype,
    multi: bool,
    upsert: bool,
) ![]u8 {
    const UpdateSpec = struct {
        q: @TypeOf(filter),
        u: @TypeOf(update),
        multi: bool,
        upsert: bool,
    };

    const updates = [_]UpdateSpec{
        .{
            .q = filter,
            .u = update,
            .multi = multi,
            .upsert = upsert,
        },
    };

    return op_msg.encodeCommand(
        allocator,
        .{
            .update = collection_name,
            .updates = &updates,
            .ordered = true,
            .@"$db" = database_name,
        },
        .{
            .request_id = request_id,
        },
    );
}

pub fn encodeDeleteOne(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
) ![]u8 {
    return encodeDelete(
        allocator,
        request_id,
        database_name,
        collection_name,
        filter,
        1,
    );
}

pub fn encodeDelete(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    filter: anytype,
    limit: i32,
) ![]u8 {
    std.debug.assert(limit == 0 or limit == 1);

    const DeleteSpec = struct {
        q: @TypeOf(filter),
        limit: i32,
    };

    const deletes = [_]DeleteSpec{
        .{
            .q = filter,
            .limit = limit,
        },
    };

    return op_msg.encodeCommand(
        allocator,
        .{
            .delete = collection_name,
            .deletes = &deletes,
            .ordered = true,
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

pub fn parseInsertManyResponse(
    response_bytes: []const u8,
    expected_response_to: i32,
) !InsertManyResult {
    const body = try validatedWriteBody(
        response_bytes,
        expected_response_to,
    );

    return .{
        .inserted_count = try requiredCount(body, "n"),
    };
}

pub fn parseUpdateResponse(
    allocator: Allocator,
    response_bytes: []const u8,
    expected_response_to: i32,
) !UpdateResult {
    const body = try validatedWriteBody(
        response_bytes,
        expected_response_to,
    );

    const affected_count = try requiredCount(body, "n");
    const modified_count = try requiredCount(body, "nModified");
    var upserted = try parseUpserted(allocator, body);
    errdefer {
        if (upserted.id) |*id| id.deinit();
    }

    if (affected_count < upserted.count) return error.InvalidCount;

    return .{
        .matched_count = affected_count - upserted.count,
        .modified_count = modified_count,
        .upserted_count = upserted.count,
        .upserted_id = upserted.id,
    };
}

pub fn parseDeleteResponse(
    response_bytes: []const u8,
    expected_response_to: i32,
) !DeleteResult {
    const body = try validatedWriteBody(
        response_bytes,
        expected_response_to,
    );

    return .{
        .deleted_count = try requiredCount(body, "n"),
    };
}

const ParsedUpserted = struct {
    count: i64,
    id: ?UpsertedId,
};

fn parseUpserted(
    allocator: Allocator,
    body: []const u8,
) !ParsedUpserted {
    const value = (try bson.Reader.get(body, "upserted")) orelse {
        return .{ .count = 0, .id = null };
    };

    const array = switch (value) {
        .array => |bytes| bytes,
        else => return error.InvalidUpserted,
    };
    try bson.validateArray(array);

    var reader = try bson.Reader.init(array);
    const first = (try reader.next()) orelse {
        return .{ .count = 0, .id = null };
    };
    if ((try reader.next()) != null) return error.InvalidUpserted;

    const document = switch (first.value) {
        .document => |bytes| bytes,
        else => return error.InvalidUpserted,
    };
    const id_value = (try bson.Reader.get(document, "_id")) orelse
        return error.MissingUpsertedId;

    return .{
        .count = 1,
        .id = try cloneValue(allocator, id_value),
    };
}

fn cloneValue(allocator: Allocator, value: bson.Value) !UpsertedId {
    var result = UpsertedId{
        .allocator = allocator,
        .value = value,
    };
    errdefer result.deinit();

    switch (value) {
        .string => |bytes| {
            const copy = try allocator.dupe(u8, bytes);
            result.owned_a = copy;
            result.value = .{ .string = copy };
        },
        .document => |bytes| {
            const copy = try allocator.dupe(u8, bytes);
            result.owned_a = copy;
            result.value = .{ .document = copy };
        },
        .array => |bytes| {
            const copy = try allocator.dupe(u8, bytes);
            result.owned_a = copy;
            result.value = .{ .array = copy };
        },
        .binary => |binary| {
            const copy = try allocator.dupe(u8, binary.data);
            result.owned_a = copy;
            result.value = .{ .binary = .{
                .subtype = binary.subtype,
                .data = copy,
            } };
        },
        .regex => |regex| {
            const pattern = try allocator.dupe(u8, regex.pattern);
            result.owned_a = pattern;
            const options = try allocator.dupe(u8, regex.options);
            result.owned_b = options;
            result.value = .{ .regex = .{
                .pattern = pattern,
                .options = options,
            } };
        },
        .db_pointer => |pointer| {
            const namespace = try allocator.dupe(u8, pointer.namespace);
            result.owned_a = namespace;
            result.value = .{ .db_pointer = .{
                .namespace = namespace,
                .id = pointer.id,
            } };
        },
        .javascript => |javascript| {
            const code = try allocator.dupe(u8, javascript.code);
            result.owned_a = code;
            result.value = .{ .javascript = .{ .code = code } };
        },
        .symbol => |symbol| {
            const bytes = try allocator.dupe(u8, symbol.value);
            result.owned_a = bytes;
            result.value = .{ .symbol = .{ .value = bytes } };
        },
        .javascript_with_scope => |javascript| {
            const code = try allocator.dupe(u8, javascript.code);
            result.owned_a = code;
            const scope = try allocator.dupe(u8, javascript.scope);
            result.owned_b = scope;
            result.value = .{ .javascript_with_scope = .{
                .code = code,
                .scope = scope,
            } };
        },
        else => {},
    }

    return result;
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
        else => return error.InvalidCount,
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
    const documents = (try bson.Reader.get(body, "documents")).?.array;
    const document = (try bson.Reader.get(documents, "0")).?.document;

    try std.testing.expectEqualStrings(
        "users",
        (try bson.Reader.get(body, "insert")).?.string,
    );
    try std.testing.expectEqualStrings(
        "bongo-insert-one",
        (try bson.Reader.get(document, "_id")).?.string,
    );
}

test "insertMany command encodes multiple ordered documents" {
    const allocator = std.testing.allocator;
    const Document = struct {
        name: []const u8,
    };
    const documents = [_]Document{
        .{ .name = "Bongo" },
        .{ .name = "Mango" },
    };

    const request = try encodeInsert(
        allocator,
        42,
        "test",
        "users",
        &documents,
        true,
    );
    defer allocator.free(request);

    const message = try op_msg.decode(request);
    const body = try message.body();
    const encoded = (try bson.Reader.get(body, "documents")).?.array;

    try std.testing.expect((try bson.Reader.get(body, "ordered")).?.boolean);
    try std.testing.expect((try bson.Reader.get(encoded, "0")) != null);
    try std.testing.expect((try bson.Reader.get(encoded, "1")) != null);
}

test "insert response returns inserted count" {
    const allocator = std.testing.allocator;
    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .n = @as(i32, 2),
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 90,
            .response_to = 42,
        },
    );
    defer allocator.free(response);

    const result = try parseInsertManyResponse(response, 42);
    try std.testing.expectEqual(@as(i64, 2), result.inserted_count);
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
            .response_to = 43,
        },
    );
    defer allocator.free(response);

    try std.testing.expectError(
        error.WriteFailed,
        parseInsertOneResponse(response, 43),
    );
}

test "updateOne command encodes filter update and multi false" {
    const allocator = std.testing.allocator;
    const request = try encodeUpdateOne(
        allocator,
        44,
        "test",
        "users",
        .{ .name = "Bongo" },
        .{ .@"$set" = .{ .active = true } },
    );
    defer allocator.free(request);

    const message = try op_msg.decode(request);
    const body = try message.body();
    const updates = (try bson.Reader.get(body, "updates")).?.array;
    const spec = (try bson.Reader.get(updates, "0")).?.document;

    try std.testing.expect(
        !(try bson.Reader.get(spec, "multi")).?.boolean,
    );
    try std.testing.expect(
        !(try bson.Reader.get(spec, "upsert")).?.boolean,
    );
}

test "update command encodes upsert true" {
    const allocator = std.testing.allocator;
    const request = try encodeUpdate(
        allocator,
        45,
        "test",
        "users",
        .{ .name = "Bongo" },
        .{ .@"$set" = .{ .active = true } },
        false,
        true,
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const updates = (try bson.Reader.get(body, "updates")).?.array;
    const spec = (try bson.Reader.get(updates, "0")).?.document;

    try std.testing.expect((try bson.Reader.get(spec, "upsert")).?.boolean);
}

test "update response returns matched and modified counts" {
    const allocator = std.testing.allocator;
    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .n = @as(i32, 1),
            .nModified = @as(i32, 1),
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 92,
            .response_to = 44,
        },
    );
    defer allocator.free(response);

    var result = try parseUpdateResponse(allocator, response, 44);
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 1), result.matched_count);
    try std.testing.expectEqual(@as(i64, 1), result.modified_count);
    try std.testing.expectEqual(@as(i64, 0), result.upserted_count);
    try std.testing.expect(result.upserted_id == null);
}

test "update response separates upsert from matched count" {
    const allocator = std.testing.allocator;
    const Upserted = struct {
        index: i32,
        _id: []const u8,
    };
    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .n = @as(i32, 1),
            .nModified = @as(i32, 0),
            .upserted = [_]Upserted{.{
                .index = 0,
                ._id = "bongo-upsert",
            }},
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 93,
            .response_to = 45,
        },
    );
    defer allocator.free(response);

    var result = try parseUpdateResponse(allocator, response, 45);
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 0), result.matched_count);
    try std.testing.expectEqual(@as(i64, 0), result.modified_count);
    try std.testing.expectEqual(@as(i64, 1), result.upserted_count);
    try std.testing.expectEqualStrings(
        "bongo-upsert",
        result.upserted_id.?.value.string,
    );
}

test "deleteOne command encodes filter and limit one" {
    const allocator = std.testing.allocator;
    const request = try encodeDeleteOne(
        allocator,
        46,
        "test",
        "users",
        .{ .name = "Bongo" },
    );
    defer allocator.free(request);

    const message = try op_msg.decode(request);
    const body = try message.body();
    const deletes = (try bson.Reader.get(body, "deletes")).?.array;
    const spec = (try bson.Reader.get(deletes, "0")).?.document;

    try std.testing.expectEqual(
        @as(i32, 1),
        (try bson.Reader.get(spec, "limit")).?.int32,
    );
}

test "delete response returns deleted count" {
    const allocator = std.testing.allocator;
    const response = try op_msg.encodeCommand(
        allocator,
        .{
            .n = @as(i32, 1),
            .ok = @as(f64, 1.0),
        },
        .{
            .request_id = 94,
            .response_to = 46,
        },
    );
    defer allocator.free(response);

    const result = try parseDeleteResponse(response, 46);
    try std.testing.expectEqual(@as(i64, 1), result.deleted_count);
}
