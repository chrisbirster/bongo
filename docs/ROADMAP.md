# Bongo Roadmap

Bongo uses `BONGO-NNNN` GitHub issues as implementation milestones. Feature branches are created from `dev` and squash-merged back into `dev`; stable groups of work eventually roll into `main`.

The issue list is the detailed source of truth. This document is the human-sized map.

## Current position

Bongo has reached **BONGO-0035**. The driver now has an application-facing API for authenticated single-server CRUD, cursors, common query options, aggregation, collection administration, index administration, and database discovery/deletion.

The next issue is #36 — a generic `runCommand` escape hatch for commands that do not yet have a high-level Bongo wrapper.

Before later roadmap tickets are implemented mechanically, their scope should be compared with the current code. Some tickets were drafted before earlier milestones grew a fuller public `Client`, `Database`, and `Collection` model, so already-satisfied work should be updated or closed rather than duplicated.

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

This layer adds projection, sort, skip, limit, advanced find options, read concern, write concern, read-preference modeling, aggregation pipelines, and explain plans.

Read preference is currently configuration/modeling only. Actual topology-aware server selection comes later.

### 5. Collection, index, and database administration — implemented

The current administration surface includes:

- create, list, rename, and drop collections;
- create, list, and drop indexes;
- list databases;
- drop databases.

Cursor-backed collection/index discovery reuses Bongo's `getMore` machinery, while database discovery owns its top-level response buffer explicitly.

### 6. Command escape hatch and client configuration — planned

The next work begins with:

- #36 — generic `runCommand`;
- typed client configuration and connection options;
- `mongodb://` URI parsing and validation;
- `mongodb+srv://` discovery;
- TLS;
- timeouts.

Existing client-object-model tickets should be reconciled with the `Client`, `Database`, and `Collection` API that is already in use before new code is added.

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
