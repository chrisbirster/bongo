const std = @import("std");
const builtin = @import("builtin");
const Transport = @import("transport.zig").Transport;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    PoolExhausted,
    PoolClosed,
    PoolCleared,
    ConnectLimitReached,
    InvalidMinSize,
    InvalidMaxConnecting,
    InvalidMaxIdleTime,
};

pub const State = enum {
    paused,
    ready,
    closing,
    closed,
};

pub const Options = struct {
    min_size: usize = 0,
    /// CMAP: 0 means unlimited; otherwise the cap includes pending + idle + in-use.
    max_size: usize = 100,
    max_connecting: usize = 2,
    /// CMAP: 0 disables idle expiry.
    max_idle_time_ms: u64 = 0,
};

/// Checked-out transport together with the pool generation that created it.
/// `idle_since` is populated only while the handle is available in the pool.
pub const Handle = struct {
    transport: Transport,
    generation: u64,
    idle_since: ?Io.Clock.Timestamp = null,
};

/// Reservation acquired before opening a physical connection. Reserving first
/// prevents concurrent callers from exceeding maxPoolSize/maxConnecting while
/// network work is in flight.
pub const CreatePermit = struct {
    generation: u64,
};

pub const Stats = struct {
    state: State,
    generation: u64,
    min_size: usize,
    max_size: usize,
    max_connecting: usize,
    max_idle_time_ms: u64,
    total: usize,
    connecting: usize,
    idle: usize,
    checked_out: usize,
    waiters: usize,
};

/// CMAP-oriented reusable transport pool with explicit lifecycle, generation
/// clearing, controlled connection establishment, idle expiry, and a Zig 0.16
/// Io wait queue.
pub const Pool = struct {
    allocator: Allocator,
    io: Io,
    min_size: usize,
    max_size: usize,
    max_connecting: usize,
    max_idle_time_ms: u64,
    mutex: Io.Mutex = Io.Mutex.init,
    condition: Io.Condition = std.mem.zeroes(Io.Condition),
    state: State = .paused,
    generation: u64 = 0,
    created: usize = 0,
    connecting: usize = 0,
    checked_out: usize = 0,
    waiters: usize = 0,
    idle: std.ArrayList(Handle) = .empty,

    pub fn init(io: Io, allocator: Allocator, max_size: usize) Error!Pool {
        return initWithOptions(io, allocator, .{ .max_size = max_size });
    }

    pub fn initWithOptions(io: Io, allocator: Allocator, options: Options) Error!Pool {
        if (options.max_size > 0 and options.min_size > options.max_size) {
            return error.InvalidMinSize;
        }
        if (options.max_connecting == 0) return error.InvalidMaxConnecting;
        if (options.max_idle_time_ms > std.math.maxInt(i64)) {
            return error.InvalidMaxIdleTime;
        }
        return .{
            .allocator = allocator,
            .io = io,
            .min_size = options.min_size,
            .max_size = options.max_size,
            .max_connecting = options.max_connecting,
            .max_idle_time_ms = options.max_idle_time_ms,
        };
    }

    pub fn ready(self: *Pool) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (self.state) {
            .paused => {
                self.state = .ready;
                self.condition.broadcast(self.io);
            },
            .ready => {},
            .closing, .closed => return error.PoolClosed,
        }
    }

    pub fn deinit(self: *Pool) void {
        self.close();
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(self.checked_out == 0);
        std.debug.assert(self.connecting == 0);
        std.debug.assert(self.waiters == 0);
        self.idle.deinit(self.allocator);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

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
        self.maybeFinishCloseLocked();
        self.condition.broadcast(self.io);
    }

    /// CMAP clear: invalidate the generation, close idle connections, evict
    /// waiters, and pause the pool until SDAM calls `ready` again.
    pub fn clear(self: *Pool) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (self.state) {
            .closing, .closed => return error.PoolClosed,
            .paused, .ready => {},
        }

        self.generation +%= 1;
        const idle_count = self.idle.items.len;
        for (self.idle.items) |*handle| handle.transport.deinit();
        self.idle.clearRetainingCapacity();
        std.debug.assert(self.created >= idle_count);
        self.created -= idle_count;
        self.state = .paused;
        self.condition.broadcast(self.io);
    }

    pub fn generationSnapshot(self: *Pool) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.generation;
    }

    /// CMAP checkout removes perished idle connections before returning a live
    /// handle. Idle expiry is evaluated with the monotonic `.awake` clock.
    pub fn take(self: *Pool) ?Handle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .ready) return null;
        _ = self.pruneIdleLocked();
        if (self.idle.items.len == 0) return null;
        var handle = self.idle.pop().?;
        std.debug.assert(handle.generation == self.generation);
        handle.idle_since = null;
        self.checked_out += 1;
        return handle;
    }

    pub fn tryStartCreate(self: *Pool) Error!CreatePermit {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return switch (self.state) {
            .paused => error.PoolCleared,
            .closing, .closed => error.PoolClosed,
            .ready => blk: {
                if (!self.underMaxLocked()) break :blk error.PoolExhausted;
                if (self.connecting >= self.max_connecting) break :blk error.ConnectLimitReached;
                self.connecting += 1;
                break :blk .{ .generation = self.generation };
            },
        };
    }

    pub fn finishCreate(self: *Pool, permit: CreatePermit) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.connecting > 0);
        self.connecting -= 1;

        switch (self.state) {
            .paused => {
                self.condition.broadcast(self.io);
                return error.PoolCleared;
            },
            .closing, .closed => {
                self.maybeFinishCloseLocked();
                self.condition.broadcast(self.io);
                return error.PoolClosed;
            },
            .ready => {},
        }
        if (permit.generation != self.generation) {
            self.condition.broadcast(self.io);
            return error.PoolCleared;
        }
        if (self.max_size > 0 and self.created >= self.max_size) {
            self.condition.signal(self.io);
            return error.PoolExhausted;
        }

        self.created += 1;
        self.checked_out += 1;
        self.condition.signal(self.io);
    }

    pub fn cancelCreate(self: *Pool, permit: CreatePermit) void {
        _ = permit;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.connecting > 0);
        self.connecting -= 1;
        self.maybeFinishCloseLocked();
        if (self.state == .closed or self.state == .paused) {
            self.condition.broadcast(self.io);
        } else {
            self.condition.signal(self.io);
        }
    }

    pub fn canCreate(self: *Pool) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.canStartCreateLocked();
    }

    /// Prune expired idle connections and report whether the pool is below its
    /// configured minimum. RuntimeClient uses this to replenish after check-in.
    pub fn needsMinConnections(self: *Pool) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .ready) return false;
        _ = self.pruneIdleLocked();
        return self.created + self.connecting < self.min_size;
    }

    /// Explicit maintenance hook for the future SDAM monitor cadence.
    pub fn pruneIdle(self: *Pool) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pruneIdleLocked();
    }

    pub fn waitForAvailability(self: *Pool) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        switch (self.state) {
            .paused => return error.PoolCleared,
            .closing, .closed => return error.PoolClosed,
            .ready => {},
        }
        _ = self.pruneIdleLocked();
        if (self.idle.items.len != 0 or self.canStartCreateLocked()) return;

        self.waiters += 1;
        defer self.waiters -= 1;

        while (self.state == .ready and
            self.idle.items.len == 0 and
            !self.canStartCreateLocked())
        {
            self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.state == .ready) _ = self.pruneIdleLocked();
        }

        return switch (self.state) {
            .ready => {},
            .paused => error.PoolCleared,
            .closing, .closed => error.PoolClosed,
        };
    }

    pub fn put(self: *Pool, handle_value: Handle) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (self.state) {
            .paused => return error.PoolCleared,
            .closing, .closed => return error.PoolClosed,
            .ready => {},
        }
        if (handle_value.generation != self.generation) return error.PoolCleared;
        std.debug.assert(self.checked_out > 0);
        var handle = handle_value;
        handle.idle_since = Io.Clock.Timestamp.now(self.io, .awake);
        try self.idle.append(self.allocator, handle);
        self.checked_out -= 1;
        self.condition.signal(self.io);
    }

    pub fn noteDiscarded(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.created > 0);
        std.debug.assert(self.checked_out > 0);
        self.created -= 1;
        self.checked_out -= 1;
        self.maybeFinishCloseLocked();
        if (self.state == .closed or self.state == .paused) {
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
            .min_size = self.min_size,
            .max_size = self.max_size,
            .max_connecting = self.max_connecting,
            .max_idle_time_ms = self.max_idle_time_ms,
            .total = self.created,
            .connecting = self.connecting,
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

    fn pruneIdleLocked(self: *Pool) usize {
        if (self.max_idle_time_ms == 0 or self.idle.items.len == 0) return 0;
        const now = Io.Clock.Timestamp.now(self.io, .awake);
        var write_index: usize = 0;
        var removed: usize = 0;
        for (self.idle.items) |handle| {
            if (self.idleExpiredLocked(handle, now)) {
                var doomed = handle.transport;
                doomed.deinit();
                std.debug.assert(self.created > 0);
                self.created -= 1;
                removed += 1;
            } else {
                self.idle.items[write_index] = handle;
                write_index += 1;
            }
        }
        self.idle.items = self.idle.items[0..write_index];
        if (removed > 0) self.condition.broadcast(self.io);
        return removed;
    }

    fn idleExpiredLocked(
        self: *Pool,
        handle: Handle,
        now: Io.Clock.Timestamp,
    ) bool {
        const idle_since = handle.idle_since orelse return false;
        const milliseconds: i64 = @intCast(self.max_idle_time_ms);
        const duration: Io.Clock.Duration = .{
            .raw = Io.Duration.fromMilliseconds(milliseconds),
            .clock = .awake,
        };
        const deadline = idle_since.addDuration(duration);
        return !now.compare(.lt, deadline);
    }

    fn underMaxLocked(self: *Pool) bool {
        return self.max_size == 0 or self.created + self.connecting < self.max_size;
    }

    fn canStartCreateLocked(self: *Pool) bool {
        return self.state == .ready and
            self.underMaxLocked() and
            self.connecting < self.max_connecting;
    }

    fn maybeFinishCloseLocked(self: *Pool) void {
        if (self.state == .closing and
            self.checked_out == 0 and
            self.connecting == 0)
        {
            self.state = .closed;
        }
    }
};

test "pool validates sizing and idle options" {
    var unlimited = try Pool.initWithOptions(std.testing.io, std.testing.allocator, .{
        .max_size = 0,
    });
    defer unlimited.deinit();
    try unlimited.ready();
    try std.testing.expect(unlimited.canCreate());

    try std.testing.expectError(
        error.InvalidMinSize,
        Pool.initWithOptions(std.testing.io, std.testing.allocator, .{
            .min_size = 3,
            .max_size = 2,
        }),
    );
    try std.testing.expectError(
        error.InvalidMaxConnecting,
        Pool.initWithOptions(std.testing.io, std.testing.allocator, .{
            .max_connecting = 0,
        }),
    );
    try std.testing.expectError(
        error.InvalidMaxIdleTime,
        Pool.initWithOptions(std.testing.io, std.testing.allocator, .{
            .max_idle_time_ms = @as(u64, std.math.maxInt(i64)) + 1,
        }),
    );
}

test "bounded pool accounts for checked-out lifecycle" {
    var pool = try Pool.initWithOptions(std.testing.io, std.testing.allocator, .{
        .max_size = 2,
        .max_connecting = 2,
    });
    defer pool.deinit();
    try pool.ready();

    const first = try pool.tryStartCreate();
    try pool.finishCreate(first);
    const second = try pool.tryStartCreate();
    try pool.finishCreate(second);

    var snapshot = pool.stats();
    try std.testing.expectEqual(State.ready, snapshot.state);
    try std.testing.expectEqual(@as(u64, 0), snapshot.generation);
    try std.testing.expectEqual(@as(usize, 2), snapshot.total);
    try std.testing.expectEqual(@as(usize, 0), snapshot.connecting);
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

test "creation permits enforce maxConnecting before network work" {
    var pool = try Pool.initWithOptions(std.testing.io, std.testing.allocator, .{
        .max_size = 4,
        .max_connecting = 1,
    });
    defer pool.deinit();
    try pool.ready();

    const permit = try pool.tryStartCreate();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().connecting);
    try std.testing.expectError(error.ConnectLimitReached, pool.tryStartCreate());
    pool.cancelCreate(permit);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().connecting);
}

test "pool clear pauses and rejects old generation creation permits" {
    var pool = try Pool.initWithOptions(std.testing.io, std.testing.allocator, .{
        .max_size = 2,
        .max_connecting = 2,
    });
    defer pool.deinit();
    try pool.ready();

    const checked_out = try pool.tryStartCreate();
    try pool.finishCreate(checked_out);
    const in_flight = try pool.tryStartCreate();

    try pool.clear();
    const snapshot = pool.stats();
    try std.testing.expectEqual(State.paused, snapshot.state);
    try std.testing.expectEqual(@as(u64, 1), snapshot.generation);
    try std.testing.expectEqual(@as(usize, 1), snapshot.total);
    try std.testing.expectEqual(@as(usize, 1), snapshot.checked_out);
    try std.testing.expectEqual(@as(usize, 1), snapshot.connecting);
    try std.testing.expectError(error.PoolCleared, pool.finishCreate(in_flight));
    try std.testing.expectError(error.PoolCleared, pool.tryStartCreate());

    pool.noteDiscarded();
    try pool.ready();
    const current = try pool.tryStartCreate();
    try pool.finishCreate(current);
    pool.noteDiscarded();
}

test "pool accounting remains consistent under contention" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var pool = try Pool.initWithOptions(std.testing.io, std.testing.allocator, .{
        .max_size = 8,
        .max_connecting = 2,
    });
    defer pool.deinit();
    try pool.ready();

    const Runner = struct {
        pool: *Pool,
        iterations: usize,

        fn run(self: *@This()) void {
            for (0..self.iterations) |_| {
                while (true) {
                    const permit = self.pool.tryStartCreate() catch {
                        std.Thread.yield() catch {};
                        continue;
                    };
                    self.pool.finishCreate(permit) catch {
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
    try std.testing.expectEqual(@as(usize, 0), snapshot.connecting);
    try std.testing.expectEqual(@as(usize, 0), snapshot.checked_out);
    try std.testing.expectEqual(@as(usize, 0), snapshot.idle);
    try std.testing.expectEqual(@as(usize, 0), snapshot.waiters);
}

test "pool clear evicts waiters with PoolCleared" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var pool = try Pool.init(std.testing.io, std.testing.allocator, 1);
    defer pool.deinit();
    try pool.ready();
    const permit = try pool.tryStartCreate();
    try pool.finishCreate(permit);

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
    try pool.clear();
    thread.join();
    try std.testing.expectEqual(error.PoolCleared, waiter.result.?);

    pool.noteDiscarded();
}

test "pool close wakes waiters" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var pool = try Pool.init(std.testing.io, std.testing.allocator, 1);
    defer pool.deinit();
    try pool.ready();
    const permit = try pool.tryStartCreate();
    try pool.finishCreate(permit);

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

    pool.noteDiscarded();
    try std.testing.expectEqual(State.closed, pool.stats().state);
}
