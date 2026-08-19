# Connection strings

Bongo's connection-string layer is built in stages so parsing, normalization, DNS discovery, and transport behavior stay independently testable.

## Structural parsing

`bongo.parseConnectionString(allocator, uri)` parses a standard `mongodb://` URI into an owned `bongo.ConnectionString` value.

```zig
var parsed = try bongo.parseConnectionString(
    allocator,
    "mongodb://alice:secret@db1.example:27017,db2.example/app?retryWrites=true",
);
defer parsed.deinit();

const username = parsed.username.?;       // "alice"
const first_host = parsed.hosts[0].name;  // "db1.example"
const database = parsed.database.?;       // "app"
```

The parsed value owns the backing URI storage plus its host and option arrays. All string fields remain valid until `deinit()`.

The structural parser understands:

- optional username and password user-info;
- one or more comma-separated seed hosts;
- optional per-host ports;
- bracketed IPv6 literals such as `[2001:db8::1]:27017`;
- an optional default database;
- query-string option name/value pairs.

## What structural parsing does not do

The first parsing layer deliberately preserves percent-encoded text and raw option values. For example, `%40` remains `%40` instead of becoming `@`, and `retryWrites=true` remains a raw option pair rather than immediately becoming a boolean.

That separation is intentional. Connection-string normalization and validation are responsible for percent decoding, typed boolean/numeric option parsing, duplicate handling, and incompatible-option checks. Keeping those rules out of structural parsing makes malformed URI shapes distinguishable from invalid MongoDB option combinations.

`mongodb+srv://` discovery, TLS transport setup, authentication negotiation, compression, and timeout behavior are separate connection-layer stages as well.
