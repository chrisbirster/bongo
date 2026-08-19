const std = @import("std");

const Allocator = std.mem.Allocator;
const proof_length = std.crypto.auth.hmac.sha2.HmacSha256.mac_length;
const encoded_proof_length = std.base64.standard.Encoder.calcSize(proof_length);

comptime {
    std.debug.assert(proof_length == 32);
    std.debug.assert(encoded_proof_length == 44);
}

/// Build the SCRAM client-final message without the proof.
///
/// With no channel binding, `c=biws` is the Base64 encoding of the GS2
/// header `n,,`. The combined server nonce is copied exactly as received.
///
/// The returned slice is owned by the caller.
pub fn clientFinalWithoutProof(
    allocator: Allocator,
    server_nonce: []const u8,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "c=biws,r={s}",
        .{server_nonce},
    );
}

/// Append the Base64-encoded SCRAM ClientProof to a client-final message.
///
/// The returned slice is owned by the caller.
pub fn clientFinal(
    allocator: Allocator,
    client_final_without_proof: []const u8,
    client_proof: *const [proof_length]u8,
) Allocator.Error![]u8 {
    var encoded_proof_buffer: [encoded_proof_length]u8 = undefined;

    const encoded_proof = std.base64.standard.Encoder.encode(
        &encoded_proof_buffer,
        client_proof[0..],
    );

    std.debug.assert(encoded_proof.len == encoded_proof_length);

    return std.fmt.allocPrint(
        allocator,
        "{s},p={s}",
        .{
            client_final_without_proof,
            encoded_proof,
        },
    );
}

test "SCRAM client-final without proof matches SHA-256 conversation" {
    const result = try clientFinalWithoutProof(
        std.testing.allocator,
        "rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0",
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0",
        result,
    );
}

test "SCRAM client-final matches SHA-256 conversation" {
    const proof = [_]u8{
        0x74, 0x7c, 0xdb, 0x65, 0xaa, 0x56, 0x22, 0x4e,
        0x23, 0x52, 0x13, 0x7e, 0x52, 0xd7, 0xbd, 0xca,
        0xd6, 0xa0, 0xf7, 0x38, 0xdf, 0x30, 0x78, 0x2c,
        0xaa, 0x69, 0xa2, 0xcf, 0xb0, 0x27, 0x75, 0x54,
    };

    const without_proof = try clientFinalWithoutProof(
        std.testing.allocator,
        "rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0",
    );
    defer std.testing.allocator.free(without_proof);

    const result = try clientFinal(
        std.testing.allocator,
        without_proof,
        &proof,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        result,
    );
}
