const std = @import("std");
pub const bson = @import("bson.zig");

pub const mongo = struct {
    pub const op_msg = @import("mongo/op_msg.zig");
    pub const Connection =
        @import("mongo/connection.zig").Connection;
};

test {
    _ = @import("bson.zig");
    _ = @import("mongo/op_msg.zig");
    _ = @import("mongo/connection.zig");
    _ = @import("mongo/scram.zig");
    _ = @import("mongo/scram_final.zig");
    _ = @import("mongo/scram_server.zig");
}
