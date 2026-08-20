# Bongo driver parity plan after v0.3.0

This document is the dependency-ordered plan for moving Bongo from the Deez-capable v0.3.0 runtime toward the reliability and deployment behavior expected from a mature MongoDB driver such as the official Go driver.

It deliberately does **not** mean "implement every feature the Go driver has." The highest-value parity gap is production runtime behavior around otherwise-working CRUD: connection-pool semantics, concurrency, topology monitoring, server selection, failover, sessions, retries, error classification, and conformance testing.

## Principles

1. **Freeze v0.3.0.** The tag is an immutable baseline. Fixes become focused v0.3.x patch work; deferred features do not get retrofitted into the release.
2. **Audit before adding.** BONGO-0101 / #176 hardens the exact Deez path before the next feature milestone.
3. **Specification tests move early.** BONGO-0096 is a prerequisite/tooling foundation for new CMAP, SDAM, session, retry, and transaction behavior.
4. **Small coherent releases.** Do not repeat v0.3.0's broad URI + SRV + TLS + auth + pool + session + transaction batch in one release.
5. **Final-tree behavior beats intermediate history.** Removed experiments such as OP_COMPRESSED are not considered shipped functionality.
6. **Generic Zig gaps stay generic.** Mutual-TLS/client-certificate work belongs in `chrisbirster/zig-mtls`; Bongo should consume it later rather than own a generic TLS fork.
7. **Do not measure parity by method count.** Bongo already has broad CRUD/query/admin coverage. Runtime correctness is the bottleneck.

## Current v0.3.0 baseline

The release already provides the application path required by Deez:

```text
RuntimeClient
  -> mongodb:// / mongodb+srv://
  -> verified server-authenticated TLS
  -> SCRAM-SHA-256 / SCRAM-SHA-1
  -> writable-server probing/selection
  -> bounded reusable transport pool
  -> logical session + transaction number
  -> pinned replica-set transaction
  -> find / insertOne / updateOne
```

The release has been exercised on native macOS and in the Linux/Fly-style validation container using unit, normal integration, TLS+SCRAM, and replica-set transaction gates.

This is a useful baseline, not a claim of production-driver parity.

## Phase 0 — v0.3.x hardening

### Primary issue

- BONGO-0101 / #176 — audit and harden the v0.3.x Deez runtime baseline

### Supporting issues

- #98 — expand platform/MongoDB compatibility CI matrix
- #97 — fuzz/malformed-wire testing where the audit exposes parser risk
- documentation/test-only fixes discovered by the audit

### Work

- inventory exactly which Bongo APIs Deez uses
- inspect ownership/deinit/error paths for those APIs
- reproduce network/server failure modes
- stress current pool/session/transaction cleanup
- validate Deez as an external Zig package consumer, not a sibling source checkout
- automate macOS coverage instead of relying only on manual checks
- make patch-compatible fixes only

### Exit gate

```text
BLOCKER findings: 0
HIGH findings: fixed or explicitly accepted/documented
macOS: green
Linux: green
Deez external-consumer test: green
```

If code fixes are required, publish them as v0.3.1/v0.3.x rather than adding features.

---

## Phase 1 — conformance and runtime foundations

This phase creates the infrastructure needed to implement production behavior safely.

### 1. Official specification-test harness

- #96 — early MongoDB specification-test harness

Implement first. Start with URI/CRUD/current session/transaction fixtures, then enable CMAP/SDAM/retry fixtures as those features land. Unsupported cases must be reported as skipped with reasons, never silently ignored.

### 2. Concurrency contract

- #54 — define and stress-test concurrency/thread-safety model

Before background monitoring or more complicated pooling, define which public types are thread-safe and which are single-owner. Stress checkout/request/checkin and shutdown/error races on macOS and Linux.

### 3. Standards-aware handshake

- #56 — complete driver metadata, wire-version, server-limit, and capability negotiation

Authentication negotiation already shipped. This issue should produce one canonical managed-connection handshake used by pool and topology layers.

### 4. Structured error model

- #94 — MongoDB error codes and error labels

Move this early because retries, transaction retries, failover, and observability cannot be correct when errors are flattened into generic failures.

### Exit gate

- official spec harness runs useful v0.3 fixtures in CI
- concurrency semantics documented/tested
- all managed connections use a canonical validated handshake
- server errors preserve codes/labels needed by later phases

---

## Phase 2 — CMAP-grade connection pooling

Bongo v0.3 has a bounded reusable RuntimeClient pool. This phase turns it into a production pool model rather than replacing it blindly.

### Issues

- #49 — complete CMAP-grade connection pool core
- #50 — pool sizing controls
- #51 — idle/stale connection lifecycle
- #52 — wait queue and checkout deadline
- #53 — CMAP pool monitoring events
- #55 — graceful client shutdown

#54 concurrency is a prerequisite and should already be complete.

### Required behavior

- one pool per server once SDAM supplies multiple server descriptions
- authenticated connection readiness lifecycle
- bounded creation and checkout
- `minPoolSize`, `maxPoolSize`, and controlled concurrent connection creation as applicable
- wait queue obeying remaining operation budget
- stale/broken connection rejection
- pool generations and clear semantics
- idle reclamation
- deterministic shutdown with in-flight operations
- CMAP events for conformance testing/observability

### Exit gate

- relevant CMAP specification fixtures pass
- contention/stress tests pass repeatedly
- broken connections are never handed to later operations
- no known leaks/double-close/use-after-checkin behavior

---

## Phase 3 — SDAM and server selection

This is the largest remaining gap between Bongo's v0.3 writable-server probe and a mature MongoDB driver runtime.

### Issues

- #57 — SDAM topology model
- #58 — replica-set discovery
- #59 — primary server selection
- #60 — secondary/read-preference server selection
- #61 — heartbeat monitoring
- #62 — topology changes and failover handling
- #63 — latency-window server selection

### Implementation order

```text
#57 topology/server descriptions
  -> #58 replica-set discovery
  -> #61 heartbeat monitoring + RTT
  -> #59 primary selection
  -> #60 read-preference selection
  -> #63 latency window
  -> #62 failover/pool clearing/reselection integration
```

Some pieces can be developed in parallel after the core topology model exists, but every behavior should be driven by the relevant SDAM/server-selection fixtures in #96.

### Required integration scenario

At minimum, run a multi-member replica set and prove:

1. client discovers members from seeds/hello responses;
2. operations select the current primary when required;
3. reads obey supported read preference;
4. monitors observe primary stepdown;
5. affected pools are cleared where required;
6. a replacement primary is selected within `serverSelectionTimeoutMS`;
7. operations resume without restarting the client.

### Later deployment subphase

- #64 — sharded/mongos support
- #65 — load-balanced mode

Do not block basic replica-set production reliability on these more specialized deployment modes.

---

## Phase 4 — sessions and reliability

### Sessions

- #66 — complete public client-session API
- #67 — server session pool / lsid reuse and expiry
- #68 — clusterTime / operationTime propagation
- #69 — causal consistency

The v0.3 internal transaction session is a foundation, not a complete public session implementation.

### Retryable operations

- #70 — spec-backed retryable reads
- #71 — complete spec-backed retryable writes

Dependencies:

```text
#94 structured errors
+ #49-#55 pool semantics
+ #57-#63 SDAM/failover/server selection
+ #66/#67 session identity
+ #96 spec tests
    -> #70/#71
```

Retryable writes must preserve the same logical `(lsid, txnNumber)` across eligible wire retries so ambiguous failures do not duplicate application writes.

### Transactions

Already complete at the v0.3 Deez boundary:

- #72 transaction start — closed
- #73 commit/abort — closed

Remaining:

- #74 — complete transaction options and deployment-aware pinning
- #75 — transaction retry/error-label semantics

### Cancellation

- #95 — operation cancellation

Cancellation must interrupt selection, pool checkout, and network waits without putting a corrupted connection back into a pool.

### Exit gate

- official session/retry/transaction fixtures for supported behavior pass
- primary failover tests include eligible retries
- retryable writes prove no duplicate logical writes
- transaction retry tests handle transient transaction and unknown commit outcomes correctly

---

## Phase 5 — BSON developer ergonomics

Once runtime reliability is strong, improve the application-facing BSON experience.

### Issues

- #77 — ObjectId generation
- #78 — typed BSON struct decoding
- #79 — field tags/naming controls
- #80 — optionals/nulls/enums
- #81 — arrays/maps/dynamic documents
- #82 — custom codecs
- #83 — ownership/zero-copy decoding
- #84 — Extended JSON
- #85 — Decimal128 conversions
- #86 — UUID helpers

### Suggested order

Start with #83 ownership rules and #78 typed decode together or in closely coordinated PRs. Typed APIs should not be built on ambiguous buffer lifetimes.

Developer ergonomics can become a Bongo strength, but it should not preempt SDAM/reliability work required by applications already using the driver.

---

## Phase 6 — optional parity features

These are valuable but should not block a reliable general CRUD/runtime driver.

### Transport/auth

- #44 — complete MONGODB-X509 after `zig-mtls` exposes a stable client-certificate transport
- #46 — reintroduce OP_COMPRESSED using spec-backed implementation
- #76 — MongoDB Stable API support

### Change streams

- #87 — change streams
- #88 — resumable change streams (requires #94 and reliable selection/retry behavior)

### GridFS

- #89 — upload
- #90 — download
- #91 — find/delete/rename

### Observability

- #92 — command monitoring
- #93 — structured logging hooks

Pool monitoring (#53) should land earlier because CMAP conformance benefits from it. General logging can remain optional and must never expose credentials/secrets.

### Additional future parity

Do not create implementation tickets yet unless a real consumer needs them. Examples from mature drivers include additional authentication mechanisms and client-side/queryable encryption. These are intentionally behind the core runtime work above.

---

## Continuous quality gates

Every phase should preserve the existing baseline gates:

```bash
zig build test
zig build integration-test
zig build tls-integration-test
zig build runtime-integration-test
```

Linux/Fly-style validation:

```bash
docker compose build --no-cache
docker compose up \
  --abort-on-container-exit \
  --exit-code-from bongo-linux-validation
```

And progressively add:

- native macOS CI
- multiple MongoDB server versions (#98)
- official MongoDB specification fixtures (#96)
- concurrent stress tests (#54)
- failover/stepdown integration tests (#62)
- fuzz/malformed-wire tests (#97)

## Release discipline

Use releases as coherent capability boundaries rather than issue-number checkpoints.

A reasonable shape is:

```text
0.3.x  hardening / Deez baseline fixes only
next minor  conformance + concurrency + CMAP foundations
next minor  SDAM + replica-set server selection + failover
next minor  sessions + retries + full transaction reliability
later minors BSON ergonomics and optional parity features
1.0     production-support boundary after compatibility/spec review
```

The exact version numbers can change. The important rule is that each minor release has a small, explainable theme and its own acceptance matrix.

## Issue bookkeeping rule

When an issue's original acceptance criteria have already shipped, close it and create/update a narrower issue for the remaining behavior. Do not leave completed milestone tickets open simply because a later, more complete implementation exists.

This is why the v0.3 reconciliation closes the shipped URI/SRV/auth/timeout and transaction-start/finish tickets while keeping incomplete CMAP, SDAM, general sessions, retries, transaction pinning/retries, X.509 transport, and compression work open.
