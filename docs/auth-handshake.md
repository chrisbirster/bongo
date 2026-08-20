# Authentication handshake

Bongo can negotiate the default SCRAM mechanism as part of the initial MongoDB handshake and can use speculative authentication to remove one authentication round trip on modern servers.

`bongo.mongo.authenticateWithHandshake(...)` sends a `hello` command containing both:

- `saslSupportedMechs: "<auth database>.<username>"`; and
- a speculative SCRAM-SHA-256 `saslStart` document.

The username in `saslSupportedMechs` is the raw username provided by the application. Bongo does not SASLprep or otherwise normalize it before the mechanism lookup.

## Selection rules

When the server returns `saslSupportedMechs`, Bongo prefers `SCRAM-SHA-256` whenever that mechanism is present. If SHA-256 is absent, Bongo falls back to `SCRAM-SHA-1` regardless of whether the returned array contains unknown mechanisms. If the field is missing entirely, Bongo also falls back to SHA-1 as required by the MongoDB authentication specification.

Unknown mechanism names are ignored rather than treated as handshake failures.

## Speculative authentication

When no explicit mechanism is configured, the speculative command uses SCRAM-SHA-256. If the handshake response contains a `speculativeAuthenticate` reply and SHA-256 is selected, Bongo treats that embedded reply as the first successful SASL response and continues the same conversation directly with `saslContinue`.

If an older server ignores `speculativeAuthenticate`, Bongo starts the selected SCRAM mechanism normally after the handshake.

The low-level result records both the selected mechanism and whether the speculative exchange was used:

```zig
const result = try bongo.mongo.authenticateWithHandshake(
    &connection,
    allocator,
    "admin",
    "alice",
    "secret",
);

switch (result.selected_mechanism) {
    .scram_sha_256 => {},
    .scram_sha_1 => {},
}
```

This handshake path is the foundation for later connection work such as explicit URI mechanisms, X.509, compressor negotiation, server metadata, and pooled connections.
