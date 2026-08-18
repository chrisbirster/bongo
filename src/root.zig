const std = @import("std");
pub const bson = @import("bson.zig");

pub const Client = @import("mongo/client.zig").Client;
pub const Database = @import("mongo/client.zig").Database;
pub const Collection = @import("mongo/client.zig").Collection;
pub const Cursor = @import("mongo/client.zig").Cursor;
pub const FindResult = @import("mongo/client.zig").FindResult;
pub const OwnedDocument = @import("mongo/client.zig").OwnedDocument;
pub const ReturnDocument = @import("mongo/client.zig").ReturnDocument;
pub const FindOneAndUpdateOptions = @import("mongo/client.zig").FindOneAndUpdateOptions;
pub const InsertOneResult = @import("mongo/crud.zig").InsertOneResult;
pub const InsertManyResult = @import("mongo/crud.zig").InsertManyResult;
pub const UpdateResult = @import("mongo/crud.zig").UpdateResult;
pub const DeleteResult = @import("mongo/crud.zig").DeleteResult;

pub const mongo = struct {
    pub const op_msg = @import("mongo/op_msg.zig");
    pub const Connection =
        @import("mongo/connection.zig").Connection;
    pub const authenticate =
        @import("mongo/auth.zig").authenticate;
    pub const Client = @import("mongo/client.zig").Client;
    pub const Database = @import("mongo/client.zig").Database;
    pub const Collection = @import("mongo/client.zig").Collection;
    pub const Cursor = @import("mongo/client.zig").Cursor;
    pub const FindResult = @import("mongo/client.zig").FindResult;
    pub const OwnedDocument = @import("mongo/client.zig").OwnedDocument;
    pub const ReturnDocument = @import("mongo/client.zig").ReturnDocument;
    pub const FindOneAndUpdateOptions = @import("mongo/client.zig").FindOneAndUpdateOptions;
    pub const InsertOneResult = @import("mongo/crud.zig").InsertOneResult;
    pub const InsertManyResult = @import("mongo/crud.zig").InsertManyResult;
    pub const UpdateResult = @import("mongo/crud.zig").UpdateResult;
    pub const DeleteResult = @import("mongo/crud.zig").DeleteResult;
};

test {
    _ = @import("bson.zig");
    _ = @import("mongo/op_msg.zig");
    _ = @import("mongo/connection.zig");
    _ = @import("mongo/scram.zig");
    _ = @import("mongo/scram_final.zig");
    _ = @import("mongo/scram_server.zig");
    _ = @import("mongo/sasl.zig");
    _ = @import("mongo/auth.zig");
    _ = @import("mongo/client.zig");
    _ = @import("mongo/crud.zig");
    _ = @import("mongo/replacement.zig");
    _ = @import("mongo/find_and_modify.zig");
}
