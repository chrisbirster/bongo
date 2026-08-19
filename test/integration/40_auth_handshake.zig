const std = @import("std");
const bongo = @import("bongo");

test "40 - negotiate SCRAM and zlib then exchange compressed command" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var connection = try bongo.mongo.Connection.connect(io, "127.0.0.1", 27017);
    defer connection.deinit();

    const handshake = try bongo.mongo.authenticateWithHandshake(
        &connection,
        allocator,
        "admin",
        "admin",
        "secretpassword",
    );

    switch (handshake.selected_mechanism) {
        .scram_sha_256 => {},
        else => return error.ExpectedScramSha256,
    }
    try std.testing.expectEqual(
        bongo.mongo.WireCompressor.zlib,
        handshake.selected_compressor.?,
    );

    // authenticateWithHandshake enables the negotiated compressor only after
    // SASL completes, so this ping travels through OP_COMPRESSED.
    const request = try bongo.mongo.op_msg.encodeCommand(
        allocator,
        .{ .ping = @as(i32, 1), .@"$db" = "admin" },
        .{ .request_id = 2200 },
    );
    defer allocator.free(request);

    const response = try connection.request(allocator, request);
    defer allocator.free(response);
    const message = try bongo.mongo.op_msg.decode(response);
    try std.testing.expectEqual(@as(i32, 2200), message.header.response_to);
}
