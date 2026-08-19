# Querying

Bongo uses Zig values directly to build BSON filters and command options.

## Filters

A simple equality filter is an anonymous struct:

```zig
var cursor = try users.find(.{
    .active = true,
    .score = @as(i32, 5),
});
defer cursor.deinit();
```

MongoDB operators use quoted Zig field names:

```zig
var cursor = try users.find(.{
    .score = .{ .@"$gte" = @as(i32, 5) },
});
```

## Find options

`bongo.findWithOptions()` adds query options without changing the simple `Collection.find()` API:

```zig
var cursor = try bongo.findWithOptions(
    users,
    .{ .active = true },
    .{
        .projection = .{
            ._id = @as(i32, 0),
            .name = @as(i32, 1),
        },
        .sort = .{ .score = @as(i32, -1) },
        .skip = @as(i64, 10),
        .limit = @as(i64, 20),
    },
);
defer cursor.deinit();
```

The currently supported find-option surface includes:

- `projection`
- `sort`
- `skip`
- `limit`
- `collation`
- `hint`
- `comment`
- `maxTimeMS`
- `let`

Advanced example:

```zig
var cursor = try bongo.findWithOptions(
    users,
    .{ .name = "Bongo" },
    .{
        .collation = .{ .locale = "en", .strength = @as(i32, 2) },
        .hint = "_id_",
        .comment = "find Bongo",
        .maxTimeMS = @as(i64, 5000),
        .let = .{ .unused = @as(i32, 1) },
    },
);
defer cursor.deinit();
```

Options are omitted from the wire command when the caller does not supply them.

## Cursors and batches

MongoDB may not return all matches in the first response. Bongo hides the `firstBatch` / `getMore` transition behind `Cursor.next()`:

```text
find
  │
  ▼
firstBatch + cursor id
  │
  ├── document available ──► next()
  │
  └── batch exhausted
          │
          ▼
        getMore
          │
          ▼
      nextBatch
```

A document slice returned by `next()` is borrowed from the cursor and must not be retained across another `next()`, `close()`, or `deinit()` call.

See [cursors.md](cursors.md) for the complete ownership and cleanup rules.

## Count

```zig
const active_count = try users.countDocuments(
    .{ .active = true },
    .{},
);
```

`countDocuments()` accepts a filter plus count options such as skip and limit.

For a fast collection-level estimate:

```zig
const estimate = try users.estimatedDocumentCount();
```

## Distinct

```zig
var result = try users.distinct("category", .{ .active = true });
defer result.deinit();

while (try result.next()) |value| {
    switch (value) {
        .string => |category| std.debug.print("{s}\n", .{category}),
        else => {},
    }
}
```

The distinct result owns the MongoDB response bytes. Values returned by `next()` may borrow from that owned response and remain valid until `deinit()`.

## Aggregation

An aggregation pipeline is a Zig tuple. This allows each stage to have a different compile-time type:

```zig
var cursor = try bongo.aggregate(
    users,
    .{
        .{ .@"$match" = .{ .group = "cat" } },
        .{ .@"$sort" = .{ .score = @as(i32, -1) } },
        .{ .@"$project" = .{
            ._id = @as(i32, 0),
            .name = @as(i32, 1),
        } },
    },
);
defer cursor.deinit();
```

Aggregation reuses the same command-cursor machinery used by other cursor-returning commands.

## Explain

`explainFind()` returns MongoDB's explanation as an owned raw BSON document:

```zig
var explanation = try bongo.explainFind(
    users,
    .{ .name = "Bongo" },
    .query_planner,
);
defer explanation.deinit();
```

Supported verbosity values are:

- `.query_planner`
- `.execution_stats`
- `.all_plans_execution`

Bongo intentionally does not expose a typed query-plan model because MongoDB's explain output is not a stable application schema.

## Read concern

Read concern is configured on the client and attached to supported read commands:

```zig
var client = try bongo.Client.connect(
    io,
    allocator,
    .{
        .username = "admin",
        .password = "secretpassword",
        .read_concern = .{ .level = .local },
    },
);
```

The read-concern model supports MongoDB's configured levels, including local, majority, linearizable, available, and snapshot where the server/operation permits them.

## Read preference

Bongo has a validated read-preference model for modes, tag sets, and max staleness. It is intentionally **not** described as active server routing yet.

The current `Client` talks to one server. SDAM topology discovery and read-preference server selection are future work (#57 and #60). Until those exist, configuring a read preference does not make Bongo select a replica-set secondary.

## Write concern

Write concern is configured on the client and attached to supported write commands:

```zig
var client = try bongo.Client.connect(
    io,
    allocator,
    .{
        .username = "admin",
        .password = "secretpassword",
        .write_concern = .{
            .w = .majority,
            .journal = true,
            .wtimeout_ms = 1000,
        },
    },
);
```

A server `writeConcernError` is surfaced separately as `error.WriteConcernFailed`.
