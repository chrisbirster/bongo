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
- raw `find` command
- integration tests against a real MongoDB server

## Why?

I’m building Bongo to learn how MongoDB works at the wire-protocol level and to eventually use it as the database layer for all my projects

## Example

```zig
const request = try bongo.mongo.op_msg.encodeCommand(
    allocator,
    .{
        .hello = @as(i32, 1),
        .@"$db" = "admin",
    },
    .{ .request_id = 1 },
);