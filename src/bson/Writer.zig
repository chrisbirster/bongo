const std = @import("std");
const types = @import("types.zig");

const Writer = @This();
const Reader = @import("Reader.zig");

const Allocator = std.mem.Allocator;

const Type = types.Type;
const Value = types.Value;

allocator: Allocator,
bytes: std.ArrayList(u8) = .empty,
finished: bool = false,

pub const Error =
    Allocator.Error ||
    Reader.Error ||
    error{
        AlreadyFinished,
        DocumentTooLarge,
    };

pub fn init(
    allocator: Allocator,
) Allocator.Error!Writer {
    var writer = Writer{
        .allocator = allocator,
    };

    errdefer writer.deinit();

    // BSON documents begin with a 4-byte length.
    // We do not know it yet, so reserve four bytes.
    try writer.bytes.appendSlice(
        allocator,
        &.{ 0, 0, 0, 0 },
    );

    return writer;
}

pub fn deinit(
    writer: *Writer,
) void {
    writer.bytes.deinit(
        writer.allocator,
    );

    writer.* = undefined;
}

pub fn finish(
    writer: *Writer,
) Error![]u8 {
    if (writer.finished) {
        return error.AlreadyFinished;
    }

    // Every BSON document ends with 0x00.
    try writer.bytes.append(
        writer.allocator,
        0x00,
    );

    const len_i32 =
        try checkedI32Len(
            writer.bytes.items.len,
        );

    var len_bytes: [4]u8 =
        undefined;

    std.mem.writeInt(
        i32,
        &len_bytes,
        len_i32,
        .little,
    );

    @memcpy(
        writer.bytes.items[0..4],
        &len_bytes,
    );

    writer.finished = true;

    return writer.bytes.toOwnedSlice(
        writer.allocator,
    );
}

pub fn writeValue(
    writer: *Writer,
    name: []const u8,
    value: Value,
) Error!void {
    switch (value) {
        .double => |v| try writer.writeDouble(name, v),

        .string => |v| try writer.writeString(name, v),

        .document => |v| try writer.writeDocument(name, v),

        .array => |v| try writer.writeArray(name, v),

        .binary => |v| try writer.writeBinary(name, v),

        .undefined_value => try writer.writeUndefined(name),

        .object_id => |v| try writer.writeObjectId(name, v),

        .boolean => |v| try writer.writeBool(name, v),

        .datetime => |v| try writer.writeDateTime(name, v),

        .null_value => try writer.writeNull(name),

        .regex => |v| try writer.writeRegex(name, v),

        .db_pointer => |v| try writer.writeDbPointer(name, v),

        .javascript => |v| try writer.writeJavaScript(name, v),

        .symbol => |v| try writer.writeSymbol(name, v),

        .javascript_with_scope => |v| try writer.writeJavaScriptWithScope(
            name,
            v,
        ),

        .int32 => |v| try writer.writeInt32(name, v),

        .timestamp => |v| try writer.writeTimestamp(name, v),

        .int64 => |v| try writer.writeInt64(name, v),

        .decimal128 => |v| try writer.writeDecimal128(name, v),

        .min_key => try writer.writeMinKey(name),

        .max_key => try writer.writeMaxKey(name),
    }
}

pub fn writeDouble(
    writer: *Writer,
    name: []const u8,
    value: f64,
) Error!void {
    try writer.writeElementHeader(
        .double,
        name,
    );

    try writer.writeIntRaw(
        u64,
        @bitCast(value),
    );
}

pub fn writeString(
    writer: *Writer,
    name: []const u8,
    value: []const u8,
) Error!void {
    if (!std.unicode.utf8ValidateSlice(
        value,
    )) {
        return error.InvalidUtf8;
    }

    try writer.writeElementHeader(
        .string,
        name,
    );

    try writer.writeStringRaw(
        value,
    );
}

pub fn writeDocument(
    writer: *Writer,
    name: []const u8,
    document_bytes: []const u8,
) Error!void {
    try Reader.validateDocument(
        document_bytes,
    );

    try writer.writeElementHeader(
        .document,
        name,
    );

    try writer.bytes.appendSlice(
        writer.allocator,
        document_bytes,
    );
}

pub fn writeArray(
    writer: *Writer,
    name: []const u8,
    array_document_bytes: []const u8,
) Error!void {
    try Reader.validateArray(
        array_document_bytes,
    );

    try writer.writeElementHeader(
        .array,
        name,
    );

    try writer.bytes.appendSlice(
        writer.allocator,
        array_document_bytes,
    );
}

pub fn writeBinary(
    writer: *Writer,
    name: []const u8,
    value: types.Binary,
) Error!void {
    try writer.writeElementHeader(
        .binary,
        name,
    );

    if (value.subtype == .old_binary) {
        const outer_len =
            try checkedI32Len(
                value.data.len + 4,
            );

        try writer.writeIntRaw(
            i32,
            outer_len,
        );

        try writer.bytes.append(
            writer.allocator,
            value.subtype.byte(),
        );

        try writer.writeIntRaw(
            i32,
            try checkedI32Len(
                value.data.len,
            ),
        );

        try writer.bytes.appendSlice(
            writer.allocator,
            value.data,
        );

        return;
    }

    try writer.writeIntRaw(
        i32,
        try checkedI32Len(
            value.data.len,
        ),
    );

    try writer.bytes.append(
        writer.allocator,
        value.subtype.byte(),
    );

    try writer.bytes.appendSlice(
        writer.allocator,
        value.data,
    );
}

pub fn writeUndefined(
    writer: *Writer,
    name: []const u8,
) Error!void {
    try writer.writeElementHeader(
        .undefined_value,
        name,
    );
}

pub fn writeObjectId(
    writer: *Writer,
    name: []const u8,
    value: types.ObjectId,
) Error!void {
    try writer.writeElementHeader(
        .object_id,
        name,
    );

    try writer.bytes.appendSlice(
        writer.allocator,
        &value.bytes,
    );
}

pub fn writeBool(
    writer: *Writer,
    name: []const u8,
    value: bool,
) Error!void {
    try writer.writeElementHeader(
        .boolean,
        name,
    );

    try writer.bytes.append(
        writer.allocator,
        if (value) 0x01 else 0x00,
    );
}

pub fn writeDateTime(
    writer: *Writer,
    name: []const u8,
    value: types.DateTime,
) Error!void {
    try writer.writeElementHeader(
        .datetime,
        name,
    );

    try writer.writeIntRaw(
        i64,
        value.milliseconds,
    );
}

pub fn writeNull(
    writer: *Writer,
    name: []const u8,
) Error!void {
    try writer.writeElementHeader(
        .null_value,
        name,
    );
}

pub fn writeRegex(
    writer: *Writer,
    name: []const u8,
    value: types.Regex,
) Error!void {
    if (std.mem.findScalar(
        u8,
        value.options,
        0,
    ) != null) {
        return error.InvalidCString;
    }

    if (!types.isCanonicalRegexOptions(
        value.options,
    )) {
        return error.InvalidRegexOptions;
    }

    try writer.writeElementHeader(
        .regex,
        name,
    );

    try writer.writeCStringRaw(
        value.pattern,
    );

    try writer.writeCStringRaw(
        value.options,
    );
}

pub fn writeDbPointer(
    writer: *Writer,
    name: []const u8,
    value: types.DbPointer,
) Error!void {
    try writer.writeElementHeader(
        .db_pointer,
        name,
    );

    try writer.writeStringRaw(
        value.namespace,
    );

    try writer.bytes.appendSlice(
        writer.allocator,
        &value.id.bytes,
    );
}

pub fn writeJavaScript(
    writer: *Writer,
    name: []const u8,
    value: types.JavaScript,
) Error!void {
    try writer.writeElementHeader(
        .javascript,
        name,
    );

    try writer.writeStringRaw(
        value.code,
    );
}

pub fn writeSymbol(
    writer: *Writer,
    name: []const u8,
    value: types.Symbol,
) Error!void {
    try writer.writeElementHeader(
        .symbol,
        name,
    );

    try writer.writeStringRaw(
        value.value,
    );
}

pub fn writeJavaScriptWithScope(
    writer: *Writer,
    name: []const u8,
    value: types.JavaScriptWithScope,
) Error!void {
    try Reader.validateDocument(
        value.scope,
    );

    if (!std.unicode.utf8ValidateSlice(
        value.code,
    )) {
        return error.InvalidUtf8;
    }

    try writer.writeElementHeader(
        .javascript_with_scope,
        name,
    );

    const total_len =
        4 +
        4 +
        value.code.len +
        1 +
        value.scope.len;

    try writer.writeIntRaw(
        i32,
        try checkedI32Len(total_len),
    );

    try writer.writeStringRaw(
        value.code,
    );

    try writer.bytes.appendSlice(
        writer.allocator,
        value.scope,
    );
}

pub fn writeInt32(
    writer: *Writer,
    name: []const u8,
    value: i32,
) Error!void {
    try writer.writeElementHeader(
        .int32,
        name,
    );

    try writer.writeIntRaw(
        i32,
        value,
    );
}

pub fn writeTimestamp(
    writer: *Writer,
    name: []const u8,
    value: types.Timestamp,
) Error!void {
    try writer.writeElementHeader(
        .timestamp,
        name,
    );

    try writer.writeIntRaw(
        u32,
        value.increment,
    );

    try writer.writeIntRaw(
        u32,
        value.seconds,
    );
}

pub fn writeInt64(
    writer: *Writer,
    name: []const u8,
    value: i64,
) Error!void {
    try writer.writeElementHeader(
        .int64,
        name,
    );

    try writer.writeIntRaw(
        i64,
        value,
    );
}

pub fn writeDecimal128(
    writer: *Writer,
    name: []const u8,
    value: types.Decimal128,
) Error!void {
    try writer.writeElementHeader(
        .decimal128,
        name,
    );

    try writer.bytes.appendSlice(
        writer.allocator,
        &value.bytes,
    );
}

pub fn writeMinKey(
    writer: *Writer,
    name: []const u8,
) Error!void {
    try writer.writeElementHeader(
        .min_key,
        name,
    );
}

pub fn writeMaxKey(
    writer: *Writer,
    name: []const u8,
) Error!void {
    try writer.writeElementHeader(
        .max_key,
        name,
    );
}

fn writeElementHeader(
    writer: *Writer,
    element_type: Type,
    name: []const u8,
) Error!void {
    if (writer.finished) {
        return error.AlreadyFinished;
    }

    try writer.bytes.append(
        writer.allocator,
        element_type.byte(),
    );

    try writer.writeCStringRaw(
        name,
    );
}

fn writeCStringRaw(
    writer: *Writer,
    value: []const u8,
) Error!void {
    if (std.mem.findScalar(
        u8,
        value,
        0,
    ) != null) {
        return error.InvalidCString;
    }

    if (!std.unicode.utf8ValidateSlice(
        value,
    )) {
        return error.InvalidUtf8;
    }

    try writer.bytes.appendSlice(
        writer.allocator,
        value,
    );

    try writer.bytes.append(
        writer.allocator,
        0x00,
    );
}

fn writeStringRaw(
    writer: *Writer,
    value: []const u8,
) Error!void {
    if (!std.unicode.utf8ValidateSlice(
        value,
    )) {
        return error.InvalidUtf8;
    }

    const len =
        try checkedI32Len(
            value.len + 1,
        );

    try writer.writeIntRaw(
        i32,
        len,
    );

    try writer.bytes.appendSlice(
        writer.allocator,
        value,
    );

    try writer.bytes.append(
        writer.allocator,
        0x00,
    );
}

fn writeIntRaw(
    writer: *Writer,
    comptime T: type,
    value: T,
) Allocator.Error!void {
    var buffer: [@sizeOf(T)]u8 =
        undefined;

    std.mem.writeInt(
        T,
        &buffer,
        value,
        .little,
    );

    try writer.bytes.appendSlice(
        writer.allocator,
        &buffer,
    );
}

fn checkedI32Len(
    len: usize,
) error{DocumentTooLarge}!i32 {
    if (len >
        std.math.maxInt(i32))
    {
        return error.DocumentTooLarge;
    }

    return @intCast(len);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "empty BSON document is five bytes" {
    var writer =
        try Writer.init(
            std.testing.allocator,
        );

    defer writer.deinit();

    const bytes =
        try writer.finish();

    defer std.testing.allocator.free(
        bytes,
    );

    try std.testing.expectEqualSlices(
        u8,
        &.{ 5, 0, 0, 0, 0 },
        bytes,
    );

    try Reader.validateDocument(
        bytes,
    );
}

test "known BSON name John encoding" {
    var writer =
        try Writer.init(
            std.testing.allocator,
        );

    defer writer.deinit();

    try writer.writeString(
        "name",
        "John",
    );

    const bytes =
        try writer.finish();

    defer std.testing.allocator.free(
        bytes,
    );

    const expected = [_]u8{
        0x14, 0x00, 0x00, 0x00,

        0x02, 'n',  'a',  'm',
        'e',  0x00, 0x05, 0x00,
        0x00, 0x00, 'J',  'o',
        'h',  'n',  0x00, 0x00,
    };

    try std.testing.expectEqualSlices(
        u8,
        &expected,
        bytes,
    );
}

test "writer rejects invalid cstring and UTF-8" {
    var writer =
        try Writer.init(
            std.testing.allocator,
        );

    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidCString,
        writer.writeString(
            "bad\x00key",
            "x",
        ),
    );

    try std.testing.expectError(
        error.InvalidUtf8,
        writer.writeString(
            "name",
            "\xff",
        ),
    );
}

test "writer rejects invalid regex options" {
    var writer =
        try Writer.init(
            std.testing.allocator,
        );

    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRegexOptions,
        writer.writeRegex(
            "r",
            .{
                .pattern = "x",
                .options = "mi",
            },
        ),
    );

    try std.testing.expectError(
        error.InvalidRegexOptions,
        writer.writeRegex(
            "r",
            .{
                .pattern = "x",
                .options = "ii",
            },
        ),
    );

    try std.testing.expectError(
        error.InvalidRegexOptions,
        writer.writeRegex(
            "r",
            .{
                .pattern = "x",
                .options = "z",
            },
        ),
    );
}

test "finish can only be called once" {
    var writer =
        try Writer.init(
            std.testing.allocator,
        );

    defer writer.deinit();

    const bytes =
        try writer.finish();

    defer std.testing.allocator.free(
        bytes,
    );

    try std.testing.expectError(
        error.AlreadyFinished,
        writer.finish(),
    );
}

test "writer rejects malformed nested document" {
    var writer =
        try Writer.init(
            std.testing.allocator,
        );

    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidDocumentLength,
        writer.writeDocument(
            "document",
            &.{ 4, 0, 0, 0 },
        ),
    );
}

test "writer rejects malformed array indexes" {
    var writer =
        try Writer.init(
            std.testing.allocator,
        );

    defer writer.deinit();

    const invalid_array = [_]u8{
        14,   0,   0, 0,

        0x02, '1', 0, 2,
        0,    0,   0, 'x',
        0,    0,
    };

    try std.testing.expectError(
        error.InvalidArrayIndex,
        writer.writeArray(
            "array",
            &invalid_array,
        ),
    );
}

test "writer validates JavaScript with scope" {
    var writer =
        try Writer.init(
            std.testing.allocator,
        );

    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidDocumentLength,
        writer.writeJavaScriptWithScope(
            "value",
            .{
                .code = "return x",
                .scope = &.{ 4, 0, 0, 0 },
            },
        ),
    );

    const scope = [_]u8{
        5, 0, 0, 0, 0,
    };

    try std.testing.expectError(
        error.InvalidUtf8,
        writer.writeJavaScriptWithScope(
            "value",
            .{
                .code = "\xff",
                .scope = &scope,
            },
        ),
    );
}

test "checkedI32Len rejects oversized length" {
    try std.testing.expectEqual(
        @as(i32, 5),
        try checkedI32Len(5),
    );

    try std.testing.expectError(
        error.DocumentTooLarge,
        checkedI32Len(
            @as(
                usize,
                std.math.maxInt(i32),
            ) + 1,
        ),
    );
}

test "user-defined binary subtype survives round trip" {
    const allocator =
        std.testing.allocator;

    var writer =
        try Writer.init(allocator);

    defer writer.deinit();

    try writer.writeBinary(
        "data",
        .{
            .subtype = types.BinarySubtype
                .userDefined(0x80),

            .data = &.{ 9, 8 },
        },
    );

    const bytes =
        try writer.finish();

    defer allocator.free(bytes);

    const value =
        (try Reader.get(
            bytes,
            "data",
        )).?;

    try std.testing.expectEqual(
        @as(u8, 0x80),
        value.binary.subtype.byte(),
    );

    try std.testing.expectEqualSlices(
        u8,
        &.{ 9, 8 },
        value.binary.data,
    );
}

test "deprecated old binary subtype round trips" {
    const allocator =
        std.testing.allocator;

    var writer =
        try Writer.init(allocator);

    defer writer.deinit();

    try writer.writeBinary(
        "old",
        .{
            .subtype = .old_binary,
            .data = &.{ 10, 20, 30 },
        },
    );

    const bytes =
        try writer.finish();

    defer allocator.free(bytes);

    const value =
        (try Reader.get(
            bytes,
            "old",
        )).?;

    try std.testing.expectEqual(
        types.BinarySubtype.old_binary,
        value.binary.subtype,
    );

    try std.testing.expectEqualSlices(
        u8,
        &.{ 10, 20, 30 },
        value.binary.data,
    );

    var corrupted =
        try allocator.dupe(
            u8,
            bytes,
        );

    defer allocator.free(corrupted);

    // Header(4)
    // + type(1)
    // + "old\0"(4)
    // + outer length(4)
    // + subtype(1)
    const inner_len_offset =
        4 + 1 + 4 + 4 + 1;

    corrupted[
        inner_len_offset
    ] = 2;

    try std.testing.expectError(
        error.InvalidOldBinaryLength,
        Reader.validateDocument(
            corrupted,
        ),
    );
}

test "writeValue dispatches every Value branch" {
    const allocator =
        std.testing.allocator;

    const oid =
        try types.ObjectId.fromHex(
            "507f1f77bcf86cd799439011",
        );

    const empty_doc = [_]u8{
        5, 0, 0, 0, 0,
    };

    var array_writer =
        try Writer.init(allocator);

    defer array_writer.deinit();

    try array_writer.writeString(
        "0",
        "x",
    );

    const array_doc =
        try array_writer.finish();

    defer allocator.free(array_doc);

    var writer =
        try Writer.init(allocator);

    defer writer.deinit();

    try writer.writeValue(
        "v01",
        .{ .double = 1.5 },
    );

    try writer.writeValue(
        "v02",
        .{ .string = "s" },
    );

    try writer.writeValue(
        "v03",
        .{ .document = &empty_doc },
    );

    try writer.writeValue(
        "v04",
        .{ .array = array_doc },
    );

    try writer.writeValue(
        "v05",
        .{
            .binary = .{
                .data = &.{1},
            },
        },
    );

    try writer.writeValue(
        "v06",
        .{ .undefined_value = {} },
    );

    try writer.writeValue(
        "v07",
        .{ .object_id = oid },
    );

    try writer.writeValue(
        "v08",
        .{ .boolean = true },
    );

    try writer.writeValue(
        "v09",
        .{
            .datetime = .{
                .milliseconds = 1,
            },
        },
    );

    try writer.writeValue(
        "v10",
        .{ .null_value = {} },
    );

    try writer.writeValue(
        "v11",
        .{
            .regex = .{
                .pattern = "x",
                .options = "i",
            },
        },
    );

    try writer.writeValue(
        "v12",
        .{
            .db_pointer = .{
                .namespace = "db.c",
                .id = oid,
            },
        },
    );

    try writer.writeValue(
        "v13",
        .{
            .javascript = .{
                .code = "x",
            },
        },
    );

    try writer.writeValue(
        "v14",
        .{
            .symbol = .{
                .value = "x",
            },
        },
    );

    try writer.writeValue(
        "v15",
        .{
            .javascript_with_scope = .{
                .code = "x",
                .scope = &empty_doc,
            },
        },
    );

    try writer.writeValue(
        "v16",
        .{ .int32 = 1 },
    );

    try writer.writeValue(
        "v17",
        .{
            .timestamp = .{
                .increment = 1,
                .seconds = 2,
            },
        },
    );

    try writer.writeValue(
        "v18",
        .{ .int64 = 2 },
    );

    try writer.writeValue(
        "v19",
        .{
            .decimal128 = .{
                .bytes = [_]u8{0} ** 16,
            },
        },
    );

    try writer.writeValue(
        "v20",
        .{ .min_key = {} },
    );

    try writer.writeValue(
        "v21",
        .{ .max_key = {} },
    );

    const bytes =
        try writer.finish();

    defer allocator.free(bytes);

    try Reader.validateDocument(
        bytes,
    );

    var reader =
        try Reader.init(bytes);

    var count: usize = 0;

    while (try reader.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(
        @as(usize, 21),
        count,
    );
}
