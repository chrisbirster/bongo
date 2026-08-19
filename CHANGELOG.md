# Changelog

Bongo follows semantic versioning while the project is pre-1.0. Minor releases (`0.x.0`) represent coherent driver capability milestones; patch releases (`0.x.y`) are reserved for compatible fixes within a released milestone.

## 0.2.0 — 2026-08-18

Expands Bongo from core authenticated CRUD into a broader single-server MongoDB driver surface with query controls, concerns, aggregation, administration, and a generic command escape hatch.

### Added

- Client-level write concern with numeric or majority acknowledgement, optional journaling, and write timeout encoding.
- Client-level read concern across supported read operations.
- A validated read-preference model for future topology and server-selection work.
- `findWithOptions` with projection, sort, skip, limit, collation, hint, comment, `maxTimeMS`, and `let`.
- Aggregation pipelines with cursor-backed results.
- `explain` support for find operations.
- Collection administration: create, drop, list, and rename collections.
- Index administration: create, drop, and list indexes.
- Database administration: list and drop databases.
- Generic `runCommand` for commands that do not yet have a high-level Bongo wrapper.
- Reusable command-cursor and command-response infrastructure used across the expanded driver surface.
- Expanded getting-started, CRUD, querying, administration, architecture, command, and testing documentation.

### Improved

- Stronger malformed-response, boundary, command-failure, and generic-API test coverage.
- Bulk-write runtime behavior on Zig 0.16.
- Clearer ownership, cursor lifetime, and single-server limitation documentation.

### Current limitations

- One TCP connection per client; no connection pool yet.
- No `mongodb://` URI parser yet.
- No TLS yet.
- Read preference is modeled but not yet used for multi-server selection.
- No topology discovery, replica-set selection, sessions, retryable operations, or transactions yet.
- Socket/connect and whole-operation timeouts are not yet implemented.

## 0.1.0 — 2026-08-18

Bongo's first usable application-facing MongoDB driver release.

### Added

- SCRAM-SHA-256 authentication for a single MongoDB server.
- `Client`, `Database`, and `Collection` handles for normal application code.
- Stateful MongoDB cursors with `getMore`, explicit close, and best-effort `killCursors` cleanup.
- Core CRUD: `insertOne`, `insertMany`, `find`, `findOne`, `updateOne`, `updateMany`, `replaceOne`, `deleteOne`, and `deleteMany`.
- Atomic `findOneAndUpdate`, `findOneAndReplace`, and `findOneAndDelete` operations.
- `countDocuments`, `estimatedDocumentCount`, and `distinct`.
- Mixed ordered/unordered `bulkWrite` support.
- Upsert support for update and replacement operations.
- Unit and real-MongoDB integration coverage for the public driver surface.

### Current limitations

- One TCP connection per client; no connection pool yet.
- No `mongodb://` URI parser yet.
- No TLS yet.
- No topology discovery, replica-set selection, sessions, or transactions yet.
- Query options, concerns, aggregation, administration helpers, and `runCommand` are planned for later minor releases.
