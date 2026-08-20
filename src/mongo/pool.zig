const std = @import("std");
const Transport = @import("transport.zig").Transport;

const Allocator = std.mem.Allocator;

pub const Error = error{
    PoolExhausted,
    InvalidMaxSize,
};

/// Small bounded idle-connection pool.
///
/// The managed client owns creation/authentication and uses this type for
/// lifetime accounting. Deez is single-process CLI software today, so this
/// first pool deliberately does not claim concurrent checkout safety; CMAP
/// synchronization can evolve independently without changing the checkout API.
pub const Pool = struct {
    allocator: Allocator,
    max_size: usize,
    created: usize = 0,
    idle: std.ArrayList(Transport) = .empty,

    pub fn init(allocator: Allocator, max_size: usize) Error!Pool {
        if (max_size == 0) return error.InvalidMaxSize;
        return .{ .allocator = allocator, .max_size = max_size };
    }

    pub fn deinit(self: *Pool) void {
        for (self.idle.items) |*transport| transport.deinit();
        self.idle.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn take(self: *Pool) ?Transport {
        if (self.idle.items.len == 0) return null;
        return self.idle.pop().?;
    }

    pub fn canCreate(self: Pool) bool {
        return self.created < self.max_size;
    }

    pub fn noteCreated(self: *Pool) Error!void {
        if (!self.canCreate()) return error.PoolExhausted;
        self.created += 1;
    }

    pub fn put(self: *Pool, transport: Transport) !void {
        try self.idle.append(self.allocator, transport);
    }

    /// Permanently discard a checked-out connection after a transport-level
    /// failure. The caller deinitializes the transport before calling this.
    pub fn noteDiscarded(self: *Pool) void {
        std.debug.assert(self.created > 0);
        self.created -= 1;
    }

    pub fn idleCount(self: Pool) usize {
        return self.idle.items.len;
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
