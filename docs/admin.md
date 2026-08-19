# Collection and index administration

Bongo exposes the MongoDB management commands implemented so far as top-level driver helpers operating on `Database` or `Collection` handles.

## Create a collection

```zig
const database = client.database("app");
try bongo.createCollection(database, "events", .{});
```

Collection options are flattened into MongoDB's `create` command, so supported BSON options can be supplied without Bongo hard-coding every server option.

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

## Rename and drop collections

```zig
const events = database.collection("events");
try bongo.renameCollection(events, "archived_events", false);
try bongo.dropCollection(database.collection("archived_events"));
```

The rename boolean controls MongoDB's `dropTarget` option. `renameCollection` runs against `admin` internally using fully qualified namespaces. Dropping a collection is idempotent with current MongoDB behavior.

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

The key document may contain one or multiple fields. Index options are flattened into the index specification. `CreateIndexResult` exposes MongoDB's optional before/after index counts and automatic-collection-creation flag.

## Drop indexes

```zig
try bongo.dropIndex(users, "first_last_unique");
try bongo.dropIndex(users, "*");
```

`dropIndex()` wraps MongoDB's `dropIndexes` command. The selector is BSON-encoded, so a name or key specification can be supplied. The special `"*"` selector asks MongoDB to remove all droppable non-`_id` indexes. Configured client write concern is included automatically, and server failures are returned as errors.

MongoDB command reference: <https://www.mongodb.com/docs/manual/reference/command/dropIndexes/>

## List indexes

`listIndexes()` returns a cursor of raw index-information BSON documents:

```zig
var indexes = try bongo.listIndexes(
    users,
    .{ .cursor = .{ .batchSize = @as(i32, 10) } },
);
defer indexes.deinit();

while (try indexes.next()) |document| {
    const name = (try bongo.bson.Reader.get(document, "name")).?.string;
    const key = (try bongo.bson.Reader.get(document, "key")).?.document;
    _ = key;
    std.debug.print("{s}\n", .{name});
}
```

The raw documents preserve MongoDB's key specification and index options. The command cursor automatically uses `getMore` when a batch is exhausted.

MongoDB command reference: <https://www.mongodb.com/docs/manual/reference/command/listIndexes/>

## What is not implemented yet

The remaining database-administration milestones in this group are:

- #34 — `listDatabases`
- #35 — `dropDatabase`
