# Testing and quality

Bongo treats tests as part of the design, not as a final check after implementation. The detailed engineering rules live in [BONGO_STYLE.md](BONGO_STYLE.md); this document turns those rules into a practical test and review workflow.

## Two test layers

### Unit tests

Unit tests live next to the source code they verify and are discovered through `src/root.zig`.

Use them for:

- BSON encoding and parsing;
- OP_MSG encoding and parsing;
- command document shape;
- response parsing;
- protocol state transitions;
- boundary checks;
- malformed input;
- ownership and allocator behavior;
- deterministic SCRAM/specification vectors;
- compile-time/generic API instantiation.

Run:

```bash
zig build test
```

Allocating unit tests should use `std.testing.allocator` so leaks are visible.

### Integration tests

Integration tests live under `test/integration/` and execute against a real authentication-enabled MongoDB server.

Use them for behavior that requires MongoDB itself:

- authentication success and failure;
- actual CRUD semantics;
- cursor continuation and cleanup;
- duplicate-key/write errors;
- ordered versus unordered bulk behavior;
- concerns and command options;
- aggregation/explain behavior;
- collection/index administration.

Run:

```bash
zig build integration-test
```

Integration tests that prove failure behavior remain permanent. A feature becoming supported is not a reason to delete the test that proves an unsupported/unauthenticated path is rejected correctly.

## The negative-space rule

A happy-path test is not enough for protocol code.

For every external boundary, ask what happens when the input is:

- missing;
- the wrong BSON type;
- empty;
- truncated;
- malformed;
- duplicated when duplicates are forbidden;
- exactly at the minimum/maximum boundary;
- just outside the valid boundary;
- internally contradictory;
- associated with the wrong request/response ID.

If a remote MongoDB server can produce the state, the result must be an error rather than a panic or assertion.

A useful response-parser matrix is:

```text
valid reply                         -> success
wrong responseTo                    -> error
missing ok                          -> error
ok = 0                              -> error
wrong type for required field       -> error
missing required field              -> error
malformed nested BSON               -> error
server write error                  -> error
write concern error                 -> error
```

Not every parser has every field above, but every relevant invalid branch should be intentionally covered.

## Assertions versus errors

Use an assertion only for a programmer invariant that external input cannot violate after validation.

Good examples:

```zig
std.debug.assert(limit == 0 or limit == 1);
std.debug.assert(!cursor.closed);
std.debug.assert(cursor.cursor_id != 0);
```

Bad example:

```zig
// Do not assert this if MongoDB supplied the field.
std.debug.assert(response_to == request_id);
```

A mismatched server response ID must return an error.

The decision is:

```text
Can outside input cause this?
        │
   ┌────┴────┐
  yes       no
   │         │
 error    assertion
```

Assertions are executable contracts; they are not decorations and there is no target assertion count per function.

## Generic Zig APIs must be instantiated by unit tests

Bongo makes heavy use of `anytype`, anonymous structs, and tuples. Zig only compiles many generic function bodies when they are instantiated.

Therefore every significant public generic path should have at least one unit test that actually calls it.

This prevents a situation where:

```text
module imported by zig build test
        │
        └── generic function never instantiated
                     │
                     └── compile error discovered only by integration test/user code
```

An integration test is still required when the behavior depends on MongoDB, but it should not be the first place the generic function is compiled.

## Ownership tests

Any API that allocates or borrows memory needs an explicit lifetime model.

Tests should verify, where practical:

- caller-owned results are deinitialized without leaks;
- error paths free partially acquired resources;
- cursor batch replacement frees the previous response;
- cloned BSON values own every slice they expose;
- borrowed BSON slices are documented and are not accidentally retained across buffer replacement.

`std.testing.allocator` is the default tool for detecting leaks in unit tests.

## Protocol boundaries must be spec-first

Before implementing or changing BSON, OP_MSG, SCRAM, command, cursor, handshake, SDAM, CMAP, session, or transaction behavior:

1. Find the relevant MongoDB specification/RFC or command documentation.
2. Identify exact field names, wire widths, byte order, limits, and state transitions.
3. Encode those rules in validation/errors.
4. Add valid and invalid tests around the rule.
5. Only then wire the behavior into the public API.

Examples alone are not a specification.

## Bounded work

External input must not silently control unbounded work.

Review:

- document/message lengths;
- allocation sizes;
- cursor batches;
- SCRAM iteration counts;
- retry loops;
- timeouts;
- connection-pool sizes and wait queues;
- server-advertised limits.

When Bongo does not yet negotiate or enforce a server capability, that limitation should be explicit rather than approximated. Full handshake capability/server-limit negotiation is tracked by #56.

## Merge checklist

Before a feature PR is merged, answer all of these:

- [ ] Did implementation start from the relevant MongoDB specification or RFC?
- [ ] Is external input validated before indexing, allocating, converting, or changing state?
- [ ] Are externally influenced lengths/loops/retries/allocations bounded?
- [ ] Are wire-width conversions explicit?
- [ ] Are malformed or contradictory server replies returned as errors?
- [ ] Are programmer invariants expressed with meaningful assertions where useful?
- [ ] Is memory ownership obvious and tested?
- [ ] Does every significant generic public path have a unit-test instantiation?
- [ ] Is the normal valid case tested?
- [ ] Is relevant negative space tested?
- [ ] Is the real MongoDB behavior covered by integration tests when needed?
- [ ] Does the documentation distinguish supported behavior from planned behavior?
- [ ] Did `zig fmt` run?
- [ ] Did `zig build test` pass?
- [ ] Did `zig build integration-test` pass when MongoDB behavior is involved?

## Future hardening

The existing roadmap deliberately goes beyond hand-written unit/integration tests:

- #96 adds a MongoDB specification-test harness.
- #97 adds fuzzing and a malformed-wire corpus.
- #100 performs the final API/documentation/compatibility review for v0.1.0.

Those milestones deepen the safety net; they do not replace the Bongo Style requirements for each feature as it is implemented.
