const std = @import("std");
const bson = @import("../bson.zig");

const Io = std.Io;

pub const TransactionState = enum {
    none,
    starting,
    in_progress,
    committed,
    aborted,
};

pub const ReadConcern = enum {
    local,
    majority,
    snapshot,

    pub fn wireName(self: ReadConcern) []const u8 {
        return switch (self) {
            .local => "local",
            .majority => "majority",
            .snapshot => "snapshot",
        };
    }
};

pub const TransactionOptions = struct {
    read_concern: ?ReadConcern = .snapshot,
    majority_write_concern: bool = true,
    max_commit_time_ms: ?u64 = null,
};

pub const Error = error{
    TransactionAlreadyActive,
    NoActiveTransaction,
    TransactionAlreadyFinished,
    TransactionNumberOverflow,
};

/// Explicit MongoDB client session.
///
/// The `id` is encoded as BSON UUID subtype 4 in the `lsid` document. The same
/// transaction-number counter is used by multi-document transactions and by
/// retryable single-document writes so a command can be resent with the exact
/// same `(lsid, txnNumber)` pair.
pub const Session = struct {
    id: [16]u8,
    txn_number: i64 = -1,
    transaction_state: TransactionState = .none,
    transaction_options: TransactionOptions = .{},

    pub fn init(io: Io) Session {
        var id: [16]u8 = undefined;
        io.random(&id);
        // RFC 4122 variant/version bits make logs and diagnostics recognize
        // the value as a normal v4 UUID while MongoDB only requires a UUID.
        id[6] = (id[6] & 0x0f) | 0x40;
        id[8] = (id[8] & 0x3f) | 0x80;
        return .{ .id = id };
    }

    pub fn lsid(self: *const Session) struct { id: bson.Binary } {
        return .{
            .id = .{
                .subtype = .uuid,
                .data = self.id[0..],
            },
        };
    }

    pub fn nextTransactionNumber(self: *Session) Error!i64 {
        if (self.txn_number == std.math.maxInt(i64)) {
            return error.TransactionNumberOverflow;
        }
        self.txn_number += 1;
        return self.txn_number;
    }

    pub fn beginTransaction(
        self: *Session,
        options: TransactionOptions,
    ) Error!void {
        switch (self.transaction_state) {
            .starting, .in_progress => return error.TransactionAlreadyActive,
            else => {},
        }
        _ = try self.nextTransactionNumber();
        self.transaction_state = .starting;
        self.transaction_options = options;
    }

    pub fn isFirstTransactionCommand(self: Session) bool {
        return self.transaction_state == .starting;
    }

    pub fn markCommandSucceeded(self: *Session) Error!void {
        switch (self.transaction_state) {
            .starting => self.transaction_state = .in_progress,
            .in_progress => {},
            .none => return error.NoActiveTransaction,
            .committed, .aborted => return error.TransactionAlreadyFinished,
        }
    }

    pub fn markCommitted(self: *Session) Error!void {
        switch (self.transaction_state) {
            .starting, .in_progress => self.transaction_state = .committed,
            .none => return error.NoActiveTransaction,
            .committed, .aborted => return error.TransactionAlreadyFinished,
        }
    }

    pub fn markAborted(self: *Session) Error!void {
        switch (self.transaction_state) {
            .starting, .in_progress => self.transaction_state = .aborted,
            .none => return error.NoActiveTransaction,
            .committed, .aborted => return error.TransactionAlreadyFinished,
        }
    }

    pub fn reset(self: *Session) void {
        self.transaction_state = .none;
        self.transaction_options = .{};
    }
};

test "session uses BSON UUID lsid and monotonic transaction numbers" {
    var session = Session.init(std.testing.io);
    const lsid = session.lsid();
    try std.testing.expectEqual(bson.BinarySubtype.uuid, lsid.id.subtype);
    try std.testing.expectEqual(@as(usize, 16), lsid.id.data.len);

    try std.testing.expectEqual(@as(i64, 0), try session.nextTransactionNumber());
    try session.beginTransaction(.{});
    try std.testing.expectEqual(@as(i64, 1), session.txn_number);
    try std.testing.expect(session.isFirstTransactionCommand());
    try session.markCommandSucceeded();
    try std.testing.expectEqual(TransactionState.in_progress, session.transaction_state);
    try session.markCommitted();
    session.reset();
    try session.beginTransaction(.{});
    try std.testing.expectEqual(@as(i64, 2), session.txn_number);
}
