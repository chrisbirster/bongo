# Bongo

A MongoDB driver for Zig, built from the wire protocol up.

Named after my cat, Bongo.

![Bongo](./assets/bongo.jpg)

> **Status:** experimental. Bongo already has a useful single-server driver API, but it is not production-ready yet. Connection pooling, TLS, URI parsing, full topology/server selection, sessions, transactions, and several compatibility features are still on the roadmap.

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

## What works today

| Area | Current support |
| --- | --- |
| BSON | Encoding, decoding, validation, raw BSON values/documents |
| Wire protocol | OP_MSG encoding/decoding, request/response IDs |
| Connection | TCP connection to one MongoDB server |
| Authentication | SCRAM-SHA-256 |
| Driver handles | `Client`, `Database`, `Collection` |
| Reads | `find`, `findOne`, cursors, `countDocuments`, `estimatedDocumentCount`, `distinct` |
| Find options | projection, sort, skip, limit, collation, hint, comment, `maxTimeMS`, `let` |
| Writes | `insertOne`, `insertMany`, `updateOne`, `updateMany`, `replaceOne`, `deleteOne`, `deleteMany` |
| Atomic operations | `findOneAndUpdate`, `findOneAndReplace`, `findOneAndDelete` |
| Write features | upsert, ordered/unordered mixed `bulkWrite`, write concern |
| Read configuration | read concern and read-preference modeling |
| Aggregation | multi-stage `aggregate` cursors and `explain` |
| Collections | create, list, rename, drop |
| Indexes | create, list, drop |
| Databases | list and drop |
| Testing | unit tests plus integration tests against a real MongoDB server |

## Important limitations

Bongo deliberately exposes unfinished boundaries instead of pretending to be a complete production driver.

- A `Client` currently owns one TCP connection; connection pooling is planned in #49.
- Standard `mongodb://` URI parsing is planned in #39 and option validation in #40.
- TLS is planned in #42.
- The full standards-aware handshake, wire-version negotiation, and negotiated server limits are planned in #56.
- Read preference is modeled and validated, but replica-set/server selection is not implemented yet; that work is planned in #57 and #60.
- Sessions and transactions are not implemented yet.
- Typed BSON struct decoding is planned in #78.
- SCRAM-SHA-256 password preparation currently accepts printable ASCII passwords; full SASLprep support is still incomplete.

## Documentation

Start here:

- [Getting started](docs/getting-started.md) — connect, choose a collection, and understand ownership.
- [CRUD](docs/crud.md) — inserts, reads, updates, replacements, deletes, upserts, and bulk writes.
- [Querying](docs/querying.md) — filters, options, cursors, aggregation, explain, and concerns.
- [Administration](docs/admin.md) — collection, index, and database management.
- [Architecture](docs/architecture.md) — how the public API reaches BSON, OP_MSG, and MongoDB.
- [Testing and quality](docs/testing.md) — Bongo Style expectations, negative-space testing, assertions, errors, and merge gates.
- [MongoDB cursors](docs/cursors.md) — `firstBatch`, `getMore`, cleanup, and document lifetimes.
- [SCRAM](docs/scram.md) — how SCRAM-SHA-256 authentication works internally.
- [Bongo Style](docs/BONGO_STYLE.md) — engineering rules for correctness, safety, performance, and tests.
- [Roadmap](docs/ROADMAP.md) — where the project is now and what comes next.

## Local MongoDB

The integration suite expects the development MongoDB configuration started by:

```bash
./scripts/start-db.sh
```

Then run:

```bash
zig build test
zig build integration-test
```

## Why?

Bongo exists to learn MongoDB from first principles and grow that understanding into a real Zig driver. The goal is not merely to make commands work; the driver should make wire behavior, ownership, failure modes, and protocol boundaries understandable and deliberate.
