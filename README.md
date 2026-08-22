# Bongo

A MongoDB driver for Zig, built from the wire protocol up.

Named after my cat, Bongo.

![Bongo](./assets/bongo.jpg)

> **Status:** experimental. Bongo has a stable low-level/single-server API and a production-oriented replica-set `RuntimeClient` for Zig 0.16. The managed runtime now covers verified TLS + SCRAM, URI/SRV configuration, CMAP-style pooling, SDAM discovery/monitoring, primary and read-preference selection, sessions, and transactions. It is still not a production-complete MongoDB driver across every deployment type and specification feature.

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

    const users = client.database("test").collection("users");

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

For URI/SRV/TLS/pooling/topology/session-aware application code, use `bongo.RuntimeClient`:

```zig
var client = try bongo.RuntimeClient.connectUri(
    io,
    allocator,
    "mongodb://user:password@localhost:27017/app?authSource=admin",
    .{},
);
defer client.deinit();
```

For a replica set, Bongo can discover members from one seed, monitor them in the background, select the current primary for writes, and route reads according to supported read preferences:

```zig
var client = try bongo.RuntimeClient.connectUri(
    io,
    allocator,
    "mongodb://localhost:27017/app?replicaSet=rs0&readPreference=secondaryPreferred",
    .{},
);
defer client.deinit();

var cursor = try client.findWithReadPreference(
    "app",
    "cards",
    .{},
    .{ .limit = @as(i64, 10) },
    .{ .mode = .secondary_preferred },
);
defer cursor.deinit();
```

## What works today

| Area | Current support |
| --- | --- |
| BSON | Encoding, decoding, validation, raw BSON values/documents |
| Wire protocol | OP_MSG encoding/decoding, request/response IDs |
| Connection | TCP plus verified server-authenticated TLS |
| Connection strings | `mongodb://`, typed options, `mongodb+srv://` SRV/TXT discovery |
| Authentication | SCRAM-SHA-256 and SCRAM-SHA-1; negotiated/speculative auth |
| Driver handles | `Client`, `Database`, `Collection`, and managed `RuntimeClient` |
| Reads | `find`, `findOne`, cursors, `countDocuments`, `estimatedDocumentCount`, `distinct` |
| Find options | projection, sort, skip, limit, collation, hint, comment, `maxTimeMS`, `let` |
| Writes | `insertOne`, `insertMany`, `updateOne`, `updateMany`, `replaceOne`, `deleteOne`, `deleteMany` |
| Atomic operations | `findOneAndUpdate`, `findOneAndReplace`, `findOneAndDelete` |
| Write features | upsert, ordered/unordered mixed `bulkWrite`, write concern |
| Query helpers | Zig helpers for operators such as `lte`, `gte`, `in`, `set`, and `inc` |
| Read configuration | read concern plus primary/primaryPreferred/secondary/secondaryPreferred/nearest selection; tag and max-staleness filtering in the replica-set selector |
| Aggregation | multi-stage `aggregate` cursors and `explain` |
| Collections | create, list, rename, drop |
| Indexes | create, list, drop |
| Databases | list and drop |
| Commands | generic `runCommand` with owned raw BSON responses |
| Runtime topology | owned replica-set topology, member discovery, set-name validation, heartbeat polling, RTT tracking, primary changes |
| Server selection | primary/write selection, read-preference selection, `serverSelectionTimeoutMS`, `localThresholdMS` latency window |
| Pooling | bounded CMAP-style reusable pools with min/max sizing, `maxConnecting`, idle lifetime, checkout deadlines, generations/clear semantics, monitoring events |
| Sessions | logical session IDs and transaction numbers |
| Transactions | pinned connection, `startTransaction`, commit, abort; live-tested on a replica set |
| Shutdown | deterministic monitor stop/join, new-work rejection, pool close, active-handle checks |
| Timeouts | connect, socket, whole-operation, bounded pool checkout, and server-selection budgets |
| Testing | unit, spec harness, standalone integration, TLS+SCRAM, transactions, CMAP, three-member SDAM/failover, Deez readiness, Linux/Fly validation |

## Replica-set behavior in v0.5

The v0.5 runtime is designed so applications do not recreate the client when a primary changes.

1. `RuntimeClient` connects from configured or discovered seeds.
2. SDAM owns copied server descriptions instead of borrowing a one-shot hello buffer.
3. Dedicated monitor work sends periodic hello probes and tracks RTT.
4. Writes select the current primary.
5. Reads can select a primary or secondary according to the requested mode and latency window.
6. Non-primary OP_MSG reads carry `$readPreference` metadata on the wire.
7. When the primary changes, the affected application pool generation is cleared and the runtime selects the replacement primary.
8. New operations continue through the same `RuntimeClient`.

The repository includes a real three-member replica-set integration test that steps down the primary, waits for MongoDB to elect another member, and verifies that Bongo resumes writes without recreating the client.

## Important limitations

Bongo deliberately exposes unfinished boundaries instead of pretending to be a complete production driver.

- The original `Client` remains the simpler single-server API. Managed pooling, SDAM, sessions, and replica-set failover live in `RuntimeClient`.
- v0.5 is the replica-set runtime milestone. Full sharded/mongos deployment support (#64) and load-balanced mode (#65) are not complete.
- Retryable reads (#70) and complete retryable writes (#71) are not implemented yet.
- Complete public session/causal-consistency behavior (#66-#69) and full transaction retry/pinning semantics (#74-#75) remain incomplete.
- The specification harness reports supported/local-bridge/deferred areas honestly, but full upstream MongoDB fixture ingestion is still open under #96.
- SDAM currently uses periodic hello polling; it does not yet claim the complete upstream SDAM monitoring specification surface.
- Zig 0.16's standard TLS client cannot present a client certificate. Server-authenticated TLS + SCRAM is supported; built-in mutual TLS / end-to-end `MONGODB-X509` is not. See [Zig 0.16 TLS gap](docs/zig-0.16-tls-gap.md).
- Wire compression is not enabled yet (#46).
- Operation cancellation is not implemented yet (#95).
- Typed BSON struct decoding is planned in #78.
- SCRAM-SHA-256 password preparation currently accepts printable ASCII passwords; full SASLprep support is still incomplete.

## Documentation

Start here:

- [Getting started](docs/getting-started.md) — connect, choose a collection, and understand ownership.
- [CRUD](docs/crud.md) — inserts, reads, updates, replacements, deletes, upserts, and bulk writes.
- [Querying](docs/querying.md) — filters, options, cursors, aggregation, explain, and concerns.
- [Connection strings](docs/connection-strings.md) — URI options and SRV configuration.
- [Zig 0.16 TLS gap](docs/zig-0.16-tls-gap.md) — the exact standard-library TLS boundary and what remains missing for mutual TLS/X.509.
- [Raw commands](docs/commands.md) — use `runCommand` safely when Bongo has no high-level wrapper yet.
- [Administration](docs/admin.md) — collection, index, and database management.
- [Architecture](docs/architecture.md) — how the public API reaches BSON, OP_MSG, pooling, and MongoDB.
- [Testing and quality](docs/testing.md) — Bongo Style expectations, negative-space testing, assertions, errors, and merge gates.
- [MongoDB cursors](docs/cursors.md) — `firstBatch`, `getMore`, cleanup, and document lifetimes.
- [SCRAM](docs/scram.md) — how SCRAM authentication works internally.
- [Bongo Style](docs/BONGO_STYLE.md) — engineering rules for correctness, safety, performance, and tests.
- [Roadmap](docs/ROADMAP.md) — what shipped and what comes next.

## Testing

The normal local gate is intentionally one command:

```bash
make test
```

It provisions the required MongoDB fixtures and runs the complete sequence:

```text
unit
spec harness
standalone integration
TLS + SCRAM
runtime / transactions
CMAP
three-member SDAM / failover
Deez-facing readiness
```

Linux/Fly-style validation uses:

```bash
docker compose build --no-cache
docker compose up --abort-on-container-exit --exit-code-from bongo-linux-validation
```

For release candidates, Deez is also tested as an external consumer against the exact Bongo checkout:

```bash
zig build test --fork=../bongo
zig build mongo-integration-test --fork=../bongo
```

## Why?

Bongo exists to learn MongoDB from first principles and grow that understanding into a real Zig driver. The goal is not merely to make commands work; the driver should make wire behavior, ownership, failure modes, and protocol boundaries understandable and deliberate.
