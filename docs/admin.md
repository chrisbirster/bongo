# Collection and index administration

Bongo exposes the MongoDB management commands that have been implemented so far as top-level driver helpers operating on `Database` or `Collection` handles.

## Create a collection

```zig
const database = client.database("app");

try bongo.createCollection(
    database,
    "events",
    .{},
);
```

Collection options are flattened into MongoDB's `create` command, so supported BSON options can be supplied without Bongo hard-coding every server option:

```zig
try bongo.createCollection(
    database,
    "events",
    .{
        .capped = true,
        .size = @as(i64, 1_048_576),
    },
);
```

Creating an already existing collection is surfaced as a MongoDB command failure.

## List collections

`listCollections()` returns a cursor of raw collection-information BSON documents:

```zig
var cursor = try bongo.listCollections(
    database,
    .{
        .filter = .{ .name = "events" },
        .nameOnly = true,
    },
);
defer cursor.deinit();

while (try cursor.next()) |document| {
    const name = (try bongo.bson.Reader.get(document, "name")).?.string;
    std.debug.print("{s}\n", .{name});
}
```

Bongo preserves the raw collection metadata rather than reducing the response to names only.

## Rename a collection

```zig
const events = database.collection("events");
try bongo.renameCollection(events, "archived_events", false);
```

The third argument controls MongoDB's `dropTarget` option.

MongoDB's `renameCollection` command runs against the `admin` database and uses fully qualified source/target namespaces internally; Bongo constructs those namespaces for the caller.

## Drop a collection

```zig
const events = database.collection("events");
try bongo.dropCollection(events);
```

Dropping a collection is idempotent with current MongoDB behavior: dropping a collection that does not exist is treated as success. Callers should not rely on a second drop producing an error.

## Create an index

```zig
const users = database.collection("users");

const result = try bongo.createIndex(
    users,
    .{
        .first = @as(i32, 1),
        .last = @as(i32, 1),
    },
    "first_last_unique",
    .{ .unique = true },
);
```

The key document may contain one or multiple fields. The caller supplies the index name. Index options are flattened into the index specification, allowing options such as `unique`, `sparse`, TTL, partial filters, collation, and hidden where accepted by the server.

`CreateIndexResult` exposes MongoDB's optional index-count metadata:

- `num_indexes_before`
- `num_indexes_after`
- `created_collection_automatically`

## What is not implemented yet

The management surface is intentionally incomplete at the current milestone:

- #32 — `dropIndex`
- #33 — `listIndexes`
- #34 — `listDatabases`
- #35 — `dropDatabase`

Those should be completed before this document describes a full collection/index/database administration API.
