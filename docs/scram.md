# SCRAM-SHA-256 authentication

MongoDB uses SCRAM-SHA-256 to let a client prove it knows a user's password without sending the password itself to the server.

Bongo implements the conversation in small steps so the exact bytes used by SCRAM stay explicit and testable.

## Key derivation pipeline

After the server sends its Base64-encoded salt and iteration count, Bongo decodes the salt and derives the client-side keys used to build the authentication proof.

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
       ▼
HMAC-SHA-256("Client Key")
       │
       ▼
ClientKey
       │
       ▼
SHA-256
       │
       ▼
StoredKey
```

The current BONGO-0001 implementation reaches `AuthMessage`.

## SaltedPassword

```text
SaltedPassword = PBKDF2-HMAC-SHA-256(
    prepared_password,
    salt,
    iterations
)
```

The server sends the salt as Base64 text. Bongo decodes that text before passing the raw salt bytes into PBKDF2.

MongoDB requires at least 4096 SCRAM iterations, so Bongo rejects smaller values at the protocol boundary.

Password preparation is intentionally separate from `saltedPassword()`. The helper expects a password that already satisfies the SCRAM-SHA-256 password preparation rules.

## ClientKey

```text
ClientKey = HMAC-SHA-256(
    SaltedPassword,
    "Client Key"
)
```

`"Client Key"` is literal protocol text. It is not a label chosen by Bongo.

The ClientKey is later combined with the ClientSignature to produce the proof sent to MongoDB.

## StoredKey

```text
StoredKey = SHA-256(ClientKey)
```

The StoredKey is a one-way hash of the ClientKey. SCRAM uses it to calculate the ClientSignature:

```text
ClientSignature = HMAC-SHA-256(
    StoredKey,
    AuthMessage
)
```

Bongo does not send the StoredKey or ClientKey directly to MongoDB.

## AuthMessage

SCRAM signs the exact authentication transcript rather than a parsed or normalized representation of it.

RFC 5802 defines the AuthMessage as:

```text
AuthMessage =
    client-first-message-bare
    + "," +
    server-first-message
    + "," +
    client-final-message-without-proof
```

For the SCRAM-SHA-256 example from RFC 7677, the three pieces are:

```text
client-first-message-bare:
n=user,r=rOprNGfwEbeRWgbNEkqO

server-first-message:
r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096

client-final-message-without-proof:
c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0
```

Bongo's `authMessage()` helper joins those original byte sequences with commas. It does not parse, reorder, normalize, or regenerate the fields. This matters because even semantically equivalent text would produce a different HMAC if the bytes changed.

The resulting AuthMessage becomes the message input to both the client and server signature calculations.

## What comes next

The remaining client proof path is:

```text
StoredKey
   +
AuthMessage
   │
   ▼
HMAC-SHA-256
   │
   ▼
ClientSignature
   +
ClientKey
   │
   ▼ XOR
ClientProof
   │
   ▼
Base64 proof
   │
   ▼
client-final message
```

Bongo will also derive a server key and verify MongoDB's server-final signature before treating authentication as successful.

## SCRAM conversation

At a high level, authentication will eventually look like this:

```text
Bongo                                      MongoDB
  │                                           │
  │ client-first                              │
  │──────────────────────────────────────────>│
  │                                           │
  │                 server-first              │
  │<──────────────────────────────────────────│
  │                                           │
  │ derive SaltedPassword                     │
  │ derive ClientKey                          │
  │ derive StoredKey                          │
  │ build AuthMessage                         │
  │ build ClientProof                         │
  │                                           │
  │ client-final                              │
  │──────────────────────────────────────────>│
  │                                           │
  │                 server-final              │
  │<──────────────────────────────────────────│
  │                                           │
  │ verify server signature                   │
  │                                           │
```

MongoDB carries this SCRAM exchange inside the `saslStart` and `saslContinue` commands. That transport layer is implemented after the proof calculations are complete.

## References

- RFC 5802 — Salted Challenge Response Authentication Mechanism (SCRAM): https://www.rfc-editor.org/rfc/rfc5802
- RFC 7677 — SCRAM-SHA-256: https://www.rfc-editor.org/rfc/rfc7677
- MongoDB Authentication Specification: https://github.com/mongodb/specifications/blob/master/source/auth/auth.md
