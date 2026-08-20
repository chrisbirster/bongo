const std = @import("std");
const bongo = @import("bongo");

test "41 - verified TLS transport authenticates with SCRAM and reaches MongoDB" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const ca_path = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        ".bongo-tls/server-cert.pem",
        allocator,
    );
    defer allocator.free(ca_path);

    const tls_connection = try bongo.TlsConnection.connect(
        io,
        allocator,
        "localhost",
        27018,
        .{
            .ca_file = ca_path,
            .connect_timeout_ms = 5000,
            .socket_timeout_ms = 5000,
            .operation_timeout_ms = 10000,
        },
    );
    var transport: bongo.Transport = .{ .tls = tls_connection };
    defer transport.deinit();

    try bongo.authenticateTransport(
        &transport,
        allocator,
        "admin",
        "admin",
        "secretpassword",
    );

    const request = try bongo.mongo.op_msg.encodeCommand(
        allocator,
        .{
            .hello = @as(i32, 1),
            .@"$db" = "admin",
        },
        .{ .request_id = 2300 },
    );
    defer allocator.free(request);

    const response = try transport.request(allocator, request);
    defer allocator.free(response);

    const message = try bongo.mongo.op_msg.decode(response);
    try std.testing.expectEqual(@as(i32, 2300), message.header.response_to);
    const body = try message.body();
    const ok = (try bongo.bson.Reader.get(body, "ok")).?;
    switch (ok) {
        .double => |value| try std.testing.expectEqual(@as(f64, 1.0), value),
        .int32 => |value| try std.testing.expectEqual(@as(i32, 1), value),
        .int64 => |value| try std.testing.expectEqual(@as(i64, 1), value),
        else => return error.InvalidHelloResponse,
    }
}
