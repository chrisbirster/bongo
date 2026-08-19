const std = @import("std");
const types = @import("types.zig");

const Error = types.Error;
const Type = types.Type;
const Value = types.Value;
const Element = types.Element;
const Binary = types.Binary;
const BinarySubtype = types.BinarySubtype;
const JavaScriptWithScope = types.JavaScriptWithScope;

pub const Reader = struct {
    bytes: []const u8,
    position: usize,
    end: usize,

    pub fn init(document_bytes: []const u8) Error!Reader {
        try validateEnvelope(document_bytes);
        return .{
            .bytes = document_bytes,
            .position = 4,
            .end = document_bytes.len - 1,
        };
    }

    pub fn next(self: *Reader) Error!?Element {
        if (self.position == self.end) return null;
        if (self.position > self.end) return error.UnexpectedEnd;

        const type_byte = try self.readByte();
        const element_type = try Type.fromByte(type_byte);
        const name = try self.readCString();
        const value = try self.readValue(element_type);
        return .{ .name = name, .value = value };
    }

    pub fn get(document_bytes: []const u8, name: []const u8) Error!?Value {
        var reader = try Reader.init(document_bytes);
        while (try reader.next()) |element| {
            if (std.mem.eql(u8, element.name, name)) return element.value;
        }
        return null;
    }

    fn readValue(self: *Reader, element_type: Type) Error!Value {
        return switch (element_type) {
            .double => .{ .double = @bitCast(try self.readIntRaw(u64)) },
            .string => .{ .string = try self.readString() },
            .document => .{ .document = try self.readEmbeddedDocument() },
            .array => .{ .array = try self.readEmbeddedArray() },
            .binary => .{ .binary = try self.readBinary() },
            .undefined_value => .{ .undefined_value = {} },
            .object_id => .{ .object_id = .{ .bytes = try self.readArray(12) } },
            .boolean => .{ .boolean = try self.readBool() },
            .datetime => .{ .datetime = .{ .milliseconds = try self.readIntRaw(i64) } },
            .null_value => .{ .null_value = {} },
            .regex => .{ .regex = .{
                .pattern = try self.readCString(),
                .options = options: {
                    const opts = try self.readCString();
                    try validateRegexOptions(opts);
                    break :options opts;
                },
            } },
            .db_pointer => .{ .db_pointer = .{
                .namespace = try self.readString(),
                .id = .{ .bytes = try self.readArray(12) },
            } },
            .javascript => .{ .javascript = .{ .code = try self.readString() } },
            .symbol => .{ .symbol = .{ .value = try self.readString() } },
            .javascript_with_scope => .{ .javascript_with_scope = try self.readCodeWithScope() },
            .int32 => .{ .int32 = try self.readIntRaw(i32) },
            .timestamp => .{ .timestamp = .{
                .increment = try self.readIntRaw(u32),
                .seconds = try self.readIntRaw(u32),
            } },
            .int64 => .{ .int64 = try self.readIntRaw(i64) },
            .decimal128 => .{ .decimal128 = .{ .bytes = try self.readArray(16) } },
            .min_key => .{ .min_key = {} },
            .max_key => .{ .max_key = {} },
        };
    }

    fn readBinary(self: *Reader) Error!Binary {
        const len_i32 = try self.readIntRaw(i32);
        if (len_i32 < 0) return error.InvalidBinaryLength;
        const len: usize = @intCast(len_i32);
        const subtype = BinarySubtype{ .value = try self.readByte() };

        if (subtype.value == BinarySubtype.old_binary.value) {
            if (len < 4) return error.InvalidOldBinaryLength;
            const inner_i32 = try self.readIntRaw(i32);
            if (inner_i32 < 0) return error.InvalidOldBinaryLength;
            const inner: usize = @intCast(inner_i32);
            if (inner + 4 != len) return error.InvalidOldBinaryLength;
            return .{ .subtype = subtype, .data = try self.readBytes(inner) };
        }

        return .{ .subtype = subtype, .data = try self.readBytes(len) };
    }

    fn readCodeWithScope(self: *Reader) Error!JavaScriptWithScope {
        const start = self.position;
        const total_i32 = try self.readIntRaw(i32);

        // Minimum possible code-with-scope:
        // 4 bytes total size + 5 byte empty string + 5 byte empty document.
        if (total_i32 < 14) return error.InvalidCodeWithScopeLength;

        const total: usize = @intCast(total_i32);
        if (total > self.end - start) return error.InvalidCodeWithScopeLength;

        const expected_end = start + total;
        const code = try self.readString();
        const scope = try self.readEmbeddedDocument();

        if (self.position != expected_end) return error.InvalidCodeWithScopeLength;
        return .{ .code = code, .scope = scope };
    }

    fn readEmbeddedDocument(self: *Reader) Error![]const u8 {
        const doc = try self.readEmbeddedRaw();
        try validateDocument(doc);
        return doc;
    }

    fn readEmbeddedArray(self: *Reader) Error![]const u8 {
        const doc = try self.readEmbeddedRaw();
        try validateArray(doc);
        return doc;
    }

    fn readEmbeddedRaw(self: *Reader) Error![]const u8 {
        if (self.position + 4 > self.end) return error.UnexpectedEnd;
        const len_i32 = readI32At(self.bytes, self.position) catch return error.UnexpectedEnd;
        if (len_i32 < 5) return error.InvalidDocumentLength;
        const len: usize = @intCast(len_i32);
        if (self.position + len > self.end) return error.UnexpectedEnd;
        const result = self.bytes[self.position .. self.position + len];
        self.position += len;
        return result;
    }

    fn readString(self: *Reader) Error![]const u8 {
        const len_i32 = try self.readIntRaw(i32);
        if (len_i32 <= 0) return error.InvalidStringLength;
        const len: usize = @intCast(len_i32);
        const raw = try self.readBytes(len);
        if (raw[raw.len - 1] != 0) return error.InvalidStringTerminator;
        const value = raw[0 .. raw.len - 1];
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        return value;
    }

    fn readCString(self: *Reader) Error![]const u8 {
        const remaining = self.bytes[self.position..self.end];
        const relative_end = std.mem.findScalar(u8, remaining, 0) orelse return error.InvalidCString;
        const value = remaining[0..relative_end];
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        self.position += relative_end + 1;
        return value;
    }

    fn readBool(self: *Reader) Error!bool {
        return switch (try self.readByte()) {
            0x00 => false,
            0x01 => true,
            else => error.InvalidBoolean,
        };
    }

    fn readByte(self: *Reader) Error!u8 {
        if (self.position >= self.end) return error.UnexpectedEnd;
        const value = self.bytes[self.position];
        self.position += 1;
        return value;
    }

    fn readBytes(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.end - self.position) return error.UnexpectedEnd;
        const result = self.bytes[self.position .. self.position + count];
        self.position += count;
        return result;
    }

    fn readArray(self: *Reader, comptime N: usize) Error![N]u8 {
        const raw = try self.readBytes(N);
        var result: [N]u8 = undefined;
        @memcpy(&result, raw);
        return result;
    }

    fn readIntRaw(self: *Reader, comptime T: type) Error!T {
        const raw = try self.readBytes(@sizeOf(T));
        var buf: [@sizeOf(T)]u8 = undefined;
        @memcpy(&buf, raw);
        return std.mem.readInt(T, &buf, .little);
    }
};

pub fn validateDocument(document_bytes: []const u8) Error!void {
    var reader = try Reader.init(document_bytes);
    while (try reader.next()) |_| {}
    if (reader.position != reader.end) return error.InvalidDocumentLength;
}

pub fn validateArray(document_bytes: []const u8) Error!void {
    var reader = try Reader.init(document_bytes);
    var expected_index: usize = 0;
    while (try reader.next()) |element| : (expected_index += 1) {
        var key_buffer: [32]u8 = undefined;
        const expected = std.fmt.bufPrint(&key_buffer, "{d}", .{expected_index}) catch unreachable;
        if (!std.mem.eql(u8, element.name, expected)) return error.InvalidArrayIndex;
    }
}

fn validateEnvelope(document_bytes: []const u8) Error!void {
    if (document_bytes.len < 5) return error.InvalidDocumentLength;
    const declared = try readI32At(document_bytes, 0);
    if (declared < 5) return error.InvalidDocumentLength;
    const declared_usize: usize = @intCast(declared);
    if (declared_usize != document_bytes.len) return error.InvalidDocumentLength;
    if (document_bytes[document_bytes.len - 1] != 0) return error.InvalidDocumentTerminator;
}

pub fn validateRegexOptions(options: []const u8) Error!void {
    if (std.mem.findScalar(u8, options, 0) != null) return error.InvalidCString;
    var previous: ?u8 = null;
    for (options) |option| {
        if (option != 'i' and option != 'm' and option != 's' and option != 'u' and option != 'x') {
            return error.InvalidRegexOptions;
        }
        if (previous) |p| {
            if (option <= p) return error.InvalidRegexOptions;
        }
        previous = option;
    }
}

fn readI32At(bytes: []const u8, offset: usize) Error!i32 {
    if (offset + 4 > bytes.len) return error.UnexpectedEnd;
    var buf: [4]u8 = undefined;
    @memcpy(&buf, bytes[offset .. offset + 4]);
    return std.mem.readInt(i32, &buf, .little);
}

test "document validation rejects short wrong length and missing terminator" {
    try std.testing.expectError(error.InvalidDocumentLength, validateDocument(&.{ 4, 0, 0, 0 }));
    try std.testing.expectError(error.InvalidDocumentLength, validateDocument(&.{ 6, 0, 0, 0, 0 }));
    try std.testing.expectError(error.InvalidDocumentTerminator, validateDocument(&.{ 5, 0, 0, 0, 1 }));
}

test "reader rejects unknown type" {
    const bytes = [_]u8{ 8, 0, 0, 0, 0x20, 'x', 0, 0 };
    try std.testing.expectError(error.UnknownType, validateDocument(&bytes));
}

test "reader rejects invalid boolean" {
    const bytes = [_]u8{ 9, 0, 0, 0, 0x08, 'x', 0, 2, 0 };
    try std.testing.expectError(error.InvalidBoolean, validateDocument(&bytes));
}

test "reader rejects invalid string length and terminator" {
    const zero_len = [_]u8{ 12, 0, 0, 0, 0x02, 'x', 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidStringLength, validateDocument(&zero_len));

    const bad_term = [_]u8{ 14, 0, 0, 0, 0x02, 'x', 0, 2, 0, 0, 0, 'a', 'b', 0 };
    try std.testing.expectError(error.InvalidStringTerminator, validateDocument(&bad_term));
}

test "reader rejects truncated payload" {
    const bytes = [_]u8{ 12, 0, 0, 0, 0x12, 'x', 0, 1, 2, 3, 4, 0 };
    try std.testing.expectError(error.UnexpectedEnd, validateDocument(&bytes));
}

test "reader rejects invalid UTF-8 in a string value" {
    const bytes = [_]u8{ 14, 0, 0, 0, 0x02, 'x', 0, 2, 0, 0, 0, 0xFF, 0, 0 };
    try std.testing.expectError(error.InvalidUtf8, validateDocument(&bytes));
}

test "reader rejects cstring with no terminator before document end" {
    const valid = [_]u8{ 8, 0, 0, 0, 0x0A, 'x', 0, 0 };
    const malformed = [_]u8{ 8, 0, 0, 0, 0x0A, 'x', 'y', 0 };

    try std.testing.expectError(error.InvalidCString, validateDocument(&malformed));
    try validateDocument(&valid);
}

test "reader rejects negative binary length" {
    const bytes = [_]u8{
        13,   0,    0,    0,
        0x05, 'b',  0,    0xFF,
        0xFF, 0xFF, 0xFF, 0x00,
        0x00,
    };

    try std.testing.expectError(error.InvalidBinaryLength, validateDocument(&bytes));
}

test "reader rejects malformed code-with-scope total length" {
    // Valid value would declare 15 bytes. Declaring 16 makes the internal
    // code-with-scope length extend past the containing BSON document.
    const bytes = [_]u8{
        23,   0,   0, 0,
        0x0F, 'c', 0, 16,
        0,    0,   0, 2,
        0,    0,   0, 'x',
        0,    5,   0, 0,
        0,    0,   0,
    };

    try std.testing.expectError(error.InvalidCodeWithScopeLength, validateDocument(&bytes));
}

test "reader rejects regex options that are not canonical" {
    const bytes = [_]u8{
        13,   0,   0,   0,
        0x0B, 'r', 0,   'x',
        0,    'm', 'i', 0,
        0,
    };

    try std.testing.expectError(error.InvalidRegexOptions, validateDocument(&bytes));
}

test "validateArray requires canonical sequential numeric keys" {
    const bytes = [_]u8{
        23,   0,    0,   0,
        0x02, '0',  0,   2,
        0,    0,    0,   'a',
        0,    0x02, '2', 0,
        2,    0,    0,   0,
        'b',  0,    0,
    };

    try std.testing.expectError(error.InvalidArrayIndex, validateArray(&bytes));
}

test "Reader.get returns a value and null when field is absent" {
    const bytes = [_]u8{
        20,   0,   0,   0,
        0x02, 'n', 'a', 'm',
        'e',  0,   5,   0,
        0,    0,   'J', 'o',
        'h',  'n', 0,   0,
    };

    const name = (try Reader.get(&bytes, "name")).?;
    try std.testing.expectEqual(Type.string, std.meta.activeTag(name));
    try std.testing.expectEqualStrings("John", name.string);
    try std.testing.expect((try Reader.get(&bytes, "age")) == null);
}
