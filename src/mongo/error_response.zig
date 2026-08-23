const std = @import("std");
const bson = @import("../bson.zig");
const op_msg = @import("op_msg.zig");

pub const Error = error{
    UnexpectedResponse,
    InvalidErrorResponse,
};

pub const Label = enum {
    retryable_write,
    retryable_error,
    system_overloaded,
    transient_transaction,
    unknown_transaction_commit,
    no_writes_performed,
};

/// Structured view over a MongoDB command response.
///
/// String fields borrow from the inspected response/body bytes and remain
/// valid only as long as those bytes remain alive.
pub const Status = struct {
    ok: bool,
    code: ?i32 = null,
    code_name: ?[]const u8 = null,
    message: ?[]const u8 = null,
    write_error_code: ?i32 = null,
    write_error_message: ?[]const u8 = null,
    write_concern_code: ?i32 = null,
    write_concern_message: ?[]const u8 = null,
    retryable_write: bool = false,
    retryable_error: bool = false,
    system_overloaded: bool = false,
    transient_transaction: bool = false,
    unknown_transaction_commit: bool = false,
    no_writes_performed: bool = false,

    pub fn retryableRead(self: Status) bool {
        if (self.ok) return false;
        if (self.retryable_error) return true;
        const code = self.code orelse return false;
        return isRetryableReadCode(code);
    }

    pub fn retryableWrite(self: Status) bool {
        return self.retryable_write or self.retryable_error;
    }

    pub fn hasLabel(self: Status, label: Label) bool {
        return switch (label) {
            .retryable_write => self.retryable_write,
            .retryable_error => self.retryable_error,
            .system_overloaded => self.system_overloaded,
            .transient_transaction => self.transient_transaction,
            .unknown_transaction_commit => self.unknown_transaction_commit,
            .no_writes_performed => self.no_writes_performed,
        };
    }
};

pub fn inspect(response_bytes: []const u8, expected_response_to: i32) !Status {
    const message = try op_msg.decode(response_bytes);
    if (message.header.response_to != expected_response_to) {
        return error.UnexpectedResponse;
    }
    return inspectBody(try message.body());
}

pub fn inspectBody(body: []const u8) !Status {
    const ok_value = (try bson.Reader.get(body, "ok")) orelse
        return error.InvalidErrorResponse;
    var status: Status = .{ .ok = commandSucceeded(ok_value) };

    if (try bson.Reader.get(body, "code")) |value| {
        status.code = try int32Value(value);
    }
    if (try bson.Reader.get(body, "codeName")) |value| {
        status.code_name = try stringValue(value);
    }
    if (try bson.Reader.get(body, "errmsg")) |value| {
        status.message = try stringValue(value);
    }

    if (try bson.Reader.get(body, "writeErrors")) |value| {
        const errors = switch (value) {
            .array => |bytes| bytes,
            else => return error.InvalidErrorResponse,
        };
        var reader = try bson.Reader.init(errors);
        if (try reader.next()) |element| {
            const document = switch (element.value) {
                .document => |bytes| bytes,
                else => return error.InvalidErrorResponse,
            };
            if (try bson.Reader.get(document, "code")) |code| {
                status.write_error_code = try int32Value(code);
            }
            if (try bson.Reader.get(document, "errmsg")) |message| {
                status.write_error_message = try stringValue(message);
            }
        }
    }

    if (try bson.Reader.get(body, "writeConcernError")) |value| {
        const document = switch (value) {
            .document => |bytes| bytes,
            else => return error.InvalidErrorResponse,
        };
        if (try bson.Reader.get(document, "code")) |code| {
            status.write_concern_code = try int32Value(code);
        }
        if (try bson.Reader.get(document, "errmsg")) |message| {
            status.write_concern_message = try stringValue(message);
        }
    }

    if (try bson.Reader.get(body, "errorLabels")) |value| {
        const labels = switch (value) {
            .array => |bytes| bytes,
            else => return error.InvalidErrorResponse,
        };
        var reader = try bson.Reader.init(labels);
        while (try reader.next()) |element| {
            const label = try stringValue(element.value);
            if (std.mem.eql(u8, label, "RetryableWriteError")) {
                status.retryable_write = true;
            } else if (std.mem.eql(u8, label, "RetryableError")) {
                status.retryable_error = true;
            } else if (std.mem.eql(u8, label, "SystemOverloadedError")) {
                status.system_overloaded = true;
            } else if (std.mem.eql(u8, label, "TransientTransactionError")) {
                status.transient_transaction = true;
            } else if (std.mem.eql(u8, label, "UnknownTransactionCommitResult")) {
                status.unknown_transaction_commit = true;
            } else if (std.mem.eql(u8, label, "NoWritesPerformed")) {
                status.no_writes_performed = true;
            }
        }
    }

    return status;
}

pub fn isRetryableReadCode(code: i32) bool {
    return switch (code) {
        6, // HostUnreachable
        7, // HostNotFound
        89, // NetworkTimeout
        91, // ShutdownInProgress
        134, // ReadConcernMajorityNotAvailableYet
        189, // PrimarySteppedDown
        262, // ExceededTimeLimit
        9001, // SocketException
        10058, // LegacyNotPrimary
        10107, // NotWritablePrimary
        11600, // InterruptedAtShutdown
        11602, // InterruptedDueToReplStateChange
        13435, // NotPrimaryNoSecondaryOk
        13436, // NotPrimaryOrSecondary
        => true,
        else => false,
    };
}

/// Errors from an established socket/TLS stream for which a fresh server
/// selection and retry is useful. An operation timeout is deliberately not
/// retryable here because its client-side budget has already expired.
pub fn isRetryableTransportError(err: anyerror) bool {
    return switch (err) {
        error.SocketTimeout,
        error.EndOfStream,
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.ConnectionRefused,
        error.PoolCleared,
        => true,
        else => false,
    };
}

fn int32Value(value: bson.Value) !i32 {
    return switch (value) {
        .int32 => |number| number,
        .int64 => |number| std.math.cast(i32, number) orelse return error.InvalidErrorResponse,
        else => return error.InvalidErrorResponse,
    };
}

fn stringValue(value: bson.Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => return error.InvalidErrorResponse,
    };
}

fn commandSucceeded(value: bson.Value) bool {
    return switch (value) {
        .double => |number| number == 1.0,
        .int32 => |number| number == 1,
        .int64 => |number| number == 1,
        else => false,
    };
}

test "error response recognizes MongoDB retry labels and details" {
    const body = try bson.encode(std.testing.allocator, .{
        .ok = @as(i32, 0),
        .code = @as(i32, 10107),
        .codeName = "NotWritablePrimary",
        .errmsg = "not primary",
        .errorLabels = [_][]const u8{
            "RetryableWriteError",
            "RetryableError",
            "SystemOverloadedError",
            "TransientTransactionError",
            "UnknownTransactionCommitResult",
            "NoWritesPerformed",
        },
    });
    defer std.testing.allocator.free(body);

    const status = try inspectBody(body);
    try std.testing.expect(!status.ok);
    try std.testing.expectEqual(@as(?i32, 10107), status.code);
    try std.testing.expectEqualStrings("NotWritablePrimary", status.code_name.?);
    try std.testing.expectEqualStrings("not primary", status.message.?);
    try std.testing.expect(status.hasLabel(.retryable_write));
    try std.testing.expect(status.hasLabel(.retryable_error));
    try std.testing.expect(status.hasLabel(.system_overloaded));
    try std.testing.expect(status.hasLabel(.transient_transaction));
    try std.testing.expect(status.hasLabel(.unknown_transaction_commit));
    try std.testing.expect(status.hasLabel(.no_writes_performed));
    try std.testing.expect(status.retryableRead());
    try std.testing.expect(status.retryableWrite());
}

test "write and write concern details remain inspectable" {
    const body = try bson.encode(std.testing.allocator, .{
        .ok = @as(i32, 1),
        .writeErrors = [_]struct { index: i32, code: i32, errmsg: []const u8 }{.{
            .index = 0,
            .code = 11000,
            .errmsg = "duplicate key",
        }},
        .writeConcernError = .{
            .code = @as(i32, 91),
            .errmsg = "shutdown",
        },
    });
    defer std.testing.allocator.free(body);
    const status = try inspectBody(body);
    try std.testing.expect(status.ok);
    try std.testing.expectEqual(@as(?i32, 11000), status.write_error_code);
    try std.testing.expectEqualStrings("duplicate key", status.write_error_message.?);
    try std.testing.expectEqual(@as(?i32, 91), status.write_concern_code);
    try std.testing.expectEqualStrings("shutdown", status.write_concern_message.?);
}

test "successful response may omit structured error fields" {
    const body = try bson.encode(std.testing.allocator, .{ .ok = @as(i32, 1) });
    defer std.testing.allocator.free(body);
    const status = try inspectBody(body);
    try std.testing.expect(status.ok);
    try std.testing.expect(status.code == null);
    try std.testing.expect(status.code_name == null);
    try std.testing.expect(status.message == null);
    try std.testing.expect(status.write_error_code == null);
    try std.testing.expect(status.write_concern_code == null);
}

test "retryable read codes include majority-read transient failure" {
    try std.testing.expect(isRetryableReadCode(134));
    try std.testing.expect(isRetryableReadCode(10107));
    try std.testing.expect(!isRetryableReadCode(11000));
}

test "operation timeout is not retried after its budget expires" {
    try std.testing.expect(isRetryableTransportError(error.SocketTimeout));
    try std.testing.expect(isRetryableTransportError(error.PoolCleared));
    try std.testing.expect(!isRetryableTransportError(error.OperationTimeout));
}
