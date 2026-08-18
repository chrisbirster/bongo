# MongoDB cursors

MongoDB does not necessarily return every matching document in the first response to `find`.

The initial response contains a `cursor` document:

```text
cursor
├── id
├── ns
└── firstBatch
```

If `id` is nonzero, MongoDB still owns server-side cursor state. Bongo keeps that id and fetches later documents with `getMore`:

```text
find
  │
  ▼
firstBatch + cursor id
  │
  ├── documents remain in batch → return next document
  │
  └── batch exhausted and id != 0
          │
          ▼
        getMore
          │
          ▼
     nextBatch + new id
```

Iteration ends when the current batch is empty and MongoDB has returned cursor id `0`.

## Application API

```zig
var cursor = try collection.find(.{ .active = true });
defer cursor.deinit();

while (try cursor.next()) |document| {
    // document is BSON
}
```

Applications do not construct `getMore` commands directly.

## Cleanup

Stopping before the server cursor reaches id `0` leaves cursor state on MongoDB. `Cursor.close()` sends:

```text
{
    killCursors: <collection>,
    cursors: [<cursor id>],
    $db: <database>
}
```

`Cursor.deinit()` performs this cleanup on a best-effort basis and always releases local memory. Call `close()` explicitly first when the caller needs to observe a `killCursors` error.

## Ownership

A `Cursor` owns:

- the current MongoDB wire response
- copies of the database, collection, and namespace names needed for later cursor commands
- the current server cursor id

Bongo frees the previous wire response when it advances to another batch. This keeps cursor memory bounded instead of retaining every batch until the query finishes.

A BSON document returned from `Cursor.next()` borrows from the current response buffer. Treat that document slice as valid only until the next call to `next()`, `close()`, or `deinit()`.

The `Cursor` itself borrows its `Client` and must not outlive that client.

## Wire commands

A later batch is requested with:

```text
{
    getMore: <cursor id>,
    collection: <collection>,
    $db: <database>
}
```

MongoDB responds with `cursor.nextBatch`. Bongo validates the command result, response id, cursor id, namespace, and batch before exposing documents to the caller.
