const std = @import("std");

pub const Error = error{
    AlreadyFinished,
    DocumentTooLarge,
    InvalidDocumentLength,
    InvalidDocumentTerminator,
    InvalidCString,
    InvalidUtf8,
    InvalidStringLength,
    InvalidStringTerminator,
    InvalidBoolean,
    InvalidBinaryLength,
    InvalidOldBinaryLength,
    InvalidRegexOptions,
    InvalidCodeWithScopeLength,
    InvalidArrayIndex,
    UnexpectedEnd,
    UnknownType,
    UnsupportedInteger,
    UnsupportedPointer,
    UnsupportedType,
    InvalidObjectIdHex,
};

pub const Type = enum(i8) {
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
    min_key = -1,
    max_key = 0x7F,

    pub fn byte(self: Type) u8 {
        const signed: i8 = @intFromEnum(self);
        return @bitCast(signed);
    }

    pub fn fromByte(byte_value: u8) Error!Type {
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
            else => error.UnknownType,
        };
    }
};

pub const BinarySubtype = struct {
    value: u8,

    pub const generic = BinarySubtype{ .value = 0x00 };
    pub const function = BinarySubtype{ .value = 0x01 };
    pub const old_binary = BinarySubtype{ .value = 0x02 };
    pub const old_uuid = BinarySubtype{ .value = 0x03 };
    pub const uuid = BinarySubtype{ .value = 0x04 };
    pub const md5 = BinarySubtype{ .value = 0x05 };
    pub const encrypted = BinarySubtype{ .value = 0x06 };
    pub const compressed_column = BinarySubtype{ .value = 0x07 };
    pub const sensitive = BinarySubtype{ .value = 0x08 };
    pub const vector = BinarySubtype{ .value = 0x09 };

    pub fn userDefined(value: u8) BinarySubtype {
        std.debug.assert(value >= 0x80);
        return .{ .value = value };
    }
};

pub const ObjectId = struct {
    bytes: [12]u8,

    pub fn fromHex(hex: []const u8) Error!ObjectId {
        if (hex.len != 24) return error.InvalidObjectIdHex;
        var out: [12]u8 = undefined;
        for (0..12) |i| {
            const hi = hexNibble(hex[i * 2]) orelse return error.InvalidObjectIdHex;
            const lo = hexNibble(hex[i * 2 + 1]) orelse return error.InvalidObjectIdHex;
            out[i] = (hi << 4) | lo;
        }
        return .{ .bytes = out };
    }

    pub fn toHex(self: ObjectId) [24]u8 {
        const digits = "0123456789abcdef";
        var out: [24]u8 = undefined;
        for (self.bytes, 0..) |b, i| {
            out[i * 2] = digits[b >> 4];
            out[i * 2 + 1] = digits[b & 0x0F];
        }
        return out;
    }

    fn hexNibble(c: u8) ?u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }
};

pub const DateTime = struct { milliseconds: i64 };
pub const Decimal128 = struct { bytes: [16]u8 };
pub const Undefined = struct {};
pub const Null = struct {};
pub const MinKey = struct {};
pub const MaxKey = struct {};
pub const JavaScript = struct { code: []const u8 };
pub const Symbol = struct { value: []const u8 };

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
    scope: []const u8, // complete encoded BSON document
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

test "Type maps every BSON element type to the correct wire byte" {
    const cases = [_]struct { t: Type, b: u8 }{
        .{ .t = .double, .b = 0x01 },
        .{ .t = .string, .b = 0x02 },
        .{ .t = .document, .b = 0x03 },
        .{ .t = .array, .b = 0x04 },
        .{ .t = .binary, .b = 0x05 },
        .{ .t = .undefined_value, .b = 0x06 },
        .{ .t = .object_id, .b = 0x07 },
        .{ .t = .boolean, .b = 0x08 },
        .{ .t = .datetime, .b = 0x09 },
        .{ .t = .null_value, .b = 0x0A },
        .{ .t = .regex, .b = 0x0B },
        .{ .t = .db_pointer, .b = 0x0C },
        .{ .t = .javascript, .b = 0x0D },
        .{ .t = .symbol, .b = 0x0E },
        .{ .t = .javascript_with_scope, .b = 0x0F },
        .{ .t = .int32, .b = 0x10 },
        .{ .t = .timestamp, .b = 0x11 },
        .{ .t = .int64, .b = 0x12 },
        .{ .t = .decimal128, .b = 0x13 },
        .{ .t = .min_key, .b = 0xFF },
        .{ .t = .max_key, .b = 0x7F },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.b, case.t.byte());
        try std.testing.expectEqual(case.t, try Type.fromByte(case.b));
    }

    try std.testing.expectError(error.UnknownType, Type.fromByte(0x20));
}

test "ObjectId hex round trip and errors" {
    const oid = try ObjectId.fromHex("507f1f77bcf86cd799439011");
    const hex = oid.toHex();
    try std.testing.expectEqualStrings("507f1f77bcf86cd799439011", &hex);

    const upper = try ObjectId.fromHex("507F1F77BCF86CD799439011");
    try std.testing.expectEqualSlices(u8, &oid.bytes, &upper.bytes);

    try std.testing.expectError(error.InvalidObjectIdHex, ObjectId.fromHex("1234"));
    try std.testing.expectError(error.InvalidObjectIdHex, ObjectId.fromHex("507f1f77bcf86cd79943901z"));
}

test "user defined binary subtype preserves its byte" {
    const subtype = BinarySubtype.userDefined(0x80);
    try std.testing.expectEqual(@as(u8, 0x80), subtype.value);
}
