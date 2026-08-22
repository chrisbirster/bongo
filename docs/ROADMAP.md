# Bongo Roadmap

Bongo uses `BONGO-NNNN` GitHub issues for focused implementation milestones. The issue list is the detailed source of truth; this file is the current high-level map.

For the longer dependency-ordered parity plan, see [DRIVER_PARITY_PLAN.md](DRIVER_PARITY_PLAN.md).

## Current position — v0.5.0

Bongo v0.5.0 is the first production-oriented **replica-set runtime** milestone.

The earlier releases established the layers underneath it:

- v0.1: authenticated CRUD and cursors;
- v0.2: concerns, query options, aggregation, administration, and raw commands;
- v0.3: URI/SRV, verified TLS + SCRAM, bounded pooling, sessions, and transactions;
- v0.4: runtime hardening, structured errors, standards-aware handshake metadata, synchronized state, explicit pool lifecycle/accounting, bounded checkout, and shutdown safety;
- v0.5: CMAP completion plus replica-set SDAM, read selection, and failover.

The v0.5 runtime now includes:

- CMAP-style pool generations and clear semantics;
- `minPoolSize`, `maxPoolSize`, `maxConnecting`, and `maxIdleTimeMS` behavior;
- bounded wait-queue checkout through the operation timeout budget;
- deterministic pool/connection monitoring events;
- deterministic managed-client shutdown that stops heartbeat work and wakes/ends pool activity;
- an owned SDAM topology model rather than borrowed one-shot hello data;
- replica-set member discovery from `hosts`, `passives`, `arbiters`, `primary`, and `me`;
- requested `replicaSet` name validation;
- dedicated periodic hello monitoring and smoothed RTT tracking;
- primary/write server selection with `serverSelectionTimeoutMS`;
- read modes `primary`, `primaryPreferred`, `secondary`, `secondaryPreferred`, and `nearest`;
- tag-set and max-staleness filtering in the replica-set selector;
- `localThresholdMS` latency-window filtering and deterministic selection among eligible servers;
- per-server read pools and OP_MSG `$readPreference` propagation for non-primary reads;
- primary-change pool clearing/reselection;
- real three-member stepdown/election testing without recreating `RuntimeClient`;
- concurrent shared-client selection stress coverage;
- macOS, Linux/Fly, Zig 0.16 CI, live MongoDB CI, and exact Deez-consumer validation.

## What v0.5 intentionally does not mean

Bongo does **not** claim complete MongoDB-driver parity.

The v0.5 supported deployment milestone is replica sets. These remain open:

- #64 sharded/mongos deployment support;
- #65 load-balanced mode;
- #66-#69 complete public/server sessions, cluster/operation time, and causal consistency;
- #70 retryable reads;
- #71 complete retryable writes;
- #74 transaction option/deployment-aware pinning completion;
- #75 transaction retry/error-label semantics;
- #95 operation cancellation;
- #44 built-in client-certificate mTLS / end-to-end MONGODB-X509;
- #46 OP_COMPRESSED/compressor negotiation;
- #77-#86 BSON ergonomics and typed decoding work.

The SDAM implementation uses dedicated periodic hello polling and proves the required replica-set behavior, but it does not yet claim every upstream SDAM monitoring detail.

## Immediate next sequence

### 1. Turn the spec harness into real upstream-fixture conformance

#96 remains deliberately open.

The current harness distinguishes:

- `supported` — Bongo-owned harness coverage for implemented areas;
- `local_bridge` — CMAP/SDAM tests that exercise public Bongo behavior but are not upstream fixture ingestion;
- `deferred` — unsupported areas.

Next, pin and execute a documented subset of the official MongoDB driver specification fixtures in CI, starting with CMAP and SDAM/server selection and then extending to retries/errors/transactions.

### 2. Finish the broad concurrency and capability contracts

- #54: document and stress the full public thread-safety/ownership model beyond the already-synchronized v0.5 RuntimeClient path.
- #56: finish the remaining capability/spec surface needed by later deployment modes and compression.
- #94: complete the richer error/write-error model needed by retries.
- #98: expand from today's Linux CI + manual macOS gate into a pinned MongoDB-version/platform compatibility matrix.

### 3. Reliability features

After the v0.5 CMAP/SDAM foundation:

1. #66-#69 complete sessions/causal consistency;
2. #70 retryable reads;
3. #71 complete retryable writes;
4. #74 transaction options/pinning;
5. #75 transaction retry/error-label semantics;
6. #95 cancellation.

### 4. Deployment extensions

- #64 sharded/mongos;
- #65 load-balanced mode.

These should build on the existing topology/selection abstractions rather than creating a second runtime path.

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

It runs unit tests, the specification harness, standalone integration, TLS+SCRAM, transactions, CMAP, three-member SDAM/failover, and Deez-facing readiness.

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

Future milestones should expand conformance and compatibility without weakening these gates.

## Engineering rule

Reaching a later issue number is not the goal. A milestone is complete only when its protocol behavior, ownership, errors, positive/negative tests, integration behavior, and documentation form a coherent supported boundary.

See [DRIVER_PARITY_PLAN.md](DRIVER_PARITY_PLAN.md), [BONGO_STYLE.md](BONGO_STYLE.md), and [testing.md](testing.md).
