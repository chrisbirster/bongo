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

test "41 - failed TLS SCRAM connects release transport resources" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const ca_path = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        ".bongo-tls/server-cert.pem",
        allocator,
    );
    defer allocator.free(ca_path);

    const bad_uri = try std.fmt.allocPrint(
        allocator,
        "mongodb://admin:wrong-password@localhost:27018/admin?authSource=admin&tls=true&tlsCAFile={s}&connectTimeoutMS=5000&socketTimeoutMS=5000&timeoutMS=10000",
        .{ca_path},
    );
    defer allocator.free(bad_uri);

    for (0..3) |_| {
        if (bongo.RuntimeClient.connectUri(io, allocator, bad_uri, .{})) |client_value| {
            var client = client_value;
            client.deinit();
            return error.ExpectedAuthenticationFailure;
        } else |_| {}
    }

    // A successful connection immediately after repeated authentication
    // failures proves those failures did not leave the TLS fixture or runtime
    // client in a poisoned ownership state. std.testing.allocator also makes
    // leaked heap allocations from the failure path fail this test.
    const good_uri = try std.fmt.allocPrint(
        allocator,
        "mongodb://admin:secretpassword@localhost:27018/admin?authSource=admin&tls=true&tlsCAFile={s}&connectTimeoutMS=5000&socketTimeoutMS=5000&timeoutMS=10000",
        .{ca_path},
    );
    defer allocator.free(good_uri);

    var client = try bongo.RuntimeClient.connectUri(io, allocator, good_uri, .{});
    defer client.deinit();
    try std.testing.expectEqualStrings("admin", client.databaseName());
}

test "41 - TLS setup failure releases partially initialized resources" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    try std.testing.expectError(
        error.FileNotFound,
        bongo.TlsConnection.connect(
            io,
            allocator,
            "localhost",
            27018,
            .{
                .ca_file = "/definitely/not/a/bongo/ca.pem",
                .connect_timeout_ms = 100,
            },
        ),
    );
}
