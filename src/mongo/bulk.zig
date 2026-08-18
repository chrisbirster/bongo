const std = @import("std");

pub const Error = error{
    EmptyOperations,
    UnsupportedBulkOperation,
};

pub const Options = struct {
    ordered: bool = true,
};

pub const Result = struct {
    inserted_count: i64 = 0,
    matched_count: i64 = 0,
    modified_count: i64 = 0,
    deleted_count: i64 = 0,
    error_count: usize = 0,
    first_error_index: ?usize = null,
    first_error: ?anyerror = null,
    stopped_early: bool = false,
};

/// Execute a heterogeneous tuple of write models through one collection API.
///
/// Each tuple element must contain exactly one supported model field:
/// `insert_one`, `update_one`, `update_many`, `replace_one`, `delete_one`, or
/// `delete_many`.
pub fn execute(
    collection: anytype,
    operations: anytype,
    options: Options,
) !Result {
    const operation_count = @typeInfo(@TypeOf(operations)).@"struct".fields.len;
    if (operation_count == 0) return error.EmptyOperations;

    var result = Result{};

    inline for (operations, 0..) |operation, index| {
        const T = @TypeOf(operation);

        if (@hasField(T, "insert_one")) {
            const model = operation.insert_one;
            if (collection.insertOne(model.document)) |write_result| {
                result.inserted_count += write_result.inserted_count;
            } else |err| {
                if (!recordWriteError(&result, index, err)) return err;
                if (options.ordered) {
                    result.stopped_early = true;
                    return result;
                }
            }
        } else if (@hasField(T, "update_one")) {
            const model = operation.update_one;
            if (collection.updateOne(
                model.filter,
                model.update,
            )) |write_result| {
                result.matched_count += write_result.matched_count;
                result.modified_count += write_result.modified_count;
            } else |err| {
                if (!recordWriteError(&result, index, err)) return err;
                if (options.ordered) {
                    result.stopped_early = true;
                    return result;
                }
            }
        } else if (@hasField(T, "update_many")) {
            const model = operation.update_many;
            if (collection.updateMany(
                model.filter,
                model.update,
            )) |write_result| {
                result.matched_count += write_result.matched_count;
                result.modified_count += write_result.modified_count;
            } else |err| {
                if (!recordWriteError(&result, index, err)) return err;
                if (options.ordered) {
                    result.stopped_early = true;
                    return result;
                }
            }
        } else if (@hasField(T, "replace_one")) {
            const model = operation.replace_one;
            if (collection.replaceOne(
                model.filter,
                model.replacement,
            )) |write_result| {
                result.matched_count += write_result.matched_count;
                result.modified_count += write_result.modified_count;
            } else |err| {
                if (!recordWriteError(&result, index, err)) return err;
                if (options.ordered) {
                    result.stopped_early = true;
                    return result;
                }
            }
        } else if (@hasField(T, "delete_one")) {
            const model = operation.delete_one;
            if (collection.deleteOne(model.filter)) |write_result| {
                result.deleted_count += write_result.deleted_count;
            } else |err| {
                if (!recordWriteError(&result, index, err)) return err;
                if (options.ordered) {
                    result.stopped_early = true;
                    return result;
                }
            }
        } else if (@hasField(T, "delete_many")) {
            const model = operation.delete_many;
            if (collection.deleteMany(model.filter)) |write_result| {
                result.deleted_count += write_result.deleted_count;
            } else |err| {
                if (!recordWriteError(&result, index, err)) return err;
                if (options.ordered) {
                    result.stopped_early = true;
                    return result;
                }
            }
        } else {
            return error.UnsupportedBulkOperation;
        }
    }

    return result;
}

fn recordWriteError(
    result: *Result,
    index: usize,
    err: anyerror,
) bool {
    if (!isWriteError(err)) return false;

    result.error_count += 1;
    if (result.first_error_index == null) {
        result.first_error_index = index;
        result.first_error = err;
    }
    return true;
}

fn isWriteError(err: anyerror) bool {
    return err == error.WriteFailed or err == error.WriteConcernFailed;
}

test "bulk result records first write error" {
    var result = Result{};

    try std.testing.expect(recordWriteError(
        &result,
        2,
        error.WriteFailed,
    ));
    try std.testing.expect(recordWriteError(
        &result,
        4,
        error.WriteConcernFailed,
    ));

    try std.testing.expectEqual(@as(usize, 2), result.error_count);
    try std.testing.expectEqual(@as(?usize, 2), result.first_error_index);
    try std.testing.expect(result.first_error.? == error.WriteFailed);
}

test "bulk result does not classify protocol errors as write errors" {
    var result = Result{};

    try std.testing.expect(!recordWriteError(
        &result,
        0,
        error.CommandFailed,
    ));
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
}

test "unordered bulk execution continues after a runtime write error" {
    const FakeCollection = struct {
        const InsertResult = struct {
            inserted_count: i64,
        };

        calls: usize = 0,

        pub fn insertOne(
            self: *@This(),
            document: anytype,
        ) !InsertResult {
            _ = document;
            self.calls += 1;
            if (self.calls == 1) return error.WriteFailed;
            return .{ .inserted_count = 1 };
        }
    };

    var collection = FakeCollection{};
    const result = try execute(
        &collection,
        .{
            .{ .insert_one = .{ .document = .{ .value = @as(i32, 1) } } },
            .{ .insert_one = .{ .document = .{ .value = @as(i32, 2) } } },
        },
        .{ .ordered = false },
    );

    try std.testing.expectEqual(@as(usize, 2), collection.calls);
    try std.testing.expectEqual(@as(i64, 1), result.inserted_count);
    try std.testing.expectEqual(@as(usize, 1), result.error_count);
    try std.testing.expectEqual(@as(?usize, 0), result.first_error_index);
    try std.testing.expect(!result.stopped_early);
}
