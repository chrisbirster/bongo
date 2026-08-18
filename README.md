# Bongo

A MongoDB driver for Zig.

Named after my cat, Bongo.

![Bongo](./assets/bongo.jpg)

## Status

Work in progress.

Currently implemented:

- BSON encoding and decoding
- MongoDB OP_MSG encoding and decoding
- TCP connections
- `hello` command
- SCRAM-SHA-256 authentication
- application-facing `Client`, `Database`, and `Collection` handles
- `Collection.find()` with automatic MongoDB cursor iteration
- `getMore` for multi-batch find results
- `killCursors` cleanup for cursors stopped early
- integration tests against a real MongoDB server

## Why?

I’m building Bongo to learn how MongoDB works at the wire-protocol level and to eventually use it as the database layer for all my projects.

## Example

```zig
const std = @import("std");
const bongo = @import("bongo");

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var client = try bongo.Client.connect(
        io,
        allocator,
        .{
            .username = "admin",
            .password = "secretpassword",
        },
    );
    defer client.deinit();

    const users = client
        .database("test")
        .collection("users");

    var cursor = try users.find(.{ .active = true });
    defer cursor.deinit();

    while (try cursor.next()) |document| {
        const name = (try bongo.bson.Reader.get(document, "name")).?.string;
        std.debug.print("{s}\n", .{name});
    }
}
```

`Collection.find()` returns a cursor. Bongo reads `firstBatch`, automatically sends `getMore` when that batch is exhausted, and stops when MongoDB returns cursor id `0`. If iteration stops early, cursor cleanup sends `killCursors` during `deinit()`.
