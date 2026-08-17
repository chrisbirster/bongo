# Bongo Style

Bongo's engineering style is inspired by [TigerBeetle's TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md), but adapted for a MongoDB driver and for the conventions already established in this repository.

This document applies immediately to new code and to existing code when it is modified.

## Design Priorities

Bongo optimizes for these goals, in this order:

1. Correctness and safety.
2. Performance and predictable resource use.
3. Developer experience.

A design should try to improve all three. When they conflict, correctness wins.

Incomplete functionality is acceptable when its boundary is explicit and tested. Knowingly incorrect protocol behavior is not.

## Protocol Work Is Spec-First

MongoDB, BSON, OP_MSG, SCRAM, and related protocols must be implemented from their specifications rather than from examples alone.

When implementing a protocol feature:

- Link the relevant MongoDB specification or RFC in the implementation documentation.
- Preserve exact wire widths, byte order, and required validation rules.
- Do not guess about unspecified behavior.
- Treat bytes received from the server as untrusted input.
- Validate lengths and ranges before indexing, allocating, or converting.
- Respect negotiated server limits and capabilities where the protocol provides them.
- Preserve exact protocol text or bytes when later cryptographic calculations depend on the original representation.

## Explicit Control Flow

Prefer simple, visible control flow over clever abstractions.

- Avoid recursion in wire parsing, authentication, cursor handling, and other bounded protocol code.
- Keep branching in the function responsible for control flow; move focused calculations into helpers.
- Keep helpers as pure as practical.
- Prefer positive invariants over double negatives.
- Split complicated boolean conditions when doing so makes valid and invalid cases easier to audit.
- Keep variables in the smallest useful scope.
- Introduce values close to where they are consumed.

New or substantially modified functions should fit within roughly 70 lines. If a function grows past that point, first look for a meaningful responsibility that can become a helper rather than mechanically splitting the function.

## Put Bounds On External Input

Anything controlled by a MongoDB server, connection string, user, file, or network peer must have a clear bound before Bongo trusts it.

Examples include:

- BSON document lengths.
- OP_MSG message lengths.
- string and binary lengths.
- cursor batches.
- SCRAM attributes.
- iteration counts.
- connection-pool sizes and wait queues.
- retry counts and timeouts.

A loop over external input must terminate because the input is bounded or because the loop has an explicit limit.

## Exact Types At Boundaries

Use integer types that match the protocol representation at wire boundaries.

Examples:

- BSON document lengths use the type required by BSON.
- OP_MSG fields use their specified fixed-width integer types.
- flags use explicitly sized unsigned integers or enums backed by them.

Use `usize` for local memory indexing and Zig APIs when appropriate, but never silently convert an external wire value into `usize`. Validate the value first, then convert deliberately.

## Assertions Versus Errors

Assertions and errors have different jobs.

Use assertions for programmer invariants: conditions that should be impossible to violate if Bongo itself is correct.

Use errors for expected runtime failures, including:

- malformed BSON.
- malformed MongoDB replies.
- invalid credentials.
- network failures.
- unsupported server features.
- invalid user input.

Do not crash because a remote server sent bad data.

Where an invariant is important, check both sides of the boundary when practical. Tests should cover the valid space, invalid space, and the exact boundary between them.

Prefer separate assertions when they express separate invariants.

## Memory Ownership Must Be Obvious

Every API that allocates or borrows memory should make ownership clear from its signature, documentation, or both.

Bongo conventions:

- Pass an allocator explicitly when a function returns newly allocated memory.
- State when the caller owns a returned slice.
- State when a returned slice borrows from an input buffer.
- Place `defer` immediately after successful resource acquisition when practical.
- Avoid unnecessary copies of BSON and wire buffers.
- Borrow slices when lifetime rules are simple and safe.
- Use `std.testing.allocator` in allocating unit tests so leaks are detected.

For example, `clientFirst()` returns caller-owned memory, while `parseServerFirst()` returns slices borrowed from the server-first input message. The documentation must preserve that distinction.

## Errors Must Be Handled

Every error path matters.

Do not discard an error merely to make the happy path compile. If an error is intentionally translated, ignored, retried, or collapsed into another error, the reason should be obvious in the code.

Protocol parsers should have tests for malformed and truncated input, not only valid examples.

## Tests Are Part Of The Design

Unit tests live close to the code they verify.

`src/root.zig` imports each source module required for test discovery. A module is imported once; individual tests inside that module do not need to be listed separately.

```zig
test {
    _ = @import("bson.zig");
    _ = @import("mongo/op_msg.zig");
    _ = @import("mongo/connection.zig");
    _ = @import("mongo/scram.zig");
}
```

Real MongoDB tests remain separate under `test/integration/` and are discovered through `test/integration.zig`.

Before merging relevant changes:

```text
zig build test
zig build integration-test
```

Integration tests that intentionally verify failure behavior remain permanent. For example, the unauthenticated-find test should continue to prove that an auth-enabled MongoDB server rejects an unauthenticated operation even after Bongo gains authentication support.

For protocol and cryptographic work, tests should include:

- normal valid input.
- minimum and maximum boundaries.
- malformed input.
- truncated input.
- duplicate fields when forbidden.
- invalid transitions from valid to invalid data.
- deterministic specification test vectors when available.

## Naming

Names should expose the MongoDB concept being modeled rather than hide it behind generic terminology.

- Functions and variables use `snake_case`.
- Types use Zig's normal type naming conventions.
- Avoid abbreviations unless they are established protocol terms such as BSON, SCRAM, OP_MSG, or URI.
- Include units in names when a number has units, for example `timeout_ms` or `message_bytes_max`.
- Avoid using one name for multiple protocol concepts.

### File Names

Bongo intentionally follows a Zig stdlib-style convention for file-as-type modules:

```text
Reader.zig
Writer.zig
ObjectId.zig
```

Concrete type files may therefore use `CamelCase.zig` and `@This()`.

Namespace and facade modules use lowercase or `snake_case` names and do not use `@This()` merely to create a namespace:

```text
bson.zig
bson/types.zig
mongo/op_msg.zig
mongo/scram.zig
```

This is a deliberate Bongo convention even though TigerBeetle chooses a different filename rule.

## Formatting

Run `zig fmt`.

Prefer compact Zig that remains easy to scan.

```zig
pub const ObjectId = types.ObjectId;
pub const Reader = @import("bson/Reader.zig");
pub const Writer = @import("bson/Writer.zig");
```

Do not break a short expression immediately after `=` simply to make it vertical.

Prefer:

```zig
pub const Connection = @import("mongo/connection.zig").Connection;
```

Over:

```zig
pub const Connection =
    @import("mongo/connection.zig").Connection;
```

Long calls, struct literals, signatures, and expressions should become multiline when that improves readability. Let `zig fmt` handle the final shape.

Aim to keep source lines at or below 100 columns.

## Comments And Documentation

Comments should primarily explain why a decision exists, what invariant is being protected, or what non-obvious protocol rule is being followed.

Do not narrate obvious syntax.

Implementation documentation belongs under `docs/` when a feature has enough protocol or architectural context that a future reader would otherwise need to rediscover it.

Use this distinction:

```text
README.md      How do I use Bongo?
docs/         How does Bongo work?
code comments Why does this specific implementation detail exist?
```

When adding a significant protocol feature, update the relevant implementation document as part of the same work.

## Performance

Think about performance while designing an API, but do not trade correctness for a speculative micro-optimization.

Consider costs in this order for driver work:

1. Network round trips.
2. Memory allocation and copying.
3. Parsing and serialization work.
4. CPU micro-optimizations.

Prefer designs that:

- avoid needless wire-buffer copies.
- avoid repeated allocation in hot paths.
- reuse buffers when ownership remains clear.
- batch operations when MongoDB exposes a batching mechanism.
- keep parsing predictable and bounded.

When performance code becomes non-obvious, add a benchmark or measurement that justifies it.

## Dependencies And Tooling

Prefer the Zig standard library and a small dependency surface.

A new dependency should solve a meaningful problem that would otherwise be costly or risky to implement correctly. Convenience alone is not sufficient for foundational protocol code.

Prefer Zig-based tooling when it keeps the development environment simpler, but do not force Zig into a task where doing so clearly harms correctness or maintainability.

## Commits And Pull Requests

Commit messages should describe the actual implementation change because commit history survives after a pull request is merged.

When work belongs to a Bongo ticket, include the ticket identifier when practical:

```text
BONGO-0001 parse SCRAM server-first message
```

A pull request should explain:

- what changed.
- why it changed.
- which protocol rule or specification matters.
- what was tested.
- what remains intentionally unfinished.

Do not claim an issue is complete while required acceptance criteria remain unfinished.

## Before Merge

For each change, ask:

- Is external input validated before use?
- Are lengths, loops, retries, and queues bounded?
- Are wire-width conversions explicit?
- Is memory ownership clear?
- Are programmer invariants assertions and runtime failures errors?
- Are both valid and invalid cases tested?
- Does the implementation follow the relevant MongoDB specification or RFC?
- Does the code explain any surprising decision?
- Did `zig fmt` run?
- Did `zig build test` pass?
- Did `zig build integration-test` pass when a real MongoDB behavior changed?

The goal is not to imitate TigerBeetle mechanically. The goal is to bring the same level of deliberate engineering discipline to Bongo while keeping Bongo's own architecture, protocol requirements, and Zig conventions coherent.
