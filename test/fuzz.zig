const std = @import("std");
const bongo = @import("bongo");

/// Deterministic fuzz-style mutation gate. This intentionally does not depend
/// on an external fuzzer runtime so it runs in every normal Zig/CI build.
test "malformed BSON and OP_MSG never panic or read out of bounds" {
    var state: u64 = 0x6b6f_6e67_6f2d_3036;
    var bytes: [512]u8 = undefined;

    for (0..2_000) |iteration| {
        for (&bytes) |*byte| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            byte.* = @truncate(state >> 32);
        }
        const length = (iteration * 37 + @as(usize, bytes[0])) % (bytes.len + 1);
        const sample = bytes[0..length];

        _ = bongo.bson.validateDocument(sample) catch {};
        _ = bongo.mongo.op_msg.decode(sample) catch {};
    }
}

test "truncated valid BSON is rejected at every boundary" {
    const document = try bongo.bson.encode(std.testing.allocator, .{
        .name = "bongo",
        .count = @as(i64, 42),
        .nested = .{ .ok = true },
    });
    defer std.testing.allocator.free(document);

    try bongo.bson.validateDocument(document);
    for (0..document.len) |length| {
        if (bongo.bson.validateDocument(document[0..length])) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "OP_MSG rejects impossible length and opcode mutations" {
    const message = try bongo.mongo.op_msg.encodeCommand(
        std.testing.allocator,
        .{ .ping = @as(i32, 1), .@"$db" = "admin" },
        .{ .request_id = 1 },
    );
    defer std.testing.allocator.free(message);

    var mutated = try std.testing.allocator.dupe(u8, message);
    defer std.testing.allocator.free(mutated);

    // Message length smaller than the wire header.
    mutated[0] = 1;
    mutated[1] = 0;
    mutated[2] = 0;
    mutated[3] = 0;
    try std.testing.expectError(error.InvalidMessageLength, bongo.mongo.op_msg.decode(mutated));

    @memcpy(mutated, message);
    // Opcode 0x7fffffff is not OP_MSG.
    mutated[12] = 0xff;
    mutated[13] = 0xff;
    mutated[14] = 0xff;
    mutated[15] = 0x7f;
    try std.testing.expectError(error.InvalidOpcode, bongo.mongo.op_msg.decode(mutated));
}
