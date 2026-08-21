const core_mod = @import("pool_core.zig");
const monitor_mod = @import("cmap_monitor.zig");

pub const Error = core_mod.Error;
pub const State = core_mod.State;
pub const Handle = core_mod.Handle;
pub const CreatePermit = core_mod.CreatePermit;
pub const Stats = core_mod.Stats;
pub const Event = monitor_mod.Event;
pub const Monitor = monitor_mod.Monitor;
pub const ConnectionClosedReason = monitor_mod.ConnectionClosedReason;
pub const CheckoutFailedReason = monitor_mod.CheckoutFailedReason;

pub const Options = struct {
    min_size: usize = 0,
    max_size: usize = 100,
    max_connecting: usize = 2,
    max_idle_time_ms: u64 = 0,
    monitor: ?Monitor = null,
};

threadlocal var checkout_pool: ?*Pool = null;
threadlocal var maintenance_pool: ?*Pool = null;
threadlocal var suppress_next_checkin_pool: ?*Pool = null;

/// Observable CMAP facade around the validated pool core.
///
/// The core implementation remains isolated in `pool_core.zig`; callbacks are
/// emitted only after core methods return, so user monitoring code never runs
/// while the pool core mutex is held.
pub const Pool = struct {
    core: core_mod.Pool,
    monitor: ?Monitor = null,
    opened_emitted: bool = false,
    closed_emitted: bool = false,

    pub const MonitoringEvent = Event;
    pub const MonitoringMonitor = Monitor;

    pub fn init(io: @import("std").Io, allocator: @import("std").mem.Allocator, max_size: usize) Error!Pool {
        return initWithOptions(io, allocator, .{ .max_size = max_size });
    }

    pub fn initWithOptions(
        io: @import("std").Io,
        allocator: @import("std").mem.Allocator,
        options: Options,
    ) Error!Pool {
        var self: Pool = .{
            .core = try core_mod.Pool.initWithOptions(io, allocator, .{
                .min_size = options.min_size,
                .max_size = options.max_size,
                .max_connecting = options.max_connecting,
                .max_idle_time_ms = options.max_idle_time_ms,
            }),
            .monitor = options.monitor,
        };
        if (self.monitor != null) self.emitOpened();
        return self;
    }

    /// Attach or replace a synchronous CMAP monitor. Attaching after client
    /// construction emits a synthetic `pool_opened` event for the current pool
    /// generation so the observer always has a lifecycle starting point.
    pub fn setMonitor(self: *Pool, monitor: Monitor) void {
        self.monitor = monitor;
        self.closed_emitted = false;
        self.emitOpened();
    }

    pub fn clearMonitor(self: *Pool) void {
        self.monitor = null;
    }

    pub fn ready(self: *Pool) Error!void {
        return self.core.ready();
    }

    pub fn deinit(self: *Pool) void {
        self.close();
        self.core.deinit();
        if (checkout_pool == self) checkout_pool = null;
        if (maintenance_pool == self) maintenance_pool = null;
        if (suppress_next_checkin_pool == self) suppress_next_checkin_pool = null;
        self.* = undefined;
    }

    pub fn close(self: *Pool) void {
        const before = self.core.stats();
        self.core.close();
        if (before.idle > 0) {
            self.emit(.{ .connection_closed = .{
                .generation = before.generation,
                .count = before.idle,
                .reason = .pool_closed,
            } });
        }
        if (!self.closed_emitted) {
            self.closed_emitted = true;
            self.emit(.{ .pool_closed = .{ .generation = before.generation } });
        }
        if (checkout_pool == self) self.checkoutFailed(.pool_closed);
    }

    pub fn clear(self: *Pool) Error!void {
        const before = self.core.stats();
        try self.core.clear();
        const generation = self.core.generationSnapshot();
        if (before.idle > 0) {
            self.emit(.{ .connection_closed = .{
                .generation = before.generation,
                .count = before.idle,
                .reason = .pool_cleared,
            } });
        }
        self.emit(.{ .pool_cleared = .{ .generation = generation } });
        if (checkout_pool == self) self.checkoutFailed(.pool_cleared);
    }

    pub fn generationSnapshot(self: *Pool) u64 {
        return self.core.generationSnapshot();
    }

    /// Begin or continue one logical application checkout. RuntimeClient calls
    /// `take` first on every checkout loop, so a waiter/retry keeps one start
    /// event until it either succeeds or records a terminal failure.
    pub fn take(self: *Pool) ?Handle {
        if (checkout_pool != self) {
            checkout_pool = self;
            self.emit(.{ .checkout_started = .{
                .generation = self.core.generationSnapshot(),
            } });
        }

        const before = self.core.stats();
        const result = self.core.take();
        const after = self.core.stats();
        self.emitIdleReclamation(before, after);
        if (result) |handle| {
            self.emit(.{ .checked_out = .{ .generation = handle.generation } });
            checkout_pool = null;
        }
        return result;
    }

    pub fn tryStartCreate(self: *Pool) Error!CreatePermit {
        const permit = self.core.tryStartCreate() catch |err| {
            if (err == error.PoolCleared and checkout_pool == self) {
                self.checkoutFailed(.pool_cleared);
            } else if (err == error.PoolClosed and checkout_pool == self) {
                self.checkoutFailed(.pool_closed);
            }
            return err;
        };
        self.emit(.{ .connection_created = .{ .generation = permit.generation } });
        return permit;
    }

    pub fn finishCreate(self: *Pool, permit: CreatePermit) Error!void {
        self.core.finishCreate(permit) catch |err| {
            const reason: ConnectionClosedReason = switch (err) {
                error.PoolCleared => .pool_cleared,
                error.PoolClosed => .pool_closed,
                else => .error,
            };
            self.emit(.{ .connection_closed = .{
                .generation = permit.generation,
                .count = 1,
                .reason = reason,
            } });
            if (checkout_pool == self) {
                self.checkoutFailed(switch (err) {
                    error.PoolCleared => .pool_cleared,
                    error.PoolClosed => .pool_closed,
                    else => .connection_error,
                });
            }
            return err;
        };

        self.emit(.{ .connection_ready = .{ .generation = permit.generation } });
        if (checkout_pool == self and maintenance_pool != self) {
            self.emit(.{ .checked_out = .{ .generation = permit.generation } });
            checkout_pool = null;
        } else {
            // Initial client connection and minPoolSize warming become idle
            // without ever being application checkouts.
            suppress_next_checkin_pool = self;
        }
    }

    pub fn cancelCreate(self: *Pool, permit: CreatePermit) void {
        self.core.cancelCreate(permit);
        self.emit(.{ .connection_closed = .{
            .generation = permit.generation,
            .count = 1,
            .reason = .error,
        } });
        if (checkout_pool == self) self.checkoutFailed(.connection_error);
    }

    pub fn canCreate(self: *Pool) bool {
        return self.core.canCreate();
    }

    pub fn needsMinConnections(self: *Pool) bool {
        const before = self.core.stats();
        const result = self.core.needsMinConnections();
        const after = self.core.stats();
        self.emitIdleReclamation(before, after);
        if (result) {
            maintenance_pool = self;
        } else if (maintenance_pool == self) {
            maintenance_pool = null;
        }
        return result;
    }

    pub fn pruneIdle(self: *Pool) usize {
        const before = self.core.stats();
        const removed = self.core.pruneIdle();
        const after = self.core.stats();
        self.emitIdleReclamation(before, after);
        return removed;
    }

    pub fn waitForAvailability(self: *Pool) Error!void {
        return self.core.waitForAvailability();
    }

    pub fn put(self: *Pool, handle: Handle) !void {
        try self.core.put(handle);
        if (suppress_next_checkin_pool == self) {
            suppress_next_checkin_pool = null;
        } else if (maintenance_pool == self) {
            maintenance_pool = null;
        } else {
            self.emit(.{ .checked_in = .{ .generation = handle.generation } });
        }
    }

    pub fn noteDiscarded(self: *Pool) void {
        const before = self.core.stats();
        self.core.noteDiscarded();
        const reason: ConnectionClosedReason = switch (before.state) {
            .paused => .pool_cleared,
            .closing, .closed => .pool_closed,
            .ready => .error,
        };
        self.emit(.{ .connection_closed = .{
            .generation = before.generation,
            .count = 1,
            .reason = reason,
        } });
    }

    pub fn stats(self: *Pool) Stats {
        return self.core.stats();
    }

    pub fn idleCount(self: *Pool) usize {
        return self.core.idleCount();
    }

    pub fn createdCount(self: *Pool) usize {
        return self.core.createdCount();
    }

    pub fn checkedOutCount(self: *Pool) usize {
        return self.core.checkedOutCount();
    }

    /// Used by the deadline wait helper to close one logical checkout exactly
    /// once when timeout/clear/shutdown wins the wait race.
    pub fn checkoutFailed(self: *Pool, reason: CheckoutFailedReason) void {
        if (checkout_pool != self) return;
        const generation = self.core.generationSnapshot();
        checkout_pool = null;
        self.emit(.{ .checkout_failed = .{
            .generation = generation,
            .reason = reason,
        } });
    }

    fn emitOpened(self: *Pool) void {
        self.opened_emitted = true;
        self.emit(.{ .pool_opened = .{
            .generation = self.core.generationSnapshot(),
        } });
    }

    fn emitIdleReclamation(self: *Pool, before: Stats, after: Stats) void {
        if (before.total <= after.total) return;
        self.emit(.{ .connection_closed = .{
            .generation = before.generation,
            .count = before.total - after.total,
            .reason = .idle,
        } });
    }

    fn emit(self: *Pool, event: Event) void {
        const monitor = self.monitor orelse return;
        monitor.emit(event);
    }
};
