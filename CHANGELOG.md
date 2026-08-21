# Changelog

Bongo follows semantic versioning while the project is pre-1.0. Minor releases (`0.x.0`) represent coherent driver capability milestones; patch releases (`0.x.y`) are reserved for compatible fixes within a released milestone.

## 0.4.0 — 2026-08-20

Bongo 0.4.0 hardens the managed `RuntimeClient` for real application use on Zig 0.16, with safer failover, explicit connection ownership, concurrent-client synchronization, stronger handshake/error inspection, and a condition-based bounded pool wait queue.

### Added

- A one-command `make test` validation path that provisions and validates standalone, TLS, and replica-set MongoDB fixtures before running unit, specification, integration, runtime, and Deez-readiness gates.
- A MongoDB specification-test harness foundation with a dedicated `zig build spec-test` gate and explicit supported/deferred suite tracking.
- Public structured MongoDB error inspection through `MongoErrorStatus`, `MongoErrorLabel`, `inspectMongoError`, and `inspectMongoErrorBody`, including error codes, code names/messages, and standard retry/transaction labels.
- Richer initial handshake metadata and server capability parsing, including the Zig 0.16-compatible handshake path used by `RuntimeClient`.
- Explicit pool lifecycle/state accounting for total, idle, checked-out, and waiting connections.
- A Zig 0.16 `std.Io.Condition` wait queue for `RuntimeClient` checkouts when `max_pool_size` is exhausted.
- `RuntimeClient.requestShutdown()` to stop new work and wake blocked pool checkouts during shutdown.
- Checked client teardown through `deinitChecked()` so active cursors, transactions, and in-flight operations cannot silently outlive the client.

### Fixed

- Failed socket/TLS requests are discarded instead of being returned to the reusable transport pool.
- Pool check-in failure no longer allows double deinitialization/double accounting of a transport.
- Failover cleanup no longer deinitializes the same selected transport twice when writable-server discovery also fails.
- `RuntimeClient` now re-probes configured seeds when the remembered selected host becomes unreachable or its `hello` request fails.
- Exhausted cursors release their transport as soon as MongoDB reports `cursor_id == 0`, so a live cursor value does not unnecessarily monopolize a small pool.
- TLS/SCRAM/connect failure paths have regression coverage that verifies cleanup and successful reconnect behavior.
- Shared `RuntimeClient` state and pool accounting use Zig 0.16 `std.Io.Mutex` synchronization for concurrent callers.
- Pool shutdown wakes blocked waiters and transitions deterministically from ready to closing to closed.
- Initial pool population and later allocation failures preserve transport ownership/accounting invariants.

### Current limitations

- Full SDAM background monitoring and the complete MongoDB server-selection specification are still not implemented; `RuntimeClient` performs writable-server probing across configured/SRV seeds.
- The specification harness is infrastructure for progressively importing the official MongoDB test corpus; it does not yet claim full specification-suite coverage.
- Pool waiting is condition-based and wakes on capacity changes or shutdown; a separate wait-queue timeout option is not exposed because Zig 0.16 `std.Io.Condition` does not provide a native timed-wait primitive.
- Retryable reads/writes and the complete transaction retry/error-label behavior remain incomplete.
- Read preference is modeled, but managed routing still focuses on the writable server required by Deez.
- Zig 0.16 still does not expose the client-certificate/private-key TLS path needed for built-in mutual TLS and end-to-end `MONGODB-X509`.
- SCRAM-SHA-256 password preparation still supports printable ASCII rather than complete SASLprep coverage.
- Wire compression remains deferred; URI compressor options are parsed but `OP_COMPRESSED` is not enabled.

## 0.3.0 — 2026-08-19

Bongo's third application-facing release hardens connection setup and adds the managed runtime capabilities needed by Deez: URI/SRV configuration, verified TLS + SCRAM, writable-server selection, bounded pooling, sessions, and transactions.

### Added

- `mongodb://` connection-string parsing with owned structural results for credentials, multiple hosts, database names, query options, and IPv6-safe addresses.
- Typed URI option normalization with percent decoding, authentication/TLS/topology settings, timeout values, compressor preferences, and deterministic security/conflict validation.
- `mongodb+srv://` SRV/TXT discovery with parent-domain validation, TXT default merging, `srvServiceName`, `srvMaxHosts`, and implicit TLS configuration.
- Verified server-authenticated TLS on Zig 0.16 with CA-chain and host-name verification enabled by default.
- SCRAM-SHA-1 compatibility alongside the existing SCRAM-SHA-256 implementation, including SCRAM over TLS.
- Authentication handshake negotiation that prefers SCRAM-SHA-256, falls back to SCRAM-SHA-1, and resumes speculative SCRAM-SHA-256 authentication when the server accepts it.
- MONGODB-X509 authentication command and connection-configuration validation; end-to-end client-certificate transport remains unsupported on Zig 0.16.
- Configurable DNS/TCP connection-establishment, socket I/O, and whole-operation timeouts. Bongo works around Zig 0.16's unfinished POSIX `Io.Threaded` connect-timeout path with an `Io.Select` deadline race.
- Experimental URI-driven `RuntimeClient` for application code that needs SRV, TLS, managed authentication, writable-server probing, reusable transports, sessions, and transactions.
- Writable-server probing/selection across configured and SRV-discovered seeds.
- A bounded reusable transport pool in `RuntimeClient`.
- Logical sessions and transaction numbers.
- Pinned-connection transactions with `startTransaction`, `commitTransaction`, and `abortTransaction`, live-tested against a MongoDB replica set.
- Transaction operations required by Deez, including transactional `insertOne` plus scheduler-state `updateOne`.
- Query/update operator helpers for normal Zig syntax, including `lte`, `gte`, `in`, `set`, and `inc`.
- Canonical documentation of the Zig 0.16 networking/TLS compatibility boundary in `docs/zig-0.16-tls-gap.md`.
- Dedicated Zig 0.16 compile, TLS+SCRAM, and replica-set transaction CI gates.

### Current limitations

- The original `Client` remains the simpler single-server API. Managed topology, pooling, sessions, and transactions live in the experimental `RuntimeClient` while that API matures.
- `RuntimeClient` selects a writable server by probing configured/SRV seeds; full SDAM monitoring, background topology updates, and the complete MongoDB server-selection specification are not implemented yet.
- Read preference is modeled, but the managed client currently targets the writable server needed by Deez rather than implementing all read-preference routing modes.
- Retryable reads/writes and the complete transaction retry/error-label specification are not yet complete.
- Zig 0.16's standard TLS client does not expose the client-certificate/private-key path needed for built-in mutual TLS and end-to-end `MONGODB-X509`. Server-authenticated TLS + SCRAM is supported and live-tested.
- SCRAM-SHA-256 password preparation currently supports printable ASCII; complete SASLprep coverage remains unfinished.
- Wire compression is not enabled in v0.3. The URI layer recognizes compressor preferences for forward compatibility; MongoDB `OP_COMPRESSED` support remains deferred under BONGO-0046.

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
