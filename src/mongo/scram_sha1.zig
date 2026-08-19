const std = @import("std");

const Allocator = std.mem.Allocator;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const Sha1 = std.crypto.hash.Sha1;
const Md5 = std.crypto.hash.Md5;

pub const digest_length = HmacSha1.mac_length;

comptime {
    std.debug.assert(digest_length == 20);
    std.debug.assert(digest_length == Sha1.digest_length);
}

pub const Error = Allocator.Error || error{
    InvalidIterationCount,
    InvalidServerFinalMessage,
    ServerAuthenticationFailed,
    InvalidServerVerifier,
    ServerSignatureMismatch,
};

/// MongoDB SCRAM-SHA-1 uses the lowercase hexadecimal MD5 digest of
/// `username + ":mongo:" + password` as the SCRAM password input.
///
/// The returned slice is owned by the caller.
pub fn mongoPasswordDigest(
    allocator: Allocator,
    username: []const u8,
    password: []const u8,
) Allocator.Error![]u8 {
    const input = try std.fmt.allocPrint(
        allocator,
        "{s}:mongo:{s}",
        .{ username, password },
    );
    defer allocator.free(input);

    var digest: [Md5.digest_length]u8 = undefined;
    Md5.hash(input, &digest, .{});

    const encoded = try allocator.alloc(u8, digest.len * 2);
    for (digest, 0..) |byte, index| {
        encoded[index * 2] = lowerHex(byte >> 4);
        encoded[index * 2 + 1] = lowerHex(byte & 0x0f);
    }
    return encoded;
}

pub fn saltedPassword(
    mongo_password_digest: []const u8,
    salt: []const u8,
    iterations: u32,
) error{InvalidIterationCount}![digest_length]u8 {
    if (iterations < 4096) return error.InvalidIterationCount;

    var result: [digest_length]u8 = undefined;
    std.crypto.pwhash.pbkdf2(
        &result,
        mongo_password_digest,
        salt,
        iterations,
        HmacSha1,
    ) catch unreachable;
    return result;
}

pub fn clientKey(
    salted_password: *const [digest_length]u8,
) [digest_length]u8 {
    var result: [digest_length]u8 = undefined;
    HmacSha1.create(&result, "Client Key", salted_password[0..]);
    return result;
}

pub fn storedKey(
    client_key: *const [digest_length]u8,
) [digest_length]u8 {
    var result: [digest_length]u8 = undefined;
    Sha1.hash(client_key[0..], &result, .{});
    return result;
}

pub fn clientSignature(
    stored_key: *const [digest_length]u8,
    auth_message: []const u8,
) [digest_length]u8 {
    var result: [digest_length]u8 = undefined;
    HmacSha1.create(&result, auth_message, stored_key[0..]);
    return result;
}

pub fn clientProof(
    client_key: *const [digest_length]u8,
    client_signature: *const [digest_length]u8,
) [digest_length]u8 {
    var result: [digest_length]u8 = undefined;
    for (result[0..], client_key[0..], client_signature[0..]) |
        *result_byte,
        key_byte,
        signature_byte,
    | {
        result_byte.* = key_byte ^ signature_byte;
    }
    return result;
}

pub fn serverKey(
    salted_password: *const [digest_length]u8,
) [digest_length]u8 {
    var result: [digest_length]u8 = undefined;
    HmacSha1.create(&result, "Server Key", salted_password[0..]);
    return result;
}

pub fn serverSignature(
    server_key: *const [digest_length]u8,
    auth_message: []const u8,
) [digest_length]u8 {
    var result: [digest_length]u8 = undefined;
    HmacSha1.create(&result, auth_message, server_key[0..]);
    return result;
}

pub fn clientFinal(
    allocator: Allocator,
    client_final_without_proof: []const u8,
    client_proof: *const [digest_length]u8,
) Allocator.Error![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(digest_length);
    var encoded_buffer: [std.base64.standard.Encoder.calcSize(digest_length)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(
        &encoded_buffer,
        client_proof[0..],
    );
    std.debug.assert(encoded.len == encoded_len);

    return std.fmt.allocPrint(
        allocator,
        "{s},p={s}",
        .{ client_final_without_proof, encoded },
    );
}

pub fn verifyServerFinal(
    expected_signature: *const [digest_length]u8,
    server_final_message: []const u8,
) Error!void {
    var verifier: ?[]const u8 = null;
    var server_error: ?[]const u8 = null;

    var fields = std.mem.splitScalar(u8, server_final_message, ',');
    while (fields.next()) |field| {
        if (field.len < 3 or field[1] != '=') {
            return error.InvalidServerFinalMessage;
        }

        const value = field[2..];
        switch (field[0]) {
            'v' => {
                if (verifier != null) return error.InvalidServerFinalMessage;
                verifier = value;
            },
            'e' => {
                if (server_error != null) return error.InvalidServerFinalMessage;
                server_error = value;
            },
            else => {},
        }
    }

    if (verifier != null and server_error != null) {
        return error.InvalidServerFinalMessage;
    }

    if (server_error) |value| {
        if (value.len == 0) return error.InvalidServerFinalMessage;
        return error.ServerAuthenticationFailed;
    }

    const encoded = verifier orelse return error.InvalidServerFinalMessage;
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch {
        return error.InvalidServerVerifier;
    };
    if (decoded_len != digest_length) return error.InvalidServerVerifier;

    var decoded: [digest_length]u8 = undefined;
    decoder.decode(&decoded, encoded) catch return error.InvalidServerVerifier;

    if (!std.crypto.timing_safe.eql(
        [digest_length]u8,
        expected_signature.*,
        decoded,
    )) {
        return error.ServerSignatureMismatch;
    }
}

fn lowerHex(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

test "MongoDB SCRAM-SHA-1 password digest matches reference value" {
    const digest = try mongoPasswordDigest(
        std.testing.allocator,
        "user",
        "pencil",
    );
    defer std.testing.allocator.free(digest);

    try std.testing.expectEqualStrings(
        "1c33006ec1ffd90f9cadcbcc0e118200",
        digest,
    );
}

test "SCRAM-SHA-1 salted password and keys match deterministic conversation" {
    const digest = try mongoPasswordDigest(
        std.testing.allocator,
        "user",
        "pencil",
    );
    defer std.testing.allocator.free(digest);

    const salt = [_]u8{
        0x5b, 0x6d, 0x99, 0x68, 0x9d, 0x12, 0x35, 0x8e,
        0xec, 0xa0, 0x4b, 0x14, 0x12, 0x36, 0xfa, 0x81,
    };

    const salted = try saltedPassword(digest, &salt, 4096);
    const expected_salted = [_]u8{
        0x1e, 0xac, 0xaf, 0xf1, 0x71, 0x8b, 0x73, 0xaf,
        0x15, 0x34, 0xd8, 0x25, 0x38, 0x03, 0xf3, 0x43,
        0x1b, 0x32, 0xce, 0x08,
    };
    try std.testing.expectEqualSlices(u8, &expected_salted, &salted);

    const client_key = clientKey(&salted);
    const expected_client_key = [_]u8{
        0xc5, 0x74, 0xef, 0x20, 0xfa, 0x4a, 0xab, 0xc0,
        0xb2, 0xa8, 0x6c, 0x8e, 0x99, 0x1e, 0x79, 0x49,
        0xdc, 0x95, 0xb0, 0x53,
    };
    try std.testing.expectEqualSlices(u8, &expected_client_key, &client_key);

    const stored_key = storedKey(&client_key);
    const expected_stored_key = [_]u8{
        0xe4, 0xd8, 0x05, 0x7b, 0xf4, 0x7a, 0xe6, 0x11,
        0x6c, 0x2b, 0x13, 0x72, 0x06, 0xdd, 0xc0, 0xb7,
        0x60, 0x22, 0x43, 0x2f,
    };
    try std.testing.expectEqualSlices(u8, &expected_stored_key, &stored_key);
}

test "SCRAM-SHA-1 proof and server verifier match deterministic conversation" {
    const salted = [_]u8{
        0x1e, 0xac, 0xaf, 0xf1, 0x71, 0x8b, 0x73, 0xaf,
        0x15, 0x34, 0xd8, 0x25, 0x38, 0x03, 0xf3, 0x43,
        0x1b, 0x32, 0xce, 0x08,
    };
    const client_key = clientKey(&salted);
    const stored_key = storedKey(&client_key);
    const auth_message =
        "n=user,r=rOprNGfwEbeRWgbNEkqO," ++
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096," ++
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";

    const signature = clientSignature(&stored_key, auth_message);
    const proof = clientProof(&client_key, &signature);
    const final = try clientFinal(
        std.testing.allocator,
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0",
        &proof,
    );
    defer std.testing.allocator.free(final);
    try std.testing.expectEqualStrings(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=FbaVUaWV7toi7FkYKm0Grr2EmbA=",
        final,
    );

    const server_key = serverKey(&salted);
    const server_signature = serverSignature(&server_key, auth_message);
    try verifyServerFinal(
        &server_signature,
        "v=Bu6qplTTDNYGc1tZYdBhaGoiNvM=",
    );
}

test "SCRAM-SHA-1 enforces MongoDB iteration minimum" {
    try std.testing.expectError(
        error.InvalidIterationCount,
        saltedPassword("digest", "salt", 4095),
    );
}
