# Collection, index, and database administration

Bongo exposes MongoDB management commands as top-level helpers operating on `Client`, `Database`, or `Collection` handles.

## Collections

Create a collection:

```zig
const database = client.database("app");
try bongo.createCollection(database, "events", .{});
```

List collections as raw BSON metadata:

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

Collection options are flattened into MongoDB's command documents where the API accepts an options struct. `renameCollection` runs against `admin` internally using fully qualified namespaces. Dropping a collection is idempotent with current MongoDB behavior.

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

Drop indexes by name, key specification, or MongoDB's special all-droppable selector:

```zig
try bongo.dropIndex(users, "first_last_unique");
try bongo.dropIndex(users, "*");
```

List index metadata:

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

`listIndexes()` uses the shared command cursor and automatically issues `getMore` if metadata spans batches. Configured write concern is included by index commands that support it, and server failures are returned as errors.

MongoDB references:

- <https://www.mongodb.com/docs/manual/reference/command/dropIndexes/>
- <https://www.mongodb.com/docs/manual/reference/command/listIndexes/>

## Databases

List accessible databases:

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

`listDatabases()` runs against MongoDB's `admin` database. Options such as `filter`, `nameOnly`, `authorizedDatabases`, and `comment` are flattened into the command. Each document returned by `next()` borrows from `ListDatabasesResult` and remains valid until that result is deinitialized.

Drop a database through its `Database` handle:

```zig
const scratch = client.database("scratch");
try bongo.dropDatabase(scratch);
```

Bongo validates that the database name is non-empty, includes configured client write concern, validates the MongoDB response, and surfaces command/write-concern failures. Dropping a database removes the database and its collections/indexes; user-management behavior remains MongoDB server behavior rather than a Bongo abstraction.

MongoDB references:

- <https://www.mongodb.com/docs/manual/reference/command/listDatabases/>
- <https://www.mongodb.com/docs/manual/reference/command/dropDatabase/>

## Ownership summary

- `listCollections()` and `listIndexes()` return cursors whose documents borrow from the current cursor batch.
- `listDatabases()` returns an owned response whose documents borrow from that response until `deinit()`.
- create, rename, drop, and index mutation helpers do not return borrowed response data.
