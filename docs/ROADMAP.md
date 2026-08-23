# Bongo Roadmap

Bongo uses `BONGO-NNNN` GitHub issues for focused implementation milestones. The issue list is the detailed source of truth; this file is the current high-level map.

For the longer dependency-ordered parity plan, see [DRIVER_PARITY_PLAN.md](DRIVER_PARITY_PLAN.md).

## Current position — v0.6.0

Bongo v0.6.0 is the **replica-set reliability and conformance** milestone.

The release sequence now looks like this:

- v0.1: authenticated CRUD and cursors;
- v0.2: concerns, query options, aggregation, administration, and raw commands;
- v0.3: URI/SRV, verified TLS + SCRAM, bounded pooling, sessions, and transactions;
- v0.4: runtime hardening, structured errors, synchronized state, bounded checkout, and shutdown safety;
- v0.5: CMAP completion plus replica-set SDAM, read selection, and failover;
- v0.6: retryable reads/writes, transaction commit retry, upstream retry fixtures, malformed-wire stress, shutdown ownership stress, and a MongoDB/platform compatibility matrix.

The v0.6 runtime includes:

- all v0.5 replica-set CMAP/SDAM behavior;
- `retryReads` and `retryWrites` URI/runtime configuration;
- one retry of the initial `find` command on retryable read failures;
- one retry for replica-set `insertOne`, `updateOne`, `deleteOne`, and `findOneAndUpdate`;
- stable `(lsid, txnNumber)` reuse across a retryable write attempt;
- one retry of `commitTransaction` for `UnknownTransactionCommitResult`, with majority write concern on the retry;
- richer retry/read/write/write-concern error classification;
- pinned official MongoDB retryable-read and retryable-write fixtures in the spec harness;
- live `failCommand` integration coverage for retryable reads, writes, and transaction commit handling;
- deterministic malformed BSON/OP_MSG mutation coverage;
- secondary-cursor shutdown/ownership stress;
- automated macOS Zig 0.16 coverage and full Linux `make test` compatibility rows for MongoDB 7.0 and 8.0;
- macOS, Linux/Fly, Zig 0.16 CI, live MongoDB CI, and exact Deez-consumer validation.

## What v0.6 intentionally does not mean

Bongo does **not** claim complete MongoDB-driver parity.

The supported managed deployment milestone remains replica sets. These remain open or incremental:

- #64 sharded/mongos deployment support;
- #65 load-balanced mode;
- #66-#69 complete public/server sessions, cluster/operation time, and causal consistency;
- #74 remaining transaction option/deployment-aware pinning behavior;
- #75 remaining transaction convenience/body-retry semantics beyond commit retry;
- #95 operation cancellation;
- #44 built-in client-certificate mTLS / end-to-end MONGODB-X509;
- #46 OP_COMPRESSED/compressor negotiation;
- #77-#86 BSON ergonomics and typed decoding work.

Retryability in v0.6 is deliberately bounded: `getMore` is not retried, retryable writes are replica-set scoped, and the release does not claim sharded/load-balanced retry semantics.

The specification harness now consumes a pinned upstream subset for retryable reads/writes, but #96 remains incremental until broader official fixture ingestion exists. SDAM still uses dedicated periodic hello polling and does not claim every upstream monitoring detail.

## Immediate next sequence

### 1. Complete sessions and transaction ergonomics

- #66-#69: public/server sessions, cluster/operation time, and causal consistency.
- #74: remaining transaction option and deployment-aware pinning behavior.
- #75: transaction body retry/convenience semantics beyond the v0.6 commit retry path.

### 2. Continue official specification ingestion

#96 remains deliberately incremental. Extend the pinned fixture harness beyond retryable reads/writes into CMAP, SDAM/server selection, sessions, and transactions without claiming conformance that is not actually executed.

### 3. Finish broad concurrency/capability contracts

- #54: continue stress coverage of the public thread-safety and ownership model beyond the v0.6 shutdown/read-handle cases.
- #56: finish remaining handshake/capability surface needed by later deployment modes and compression.
- #94: continue structured error detail where future operations require it.
- #98: keep the MongoDB/platform compatibility matrix current as supported server versions change.

### 4. Deployment extensions

- #64 sharded/mongos;
- #65 load-balanced mode.

These should build on the existing topology, selection, pool, retry, and error abstractions rather than creating a second runtime path.

### 5. BSON/application ergonomics

#77-#86 cover ObjectId generation, typed decoding, naming controls, optionals/enums, arrays/dynamic documents, custom codecs, ownership/zero-copy APIs, Extended JSON, Decimal128, and UUID helpers.

### 6. Optional parity features

- #44 MONGODB-X509 via a client-certificate-capable TLS transport;
- #46 OP_COMPRESSED;
- #76 Stable API;
- #87-#88 change streams;
- #89-#91 GridFS;
- #92 command monitoring;
- #93 structured logging.

## Release and quality gates

The normal complete local gate is:

```bash
make test
```

It runs unit tests, the specification harness, standalone integration, TLS+SCRAM, transactions, CMAP, three-member SDAM/failover, retryability failpoint tests, malformed-wire stress, and Deez-facing readiness.

Linux/Fly-style validation remains required:

```bash
docker compose build --no-cache
docker compose up --abort-on-container-exit --exit-code-from bongo-linux-validation
```

A release candidate must also keep Deez green against the exact Bongo checkout:

```bash
zig build test --fork=../bongo
zig build mongo-integration-test --fork=../bongo
```

CI additionally validates the supported MongoDB 7.0/8.0 rows and macOS Zig 0.16 compile/spec/fuzz surface.

## Engineering rule

Reaching a later issue number is not the goal. A milestone is complete only when its protocol behavior, ownership, errors, positive/negative tests, integration behavior, and documentation form a coherent supported boundary.

See [DRIVER_PARITY_PLAN.md](DRIVER_PARITY_PLAN.md), [BONGO_STYLE.md](BONGO_STYLE.md), and [testing.md](testing.md).
