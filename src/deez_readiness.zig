//! Compile root for Bongo features exercised by Deez.
//!
//! Keeping this at `src/` lets Zig enforce normal module boundaries while CI
//! eagerly analyzes feature modules that the legacy root API may not yet
//! instantiate.
const std = @import("std");

pub const query = @import("mongo/query.zig");
pub const session = @import("mongo/session.zig");
pub const pool = @import("mongo/pool.zig");
pub const topology = @import("mongo/topology.zig");
pub const transaction = @import("mongo/transaction.zig");
pub const runtime_client = @import("mongo/runtime_client.zig");
pub const tls_connection = @import("mongo/tls_connection.zig");
pub const transport = @import("mongo/transport.zig");
pub const auth_transport = @import("mongo/auth_transport.zig");

test {
    std.testing.refAllDecls(@This());
}
