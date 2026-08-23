# Connection strings

Bongo keeps connection-string work in layers so URI parsing, option validation, DNS discovery, and transport setup can be tested independently.

## From URI to a live client

```mermaid
flowchart TD
    URI[MongoDB connection string]
    URI --> Parse[parseConnectionString]
    Parse --> Structural[Owned ConnectionString]
    Structural --> Normalize[parseConnectionOptions]
    Normalize --> Options[NormalizedConnectionOptions]

    Options --> Scheme{mongodb or mongodb+srv?}
    Scheme -->|mongodb| Seeds[Configured seed hosts]
    Scheme -->|mongodb+srv| DNS[SRV + TXT lookup]
    DNS --> Seeds

    Seeds --> Connect[Open transport]
    Connect --> TLS{TLS enabled?}
    TLS -->|Yes| Secure[TLS with server verification]
    TLS -->|No| Plain[TCP]
    Secure --> Auth[Handshake + authentication]
    Plain --> Auth
    Auth --> Runtime[RuntimeClient]
    Runtime --> Topology[SDAM discovery + pools]
```

The parser does not open sockets. DNS discovery does not authenticate. Authentication does not own server selection. Keeping those responsibilities separate makes failures easier to test and reason about.

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

The parsed value owns the backing URI storage plus its host and option arrays. String fields remain valid until `deinit()`.

The structural parser understands:

- optional username/password user-info;
- one or more comma-separated seed hosts;
- optional per-host ports;
- bracketed IPv6 literals such as `[2001:db8::1]:27017`;
- an optional default database;
- query-string option name/value pairs.

Structural parsing preserves encoded text and raw option values. `%40` is still `%40` here, and `retryWrites=true` is still a name/value pair.

## Normalized options

`bongo.parseConnectionOptions(allocator, uri)` turns the structural result into typed `bongo.NormalizedConnectionOptions`.

```zig
var options = try bongo.parseConnectionOptions(
    allocator,
    "mongodb://alice:secret@DB.EXAMPLE/app?tls=true&connectTimeoutMS=5000",
);
defer options.deinit();

const host = options.hosts[0].name;                   // "db.example"
const port = options.hosts[0].port;                   // 27017
const tls = options.tls.?;                            // true
const connect_timeout = options.connect_timeout_ms.?; // 5000
```

Normalization handles the settings used by the managed runtime, including:

- percent-decoded credentials, database names, paths, and string options;
- lowercase host names and default port `27017`;
- authentication mechanism and auth-source validation;
- TLS and topology options;
- connect, socket, operation, pool, heartbeat, and server-selection settings;
- read preference and max-staleness settings;
- `retryReads` and `retryWrites`;
- SRV-specific settings;
- compressor preferences for forward-compatible parsing.

Recognized scalar options are strict. Conflicting repeated values return errors instead of relying on undocumented precedence. `tls` and legacy `ssl` follow the MongoDB URI rules: repeated values may agree, but conflicting values are rejected.

Bongo also rejects incompatible combinations such as `directConnection=true` with multiple seeds, load-balanced mode with a replica-set name, conflicting TLS security controls, and SRV-only options on a normal `mongodb://` URI.

Unknown URI options are ignored for forward compatibility.

## `mongodb+srv://`

SRV connection strings go through DNS before the runtime opens application connections. Bongo resolves SRV hosts, validates that discovered names remain under the expected parent domain, applies supported TXT defaults, and then feeds the resulting host list into the same normalized runtime configuration used by normal seed lists.

That means the rest of the runtime does not need a second networking architecture just because the seed list came from DNS.

## TLS and authentication

When TLS is enabled, Bongo verifies the server certificate and host name before using the connection for MongoDB authentication. SCRAM-SHA-256 and SCRAM-SHA-1 are supported, including mechanism negotiation and speculative authentication.

Client-certificate mTLS / end-to-end `MONGODB-X509` is still limited by the Zig 0.16 TLS client API; see [Zig 0.16 TLS gap](zig-0.16-tls-gap.md).

## Current limits

Some options are parsed before the corresponding runtime feature exists. In particular, compressor preferences are understood by the URI layer, but Bongo does not yet send `OP_COMPRESSED` messages.

Sharded/mongos and load-balanced deployment support are also not yet complete. The URI layer validates their configuration boundaries without pretending that the full runtime behavior is already implemented.