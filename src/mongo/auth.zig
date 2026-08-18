const std = @import("std");
const Connection = @import("connection.zig").Connection;
const scram = @import("scram.zig");
const scram_final = @import("scram_final.zig");
const scram_server = @import("scram_server.zig");
const sasl = @import("sasl.zig");

const Allocator = std.mem.Allocator;
const nonce_raw_length = 18;
const nonce_encoded_length =
    std.base64.standard_no_pad.Encoder.calcSize(nonce_raw_length);

comptime {
    std.debug.assert(nonce_encoded_length == 24);
}

pub const Error = error{
    EmptyUsername,
    UnsupportedPasswordPreparation,
    InvalidClientFirstMessage,
    UnexpectedSaslCompletion,
    ConversationIdMismatch,
};

/// Authenticate one MongoDB connection with SCRAM-SHA-256.
///
/// This first implementation accepts ASCII passwords that pass through
/// SASLprep unchanged. Non-ASCII password preparation is rejected explicitly
/// until Bongo implements the complete SASLprep profile.
pub fn authenticate(
    connection: *Connection,
    allocator: Allocator,
    database: []const u8,
    username: []const u8,
    password: []const u8,
) !void {
    if (username.len == 0) return error.EmptyUsername;
    const prepared_password = try preparePassword(password);

    var nonce_raw: [nonce_raw_length]u8 = undefined;
    std.crypto.random.bytes(&nonce_raw);

    var nonce_buffer: [nonce_encoded_length]u8 = undefined;
    const nonce = std.base64.standard_no_pad.Encoder.encode(
        &nonce_buffer,
        &nonce_raw,
    );

    std.debug.assert(nonce.len == nonce_encoded_length);

    const client_first = try scram.clientFirst(
        allocator,
        username,
        nonce,
    );
    defer allocator.free(client_first);

    if (!std.mem.startsWith(u8, client_first, "n,,")) {
        return error.InvalidClientFirstMessage;
    }

    const client_first_bare = client_first[3..];

    var first = try sasl.start(
        connection,
        allocator,
        1000,
        database,
        client_first,
    );
    defer first.deinit(allocator);

    if (first.done) return error.UnexpectedSaslCompletion;

    const server_first = try scram.parseServerFirst(
        first.payload,
        nonce,
    );

    const salt = try scram.decodeSalt(
        allocator,
        server_first.salt,
    );
    defer allocator.free(salt);

    const salted_password = try scram.saltedPassword(
        prepared_password,
        salt,
        server_first.iterations,
    );

    const client_key = scram.clientKey(&salted_password);
    const stored_key = scram.storedKey(&client_key);

    const final_without_proof = try scram_final.clientFinalWithoutProof(
        allocator,
        server_first.nonce,
    );
    defer allocator.free(final_without_proof);

    const auth_message = try scram.authMessage(
        allocator,
        client_first_bare,
        first.payload,
        final_without_proof,
    );
    defer allocator.free(auth_message);

    const client_signature = scram.clientSignature(
        &stored_key,
        auth_message,
    );

    const client_proof = scram.clientProof(
        &client_key,
        &client_signature,
    );

    const client_final = try scram_final.clientFinal(
        allocator,
        final_without_proof,
        &client_proof,
    );
    defer allocator.free(client_final);

    const server_key = scram_server.serverKey(&salted_password);
    const expected_server_signature = scram_server.serverSignature(
        &server_key,
        auth_message,
    );

    var second = try sasl.continueConversation(
        connection,
        allocator,
        1001,
        database,
        first.conversation_id,
        client_final,
    );
    defer second.deinit(allocator);

    if (second.conversation_id != first.conversation_id) {
        return error.ConversationIdMismatch;
    }

    try scram_server.verifyServerFinal(
        &expected_server_signature,
        second.payload,
    );

    if (second.done) return;

    // Older MongoDB servers may require the historical empty third exchange
    // even when `skipEmptyExchange` was sent in saslStart.
    var third = try sasl.continueConversation(
        connection,
        allocator,
        1002,
        database,
        first.conversation_id,
        "",
    );
    defer third.deinit(allocator);

    if (third.conversation_id != first.conversation_id) {
        return error.ConversationIdMismatch;
    }

    if (!third.done) return error.UnexpectedSaslCompletion;
}

fn preparePassword(password: []const u8) Error![]const u8 {
    for (password) |byte| {
        if (byte < 0x20 or byte > 0x7e) {
            return error.UnsupportedPasswordPreparation;
        }
    }

    return password;
}

test "SCRAM password preparation accepts unchanged ASCII password" {
    const result = try preparePassword("secretpassword");
    try std.testing.expectEqualStrings("secretpassword", result);
}

test "SCRAM password preparation rejects unsupported non-ASCII input" {
    try std.testing.expectError(
        error.UnsupportedPasswordPreparation,
        preparePassword("p\xc3\xa4ssword"),
    );
}
