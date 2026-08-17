const std = @import("std");
const types = @import("types.zig");

const Reader = @This();

const Type = types.Type;
const Value = types.Value;
const Element = types.Element;
const Binary = types.Binary;
const BinarySubtype = types.BinarySubtype;
const JavaScriptWithScope = types.JavaScriptWithScope;

bytes: []const u8,
position: usize,
end: usize,

pub const Error = error{
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
};

pub fn init(document_bytes: []const u8) Error!Reader {
    try validateEnvelope(document_bytes);

    return .{
        .bytes = document_bytes,
        .position = 4,
        .end = document_bytes.len - 1,
    };
}

pub fn next(reader: *Reader) Error!?Element {
    if (reader.position == reader.end) {
        return null;
    }

    if (reader.position > reader.end) {
        return error.UnexpectedEnd;
    }

    const type_byte =
        try reader.readByte();

    const element_type =
        Type.fromByte(type_byte) orelse
        return error.UnknownType;

    const name =
        try reader.readCString();

    const value =
        try reader.readValue(element_type);

    return .{
        .name = name,
        .value = value,
    };
}

pub fn get(
    document_bytes: []const u8,
    name: []const u8,
) Error!?Value {
    var reader =
        try Reader.init(document_bytes);

    while (try reader.next()) |element| {
        if (std.mem.eql(
            u8,
            element.name,
            name,
        )) {
            return element.value;
        }
    }

    return null;
}

fn readValue(
    reader: *Reader,
    element_type: Type,
) Error!Value {
    return switch (element_type) {
        .double => .{
            .double = @bitCast(
                try reader.readIntRaw(u64),
            ),
        },

        .string => .{
            .string = try reader.readString(),
        },

        .document => .{
            .document = try reader.readEmbeddedDocument(),
        },

        .array => .{
            .array = try reader.readEmbeddedArray(),
        },

        .binary => .{
            .binary = try reader.readBinary(),
        },

        .undefined_value => .{
            .undefined_value = {},
        },

        .object_id => .{
            .object_id = .{
                .bytes = try reader.readArray(12),
            },
        },

        .boolean => .{
            .boolean = try reader.readBool(),
        },

        .datetime => .{
            .datetime = .{
                .milliseconds = try reader.readIntRaw(i64),
            },
        },

        .null_value => .{
            .null_value = {},
        },

        .regex => .{
            .regex = .{
                .pattern = try reader.readCString(),

                .options = options: {
                    const options =
                        try reader.readCString();

                    if (!types.isCanonicalRegexOptions(
                        options,
                    )) {
                        return error.InvalidRegexOptions;
                    }

                    break :options options;
                },
            },
        },

        .db_pointer => .{
            .db_pointer = .{
                .namespace = try reader.readString(),

                .id = .{
                    .bytes = try reader.readArray(12),
                },
            },
        },

        .javascript => .{
            .javascript = .{
                .code = try reader.readString(),
            },
        },

        .symbol => .{
            .symbol = .{
                .value = try reader.readString(),
            },
        },

        .javascript_with_scope => .{
            .javascript_with_scope = try reader.readCodeWithScope(),
        },

        .int32 => .{
            .int32 = try reader.readIntRaw(i32),
        },

        .timestamp => .{
            .timestamp = .{
                .increment = try reader.readIntRaw(u32),

                .seconds = try reader.readIntRaw(u32),
            },
        },

        .int64 => .{
            .int64 = try reader.readIntRaw(i64),
        },

        .decimal128 => .{
            .decimal128 = .{
                .bytes = try reader.readArray(16),
            },
        },

        .min_key => .{
            .min_key = {},
        },

        .max_key => .{
            .max_key = {},
        },
    };
}

fn readBinary(
    reader: *Reader,
) Error!Binary {
    const len_i32 = try reader.readIntRaw(i32);

    if (len_i32 < 0) {
        return error.InvalidBinaryLength;
    }

    const len: usize =
        @intCast(len_i32);

    const subtype =
        BinarySubtype.fromByte(
            try reader.readByte(),
        );

    if (subtype == .old_binary) {
        if (len < 4) {
            return error.InvalidOldBinaryLength;
        }

        const inner_i32 =
            try reader.readIntRaw(i32);

        if (inner_i32 < 0) {
            return error.InvalidOldBinaryLength;
        }

        const inner: usize =
            @intCast(inner_i32);

        if (inner + 4 != len) {
            return error.InvalidOldBinaryLength;
        }

        return .{
            .subtype = subtype,
            .data = try reader.readBytes(inner),
        };
    }

    return .{
        .subtype = subtype,
        .data = try reader.readBytes(len),
    };
}

fn readCodeWithScope(
    reader: *Reader,
) Error!JavaScriptWithScope {
    const start =
        reader.position;

    const total_i32 =
        try reader.readIntRaw(i32);

    // Minimum possible code-with-scope:
    //
    // 4 bytes total size
    // 5 bytes empty BSON string
    // 5 bytes empty BSON document
    //
    // = 14 bytes
    if (total_i32 < 14) {
        return error.InvalidCodeWithScopeLength;
    }

    const total: usize =
        @intCast(total_i32);

    if (total > reader.end - start) {
        return error.InvalidCodeWithScopeLength;
    }

    const expected_end =
        start + total;

    const code =
        try reader.readString();

    const scope =
        try reader.readEmbeddedDocument();

    if (reader.position != expected_end) {
        return error.InvalidCodeWithScopeLength;
    }

    return .{
        .code = code,
        .scope = scope,
    };
}

fn readEmbeddedDocument(
    reader: *Reader,
) Error![]const u8 {
    const document =
        try reader.readEmbeddedRaw();

    try validateDocument(document);

    return document;
}

fn readEmbeddedArray(
    reader: *Reader,
) Error![]const u8 {
    const document =
        try reader.readEmbeddedRaw();

    try validateArray(document);

    return document;
}

fn readEmbeddedRaw(
    reader: *Reader,
) Error![]const u8 {
    if (reader.position + 4 > reader.end) {
        return error.UnexpectedEnd;
    }

    const len_i32 =
        readI32At(
            reader.bytes,
            reader.position,
        ) catch {
            return error.UnexpectedEnd;
        };

    if (len_i32 < 5) {
        return error.InvalidDocumentLength;
    }

    const len: usize =
        @intCast(len_i32);

    if (len >
        reader.end - reader.position)
    {
        return error.UnexpectedEnd;
    }

    const result =
        reader.bytes[reader.position .. reader.position + len];

    reader.position += len;

    return result;
}

fn readString(
    reader: *Reader,
) Error![]const u8 {
    const len_i32 =
        try reader.readIntRaw(i32);

    if (len_i32 <= 0) {
        return error.InvalidStringLength;
    }

    const len: usize =
        @intCast(len_i32);

    const raw =
        try reader.readBytes(len);

    if (raw[raw.len - 1] != 0) {
        return error.InvalidStringTerminator;
    }

    const value =
        raw[0 .. raw.len - 1];

    if (!std.unicode.utf8ValidateSlice(
        value,
    )) {
        return error.InvalidUtf8;
    }

    return value;
}

fn readCString(
    reader: *Reader,
) Error![]const u8 {
    const remaining =
        reader.bytes[reader.position..reader.end];

    const relative_end =
        std.mem.findScalar(
            u8,
            remaining,
            0,
        ) orelse {
            return error.InvalidCString;
        };

    const value =
        remaining[0..relative_end];

    if (!std.unicode.utf8ValidateSlice(
        value,
    )) {
        return error.InvalidUtf8;
    }

    reader.position +=
        relative_end + 1;

    return value;
}

fn readBool(
    reader: *Reader,
) Error!bool {
    return switch (try reader.readByte()) {
        0x00 => false,
        0x01 => true,
        else => error.InvalidBoolean,
    };
}

fn readByte(
    reader: *Reader,
) Error!u8 {
    if (reader.position >= reader.end) {
        return error.UnexpectedEnd;
    }

    const value =
        reader.bytes[reader.position];

    reader.position += 1;

    return value;
}

fn readBytes(
    reader: *Reader,
    count: usize,
) Error![]const u8 {
    if (count >
        reader.end - reader.position)
    {
        return error.UnexpectedEnd;
    }

    const result =
        reader.bytes[reader.position .. reader.position + count];

    reader.position += count;

    return result;
}

fn readArray(
    reader: *Reader,
    comptime N: usize,
) Error![N]u8 {
    const raw =
        try reader.readBytes(N);

    var result: [N]u8 =
        undefined;

    @memcpy(
        &result,
        raw,
    );

    return result;
}

fn readIntRaw(
    reader: *Reader,
    comptime T: type,
) Error!T {
    const raw =
        try reader.readBytes(
            @sizeOf(T),
        );

    var buffer: [@sizeOf(T)]u8 =
        undefined;

    @memcpy(
        &buffer,
        raw,
    );

    return std.mem.readInt(
        T,
        &buffer,
        .little,
    );
}

/// Validate a complete BSON document.
pub fn validateDocument(
    document_bytes: []const u8,
) Error!void {
    var reader =
        try Reader.init(document_bytes);

    while (try reader.next()) |_| {}

    if (reader.position != reader.end) {
        return error.InvalidDocumentLength;
    }
}

/// Validate a BSON array document.
///
/// BSON arrays are encoded as documents whose keys are
/// "0", "1", "2", ... in order.
pub fn validateArray(
    document_bytes: []const u8,
) Error!void {
    var reader =
        try Reader.init(document_bytes);

    var expected_index: usize = 0;

    while (try reader.next()) |element| : (expected_index += 1) {
        var key_buffer: [32]u8 =
            undefined;

        const expected =
            std.fmt.bufPrint(
                &key_buffer,
                "{d}",
                .{expected_index},
            ) catch unreachable;

        if (!std.mem.eql(
            u8,
            element.name,
            expected,
        )) {
            return error.InvalidArrayIndex;
        }
    }
}

fn validateEnvelope(
    document_bytes: []const u8,
) Error!void {
    if (document_bytes.len < 5) {
        return error.InvalidDocumentLength;
    }

    const declared =
        try readI32At(
            document_bytes,
            0,
        );

    if (declared < 5) {
        return error.InvalidDocumentLength;
    }

    const declared_usize: usize =
        @intCast(declared);

    if (declared_usize !=
        document_bytes.len)
    {
        return error.InvalidDocumentLength;
    }

    if (document_bytes[
        document_bytes.len - 1
    ] != 0) {
        return error.InvalidDocumentTerminator;
    }
}

fn readI32At(
    bytes: []const u8,
    offset: usize,
) Error!i32 {
    if (offset + 4 > bytes.len) {
        return error.UnexpectedEnd;
    }

    var buffer: [4]u8 =
        undefined;

    @memcpy(
        &buffer,
        bytes[offset .. offset + 4],
    );

    return std.mem.readInt(
        i32,
        &buffer,
        .little,
    );
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "document validation rejects invalid envelopes" {
    try std.testing.expectError(
        error.InvalidDocumentLength,
        validateDocument(
            &.{ 4, 0, 0, 0 },
        ),
    );

    try std.testing.expectError(
        error.InvalidDocumentLength,
        validateDocument(
            &.{ 6, 0, 0, 0, 0 },
        ),
    );

    try std.testing.expectError(
        error.InvalidDocumentTerminator,
        validateDocument(
            &.{ 5, 0, 0, 0, 1 },
        ),
    );
}

test "reader rejects unknown type" {
    const bytes = [_]u8{
        8,    0,   0, 0,
        0x20, 'x', 0, 0,
    };

    try std.testing.expectError(
        error.UnknownType,
        validateDocument(&bytes),
    );
}

test "reader rejects invalid boolean" {
    const bytes = [_]u8{
        9,    0,   0, 0,
        0x08, 'x', 0, 2,
        0,
    };

    try std.testing.expectError(
        error.InvalidBoolean,
        validateDocument(&bytes),
    );
}

test "reader rejects invalid string length" {
    const bytes = [_]u8{
        12,   0,   0, 0,
        0x02, 'x', 0, 0,
        0,    0,   0, 0,
    };

    try std.testing.expectError(
        error.InvalidStringLength,
        validateDocument(&bytes),
    );
}

test "reader rejects invalid string terminator" {
    const bytes = [_]u8{
        14,   0,   0, 0,
        0x02, 'x', 0, 2,
        0,    0,   0, 'a',
        'b',  0,
    };

    try std.testing.expectError(
        error.InvalidStringTerminator,
        validateDocument(&bytes),
    );
}

test "reader rejects truncated payload" {
    const bytes = [_]u8{
        12,   0,   0, 0,
        0x12, 'x', 0, 1,
        2,    3,   4, 0,
    };

    try std.testing.expectError(
        error.UnexpectedEnd,
        validateDocument(&bytes),
    );
}

test "reader rejects invalid UTF-8" {
    const bytes = [_]u8{
        14,   0,   0, 0,
        0x02, 'x', 0, 2,
        0,    0,   0, 0xFF,
        0,    0,
    };

    try std.testing.expectError(
        error.InvalidUtf8,
        validateDocument(&bytes),
    );
}

test "reader rejects cstring without terminator" {
    const valid = [_]u8{
        8,    0,   0, 0,
        0x0A, 'x', 0, 0,
    };

    const malformed = [_]u8{
        8,    0,   0,   0,
        0x0A, 'x', 'y', 0,
    };

    try std.testing.expectError(
        error.InvalidCString,
        validateDocument(&malformed),
    );

    try validateDocument(&valid);
}

test "reader rejects negative binary length" {
    const bytes = [_]u8{
        13,   0,    0,    0,
        0x05, 'b',  0,    0xFF,
        0xFF, 0xFF, 0xFF, 0x00,
        0x00,
    };

    try std.testing.expectError(
        error.InvalidBinaryLength,
        validateDocument(&bytes),
    );
}

test "reader rejects malformed code-with-scope total length" {
    const bytes = [_]u8{
        23,   0,   0, 0,

        0x0F, 'c', 0,

        // Incorrectly declares 16 bytes.
        16,
        0,    0,   0,

        // code = "x"
        2,
        0,    0,   0, 'x',
        0,

        // empty scope document
           5,   0, 0,
        0,    0,

        // outer document terminator
          0,
    };

    try std.testing.expectError(
        error.InvalidCodeWithScopeLength,
        validateDocument(&bytes),
    );
}

test "reader rejects non-canonical regex options" {
    const bytes = [_]u8{
        13,   0,   0,   0,

        0x0B, 'r', 0,   'x',
        0,    'm', 'i', 0,

        0,
    };

    try std.testing.expectError(
        error.InvalidRegexOptions,
        validateDocument(&bytes),
    );
}

test "validateArray requires sequential numeric keys" {
    const bytes = [_]u8{
        23,   0,    0,   0,

        0x02, '0',  0,   2,
        0,    0,    0,   'a',
        0,    0x02, '2', 0,
        2,    0,    0,   0,
        'b',  0,    0,
    };

    try std.testing.expectError(
        error.InvalidArrayIndex,
        validateArray(&bytes),
    );
}

test "Reader.get returns value or null" {
    const bytes = [_]u8{
        20,   0,   0,   0,

        0x02, 'n', 'a', 'm',
        'e',  0,   5,   0,
        0,    0,   'J', 'o',
        'h',  'n', 0,   0,
    };

    const name =
        (try Reader.get(
            &bytes,
            "name",
        )).?;

    try std.testing.expectEqual(
        Type.string,
        std.meta.activeTag(name),
    );

    try std.testing.expectEqualStrings(
        "John",
        name.string,
    );

    try std.testing.expect(
        (try Reader.get(
            &bytes,
            "age",
        )) == null,
    );
}
