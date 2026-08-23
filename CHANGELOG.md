# Changelog

Bongo follows semantic versioning while the project is pre-1.0. Minor releases (`0.x.0`) represent coherent driver capability milestones; patch releases (`0.x.y`) are reserved for compatible fixes within a released milestone.

## 0.6.0 — 2026-08-23

Bongo 0.6.0 is the replica-set reliability and conformance milestone. It adds bounded retry semantics, strengthens error and shutdown behavior, starts executing pinned official MongoDB retry fixtures, adds deterministic malformed-wire stress coverage, and turns platform/server validation into a repeatable compatibility matrix.

### Added

- `retryReads` and `retryWrites` URI/runtime options, enabled by default when the deployment supports them.
- One retry for the initial `find` command after retryable server or transport failures. Cursor `getMore` remains deliberately non-retryable.
- Replica-set retryable writes for `insertOne`, `updateOne`, `deleteOne`, and `findOneAndUpdate`.
- Stable `(lsid, txnNumber)` reuse across retryable write attempts so MongoDB can provide at-most-once write semantics.
- Transaction commit retry for `UnknownTransactionCommitResult`, with majority write concern on the retry.
- Richer retryable read/write, error-label, write-error, and write-concern classification.
- Pinned official MongoDB retryable-read and retryable-write fixtures in the spec harness.
- Live `failCommand` integration tests for retryable reads, retryable writes, and transaction commit handling.
- Secondary-read cursor shutdown/ownership stress coverage.
- Deterministic malformed BSON and OP_MSG mutation/truncation tests.
- A compatibility CI matrix that runs the full Linux suite against MongoDB 7.0 and 8.0 plus automated macOS Zig 0.16 unit/spec/fuzz/Deez-readiness validation.
- Retryability and malformed-wire gates in the normal `make test` sequence.

### Changed

- Local/CI MongoDB fixtures now default to pinned `mongo:8.0` instead of `mongo:latest`; `MONGO_IMAGE` remains overridable for compatibility testing.
- The normal Zig CI permanently runs unit, spec, fuzz, and Deez-readiness gates.
- Live SDAM CI now also executes the retryability failpoint suite.
- Package and handshake metadata now report Bongo `0.6.0`.

### Validated release gates

- macOS Apple Silicon with Homebrew Zig 0.16.0_1: full `make test` passed.
- Linux/Fly Docker validation passed.
- Deez passed both `zig build test --fork=../bongo` and `zig build mongo-integration-test --fork=../bongo` against the v0.6 candidate.
- GitHub Actions Zig 0.16 and live MongoDB gates passed during candidate validation; final release-candidate CI additionally includes the MongoDB 7.0/8.0 and macOS compatibility matrix.

### Current limitations

- v0.6 remains a replica-set runtime milestone; complete sharded/mongos support (#64) and load-balanced mode (#65) remain future work.
- Retryable writes are replica-set scoped and cover the four single-document write forms listed above; `getMore` is not retried.
- Transaction commit retry is implemented, but remaining transaction convenience/body-retry behavior under #74/#75 is still incremental.
- Complete public/server-session and causal-consistency behavior remains incomplete (#66-#69).
- The specification harness now ingests a pinned retryable-read/write subset but does not claim full official fixture-corpus conformance; #96 remains incremental.
- SDAM uses periodic hello polling and does not yet claim the complete upstream monitoring specification surface.
- Zig 0.16 still does not expose the client-certificate/private-key TLS path needed for built-in mutual TLS and end-to-end `MONGODB-X509`.
- SCRAM-SHA-256 password preparation still supports printable ASCII rather than complete SASLprep coverage.
- Wire compression remains deferred; URI compressor options are parsed but `OP_COMPRESSED` is not enabled.
- Typed BSON struct decoding and the broader BSON ergonomics roadmap remain future work.

## 0.5.0 — 2026-08-22

Bongo 0.5.0 is the first production-oriented replica-set `RuntimeClient` milestone. It completes the CMAP behavior needed by topology changes, adds owned SDAM discovery and monitoring, routes writes and reads through replica-set server selection, and proves real primary stepdown/re-election without recreating the client.

### Added

- CMAP-style pool monitoring events for pool open/close/clear, connection creation/readiness/close, checkout start/failure/success, and check-in.
- Pool sizing/lifecycle controls covering `minPoolSize`, `maxPoolSize`, `maxConnecting`, `maxIdleTimeMS`, generation clearing, stale-checkout rejection, and bounded saturated checkout.
- Deterministic managed shutdown that stops and joins heartbeat work, rejects new operations, closes read/write pools, and preserves active-handle checks.
- An owned SDAM topology model with standalone/replica-set/sharded/load-balanced topology states and per-server descriptions.
- Replica-set discovery from hello `hosts`, `passives`, `arbiters`, `primary`, and `me`, including requested set-name validation.
- Dedicated periodic hello monitoring with RTT measurement and smoothed RTT tracking.
- Primary/write selection with `serverSelectionTimeoutMS`.
- Read selection for `primary`, `primaryPreferred`, `secondary`, `secondaryPreferred`, and `nearest`, including tag sets, max-staleness filtering, and `localThresholdMS` latency windows.
- Per-server read pools so secondary reads do not repurpose the primary write pool.
- OP_MSG `$readPreference` propagation for selected non-primary reads.
- Real three-member replica-set integration coverage for discovery, secondary reads, concurrent shared-client selection, primary stepdown, replacement election, pool generation clearing, and resumed writes without recreating `RuntimeClient`.
- Expanded specification-harness reporting with explicit `supported`, `local_bridge`, and `deferred` dispositions for honest CMAP/SDAM coverage status.
- A complete `make test` sequence that includes CMAP, SDAM/failover, and Deez-facing readiness in addition to the existing unit/spec/standalone/TLS/transaction gates.

### Fixed

- `RuntimeClient` no longer treats a local `WaitQueueTimeout` as evidence that the selected primary is bad; saturated checkout failure does not spuriously clear the pool.
- Secondary reads now carry the required wire-level read-preference metadata instead of selecting a secondary and then sending a primary-style command.
- Read-pool teardown uses the mutable Zig 0.16 ArrayList lifecycle required by `deinit`.
- SDAM RTT timing matches Zig 0.16's `Timestamp.untilNow()` API.
- The real primary-stepdown test uses MongoDB's election-handoff path rather than a forced stepdown whose default election timeout could race the test deadline.

### Validated release gates

- macOS Apple Silicon with Homebrew Zig 0.16.0_1: full `make test` passed.
- Linux/Fly Docker validation passed.
- GitHub Actions Zig 0.16 passed.
- GitHub Actions live TLS/SCRAM, transactions/CMAP, and three-member SDAM passed.
- Deez `main` passed both `zig build test --fork=../bongo` and `zig build mongo-integration-test --fork=../bongo` against the exact v0.5 candidate.

### Current limitations

- v0.5 is a replica-set runtime milestone; complete sharded/mongos support (#64) and load-balanced mode (#65) remain future work.
- Full retryable reads/writes and complete transaction retry/error-label behavior remain incomplete (#70, #71, #75).
- Complete public/server-session and causal-consistency behavior remains incomplete (#66-#69).
- The specification harness includes local CMAP/SDAM bridge tests but does not yet ingest the full official MongoDB fixture corpus; #96 remains open.
- SDAM uses periodic hello polling and does not yet claim the complete upstream monitoring specification surface.
- Zig 0.16 still does not expose the client-certificate/private-key TLS path needed for built-in mutual TLS and end-to-end `MONGODB-X509`.
- SCRAM-SHA-256 password preparation still supports printable ASCII rather than complete SASLprep coverage.
- Wire compression remains deferred; URI compressor options are parsed but `OP_COMPRESSED` is not enabled.
- Typed BSON struct decoding and the broader BSON ergonomics roadmap remain future work.

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
