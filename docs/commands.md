# Running raw MongoDB commands

Bongo provides high-level helpers for the MongoDB operations it understands directly. Use those helpers when one exists because they provide command-specific validation, result types, cursor handling, and ownership rules.

`runCommand()` is the low-level escape hatch for commands that Bongo does not wrap yet.

## Basic usage

```zig
const database = client.database("admin");

var response = try bongo.runCommand(
    database,
    .{ .ping = @as(i32, 1) },
);
defer response.deinit();

const ok = try bongo.bson.Reader.get(response.bytes, "ok");
```

The returned `OwnedDocument` owns a BSON copy of MongoDB's command response body. Any slices read from `response.bytes` remain valid until `response.deinit()`.

## Command field order matters

MongoDB database commands use the first field of the command document as the command name. Put the command field first:

```zig
.{
    .hello = @as(i32, 1),
    .comment = "diagnostic probe",
}
```

Bongo preserves the supplied field order and appends the wire-protocol `$db` field itself.

Do not provide `$db` in the command document. Bongo rejects it with `error.ReservedDatabaseField` so the command cannot silently target a database different from the `Database` handle supplied to `runCommand()`.

An empty command document returns `error.EmptyCommand`. An empty database name returns `error.EmptyDatabase`. Both are rejected before a request id is consumed or network I/O begins.

## Administrative commands

Some MongoDB commands must run against the `admin` database. Select it explicitly:

```zig
const admin = client.database("admin");
var response = try bongo.runCommand(
    admin,
    .{ .buildInfo = @as(i32, 1) },
);
defer response.deinit();
```

`runCommand()` does not guess which database a command requires.

## Response validation

The same shared response boundary used by Bongo's wrapped commands validates raw command responses:

- the OP_MSG `responseTo` value must match the request id;
- the response must contain a successful numeric `ok` value;
- a `writeConcernError` is surfaced as an error;
- malformed BSON or OP_MSG framing is returned as an error.

Unknown or rejected MongoDB commands therefore surface as `error.CommandFailed` rather than returning an unchecked response document.

## What `runCommand()` does not add

`runCommand()` intentionally stays low-level. Bongo adds `$db`, but otherwise passes the supplied command fields through unchanged.

It does not automatically infer command-specific read concern, write concern, read preference, collation, timeout, or other options. Include fields required by the command itself, or use Bongo's high-level wrapper when one exists.

It also returns a single raw response document. If a command returns a server cursor, `runCommand()` does not automatically turn that cursor into Bongo's cursor abstraction or issue `getMore`. Use the high-level cursor-returning API for commands Bongo already supports.
