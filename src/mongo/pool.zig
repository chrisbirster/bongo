const std = @import("std");
const builtin = @import("builtin");
const Transport = @import("transport.zig").Transport;

const Allocator = std.mem.Allocator;

pub const Error = error{
    PoolExhausted,
    InvalidMaxSize,
};

/// Small bounded reusable transport pool.
///
/// All accounting and idle-list mutations are synchronized so multiple
/// RuntimeClient operations can safely check transports in and out from
/// different threads. Connection creation still happens outside the mutex;
/// `noteCreated` is the final capacity reservation and can reject a racing
/// creator, which must then close its just-created transport.
pub const Pool = struct {
    allocator: Allocator,
    max_size: usize,
    mutex: std.Thread.Mutex = .{},
    created: usize = 0,
    idle: std.ArrayList(Transport) = .empty,

    pub fn init(allocator: Allocator, max_size: usize) Error!Pool {
        if (max_size == 0) return error.InvalidMaxSize;
        return .{ .allocator = allocator, .max_size = max_size };
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lock();
        for (self.idle.items) |*transport| transport.deinit();
        self.idle.deinit(self.allocator);
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn take(self: *Pool) ?Transport {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.idle.items.len == 0) return null;
        return self.idle.pop().?;
    }

    pub fn canCreate(self: *Pool) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.created < self.max_size;
    }

    pub fn noteCreated(self: *Pool) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.created >= self.max_size) return error.PoolExhausted;
        self.created += 1;
    }

    pub fn put(self: *Pool, transport: Transport) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.idle.append(self.allocator, transport);
    }

    /// Permanently discard a checked-out connection after a transport-level
    /// failure. The caller deinitializes the transport before calling this.
    pub fn noteDiscarded(self: *Pool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.created > 0);
        self.created -= 1;
    }

    pub fn idleCount(self: *Pool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.idle.items.len;
    }

    pub fn createdCount(self: *Pool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.created;
    }
};

test "bounded pool accounts for checkout and discard" {
    var pool = try Pool.init(std.testing.allocator, 2);
    defer pool.deinit();
    try pool.noteCreated();
    try pool.noteCreated();
    try std.testing.expect(!pool.canCreate());
    pool.noteDiscarded();
    try std.testing.expect(pool.canCreate());
}

test "pool accounting remains consistent under contention" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var pool = try Pool.init(std.testing.allocator, 8);
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

    try std.testing.expectEqual(@as(usize, 0), pool.createdCount());
    try std.testing.expectEqual(@as(usize, 0), pool.idleCount());
}
