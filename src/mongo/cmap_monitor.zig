/// Synchronous CMAP-style monitoring surface used by RuntimeClient's pool.
///
/// Callbacks run after the underlying pool mutation has released its mutex.
/// Keep callbacks lightweight and do not perform re-entrant operations on the
/// same RuntimeClient from the callback.
pub const ConnectionClosedReason = enum {
    idle,
    stale,
    connection_error,
    pool_closed,
    pool_cleared,
};

pub const CheckoutFailedReason = enum {
    timeout,
    pool_closed,
    pool_cleared,
    connection_error,
};

pub const PoolEvent = struct {
    generation: u64,
};

pub const ConnectionEvent = struct {
    generation: u64,
};

pub const ConnectionClosedEvent = struct {
    generation: u64,
    count: usize,
    reason: ConnectionClosedReason,
};

pub const CheckoutFailedEvent = struct {
    generation: u64,
    reason: CheckoutFailedReason,
};

pub const Event = union(enum) {
    pool_opened: PoolEvent,
    pool_closed: PoolEvent,
    pool_cleared: PoolEvent,
    connection_created: ConnectionEvent,
    connection_ready: ConnectionEvent,
    connection_closed: ConnectionClosedEvent,
    checkout_started: PoolEvent,
    checkout_failed: CheckoutFailedEvent,
    checked_out: ConnectionEvent,
    checked_in: ConnectionEvent,
};

pub const Monitor = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, Event) void,

    pub fn emit(self: Monitor, event: Event) void {
        self.callback(self.context, event);
    }
};
