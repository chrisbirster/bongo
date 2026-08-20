# Bongo readiness for Deez

This is the product-level checklist for using Deez as Bongo's first demanding application.

## Required for the experimental MongoStore

- [x] BSON documents, arrays, binary values, ObjectId and numeric values
- [x] inserts, finds, updates, upserts and deletes
- [x] sort/limit query support
- [x] `findOneAndUpdate` for atomic counters
- [x] indexes
- [x] aggregation and `runCommand`
- [x] `mongodb://` parsing
- [x] `mongodb+srv://` SRV/TXT discovery
- [x] SCRAM-SHA-256 and SCRAM-SHA-1 protocol support
- [ ] server-authenticated TLS validated against real `mongod`
- [ ] SCRAM-SHA-256 validated over TLS
- [x] connect/socket/operation timeout configuration

## Required for first-class storage parity

- [ ] writable-primary server selection
- [ ] explicit client sessions
- [ ] logical server-session IDs (`lsid`)
- [ ] transaction start
- [ ] transaction commit/abort
- [ ] transaction concerns/options
- [ ] transaction retry semantics
- [ ] retryable reads
- [ ] retryable writes

Deez's review history is immutable source-of-truth data and scheduler state is rebuildable. That allows an experimental MongoStore before transactions are complete, but production parity requires transactions around review append + scheduler-state update.

## Performance and maturity

- [ ] bounded connection pool
- [ ] MongoDB specification-test harness for the implemented surfaces

## Ergonomics

Bongo should expose Zig-friendly query helpers instead of requiring callers to write escaped MongoDB keys everywhere:

```zig
const q = bongo.query;

var cursor = try cards.find(.{
    .deck_id = deck_id,
    .due_at_ms = q.lte(now_ms),
});
```

Helpers should include comparisons (`eq`, `ne`, `gt`, `gte`, `lt`, `lte`), membership (`in`, `nin`), existence, logical combinators, and common update operators.

## Explicit non-requirements for Deez

These should not block the Deez backend:

- wire compression;
- MONGODB-X509;
- client-certificate/mutual TLS;
- change streams;
- GridFS;
- SQLite/Mongo automatic synchronization;
- a generic SQL/Mongo query language.

The abstraction belongs in Deez above both databases: Deez defines persistence operations and each backend implements them idiomatically.
