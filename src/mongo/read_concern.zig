const std = @import("std");
const bson = @import("../bson.zig");

const Allocator = std.mem.Allocator;

pub const Level = enum {
    local,
    majority,
    linearizable,
    available,
    snapshot,

    pub fn wireName(level: Level) []const u8 {
        return switch (level) {
            .local => "local",
            .majority => "majority",
            .linearizable => "linearizable",
            .available => "available",
            .snapshot => "snapshot",
        };
    }
};

pub const ReadConcern = struct {
    level: Level,
};

pub fn encode(
    allocator: Allocator,
    concern: ReadConcern,
) ![]u8 {
    return bson.encode(
        allocator,
        .{ .level = concern.level.wireName() },
    );
}

test "read concern encodes supported levels" {
    const allocator = std.testing.allocator;

    inline for (.{
        Level.local,
        Level.majority,
        Level.linearizable,
        Level.available,
        Level.snapshot,
    }) |level| {
        const document = try encode(allocator, .{ .level = level });
        defer allocator.free(document);

        try std.testing.expectEqualStrings(
            level.wireName(),
            (try bson.Reader.get(document, "level")).?.string,
        );
    }
}
