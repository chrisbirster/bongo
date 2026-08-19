# CRUD

Bongo exposes CRUD operations from a `Collection` handle:

```zig
const users = client.database("test").collection("users");
```

The examples below use anonymous Zig structs as BSON documents and filters.

## Insert

### `insertOne`

```zig
const result = try users.insertOne(.{
    ._id = "bongo",
    .name = "Bongo",
    .score = @as(i32, 1),
});

std.debug.assert(result.inserted_count == 1);
```

### `insertMany`

The documents in one call must have one Zig element type.

```zig
const User = struct {
    name: []const u8,
    score: i32,
};

const documents = [_]User{
    .{ .name = "Bongo", .score = 1 },
    .{ .name = "Mango", .score = 2 },
};

const result = try users.insertMany(&documents);
std.debug.assert(result.inserted_count == 2);
```

## Find

### `find`

```zig
var cursor = try users.find(.{ .score = @as(i32, 1) });
defer cursor.deinit();

while (try cursor.next()) |document| {
    // document is a borrowed raw BSON document.
}
```

Bongo automatically follows the server cursor with `getMore` when the current batch is exhausted. See [cursors.md](cursors.md) for lifetime and cleanup rules.

### `findOne`

```zig
var document = (try users.findOne(.{ ._id = "bongo" })) orelse {
    return error.NotFound;
};
defer document.deinit();
```

`findOne()` returns `null` when no document matches. A returned document owns its copied BSON bytes and remains valid until `deinit()`.

## Update

MongoDB update operators can be represented with quoted Zig field names:

```zig
var result = try users.updateOne(
    .{ ._id = "bongo" },
    .{ .@"$set" = .{ .score = @as(i32, 2) } },
);
defer result.deinit();

std.debug.assert(result.matched_count == 1);
std.debug.assert(result.modified_count == 1);
```

`updateMany()` has the same shape but applies the update to every matching document:

```zig
var result = try users.updateMany(
    .{ .active = true },
    .{ .@"$set" = .{ .reviewed = true } },
);
defer result.deinit();
```

## Upsert

Use the `WithOptions` variants when an update or replacement should insert a document if nothing matches:

```zig
var result = try users.updateOneWithOptions(
    .{ ._id = "missing" },
    .{ .@"$set" = .{ .name = "Bongo" } },
    .{ .upsert = true },
);
defer result.deinit();

std.debug.assert(result.matched_count == 0);
std.debug.assert(result.upserted_count == 1);
```

An upsert result can own the returned `_id`, so update/replace results should be deinitialized when you are finished with them.

## Replace

`replaceOne()` replaces the matching document rather than applying update operators:

```zig
var result = try users.replaceOne(
    .{ ._id = "bongo" },
    .{
        ._id = "bongo",
        .name = "Bongo",
        .score = @as(i32, 10),
    },
);
defer result.deinit();
```

Modifier-style replacement documents such as `{ "$set": ... }` are rejected with `error.InvalidReplacement`. Use `updateOne()` or `updateMany()` for update operators.

`replaceOneWithOptions(..., .{ .upsert = true })` enables replacement upserts.

## Delete

```zig
const one = try users.deleteOne(.{ ._id = "bongo" });
std.debug.assert(one.deleted_count <= 1);

const many = try users.deleteMany(.{ .temporary = true });
```

## Atomic find-and-modify operations

Bongo supports MongoDB's atomic `findAndModify` family:

```zig
var document = try users.findOneAndUpdate(
    .{ ._id = "bongo" },
    .{ .@"$set" = .{ .active = false } },
    .{ .return_document = .after },
);
if (document) |*owned| {
    defer owned.deinit();
}
```

The related operations are:

- `findOneAndUpdate`
- `findOneAndReplace`
- `findOneAndDelete`

They return an owned BSON document when a document matches, or `null` when nothing matches.

## Bulk writes

`bulkWrite()` accepts a heterogeneous Zig tuple of write models:

```zig
const result = try users.bulkWrite(
    .{
        .{ .insert_one = .{ .document = .{
            ._id = "a",
            .score = @as(i32, 1),
        } } },
        .{ .update_one = .{
            .filter = .{ ._id = "a" },
            .update = .{ .@"$set" = .{ .score = @as(i32, 2) } },
        } },
        .{ .delete_one = .{ .filter = .{ ._id = "a" } } },
    },
    .{ .ordered = true },
);
```

The result aggregates inserted, matched, modified, and deleted counts. Write failures are recorded with their first operation index.

With ordered execution, Bongo stops after the first write failure. With unordered execution, it records the error and continues through later models.

The current `bulkWrite()` implementation composes the existing collection write APIs. It is not yet a single server-side MongoDB 8.0 `bulkWrite` command.

## Write errors

MongoDB can return a command-level failure, a `writeErrors` array, or a `writeConcernError`. Bongo keeps those categories separate:

- command failures become `error.CommandFailed`;
- write failures become `error.WriteFailed`;
- write concern failures become `error.WriteConcernFailed`.

Malformed reply fields are also rejected rather than guessed.
