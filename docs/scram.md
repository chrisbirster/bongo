# SCRAM-SHA-256 authentication

MongoDB uses SCRAM-SHA-256 to let a client prove it knows a user's password without sending the password itself to the server.

Bongo keeps the protocol bytes explicit so the authentication transcript and cryptographic inputs remain testable.

## Key derivation

```text
prepared password
       +
 decoded salt
       +
 iterations
       │
       ▼
PBKDF2-HMAC-SHA-256
       │
       ▼
SaltedPassword
       │
       ├──────────────────────────────┐
       ▼                              ▼
HMAC("Client Key")             HMAC("Server Key")
       │                              │
       ▼                              ▼
ClientKey                       ServerKey
       │                              │
       ▼                              │
SHA-256                              │
       │                              │
       ▼                              │
StoredKey                            │
```

MongoDB requires at least 4096 SCRAM iterations. Bongo rejects smaller values.

SCRAM-SHA-256 requires SASLprep for passwords. The current application-level authentication helper accepts ASCII passwords that pass through SASLprep unchanged and returns `UnsupportedPasswordPreparation` for non-ASCII input rather than deriving credentials from incorrectly prepared bytes.

Usernames are not SASLprep-normalized. SCRAM escaping still replaces `,` with `=2C` and `=` with `=3D` in the client-first message.

## Authentication transcript

The client-first message begins with the GS2 header `n,,`:

```text
n,,n=<escaped username>,r=<client nonce>
```

MongoDB responds with a server-first message containing the combined nonce, Base64 salt, and iteration count:

```text
r=<combined nonce>,s=<Base64 salt>,i=<iterations>
```

With channel binding disabled, the client-final-message-without-proof is:

```text
c=biws,r=<combined nonce>
```

SCRAM signs the exact original transcript bytes:

```text
AuthMessage =
    client-first-message-bare
    + "," +
    server-first-message
    + "," +
    client-final-message-without-proof
```

Bongo does not parse and regenerate those three transcript parts before signing them.

## Client proof

```text
ClientSignature = HMAC-SHA-256(StoredKey, AuthMessage)
ClientProof     = ClientKey XOR ClientSignature
```

The 32-byte ClientProof is Base64-encoded and appended to the client-final message:

```text
c=biws,r=<combined nonce>,p=<Base64 ClientProof>
```

For the RFC 7677 `user` / `pencil` example, the proof is:

```text
dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=
```

## Server verification

Bongo also proves that the server knows the password-derived secret:

```text
ServerKey       = HMAC-SHA-256(SaltedPassword, "Server Key")
ServerSignature = HMAC-SHA-256(ServerKey, AuthMessage)
```

MongoDB sends the verifier as:

```text
v=<Base64 ServerSignature>
```

Bongo Base64-decodes the verifier and compares the fixed 32-byte signatures with Zig's constant-time cryptographic comparison helper. A server-final `e=` attribute is treated as an authentication failure.

For the RFC 7677 example, the verifier is:

```text
6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=
```

## MongoDB SASL transport

SCRAM messages are carried in MongoDB commands as BSON binary subtype 0 payloads.

The first command is:

```text
{
  saslStart: 1,
  mechanism: "SCRAM-SHA-256",
  payload: BinData(0, <client-first>),
  options: { skipEmptyExchange: true },
  $db: <authentication database>
}
```

Bongo remembers the returned `conversationId` and sends the client-final message with:

```text
{
  saslContinue: 1,
  conversationId: <conversationId>,
  payload: BinData(0, <client-final>),
  $db: <authentication database>
}
```

Authentication completes when MongoDB returns `done: true` after the verified server-final payload. Older servers that do not honor `skipEmptyExchange` receive one final empty `saslContinue` exchange.

## Application API

Authentication operates on the same TCP connection that will be used for MongoDB commands:

```zig
var connection = try bongo.mongo.Connection.connect(
    io,
    "127.0.0.1",
    27017,
);
defer connection.deinit();

try bongo.mongo.authenticate(
    &connection,
    allocator,
    "admin",
    "admin",
    "secretpassword",
);
```

After `authenticate()` returns successfully, later commands sent through that connection use the authenticated MongoDB session.

## Conversation overview

```text
Bongo                                      MongoDB
  │                                           │
  │ saslStart(client-first)                   │
  │──────────────────────────────────────────>│
  │                                           │
  │        server-first + conversationId      │
  │<──────────────────────────────────────────│
  │                                           │
  │ derive keys / AuthMessage / ClientProof   │
  │                                           │
  │ saslContinue(client-final)                │
  │──────────────────────────────────────────>│
  │                                           │
  │                 server-final              │
  │<──────────────────────────────────────────│
  │                                           │
  │ constant-time server verifier check       │
  │                                           │
  │ authenticated                             │
```

## References

- RFC 5802 — Salted Challenge Response Authentication Mechanism (SCRAM): https://www.rfc-editor.org/rfc/rfc5802
- RFC 7677 — SCRAM-SHA-256: https://www.rfc-editor.org/rfc/rfc7677
- MongoDB Authentication Specification: https://github.com/mongodb/specifications/blob/master/source/auth/auth.md
