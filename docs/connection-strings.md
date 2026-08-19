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

## Normalized connection options

`bongo.parseConnectionOptions(allocator, uri)` builds on the structural parser and returns an owned `bongo.NormalizedConnectionOptions` value suitable for later connection-layer stages.

```zig
var options = try bongo.parseConnectionOptions(
    allocator,
    "mongodb://alice:secret@DB.EXAMPLE/app?tls=true&connectTimeoutMS=5000",
);
defer options.deinit();

const host = options.hosts[0].name;              // "db.example"
const port = options.hosts[0].port;              // 27017
const tls = options.tls.?;                       // true
const connect_timeout = options.connect_timeout_ms.?; // 5000
```

Normalization currently provides the typed settings needed by the rest of the v0.3 connection work:

- percent-decoded UTF-8 credentials, database names, file paths, and string options;
- lowercase host names with a default port of `27017`;
- authentication mechanism and authentication-source validation;
- boolean topology/TLS options;
- connection, socket, and client-side operation timeout values;
- compressor lists for forward-compatible configuration parsing;
- TLS certificate/CA settings for forward-compatible configuration parsing;
- SRV-specific option fields for the DNS discovery layer.

Recognized scalar options are intentionally strict: conflicting or repeated settings return deterministic errors instead of leaving precedence undefined. `tls` and its legacy alias `ssl` are the exception required by the MongoDB URI rules: repeated instances are accepted when all values agree and rejected when they conflict.

Bongo also rejects known incompatible combinations such as `directConnection=true` with multiple seed hosts, load-balanced mode with multiple seeds or a replica set, conflicting insecure TLS controls, invalid authentication requirements, and SRV-only options on a standard `mongodb://` URI.

Unknown URI options are ignored for forward compatibility. Bongo does not yet have a logging subsystem to emit the MongoDB specification's recommended warning for unsupported keys.

## Layer boundaries

Structural parsing deliberately preserves percent-encoded text and raw option values. For example, `%40` remains `%40` instead of becoming `@`, and `retryWrites=true` remains a raw option pair rather than immediately becoming a boolean. Normalization is the layer that decodes and validates those values.

`mongodb+srv://` discovery, authentication negotiation, and timeout enforcement remain separate connection-layer stages so each can be tested independently. Runtime TLS and wire compression are deferred beyond v0.3; their URI preferences are parsed now so later transport support does not require changing the connection-string API.
