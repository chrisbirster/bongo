# Bongo Roadmap

Bongo uses `BONGO-NNNN` GitHub issues as implementation milestones. Feature branches are created from `dev` and squash-merged back into `dev`; stable groups of work eventually roll into `main`.

The issue list is the detailed source of truth. This document is the human-sized map.

## Current position

Bongo has reached **BONGO-0031**: the driver now has a real application-facing API for authenticated single-server CRUD, cursors, common query options, aggregation, collection management, and index creation.

The immediate next issues are:

- #32 — drop indexes
- #33 — list indexes
- #34 — list databases
- #35 — drop databases

That means the project is no longer in the "can Zig speak MongoDB wire bytes?" stage. It is now an early driver with a substantial single-server command surface.

## Phase map

### 1. Wire foundation — implemented

```text
BSON
  ↓
OP_MSG
  ↓
TCP
  ↓
hello
```

This layer establishes BSON encoding/decoding, MongoDB message framing, request/response handling, and direct server communication.

### 2. Authentication — implemented

```text
TCP connection
      ↓
SCRAM-SHA-256
      ↓
authenticated connection
```

SCRAM-SHA-256 works end to end. Full password SASLprep remains incomplete and should be treated as an explicit limitation.

### 3. Driver API and CRUD — implemented

```text
Client
  └── Database
        └── Collection
              ├── find / findOne
              ├── insert
              ├── update
              ├── replace
              ├── delete
              └── bulkWrite
```

This phase includes cursor continuation/cleanup, atomic find-and-modify operations, upserts, counts, and distinct values.

### 4. Querying and command features — implemented

This layer adds:

- projection, sort, skip, and limit;
- advanced find options;
- read concern;
- write concern;
- read-preference modeling;
- aggregation pipelines;
- explain plans.

Read preference is currently configuration/modeling only. Actual topology-aware server selection comes later.

### 5. Collection and index administration — in progress

Implemented:

- create collection;
- list collections;
- rename collection;
- drop collection;
- create index.

Next (#32-#35):

- drop index;
- list indexes;
- list databases;
- drop database.

### 6. Client configuration and secure connectivity — planned

Later roadmap work adds the pieces expected from a general-purpose MongoDB connection layer, including:

- typed client options;
- `mongodb://` URI parsing and validation;
- `mongodb+srv://` discovery;
- TLS;
- timeouts.

### 7. Pooling, topology, and server selection — planned

A production driver cannot remain a single socket. The roadmap therefore adds:

- connection pooling and bounded checkout behavior;
- standards-aware handshake metadata/capability negotiation;
- SDAM topology tracking;
- replica-set and sharded deployment support;
- heartbeat monitoring;
- latency-aware and read-preference-aware server selection;
- failover handling.

Until this phase exists, Bongo should be described as a **single-server driver**, not as a replica-set-aware production driver.

### 8. Sessions, transactions, and reliability — planned

Later milestones add logical sessions, retryable behavior, transaction lifecycle, pinning, and related command metadata.

### 9. BSON ergonomics and additional MongoDB features — planned

The roadmap continues with typed BSON decoding, naming controls, ownership refinements, Extended JSON, change streams, GridFS, and other driver capabilities.

### 10. Hardening and release — planned

The final initial-roadmap milestones include:

- #96 — MongoDB specification-test harness;
- #97 — fuzz and malformed-wire testing;
- #99 — documentation, examples, and benchmarks;
- #100 — v0.1.0 release review and tag.

## Engineering rule

Reaching a later issue number is not the goal by itself. A milestone is useful only when its protocol behavior, ownership, errors, positive tests, negative-space tests, integration behavior, and documentation are coherent.

See [BONGO_STYLE.md](BONGO_STYLE.md) and [testing.md](testing.md) for the merge discipline used throughout the roadmap.
