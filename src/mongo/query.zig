const std = @import("std");

/// Zig-friendly MongoDB query/update operator helpers.
///
/// These functions only construct anonymous Zig values. BSON encoding still
/// emits MongoDB's native `$...` keys on the wire.
pub fn eq(value: anytype) @TypeOf(.{ .@"$eq" = value }) {
    return .{ .@"$eq" = value };
}

pub fn ne(value: anytype) @TypeOf(.{ .@"$ne" = value }) {
    return .{ .@"$ne" = value };
}

pub fn gt(value: anytype) @TypeOf(.{ .@"$gt" = value }) {
    return .{ .@"$gt" = value };
}

pub fn gte(value: anytype) @TypeOf(.{ .@"$gte" = value }) {
    return .{ .@"$gte" = value };
}

pub fn lt(value: anytype) @TypeOf(.{ .@"$lt" = value }) {
    return .{ .@"$lt" = value };
}

pub fn lte(value: anytype) @TypeOf(.{ .@"$lte" = value }) {
    return .{ .@"$lte" = value };
}

pub fn in(values: anytype) @TypeOf(.{ .@"$in" = values }) {
    return .{ .@"$in" = values };
}

pub fn nin(values: anytype) @TypeOf(.{ .@"$nin" = values }) {
    return .{ .@"$nin" = values };
}

pub fn exists(value: bool) @TypeOf(.{ .@"$exists" = value }) {
    return .{ .@"$exists" = value };
}

/// `$and`. `all` avoids forcing callers to use an escaped Zig identifier for
/// the reserved word `and`.
pub fn all(clauses: anytype) @TypeOf(.{ .@"$and" = clauses }) {
    return .{ .@"$and" = clauses };
}

/// `$or`.
pub fn any(clauses: anytype) @TypeOf(.{ .@"$or" = clauses }) {
    return .{ .@"$or" = clauses };
}

pub fn nor(clauses: anytype) @TypeOf(.{ .@"$nor" = clauses }) {
    return .{ .@"$nor" = clauses };
}

pub fn elemMatch(value: anytype) @TypeOf(.{ .@"$elemMatch" = value }) {
    return .{ .@"$elemMatch" = value };
}

pub fn set(value: anytype) @TypeOf(.{ .@"$set" = value }) {
    return .{ .@"$set" = value };
}

pub fn inc(value: anytype) @TypeOf(.{ .@"$inc" = value }) {
    return .{ .@"$inc" = value };
}

pub fn unset(value: anytype) @TypeOf(.{ .@"$unset" = value }) {
    return .{ .@"$unset" = value };
}

pub fn push(value: anytype) @TypeOf(.{ .@"$push" = value }) {
    return .{ .@"$push" = value };
}

pub fn addToSet(value: anytype) @TypeOf(.{ .@"$addToSet" = value }) {
    return .{ .@"$addToSet" = value };
}

test "query helpers expose native MongoDB keys" {
    const less = lte(@as(i64, 42));
    try std.testing.expectEqual(@as(i64, 42), less.@"$lte");

    const values = [_]i32{ 1, 2, 3 };
    const member = in(&values);
    try std.testing.expectEqual(@as(i32, 2), member.@"$in"[1]);

    const update = set(.{ .due_at_ms = @as(i64, 100) });
    try std.testing.expectEqual(@as(i64, 100), update.@"$set".due_at_ms);
}
