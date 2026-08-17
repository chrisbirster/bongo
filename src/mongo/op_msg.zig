const std = @import("std");
const bson = @import("../bson.zig");

/// MongoDB OP_MSG wire protocol support.
///
/// This first Bongo implementation intentionally:
/// - encodes normal kind-0 command bodies (hello, find, getMore, etc.)
/// - decodes kind-0 bodies
/// - decodes kind-1 document sequences
/// - understands checksum framing but does not verify CRC-32C yet
/// - does not encode kind-1 document sequences yet
pub const Error =
    bson.Reader.Error ||
    std.mem.Allocator.Error ||
    error{
        MessageTooLarge,
        MessageTooShort,
        InvalidMessageLength,
        InvalidOpcode,
        UnknownRequiredFlag,
        UnknownOutgoingFlag,
        ChecksumEncodingUnsupported,
        InvalidSectionKind,
        InvalidSectionLength,
        InvalidSectionIdentifier,
        MissingBodySection,
        MultipleBodySections,
    };

pub const opcode: i32 = 2013;
pub const header_size: usize = 16;
pub const flags_size: usize = 4;
pub const fixed_prefix_size: usize = header_size + flags_size;

pub const Flag = struct {
    /// Bit 0. If set, the final four bytes are a CRC-32C checksum.
    pub const checksum_present: u32 = 1 << 0;

    /// Bit 1. Another message follows without a new request.
    pub const more_to_come: u32 = 1 << 1;

    /// Bit 16. Client allows exhaust-style multiple replies.
    pub const exhaust_allowed: u32 = 1 << 16;
};

const required_flag_mask: u32 = 0x0000_FFFF;
const known_required_flags: u32 = Flag.checksum_present | Flag.more_to_come;
const known_outgoing_flags: u32 = known_required_flags | Flag.exhaust_allowed;

pub const Header = struct {
    message_length: i32,
    request_id: i32,
    response_to: i32,
    op_code: i32,
};

pub const EncodeOptions = struct {
    request_id: i32 = 1,
    response_to: i32 = 0,
    flags: u32 = 0,
};

pub const DocumentSequence = struct {
    identifier: []const u8,
    documents_bytes: []const u8,

    pub fn iterator(self: DocumentSequence) DocumentIterator {
        return .{
            .bytes = self.documents_bytes,
            .position = 0,
        };
    }
};

pub const Section = union(enum) {
    body: []const u8,
    document_sequence: DocumentSequence,
};

/// A zero-allocation view over one complete OP_MSG packet.
/// All slices borrow from `bytes`.
pub const Message = struct {
    bytes: []const u8,
    header: Header,
    flags: u32,
    sections_end: usize,
    checksum: ?u32,

    pub fn hasFlag(self: Message, flag: u32) bool {
        return (self.flags & flag) != 0;
    }

    pub fn sectionIterator(self: Message) SectionIterator {
        return .{
            .bytes = self.bytes,
            .position = fixed_prefix_size,
            .end = self.sections_end,
        };
    }

    /// Return the standard kind-0 BSON body.
    ///
    /// While locating it, this also validates every section in the message.
    pub fn body(self: Message) Error![]const u8 {
        var iterator = self.sectionIterator();
        var result: ?[]const u8 = null;

        while (try iterator.next()) |section| {
            switch (section) {
                .body => |document| {
                    if (result != null) return error.MultipleBodySections;
                    result = document;
                },
                .document_sequence => {},
            }
        }

        return result orelse error.MissingBodySection;
    }
};

pub const SectionIterator = struct {
    bytes: []const u8,
    position: usize,
    end: usize,

    pub fn next(self: *SectionIterator) Error!?Section {
        if (self.position == self.end) return null;
        if (self.position > self.end) return error.UnexpectedEnd;

        const kind = self.bytes[self.position];
        self.position += 1;

        return switch (kind) {
            0 => .{ .body = try self.readBody() },
            1 => .{ .document_sequence = try self.readDocumentSequence() },
            else => error.InvalidSectionKind,
        };
    }

    fn readBody(self: *SectionIterator) Error![]const u8 {
        const document = try readDocumentAt(self.bytes, self.position, self.end);
        try bson.validateDocument(document);
        self.position += document.len;
        return document;
    }

    fn readDocumentSequence(self: *SectionIterator) Error!DocumentSequence {
        const section_start = self.position;
        const size_i32 = try readI32At(self.bytes, section_start, self.end);
        if (size_i32 < 5) return error.InvalidSectionLength;

        const size: usize = @intCast(size_i32);
        if (size > self.end - section_start) return error.InvalidSectionLength;
        const section_end = section_start + size;

        const identifier_start = section_start + 4;
        const identifier_area = self.bytes[identifier_start..section_end];
        const zero_index = std.mem.findScalar(u8, identifier_area, 0) orelse
            return error.InvalidSectionIdentifier;

        const identifier = identifier_area[0..zero_index];
        if (!std.unicode.utf8ValidateSlice(identifier)) return error.InvalidSectionIdentifier;

        const documents_start = identifier_start + zero_index + 1;
        const documents = self.bytes[documents_start..section_end];

        // Validate all BSON documents in the sequence now, not later.
        var document_iterator = DocumentIterator{
            .bytes = documents,
            .position = 0,
        };
        while (try document_iterator.next()) |_| {}

        self.position = section_end;
        return .{
            .identifier = identifier,
            .documents_bytes = documents,
        };
    }
};

pub const DocumentIterator = struct {
    bytes: []const u8,
    position: usize,

    pub fn next(self: *DocumentIterator) Error!?[]const u8 {
        if (self.position == self.bytes.len) return null;
        if (self.position > self.bytes.len) return error.UnexpectedEnd;

        const document = try readDocumentAt(self.bytes, self.position, self.bytes.len);
        try bson.validateDocument(document);
        self.position += document.len;
        return document;
    }
};

/// Encode an already-encoded BSON document as an OP_MSG kind-0 body.
pub fn encodeBody(
    allocator: std.mem.Allocator,
    body_bson: []const u8,
    options: EncodeOptions,
) Error![]u8 {
    try bson.validateDocument(body_bson);
    try validateOutgoingFlags(options.flags);

    // We understand checksum framing on decode, but until Bongo has CRC-32C
    // support we deliberately refuse to claim a checksum is present on output.
    if ((options.flags & Flag.checksum_present) != 0)
        return error.ChecksumEncodingUnsupported;

    const message_len = fixed_prefix_size + 1 + body_bson.len;
    const message_len_i32 = try checkedI32Len(message_len);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.ensureTotalCapacity(allocator, message_len);

    try appendInt(&bytes, allocator, i32, message_len_i32);
    try appendInt(&bytes, allocator, i32, options.request_id);
    try appendInt(&bytes, allocator, i32, options.response_to);
    try appendInt(&bytes, allocator, i32, opcode);
    try appendInt(&bytes, allocator, u32, options.flags);

    // Section kind 0: body.
    try bytes.append(allocator, 0x00);
    try bytes.appendSlice(allocator, body_bson);

    std.debug.assert(bytes.items.len == message_len);
    return bytes.toOwnedSlice(allocator);
}

/// Convenience API: turn a Zig struct into BSON and then wrap it in OP_MSG.
///
/// Example:
///
///     const packet = try op_msg.encodeCommand(allocator, .{
///         .find = "users",
///         .filter = .{ .name = "John" },
///         .@"$db" = "test",
///     }, .{ .request_id = 1 });
pub fn encodeCommand(
    allocator: std.mem.Allocator,
    command: anytype,
    options: EncodeOptions,
) ![]u8 {
    const body = try bson.encode(allocator, command);
    defer allocator.free(body);
    return encodeBody(allocator, body, options);
}

/// Decode and validate one complete OP_MSG packet.
///
/// This function validates the header, required flags, checksum framing, and
/// all sections. It does not currently verify the CRC-32C checksum value.
pub fn decode(bytes: []const u8) Error!Message {
    if (bytes.len < fixed_prefix_size) return error.MessageTooShort;

    const message_length = try readI32At(bytes, 0, bytes.len);
    if (message_length < @as(i32, @intCast(fixed_prefix_size)))
        return error.InvalidMessageLength;

    const message_length_usize: usize = @intCast(message_length);
    if (message_length_usize != bytes.len) return error.InvalidMessageLength;

    const request_id = try readI32At(bytes, 4, bytes.len);
    const response_to = try readI32At(bytes, 8, bytes.len);
    const op_code = try readI32At(bytes, 12, bytes.len);
    if (op_code != opcode) return error.InvalidOpcode;

    const flags = try readU32At(bytes, header_size, bytes.len);
    try validateIncomingFlags(flags);

    var sections_end = bytes.len;
    var checksum: ?u32 = null;

    if ((flags & Flag.checksum_present) != 0) {
        if (sections_end < fixed_prefix_size + 4) return error.MessageTooShort;
        sections_end -= 4;
        checksum = try readU32At(bytes, sections_end, bytes.len);
    }

    if (sections_end <= fixed_prefix_size) return error.MissingBodySection;

    const message = Message{
        .bytes = bytes,
        .header = .{
            .message_length = message_length,
            .request_id = request_id,
            .response_to = response_to,
            .op_code = op_code,
        },
        .flags = flags,
        .sections_end = sections_end,
        .checksum = checksum,
    };

    // Fully validate sections now and guarantee a kind-0 body exists.
    _ = try message.body();
    return message;
}

fn validateIncomingFlags(flags: u32) Error!void {
    const unknown_required = (flags & required_flag_mask) & ~known_required_flags;
    if (unknown_required != 0) return error.UnknownRequiredFlag;

    // Optional bits 16-31 must be ignored when unknown.
}

fn validateOutgoingFlags(flags: u32) Error!void {
    if ((flags & ~known_outgoing_flags) != 0) return error.UnknownOutgoingFlag;
}

fn appendInt(
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime T: type,
    value: T,
) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try bytes.appendSlice(allocator, &buffer);
}

fn checkedI32Len(len: usize) Error!i32 {
    if (len > std.math.maxInt(i32)) return error.MessageTooLarge;
    return @intCast(len);
}

fn writeIntAt(bytes: []u8, offset: usize, comptime T: type, value: T) void {
    std.debug.assert(offset + @sizeOf(T) <= bytes.len);
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    @memcpy(bytes[offset .. offset + @sizeOf(T)], &buffer);
}

fn readI32At(bytes: []const u8, offset: usize, end: usize) Error!i32 {
    if (offset > end or 4 > end - offset) return error.UnexpectedEnd;
    var buffer: [4]u8 = undefined;
    @memcpy(&buffer, bytes[offset .. offset + 4]);
    return std.mem.readInt(i32, &buffer, .little);
}

fn readU32At(bytes: []const u8, offset: usize, end: usize) Error!u32 {
    if (offset > end or 4 > end - offset) return error.UnexpectedEnd;
    var buffer: [4]u8 = undefined;
    @memcpy(&buffer, bytes[offset .. offset + 4]);
    return std.mem.readInt(u32, &buffer, .little);
}

fn readDocumentAt(bytes: []const u8, offset: usize, end: usize) Error![]const u8 {
    if (offset > end or 4 > end - offset) return error.UnexpectedEnd;

    const length_i32 = try readI32At(bytes, offset, end);
    if (length_i32 < 5) return error.InvalidDocumentLength;

    const length: usize = @intCast(length_i32);
    if (length > end - offset) return error.UnexpectedEnd;

    return bytes[offset .. offset + length];
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "encodeBody builds OP_MSG header, flags, kind 0, and BSON body" {
    const allocator = std.testing.allocator;

    const body = try bson.encode(allocator, .{
        .ping = 1,
        .@"$db" = "admin",
    });
    defer allocator.free(body);

    const packet = try encodeBody(allocator, body, .{
        .request_id = 42,
    });
    defer allocator.free(packet);

    try std.testing.expectEqual(@as(i32, @intCast(packet.len)), try readI32At(packet, 0, packet.len));
    try std.testing.expectEqual(@as(i32, 42), try readI32At(packet, 4, packet.len));
    try std.testing.expectEqual(@as(i32, 0), try readI32At(packet, 8, packet.len));
    try std.testing.expectEqual(opcode, try readI32At(packet, 12, packet.len));
    try std.testing.expectEqual(@as(u32, 0), try readU32At(packet, 16, packet.len));
    try std.testing.expectEqual(@as(u8, 0), packet[20]);
    try std.testing.expectEqualSlices(u8, body, packet[21..]);
}

test "encodeCommand creates a decodable find command" {
    const allocator = std.testing.allocator;

    const packet = try encodeCommand(allocator, .{
        .find = "users",
        .filter = .{ .name = "John" },
        .@"$db" = "test",
    }, .{ .request_id = 7 });
    defer allocator.free(packet);

    const message = try decode(packet);
    try std.testing.expectEqual(@as(i32, 7), message.header.request_id);

    const body = try message.body();

    const find_value = (try bson.Reader.get(body, "find")) orelse return error.TestExpectedEqual;
    switch (find_value) {
        .string => |value| try std.testing.expectEqualStrings("users", value),
        else => return error.TestExpectedEqual,
    }

    const filter_value = (try bson.Reader.get(body, "filter")) orelse return error.TestExpectedEqual;
    switch (filter_value) {
        .document => |filter| {
            const name_value = (try bson.Reader.get(filter, "name")) orelse return error.TestExpectedEqual;
            switch (name_value) {
                .string => |value| try std.testing.expectEqualStrings("John", value),
                else => return error.TestExpectedEqual,
            }
        },
        else => return error.TestExpectedEqual,
    }
}

test "decode exposes responseTo and moreToCome" {
    const allocator = std.testing.allocator;
    const body = try bson.encode(allocator, .{ .ok = 1 });
    defer allocator.free(body);

    const packet = try encodeBody(allocator, body, .{
        .request_id = 99,
        .response_to = 42,
        .flags = Flag.more_to_come,
    });
    defer allocator.free(packet);

    const message = try decode(packet);
    try std.testing.expectEqual(@as(i32, 99), message.header.request_id);
    try std.testing.expectEqual(@as(i32, 42), message.header.response_to);
    try std.testing.expect(message.hasFlag(Flag.more_to_come));
}

test "decode ignores unknown optional flag bits" {
    const allocator = std.testing.allocator;
    const body = try bson.encode(allocator, .{ .ok = 1 });
    defer allocator.free(body);

    const packet = try encodeBody(allocator, body, .{});
    defer allocator.free(packet);

    // Optional bits are 16..31. Parser must ignore unknown optional bits.
    var flags_buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &flags_buffer, @as(u32, 1 << 31), .little);
    @memcpy(packet[16..20], &flags_buffer);

    const message = try decode(packet);
    try std.testing.expectEqual(@as(u32, 1 << 31), message.flags);
}

test "decode rejects unknown required flag bits" {
    const allocator = std.testing.allocator;
    const body = try bson.encode(allocator, .{ .ok = 1 });
    defer allocator.free(body);

    const packet = try encodeBody(allocator, body, .{});
    defer allocator.free(packet);

    var flags_buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &flags_buffer, @as(u32, 1 << 2), .little);
    @memcpy(packet[16..20], &flags_buffer);

    try std.testing.expectError(error.UnknownRequiredFlag, decode(packet));
}

test "decode rejects incorrect message length" {
    const allocator = std.testing.allocator;
    const body = try bson.encode(allocator, .{ .ok = 1 });
    defer allocator.free(body);

    const packet = try encodeBody(allocator, body, .{});
    defer allocator.free(packet);

    var length_buffer: [4]u8 = undefined;
    std.mem.writeInt(i32, &length_buffer, @as(i32, @intCast(packet.len - 1)), .little);
    @memcpy(packet[0..4], &length_buffer);

    try std.testing.expectError(error.InvalidMessageLength, decode(packet));
}

test "decode rejects non OP_MSG opcode" {
    const allocator = std.testing.allocator;
    const body = try bson.encode(allocator, .{ .ok = 1 });
    defer allocator.free(body);

    const packet = try encodeBody(allocator, body, .{});
    defer allocator.free(packet);

    var opcode_buffer: [4]u8 = undefined;
    std.mem.writeInt(i32, &opcode_buffer, 2004, .little);
    @memcpy(packet[12..16], &opcode_buffer);

    try std.testing.expectError(error.InvalidOpcode, decode(packet));
}

test "decode recognizes checksum framing and excludes checksum from sections" {
    const allocator = std.testing.allocator;
    const body = try bson.encode(allocator, .{ .ok = 1 });
    defer allocator.free(body);

    const without_checksum = try encodeBody(allocator, body, .{});
    defer allocator.free(without_checksum);

    var packet: std.ArrayList(u8) = .empty;
    defer packet.deinit(allocator);
    try packet.appendSlice(allocator, without_checksum);

    const checksum: u32 = 0x1234_5678;
    var checksum_buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum_buffer, checksum, .little);
    try packet.appendSlice(allocator, &checksum_buffer);

    var length_buffer: [4]u8 = undefined;
    std.mem.writeInt(i32, &length_buffer, @intCast(packet.items.len), .little);
    @memcpy(packet.items[0..4], &length_buffer);

    var flags_buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &flags_buffer, Flag.checksum_present, .little);
    @memcpy(packet.items[16..20], &flags_buffer);

    const message = try decode(packet.items);
    try std.testing.expectEqual(checksum, message.checksum.?);
    try std.testing.expectEqualSlices(u8, body, try message.body());
}

test "encodeBody refuses checksumPresent until CRC32C encoding exists" {
    const allocator = std.testing.allocator;
    const body = try bson.encode(allocator, .{ .ping = 1 });
    defer allocator.free(body);

    try std.testing.expectError(
        error.ChecksumEncodingUnsupported,
        encodeBody(allocator, body, .{ .flags = Flag.checksum_present }),
    );
}

test "decode rejects missing body section" {
    var packet: [20]u8 = @splat(0);
    writeIntAt(&packet, 0, i32, 20);
    writeIntAt(&packet, 12, i32, opcode);

    try std.testing.expectError(error.MissingBodySection, decode(&packet));
}

test "decode parses kind 1 document sequence alongside body" {
    const allocator = std.testing.allocator;

    const body = try bson.encode(allocator, .{
        .insert = "users",
        .@"$db" = "test",
    });
    defer allocator.free(body);

    const doc1 = try bson.encode(allocator, .{ .name = "John" });
    defer allocator.free(doc1);
    const doc2 = try bson.encode(allocator, .{ .name = "Jane" });
    defer allocator.free(doc2);

    var packet: std.ArrayList(u8) = .empty;
    defer packet.deinit(allocator);

    // Reserve header + flags; patch length later.
    for (0..fixed_prefix_size) |_| try packet.append(allocator, 0);

    // Kind 0 body.
    try packet.append(allocator, 0);
    try packet.appendSlice(allocator, body);

    // Kind 1 document sequence.
    try packet.append(allocator, 1);
    const sequence_size: i32 = @intCast(4 + "documents".len + 1 + doc1.len + doc2.len);
    try appendInt(&packet, allocator, i32, sequence_size);
    try packet.appendSlice(allocator, "documents");
    try packet.append(allocator, 0);
    try packet.appendSlice(allocator, doc1);
    try packet.appendSlice(allocator, doc2);

    writeIntAt(packet.items, 0, i32, @intCast(packet.items.len));
    writeIntAt(packet.items, 4, i32, 5);
    writeIntAt(packet.items, 8, i32, 0);
    writeIntAt(packet.items, 12, i32, opcode);
    writeIntAt(packet.items, 16, u32, 0);

    const message = try decode(packet.items);
    var sections = message.sectionIterator();

    const first = (try sections.next()).?;
    switch (first) {
        .body => |decoded_body| try std.testing.expectEqualSlices(u8, body, decoded_body),
        else => return error.TestExpectedEqual,
    }

    const second = (try sections.next()).?;
    switch (second) {
        .document_sequence => |sequence| {
            try std.testing.expectEqualStrings("documents", sequence.identifier);

            var documents = sequence.iterator();
            try std.testing.expectEqualSlices(u8, doc1, (try documents.next()).?);
            try std.testing.expectEqualSlices(u8, doc2, (try documents.next()).?);
            try std.testing.expect((try documents.next()) == null);
        },
        else => return error.TestExpectedEqual,
    }

    try std.testing.expect((try sections.next()) == null);
}

test "decode rejects duplicate body sections" {
    const allocator = std.testing.allocator;
    const body = try bson.encode(allocator, .{ .ok = 1 });
    defer allocator.free(body);

    var packet: std.ArrayList(u8) = .empty;
    defer packet.deinit(allocator);
    for (0..fixed_prefix_size) |_| try packet.append(allocator, 0);
    try packet.append(allocator, 0);
    try packet.appendSlice(allocator, body);
    try packet.append(allocator, 0);
    try packet.appendSlice(allocator, body);

    writeIntAt(packet.items, 0, i32, @intCast(packet.items.len));
    writeIntAt(packet.items, 12, i32, opcode);

    try std.testing.expectError(error.MultipleBodySections, decode(packet.items));
}

test "decode rejects invalid section kind" {
    const allocator = std.testing.allocator;
    const body = try bson.encode(allocator, .{ .ok = 1 });
    defer allocator.free(body);

    const packet = try encodeBody(allocator, body, .{});
    defer allocator.free(packet);
    packet[20] = 2;

    try std.testing.expectError(error.InvalidSectionKind, decode(packet));
}
