# Bongo

A MongoDB driver for Zig, built from the wire protocol up.

Named after my cat, Bongo.

![Bongo](./assets/bongo.jpg)

> **Status:** experimental. Bongo has a stable low-level/single-server API plus an experimental URI-driven `RuntimeClient` for application work that needs TLS, SRV discovery, writable-server selection, pooling, sessions, and transactions. It is not yet a production-complete MongoDB driver.

## Quick start

```zig
const std = @import("std");
const bongo = @import("bongo");

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var client = try bongo.Client.connect(
        io,
        allocator,
        .{
            .username = "admin",
            .password = "secretpassword",
        },
    );
    defer client.deinit();

    const users = client
        .database("test")
        .collection("users");

    _ = try users.insertOne(.{
        .name = "Bongo",
        .active = true,
    });

    var cursor = try users.find(.{ .active = true });
    defer cursor.deinit();

    while (try cursor.next()) |document| {
        const name = (try bongo.bson.Reader.get(document, "name")).?.string;
        std.debug.print("{s}\n", .{name});
    }
}
```

`Collection.find()` returns a cursor. Bongo reads `firstBatch`, sends `getMore` as needed, and cleans up an unfinished server cursor with `killCursors`.

For URI/SRV/TLS/session/transaction-aware application code, use `bongo.RuntimeClient`:

```zig
var client = try bongo.RuntimeClient.connectUri(
    io,
    allocator,
    "mongodb://user:password@localhost:27017/app?authSource=admin",
    .{},
);
defer client.deinit();
```

## What works today

| Area | Current support |
| --- | --- |
| BSON | Encoding, decoding, validation, raw BSON values/documents |
| Wire protocol | OP_MSG encoding/decoding, request/response IDs |
| Connection | TCP plus verified server-authenticated TLS |
| Connection strings | `mongodb://`, typed options, `mongodb+srv://` SRV/TXT discovery |
| Authentication | SCRAM-SHA-256 and SCRAM-SHA-1; negotiated/speculative auth in the low-level API |
| Driver handles | `Client`, `Database`, `Collection`; experimental `RuntimeClient` |
| Reads | `find`, `findOne`, cursors, `countDocuments`, `estimatedDocumentCount`, `distinct` |
| Find options | projection, sort, skip, limit, collation, hint, comment, `maxTimeMS`, `let` |
| Writes | `insertOne`, `insertMany`, `updateOne`, `updateMany`, `replaceOne`, `deleteOne`, `deleteMany` |
| Atomic operations | `findOneAndUpdate`, `findOneAndReplace`, `findOneAndDelete` |
| Write features | upsert, ordered/unordered mixed `bulkWrite`, write concern |
| Query helpers | native Zig helpers for MongoDB operators such as `lte`, `gte`, `in`, `set`, and `inc` |
| Read configuration | read concern and read-preference modeling |
| Aggregation | multi-stage `aggregate` cursors and `explain` |
| Collections | create, list, rename, drop |
| Indexes | create, list, drop |
| Databases | list and drop |
| Commands | generic `runCommand` with owned raw BSON responses |
| Runtime topology | probes configured/SRV hosts and selects a writable server |
| Pooling | bounded reusable transport pool in `RuntimeClient` |
| Sessions | logical session IDs and transaction numbers |
| Transactions | pinned connection, `startTransaction`, commit, abort; live-tested on a replica set |
| Timeouts | connect, socket, and whole-operation timeout budgets |
| Testing | unit, normal MongoDB integration, TLS+SCRAM, and replica-set transaction gates |

## Important limitations

Bongo deliberately exposes unfinished boundaries instead of pretending to be a complete production driver.

- The original `Client` remains the simpler single-server API. Pooling/topology/session behavior lives in the newer `RuntimeClient` while that API matures.
- `RuntimeClient` currently selects a writable server by probing configured seeds; full SDAM monitoring, background topology updates, and the complete MongoDB server-selection specification are not implemented yet.
- Retryable reads/writes and the complete transaction retry/error-label specification are not yet complete.
- Read preference is modeled but the managed client currently targets the writable server needed by Deez rather than implementing all read-preference routing modes.
- Zig 0.16's standard TLS client cannot present a client certificate. Server-authenticated TLS + SCRAM is supported; built-in mutual TLS / end-to-end `MONGODB-X509` is not. See [Zig 0.16 TLS gap](docs/zig-0.16-tls-gap.md).
- Wire compression is not enabled yet.
- Typed BSON struct decoding is planned in #78.
- SCRAM-SHA-256 password preparation currently accepts printable ASCII passwords; full SASLprep support is still incomplete.

## Documentation

Start here:

- [Getting started](docs/getting-started.md) — connect, choose a collection, and understand ownership.
- [CRUD](docs/crud.md) — inserts, reads, updates, replacements, deletes, upserts, and bulk writes.
- [Querying](docs/querying.md) — filters, options, cursors, aggregation, explain, and concerns.
- [Connection strings](docs/connection-strings.md) — URI options and SRV configuration.
- [Zig 0.16 TLS gap](docs/zig-0.16-tls-gap.md) — the exact standard-library TLS boundary, what Deez needs, and what remains missing for mutual TLS/X.509.
- [Raw commands](docs/commands.md) — use `runCommand` safely when Bongo has no high-level wrapper yet.
- [Administration](docs/admin.md) — collection, index, and database management.
- [Architecture](docs/architecture.md) — how the public API reaches BSON, OP_MSG, and MongoDB.
- [Testing and quality](docs/testing.md) — Bongo Style expectations, negative-space testing, assertions, errors, and merge gates.
- [MongoDB cursors](docs/cursors.md) — `firstBatch`, `getMore`, cleanup, and document lifetimes.
- [SCRAM](docs/scram.md) — how SCRAM authentication works internally.
- [Bongo Style](docs/BONGO_STYLE.md) — engineering rules for correctness, safety, performance, and tests.
- [Roadmap](docs/ROADMAP.md) — where the project is now and what comes next.

## Local MongoDB

The normal integration suite expects the development MongoDB configuration started by:

```bash
bash ./scripts/start-db.sh
zig build test
zig build integration-test
```

The Deez-facing live gates are separate:

```bash
bash ./scripts/start-tls-db.sh
zig build tls-integration-test

bash ./scripts/start-replica-db.sh
zig build runtime-integration-test
```

## Why?

Bongo exists to learn MongoDB from first principles and grow that understanding into a real Zig driver. The goal is not merely to make commands work; the driver should make wire behavior, ownership, failure modes, and protocol boundaries understandable and deliberate.
