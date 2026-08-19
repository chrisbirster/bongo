const std = @import("std");
const bson = @import("../bson.zig");
const Connection = @import("connection.zig").Connection;
const auth = @import("auth.zig");
const compression = @import("compression.zig");
const op_msg = @import("op_msg.zig");
const sasl = @import("sasl.zig");
const scram = @import("scram.zig");
const scram_final = @import("scram_final.zig");
const scram_server = @import("scram_server.zig");

const Allocator = std.mem.Allocator;
const nonce_raw_length = 18;
const nonce_encoded_length = std.base64.standard_no_pad.Encoder.calcSize(nonce_raw_length);

pub const Error = error{
    UnexpectedResponse,
    CommandFailed,
    InvalidClientFirstMessage,
    UnexpectedSaslCompletion,
    ConversationIdMismatch,
    UnsupportedPasswordPreparation,
};

pub const Handshake = struct {
    selected_mechanism: sasl.Mechanism,
    used_speculative_auth: bool,
    selected_compressor: ?compression.Compressor,
};

/// Perform the initial MongoDB authentication handshake for a single SCRAM
/// credential. The hello requests mechanism support, advertises Bongo's zlib
/// codec, and speculatively starts SCRAM-SHA-256 in the same round trip.
pub fn authenticate(
    connection: *Connection,
    allocator: Allocator,
    database: []const u8,
    username: []const u8,
    password: []const u8,
) !Handshake {
    var nonce_raw: [nonce_raw_length]u8 = undefined;
    connection.io.random(&nonce_raw);
    var nonce_buffer: [nonce_encoded_length]u8 = undefined;
    const nonce = std.base64.standard_no_pad.Encoder.encode(&nonce_buffer, &nonce_raw);

    const client_first = try scram.clientFirst(allocator, username, nonce);
    defer allocator.free(client_first);
    if (!std.mem.startsWith(u8, client_first, "n,,")) return error.InvalidClientFirstMessage;

    const request = try encodeRequest(allocator, 900, database, username, client_first);
    defer allocator.free(request);
    const response_bytes = try connection.request(allocator, request);
    defer allocator.free(response_bytes);

    const message = try op_msg.decode(response_bytes);
    if (message.header.response_to != 900) return error.UnexpectedResponse;
    const body = try message.body();
    try requireCommandOk(body);

    const mechanism = try selectMechanism(body);
    const selected_compressor = try selectCompressor(body);

    if (mechanism == .scram_sha_256) {
        if (try speculativeResponse(allocator, body)) |first_value| {
            var first = first_value;
            defer first.deinit(allocator);
            try finishSpeculativeSha256(
                connection,
                allocator,
                database,
                username,
                password,
                nonce,
                client_first,
                &first,
            );
            connection.setCompressor(selected_compressor);
            return .{
                .selected_mechanism = mechanism,
                .used_speculative_auth = true,
                .selected_compressor = selected_compressor,
            };
        }
        try auth.authenticate(connection, allocator, database, username, password);
    } else {
        try auth.authenticateSha1(connection, allocator, database, username, password);
    }

    connection.setCompressor(selected_compressor);
    return .{
        .selected_mechanism = mechanism,
        .used_speculative_auth = false,
        .selected_compressor = selected_compressor,
    };
}

pub fn encodeRequest(
    allocator: Allocator,
    request_id: i32,
    database: []const u8,
    username: []const u8,
    client_first_sha256: []const u8,
) ![]u8 {
    const principal = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ database, username });
    defer allocator.free(principal);
    return op_msg.encodeCommand(
        allocator,
        .{
            .hello = @as(i32, 1),
            .helloOk = true,
            .compression = [_][]const u8{"zlib"},
            .saslSupportedMechs = principal,
            .speculativeAuthenticate = .{
                .saslStart = @as(i32, 1),
                .mechanism = "SCRAM-SHA-256",
                .payload = bson.Binary{ .subtype = .generic, .data = client_first_sha256 },
                .options = .{ .skipEmptyExchange = true },
                .db = database,
            },
            .@"$db" = "admin",
        },
        .{ .request_id = request_id },
    );
}

fn selectMechanism(body: []const u8) !sasl.Mechanism {
    const value = (try bson.Reader.get(body, "saslSupportedMechs")) orelse return .scram_sha_1;
    const array = switch (value) {
        .array => |bytes| bytes,
        else => return .scram_sha_1,
    };
    var reader = try bson.Reader.init(array);
    while (try reader.next()) |element| {
        switch (element.value) {
            .string => |name| if (std.mem.eql(u8, name, "SCRAM-SHA-256")) return .scram_sha_256,
            else => {},
        }
    }
    return .scram_sha_1;
}

fn selectCompressor(body: []const u8) !?compression.Compressor {
    const value = (try bson.Reader.get(body, "compression")) orelse return null;
    const array = switch (value) {
        .array => |bytes| bytes,
        else => return null,
    };
    return compression.select(array);
}

fn speculativeResponse(allocator: Allocator, body: []const u8) !?sasl.Response {
    const value = (try bson.Reader.get(body, "speculativeAuthenticate")) orelse return null;
    const document = switch (value) {
        .document => |bytes| bytes,
        else => return null,
    };
    return try sasl.parseDocument(allocator, document);
}

fn finishSpeculativeSha256(
    connection: *Connection,
    allocator: Allocator,
    database: []const u8,
    username: []const u8,
    password: []const u8,
    nonce: []const u8,
    client_first: []const u8,
    first: *sasl.Response,
) !void {
    _ = username;
    if (first.done) return error.UnexpectedSaslCompletion;
    const prepared_password = try preparePassword(password);
    const server_first = try scram.parseServerFirst(first.payload, nonce);
    const salt = try scram.decodeSalt(allocator, server_first.salt);
    defer allocator.free(salt);
    const salted_password = try scram.saltedPassword(prepared_password, salt, server_first.iterations);
    const client_key = scram.clientKey(&salted_password);
    const stored_key = scram.storedKey(&client_key);
    const final_without_proof = try scram_final.clientFinalWithoutProof(allocator, server_first.nonce);
    defer allocator.free(final_without_proof);
    const auth_message = try scram.authMessage(allocator, client_first[3..], first.payload, final_without_proof);
    defer allocator.free(auth_message);
    const client_signature = scram.clientSignature(&stored_key, auth_message);
    const client_proof = scram.clientProof(&client_key, &client_signature);
    const client_final = try scram_final.clientFinal(allocator, final_without_proof, &client_proof);
    defer allocator.free(client_final);
    const server_key = scram_server.serverKey(&salted_password);
    const expected_server_signature = scram_server.serverSignature(&server_key, auth_message);

    var second = try sasl.continueConversation(connection, allocator, 901, database, first.conversation_id, client_final);
    defer second.deinit(allocator);
    if (second.conversation_id != first.conversation_id) return error.ConversationIdMismatch;
    try scram_server.verifyServerFinal(&expected_server_signature, second.payload);
    if (second.done) return;

    var third = try sasl.continueConversation(connection, allocator, 902, database, first.conversation_id, "");
    defer third.deinit(allocator);
    if (third.conversation_id != first.conversation_id) return error.ConversationIdMismatch;
    if (!third.done) return error.UnexpectedSaslCompletion;
}

fn requireCommandOk(body: []const u8) !void {
    const ok = (try bson.Reader.get(body, "ok")) orelse return error.CommandFailed;
    const succeeded = switch (ok) {
        .double => |value| value == 1.0,
        .int32 => |value| value == 1,
        .int64 => |value| value == 1,
        else => false,
    };
    if (!succeeded) return error.CommandFailed;
}

fn preparePassword(password: []const u8) Error![]const u8 {
    for (password) |byte| if (byte < 0x20 or byte > 0x7e) return error.UnsupportedPasswordPreparation;
    return password;
}

test "auth handshake requests mechanisms speculative SHA-256 and zlib" {
    const bytes = try encodeRequest(std.testing.allocator, 900, "admin", "alice", "n,,n=alice,r=nonce");
    defer std.testing.allocator.free(bytes);
    const message = try op_msg.decode(bytes);
    const body = try message.body();
    try std.testing.expectEqualStrings("admin.alice", (try bson.Reader.get(body, "saslSupportedMechs")).?.string);
    const advertised = (try bson.Reader.get(body, "compression")).?.array;
    var advertised_reader = try bson.Reader.init(advertised);
    const first_compressor = (try advertised_reader.next()).?;
    try std.testing.expectEqualStrings("zlib", first_compressor.value.string);
    const speculative = (try bson.Reader.get(body, "speculativeAuthenticate")).?.document;
    try std.testing.expectEqualStrings("SCRAM-SHA-256", (try bson.Reader.get(speculative, "mechanism")).?.string);
    try std.testing.expectEqualStrings("admin", (try bson.Reader.get(speculative, "db")).?.string);
}

test "mechanism selection prefers SHA-256" {
    const body = try bson.encode(std.testing.allocator, .{
        .saslSupportedMechs = [_][]const u8{ "SCRAM-SHA-1", "SOMETHING-UNKNOWN", "SCRAM-SHA-256" },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqual(sasl.Mechanism.scram_sha_256, try selectMechanism(body));
}

test "mechanism selection falls back to SHA-1" {
    const missing = try bson.encode(std.testing.allocator, .{ .ok = 1 });
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqual(sasl.Mechanism.scram_sha_1, try selectMechanism(missing));
    const unknown_only = try bson.encode(std.testing.allocator, .{ .saslSupportedMechs = [_][]const u8{"UNKNOWN"} });
    defer std.testing.allocator.free(unknown_only);
    try std.testing.expectEqual(sasl.Mechanism.scram_sha_1, try selectMechanism(unknown_only));
}

test "compression selection accepts zlib intersection" {
    const body = try bson.encode(std.testing.allocator, .{ .compression = [_][]const u8{ "snappy", "zlib" } });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqual(compression.Compressor.zlib, (try selectCompressor(body)).?);
}
