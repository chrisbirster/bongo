# Architecture

Bongo is intentionally layered so the application-facing driver API does not need to know MongoDB wire details.

```text
Application
    │
    ▼
Client / Database / Collection
    │
    ├── CRUD and command modules
    │       │
    │       └── cursor / response parsing
    │
    ▼
OP_MSG
    │
    ▼
BSON
    │
    ▼
TCP connection
    │
    ▼
MongoDB
```

Authentication is performed when the client establishes its current connection:

```text
connect
   │
   ▼
TCP connection
   │
   ▼
SCRAM-SHA-256
   │
   ▼
authenticated Client
```

## Public handles

### `Client`

`Client` currently owns:

- the allocator used for driver-owned allocations;
- one authenticated MongoDB connection;
- the next application command request ID;
- configured read concern;
- configured write concern.

A future connection-pool milestone will change the one-connection architecture, but callers should continue to interact with the `Client` abstraction rather than with raw sockets.

### `Database`

A `Database` is a lightweight borrowed handle containing:

- `*Client`
- a database name slice

It does not allocate or open another connection.

### `Collection`

A `Collection` is a lightweight borrowed handle containing:

- `*Client`
- a database name slice
- a collection name slice

Most application operations are exposed through this handle.

## Command modules

Bongo keeps protocol-specific responsibilities in focused modules rather than building every command directly inside `Client`.

Examples include:

- `crud.zig` — insert/update/delete wire commands and write-result parsing;
- `replacement.zig` — replacement-document validation;
- `find_and_modify.zig` — atomic find-and-modify commands;
- `find_options.zig` — configurable find commands;
- `aggregate.zig` — aggregation command encoding;
- `explain.zig` — explain wrapper commands;
- `collection_admin.zig` — collection management;
- `index_admin.zig` — index management;
- `command_response.zig` — shared command-response validation;
- `command_cursor.zig` — reusable cursor parsing, `getMore`, and cleanup.

The goal is for `Client` and `Collection` to coordinate operations while wire-specific parsing stays close to the code that understands that wire shape.

## OP_MSG

MongoDB commands are encoded into OP_MSG messages. Each application command receives a positive request ID. Replies are checked against the expected `responseTo` value before their contents are trusted.

A response from MongoDB is external input. Incorrect IDs, missing fields, wrong BSON types, malformed batches, and failed command status must return errors rather than assertions.

## BSON

BSON is the serialization layer below commands. Bongo supports raw BSON documents and values so the driver can implement MongoDB protocol behavior before a full typed Zig decoding layer exists.

That leads to two important public ownership forms.

### Borrowed documents

Cursor iteration returns a raw BSON slice borrowed from the cursor's current response buffer:

```zig
const document = (try cursor.next()).?;
```

The slice is valid only until the cursor advances, closes, or deinitializes.

### Owned documents

Operations such as `findOne()` and `explainFind()` return an owned BSON document. The caller must deinitialize it:

```zig
var document = (try collection.findOne(filter)).?;
defer document.deinit();
```

The owned bytes remain valid until `deinit()`.

## Cursors

Cursor-returning commands keep only the current response batch in memory.

```text
firstBatch
    │
    ▼
next()
    │
    ├── more documents in current batch ──► return document
    │
    └── batch exhausted and cursor id != 0
                    │
                    ▼
                  getMore
                    │
                    ▼
                 nextBatch
```

The previous response buffer is freed when Bongo advances to a new batch. If iteration stops while MongoDB still owns a server cursor, cleanup sends `killCursors`.

See [cursors.md](cursors.md).

## Error boundary

Bongo Style draws a hard line between runtime input and programmer invariants:

```text
Can MongoDB, the network, or a caller cause it?
                 │
          ┌──────┴──────┐
         yes            no
          │              │
        error         assertion
```

Examples that must be errors:

- malformed BSON;
- malformed OP_MSG replies;
- mismatched response IDs;
- missing or incorrectly typed response fields;
- authentication rejection;
- MongoDB command/write failures;
- invalid caller input.

Assertions are for state that should be impossible after Bongo has already validated its inputs, such as an internal delete limit that must be exactly `0` or `1`, or fetching a new cursor batch only after establishing that the cursor is open and its ID is nonzero.

## Current deployment boundary

The current architecture is intentionally a single-server driver. Several production-driver responsibilities remain later milestones:

- client option/URI parsing;
- TLS;
- socket/connect timeouts;
- connection pooling;
- wire-version and server-limit negotiation;
- SDAM topology tracking;
- server selection and active read-preference routing;
- heartbeat monitoring and failover;
- sessions and transactions.

Those are not hidden limitations. The public docs should continue to distinguish an implemented configuration model from behavior that depends on future topology infrastructure.
