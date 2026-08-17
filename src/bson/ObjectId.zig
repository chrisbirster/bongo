const std = @import("std");

const ObjectId = @This();

/// Raw 12-byte BSON ObjectId.
bytes: [12]u8,

pub const Error = error{
    InvalidLength,
    InvalidCharacter,
};

/// Parse a 24-character hexadecimal ObjectId.
pub fn fromHex(hex: []const u8) Error!ObjectId {
    if (hex.len != 24) {
        return error.InvalidLength;
    }

    var bytes: [12]u8 = undefined;

    for (0..12) |i| {
        const high =
            hexNibble(hex[i * 2]) orelse
            return error.InvalidCharacter;

        const low =
            hexNibble(hex[i * 2 + 1]) orelse
            return error.InvalidCharacter;

        bytes[i] = (high << 4) | low;
    }

    return .{
        .bytes = bytes,
    };
}

/// Convert an ObjectId to its 24-character lowercase hexadecimal form.
pub fn toHex(id: ObjectId) [24]u8 {
    const digits = "0123456789abcdef";

    var hex: [24]u8 = undefined;

    for (id.bytes, 0..) |byte, i| {
        hex[i * 2] = digits[byte >> 4];
        hex[i * 2 + 1] = digits[byte & 0x0F];
    }

    return hex;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

test ObjectId {
    const id =
        try ObjectId.fromHex(
            "507f1f77bcf86cd799439011",
        );

    const hex = id.toHex();

    try std.testing.expectEqualStrings(
        "507f1f77bcf86cd799439011",
        &hex,
    );

    const upper =
        try ObjectId.fromHex(
            "507F1F77BCF86CD799439011",
        );

    try std.testing.expectEqualSlices(
        u8,
        &id.bytes,
        &upper.bytes,
    );

    try std.testing.expectError(
        error.InvalidLength,
        ObjectId.fromHex("1234"),
    );

    try std.testing.expectError(
        error.InvalidCharacter,
        ObjectId.fromHex(
            "507f1f77bcf86cd79943901z",
        ),
    );
}
