const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{
    InvalidNonce,
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
