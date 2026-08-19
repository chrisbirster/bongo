//! BSON encoding and decoding.

const std = @import("std");
const types = @import("bson/types.zig");
pub const Reader = @import("bson/Reader.zig");
pub const Writer = @import("bson/Writer.zig");

pub const ObjectId = types.ObjectId;
pub const Type = types.Type;
pub const BinarySubtype = types.BinarySubtype;
pub const DateTime = types.DateTime;
pub const Decimal128 = types.Decimal128;
pub const Undefined = types.Undefined;
pub const Null = types.Null;
pub const MinKey = types.MinKey;
pub const MaxKey = types.MaxKey;
pub const JavaScript = types.JavaScript;
pub const Symbol = types.Symbol;
pub const Timestamp = types.Timestamp;
pub const Binary = types.Binary;
pub const Regex = types.Regex;
pub const DbPointer = types.DbPointer;
pub const JavaScriptWithScope = types.JavaScriptWithScope;
pub const Value = types.Value;
pub const Element = types.Element;

/// Errors produced while decoding BSON.
pub const DecodeError =
    Reader.Error;

/// Errors produced by the high-level Zig-value encoder.
pub const EncodeError =
    Writer.Error ||
    error{
        UnsupportedInteger,
        UnsupportedPointer,
        UnsupportedType,
    };

pub const validateDocument = Reader.validateDocument;
pub const validateArray = Reader.validateArray;

/// Decode a complete BSON document into a streaming Reader.
///
/// Returned slices borrow from `document_bytes`.
pub fn decode(
    document_bytes: []const u8,
) DecodeError!Reader {
    return Reader.init(document_bytes);
}

/// Encode a Zig struct or anonymous struct into BSON.
pub fn encode(
    allocator: std.mem.Allocator,
    document: anytype,
) EncodeError![]u8 {
    const T = @TypeOf(document);

    if (@typeInfo(T) != .@"struct") {
        @compileError(
            "bson.encode expects a struct/anonymous struct document",
        );
    }

    var writer = try Writer.init(allocator);

    errdefer writer.deinit();

    try encodeStructFields(
        &writer,
        document,
    );

    return writer.finish();
}

fn encodeStructFields(
    writer: *Writer,
    value: anytype,
) EncodeError!void {
    const T = @TypeOf(value);

    inline for (@typeInfo(T).@"struct".fields) |field| {
        try encodeField(
            writer,
            field.name,
            @field(
                value,
                field.name,
            ),
        );
    }
}

fn encodeField(
    writer: *Writer,
    name: []const u8,
    value: anytype,
) EncodeError!void {
    const T =
        @TypeOf(value);

    // BSON-specific wrapper types.

    if (T == ObjectId) {
        return writer.writeObjectId(
            name,
            value,
        );
    }

    if (T == DateTime) {
        return writer.writeDateTime(
            name,
            value,
        );
    }

    if (T == Decimal128) {
        return writer.writeDecimal128(
            name,
            value,
        );
    }

    if (T == Undefined) {
        return writer.writeUndefined(
            name,
        );
    }

    if (T == Null) {
        return writer.writeNull(
            name,
        );
    }

    if (T == MinKey) {
        return writer.writeMinKey(
            name,
        );
    }

    if (T == MaxKey) {
        return writer.writeMaxKey(
            name,
        );
    }

    if (T == Binary) {
        return writer.writeBinary(
            name,
            value,
        );
    }

    if (T == Regex) {
        return writer.writeRegex(
            name,
            value,
        );
    }

    if (T == DbPointer) {
        return writer.writeDbPointer(
            name,
            value,
        );
    }

    if (T == JavaScript) {
        return writer.writeJavaScript(
            name,
            value,
        );
    }

    if (T == Symbol) {
        return writer.writeSymbol(
            name,
            value,
        );
    }

    if (T == JavaScriptWithScope) {
        return writer.writeJavaScriptWithScope(
            name,
            value,
        );
    }

    if (T == Timestamp) {
        return writer.writeTimestamp(
            name,
            value,
        );
    }

    if (T == Value) {
        return writer.writeValue(
            name,
            value,
        );
    }

    // Normal Zig values.

    switch (@typeInfo(T)) {
        .bool => {
            try writer.writeBool(
                name,
                value,
            );
        },

        .int => |info| {
            if (info.signedness ==
                .signed)
            {
                if (info.bits <= 32) {
                    try writer.writeInt32(
                        name,
                        @intCast(value),
                    );
                } else if (info.bits <= 64) {
                    try writer.writeInt64(
                        name,
                        @intCast(value),
                    );
                } else {
                    return error.UnsupportedInteger;
                }
            } else {
                const as_u64: u64 =
                    if (info.bits <= 64)
                        @intCast(value)
                    else
                        return error.UnsupportedInteger;

                if (as_u64 <=
                    std.math.maxInt(i32))
                {
                    try writer.writeInt32(
                        name,
                        @intCast(as_u64),
                    );
                } else if (as_u64 <=
                    @as(
                        u64,
                        std.math.maxInt(i64),
                    ))
                {
                    try writer.writeInt64(
                        name,
                        @intCast(as_u64),
                    );
                } else {
                    return error.UnsupportedInteger;
                }
            }
        },

        .comptime_int => {
            if (value >=
                std.math.minInt(i32) and
                value <=
                    std.math.maxInt(i32))
            {
                try writer.writeInt32(
                    name,
                    @intCast(value),
                );
            } else if (value >=
                std.math.minInt(i64) and
                value <=
                    std.math.maxInt(i64))
            {
                try writer.writeInt64(
                    name,
                    @intCast(value),
                );
            } else {
                return error.UnsupportedInteger;
            }
        },

        .float,
        .comptime_float,
        => {
            try writer.writeDouble(
                name,
                @floatCast(value),
            );
        },

        .optional => {
            if (value) |inner| {
                try encodeField(
                    writer,
                    name,
                    inner,
                );
            } else {
                try writer.writeNull(
                    name,
                );
            }
        },

        .@"struct" => {
            const nested =
                try encode(
                    writer.allocator,
                    value,
                );

            defer writer.allocator.free(
                nested,
            );

            try writer.writeDocument(
                name,
                nested,
            );
        },

        .array => {
            try encodeArrayValue(
                writer,
                name,
                value[0..],
            );
        },

        .pointer => |info| {
            switch (info.size) {
                .slice => {
                    if (info.child == u8) {
                        try writer.writeString(
                            name,
                            value,
                        );
                    } else {
                        try encodeArrayValue(
                            writer,
                            name,
                            value,
                        );
                    }
                },

                .one => switch (@typeInfo(info.child)) {
                    .array => |array_info| {
                        if (array_info.child ==
                            u8)
                        {
                            try writer.writeString(
                                name,
                                value[0..array_info.len],
                            );
                        } else {
                            try encodeArrayValue(
                                writer,
                                name,
                                value[0..array_info.len],
                            );
                        }
                    },

                    .@"struct" => {
                        try encodeField(
                            writer,
                            name,
                            value.*,
                        );
                    },

                    else => return error.UnsupportedPointer,
                },

                else => return error.UnsupportedPointer,
            }
        },

        else => return error.UnsupportedType,
    }
}

fn encodeArrayValue(
    parent: *Writer,
    name: []const u8,
    values: anytype,
) EncodeError!void {
    var writer =
        try Writer.init(
            parent.allocator,
        );

    defer writer.deinit();

    for (
        values,
        0..,
    ) |item, index| {
        var key_buffer: [32]u8 =
            undefined;

        const key =
            std.fmt.bufPrint(
                &key_buffer,
                "{d}",
                .{index},
            ) catch unreachable;

        try encodeField(
            &writer,
            key,
            item,
        );
    }

    const encoded =
        try writer.finish();

    defer parent.allocator.free(
        encoded,
    );

    try parent.writeArray(
        name,
        encoded,
    );
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test {
    _ = @import("bson/ObjectId.zig");
    _ = @import("bson/types.zig");
    _ = @import("bson/Reader.zig");
    _ = @import("bson/Writer.zig");
}

test "generic encoder creates Mongo find command" {
    const bytes =
        try encode(
            std.testing.allocator,
            .{
                .find = "users",

                .filter = .{
                    .name = "John",
                },

                .@"$db" = "test",
            },
        );

    defer std.testing.allocator.free(
        bytes,
    );

    try expectValueString(
        (try Reader.get(
            bytes,
            "find",
        )).?,
        "users",
    );

    try expectValueString(
        (try Reader.get(
            bytes,
            "$db",
        )).?,
        "test",
    );

    const filter =
        (try Reader.get(
            bytes,
            "filter",
        )).?.document;

    try expectValueString(
        (try Reader.get(
            filter,
            "name",
        )).?,
        "John",
    );
}

test "generic encoder handles primitive Zig values" {
    const maybe_name: ?[]const u8 = null;

    const bytes =
        try encode(
            std.testing.allocator,
            .{
                .active = true,
                .small = @as(i16, -7),

                .large = @as(
                    i64,
                    5_000_000_000,
                ),

                .unsigned_small = @as(u16, 12),

                .ratio = @as(f32, 1.25),

                .missing = maybe_name,

                .tags = [_][]const u8{
                    "one",
                    "two",
                },
            },
        );

    defer std.testing.allocator.free(
        bytes,
    );

    try std.testing.expect(
        (try Reader.get(
            bytes,
            "active",
        )).?.boolean,
    );

    try std.testing.expectEqual(
        @as(i32, -7),
        (try Reader.get(
            bytes,
            "small",
        )).?.int32,
    );

    try std.testing.expectEqual(
        @as(i64, 5_000_000_000),
        (try Reader.get(
            bytes,
            "large",
        )).?.int64,
    );

    try std.testing.expectEqual(
        @as(i32, 12),
        (try Reader.get(
            bytes,
            "unsigned_small",
        )).?.int32,
    );

    try std.testing.expectApproxEqAbs(
        @as(f64, 1.25),
        (try Reader.get(
            bytes,
            "ratio",
        )).?.double,
        0.000001,
    );

    try std.testing.expectEqual(
        Type.null_value,
        std.meta.activeTag(
            (try Reader.get(
                bytes,
                "missing",
            )).?,
        ),
    );

    const tags =
        (try Reader.get(
            bytes,
            "tags",
        )).?.array;

    try expectValueString(
        (try Reader.get(
            tags,
            "0",
        )).?,
        "one",
    );

    try expectValueString(
        (try Reader.get(
            tags,
            "1",
        )).?,
        "two",
    );
}

test "decode returns streaming Reader" {
    const bytes =
        try encode(
            std.testing.allocator,
            .{
                .name = "John",
                .age = @as(i32, 42),
            },
        );

    defer std.testing.allocator.free(
        bytes,
    );

    var reader =
        try decode(bytes);

    try expectElementString(
        (try reader.next()).?,
        "name",
        "John",
    );

    const age =
        (try reader.next()).?;

    try std.testing.expectEqualStrings(
        "age",
        age.name,
    );

    try std.testing.expectEqual(
        @as(i32, 42),
        age.value.int32,
    );

    try std.testing.expect(
        (try reader.next()) == null,
    );
}

test "optional present value encodes inner type" {
    const maybe_name: ?[]const u8 = "John";

    const bytes =
        try encode(
            std.testing.allocator,
            .{
                .name = maybe_name,
            },
        );

    defer std.testing.allocator.free(
        bytes,
    );

    try expectValueString(
        (try Reader.get(
            bytes,
            "name",
        )).?,
        "John",
    );
}

test "generic encoder rejects unsigned integer larger than BSON int64" {
    const too_large: u64 =
        std.math.maxInt(u64);

    try std.testing.expectError(
        error.UnsupportedInteger,
        encode(
            std.testing.allocator,
            .{
                .number = too_large,
            },
        ),
    );
}

test "all BSON value types round trip" {
    const allocator =
        std.testing.allocator;

    var scope_writer =
        try Writer.init(allocator);

    defer scope_writer.deinit();

    try scope_writer.writeInt32(
        "x",
        1,
    );

    const scope =
        try scope_writer.finish();

    defer allocator.free(scope);

    var array_writer =
        try Writer.init(allocator);

    defer array_writer.deinit();

    try array_writer.writeString(
        "0",
        "red",
    );

    try array_writer.writeString(
        "1",
        "blue",
    );

    const array_document =
        try array_writer.finish();

    defer allocator.free(
        array_document,
    );

    const nested =
        try encode(
            allocator,
            .{
                .inside = true,
            },
        );

    defer allocator.free(nested);

    const oid = try ObjectId.fromHex(
        "507f1f77bcf86cd799439011",
    );

    const decimal =
        Decimal128{
            .bytes = [_]u8{0xAA} ** 16,
        };

    var writer = try Writer.init(allocator);

    defer writer.deinit();

    try writer.writeDouble(
        "double",
        3.5,
    );

    try writer.writeString(
        "string",
        "hello",
    );

    try writer.writeDocument(
        "document",
        nested,
    );

    try writer.writeArray(
        "array",
        array_document,
    );

    try writer.writeBinary(
        "binary",
        .{
            .data = &.{ 1, 2, 3 },
        },
    );

    try writer.writeUndefined(
        "undefined",
    );

    try writer.writeObjectId(
        "oid",
        oid,
    );

    try writer.writeBool(
        "bool",
        true,
    );

    try writer.writeDateTime(
        "date",
        .{
            .milliseconds = 123456789,
        },
    );

    try writer.writeNull(
        "null",
    );

    try writer.writeRegex(
        "regex",
        .{
            .pattern = "^a",
            .options = "im",
        },
    );

    try writer.writeDbPointer(
        "dbptr",
        .{
            .namespace = "db.users",
            .id = oid,
        },
    );

    try writer.writeJavaScript(
        "js",
        .{
            .code = "return 1;",
        },
    );

    try writer.writeSymbol(
        "symbol",
        .{
            .value = "sym",
        },
    );

    try writer.writeJavaScriptWithScope(
        "code_scope",
        .{
            .code = "return x;",
            .scope = scope,
        },
    );

    try writer.writeInt32(
        "i32",
        -42,
    );

    try writer.writeTimestamp(
        "timestamp",
        .{
            .increment = 7,
            .seconds = 123,
        },
    );

    try writer.writeInt64(
        "i64",
        9_000_000_000,
    );

    try writer.writeDecimal128(
        "decimal",
        decimal,
    );

    try writer.writeMinKey(
        "min",
    );

    try writer.writeMaxKey(
        "max",
    );

    const bytes =
        try writer.finish();

    defer allocator.free(bytes);

    try validateDocument(bytes);

    var reader =
        try Reader.init(bytes);

    try expectElementDouble(
        (try reader.next()).?,
        "double",
        3.5,
    );

    try expectElementString(
        (try reader.next()).?,
        "string",
        "hello",
    );

    const document =
        (try reader.next()).?;

    try std.testing.expectEqualStrings(
        "document",
        document.name,
    );

    try std.testing.expectEqual(
        Type.document,
        std.meta.activeTag(
            document.value,
        ),
    );

    try validateDocument(
        document.value.document,
    );

    const array =
        (try reader.next()).?;

    try std.testing.expectEqualStrings(
        "array",
        array.name,
    );

    try validateArray(
        array.value.array,
    );

    const binary =
        (try reader.next()).?;

    try std.testing.expectEqual(
        BinarySubtype.generic,
        binary.value.binary.subtype,
    );

    try std.testing.expectEqualSlices(
        u8,
        &.{ 1, 2, 3 },
        binary.value.binary.data,
    );

    try expectTag(
        (try reader.next()).?,
        "undefined",
        .undefined_value,
    );

    const object_id =
        (try reader.next()).?;

    try std.testing.expectEqualSlices(
        u8,
        &oid.bytes,
        &object_id.value.object_id.bytes,
    );

    const boolean =
        (try reader.next()).?;

    try std.testing.expect(
        boolean.value.boolean,
    );

    const date =
        (try reader.next()).?;

    try std.testing.expectEqual(
        @as(i64, 123456789),
        date.value.datetime.milliseconds,
    );

    try expectTag(
        (try reader.next()).?,
        "null",
        .null_value,
    );

    const regex =
        (try reader.next()).?;

    try std.testing.expectEqualStrings(
        "^a",
        regex.value.regex.pattern,
    );

    try std.testing.expectEqualStrings(
        "im",
        regex.value.regex.options,
    );

    const db_pointer =
        (try reader.next()).?;

    try std.testing.expectEqualStrings(
        "db.users",
        db_pointer.value
            .db_pointer.namespace,
    );

    const javascript =
        (try reader.next()).?;

    try std.testing.expectEqualStrings(
        "return 1;",
        javascript.value.javascript.code,
    );

    const symbol =
        (try reader.next()).?;

    try std.testing.expectEqualStrings(
        "sym",
        symbol.value.symbol.value,
    );

    const code_scope =
        (try reader.next()).?;

    try std.testing.expectEqualStrings(
        "return x;",
        code_scope.value
            .javascript_with_scope.code,
    );

    try validateDocument(
        code_scope.value
            .javascript_with_scope.scope,
    );

    const int32 =
        (try reader.next()).?;

    try std.testing.expectEqual(
        @as(i32, -42),
        int32.value.int32,
    );

    const timestamp =
        (try reader.next()).?;

    try std.testing.expectEqual(
        @as(u32, 7),
        timestamp.value
            .timestamp.increment,
    );

    try std.testing.expectEqual(
        @as(u32, 123),
        timestamp.value
            .timestamp.seconds,
    );

    const int64 =
        (try reader.next()).?;

    try std.testing.expectEqual(
        @as(i64, 9_000_000_000),
        int64.value.int64,
    );

    const decimal_value =
        (try reader.next()).?;

    try std.testing.expectEqualSlices(
        u8,
        &decimal.bytes,
        &decimal_value.value
            .decimal128.bytes,
    );

    try expectTag(
        (try reader.next()).?,
        "min",
        .min_key,
    );

    try expectTag(
        (try reader.next()).?,
        "max",
        .max_key,
    );

    try std.testing.expect(
        (try reader.next()) == null,
    );
}

fn expectElementDouble(
    element: Element,
    name: []const u8,
    expected: f64,
) !void {
    try std.testing.expectEqualStrings(
        name,
        element.name,
    );

    try std.testing.expectEqual(
        Type.double,
        std.meta.activeTag(
            element.value,
        ),
    );

    try std.testing.expectApproxEqAbs(
        expected,
        element.value.double,
        0.0000001,
    );
}

fn expectElementString(
    element: Element,
    name: []const u8,
    expected: []const u8,
) !void {
    try std.testing.expectEqualStrings(
        name,
        element.name,
    );

    try std.testing.expectEqual(
        Type.string,
        std.meta.activeTag(
            element.value,
        ),
    );

    try std.testing.expectEqualStrings(
        expected,
        element.value.string,
    );
}

fn expectTag(
    element: Element,
    name: []const u8,
    expected: Type,
) !void {
    try std.testing.expectEqualStrings(
        name,
        element.name,
    );

    try std.testing.expectEqual(
        expected,
        std.meta.activeTag(
            element.value,
        ),
    );
}

fn expectValueString(
    value: Value,
    expected: []const u8,
) !void {
    try std.testing.expectEqual(
        Type.string,
        std.meta.activeTag(value),
    );

    try std.testing.expectEqualStrings(
        expected,
        value.string,
    );
}
