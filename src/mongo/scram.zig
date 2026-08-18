const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{
    InvalidNonce,
    InvalidServerFirstMessage,
    InvalidServerNonce,
    InvalidIterationCount,
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
