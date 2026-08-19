const std = @import("std");
const bson = @import("../bson.zig");
const op_msg = @import("op_msg.zig");
const Connection = @import("connection.zig").Connection;

const Allocator = std.mem.Allocator;

pub const Mechanism = enum {
    scram_sha_1,
    scram_sha_256,

    pub fn wireName(self: Mechanism) []const u8 {
        return switch (self) {
            .scram_sha_1 => "SCRAM-SHA-1",
            .scram_sha_256 => "SCRAM-SHA-256",
        };
    }
};

pub const Error = error{
    UnexpectedResponse,
    CommandFailed,
    MissingConversationId,
    InvalidConversationId,
    MissingDone,
    InvalidDone,
    MissingPayload,
    InvalidPayload,
};

pub const Response = struct {
    conversation_id: i32,
    done: bool,
    payload: []u8,

    pub fn deinit(self: *Response, allocator: Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

pub fn encodeStart(
    allocator: Allocator,
    request_id: i32,
    database: []const u8,
    payload: []const u8,
) ![]u8 {
    return encodeStartWithMechanism(
        allocator,
        request_id,
        database,
        .scram_sha_256,
        payload,
    );
}

pub fn encodeStartWithMechanism(
    allocator: Allocator,
    request_id: i32,
    database: []const u8,
    mechanism: Mechanism,
    payload: []const u8,
) ![]u8 {
    return op_msg.encodeCommand(
        allocator,
        .{
            .saslStart = @as(i32, 1),
            .mechanism = mechanism.wireName(),
            .payload = bson.Binary{
                .subtype = .generic,
                .data = payload,
            },
            .options = .{
                .skipEmptyExchange = true,
            },
            .@"$db" = database,
        },
        .{ .request_id = request_id },
    );
}

pub fn encodeContinue(
    allocator: Allocator,
    request_id: i32,
    database: []const u8,
    conversation_id: i32,
    payload: []const u8,
) ![]u8 {
    return op_msg.encodeCommand(
        allocator,
        .{
            .saslContinue = @as(i32, 1),
            .conversationId = conversation_id,
            .payload = bson.Binary{
                .subtype = .generic,
                .data = payload,
            },
            .@"$db" = database,
        },
        .{ .request_id = request_id },
    );
}

pub fn start(
    connection: *Connection,
    allocator: Allocator,
    request_id: i32,
    database: []const u8,
    payload: []const u8,
) !Response {
    return startWithMechanism(
        connection,
        allocator,
        request_id,
        database,
        .scram_sha_256,
        payload,
    );
}

pub fn startWithMechanism(
    connection: *Connection,
    allocator: Allocator,
    request_id: i32,
    database: []const u8,
    mechanism: Mechanism,
    payload: []const u8,
) !Response {
    const request = try encodeStartWithMechanism(
        allocator,
        request_id,
        database,
        mechanism,
        payload,
    );
    defer allocator.free(request);

    const response_bytes = try connection.request(allocator, request);
    defer allocator.free(response_bytes);

    return parseResponse(allocator, response_bytes, request_id);
}

pub fn continueConversation(
    connection: *Connection,
    allocator: Allocator,
    request_id: i32,
    database: []const u8,
    conversation_id: i32,
    payload: []const u8,
) !Response {
    const request = try encodeContinue(
        allocator,
        request_id,
        database,
        conversation_id,
        payload,
    );
    defer allocator.free(request);

    const response_bytes = try connection.request(allocator, request);
    defer allocator.free(response_bytes);

    return parseResponse(allocator, response_bytes, request_id);
}

/// Parse a normal SASL command response including the top-level `ok` field.
pub fn parseResponse(
    allocator: Allocator,
    response_bytes: []const u8,
    expected_response_to: i32,
) !Response {
    const message = try op_msg.decode(response_bytes);

    if (message.header.response_to != expected_response_to) {
        return error.UnexpectedResponse;
    }

    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse
        return error.CommandFailed;

    const succeeded = switch (ok) {
        .double => |value| value == 1.0,
        .int32 => |value| value == 1,
        .int64 => |value| value == 1,
        else => false,
    };
    if (!succeeded) return error.CommandFailed;

    return parseDocument(allocator, body);
}

/// Parse the common fields of a successful SASL reply document.
///
/// This is also used for the `speculativeAuthenticate` document embedded in
/// the initial MongoDB handshake. That embedded reply intentionally has no
/// top-level `ok` field.
pub fn parseDocument(
    allocator: Allocator,
    document: []const u8,
) !Response {
    const conversation_value =
        (try bson.Reader.get(document, "conversationId")) orelse
        return error.MissingConversationId;

    const conversation_id = switch (conversation_value) {
        .int32 => |value| value,
        else => return error.InvalidConversationId,
    };

    const done_value = (try bson.Reader.get(document, "done")) orelse
        return error.MissingDone;
    const done = switch (done_value) {
        .boolean => |value| value,
        else => return error.InvalidDone,
    };

    const payload_value = (try bson.Reader.get(document, "payload")) orelse
        return error.MissingPayload;
    const payload = switch (payload_value) {
        .binary => |value| blk: {
            if (value.subtype != .generic) return error.InvalidPayload;
            break :blk try allocator.dupe(u8, value.data);
        },
        else => return error.InvalidPayload,
    };

    return .{
        .conversation_id = conversation_id,
        .done = done,
        .payload = payload,
    };
}

test "saslStart encodes SCRAM-SHA-256 binary payload and options" {
    const bytes = try encodeStart(
        std.testing.allocator,
        21,
        "admin",
        "n,,n=user,r=nonce",
    );
    defer std.testing.allocator.free(bytes);

    const message = try op_msg.decode(bytes);
    const body = try message.body();

    try std.testing.expectEqual(
        @as(i32, 1),
        (try bson.Reader.get(body, "saslStart")).?.int32,
    );
    try std.testing.expectEqualStrings(
        "SCRAM-SHA-256",
        (try bson.Reader.get(body, "mechanism")).?.string,
    );

    const payload = (try bson.Reader.get(body, "payload")).?.binary;
    try std.testing.expectEqual(bson.BinarySubtype.generic, payload.subtype);
    try std.testing.expectEqualStrings("n,,n=user,r=nonce", payload.data);

    const options = (try bson.Reader.get(body, "options")).?.document;
    try std.testing.expect(
        (try bson.Reader.get(options, "skipEmptyExchange")).?.boolean,
    );
}

test "saslStart can encode SCRAM-SHA-1" {
    const bytes = try encodeStartWithMechanism(
        std.testing.allocator,
        21,
        "admin",
        .scram_sha_1,
        "n,,n=user,r=nonce",
    );
    defer std.testing.allocator.free(bytes);

    const message = try op_msg.decode(bytes);
    const body = try message.body();
    try std.testing.expectEqualStrings(
        "SCRAM-SHA-1",
        (try bson.Reader.get(body, "mechanism")).?.string,
    );
}

test "saslContinue preserves conversation id and binary payload" {
    const bytes = try encodeContinue(
        std.testing.allocator,
        22,
        "admin",
        7,
        "client-final",
    );
    defer std.testing.allocator.free(bytes);

    const message = try op_msg.decode(bytes);
    const body = try message.body();

    try std.testing.expectEqual(
        @as(i32, 7),
        (try bson.Reader.get(body, "conversationId")).?.int32,
    );
    const payload = (try bson.Reader.get(body, "payload")).?.binary;
    try std.testing.expectEqualStrings("client-final", payload.data);
}

test "SASL response parser copies conversation payload" {
    const bytes = try op_msg.encodeCommand(
        std.testing.allocator,
        .{
            .conversationId = @as(i32, 7),
            .done = false,
            .payload = bson.Binary{
                .subtype = .generic,
                .data = "server-first",
            },
            .ok = @as(f64, 1.0),
        },
        .{ .request_id = 100, .response_to = 21 },
    );
    defer std.testing.allocator.free(bytes);

    var response = try parseResponse(
        std.testing.allocator,
        bytes,
        21,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 7), response.conversation_id);
    try std.testing.expect(!response.done);
    try std.testing.expectEqualStrings("server-first", response.payload);
}

test "embedded speculative SASL reply does not require ok" {
    const bytes = try bson.encode(
        std.testing.allocator,
        .{
            .conversationId = @as(i32, 9),
            .done = false,
            .payload = bson.Binary{
                .subtype = .generic,
                .data = "speculative-server-first",
            },
        },
    );
    defer std.testing.allocator.free(bytes);

    var response = try parseDocument(std.testing.allocator, bytes);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 9), response.conversation_id);
    try std.testing.expectEqualStrings("speculative-server-first", response.payload);
}
