#!/usr/bin/env python3
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
SPEC_COMMIT = "92b3c0b9287bfba1b0ec4084300858d05c654f8c"


def replace_once(path: str, old: str, new: str) -> None:
    p = ROOT / path
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one anchor, found {count}: {old[:100]!r}")
    p.write_text(text.replace(old, new, 1))


def append_once(path: str, marker: str, addition: str) -> None:
    p = ROOT / path
    text = p.read_text()
    if addition.strip() in text:
        return
    if marker not in text:
        raise SystemExit(f"{path}: missing append marker {marker!r}")
    p.write_text(text.replace(marker, marker + addition, 1))


# ---------------------------------------------------------------------------
# Public/root compile surface.
# ---------------------------------------------------------------------------
replace_once(
    "src/root.zig",
    '    _ = @import("mongo/transaction.zig");\n    _ = @import("mongo/runtime_client.zig");',
    '    _ = @import("mongo/transaction.zig");\n    _ = @import("mongo/retryable_write.zig");\n    _ = @import("mongo/runtime_client.zig");',
)

# ---------------------------------------------------------------------------
# URI retryReads/retryWrites defaults and parsing.
# ---------------------------------------------------------------------------
replace_once(
    "src/mongo/uri_options.zig",
    '    timeout_ms: ?u64 = null,\n\n    // CMAP connection-pool controls.',
    '    timeout_ms: ?u64 = null,\n\n    // Retryable reads and writes are enabled by default by the MongoDB driver specs.\n    retry_reads: bool = true,\n    retry_writes: bool = true,\n\n    // CMAP connection-pool controls.',
)
replace_once(
    "src/mongo/uri_options.zig",
    '    timeout_ms: bool = false,\n    min_pool_size: bool = false,',
    '    timeout_ms: bool = false,\n    retry_reads: bool = false,\n    retry_writes: bool = false,\n    min_pool_size: bool = false,',
)
replace_once(
    "src/mongo/uri_options.zig",
    '        } else if (optionName(name, "timeoutMS")) {\n            try markSeen(&seen.timeout_ms);\n            result.timeout_ms = try parseU64Option(allocator, raw_option.value);\n        } else if (optionName(name, "minPoolSize")) {',
    '        } else if (optionName(name, "timeoutMS")) {\n            try markSeen(&seen.timeout_ms);\n            result.timeout_ms = try parseU64Option(allocator, raw_option.value);\n        } else if (optionName(name, "retryReads")) {\n            try markSeen(&seen.retry_reads);\n            result.retry_reads = try parseBooleanOption(allocator, raw_option.value);\n        } else if (optionName(name, "retryWrites")) {\n            try markSeen(&seen.retry_writes);\n            result.retry_writes = try parseBooleanOption(allocator, raw_option.value);\n        } else if (optionName(name, "minPoolSize")) {',
)
append_once(
    "src/mongo/uri_options.zig",
    '\n',
    '''\ntest "retryReads and retryWrites default true and parse explicitly" {\n    var defaults = try parse(std.testing.allocator, "mongodb://localhost/app");\n    defer defaults.deinit();\n    try std.testing.expect(defaults.retry_reads);\n    try std.testing.expect(defaults.retry_writes);\n\n    var disabled = try parse(\n        std.testing.allocator,\n        "mongodb://localhost/app?retryReads=false&retryWrites=false",\n    );\n    defer disabled.deinit();\n    try std.testing.expect(!disabled.retry_reads);\n    try std.testing.expect(!disabled.retry_writes);\n}\n''',
)

# ---------------------------------------------------------------------------
# Core RuntimeClient: structured retry errors + one-attempt helpers.
# ---------------------------------------------------------------------------
replace_once(
    "src/mongo/runtime_client_core.zig",
    'const command_response = @import("command_response.zig");\nconst Connection = @import("connection.zig").Connection;',
    'const command_response = @import("command_response.zig");\nconst error_response = @import("error_response.zig");\nconst Connection = @import("connection.zig").Connection;',
)
replace_once(
    "src/mongo/runtime_client_core.zig",
    'const pool_wait = @import("pool_wait.zig");\nconst Pool = pool_mod.Pool;',
    'const pool_wait = @import("pool_wait.zig");\nconst retryable_write = @import("retryable_write.zig");\nconst Pool = pool_mod.Pool;',
)
replace_once(
    "src/mongo/runtime_client_core.zig",
    '    UnexpectedResponse,\n    CommandFailed,\n};',
    '    UnexpectedResponse,\n    CommandFailed,\n    RetryableRead,\n    RetryableWrite,\n};',
)

insert_anchor = '''    pub fn find(\n        self: *RuntimeClient,\n        database_name: []const u8,\n        collection_name: []const u8,\n        filter: anytype,\n        options: anytype,\n    ) !Cursor {'''
retry_methods = r'''    /// Execute one retryable insert attempt. The caller owns `session` and
    /// reuses it unchanged for any retry so MongoDB can enforce at-most-once
    /// behavior for the logical write.
    pub fn insertOneRetryableAttempt(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        document: anytype,
        session: *const session_mod.Session,
    ) !crud.InsertOneResult {
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
        const request_id = self.takeRequestId();
        const request = try retryable_write.encodeInsertOne(
            self.allocator,
            request_id,
            session,
            database_name,
            collection_name,
            document,
        );
        defer self.allocator.free(request);
        const response = self.requestCheckedOut(&transport, request) catch |err| {
            if (error_response.isRetryableTransportError(err)) return error.RetryableWrite;
            return err;
        };
        defer self.allocator.free(response);
        const status = try error_response.inspect(response, request_id);
        if (status.retryableWrite()) return error.RetryableWrite;
        if (!status.ok) return error.CommandFailed;
        return crud.parseInsertOneResponse(response, request_id);
    }

    pub fn updateOneRetryableAttempt(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        update: anytype,
        upsert: bool,
        session: *const session_mod.Session,
    ) !crud.UpdateResult {
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
        const request_id = self.takeRequestId();
        const request = try retryable_write.encodeUpdateOne(
            self.allocator,
            request_id,
            session,
            database_name,
            collection_name,
            filter,
            update,
            upsert,
        );
        defer self.allocator.free(request);
        const response = self.requestCheckedOut(&transport, request) catch |err| {
            if (error_response.isRetryableTransportError(err)) return error.RetryableWrite;
            return err;
        };
        defer self.allocator.free(response);
        const status = try error_response.inspect(response, request_id);
        if (status.retryableWrite()) return error.RetryableWrite;
        if (!status.ok) return error.CommandFailed;
        return crud.parseUpdateResponse(self.allocator, response, request_id);
    }

    pub fn deleteOneRetryableAttempt(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        session: *const session_mod.Session,
    ) !crud.DeleteResult {
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
        const request_id = self.takeRequestId();
        const request = try retryable_write.encodeDeleteOne(
            self.allocator,
            request_id,
            session,
            database_name,
            collection_name,
            filter,
        );
        defer self.allocator.free(request);
        const response = self.requestCheckedOut(&transport, request) catch |err| {
            if (error_response.isRetryableTransportError(err)) return error.RetryableWrite;
            return err;
        };
        defer self.allocator.free(response);
        const status = try error_response.inspect(response, request_id);
        if (status.retryableWrite()) return error.RetryableWrite;
        if (!status.ok) return error.CommandFailed;
        return crud.parseDeleteResponse(response, request_id);
    }

'''
replace_once(
    "src/mongo/runtime_client_core.zig",
    insert_anchor,
    retry_methods + insert_anchor,
)

find_and_modify_anchor = '''    pub fn createIndex(\n        self: *RuntimeClient,\n        database_name: []const u8,'''
find_and_modify_retry = r'''    pub fn findOneAndUpdateRetryableAttempt(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        update: anytype,
        upsert: bool,
        session: *const session_mod.Session,
    ) !?OwnedDocument {
        try self.beginOperation();
        defer self.endOperation();
        try validateNamespace(database_name, collection_name);
        var transport: ?PoolHandle = try self.checkout();
        defer self.releaseTransport(&transport);
        const request_id = self.takeRequestId();
        const request = try retryable_write.encodeFindOneAndUpdate(
            self.allocator,
            request_id,
            session,
            database_name,
            collection_name,
            filter,
            update,
            upsert,
        );
        defer self.allocator.free(request);
        const response = self.requestCheckedOut(&transport, request) catch |err| {
            if (error_response.isRetryableTransportError(err)) return error.RetryableWrite;
            return err;
        };
        defer self.allocator.free(response);
        const status = try error_response.inspect(response, request_id);
        if (status.retryableWrite()) return error.RetryableWrite;
        if (!status.ok) return error.CommandFailed;
        const bytes = (try find_and_modify.parseDocumentResponse(
            self.allocator,
            response,
            request_id,
        )) orelse return null;
        return .{ .allocator = self.allocator, .bytes = bytes };
    }

'''
replace_once(
    "src/mongo/runtime_client_core.zig",
    find_and_modify_anchor,
    find_and_modify_retry + find_and_modify_anchor,
)

replace_once(
    "src/mongo/runtime_client_core.zig",
    '''    const body = try message.body();\n    const ok = (try bson.Reader.get(body, "ok")) orelse return error.CommandFailed;\n    if (!commandSucceeded(ok)) return error.CommandFailed;\n    const cursor_value = (try bson.Reader.get(body, "cursor")) orelse''',
    '''    const body = try message.body();\n    const status = try error_response.inspectBody(body);\n    if (!status.ok) {\n        if (status.retryableRead()) return error.RetryableRead;\n        return error.CommandFailed;\n    }\n    const cursor_value = (try bson.Reader.get(body, "cursor")) orelse''',
)

# Commit retry: preserve unknown outcome, retry once with same session/txnNumber,
# and never send abort from deinit after an ambiguous commit result.
replace_once(
    "src/mongo/runtime_client_core.zig",
    '    session: session_mod.Session,\n    finished: bool = false,',
    '    session: session_mod.Session,\n    finished: bool = false,\n    commit_unknown: bool = false,',
)
old_commit = r'''    pub fn commit(self: *Transaction) !void {
        const transport = if (self.transport) |*owned| &owned.transport else
            return error.InvalidTransactionState;
        var transport_failed = false;
        transaction_ops.commit(
            transport,
            self.client.allocator,
            &self.session,
            self.client.takeRequestId(),
            &transport_failed,
        ) catch |err| {
            if (transport_failed) self.client.discardTransport(&self.transport);
            return err;
        };
        self.finished = true;
        self.release();
    }
'''
new_commit = r'''    pub fn commit(self: *Transaction) !void {
        var retried = false;
        while (true) {
            if (self.transport == null) {
                self.client.pool.clear() catch {};
                self.client.pool.ready() catch {};
                self.transport = self.client.checkout() catch {
                    self.commit_unknown = true;
                    return error.UnknownTransactionCommitResult;
                };
            }
            const transport = &self.transport.?.transport;
            var transport_failed = false;
            transaction_ops.commit(
                transport,
                self.client.allocator,
                &self.session,
                self.client.takeRequestId(),
                &transport_failed,
            ) catch |err| {
                if (transport_failed) self.client.discardTransport(&self.transport);
                if (err == error.UnknownTransactionCommitResult and !retried) {
                    retried = true;
                    // A retried commit uses majority write concern regardless
                    // of the original transaction write concern.
                    self.session.transaction_options.majority_write_concern = true;
                    continue;
                }
                if (err == error.UnknownTransactionCommitResult) self.commit_unknown = true;
                return err;
            };
            self.finished = true;
            self.commit_unknown = false;
            self.release();
            return;
        }
    }
'''
replace_once("src/mongo/runtime_client_core.zig", old_commit, new_commit)
replace_once(
    "src/mongo/runtime_client_core.zig",
    '        if (!self.finished and self.transport != null) self.abort() catch {};',
    '        if (!self.finished and !self.commit_unknown and self.transport != null) self.abort() catch {};',
)

# ---------------------------------------------------------------------------
# Secondary read runtime: surface retryable initial read errors and allow pool
# invalidation. getMore is deliberately unchanged/non-retried.
# ---------------------------------------------------------------------------
replace_once(
    "src/mongo/runtime_read.zig",
    'const command_response = @import("command_response.zig");\nconst Connection = @import("connection.zig").Connection;',
    'const command_response = @import("command_response.zig");\nconst error_response = @import("error_response.zig");\nconst Connection = @import("connection.zig").Connection;',
)
replace_once(
    "src/mongo/runtime_read.zig",
    '    CommandFailed,\n    UnsupportedAuthMechanism,',
    '    CommandFailed,\n    RetryableRead,\n    UnsupportedAuthMechanism,',
)
replace_once(
    "src/mongo/runtime_read.zig",
    '    pub fn requestShutdown(self: *Runtime) void {\n        self.mutex.lockUncancelable(self.io);\n        self.closing = true;\n        for (self.pools.items) |server_pool| server_pool.pool.close();\n        self.mutex.unlock(self.io);\n    }',
    '    pub fn requestShutdown(self: *Runtime) void {\n        self.mutex.lockUncancelable(self.io);\n        self.closing = true;\n        for (self.pools.items) |server_pool| server_pool.pool.close();\n        self.mutex.unlock(self.io);\n    }\n\n    pub fn clearForRetry(self: *Runtime) void {\n        self.mutex.lockUncancelable(self.io);\n        defer self.mutex.unlock(self.io);\n        for (self.pools.items) |server_pool| {\n            server_pool.pool.clear() catch {};\n            server_pool.pool.ready() catch {};\n        }\n    }',
)
replace_once(
    "src/mongo/runtime_read.zig",
    '''    const body = try message.body();\n    const ok = (try bson.Reader.get(body, "ok")) orelse return error.CommandFailed;\n    if (!commandSucceeded(ok)) return error.CommandFailed;\n    const cursor_value = (try bson.Reader.get(body, "cursor")) orelse''',
    '''    const body = try message.body();\n    const status = try error_response.inspectBody(body);\n    if (!status.ok) {\n        if (status.retryableRead()) return error.RetryableRead;\n        return error.CommandFailed;\n    }\n    const cursor_value = (try bson.Reader.get(body, "cursor")) orelse''',
)

# ---------------------------------------------------------------------------
# Facade retry loops. One retry is used without CSOT. The same implicit
# Session is reused for both write attempts.
# ---------------------------------------------------------------------------
replace_once(
    "src/mongo/runtime_client.zig",
    'const std = @import("std");\nconst core_mod = @import("runtime_client_core.zig");',
    'const std = @import("std");\nconst core_mod = @import("runtime_client_core.zig");\nconst error_response = @import("error_response.zig");',
)
replace_once(
    "src/mongo/runtime_client.zig",
    '    max_connecting: ?usize = null,\n    max_idle_time_ms: ?u64 = null,',
    '    max_connecting: ?usize = null,\n    max_idle_time_ms: ?u64 = null,\n    retry_reads: ?bool = null,\n    retry_writes: ?bool = null,',
)
replace_once(
    "src/mongo/runtime_client.zig",
    '    selected_host: usize = 0,',
    '    selected_host: usize = 0,\n    retry_reads: bool = true,\n    retry_writes: bool = true,',
)
replace_once(
    "src/mongo/runtime_client.zig",
    '            .selected_host = core.selected_host,\n        };',
    '            .selected_host = core.selected_host,\n            .retry_reads = options.retry_reads orelse core.connection_options.retry_reads,\n            .retry_writes = options.retry_writes orelse core.connection_options.retry_writes,\n        };',
)

old_insert = r'''        try self.syncWriteTarget();
        return self.core.insertOne(database_name, collection_name, document) catch |err| {
            self.notePrimaryOperationFailure(err);
            return err;
        };
'''
new_insert = r'''        if (!self.canRetryWrites()) {
            try self.syncWriteTarget();
            return self.core.insertOne(database_name, collection_name, document) catch |err| {
                self.notePrimaryOperationFailure(err);
                return err;
            };
        }
        var session = session_mod.Session.init(self.io);
        _ = try session.nextTransactionNumber();
        var retried = false;
        while (true) {
            try self.syncWriteTarget();
            const result = self.core.insertOneRetryableAttempt(
                database_name,
                collection_name,
                document,
                &session,
            ) catch |err| {
                self.notePrimaryOperationFailure(err);
                if (err == error.RetryableWrite and !retried) {
                    retried = true;
                    continue;
                }
                return err;
            };
            return result;
        }
'''
replace_once("src/mongo/runtime_client.zig", old_insert, new_insert)

old_update = r'''        try self.syncWriteTarget();
        return self.core.updateOne(database_name, collection_name, filter, update, upsert) catch |err| {
            self.notePrimaryOperationFailure(err);
            return err;
        };
'''
new_update = r'''        if (!self.canRetryWrites()) {
            try self.syncWriteTarget();
            return self.core.updateOne(database_name, collection_name, filter, update, upsert) catch |err| {
                self.notePrimaryOperationFailure(err);
                return err;
            };
        }
        var session = session_mod.Session.init(self.io);
        _ = try session.nextTransactionNumber();
        var retried = false;
        while (true) {
            try self.syncWriteTarget();
            const result = self.core.updateOneRetryableAttempt(
                database_name,
                collection_name,
                filter,
                update,
                upsert,
                &session,
            ) catch |err| {
                self.notePrimaryOperationFailure(err);
                if (err == error.RetryableWrite and !retried) {
                    retried = true;
                    continue;
                }
                return err;
            };
            return result;
        }
'''
replace_once("src/mongo/runtime_client.zig", old_update, new_update)

old_delete = r'''        try self.syncWriteTarget();
        return self.core.deleteOne(database_name, collection_name, filter) catch |err| {
            self.notePrimaryOperationFailure(err);
            return err;
        };
'''
new_delete = r'''        if (!self.canRetryWrites()) {
            try self.syncWriteTarget();
            return self.core.deleteOne(database_name, collection_name, filter) catch |err| {
                self.notePrimaryOperationFailure(err);
                return err;
            };
        }
        var session = session_mod.Session.init(self.io);
        _ = try session.nextTransactionNumber();
        var retried = false;
        while (true) {
            try self.syncWriteTarget();
            const result = self.core.deleteOneRetryableAttempt(
                database_name,
                collection_name,
                filter,
                &session,
            ) catch |err| {
                self.notePrimaryOperationFailure(err);
                if (err == error.RetryableWrite and !retried) {
                    retried = true;
                    continue;
                }
                return err;
            };
            return result;
        }
'''
replace_once("src/mongo/runtime_client.zig", old_delete, new_delete)

old_find = r'''        try self.beginOperation();
        defer self.endOperation();

        var selected = try self.sdam_manager.selectRead(self.allocator, preference);
        defer selected.deinit();

        var primary = self.sdam_manager.selectWrite(self.allocator) catch null;
        defer if (primary) |*snapshot| snapshot.deinit();
        if (primary) |snapshot| {
            if (std.mem.eql(u8, snapshot.address, selected.address)) {
                try self.syncWriteTargetSnapshot(selected);
                return .{ .primary = try self.core.find(
                    database_name,
                    collection_name,
                    filter,
                    options,
                ) };
            }
        }

        return .{ .selected_read = try self.read_runtime.find(
            selected,
            database_name,
            collection_name,
            filter,
            options,
        ) };
'''
new_find = r'''        try self.beginOperation();
        defer self.endOperation();

        var retried = false;
        while (true) {
            const cursor = self.findAttempt(
                database_name,
                collection_name,
                filter,
                options,
                preference,
            ) catch |err| {
                if (!self.retry_reads or retried or !isRetryableReadFailure(err)) return err;
                retried = true;
                self.noteReadOperationFailure();
                continue;
            };
            return cursor;
        }
'''
replace_once("src/mongo/runtime_client.zig", old_find, new_find)

old_fam = r'''        try self.syncWriteTarget();
        return self.core.findOneAndUpdate(
            database_name,
            collection_name,
            filter,
            update,
            upsert,
        ) catch |err| {
            self.notePrimaryOperationFailure(err);
            return err;
        };
'''
new_fam = r'''        if (!self.canRetryWrites()) {
            try self.syncWriteTarget();
            return self.core.findOneAndUpdate(
                database_name,
                collection_name,
                filter,
                update,
                upsert,
            ) catch |err| {
                self.notePrimaryOperationFailure(err);
                return err;
            };
        }
        var session = session_mod.Session.init(self.io);
        _ = try session.nextTransactionNumber();
        var retried = false;
        while (true) {
            try self.syncWriteTarget();
            const result = self.core.findOneAndUpdateRetryableAttempt(
                database_name,
                collection_name,
                filter,
                update,
                upsert,
                &session,
            ) catch |err| {
                self.notePrimaryOperationFailure(err);
                if (err == error.RetryableWrite and !retried) {
                    retried = true;
                    continue;
                }
                return err;
            };
            return result;
        }
'''
replace_once("src/mongo/runtime_client.zig", old_fam, new_fam)

private_anchor = '    fn beginOperation(self: *RuntimeClient) Error!void {'
private_helpers = r'''    fn canRetryWrites(self: *RuntimeClient) bool {
        if (!self.retry_writes or !self.supports_sessions) return false;
        return switch (self.topologyType()) {
            .replica_set_no_primary, .replica_set_with_primary, .sharded, .load_balanced => true,
            .unknown, .single => false,
        };
    }

    fn findAttempt(
        self: *RuntimeClient,
        database_name: []const u8,
        collection_name: []const u8,
        filter: anytype,
        options: anytype,
        preference: ?read_preference.ReadPreference,
    ) !Cursor {
        var selected = try self.sdam_manager.selectRead(self.allocator, preference);
        defer selected.deinit();

        var primary = self.sdam_manager.selectWrite(self.allocator) catch null;
        defer if (primary) |*snapshot| snapshot.deinit();
        if (primary) |snapshot| {
            if (std.mem.eql(u8, snapshot.address, selected.address)) {
                try self.syncWriteTargetSnapshot(selected);
                return .{ .primary = try self.core.find(
                    database_name,
                    collection_name,
                    filter,
                    options,
                ) };
            }
        }

        return .{ .selected_read = try self.read_runtime.find(
            selected,
            database_name,
            collection_name,
            filter,
            options,
        ) };
    }

    fn noteReadOperationFailure(self: *RuntimeClient) void {
        self.core.pool.clear() catch {};
        self.read_runtime.clearForRetry();
        self.sdam_manager.scan() catch {};
        self.core.pool.ready() catch {};
    }

'''
replace_once("src/mongo/runtime_client.zig", private_anchor, private_helpers + private_anchor)
replace_once(
    "src/mongo/runtime_client.zig",
    '};\n',
    '};\n\nfn isRetryableReadFailure(err: anyerror) bool {\n    return err == error.RetryableRead or error_response.isRetryableTransportError(err);\n}\n',
)

# ---------------------------------------------------------------------------
# Transaction abort recognizes retry labels (commit labels already existed).
# ---------------------------------------------------------------------------
replace_once(
    "src/mongo/transaction.zig",
    '    UnknownTransactionCommitResult,\n};',
    '    UnknownTransactionCommitResult,\n    RetryableWrite,\n};',
)
replace_once(
    "src/mongo/transaction.zig",
    '    const status = try error_response.inspect(response, request_id);\n    if (!status.ok) return error.CommandFailed;\n    try session.markAborted();',
    '    const status = try error_response.inspect(response, request_id);\n    if (status.retryableWrite()) return error.RetryableWrite;\n    if (!status.ok) return error.CommandFailed;\n    try session.markAborted();',
)

# ---------------------------------------------------------------------------
# Pinned official fixtures. These files are not hand-edited; they are fetched
# from one immutable mongodb/specifications commit.
# ---------------------------------------------------------------------------
fixtures = {
    "test/spec-fixtures/retryable-reads/find-serverErrors.json":
        "source/retryable-reads/tests/unified/find-serverErrors.json",
    "test/spec-fixtures/retryable-writes/insertOne.json":
        "source/retryable-writes/tests/unified/insertOne.json",
}
for local, remote in fixtures.items():
    url = f"https://raw.githubusercontent.com/mongodb/specifications/{SPEC_COMMIT}/{remote}"
    data = urlopen(url, timeout=30).read()
    p = ROOT / local
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)

manifest = ROOT / "test/spec-fixtures/README.md"
manifest.write_text(f'''# Pinned MongoDB specification fixtures\n\nBongo v0.6.0 pins a deliberately small upstream-backed retry subset at MongoDB specifications commit:\n\n`{SPEC_COMMIT}`\n\nVendored unchanged:\n\n- `source/retryable-reads/tests/unified/find-serverErrors.json`\n- `source/retryable-writes/tests/unified/insertOne.json`\n\nThese fixtures are parsed by `test/spec.zig` and their supported failure cases are exercised by the live retryability integration gate. This is not a claim of full MongoDB specification-suite conformance.\n''')

# Spec harness verifies pinned real fixture content rather than only local labels.
replace_once(
    "test/spec.zig",
    'const bongo = @import("bongo");\n',
    'const bongo = @import("bongo");\n\nconst upstream_retryable_reads = @embedFile("spec-fixtures/retryable-reads/find-serverErrors.json");\nconst upstream_retryable_writes = @embedFile("spec-fixtures/retryable-writes/insertOne.json");\n',
)
append_once(
    "test/spec.zig",
    '\n',
    r'''\ntest "pinned upstream retryable read fixture is executable input" {\n    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, upstream_retryable_reads, .{});\n    defer parsed.deinit();\n    const root = parsed.value.object;\n    try std.testing.expectEqualStrings("find-serverErrors", root.get("description").?.string);\n    const tests = root.get("tests").?.array.items;\n    var found_shutdown = false;\n    var found_not_primary = false;\n    for (tests) |case| {\n        const description = case.object.get("description").?.string;\n        if (std.mem.indexOf(u8, description, "ShutdownInProgress") != null) found_shutdown = true;\n        if (std.mem.indexOf(u8, description, "NotWritablePrimary") != null) found_not_primary = true;\n    }\n    try std.testing.expect(found_shutdown);\n    try std.testing.expect(found_not_primary);\n}\n\ntest "pinned upstream retryable write fixture is executable input" {\n    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, upstream_retryable_writes, .{});\n    defer parsed.deinit();\n    const root = parsed.value.object;\n    try std.testing.expectEqualStrings("insertOne", root.get("description").?.string);\n    try std.testing.expect(root.get("tests").?.array.items.len > 0);\n}\n''',
)

print("v0.6 runtime/spec patch applied")
