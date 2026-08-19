const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const signature_length = HmacSha256.mac_length;

comptime {
    std.debug.assert(signature_length == 32);
}

pub const Error = error{
    InvalidServerFinalMessage,
    ServerAuthenticationFailed,
    InvalidServerVerifier,
    ServerSignatureMismatch,
};

/// Derive the SCRAM ServerKey from the SaltedPassword.
///
/// RFC 5802 defines this as:
/// ServerKey := HMAC(SaltedPassword, "Server Key")
pub fn serverKey(
    salted_password: *const [signature_length]u8,
) [signature_length]u8 {
    var result: [signature_length]u8 = undefined;

    HmacSha256.create(
        &result,
        "Server Key",
        salted_password[0..],
    );

    std.debug.assert(result.len == signature_length);
    return result;
}

/// Derive the expected SCRAM ServerSignature.
///
/// RFC 5802 defines this as:
/// ServerSignature := HMAC(ServerKey, AuthMessage)
pub fn serverSignature(
    server_key: *const [signature_length]u8,
    auth_message: []const u8,
) [signature_length]u8 {
    var result: [signature_length]u8 = undefined;

    HmacSha256.create(
        &result,
        auth_message,
        server_key[0..],
    );

    std.debug.assert(result.len == signature_length);
    return result;
}

/// Verify the `v=` verifier in a SCRAM server-final message.
///
/// The verifier is decoded from Base64 and compared to the expected server
/// signature with Zig's constant-time comparison helper.
pub fn verifyServerFinal(
    expected_signature: *const [signature_length]u8,
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

    const encoded_verifier = verifier orelse
        return error.InvalidServerFinalMessage;

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded_verifier) catch {
        return error.InvalidServerVerifier;
    };

    if (decoded_len != signature_length) {
        return error.InvalidServerVerifier;
    }

    var decoded: [signature_length]u8 = undefined;
    decoder.decode(&decoded, encoded_verifier) catch {
        return error.InvalidServerVerifier;
    };

    if (!std.crypto.timing_safe.eql(
        [signature_length]u8,
        expected_signature.*,
        decoded,
    )) {
        return error.ServerSignatureMismatch;
    }
}

test "SCRAM server key matches SHA-256 conversation" {
    const salted_password = [_]u8{
        0xc4, 0xa4, 0x95, 0x10, 0x32, 0x3a, 0xb4, 0xf9,
        0x52, 0xca, 0xc1, 0xfa, 0x99, 0x44, 0x19, 0x39,
        0xe7, 0x8e, 0xa7, 0x4d, 0x6b, 0xe8, 0x1d, 0xdf,
        0x70, 0x96, 0xe8, 0x75, 0x13, 0xdc, 0x61, 0x5d,
    };

    const result = serverKey(&salted_password);

    const expected = [_]u8{
        0xc1, 0xf3, 0xcb, 0xc1, 0xc1, 0x3a, 0x9d, 0x35,
        0xa1, 0x4c, 0x09, 0x90, 0xee, 0xd9, 0x76, 0x29,
        0xea, 0x22, 0x58, 0x63, 0xe5, 0x66, 0xa4, 0x31,
        0x4a, 0xb9, 0x9f, 0x3f, 0x00, 0xe5, 0xd9, 0xd5,
    };

    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "SCRAM server signature matches SHA-256 conversation" {
    const server_key = [_]u8{
        0xc1, 0xf3, 0xcb, 0xc1, 0xc1, 0x3a, 0x9d, 0x35,
        0xa1, 0x4c, 0x09, 0x90, 0xee, 0xd9, 0x76, 0x29,
        0xea, 0x22, 0x58, 0x63, 0xe5, 0x66, 0xa4, 0x31,
        0x4a, 0xb9, 0x9f, 0x3f, 0x00, 0xe5, 0xd9, 0xd5,
    };

    const auth_message =
        "n=user,r=rOprNGfwEbeRWgbNEkqO," ++
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096," ++
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";

    const result = serverSignature(&server_key, auth_message);

    const expected = [_]u8{
        0xea, 0xba, 0xe2, 0x4d, 0x10, 0x62, 0xdb, 0x75,
        0xa9, 0x45, 0x1f, 0xf0, 0xb6, 0xea, 0x7e, 0x98,
        0xc8, 0x54, 0x65, 0x49, 0xff, 0x74, 0x1e, 0x67,
        0x2d, 0x32, 0x51, 0xb2, 0x39, 0x7d, 0xe4, 0x6e,
    };

    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "SCRAM verifies RFC 7677 server-final message" {
    const expected = [_]u8{
        0xea, 0xba, 0xe2, 0x4d, 0x10, 0x62, 0xdb, 0x75,
        0xa9, 0x45, 0x1f, 0xf0, 0xb6, 0xea, 0x7e, 0x98,
        0xc8, 0x54, 0x65, 0x49, 0xff, 0x74, 0x1e, 0x67,
        0x2d, 0x32, 0x51, 0xb2, 0x39, 0x7d, 0xe4, 0x6e,
    };

    try verifyServerFinal(
        &expected,
        "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=",
    );
}

test "SCRAM rejects mismatched server signature" {
    const expected = [_]u8{0} ** signature_length;

    try std.testing.expectError(
        error.ServerSignatureMismatch,
        verifyServerFinal(
            &expected,
            "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=",
        ),
    );
}

test "SCRAM rejects malformed server verifier" {
    const expected = [_]u8{0} ** signature_length;

    try std.testing.expectError(
        error.InvalidServerVerifier,
        verifyServerFinal(&expected, "v=not%%%base64"),
    );
}

test "SCRAM surfaces server-final authentication error" {
    const expected = [_]u8{0} ** signature_length;

    try std.testing.expectError(
        error.ServerAuthenticationFailed,
        verifyServerFinal(&expected, "e=invalid-proof"),
    );
}
