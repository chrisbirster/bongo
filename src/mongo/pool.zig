const std = @import("std");
const builtin = @import("builtin");
const Transport = @import("transport.zig").Transport;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    PoolExhausted,
    PoolClosed,
    PoolCleared,
    InvalidMaxSize,
};

pub const State = enum {
    ready,
    closing,
    closed,
};

/// Checked-out transport together with the pool generation that created it.
/// A handle from an older generation must never be returned to the idle list.
pub const Handle = struct {
    transport: Transport,
    generation: u64,
};

pub const Stats = struct {
    state: State,
    generation: u64,
    max_size: usize,
    total: usize,
    idle: usize,
    checked_out: usize,
    waiters: usize,
};

/// Bounded reusable transport pool with explicit lifecycle, accounting,
/// generation-based clear semantics, and a Zig 0.16 `Io.Condition` wait queue.
pub const Pool = struct {
    allocator: Allocator,
    io: Io,
    max_size: usize,
    mutex: Io.Mutex = Io.Mutex.init,
    condition: Io.Condition = std.mem.zeroes(Io.Condition),
    state: State = .ready,
    generation: u64 = 0,
    created: usize = 0,
    checked_out: usize = 0,
    waiters: usize = 0,
    idle: std.ArrayList(Handle) = .empty,

    pub fn init(io: Io, allocator: Allocator, max_size: usize) Error!Pool {
        if (max_size == 0) return error.InvalidMaxSize;
        return .{
            .allocator = allocator,
            .io = io,
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.close();
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(self.checked_out == 0);
        std.debug.assert(self.waiters == 0);
        self.idle.deinit(self.allocator);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    /// Begin pool shutdown. Idle transports are closed immediately and all
    /// waiters are woken. Checked-out transports are closed by RuntimeClient
    /// when they are returned; the pool reaches `.closed` when none remain.
    pub fn close(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state == .closed) return;
        self.state = .closing;

        const idle_count = self.idle.items.len;
        for (self.idle.items) |*handle| handle.transport.deinit();
        self.idle.clearRetainingCapacity();
        std.debug.assert(self.created >= idle_count);
        self.created -= idle_count;
        if (self.checked_out == 0) self.state = .closed;
        self.condition.broadcast(self.io);
    }

    /// Clear the current pool generation without closing the client. Idle
    /// connections are closed immediately. Checked-out handles remain owned by
    /// their callers but become stale and will be discarded when checked in.
    pub fn clear(self: *Pool) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .ready) return error.PoolClosed;

        self.generation +%= 1;
        const idle_count = self.idle.items.len;
        for (self.idle.items) |*handle| handle.transport.deinit();
        self.idle.clearRetainingCapacity();
        std.debug.assert(self.created >= idle_count);
        self.created -= idle_count;
        self.condition.broadcast(self.io);
    }

    /// Snapshot the generation before opening a new physical connection. The
    /// generation is checked again by `noteCreated` so a connection created
    /// across a concurrent pool clear cannot be admitted as current.
    pub fn generationSnapshot(self: *Pool) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.generation;
    }

    pub fn take(self: *Pool) ?Handle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .ready or self.idle.items.len == 0) return null;
        const handle = self.idle.pop().?;
        std.debug.assert(handle.generation == self.generation);
        self.checked_out += 1;
        return handle;
    }

    pub fn canCreate(self: *Pool) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state == .ready and self.created < self.max_size;
    }

    /// Block while the pool is full and no idle transport is available.
    /// Callers retry `take`/`canCreate` after this returns because wakeups may
    /// be spurious and another waiter may win the available transport.
    pub fn waitForAvailability(self: *Pool) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.state != .ready) return error.PoolClosed;
        if (self.idle.items.len != 0 or self.created < self.max_size) return;

        self.waiters += 1;
        defer self.waiters -= 1;

        while (self.state == .ready and
            self.idle.items.len == 0 and
            self.created >= self.max_size)
        {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
        if (self.state != .ready) return error.PoolClosed;
    }

    /// Account for a newly-created transport that is immediately checked out.
    /// The caller must pass the generation captured before connection creation.
    pub fn noteCreated(self: *Pool, generation: u64) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .ready) return error.PoolClosed;
        if (generation != self.generation) return error.PoolCleared;
        if (self.created >= self.max_size) return error.PoolExhausted;
        self.created += 1;
        self.checked_out += 1;
    }

    /// Return a healthy checked-out transport to the idle pool. Handles from a
    /// cleared generation are rejected so RuntimeClient can destroy them.
    pub fn put(self: *Pool, handle: Handle) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .ready) return error.PoolClosed;
        if (handle.generation != self.generation) return error.PoolCleared;
        std.debug.assert(self.checked_out > 0);
        // Append first. If allocation fails, ownership remains checked out and
        // the caller can discard the transport without corrupting counters.
        try self.idle.append(self.allocator, handle);
        self.checked_out -= 1;
        self.condition.signal(self.io);
    }

    /// Account for permanently discarding a checked-out connection after a
    /// transport failure, stale-generation rejection, or shutdown. The caller
    /// deinitializes the physical transport before calling this.
    pub fn noteDiscarded(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.created > 0);
        std.debug.assert(self.checked_out > 0);
        self.created -= 1;
        self.checked_out -= 1;
        if (self.state == .closing and self.checked_out == 0) {
            self.state = .closed;
            self.condition.broadcast(self.io);
        } else {
            self.condition.signal(self.io);
        }
    }

    pub fn stats(self: *Pool) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .state = self.state,
            .generation = self.generation,
            .max_size = self.max_size,
            .total = self.created,
            .idle = self.idle.items.len,
            .checked_out = self.checked_out,
            .waiters = self.waiters,
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

    const generation = pool.generationSnapshot();
    try pool.noteCreated(generation);
    try pool.noteCreated(generation);
    var snapshot = pool.stats();
    try std.testing.expectEqual(State.ready, snapshot.state);
    try std.testing.expectEqual(@as(u64, 0), snapshot.generation);
    try std.testing.expectEqual(@as(usize, 2), snapshot.total);
    try std.testing.expectEqual(@as(usize, 2), snapshot.checked_out);
    try std.testing.expectEqual(@as(usize, 0), snapshot.idle);
    try std.testing.expectEqual(@as(usize, 0), snapshot.waiters);
    try std.testing.expect(!pool.canCreate());

    pool.noteDiscarded();
    snapshot = pool.stats();
    try std.testing.expectEqual(@as(usize, 1), snapshot.total);
    try std.testing.expectEqual(@as(usize, 1), snapshot.checked_out);
    try std.testing.expect(pool.canCreate());

    pool.noteDiscarded();
}

test "pool clear advances generation and rejects in-flight old creation" {
    var pool = try Pool.init(std.testing.io, std.testing.allocator, 2);
    defer pool.deinit();

    const old_generation = pool.generationSnapshot();
    try pool.noteCreated(old_generation);
    try pool.clear();

    const snapshot = pool.stats();
    try std.testing.expectEqual(@as(u64, 1), snapshot.generation);
    try std.testing.expectEqual(@as(usize, 1), snapshot.total);
    try std.testing.expectEqual(@as(usize, 1), snapshot.checked_out);
    try std.testing.expectError(error.PoolCleared, pool.noteCreated(old_generation));

    pool.noteDiscarded();
    const current_generation = pool.generationSnapshot();
    try pool.noteCreated(current_generation);
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
                    const generation = self.pool.generationSnapshot();
                    self.pool.noteCreated(generation) catch {
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
    try std.testing.expectEqual(@as(usize, 0), snapshot.waiters);
}

test "pool close wakes waiters" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var pool = try Pool.init(std.testing.io, std.testing.allocator, 1);
    defer pool.deinit();
    try pool.noteCreated(pool.generationSnapshot());

    const Waiter = struct {
        pool: *Pool,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.pool.waitForAvailability() catch |err| {
                self.result = err;
                return;
            };
        }
    };

    var waiter: Waiter = .{ .pool = &pool };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    while (pool.stats().waiters == 0) {
        std.Thread.yield() catch {};
    }
    pool.close();
    thread.join();
    try std.testing.expectEqual(error.PoolClosed, waiter.result.?);

    // Simulate the checked-out transport being destroyed by RuntimeClient
    // after close rejected its return to the idle pool.
    pool.noteDiscarded();
    try std.testing.expectEqual(State.closed, pool.stats().state);
}
