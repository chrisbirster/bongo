const std = @import("std");
const bson = @import("../bson.zig");

pub const Error = error{
    PrimaryWithTagSets,
    PrimaryWithMaxStaleness,
    MaxStalenessTooSmall,
    InvalidTagSet,
};

pub const Mode = enum {
    primary,
    primary_preferred,
    secondary,
    secondary_preferred,
    nearest,

    pub fn wireName(mode: Mode) []const u8 {
        return switch (mode) {
            .primary => "primary",
            .primary_preferred => "primaryPreferred",
            .secondary => "secondary",
            .secondary_preferred => "secondaryPreferred",
            .nearest => "nearest",
        };
    }
};

/// One read-preference tag set represented as an encoded BSON document.
/// The bytes are borrowed and must outlive the ReadPreference using them.
pub const TagSet = struct {
    document: []const u8,
};

pub const ReadPreference = struct {
    mode: Mode = .primary,
    tag_sets: []const TagSet = &.{},
    max_staleness_seconds: ?u32 = null,

    pub fn validate(self: ReadPreference) Error!void {
        if (self.mode == .primary and self.tag_sets.len != 0) {
            return error.PrimaryWithTagSets;
        }
        if (self.mode == .primary and self.max_staleness_seconds != null) {
            return error.PrimaryWithMaxStaleness;
        }

        if (self.max_staleness_seconds) |seconds| {
            if (seconds < 90) return error.MaxStalenessTooSmall;
        }

        for (self.tag_sets) |tag_set| {
            bson.validateDocument(tag_set.document) catch {
                return error.InvalidTagSet;
            };
        }
    }
};

test "read preference exposes MongoDB wire mode names" {
    try std.testing.expectEqualStrings("primary", Mode.primary.wireName());
    try std.testing.expectEqualStrings(
        "primaryPreferred",
        Mode.primary_preferred.wireName(),
    );
    try std.testing.expectEqualStrings("secondary", Mode.secondary.wireName());
    try std.testing.expectEqualStrings(
        "secondaryPreferred",
        Mode.secondary_preferred.wireName(),
    );
    try std.testing.expectEqualStrings("nearest", Mode.nearest.wireName());
}

test "primary rejects tags and max staleness" {
    const allocator = std.testing.allocator;
    const tag_document = try bson.encode(allocator, .{ .dc = "east" });
    defer allocator.free(tag_document);
    const tags = [_]TagSet{.{ .document = tag_document }};

    try std.testing.expectError(
        error.PrimaryWithTagSets,
        (ReadPreference{
            .mode = .primary,
            .tag_sets = &tags,
        }).validate(),
    );
    try std.testing.expectError(
        error.PrimaryWithMaxStaleness,
        (ReadPreference{
            .mode = .primary,
            .max_staleness_seconds = 120,
        }).validate(),
    );
}

test "non-primary validates tag sets and max staleness" {
    const allocator = std.testing.allocator;
    const tag_document = try bson.encode(allocator, .{ .region = "east" });
    defer allocator.free(tag_document);
    const tags = [_]TagSet{.{ .document = tag_document }};

    try (ReadPreference{
        .mode = .nearest,
        .tag_sets = &tags,
        .max_staleness_seconds = 120,
    }).validate();

    try std.testing.expectError(
        error.MaxStalenessTooSmall,
        (ReadPreference{
            .mode = .secondary,
            .max_staleness_seconds = 89,
        }).validate(),
    );
}
