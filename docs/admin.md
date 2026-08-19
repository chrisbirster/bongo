# Collection, index, and database administration

Bongo exposes implemented MongoDB management commands as top-level helpers operating on `Client`, `Database`, or `Collection` handles.

## Collections

Create a collection:

```zig
const database = client.database("app");
try bongo.createCollection(database, "events", .{});
```

Collection options are flattened into MongoDB's `create` command, so supported BSON options can be supplied without Bongo hard-coding every server option.

List collections:

```zig
var collections = try bongo.listCollections(
    database,
    .{
        .filter = .{ .name = "events" },
        .nameOnly = true,
    },
);
defer collections.deinit();

while (try collections.next()) |document| {
    const name = (try bongo.bson.Reader.get(document, "name")).?.string;
    std.debug.print("{s}\n", .{name});
}
```

Rename and drop collections:

```zig
const events = database.collection("events");
try bongo.renameCollection(events, "archived_events", false);
try bongo.dropCollection(database.collection("archived_events"));
```

The rename boolean controls MongoDB's `dropTarget` option. `renameCollection` runs against `admin` internally using fully qualified namespaces. Dropping a collection is idempotent with current MongoDB behavior.

## Indexes

Create an index:

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

Drop indexes by name, key specification, or MongoDB's special all-droppable selector:

```zig
try bongo.dropIndex(users, "first_last_unique");
try bongo.dropIndex(users, "*");
```

Configured client write concern is included automatically, and server failures are returned as errors.

List indexes as raw BSON metadata:

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

`listIndexes()` uses the shared command cursor and automatically issues `getMore` if index metadata spans batches.

MongoDB references:

- <https://www.mongodb.com/docs/manual/reference/command/dropIndexes/>
- <https://www.mongodb.com/docs/manual/reference/command/listIndexes/>

## Databases

`listDatabases()` runs against MongoDB's `admin` database and returns an owned result containing raw database-information documents:

```zig
var databases = try bongo.listDatabases(
    &client,
    .{ .nameOnly = true },
);
defer databases.deinit();

while (try databases.next()) |document| {
    const name = (try bongo.bson.Reader.get(document, "name")).?.string;
    std.debug.print("{s}\n", .{name});
}
```

Options are flattened into the command, so MongoDB fields such as `filter`, `nameOnly`, `authorizedDatabases`, and `comment` can be supplied. Each document returned by `next()` borrows from the result's response buffer and remains valid until `ListDatabasesResult.deinit()`.

MongoDB command reference: <https://www.mongodb.com/docs/manual/reference/command/listDatabases/>

## What is not implemented yet

The remaining database-administration milestone in this group is:

- #35 — `dropDatabase`
