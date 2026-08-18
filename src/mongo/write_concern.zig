const std = @import("std");
const bson = @import("../bson.zig");

const Allocator = std.mem.Allocator;

pub const W = union(enum) {
    number: u32,
    majority,
};

pub const WriteConcern = struct {
    w: W,
    journal: ?bool = null,
    wtimeout_ms: ?u64 = null,
};

pub fn encode(
    allocator: Allocator,
    concern: WriteConcern,
) ![]u8 {
    var writer = try bson.Writer.init(allocator);
    errdefer writer.deinit();

    switch (concern.w) {
        .number => |value| {
            if (value <= std.math.maxInt(i32)) {
                try writer.writeInt32("w", @intCast(value));
            } else {
                try writer.writeInt64("w", @intCast(value));
            }
        },
        .majority => try writer.writeString("w", "majority"),
    }

    if (concern.journal) |journal| {
        try writer.writeBool("j", journal);
    }

    if (concern.wtimeout_ms) |timeout| {
        if (timeout != 0) {
            if (timeout <= std.math.maxInt(i32)) {
                try writer.writeInt32("wtimeout", @intCast(timeout));
            } else if (timeout <= @as(u64, std.math.maxInt(i64))) {
                try writer.writeInt64("wtimeout", @intCast(timeout));
            } else {
                return error.UnsupportedInteger;
            }
        }
    }

    return writer.finish();
}

test "write concern encodes majority journal and timeout" {
    const allocator = std.testing.allocator;

    const document = try encode(
        allocator,
        .{
            .w = .majority,
            .journal = true,
            .wtimeout_ms = 1500,
        },
    );
    defer allocator.free(document);

    try std.testing.expectEqualStrings(
        "majority",
        (try bson.Reader.get(document, "w")).?.string,
    );
    try std.testing.expect((try bson.Reader.get(document, "j")).?.boolean);
    try std.testing.expectEqual(
        @as(i32, 1500),
        (try bson.Reader.get(document, "wtimeout")).?.int32,
    );
}

test "write concern omits zero timeout and optional journal" {
    const allocator = std.testing.allocator;

    const document = try encode(
        allocator,
        .{
            .w = .{ .number = 1 },
            .wtimeout_ms = 0,
        },
    );
    defer allocator.free(document);

    try std.testing.expectEqual(
        @as(i32, 1),
        (try bson.Reader.get(document, "w")).?.int32,
    );
    try std.testing.expect((try bson.Reader.get(document, "j")) == null);
    try std.testing.expect((try bson.Reader.get(document, "wtimeout")) == null);
}
