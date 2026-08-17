# SCRAM-SHA-256 Authentication

Bongo uses SCRAM-SHA-256 to authenticate a MongoDB user without sending the user's password directly to the server.

MongoDB documents SCRAM here:

- [MongoDB SCRAM documentation](https://www.mongodb.com/docs/manual/core/security-scram/)
- [MongoDB connection-string authentication options](https://www.mongodb.com/docs/manual/reference/connection-string-options/)

The SCRAM-SHA-256 mechanism itself is standardized here:

- [RFC 7677: SCRAM-SHA-256](https://www.rfc-editor.org/rfc/rfc7677.html)
- [RFC 5802: SCRAM protocol and GS2 header](https://www.rfc-editor.org/rfc/rfc5802.html)

## Overview

```text
Bongo                                      MongoDB
  │                                           │
  │ client-first                              │
  │ n,,n=bongo,r=abc123                       │
  ├──────────────────────────────────────────>│
  │                                           │
  │ server-first                              │
  │ r=abc123XYZ,s=c2FsdA==,i=4096             │
  │<──────────────────────────────────────────┤
  │                                           │
  │ client-final + proof                      │
  ├──────────────────────────────────────────>│
  │                                           │
  │ server-final                              │
  │<──────────────────────────────────────────┤
  │                                           │
  │ authenticated                             │
```

BONGO-0001 implements this process.

## Client First Message

The first SCRAM function implemented by Bongo is:

```zig
pub fn clientFirst(
    allocator: Allocator,
    username: []const u8,
    nonce: []const u8,
) Error![]u8
```

Example:

```zig
const message = try clientFirst(
    allocator,
    "bongo",
    "abc123",
);
```

Produces:

```text
n,,n=bongo,r=abc123
```

## GS2 Header

The first three characters are the GS2 header:

```text
n,,n=bongo,r=abc123
^^^
GS2 header
```

For this SCRAM exchange, the GS2 header is:

```text
n,,
```

It can be read as:

```text
n   ,   [empty authorization identity]   ,
│                                       │
│                                       └── end of GS2 header
│
└── channel binding is not supported by this client
```

The two `n` values in the complete message mean different things:

```text
n,,n=bongo,r=abc123
│  │
│  └── `n=bongo` means username/name
│
└── the first `n` is the GS2 channel-binding flag
```

The GS2 header is part of SCRAM's protocol framing. It tells the server about channel binding and can optionally carry a SASL authorization identity.

Bongo currently uses the simple `n,,` form.

## Message Structure

```text
n,,n=bongo,r=abc123
│  │       │
│  │       └── client nonce
│  │
│  └────────── username
│
└───────────── GS2 header
```

The `n=` field contains the username.

The `r=` field contains the client-generated nonce.

## Nonce

A nonce is a random value generated for an authentication attempt.

Example:

```text
abc123
```

In production Bongo will generate a random nonce rather than using a hard-coded value.

MongoDB's server response must contain a nonce that begins with the client nonce.

For example:

```text
client:
abc123

server:
abc123XYZ
```

This ties the server's response to the authentication attempt that Bongo started.

## Username Escaping

SCRAM reserves `,` and `=` as part of its message syntax.

Therefore usernames containing these characters must be escaped.

```text
,  ->  =2C
=  ->  =3D
```

Example:

```text
username:
a,b=c

encoded:
a=2Cb=3Dc
```

So:

```text
n,,n=a=2Cb=3Dc,r=nonce
```

is sent instead of:

```text
n,,n=a,b=c,r=nonce
```

## Nonce Validation

Bongo currently rejects:

- empty nonces
- non-printable nonce characters
- commas inside a nonce

The comma cannot appear because SCRAM uses commas to separate attributes.

## Memory Ownership

`clientFirst()` allocates the completed SCRAM message.

The caller owns the returned slice:

```zig
const message = try clientFirst(
    allocator,
    "bongo",
    "abc123",
);
defer allocator.free(message);
```

The temporary escaped username is held in an `ArrayList(u8)` and freed inside `clientFirst()`.

## Current Status

```text
client-first message        ✓
username escaping           ✓
nonce validation            ✓
unit tests                  ✓

server-first parsing        next
password proof              not implemented
client-final                not implemented
server verification         not implemented
MongoDB saslStart           not implemented
MongoDB saslContinue        not implemented
```

## Relevant Source

```text
src/mongo/scram.zig
```
