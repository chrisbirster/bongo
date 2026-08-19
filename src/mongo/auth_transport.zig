const std = @import("std");
const scram = @import("scram.zig");
const scram_final = @import("scram_final.zig");
const scram_server = @import("scram_server.zig");
const scram_sha1 = @import("scram_sha1.zig");
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

pub fn authenticate(
    transport: *Transport,
    allocator: Allocator,
    database: []const u8,
    username: []const u8,
    password: []const u8,
) !void {
    if (username.len == 0) return error.EmptyUsername;
    const prepared_password = try preparePassword(password);
    const nonce = newNonce(transport);

    const client_first = try scram.clientFirst(allocator, username, &nonce);
    defer allocator.free(client_first);
    if (!std.mem.startsWith(u8, client_first, "n,,")) return error.InvalidClientFirstMessage;
    const client_first_bare = client_first[3..];

    var first = try saslStartWithMechanism(
        transport,
        allocator,
        1000,
        database,
        .scram_sha_256,
        client_first,
    );
    defer first.deinit(allocator);
    if (first.done) return error.UnexpectedSaslCompletion;

    const server_first = try scram.parseServerFirst(first.payload, &nonce);
    const salt = try scram.decodeSalt(allocator, server_first.salt);
    defer allocator.free(salt);
    const salted_password = try scram.saltedPassword(prepared_password, salt, server_first.iterations);
    const client_key = scram.clientKey(&salted_password);
    const stored_key = scram.storedKey(&client_key);
    const final_without_proof = try scram_final.clientFinalWithoutProof(allocator, server_first.nonce);
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
    const client_final = try scram_final.clientFinal(allocator, final_without_proof, &client_proof);
    defer allocator.free(client_final);
    const server_key = scram_server.serverKey(&salted_password);
    const expected_server_signature = scram_server.serverSignature(&server_key, auth_message);

    var second = try saslContinue(
        transport,
        allocator,
        1001,
        database,
        first.conversation_id,
        client_final,
    );
    defer second.deinit(allocator);
    if (second.conversation_id != first.conversation_id) return error.ConversationIdMismatch;
    try scram_server.verifyServerFinal(&expected_server_signature, second.payload);
    if (second.done) return;
    try finishEmptyExchange(transport, allocator, database, first.conversation_id);
}

pub fn authenticateSha1(
    transport: *Transport,
    allocator: Allocator,
    database: []const u8,
    username: []const u8,
    password: []const u8,
) !void {
    if (username.len == 0) return error.EmptyUsername;
    const mongo_password = try scram_sha1.mongoPasswordDigest(allocator, username, password);
    defer allocator.free(mongo_password);
    const nonce = newNonce(transport);

    const client_first = try scram.clientFirst(allocator, username, &nonce);
    defer allocator.free(client_first);
    if (!std.mem.startsWith(u8, client_first, "n,,")) return error.InvalidClientFirstMessage;
    const client_first_bare = client_first[3..];

    var first = try saslStartWithMechanism(
        transport,
        allocator,
        1000,
        database,
        .scram_sha_1,
        client_first,
    );
    defer first.deinit(allocator);
    if (first.done) return error.UnexpectedSaslCompletion;

    const server_first = try scram.parseServerFirst(first.payload, &nonce);
    const salt = try scram.decodeSalt(allocator, server_first.salt);
    defer allocator.free(salt);
    const salted_password = try scram_sha1.saltedPassword(
        mongo_password,
        salt,
        server_first.iterations,
    );
    const client_key = scram_sha1.clientKey(&salted_password);
    const stored_key = scram_sha1.storedKey(&client_key);
    const final_without_proof = try scram_final.clientFinalWithoutProof(allocator, server_first.nonce);
    defer allocator.free(final_without_proof);
    const auth_message = try scram.authMessage(
        allocator,
        client_first_bare,
        first.payload,
        final_without_proof,
    );
    defer allocator.free(auth_message);
    const client_signature = scram_sha1.clientSignature(&stored_key, auth_message);
    const client_proof = scram_sha1.clientProof(&client_key, &client_signature);
    const client_final = try scram_sha1.clientFinal(allocator, final_without_proof, &client_proof);
    defer allocator.free(client_final);
    const server_key = scram_sha1.serverKey(&salted_password);
    const expected_server_signature = scram_sha1.serverSignature(&server_key, auth_message);

    var second = try saslContinue(
        transport,
        allocator,
        1001,
        database,
        first.conversation_id,
        client_final,
    );
    defer second.deinit(allocator);
    if (second.conversation_id != first.conversation_id) return error.ConversationIdMismatch;
    try scram_sha1.verifyServerFinal(&expected_server_signature, second.payload);
    if (second.done) return;
    try finishEmptyExchange(transport, allocator, database, first.conversation_id);
}

fn newNonce(transport: *Transport) [nonce_encoded_length]u8 {
    var raw: [nonce_raw_length]u8 = undefined;
    const io = transport.io();
    io.random(&raw);
    var encoded: [nonce_encoded_length]u8 = undefined;
    _ = std.base64.standard_no_pad.Encoder.encode(&encoded, &raw);
    return encoded;
}

fn saslStartWithMechanism(
    transport: *Transport,
    allocator: Allocator,
    request_id: i32,
    database: []const u8,
    mechanism: sasl.Mechanism,
    payload: []const u8,
) !sasl.Response {
    const request = try sasl.encodeStartWithMechanism(
        allocator,
        request_id,
        database,
        mechanism,
        payload,
    );
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

fn finishEmptyExchange(
    transport: *Transport,
    allocator: Allocator,
    database: []const u8,
    conversation_id: i32,
) !void {
    var third = try saslContinue(
        transport,
        allocator,
        1002,
        database,
        conversation_id,
        "",
    );
    defer third.deinit(allocator);
    if (third.conversation_id != conversation_id) return error.ConversationIdMismatch;
    if (!third.done) return error.UnexpectedSaslCompletion;
}

fn preparePassword(password: []const u8) Error![]const u8 {
    for (password) |byte| {
        if (byte < 0x20 or byte > 0x7e) return error.UnsupportedPasswordPreparation;
    }
    return password;
}

test "transport auth password preparation rejects unsupported non-ASCII" {
    try std.testing.expectError(
        error.UnsupportedPasswordPreparation,
        preparePassword("p\xc3\xa4ssword"),
    );
}
