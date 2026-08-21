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
///
/// The condition wait is cancellable specifically so `Io.Select` can cancel
/// it after the deadline task wins. `cancelDiscard` completes that cancellation
/// before this function returns, ensuring the condition wait has re-acquired
/// the pool mutex before the outer unlock runs.
pub fn waitForAvailabilityUntil(
    pool: *Pool,
    deadline: ?Io.Clock.Timestamp,
) !void {
    pool.mutex.lockUncancelable(pool.io);
    defer pool.mutex.unlock(pool.io);

    try checkState(pool);
    if (pool.idle.items.len != 0 or canStartCreateLocked(pool)) return;

    pool.waiters += 1;
    defer pool.waiters -= 1;

    while (pool.state == .ready and
        pool.idle.items.len == 0 and
        !canStartCreateLocked(pool))
    {
        if (deadline) |target| {
            if (!Io.Clock.Timestamp.now(pool.io, .awake).compare(.lt, target)) {
                return error.WaitQueueTimeout;
            }
            try waitOnceUntilLocked(pool, target);
        } else {
            pool.condition.waitUncancelable(pool.io, &pool.mutex);
        }
    }

    try checkState(pool);
}

fn waitOnceUntilLocked(pool: *Pool, deadline: Io.Clock.Timestamp) !void {
    var results: [2]WaitTaskResult = undefined;
    var select: Io.Select(WaitTaskResult) = .init(pool.io, &results);
    defer select.cancelDiscard();

    try select.concurrent(.condition, conditionWaitTask, .{pool});
    try select.concurrent(.timer, deadlineWaitTask, .{ pool.io, deadline });

    switch (try select.await()) {
        .condition => |result| try result,
        .timer => |result| {
            try result;
            return error.WaitQueueTimeout;
        },
    }
}

fn conditionWaitTask(pool: *Pool) anyerror!void {
    try pool.condition.wait(pool.io, &pool.mutex);
}

fn deadlineWaitTask(io: Io, deadline: Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io);
}

fn checkState(pool: *Pool) !void {
    return switch (pool.state) {
        .ready => {},
        .paused => error.PoolCleared,
        .closing, .closed => error.PoolClosed,
    };
}

fn canStartCreateLocked(pool: *Pool) bool {
    const under_max = pool.max_size == 0 or
        pool.created + pool.connecting < pool.max_size;
    return pool.state == .ready and
        under_max and
        pool.connecting < pool.max_connecting;
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
