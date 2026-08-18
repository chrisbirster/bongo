const std = @import("std");

const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const salted_password_length = HmacSha256.mac_length;

comptime {
    std.debug.assert(salted_password_length == 32);
    std.debug.assert(salted_password_length == std.crypto.hash.sha2.Sha256.digest_length);
}

pub const Error = Allocator.Error || error{
    InvalidNonce,
    InvalidServerFirstMessage,
    InvalidServerNonce,
    InvalidIterationCount,
    InvalidSalt,
    UnsupportedExtension,
};

pub const ServerFirst = struct {
    nonce: []const u8,
    salt: []const u8,
    iterations: u32,
};

/// Build the SCRAM-SHA-256 client-first message.
///
/// SCRAM starts with the GS2 header `n,,`, followed by the
/// client-first-bare message containing the username and client nonce.
///
/// The returned slice is owned by the caller.
pub fn clientFirst(
    allocator: Allocator,
    username: []const u8,
    nonce: []const u8,
) Error![]u8 {
    if (!isValidNonce(nonce)) {
        return error.InvalidNonce;
    }

    var escaped_username: std.ArrayList(u8) = .empty;
    defer escaped_username.deinit(allocator);

    for (username) |byte| {
        switch (byte) {
            ',' => try escaped_username.appendSlice(allocator, "=2C"),
            '=' => try escaped_username.appendSlice(allocator, "=3D"),
            else => try escaped_username.append(allocator, byte),
        }
    }

    return std.fmt.allocPrint(
        allocator,
        "n,,n={s},r={s}",
        .{ escaped_username.items, nonce },
    );
}

/// Parse the SCRAM server-first message.
///
/// The server returns the combined nonce (`r`), Base64-encoded salt (`s`),
/// and password-derivation iteration count (`i`). The returned slices borrow
/// from `message` and remain valid only while `message` remains valid.
pub fn parseServerFirst(
    message: []const u8,
    client_nonce: []const u8,
) Error!ServerFirst {
    if (!isValidNonce(client_nonce)) return error.InvalidNonce;

    var nonce: ?[]const u8 = null;
    var salt: ?[]const u8 = null;
    var iterations: ?u32 = null;

    var fields = std.mem.splitScalar(u8, message, ',');
    while (fields.next()) |field| {
        if (field.len < 3 or field[1] != '=') {
            return error.InvalidServerFirstMessage;
        }

        const value = field[2..];

        switch (field[0]) {
            'r' => {
                if (nonce != null) return error.InvalidServerFirstMessage;
                nonce = value;
            },
            's' => {
                if (salt != null) return error.InvalidServerFirstMessage;
                salt = value;
            },
            'i' => {
                if (iterations != null) return error.InvalidServerFirstMessage;

                const parsed = std.fmt.parseInt(u32, value, 10) catch {
                    return error.InvalidIterationCount;
                };

                if (parsed < 4096) return error.InvalidIterationCount;
                iterations = parsed;
            },
            'm' => return error.UnsupportedExtension,
            else => {},
        }
    }

    const server_nonce = nonce orelse return error.InvalidServerFirstMessage;
    const server_salt = salt orelse return error.InvalidServerFirstMessage;
    const iteration_count = iterations orelse return error.InvalidServerFirstMessage;

    if (!std.mem.startsWith(u8, server_nonce, client_nonce)) {
        return error.InvalidServerNonce;
    }
    if (server_nonce.len <= client_nonce.len) return error.InvalidServerNonce;

    const result = ServerFirst{
        .nonce = server_nonce,
        .salt = server_salt,
        .iterations = iteration_count,
    };

    std.debug.assert(std.mem.startsWith(u8, result.nonce, client_nonce));
    std.debug.assert(result.nonce.len > client_nonce.len);
    std.debug.assert(result.iterations >= 4096);

    return result;
}

fn isValidNonce(nonce: []const u8) bool {
    if (nonce.len == 0) {
        return false;
    }

    for (nonce) |byte| {
        if (byte < 0x21 or byte > 0x7e or byte == ',') {
            return false;
        }
    }

    return true;
}

pub fn decodeSalt(
    allocator: Allocator,
    encoded_salt: []const u8,
) Error![]u8 {
    const decoder = std.base64.standard.Decoder;

    const decoded_len = decoder.calcSizeForSlice(
        encoded_salt,
    ) catch {
        return error.InvalidSalt;
    };

    const salt = try allocator.alloc(
        u8,
        decoded_len,
    );
    errdefer allocator.free(salt);

    decoder.decode(
        salt,
        encoded_salt,
    ) catch {
        return error.InvalidSalt;
    };

    std.debug.assert(salt.len == decoded_len);

    return salt;
}

/// Derive the SCRAM-SHA-256 SaltedPassword with PBKDF2-HMAC-SHA-256.
///
/// `prepared_password` must already have the SCRAM-SHA-256 password
/// preparation rules applied. `salt` must be the raw decoded salt bytes,
/// not the Base64 text from the server-first message.
pub fn saltedPassword(
    prepared_password: []const u8,
    salt: []const u8,
    iterations: u32,
) error{InvalidIterationCount}![salted_password_length]u8 {
    if (iterations < 4096) return error.InvalidIterationCount;

    var result: [salted_password_length]u8 = undefined;

    std.crypto.pwhash.pbkdf2(
        &result,
        prepared_password,
        salt,
        iterations,
        HmacSha256,
    ) catch unreachable;

    std.debug.assert(result.len == salted_password_length);
    return result;
}

/// Derive the SCRAM ClientKey from the SaltedPassword.
///
/// RFC 5802 defines this as:
/// ClientKey := HMAC(SaltedPassword, "Client Key")
pub fn clientKey(
    salted_password: *const [salted_password_length]u8,
) [salted_password_length]u8 {
    var result: [salted_password_length]u8 = undefined;

    HmacSha256.create(
        &result,
        "Client Key",
        salted_password[0..],
    );

    std.debug.assert(result.len == salted_password_length);
    return result;
}

/// Derive the SCRAM StoredKey from the ClientKey.
///
/// RFC 5802 defines this as:
/// StoredKey := H(ClientKey)
pub fn storedKey(
    client_key: *const [salted_password_length]u8,
) [salted_password_length]u8 {
    var result: [salted_password_length]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(
        client_key[0..],
        &result,
        .{},
    );

    std.debug.assert(result.len == salted_password_length);
    return result;
}

/// Build the exact SCRAM transcript used by client and server signatures.
///
/// RFC 5802 defines this as the three original transcript parts joined by
/// commas. Callers must pass the exact bytes used in the conversation rather
/// than reconstructed or normalized values.
pub fn authMessage(
    allocator: Allocator,
    client_first_bare: []const u8,
    server_first_message: []const u8,
    client_final_without_proof: []const u8,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s},{s},{s}",
        .{
            client_first_bare,
            server_first_message,
            client_final_without_proof,
        },
    );
}

/// Derive the SCRAM ClientSignature from the StoredKey and AuthMessage.
///
/// RFC 5802 defines this as:
/// ClientSignature := HMAC(StoredKey, AuthMessage)
pub fn clientSignature(
    stored_key: *const [salted_password_length]u8,
    auth_message: []const u8,
) [salted_password_length]u8 {
    var result: [salted_password_length]u8 = undefined;

    HmacSha256.create(
        &result,
        auth_message,
        stored_key[0..],
    );

    std.debug.assert(result.len == salted_password_length);
    return result;
}

/// Derive the SCRAM ClientProof from the ClientKey and ClientSignature.
///
/// RFC 5802 defines this as:
/// ClientProof := ClientKey XOR ClientSignature
pub fn clientProof(
    client_key: *const [salted_password_length]u8,
    client_signature: *const [salted_password_length]u8,
) [salted_password_length]u8 {
    var result: [salted_password_length]u8 = undefined;

    for (
        result[0..],
        client_key[0..],
        client_signature[0..],
    ) |*result_byte, key_byte, signature_byte| {
        result_byte.* = key_byte ^ signature_byte;
    }

    std.debug.assert(result.len == salted_password_length);
    return result;
}

test "SCRAM salt decodes from Base64" {
    const salt = try decodeSalt(
        std.testing.allocator,
        "c2FsdA==",
    );
    defer std.testing.allocator.free(salt);

    try std.testing.expectEqualSlices(
        u8,
        "salt",
        salt,
    );
}

test "SCRAM salt rejects invalid Base64" {
    try std.testing.expectError(
        error.InvalidSalt,
        decodeSalt(
            std.testing.allocator,
            "not%%%base64",
        ),
    );
}

test "SCRAM salted password matches MongoDB SHA-256 conversation" {
    const salt = try decodeSalt(
        std.testing.allocator,
        "W22ZaJ0SNY7soEsUEjb6gQ==",
    );
    defer std.testing.allocator.free(salt);

    const result = try saltedPassword(
        "pencil",
        salt,
        4096,
    );

    const expected = [_]u8{
        0xc4, 0xa4, 0x95, 0x10, 0x32, 0x3a, 0xb4, 0xf9,
        0x52, 0xca, 0xc1, 0xfa, 0x99, 0x44, 0x19, 0x39,
        0xe7, 0x8e, 0xa7, 0x4d, 0x6b, 0xe8, 0x1d, 0xdf,
        0x70, 0x96, 0xe8, 0x75, 0x13, 0xdc, 0x61, 0x5d,
    };

    try std.testing.expectEqualSlices(
        u8,
        &expected,
        &result,
    );
}

test "SCRAM salted password enforces MongoDB iteration minimum" {
    try std.testing.expectError(
        error.InvalidIterationCount,
        saltedPassword(
            "pencil",
            "salt",
            4095,
        ),
    );
}

test "SCRAM client key matches SHA-256 conversation" {
    const salted_password = [_]u8{
        0xc4, 0xa4, 0x95, 0x10, 0x32, 0x3a, 0xb4, 0xf9,
        0x52, 0xca, 0xc1, 0xfa, 0x99, 0x44, 0x19, 0x39,
        0xe7, 0x8e, 0xa7, 0x4d, 0x6b, 0xe8, 0x1d, 0xdf,
        0x70, 0x96, 0xe8, 0x75, 0x13, 0xdc, 0x61, 0x5d,
    };

    const result = clientKey(&salted_password);

    const expected = [_]u8{
        0xa6, 0x0f, 0xc9, 0x23, 0xd6, 0x7e, 0x86, 0x44,
        0xa9, 0x2d, 0x16, 0xb9, 0x6e, 0xda, 0x5e, 0xf4,
        0x65, 0x6b, 0x0c, 0x72, 0x5c, 0x48, 0x43, 0x74,
        0xbe, 0x25, 0x53, 0x55, 0x76, 0x99, 0x6e, 0x8b,
    };

    try std.testing.expectEqualSlices(
        u8,
        &expected,
        &result,
    );
}

test "SCRAM stored key matches SHA-256 conversation" {
    const client_key = [_]u8{
        0xa6, 0x0f, 0xc9, 0x23, 0xd6, 0x7e, 0x86, 0x44,
        0xa9, 0x2d, 0x16, 0xb9, 0x6e, 0xda, 0x5e, 0xf4,
        0x65, 0x6b, 0x0c, 0x72, 0x5c, 0x48, 0x43, 0x74,
        0xbe, 0x25, 0x53, 0x55, 0x76, 0x99, 0x6e, 0x8b,
    };

    const result = storedKey(&client_key);

    const expected = [_]u8{
        0x58, 0x6e, 0x5d, 0xf2, 0x83, 0xe6, 0xdc, 0xeb,
        0x5c, 0x3e, 0x79, 0x1d, 0x8b, 0x85, 0x28, 0xec,
        0x19, 0x1e, 0x66, 0x40, 0x45, 0xce, 0x97, 0x17,
        0x92, 0xe2, 0xe6, 0xb5, 0xbb, 0x13, 0xe2, 0xa6,
    };

    try std.testing.expectEqualSlices(
        u8,
        &expected,
        &result,
    );
}

test "SCRAM auth message matches SHA-256 conversation" {
    const message = try authMessage(
        std.testing.allocator,
        "n=user,r=rOprNGfwEbeRWgbNEkqO",
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0",
    );
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings(
        "n=user,r=rOprNGfwEbeRWgbNEkqO,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0",
        message,
    );
}

test "SCRAM client signature matches SHA-256 conversation" {
    const stored_key = [_]u8{
        0x58, 0x6e, 0x5d, 0xf2, 0x83, 0xe6, 0xdc, 0xeb,
        0x5c, 0x3e, 0x79, 0x1d, 0x8b, 0x85, 0x28, 0xec,
        0x19, 0x1e, 0x66, 0x40, 0x45, 0xce, 0x97, 0x17,
        0x92, 0xe2, 0xe6, 0xb5, 0xbb, 0x13, 0xe2, 0xa6,
    };

    const result = clientSignature(
        &stored_key,
        "n=user,r=rOprNGfwEbeRWgbNEkqO,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0",
    );

    const expected = [_]u8{
        0xd2, 0x73, 0x12, 0x46, 0x7c, 0x28, 0xa4, 0x0a,
        0x8a, 0x7f, 0x05, 0xc7, 0x3c, 0x0d, 0xe3, 0x3e,
        0xb3, 0xcb, 0xfb, 0x4a, 0x83, 0x78, 0x3b, 0x58,
        0x14, 0x4c, 0xf1, 0x9a, 0xc6, 0xbe, 0x1b, 0xdf,
    };

    try std.testing.expectEqualSlices(
        u8,
        &expected,
        &result,
    );
}

test "SCRAM client proof matches SHA-256 conversation" {
    const client_key = [_]u8{
        0xa6, 0x0f, 0xc9, 0x23, 0xd6, 0x7e, 0x86, 0x44,
        0xa9, 0x2d, 0x16, 0xb9, 0x6e, 0xda, 0x5e, 0xf4,
        0x65, 0x6b, 0x0c, 0x72, 0x5c, 0x48, 0x43, 0x74,
        0xbe, 0x25, 0x53, 0x55, 0x76, 0x99, 0x6e, 0x8b,
    };
    const client_signature = [_]u8{
        0xd2, 0x73, 0x12, 0x46, 0x7c, 0x28, 0xa4, 0x0a,
        0x8a, 0x7f, 0x05, 0xc7, 0x3c, 0x0d, 0xe3, 0x3e,
        0xb3, 0xcb, 0xfb, 0x4a, 0x83, 0x78, 0x3b, 0x58,
        0x14, 0x4c, 0xf1, 0x9a, 0xc6, 0xbe, 0x1b, 0xdf,
    };

    const result = clientProof(
        &client_key,
        &client_signature,
    );

    const expected = [_]u8{
        0x74, 0x7c, 0xdb, 0x65, 0xaa, 0x56, 0x22, 0x4e,
        0x23, 0x52, 0x13, 0x7e, 0x52, 0xd7, 0xbd, 0xca,
        0xd6, 0xa0, 0xf7, 0x38, 0xdf, 0x30, 0x78, 0x2c,
        0xaa, 0x69, 0xa2, 0xcf, 0xb0, 0x27, 0x75, 0x54,
    };

    try std.testing.expectEqualSlices(
        u8,
        &expected,
        &result,
    );
}

test "client first message includes username and nonce" {
    const message = try clientFirst(
        std.testing.allocator,
        "bongo",
        "abc123",
    );
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings(
        "n,,n=bongo,r=abc123",
        message,
    );
}

test "client first message escapes SCRAM username characters" {
    const message = try clientFirst(
        std.testing.allocator,
        "a,b=c",
        "nonce",
    );
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings(
        "n,,n=a=2Cb=3Dc,r=nonce",
        message,
    );
}

test "client first message rejects invalid nonce" {
    try std.testing.expectError(
        error.InvalidNonce,
        clientFirst(
            std.testing.allocator,
            "bongo",
            "bad,nonce",
        ),
    );

    try std.testing.expectError(
        error.InvalidNonce,
        clientFirst(
            std.testing.allocator,
            "bongo",
            "",
        ),
    );
}

test "server first message parses nonce salt and iterations" {
    const result = try parseServerFirst(
        "r=abc123XYZ,s=c2FsdA==,i=4096",
        "abc123",
    );

    try std.testing.expectEqualStrings("abc123XYZ", result.nonce);
    try std.testing.expectEqualStrings("c2FsdA==", result.salt);
    try std.testing.expectEqual(@as(u32, 4096), result.iterations);
}

test "server first message requires server nonce to extend client nonce" {
    try std.testing.expectError(
        error.InvalidServerNonce,
        parseServerFirst(
            "r=otherXYZ,s=c2FsdA==,i=4096",
            "abc123",
        ),
    );

    try std.testing.expectError(
        error.InvalidServerNonce,
        parseServerFirst(
            "r=abc123,s=c2FsdA==,i=4096",
            "abc123",
        ),
    );
}

test "server first message validates client nonce argument" {
    try std.testing.expectError(
        error.InvalidNonce,
        parseServerFirst(
            "r=abc123XYZ,s=c2FsdA==,i=4096",
            "",
        ),
    );

    try std.testing.expectError(
        error.InvalidNonce,
        parseServerFirst(
            "r=abc123XYZ,s=c2FsdA==,i=4096",
            "bad,nonce",
        ),
    );
}

test "server first message enforces iteration boundary" {
    const minimum = try parseServerFirst(
        "r=abc123XYZ,s=c2FsdA==,i=4096",
        "abc123",
    );
    try std.testing.expectEqual(@as(u32, 4096), minimum.iterations);

    try std.testing.expectError(
        error.InvalidIterationCount,
        parseServerFirst(
            "r=abc123XYZ,s=c2FsdA==,i=4095",
            "abc123",
        ),
    );
}

test "server first message rejects malformed iteration count" {
    try std.testing.expectError(
        error.InvalidIterationCount,
        parseServerFirst(
            "r=abc123XYZ,s=c2FsdA==,i=not-a-number",
            "abc123",
        ),
    );

    try std.testing.expectError(
        error.InvalidIterationCount,
        parseServerFirst(
            "r=abc123XYZ,s=c2FsdA==,i=4294967296",
            "abc123",
        ),
    );
}

test "server first message requires nonce salt and iterations" {
    try std.testing.expectError(
        error.InvalidServerFirstMessage,
        parseServerFirst(
            "s=c2FsdA==,i=4096",
            "abc123",
        ),
    );

    try std.testing.expectError(
        error.InvalidServerFirstMessage,
        parseServerFirst(
            "r=abc123XYZ,i=4096",
            "abc123",
        ),
    );

    try std.testing.expectError(
        error.InvalidServerFirstMessage,
        parseServerFirst(
            "r=abc123XYZ,s=c2FsdA==",
            "abc123",
        ),
    );
}

test "server first message rejects duplicate required fields" {
    try std.testing.expectError(
        error.InvalidServerFirstMessage,
        parseServerFirst(
            "r=abc123XYZ,r=abc123MORE,s=c2FsdA==,i=4096",
            "abc123",
        ),
    );

    try std.testing.expectError(
        error.InvalidServerFirstMessage,
        parseServerFirst(
            "r=abc123XYZ,s=c2FsdA==,s=b3RoZXI=,i=4096",
            "abc123",
        ),
    );

    try std.testing.expectError(
        error.InvalidServerFirstMessage,
        parseServerFirst(
            "r=abc123XYZ,s=c2FsdA==,i=4096,i=4097",
            "abc123",
        ),
    );
}

test "server first message rejects malformed fields" {
    try std.testing.expectError(
        error.InvalidServerFirstMessage,
        parseServerFirst(
            "r=abc123XYZ,,s=c2FsdA==,i=4096",
            "abc123",
        ),
    );

    try std.testing.expectError(
        error.InvalidServerFirstMessage,
        parseServerFirst(
            "rabc123XYZ,s=c2FsdA==,i=4096",
            "abc123",
        ),
    );
}

test "server first message rejects unsupported mandatory extension" {
    try std.testing.expectError(
        error.UnsupportedExtension,
        parseServerFirst(
            "r=abc123XYZ,s=c2FsdA==,i=4096,m=required",
            "abc123",
        ),
    );
}

test "server first message ignores unknown optional extension" {
    const result = try parseServerFirst(
        "r=abc123XYZ,s=c2FsdA==,i=4096,x=ignored",
        "abc123",
    );

    try std.testing.expectEqualStrings("abc123XYZ", result.nonce);
    try std.testing.expectEqualStrings("c2FsdA==", result.salt);
    try std.testing.expectEqual(@as(u32, 4096), result.iterations);
}
