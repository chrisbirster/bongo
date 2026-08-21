const std = @import("std");
const builtin = @import("builtin");
const Transport = @import("transport.zig").Transport;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    PoolExhausted,
    PoolClosed,
    InvalidMaxSize,
};

pub const State = enum {
    ready,
    closing,
    closed,
};

pub const Stats = struct {
    state: State,
    max_size: usize,
    total: usize,
    idle: usize,
    checked_out: usize,
};

/// Bounded reusable transport pool with explicit lifecycle and accounting.
///
/// `created` is the total number of live transports owned by the pool,
/// including checked-out transports. `checked_out` records transports currently
/// owned by RuntimeClient operations/cursors/transactions. All state transitions
/// and idle-list mutations are synchronized through Zig 0.16's Io mutex.
pub const Pool = struct {
    allocator: Allocator,
    io: Io,
    max_size: usize,
    mutex: Io.Mutex = Io.Mutex.init,
    state: State = .ready,
    created: usize = 0,
    checked_out: usize = 0,
    idle: std.ArrayList(Transport) = .empty,

    pub fn init(io: Io, allocator: Allocator, max_size: usize) Error!Pool {
        if (max_size == 0) return error.InvalidMaxSize;
        return .{ .allocator = allocator, .io = io, .max_size = max_size };
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(self.checked_out == 0);
        self.state = .closing;
        for (self.idle.items) |*transport| transport.deinit();
        self.idle.clearRetainingCapacity();
        self.created = 0;
        self.state = .closed;
        self.idle.deinit(self.allocator);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    pub fn take(self: *Pool) ?Transport {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .ready or self.idle.items.len == 0) return null;
        self.checked_out += 1;
        return self.idle.pop().?;
    }

    pub fn canCreate(self: *Pool) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state == .ready and self.created < self.max_size;
    }

    /// Account for a newly-created transport that is immediately checked out.
    pub fn noteCreated(self: *Pool) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .ready) return error.PoolClosed;
        if (self.created >= self.max_size) return error.PoolExhausted;
        self.created += 1;
        self.checked_out += 1;
    }

    /// Return a healthy checked-out transport to the idle pool.
    pub fn put(self: *Pool, transport: Transport) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .ready) return error.PoolClosed;
        std.debug.assert(self.checked_out > 0);
        // Append first. If allocation fails, ownership remains checked out and
        // the caller can discard the transport without corrupting counters.
        try self.idle.append(self.allocator, transport);
        self.checked_out -= 1;
    }

    /// Permanently discard a checked-out connection after a transport-level
    /// failure. The caller deinitializes the transport before calling this.
    pub fn noteDiscarded(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.created > 0);
        std.debug.assert(self.checked_out > 0);
        self.created -= 1;
        self.checked_out -= 1;
    }

    pub fn stats(self: *Pool) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .state = self.state,
            .max_size = self.max_size,
            .total = self.created,
            .idle = self.idle.items.len,
            .checked_out = self.checked_out,
        };
    }

    pub fn idleCount(self: *Pool) usize {
        return self.stats().idle;
    }

    pub fn createdCount(self: *Pool) usize {
        return self.stats().total;
    }

    pub fn checkedOutCount(self: *Pool) usize {
        return self.stats().checked_out;
    }
};

test "bounded pool accounts for checked-out lifecycle" {
    var pool = try Pool.init(std.testing.io, std.testing.allocator, 2);
    defer pool.deinit();

    try pool.noteCreated();
    try pool.noteCreated();
    var snapshot = pool.stats();
    try std.testing.expectEqual(State.ready, snapshot.state);
    try std.testing.expectEqual(@as(usize, 2), snapshot.total);
    try std.testing.expectEqual(@as(usize, 2), snapshot.checked_out);
    try std.testing.expectEqual(@as(usize, 0), snapshot.idle);
    try std.testing.expect(!pool.canCreate());

    pool.noteDiscarded();
    snapshot = pool.stats();
    try std.testing.expectEqual(@as(usize, 1), snapshot.total);
    try std.testing.expectEqual(@as(usize, 1), snapshot.checked_out);
    try std.testing.expect(pool.canCreate());

    pool.noteDiscarded();
}

test "pool accounting remains consistent under contention" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var pool = try Pool.init(std.testing.io, std.testing.allocator, 8);
    defer pool.deinit();

    const Runner = struct {
        pool: *Pool,
        iterations: usize,

        fn run(self: *@This()) void {
            for (0..self.iterations) |_| {
                while (true) {
                    self.pool.noteCreated() catch {
                        std.Thread.yield() catch {};
                        continue;
                    };
                    break;
                }
                self.pool.noteDiscarded();
            }
        }
    };

    var runner: Runner = .{ .pool = &pool, .iterations = 1000 };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    }
    for (threads) |thread| thread.join();

    const snapshot = pool.stats();
    try std.testing.expectEqual(@as(usize, 0), snapshot.total);
    try std.testing.expectEqual(@as(usize, 0), snapshot.checked_out);
    try std.testing.expectEqual(@as(usize, 0), snapshot.idle);
}
