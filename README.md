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
- `Collection.find()` with BSON document iteration
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

    var result = try users.find(.{ .active = true });
    defer result.deinit();

    var documents = try result.iterator();
    while (try documents.next()) |document| {
        const name = (try bongo.bson.Reader.get(document, "name")).?.string;
        std.debug.print("{s}\n", .{name});
    }
}
```

The driver API builds the MongoDB command, sends OP_MSG over the authenticated connection, validates the response, and exposes the returned `firstBatch` as BSON documents. Applications no longer need to construct OP_MSG packets for normal finds.
