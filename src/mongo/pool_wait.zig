const std = @import("std");
const pool_mod = @import("pool.zig");

const Io = std.Io;
const Pool = pool_mod.Pool;

const WaitTaskResult = union(enum) {
    condition: anyerror!void,
    timer: anyerror!void,
};

pub const Error = error{
    WaitQueueTimeout,
};

/// Wait until a checked-in connection or connection-creation slot becomes
/// available. `deadline` is absolute and monotonic, so wakeups/retries never
/// restart the caller's checkout timeout.
pub fn waitForAvailabilityUntil(
    pool: *Pool,
    deadline: ?Io.Clock.Timestamp,
) !void {
    waitLocked(pool, deadline) catch |err| {
        // Monitoring callbacks run only after `waitLocked` has released the
        // core mutex, so observers cannot re-enter a locked pool.
        switch (err) {
            error.WaitQueueTimeout => pool.checkoutFailed(.timeout),
            error.PoolCleared => pool.checkoutFailed(.pool_cleared),
            error.PoolClosed => pool.checkoutFailed(.pool_closed),
            else => {},
        }
        return err;
    };
}

fn waitLocked(pool: *Pool, deadline: ?Io.Clock.Timestamp) !void {
    const core = &pool.core;
    core.mutex.lockUncancelable(core.io);
    defer core.mutex.unlock(core.io);

    try checkState(pool);
    if (core.idle.items.len != 0 or canStartCreateLocked(pool)) return;

    core.waiters += 1;
    defer core.waiters -= 1;

    while (core.state == .ready and
        core.idle.items.len == 0 and
        !canStartCreateLocked(pool))
    {
        if (deadline) |target| {
            if (!Io.Clock.Timestamp.now(core.io, .awake).compare(.lt, target)) {
                return error.WaitQueueTimeout;
            }
            try waitOnceUntilLocked(pool, target);
        } else {
            core.condition.waitUncancelable(core.io, &core.mutex);
        }
    }

    try checkState(pool);
}

/// The condition wait is cancellable specifically so `Io.Select` can cancel
/// it after the deadline task wins. `cancelDiscard` completes that cancellation
/// before this function returns, ensuring the condition wait has re-acquired
/// the pool mutex before the outer unlock runs.
fn waitOnceUntilLocked(pool: *Pool, deadline: Io.Clock.Timestamp) !void {
    const core = &pool.core;
    var results: [2]WaitTaskResult = undefined;
    var select: Io.Select(WaitTaskResult) = .init(core.io, &results);
    defer select.cancelDiscard();

    try select.concurrent(.condition, conditionWaitTask, .{pool});
    try select.concurrent(.timer, deadlineWaitTask, .{ core.io, deadline });

    switch (try select.await()) {
        .condition => |result| try result,
        .timer => |result| {
            try result;
            return error.WaitQueueTimeout;
        },
    }
}

fn conditionWaitTask(pool: *Pool) anyerror!void {
    const core = &pool.core;
    try core.condition.wait(core.io, &core.mutex);
}

fn deadlineWaitTask(io: Io, deadline: Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io);
}

fn checkState(pool: *Pool) !void {
    return switch (pool.core.state) {
        .ready => {},
        .paused => error.PoolCleared,
        .closing, .closed => error.PoolClosed,
    };
}

fn canStartCreateLocked(pool: *Pool) bool {
    const core = &pool.core;
    const under_max = core.max_size == 0 or
        core.created + core.connecting < core.max_size;
    return core.state == .ready and
        under_max and
        core.connecting < core.max_connecting;
}

test "checkout wait uses one absolute deadline" {
    var pool = try Pool.init(std.testing.io, std.testing.allocator, 1);
    defer pool.deinit();
    try pool.ready();

    const permit = try pool.tryStartCreate();
    try pool.finishCreate(permit);

    const now = Io.Clock.Timestamp.now(std.testing.io, .awake);
    const duration: Io.Clock.Duration = .{
        .raw = Io.Duration.fromMilliseconds(5),
        .clock = .awake,
    };
    const deadline = now.addDuration(duration);

    try std.testing.expectError(
        error.WaitQueueTimeout,
        waitForAvailabilityUntil(&pool, deadline),
    );
    try std.testing.expectEqual(@as(usize, 0), pool.stats().waiters);

    pool.noteDiscarded();
}
