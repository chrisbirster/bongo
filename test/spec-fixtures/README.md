# Pinned MongoDB specification fixtures

Bongo v0.6.0 pins a deliberately small upstream-backed retry subset at MongoDB specifications commit:

`92b3c0b9287bfba1b0ec4084300858d05c654f8c`

Vendored unchanged:

- `source/retryable-reads/tests/unified/find-serverErrors.json`
- `source/retryable-writes/tests/unified/insertOne.json`

These fixtures are parsed by `test/spec.zig` and their supported failure cases are exercised by the live retryability integration gate. This is not a claim of full MongoDB specification-suite conformance.
