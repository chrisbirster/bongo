const bson = @import("../bson.zig");
const client_mod = @import("client.zig");
const op_msg = @import("op_msg.zig");

pub const Error = error{
    UnexpectedResponse,
    CommandFailed,
};

pub fn validate(
    response_bytes: []const u8,
    expected_response_to: i32,
) ![]const u8 {
    const message = try op_msg.decode(response_bytes);
    if (message.header.response_to != expected_response_to) {
        return error.UnexpectedResponse;
    }

    const body = try message.body();
    const ok = (try bson.Reader.get(body, "ok")) orelse
        return error.CommandFailed;
    if (!commandSucceeded(ok)) return error.CommandFailed;
    return body;
}

pub fn sendVoid(
    client: *client_mod.Client,
    request: []const u8,
    request_id: i32,
) !void {
    const response = try client.connection.request(
        client.allocator,
        request,
    );
    defer client.allocator.free(response);
    _ = try validate(response, request_id);
}

pub fn sendOwned(
    client: *client_mod.Client,
    request: []const u8,
    request_id: i32,
) !client_mod.OwnedDocument {
    const response = try client.connection.request(
        client.allocator,
        request,
    );
    defer client.allocator.free(response);
    const body = try validate(response, request_id);

    return .{
        .allocator = client.allocator,
        .bytes = try client.allocator.dupe(u8, body),
    };
}

fn commandSucceeded(value: bson.Value) bool {
    return switch (value) {
        .double => |number| number == 1.0,
        .int32 => |number| number == 1,
        .int64 => |number| number == 1,
        else => false,
    };
}
