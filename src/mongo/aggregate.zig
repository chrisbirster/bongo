const std = @import("std");
const bson = @import("../bson.zig");
const command_cursor = @import("command_cursor.zig");
const op_msg = @import("op_msg.zig");
const read_concern = @import("read_concern.zig");

const Allocator = std.mem.Allocator;

pub const Cursor = command_cursor.Cursor;

/// Execute a heterogeneous tuple of aggregation stages.
pub fn aggregate(
    collection: anytype,
    pipeline: anytype,
) !Cursor {
    const client = collection.client;
    const request_id = command_cursor.takeRequestId(client);
    const request = try encodeAggregate(
        client.allocator,
        request_id,
        collection.database_name,
        collection.name,
        pipeline,
        client.read_concern,
    );
    defer client.allocator.free(request);

    const response = try client.connection.request(
        client.allocator,
        request,
    );

    return Cursor.init(
        client,
        response,
        request_id,
        collection.database_name,
        collection.name,
        "firstBatch",
    );
}

pub fn encodeAggregate(
    allocator: Allocator,
    request_id: i32,
    database_name: []const u8,
    collection_name: []const u8,
    pipeline: anytype,
    concern: ?read_concern.ReadConcern,
) ![]u8 {
    const pipeline_document = try encodePipeline(allocator, pipeline);
    defer allocator.free(pipeline_document);
    const empty_cursor = try bson.encode(allocator, .{});
    defer allocator.free(empty_cursor);

    var writer = try bson.Writer.init(allocator);
    errdefer writer.deinit();

    try writer.writeString("aggregate", collection_name);
    try writer.writeArray("pipeline", pipeline_document);
    try writer.writeDocument("cursor", empty_cursor);

    if (concern) |configured| {
        const document = try read_concern.encode(allocator, configured);
        defer allocator.free(document);
        try writer.writeDocument("readConcern", document);
    }

    try writer.writeString("$db", database_name);

    const body = try writer.finish();
    defer allocator.free(body);
    return op_msg.encodeBody(
        allocator,
        body,
        .{ .request_id = request_id },
    );
}

pub fn encodePipeline(
    allocator: Allocator,
    pipeline: anytype,
) ![]u8 {
    if (@typeInfo(@TypeOf(pipeline)) != .@"struct" or
        !@typeInfo(@TypeOf(pipeline)).@"struct".is_tuple)
    {
        @compileError("aggregate pipeline must be a tuple of stage documents");
    }

    var writer = try bson.Writer.init(allocator);
    errdefer writer.deinit();

    inline for (pipeline, 0..) |stage, index| {
        const stage_document = try bson.encode(allocator, stage);
        defer allocator.free(stage_document);

        var index_buffer: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&index_buffer, "{d}", .{index});
        try writer.writeDocument(name, stage_document);
    }

    return writer.finish();
}

test "aggregate encodes heterogeneous pipeline and cursor" {
    const allocator = std.testing.allocator;

    const request = try encodeAggregate(
        allocator,
        67,
        "test",
        "users",
        .{
            .{ .@"$match" = .{ .active = true } },
            .{ .@"$sort" = .{ .score = @as(i32, -1) } },
            .{ .@"$project" = .{ .name = @as(i32, 1) } },
        },
        null,
    );
    defer allocator.free(request);

    const body = try (try op_msg.decode(request)).body();
    const pipeline = (try bson.Reader.get(body, "pipeline")).?.array;
    const stage0 = (try bson.Reader.get(pipeline, "0")).?.document;
    const stage1 = (try bson.Reader.get(pipeline, "1")).?.document;

    try std.testing.expect((try bson.Reader.get(stage0, "$match")) != null);
    try std.testing.expect((try bson.Reader.get(stage1, "$sort")) != null);
    try std.testing.expect((try bson.Reader.get(body, "cursor")) != null);
}
