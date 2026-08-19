# SCRAM-SHA-1 authentication

Bongo supports SCRAM-SHA-1 as a compatibility mechanism alongside its existing SCRAM-SHA-256 implementation.

The MongoDB SHA-1 mechanism differs at the password-input step. Before PBKDF2, Bongo computes:

```text
HEX(MD5(username + ":mongo:" + password))
```

The lowercase hexadecimal digest is then used as the password input to PBKDF2-HMAC-SHA-1. MongoDB requires at least 4096 SCRAM iterations, and Bongo rejects smaller counts.

After that mechanism-specific derivation, the normal SCRAM transcript rules still apply: client-first and server-first messages are preserved exactly for the auth message, the client proof is generated from the derived key material, and the server verifier is checked with a constant-time comparison.

SCRAM-SHA-1 does **not** apply the SCRAM-SHA-256 password SASLprep path before computing MongoDB's MD5 password digest.

At the low-level connection API, callers can explicitly request SHA-1:

```zig
try bongo.mongo.authenticateSha1(
    &connection,
    allocator,
    "admin",
    "admin",
    "secretpassword",
);
```

Normal `Client.connect` continues to use SCRAM-SHA-256 until authentication mechanism negotiation is integrated into the MongoDB handshake.
