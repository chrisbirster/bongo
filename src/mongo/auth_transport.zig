const std = @import("std");
const scram = @import("scram.zig");
const scram_final = @import("scram_final.zig");
const scram_server = @import("scram_server.zig");
const sasl = @import("sasl.zig");
const Transport = @import("transport.zig").Transport;

const Allocator = std.mem.Allocator;
const nonce_raw_length = 18;
const nonce_encoded_length = std.base64.standard_no_pad.Encoder.calcSize(nonce_raw_length);

pub const Error = error{
    EmptyUsername,
    UnsupportedPasswordPreparation,
    InvalidClientFirstMessage,
    UnexpectedSaslCompletion,
    ConversationIdMismatch,
};

/// SCRAM-SHA-256 authentication over either plain TCP or TLS.
///
/// The historical `auth.zig` entry point remains for the original concrete
/// TCP `Connection`; this transport-generic form is used by TLS and the
/// managed client without forcing the legacy client API to change at once.
pub fn authenticate(
    transport: *Transport,
    allocator: Allocator,
    database: []const u8,
    username: []const u8,
    password: []const u8,
) !void {
    if (username.len == 0) return error.EmptyUsername;
    const prepared_password = try preparePassword(password);

    var nonce_raw: [nonce_raw_length]u8 = undefined;
    transport.io().random(&nonce_raw);

    var nonce_buffer: [nonce_encoded_length]u8 = undefined;
    const nonce = std.base64.standard_no_pad.Encoder.encode(&nonce_buffer, &nonce_raw);

    const client_first = try scram.clientFirst(allocator, username, nonce);
    defer allocator.free(client_first);
    if (!std.mem.startsWith(u8, client_first, "n,,")) {
        return error.InvalidClientFirstMessage;
    }
    const client_first_bare = client_first[3..];

    var first = try saslStart(
        transport,
        allocator,
        1000,
        database,
        client_first,
    );
    defer first.deinit(allocator);
    if (first.done) return error.UnexpectedSaslCompletion;

    const server_first = try scram.parseServerFirst(first.payload, nonce);
    const salt = try scram.decodeSalt(allocator, server_first.salt);
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

    const client_signature = scram.clientSignature(&stored_key, auth_message);
    const client_proof = scram.clientProof(&client_key, &client_signature);
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

    var second = try saslContinue(
        transport,
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
    try scram_server.verifyServerFinal(&expected_server_signature, second.payload);
    if (second.done) return;

    var third = try saslContinue(
        transport,
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

fn saslStart(
    transport: *Transport,
    allocator: Allocator,
    request_id: i32,
    database: []const u8,
    payload: []const u8,
) !sasl.Response {
    const request = try sasl.encodeStart(allocator, request_id, database, payload);
    defer allocator.free(request);
    const response = try transport.request(allocator, request);
    defer allocator.free(response);
    return sasl.parseResponse(allocator, response, request_id);
}

fn saslContinue(
    transport: *Transport,
    allocator: Allocator,
    request_id: i32,
    database: []const u8,
    conversation_id: i32,
    payload: []const u8,
) !sasl.Response {
    const request = try sasl.encodeContinue(
        allocator,
        request_id,
        database,
        conversation_id,
        payload,
    );
    defer allocator.free(request);
    const response = try transport.request(allocator, request);
    defer allocator.free(response);
    return sasl.parseResponse(allocator, response, request_id);
}

fn preparePassword(password: []const u8) Error![]const u8 {
    for (password) |byte| {
        if (byte < 0x20 or byte > 0x7e) {
            return error.UnsupportedPasswordPreparation;
        }
    }
    return password;
}

test "transport auth password preparation rejects unsupported non-ASCII" {
    try std.testing.expectError(
        error.UnsupportedPasswordPreparation,
        preparePassword("p\xc3\xa4ssword"),
    );
}
