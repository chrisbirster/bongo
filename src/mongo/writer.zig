const std = @import("std");
const types = @import("types.zig");
const reader = @import("reader.zig");

const Error = types.Error;
const Type = types.Type;
const Value = types.Value;

pub const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Writer {
        var self = Writer{ .allocator = allocator };
        errdefer self.deinit();
        try self.bytes.appendSlice(allocator, &.{ 0, 0, 0, 0 });
        return self;
    }

    pub fn deinit(self: *Writer) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn finish(self: *Writer) ![]u8 {
        if (self.finished) return error.AlreadyFinished;
        try self.bytes.append(self.allocator, 0x00);
        const len_i32 = try checkedI32Len(self.bytes.items.len);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &len_bytes, len_i32, .little);
        @memcpy(self.bytes.items[0..4], &len_bytes);
        self.finished = true;
        return self.bytes.toOwnedSlice(self.allocator);
    }

    pub fn writeValue(self: *Writer, name: []const u8, value: Value) !void {
        switch (value) {
            .double => |v| try self.writeDouble(name, v),
            .string => |v| try self.writeString(name, v),
            .document => |v| try self.writeDocument(name, v),
            .array => |v| try self.writeArray(name, v),
            .binary => |v| try self.writeBinary(name, v),
            .undefined_value => try self.writeUndefined(name),
            .object_id => |v| try self.writeObjectId(name, v),
            .boolean => |v| try self.writeBool(name, v),
            .datetime => |v| try self.writeDateTime(name, v),
            .null_value => try self.writeNull(name),
            .regex => |v| try self.writeRegex(name, v),
            .db_pointer => |v| try self.writeDbPointer(name, v),
            .javascript => |v| try self.writeJavaScript(name, v),
            .symbol => |v| try self.writeSymbol(name, v),
            .javascript_with_scope => |v| try self.writeJavaScriptWithScope(name, v),
            .int32 => |v| try self.writeInt32(name, v),
            .timestamp => |v| try self.writeTimestamp(name, v),
            .int64 => |v| try self.writeInt64(name, v),
            .decimal128 => |v| try self.writeDecimal128(name, v),
            .min_key => try self.writeMinKey(name),
            .max_key => try self.writeMaxKey(name),
        }
    }

    pub fn writeDouble(self: *Writer, name: []const u8, value: f64) !void {
        try self.writeElementHeader(.double, name);
        try self.writeIntRaw(u64, @bitCast(value));
    }

    pub fn writeString(self: *Writer, name: []const u8, value: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        try self.writeElementHeader(.string, name);
        try self.writeStringRaw(value);
    }

    pub fn writeDocument(self: *Writer, name: []const u8, document_bytes: []const u8) !void {
        try reader.validateDocument(document_bytes);
        try self.writeElementHeader(.document, name);
        try self.bytes.appendSlice(self.allocator, document_bytes);
    }

    pub fn writeArray(self: *Writer, name: []const u8, array_document_bytes: []const u8) !void {
        try reader.validateArray(array_document_bytes);
        try self.writeElementHeader(.array, name);
        try self.bytes.appendSlice(self.allocator, array_document_bytes);
    }

    pub fn writeBinary(self: *Writer, name: []const u8, value: types.Binary) !void {
        try self.writeElementHeader(.binary, name);
        if (value.subtype.value == types.BinarySubtype.old_binary.value) {
            const outer_len = try checkedI32Len(value.data.len + 4);
            try self.writeIntRaw(i32, outer_len);
            try self.bytes.append(self.allocator, value.subtype.value);
            try self.writeIntRaw(i32, try checkedI32Len(value.data.len));
            try self.bytes.appendSlice(self.allocator, value.data);
        } else {
            try self.writeIntRaw(i32, try checkedI32Len(value.data.len));
            try self.bytes.append(self.allocator, value.subtype.value);
            try self.bytes.appendSlice(self.allocator, value.data);
        }
    }

    pub fn writeUndefined(self: *Writer, name: []const u8) !void {
        try self.writeElementHeader(.undefined_value, name);
    }

    pub fn writeObjectId(self: *Writer, name: []const u8, value: types.ObjectId) !void {
        try self.writeElementHeader(.object_id, name);
        try self.bytes.appendSlice(self.allocator, &value.bytes);
    }

    pub fn writeBool(self: *Writer, name: []const u8, value: bool) !void {
        try self.writeElementHeader(.boolean, name);
        try self.bytes.append(self.allocator, if (value) 0x01 else 0x00);
    }

    pub fn writeDateTime(self: *Writer, name: []const u8, value: types.DateTime) !void {
        try self.writeElementHeader(.datetime, name);
        try self.writeIntRaw(i64, value.milliseconds);
    }

    pub fn writeNull(self: *Writer, name: []const u8) !void {
        try self.writeElementHeader(.null_value, name);
    }

    pub fn writeRegex(self: *Writer, name: []const u8, value: types.Regex) !void {
        try reader.validateRegexOptions(value.options);
        try self.writeElementHeader(.regex, name);
        try self.writeCStringRaw(value.pattern);
        try self.writeCStringRaw(value.options);
    }

    pub fn writeDbPointer(self: *Writer, name: []const u8, value: types.DbPointer) !void {
        try self.writeElementHeader(.db_pointer, name);
        try self.writeStringRaw(value.namespace);
        try self.bytes.appendSlice(self.allocator, &value.id.bytes);
    }

    pub fn writeJavaScript(self: *Writer, name: []const u8, value: types.JavaScript) !void {
        try self.writeElementHeader(.javascript, name);
        try self.writeStringRaw(value.code);
    }

    pub fn writeSymbol(self: *Writer, name: []const u8, value: types.Symbol) !void {
        try self.writeElementHeader(.symbol, name);
        try self.writeStringRaw(value.value);
    }

    pub fn writeJavaScriptWithScope(self: *Writer, name: []const u8, value: types.JavaScriptWithScope) !void {
        try reader.validateDocument(value.scope);
        if (!std.unicode.utf8ValidateSlice(value.code)) return error.InvalidUtf8;
        try self.writeElementHeader(.javascript_with_scope, name);
        const total_len = 4 + 4 + value.code.len + 1 + value.scope.len;
        try self.writeIntRaw(i32, try checkedI32Len(total_len));
        try self.writeStringRaw(value.code);
        try self.bytes.appendSlice(self.allocator, value.scope);
    }

    pub fn writeInt32(self: *Writer, name: []const u8, value: i32) !void {
        try self.writeElementHeader(.int32, name);
        try self.writeIntRaw(i32, value);
    }

    pub fn writeTimestamp(self: *Writer, name: []const u8, value: types.Timestamp) !void {
        try self.writeElementHeader(.timestamp, name);
        try self.writeIntRaw(u32, value.increment);
        try self.writeIntRaw(u32, value.seconds);
    }

    pub fn writeInt64(self: *Writer, name: []const u8, value: i64) !void {
        try self.writeElementHeader(.int64, name);
        try self.writeIntRaw(i64, value);
    }

    pub fn writeDecimal128(self: *Writer, name: []const u8, value: types.Decimal128) !void {
        try self.writeElementHeader(.decimal128, name);
        try self.bytes.appendSlice(self.allocator, &value.bytes);
    }

    pub fn writeMinKey(self: *Writer, name: []const u8) !void {
        try self.writeElementHeader(.min_key, name);
    }

    pub fn writeMaxKey(self: *Writer, name: []const u8) !void {
        try self.writeElementHeader(.max_key, name);
    }

    fn writeElementHeader(self: *Writer, element_type: Type, name: []const u8) !void {
        if (self.finished) return error.AlreadyFinished;
        try self.bytes.append(self.allocator, element_type.byte());
        try self.writeCStringRaw(name);
    }

    fn writeCStringRaw(self: *Writer, value: []const u8) !void {
        if (std.mem.findScalar(u8, value, 0) != null) return error.InvalidCString;
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        try self.bytes.appendSlice(self.allocator, value);
        try self.bytes.append(self.allocator, 0x00);
    }

    fn writeStringRaw(self: *Writer, value: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        const len = try checkedI32Len(value.len + 1);
        try self.writeIntRaw(i32, len);
        try self.bytes.appendSlice(self.allocator, value);
        try self.bytes.append(self.allocator, 0x00);
    }

    fn writeIntRaw(self: *Writer, comptime T: type, value: T) !void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, value, .little);
        try self.bytes.appendSlice(self.allocator, &buf);
    }
};

pub fn checkedI32Len(len: usize) Error!i32 {
    if (len > std.math.maxInt(i32)) return error.DocumentTooLarge;
    return @intCast(len);
}

test "empty BSON document is exactly five bytes" {
    var writer = try Writer.init(std.testing.allocator);
    defer writer.deinit();

    const bytes = try writer.finish();
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 0, 0, 0 }, bytes);
    try reader.validateDocument(bytes);
}

test "known BSON example name John encodes to 20 bytes" {
    var writer = try Writer.init(std.testing.allocator);
    defer writer.deinit();

    try writer.writeString("name", "John");
    const bytes = try writer.finish();
    defer std.testing.allocator.free(bytes);

    const expected = [_]u8{
        0x14, 0x00, 0x00, 0x00,
        0x02, 'n',  'a',  'm',
        'e',  0x00, 0x05, 0x00,
        0x00, 0x00, 'J',  'o',
        'h',  'n',  0x00, 0x00,
    };

    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "Writer rejects invalid cstring and invalid UTF-8" {
    var writer = try Writer.init(std.testing.allocator);
    defer writer.deinit();

    try std.testing.expectError(error.InvalidCString, writer.writeString("bad\x00key", "x"));
    try std.testing.expectError(error.InvalidUtf8, writer.writeString("name", "\xff"));
}

test "Writer rejects unsorted duplicate and unknown regex options" {
    var writer = try Writer.init(std.testing.allocator);
    defer writer.deinit();

    try std.testing.expectError(error.InvalidRegexOptions, writer.writeRegex("r", .{ .pattern = "x", .options = "mi" }));
    try std.testing.expectError(error.InvalidRegexOptions, writer.writeRegex("r", .{ .pattern = "x", .options = "ii" }));
    try std.testing.expectError(error.InvalidRegexOptions, writer.writeRegex("r", .{ .pattern = "x", .options = "z" }));
}

test "Writer finish can only be called once" {
    var writer = try Writer.init(std.testing.allocator);
    defer writer.deinit();

    const bytes = try writer.finish();
    defer std.testing.allocator.free(bytes);

    try std.testing.expectError(error.AlreadyFinished, writer.finish());
}

test "writer rejects malformed nested document and malformed array" {
    var writer = try Writer.init(std.testing.allocator);
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidDocumentLength,
        writer.writeDocument("d", &.{ 4, 0, 0, 0 }),
    );

    const bad_array = [_]u8{
        14,   0,   0, 0,
        0x02, '1', 0, 2,
        0,    0,   0, 'x',
        0,    0,
    };

    try std.testing.expectError(
        error.InvalidArrayIndex,
        writer.writeArray("a", &bad_array),
    );
}

test "writer validates JavaScript with scope inputs" {
    var writer = try Writer.init(std.testing.allocator);
    defer writer.deinit();

    try std.testing.expectError(error.InvalidDocumentLength, writer.writeJavaScriptWithScope("x", .{
        .code = "return x",
        .scope = &.{ 4, 0, 0, 0 },
    }));

    const scope = [_]u8{ 5, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidUtf8, writer.writeJavaScriptWithScope("x", .{
        .code = "\xff",
        .scope = &scope,
    }));
}

test "checkedI32Len rejects lengths that do not fit BSON int32 length fields" {
    try std.testing.expectEqual(@as(i32, 5), try checkedI32Len(5));
    try std.testing.expectError(
        error.DocumentTooLarge,
        checkedI32Len(@as(usize, std.math.maxInt(i32)) + 1),
    );
}

test "user defined binary subtype is preserved" {
    const allocator = std.testing.allocator;

    var writer = try Writer.init(allocator);
    defer writer.deinit();

    try writer.writeBinary("data", .{
        .subtype = types.BinarySubtype.userDefined(0x80),
        .data = &.{ 9, 8 },
    });

    const bytes = try writer.finish();
    defer allocator.free(bytes);

    const value = (try reader.Reader.get(bytes, "data")).?;
    try std.testing.expectEqual(@as(u8, 0x80), value.binary.subtype.value);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8 }, value.binary.data);
}

test "deprecated old binary subtype round trips and validates inner length" {
    const allocator = std.testing.allocator;

    var writer = try Writer.init(allocator);
    defer writer.deinit();

    try writer.writeBinary("old", .{
        .subtype = .old_binary,
        .data = &.{ 10, 20, 30 },
    });

    const bytes = try writer.finish();
    defer allocator.free(bytes);

    const value = (try reader.Reader.get(bytes, "old")).?;
    try std.testing.expectEqual(types.BinarySubtype.old_binary.value, value.binary.subtype.value);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, value.binary.data);

    var corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);

    // Document header(4) + type(1) + "old\0"(4) + outer length(4) + subtype(1).
    const inner_len_offset = 4 + 1 + 4 + 4 + 1;
    corrupted[inner_len_offset] = 2;

    try std.testing.expectError(error.InvalidOldBinaryLength, reader.validateDocument(corrupted));
}

test "writeValue dispatches every BSON Value union branch" {
    const allocator = std.testing.allocator;
    const oid = try types.ObjectId.fromHex("507f1f77bcf86cd799439011");
    const empty_doc = [_]u8{ 5, 0, 0, 0, 0 };

    var array_writer = try Writer.init(allocator);
    defer array_writer.deinit();
    try array_writer.writeString("0", "x");
    const array_doc = try array_writer.finish();
    defer allocator.free(array_doc);

    var writer = try Writer.init(allocator);
    defer writer.deinit();

    try writer.writeValue("v01", .{ .double = 1.5 });
    try writer.writeValue("v02", .{ .string = "s" });
    try writer.writeValue("v03", .{ .document = &empty_doc });
    try writer.writeValue("v04", .{ .array = array_doc });
    try writer.writeValue("v05", .{ .binary = .{ .data = &.{1} } });
    try writer.writeValue("v06", .{ .undefined_value = {} });
    try writer.writeValue("v07", .{ .object_id = oid });
    try writer.writeValue("v08", .{ .boolean = true });
    try writer.writeValue("v09", .{ .datetime = .{ .milliseconds = 1 } });
    try writer.writeValue("v10", .{ .null_value = {} });
    try writer.writeValue("v11", .{ .regex = .{ .pattern = "x", .options = "i" } });
    try writer.writeValue("v12", .{ .db_pointer = .{ .namespace = "db.c", .id = oid } });
    try writer.writeValue("v13", .{ .javascript = .{ .code = "x" } });
    try writer.writeValue("v14", .{ .symbol = .{ .value = "x" } });
    try writer.writeValue("v15", .{ .javascript_with_scope = .{ .code = "x", .scope = &empty_doc } });
    try writer.writeValue("v16", .{ .int32 = 1 });
    try writer.writeValue("v17", .{ .timestamp = .{ .increment = 1, .seconds = 2 } });
    try writer.writeValue("v18", .{ .int64 = 2 });
    try writer.writeValue("v19", .{ .decimal128 = .{ .bytes = [_]u8{0} ** 16 } });
    try writer.writeValue("v20", .{ .min_key = {} });
    try writer.writeValue("v21", .{ .max_key = {} });

    const bytes = try writer.finish();
    defer allocator.free(bytes);

    try reader.validateDocument(bytes);

    var bson_reader = try reader.Reader.init(bytes);
    var count: usize = 0;
    while (try bson_reader.next()) |_| count += 1;

    try std.testing.expectEqual(@as(usize, 21), count);
}

test "all BSON value types round trip through Writer and Reader" {
    const allocator = std.testing.allocator;

    var scope_writer = try Writer.init(allocator);
    defer scope_writer.deinit();
    try scope_writer.writeInt32("x", 1);
    const scope = try scope_writer.finish();
    defer allocator.free(scope);

    var array_writer = try Writer.init(allocator);
    defer array_writer.deinit();
    try array_writer.writeString("0", "red");
    try array_writer.writeString("1", "blue");
    const array_doc = try array_writer.finish();
    defer allocator.free(array_doc);

    var nested_writer = try Writer.init(allocator);
    defer nested_writer.deinit();
    try nested_writer.writeBool("inside", true);
    const nested = try nested_writer.finish();
    defer allocator.free(nested);

    const oid = try types.ObjectId.fromHex("507f1f77bcf86cd799439011");
    const decimal = types.Decimal128{ .bytes = [_]u8{0xAA} ** 16 };

    var writer = try Writer.init(allocator);
    defer writer.deinit();

    try writer.writeDouble("double", 3.5);
    try writer.writeString("string", "hello");
    try writer.writeDocument("document", nested);
    try writer.writeArray("array", array_doc);
    try writer.writeBinary("binary", .{ .data = &.{ 1, 2, 3 } });
    try writer.writeUndefined("undefined");
    try writer.writeObjectId("oid", oid);
    try writer.writeBool("bool", true);
    try writer.writeDateTime("date", .{ .milliseconds = 123456789 });
    try writer.writeNull("null");
    try writer.writeRegex("regex", .{ .pattern = "^a", .options = "im" });
    try writer.writeDbPointer("dbptr", .{ .namespace = "db.users", .id = oid });
    try writer.writeJavaScript("js", .{ .code = "return 1;" });
    try writer.writeSymbol("symbol", .{ .value = "sym" });
    try writer.writeJavaScriptWithScope("code_scope", .{ .code = "return x;", .scope = scope });
    try writer.writeInt32("i32", -42);
    try writer.writeTimestamp("ts", .{ .increment = 7, .seconds = 123 });
    try writer.writeInt64("i64", 9_000_000_000);
    try writer.writeDecimal128("decimal", decimal);
    try writer.writeMinKey("min");
    try writer.writeMaxKey("max");

    const bytes = try writer.finish();
    defer allocator.free(bytes);

    try reader.validateDocument(bytes);

    var bson_reader = try reader.Reader.init(bytes);
    var count: usize = 0;
    while (try bson_reader.next()) |_| count += 1;

    try std.testing.expectEqual(@as(usize, 21), count);
}
