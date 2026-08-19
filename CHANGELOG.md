# Changelog

Bongo follows semantic versioning while the project is pre-1.0. Minor releases (`0.x.0`) represent coherent driver capability milestones; patch releases (`0.x.y`) are reserved for compatible fixes within a released milestone.

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
