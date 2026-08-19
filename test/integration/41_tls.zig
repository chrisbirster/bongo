const std = @import("std");
const bongo = @import("bongo");

test "41 - TLS transport reaches a TLS-enabled MongoDB deployment" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var connection = try bongo.TlsConnection.connect(
        io,
        allocator,
        "localhost",
        27018,
        .{
            // The local integration fixture uses a generated self-signed
            // certificate. Certificate verification behavior is covered by
            // unit tests and can be exercised with a CA file in deployments.
            .verify_certificate = false,
            .verify_hostname = false,
        },
    );
    defer connection.deinit();

    const request = try bongo.mongo.op_msg.encodeCommand(
        allocator,
        .{
            .hello = @as(i32, 1),
            .@"$db" = "admin",
        },
        .{ .request_id = 2300 },
    );
    defer allocator.free(request);

    const response = try connection.request(allocator, request);
    defer allocator.free(response);

    const message = try bongo.mongo.op_msg.decode(response);
    try std.testing.expectEqual(@as(i32, 2300), message.header.response_to);
}
