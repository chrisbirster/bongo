const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const flate = std.compress.flate;

pub const op_compressed: i32 = 2012;
pub const header_size: usize = 16;
pub const compressed_header_size: usize = 25;

pub const Compressor = enum(u8) {
    zlib = 2,

    pub fn name(self: Compressor) []const u8 {
        return switch (self) {
            .zlib => "zlib",
        };
    }

    pub fn fromId(id: u8) ?Compressor {
        return switch (id) {
            2 => .zlib,
            else => null,
        };
    }
};

pub const Error = error{
    MessageTooShort,
    InvalidMessageLength,
    MessageTooLarge,
    NestedCompressedMessage,
    UnsupportedCompressor,
    InvalidCompressedPayload,
    UncompressedSizeMismatch,
};

/// Encode one MongoDB wire message as OP_COMPRESSED.
///
/// The standard 16-byte message header is not compressed. The wrapper retains
/// requestID/responseTo, stores the original opcode, and compresses only the
/// original message body as required by the MongoDB wire protocol.
pub fn compressMessage(
    allocator: Allocator,
    message: []const u8,
    compressor: Compressor,
) ![]u8 {
    try validateMessage(message);
    const original_opcode = std.mem.readInt(i32, message[12..16], .little);
    if (original_opcode == op_compressed) return error.NestedCompressedMessage;

    const compressed_body = switch (compressor) {
        .zlib => try compressZlib(allocator, message[header_size..]),
    };
    defer allocator.free(compressed_body);

    const total_len = compressed_header_size + compressed_body.len;
    if (total_len > std.math.maxInt(i32)) return error.MessageTooLarge;

    const result = try allocator.alloc(u8, total_len);
    errdefer allocator.free(result);
    std.mem.writeInt(i32, result[0..4], @intCast(total_len), .little);
    @memcpy(result[4..12], message[4..12]);
    std.mem.writeInt(i32, result[12..16], op_compressed, .little);
    std.mem.writeInt(i32, result[16..20], original_opcode, .little);
    std.mem.writeInt(i32, result[20..24], @intCast(message.len - header_size), .little);
    result[24] = @intFromEnum(compressor);
    @memcpy(result[25..], compressed_body);
    return result;
}

/// Decode OP_COMPRESSED into the original complete MongoDB wire message.
/// The advertised uncompressed size is validated before allocating.
pub fn decompressMessage(
    allocator: Allocator,
    message: []const u8,
    max_message_size: usize,
) ![]u8 {
    try validateMessage(message);
    if (message.len < compressed_header_size) return error.MessageTooShort;
    if (std.mem.readInt(i32, message[12..16], .little) != op_compressed) {
        return error.InvalidMessageLength;
    }

    const original_opcode = std.mem.readInt(i32, message[16..20], .little);
    if (original_opcode == op_compressed) return error.NestedCompressedMessage;

    const uncompressed_size_i32 = std.mem.readInt(i32, message[20..24], .little);
    if (uncompressed_size_i32 < 0) return error.InvalidMessageLength;
    const uncompressed_size: usize = @intCast(uncompressed_size_i32);
    const total_len = header_size + uncompressed_size;
    if (total_len < header_size or total_len > max_message_size or total_len > std.math.maxInt(i32)) {
        return error.MessageTooLarge;
    }

    const compressor = Compressor.fromId(message[24]) orelse
        return error.UnsupportedCompressor;
    const body = switch (compressor) {
        .zlib => try decompressZlib(
            allocator,
            message[compressed_header_size..],
            uncompressed_size,
        ),
    };
    defer allocator.free(body);

    if (body.len != uncompressed_size) return error.UncompressedSizeMismatch;
    const result = try allocator.alloc(u8, total_len);
    errdefer allocator.free(result);
    std.mem.writeInt(i32, result[0..4], @intCast(total_len), .little);
    @memcpy(result[4..12], message[4..12]);
    std.mem.writeInt(i32, result[12..16], original_opcode, .little);
    @memcpy(result[16..], body);
    return result;
}

pub fn isCompressed(message: []const u8) bool {
    return message.len >= header_size and
        std.mem.readInt(i32, message[12..16], .little) == op_compressed;
}

/// Select the first codec Bongo can actually encode/decode that is also
/// advertised by the server. v0.3 ships the zlib wire codec; URI parsing may
/// recognize other compressor names for forward compatibility, but they are
/// not selected here.
pub fn select(server_compression_array: []const u8) !?Compressor {
    const bson = @import("../bson.zig");
    var reader = try bson.Reader.init(server_compression_array);
    while (try reader.next()) |element| {
        switch (element.value) {
            .string => |name| if (std.mem.eql(u8, name, "zlib")) return .zlib,
            else => {},
        }
    }
    return null;
}

fn validateMessage(message: []const u8) Error!void {
    if (message.len < header_size) return error.MessageTooShort;
    const declared = std.mem.readInt(i32, message[0..4], .little);
    if (declared < header_size or @as(usize, @intCast(declared)) != message.len) {
        return error.InvalidMessageLength;
    }
}

fn compressZlib(allocator: Allocator, input: []const u8) ![]u8 {
    // Zig 0.16 exposes a dedicated stored-block DEFLATE writer. It produces a
    // standards-valid zlib stream without relying on the optimizing compressor
    // path that is currently unsuitable for Bongo's short message buffers.
    // This prioritizes wire interoperability in v0.3; size-reducing DEFLATE can
    // be layered in later without changing OP_COMPRESSED framing.
    const block_count = input.len / 65_535 + 1;
    const block_overhead = std.math.mul(usize, block_count, 5) catch
        return error.MessageTooLarge;
    const capacity = std.math.add(usize, input.len, block_overhead + 6) catch
        return error.MessageTooLarge;

    const output_storage = try allocator.alloc(u8, capacity);
    defer allocator.free(output_storage);
    var output: Io.Writer = .fixed(output_storage);

    var buffer: [flate.max_window_len]u8 = undefined;
    var encoder = try flate.Compress.Raw.init(&output, &buffer, .zlib);
    try encoder.writer.writeAll(input);
    try encoder.writer.flush();

    return allocator.dupe(u8, output.buffered());
}

fn decompressZlib(
    allocator: Allocator,
    input: []const u8,
    expected_size: usize,
) ![]u8 {
    var source: Io.Reader = .fixed(input);
    // Keep the full DEFLATE history window so back-references in normal BSON
    // payloads are supported. streamRemaining is the Zig 0.16 stdlib pattern
    // for consuming a complete compressed stream.
    var history: [flate.max_window_len]u8 = undefined;
    var decompressor = flate.Decompress.init(&source, .zlib, &history);

    const output = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(output);
    var writer: Io.Writer = .fixed(output);

    const decompressed_len = decompressor.reader.streamRemaining(&writer) catch |err| switch (err) {
        error.WriteFailed => return error.UncompressedSizeMismatch,
        error.ReadFailed => return error.InvalidCompressedPayload,
    };

    if (decompressed_len != expected_size or writer.end != expected_size) {
        return error.UncompressedSizeMismatch;
    }
    return output;
}

test "OP_COMPRESSED zlib round trip preserves MongoDB header" {
    const body = "hello compressed mongodb";
    const message = try std.testing.allocator.alloc(u8, header_size + body.len);
    defer std.testing.allocator.free(message);
    std.mem.writeInt(i32, message[0..4], @intCast(message.len), .little);
    std.mem.writeInt(i32, message[4..8], 42, .little);
    std.mem.writeInt(i32, message[8..12], 7, .little);
    std.mem.writeInt(i32, message[12..16], 2013, .little);
    @memcpy(message[16..], body);

    const compressed = try compressMessage(std.testing.allocator, message, .zlib);
    defer std.testing.allocator.free(compressed);
    try std.testing.expect(isCompressed(compressed));
    try std.testing.expectEqual(@as(i32, 2013), std.mem.readInt(i32, compressed[16..20], .little));
    try std.testing.expectEqual(@as(u8, 2), compressed[24]);

    const restored = try decompressMessage(std.testing.allocator, compressed, 1024);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualSlices(u8, message, restored);
}

test "OP_COMPRESSED validates advertised size and compressor" {
    var bad = [_]u8{0} ** compressed_header_size;
    std.mem.writeInt(i32, bad[0..4], compressed_header_size, .little);
    std.mem.writeInt(i32, bad[12..16], op_compressed, .little);
    std.mem.writeInt(i32, bad[16..20], 2013, .little);
    std.mem.writeInt(i32, bad[20..24], 1000, .little);
    bad[24] = 99;
    try std.testing.expectError(
        error.MessageTooLarge,
        decompressMessage(std.testing.allocator, &bad, 100),
    );

    std.mem.writeInt(i32, bad[20..24], 1, .little);
    try std.testing.expectError(
        error.UnsupportedCompressor,
        decompressMessage(std.testing.allocator, &bad, 100),
    );
}
