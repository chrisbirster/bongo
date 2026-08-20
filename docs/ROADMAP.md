# Bongo Roadmap

Bongo uses `BONGO-NNNN` GitHub issues for focused implementation milestones. The issue list is the detailed source of truth; this file is the current high-level map.

For the dependency-ordered parity plan after v0.3.0, see [DRIVER_PARITY_PLAN.md](DRIVER_PARITY_PLAN.md).

## Current position — v0.3.0

Bongo v0.3.0 is the first Deez-capable managed-runtime release. In addition to the earlier authenticated CRUD/query/admin API, the final release includes:

- `mongodb://` parsing and typed connection options;
- `mongodb+srv://` SRV/TXT discovery;
- verified server-authenticated TLS;
- SCRAM-SHA-256 and SCRAM-SHA-1 with authentication negotiation/speculative auth;
- connect/socket/operation timeout handling;
- experimental URI-driven `RuntimeClient`;
- writable-server probing/selection;
- a bounded reusable transport pool;
- logical session/transaction-number primitives;
- pinned replica-set transactions with start/commit/abort;
- Deez-required transactional `insertOne` + `updateOne`;
- unit, normal integration, TLS+SCRAM, replica-set transaction, and Linux/Fly-style validation gates.

The v0.3.0 tag is now a frozen baseline. New work must not be inferred from intermediate v0.3 development branches; only the final tagged tree defines what shipped.

## Immediate next step — v0.3.x hardening

BONGO-0101 / #176 audits the exact path Deez depends on before Bongo adds more runtime features.

```text
Deez
  -> RuntimeClient
  -> URI / SRV
  -> TLS / SCRAM
  -> writable server
  -> pool
  -> session / transaction
  -> find / insert / update
```

Patch releases in the v0.3.x line are bug fixes, tests, documentation, and reliability improvements only.

## Production-runtime sequence

After the v0.3.x audit:

1. **Conformance and safety foundations**
   - #96 official MongoDB specification-test harness
   - #54 concurrency/thread-safety model
   - #56 standards-aware handshake/capabilities
   - #94 structured MongoDB errors/error labels

2. **CMAP-grade pooling**
   - #49-#55 connection pool lifecycle, sizing, wait queue, monitoring, concurrency, shutdown

3. **SDAM and server selection**
   - #57-#63 topology, replica-set discovery, heartbeats, primary/read selection, latency window, failover
   - #64 sharded/mongos and #65 load-balanced mode follow as deployment extensions

4. **Sessions and reliability**
   - #66-#69 public/server sessions, cluster/operation time, causal consistency
   - #70 retryable reads
   - #71 retryable writes
   - #74 transaction options/pinning
   - #75 transaction retry/error-label semantics
   - #95 cancellation

5. **BSON ergonomics**
   - #77-#86 ObjectId generation, typed decoding, naming, collections, codecs, ownership, Extended JSON, Decimal128, UUID helpers

6. **Optional parity features**
   - #44 end-to-end MONGODB-X509 via `chrisbirster/zig-mtls`
   - #46 OP_COMPRESSED/compressor negotiation
   - #76 Stable API
   - #87-#88 change streams
   - #89-#91 GridFS
   - #92-#93 command monitoring/logging

## Completed v0.3 milestones reconciled after release

The following original roadmap tickets have been closed because their acceptance boundary shipped in v0.3.0:

- #39 MongoDB URI parsing
- #40 connection-string option validation
- #41 SRV/TXT discovery
- #43 SCRAM-SHA-1
- #45 auth mechanism negotiation/speculative auth
- #47 connect/socket timeouts
- #48 current operation-timeout boundary
- #72 transaction start
- #73 transaction commit/abort

Some related broader behavior remains tracked by newer/narrowed open issues; closing the original milestone does not claim full MongoDB-driver parity.

## Explicit deferred boundaries

- Full SDAM/background topology monitoring is not implemented yet.
- Complete server-selection/read-preference behavior is not implemented yet.
- Full retryable read/write semantics are not implemented yet.
- Complete transaction retry/error-label semantics are not implemented yet.
- Built-in client-certificate mTLS / end-to-end MONGODB-X509 is blocked on the transport boundary; generic work is being separated into `zig-mtls`.
- OP_COMPRESSED is not enabled in v0.3.0; #46 is a future spec-backed reintroduction, not a hidden shipped feature.
- Full SASLprep remains incomplete.
- Typed BSON struct decoding remains future work.

## Quality gates

Every production-runtime milestone must preserve:

```bash
zig build test
zig build integration-test
zig build tls-integration-test
zig build runtime-integration-test
```

and the Linux/Fly validation harness. The roadmap additionally moves official MongoDB specification tests, macOS CI, compatibility matrices, concurrency stress tests, failover tests, and fuzz/malformed-wire tests earlier as the relevant features land.

## Engineering rule

Reaching a later issue number is not the goal. A milestone is complete only when its protocol behavior, ownership, errors, positive/negative tests, integration behavior, and documentation form a coherent supported boundary.

See [DRIVER_PARITY_PLAN.md](DRIVER_PARITY_PLAN.md), [BONGO_STYLE.md](BONGO_STYLE.md), and [testing.md](testing.md).
