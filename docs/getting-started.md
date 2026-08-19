# Getting started

This guide is for using Bongo as an application-facing MongoDB driver. If you want to understand the wire implementation, start with [architecture.md](architecture.md), [cursors.md](cursors.md), and [scram.md](scram.md).

## 1. Start the development MongoDB server

Bongo's repository includes a Docker helper that starts an authentication-enabled MongoDB server on `127.0.0.1:27017`:

```bash
./scripts/start-db.sh
```

The development credentials used by the integration suite are:

```text
username:      admin
password:      secretpassword
auth database: admin
```

## 2. Connect

```zig
const std = @import("std");
const bongo = @import("bongo");

var client = try bongo.Client.connect(
    io,
    allocator,
    .{
        .username = "admin",
        .password = "secretpassword",
    },
);
defer client.deinit();
```

The current client connects directly to one MongoDB server. `host`, `port`, and `auth_database` can be overridden in `Client.Options`.

```zig
var client = try bongo.Client.connect(
    io,
    allocator,
    .{
        .host = "127.0.0.1",
        .port = 27017,
        .auth_database = "admin",
        .username = "admin",
        .password = "secretpassword",
    },
);
```

Bongo does not yet parse `mongodb://` connection strings and does not yet provide connection pooling or TLS.

## 3. Get a database and collection

`Database` and `Collection` are lightweight handles that borrow the `Client`.

```zig
const database = client.database("test");
const users = database.collection("users");
```

They do not open another socket and they do not own the client. A database or collection handle must not outlive its `Client`.

The common shape is:

```text
Client
  │
  └── Database
        │
        └── Collection
```

## 4. Insert a document

Bongo encodes ordinary Zig structs and anonymous struct literals as BSON documents.

```zig
const result = try users.insertOne(.{
    .name = "Bongo",
    .age = @as(i32, 7),
    .active = true,
});

std.debug.assert(result.inserted_count == 1);
```

## 5. Read documents

A normal `find()` returns a cursor:

```zig
var cursor = try users.find(.{ .active = true });
defer cursor.deinit();

while (try cursor.next()) |document| {
    const name = (try bongo.bson.Reader.get(document, "name")).?.string;
    std.debug.print("{s}\n", .{name});
}
```

The `document` slice returned by `Cursor.next()` is borrowed from the cursor's current MongoDB response buffer. It is valid only until the next call to `next()`, `close()`, or `deinit()`.

If you need one document with an independent lifetime, use `findOne()`:

```zig
var document = (try users.findOne(.{ .name = "Bongo" })) orelse {
    return error.NotFound;
};
defer document.deinit();

const name = (try bongo.bson.Reader.get(document.bytes, "name")).?.string;
```

`findOne()` returns an `OwnedDocument`, so its bytes remain valid until `deinit()`.

## 6. Update and delete

```zig
var updated = try users.updateOne(
    .{ .name = "Bongo" },
    .{ .@"$set" = .{ .active = false } },
);
defer updated.deinit();

const deleted = try users.deleteOne(.{ .name = "Bongo" });
```

Update results include matched, modified, and upsert information. Delete results expose `deleted_count`.

See [crud.md](crud.md) for the complete CRUD surface.

## 7. Configure concerns

Read and write concerns can be configured when the client connects:

```zig
var client = try bongo.Client.connect(
    io,
    allocator,
    .{
        .username = "admin",
        .password = "secretpassword",
        .read_concern = .{ .level = .local },
        .write_concern = .{
            .w = .majority,
            .journal = true,
            .wtimeout_ms = 1000,
        },
    },
);
```

Read preference is currently a validated configuration model for later topology/server-selection work. It does not yet route reads to replica-set secondaries.

## Errors

Bongo uses errors for runtime failures caused by callers, MongoDB, the network, or malformed wire data. A remote server should not be able to trigger a Bongo assertion.

Examples of expected runtime errors include:

- invalid or empty operation input;
- malformed BSON or OP_MSG replies;
- mismatched response IDs;
- MongoDB command failures;
- write errors and write-concern errors;
- authentication failures;
- network failures.

Assertions are reserved for internal programmer invariants. See [BONGO_STYLE.md](BONGO_STYLE.md) and [testing.md](testing.md).

## Next

- Learn the complete CRUD surface in [crud.md](crud.md).
- Learn find options and aggregation in [querying.md](querying.md).
- Learn cursor lifetime rules in [cursors.md](cursors.md).
- See the current driver boundary in [ROADMAP.md](ROADMAP.md).
