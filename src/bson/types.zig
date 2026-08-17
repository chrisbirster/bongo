//! BSON data types and wire-format identifiers.

const std = @import("std");

pub const ObjectId = @import("ObjectId.zig");

/// BSON element type byte.
pub const Type = enum(u8) {
    double = 0x01,
    string = 0x02,
    document = 0x03,
    array = 0x04,
    binary = 0x05,
    undefined_value = 0x06,
    object_id = 0x07,
    boolean = 0x08,
    datetime = 0x09,
    null_value = 0x0A,
    regex = 0x0B,
    db_pointer = 0x0C,
    javascript = 0x0D,
    symbol = 0x0E,
    javascript_with_scope = 0x0F,
    int32 = 0x10,
    timestamp = 0x11,
    int64 = 0x12,
    decimal128 = 0x13,
    min_key = 0xFF,
    max_key = 0x7F,

    pub fn byte(t: Type) u8 {
        return @intFromEnum(t);
    }

    pub fn fromByte(byte_value: u8) ?Type {
        return switch (byte_value) {
            0x01 => .double,
            0x02 => .string,
            0x03 => .document,
            0x04 => .array,
            0x05 => .binary,
            0x06 => .undefined_value,
            0x07 => .object_id,
            0x08 => .boolean,
            0x09 => .datetime,
            0x0A => .null_value,
            0x0B => .regex,
            0x0C => .db_pointer,
            0x0D => .javascript,
            0x0E => .symbol,
            0x0F => .javascript_with_scope,
            0x10 => .int32,
            0x11 => .timestamp,
            0x12 => .int64,
            0x13 => .decimal128,
            0xFF => .min_key,
            0x7F => .max_key,
            else => null,
        };
    }
};

/// BSON binary subtype.
///
/// The `_` makes this enum non-exhaustive so BSON subtypes that Bongo
/// does not know about yet can still be represented.
pub const BinarySubtype = enum(u8) {
    generic = 0x00,
    function = 0x01,
    old_binary = 0x02,
    old_uuid = 0x03,
    uuid = 0x04,
    md5 = 0x05,
    encrypted = 0x06,
    compressed_column = 0x07,
    sensitive = 0x08,
    vector = 0x09,

    _,

    pub fn byte(subtype: BinarySubtype) u8 {
        return @intFromEnum(subtype);
    }

    pub fn fromByte(byte_value: u8) BinarySubtype {
        return @enumFromInt(byte_value);
    }

    pub fn userDefined(value: u8) BinarySubtype {
        std.debug.assert(value >= 0x80);
        return @enumFromInt(value);
    }
};

pub const DateTime = struct {
    milliseconds: i64,
};

pub const Decimal128 = struct {
    bytes: [16]u8,
};

pub const Undefined = struct {};
pub const Null = struct {};
pub const MinKey = struct {};
pub const MaxKey = struct {};

pub const JavaScript = struct {
    code: []const u8,
};

pub const Symbol = struct {
    value: []const u8,
};

pub const Timestamp = struct {
    increment: u32,
    seconds: u32,
};

pub const Binary = struct {
    subtype: BinarySubtype = .generic,
    data: []const u8,
};

pub const Regex = struct {
    pattern: []const u8,
    options: []const u8,
};

pub const DbPointer = struct {
    namespace: []const u8,
    id: ObjectId,
};

pub const JavaScriptWithScope = struct {
    code: []const u8,

    /// Complete encoded BSON document.
    scope: []const u8,
};

pub const Value = union(Type) {
    double: f64,
    string: []const u8,
    document: []const u8,
    array: []const u8,
    binary: Binary,
    undefined_value: void,
    object_id: ObjectId,
    boolean: bool,
    datetime: DateTime,
    null_value: void,
    regex: Regex,
    db_pointer: DbPointer,
    javascript: JavaScript,
    symbol: Symbol,
    javascript_with_scope: JavaScriptWithScope,
    int32: i32,
    timestamp: Timestamp,
    int64: i64,
    decimal128: Decimal128,
    min_key: void,
    max_key: void,
};

pub const Element = struct {
    name: []const u8,
    value: Value,
};

/// BSON regex options must be alphabetically ordered and may only contain
/// the supported option characters.
pub fn isCanonicalRegexOptions(options: []const u8) bool {
    if (std.mem.findScalar(u8, options, 0) != null) {
        return false;
    }

    var previous: ?u8 = null;

    for (options) |option| {
        switch (option) {
            'i', 'm', 's', 'u', 'x' => {},
            else => return false,
        }

        if (previous) |p| {
            if (option <= p) {
                return false;
            }
        }

        previous = option;
    }

    return true;
}

test Type {
    const cases = [_]struct {
        value: Type,
        byte: u8,
    }{
        .{ .value = .double, .byte = 0x01 },
        .{ .value = .string, .byte = 0x02 },
        .{ .value = .document, .byte = 0x03 },
        .{ .value = .array, .byte = 0x04 },
        .{ .value = .binary, .byte = 0x05 },
        .{ .value = .undefined_value, .byte = 0x06 },
        .{ .value = .object_id, .byte = 0x07 },
        .{ .value = .boolean, .byte = 0x08 },
        .{ .value = .datetime, .byte = 0x09 },
        .{ .value = .null_value, .byte = 0x0A },
        .{ .value = .regex, .byte = 0x0B },
        .{ .value = .db_pointer, .byte = 0x0C },
        .{ .value = .javascript, .byte = 0x0D },
        .{ .value = .symbol, .byte = 0x0E },
        .{ .value = .javascript_with_scope, .byte = 0x0F },
        .{ .value = .int32, .byte = 0x10 },
        .{ .value = .timestamp, .byte = 0x11 },
        .{ .value = .int64, .byte = 0x12 },
        .{ .value = .decimal128, .byte = 0x13 },
        .{ .value = .max_key, .byte = 0x7F },
        .{ .value = .min_key, .byte = 0xFF },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.byte,
            case.value.byte(),
        );

        try std.testing.expectEqual(
            case.value,
            Type.fromByte(case.byte).?,
        );
    }

    try std.testing.expectEqual(
        null,
        Type.fromByte(0x20),
    );
}

test BinarySubtype {
    const subtype =
        BinarySubtype.userDefined(0x80);

    try std.testing.expectEqual(
        @as(u8, 0x80),
        subtype.byte(),
    );

    const unknown =
        BinarySubtype.fromByte(0x42);

    try std.testing.expectEqual(
        @as(u8, 0x42),
        unknown.byte(),
    );
}

test "regex options are canonical" {
    try std.testing.expect(
        isCanonicalRegexOptions(""),
    );

    try std.testing.expect(
        isCanonicalRegexOptions("im"),
    );

    try std.testing.expect(
        !isCanonicalRegexOptions("mi"),
    );

    try std.testing.expect(
        !isCanonicalRegexOptions("ii"),
    );

    try std.testing.expect(
        !isCanonicalRegexOptions("z"),
    );
}
