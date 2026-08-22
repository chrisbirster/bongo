const std = @import("std");
const bson = @import("../bson.zig");
const op_msg = @import("op_msg.zig");
const Transport = @import("transport.zig").Transport;

const Allocator = std.mem.Allocator;

pub const Error = error{
    UnexpectedResponse,
    CommandFailed,
    InvalidHelloField,
};

/// Owned subset of a hello response used by SDAM. All slices remain valid
/// until `deinit`, unlike the lightweight handshake description whose strings
/// only need to be consumed during the handshake call.
pub const Description = struct {
    allocator: Allocator,
    is_writable_primary: bool = false,
    secondary: bool = false,
    arbiter_only: bool = false,
    hidden: bool = false,
    is_mongos: bool = false,
    set_name: ?[]u8 = null,
    primary: ?[]u8 = null,
    me: ?[]u8 = null,
    hosts: [][]u8 = &.{},
    passives: [][]u8 = &.{},
    arbiters: [][]u8 = &.{},
    tags: ?[]u8 = null,
    last_write_date_ms: ?i64 = null,
    logical_session_timeout_minutes: ?i64 = null,
    min_wire_version: ?i32 = null,
    max_wire_version: ?i32 = null,

    pub fn deinit(self: *Description) void {
        freeOptional(self.allocator, self.set_name);
        freeOptional(self.allocator, self.primary);
        freeOptional(self.allocator, self.me);
        freeStringArray(self.allocator, self.hosts);
        freeStringArray(self.allocator, self.passives);
        freeStringArray(self.allocator, self.arbiters);
        freeOptional(self.allocator, self.tags);
        self.* = undefined;
    }
};

pub fn hello(
    transport: *Transport,
    allocator: Allocator,
    request_id: i32,
) !Description {
    const request = try op_msg.encodeCommand(
        allocator,
        .{
            .hello = @as(i32, 1),
            .@"$db" = "admin",
        },
        .{ .request_id = request_id },
    );
    defer allocator.free(request);

    const response = try transport.request(allocator, request);
    defer allocator.free(response);
    const message = try op_msg.decode(response);
    if (message.header.response_to != request_id) return error.UnexpectedResponse;
    const body = try message.body();
    if (!try commandSucceeded(body)) return error.CommandFailed;
    return parseOwned(allocator, body);
}

pub fn parseOwned(allocator: Allocator, body: []const u8) !Description {
    var result: Description = .{ .allocator = allocator };
    errdefer result.deinit();

    if (try bson.Reader.get(body, "isWritablePrimary")) |value| {
        result.is_writable_primary = try boolValue(value);
    } else if (try bson.Reader.get(body, "ismaster")) |value| {
        result.is_writable_primary = try boolValue(value);
    }
    if (try bson.Reader.get(body, "secondary")) |value| {
        result.secondary = try boolValue(value);
    }
    if (try bson.Reader.get(body, "arbiterOnly")) |value| {
        result.arbiter_only = try boolValue(value);
    }
    if (try bson.Reader.get(body, "hidden")) |value| {
        result.hidden = try boolValue(value);
    }
    if (try bson.Reader.get(body, "msg")) |value| {
        const msg = try stringValue(value);
        result.is_mongos = std.mem.eql(u8, msg, "isdbgrid");
    }
    if (try bson.Reader.get(body, "setName")) |value| {
        result.set_name = try allocator.dupe(u8, try stringValue(value));
    }
    if (try bson.Reader.get(body, "primary")) |value| {
        result.primary = try allocator.dupe(u8, try stringValue(value));
    }
    if (try bson.Reader.get(body, "me")) |value| {
        result.me = try allocator.dupe(u8, try stringValue(value));
    }
    if (try bson.Reader.get(body, "hosts")) |value| {
        result.hosts = try ownStringArray(allocator, value);
    }
    if (try bson.Reader.get(body, "passives")) |value| {
        result.passives = try ownStringArray(allocator, value);
    }
    if (try bson.Reader.get(body, "arbiters")) |value| {
        result.arbiters = try ownStringArray(allocator, value);
    }
    if (try bson.Reader.get(body, "tags")) |value| {
        const document = switch (value) {
            .document => |v| v,
            else => return error.InvalidHelloField,
        };
        result.tags = try allocator.dupe(u8, document);
    }
    if (try bson.Reader.get(body, "lastWrite")) |value| {
        const last_write = switch (value) {
            .document => |v| v,
            else => return error.InvalidHelloField,
        };
        if (try bson.Reader.get(last_write, "lastWriteDate")) |date_value| {
            result.last_write_date_ms = switch (date_value) {
                .datetime => |v| v.milliseconds,
                else => return error.InvalidHelloField,
            };
        }
    }
    if (try bson.Reader.get(body, "logicalSessionTimeoutMinutes")) |value| {
        result.logical_session_timeout_minutes = try int64Value(value);
    }
    if (try bson.Reader.get(body, "minWireVersion")) |value| {
        result.min_wire_version = try int32Value(value);
    }
    if (try bson.Reader.get(body, "maxWireVersion")) |value| {
        result.max_wire_version = try int32Value(value);
    }
    return result;
}

fn ownStringArray(allocator: Allocator, value: bson.Value) ![][]u8 {
    const bytes = switch (value) {
        .array => |v| v,
        else => return error.InvalidHelloField,
    };
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }
    var reader = try bson.Reader.init(bytes);
    while (try reader.next()) |element| {
        const owned = try allocator.dupe(u8, try stringValue(element.value));
        errdefer allocator.free(owned);
        try list.append(allocator, owned);
    }
    return try list.toOwnedSlice(allocator);
}

fn stringValue(value: bson.Value) ![]const u8 {
    return switch (value) {
        .string => |v| v,
        else => error.InvalidHelloField,
    };
}

fn boolValue(value: bson.Value) !bool {
    return switch (value) {
        .boolean => |v| v,
        else => error.InvalidHelloField,
    };
}

fn int32Value(value: bson.Value) !i32 {
    return switch (value) {
        .int32 => |v| v,
        .int64 => |v| std.math.cast(i32, v) orelse return error.InvalidHelloField,
        else => error.InvalidHelloField,
    };
}

fn int64Value(value: bson.Value) !i64 {
    return switch (value) {
        .int32 => |v| v,
        .int64 => |v| v,
        else => error.InvalidHelloField,
    };
}

fn commandSucceeded(body: []const u8) !bool {
    const ok = (try bson.Reader.get(body, "ok")) orelse return false;
    return switch (ok) {
        .double => |v| v == 1.0,
        .int32 => |v| v == 1,
        .int64 => |v| v == 1,
        else => false,
    };
}

fn freeOptional(allocator: Allocator, value: ?[]u8) void {
    if (value) |bytes| allocator.free(bytes);
}

fn freeStringArray(allocator: Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    if (values.len != 0) allocator.free(values);
}

test "owned SDAM hello parser keeps discovered members" {
    const allocator = std.testing.allocator;
    const hosts = [_][]const u8{ "db1:27017", "db2:27017" };
    const passives = [_][]const u8{"db3:27017"};
    const body = try bson.encode(allocator, .{
        .ok = @as(i32, 1),
        .isWritablePrimary = true,
        .setName = "rs0",
        .primary = "db1:27017",
        .me = "db1:27017",
        .hosts = hosts,
        .passives = passives,
        .tags = .{ .region = "east" },
        .lastWrite = .{ .lastWriteDate = bson.DateTime{ .milliseconds = 1234 } },
    });
    defer allocator.free(body);

    var description = try parseOwned(allocator, body);
    defer description.deinit();
    try std.testing.expect(description.is_writable_primary);
    try std.testing.expectEqualStrings("rs0", description.set_name.?);
    try std.testing.expectEqual(@as(usize, 2), description.hosts.len);
    try std.testing.expectEqualStrings("db2:27017", description.hosts[1]);
    try std.testing.expectEqual(@as(?i64, 1234), description.last_write_date_ms);
}
