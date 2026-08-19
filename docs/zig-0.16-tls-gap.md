# Zig 0.16 TLS gap and Bongo's compatibility boundary

This document is the canonical record of the TLS limitation Bongo found while validating MongoDB connections on **Zig 0.16.0**. Keep it updated whenever Bongo changes TLS behavior or raises its minimum Zig version.

## Executive summary

Bongo can use Zig 0.16.0's `std.crypto.tls.Client` for the TLS mode Deez needs:

- the MongoDB server presents a certificate;
- Bongo verifies the server certificate chain;
- Bongo verifies the requested host name;
- the client does **not** present a client certificate;
- MongoDB authentication happens after TLS with SCRAM-SHA-256 or SCRAM-SHA-1.

Zig 0.16.0 does **not** provide the client-certificate handshake support Bongo needs for MongoDB deployments that request or require a TLS client certificate. In particular, `std.crypto.tls.Client` has no public client certificate/private-key option and its handshake implementation does not handle the TLS `CertificateRequest` path needed for mutual TLS.

That missing capability blocks Bongo's built-in transport from completing end-to-end `MONGODB-X509` authentication. It does **not** block Deez when Deez uses normal SCRAM authentication over server-authenticated TLS.

## Environment where the gap was reproduced

The release gate exposed the problem with:

```text
Zig: 0.16.0
Homebrew install: /opt/homebrew/Cellar/zig/0.16.0_1
MongoDB fixture: mongo:latest
Client: std.crypto.tls.Client
```

The observed handshake returned:

```text
error.TlsUnexpectedMessage
```

The first Bongo cleanup implementation then obscured that error with a second bug: both the local socket cleanup and the heap-owned TLS connection cleanup closed the same file descriptor, causing Zig's debug `Io.Threaded` backend to abort on `BADF`. Bongo's TLS implementation must keep exactly one cleanup owner at every point in `connect`.

## What Zig 0.16.0 provides

The final Zig 0.16.0 `std.crypto.tls.Client.Options` used by Bongo includes:

- host verification (`host`);
- CA verification (`ca`);
- caller-owned read/write buffers;
- caller-provided cryptographic entropy;
- current wall-clock time;
- normal TLS 1.2/1.3 client handshakes.

For CA-bundle verification, Zig 0.16.0 expects a context containing the allocator, `std.Io`, an `std.Io.RwLock`, and a pointer to `Certificate.Bundle`. The final 0.16.0 client also requires 240 bytes of handshake entropy.

Bongo intentionally treats the installed Zig 0.16.0 standard library as authoritative rather than relying on pre-release 0.16 snapshots, because those snapshots used different TLS option shapes.

## What is missing from Zig 0.16.0

### 1. No client-certificate/private-key option

`std.crypto.tls.Client.Options` does not expose a certificate chain and private key for the client to present to a server.

Bongo therefore cannot implement built-in mutual TLS or end-to-end `MONGODB-X509` using only Zig 0.16.0's standard TLS client.

### 2. No usable `CertificateRequest` client-handshake path

TLS servers may send a `CertificateRequest` handshake message when they want client-certificate authentication. Zig defines the TLS handshake type, but the 0.16 client implementation does not provide the application-facing client-certificate response path Bongo needs.

A complete upstream solution needs to support both cases:

1. **No client certificate configured:** accept a server `CertificateRequest` where the protocol permits it and respond with an empty client certificate message rather than treating the request as an unexpected handshake message.
2. **Client certificate configured:** send the configured certificate chain and a valid `CertificateVerify` signature using the configured private key.

The second case also needs a safe API for private-key ownership/signing and certificate-chain configuration.

## MongoDB distinction that matters

MongoDB has two materially different TLS deployments:

### Server-authenticated TLS + SCRAM

This is the Deez requirement.

```text
Deez
  -> Bongo
      -> TLS: verify MongoDB server
      -> SCRAM-SHA-256/SHA-1
          -> MongoDB
```

The server proves its identity with a certificate. The client does not use a TLS certificate for authentication. MongoDB authentication happens at the MongoDB protocol layer with SCRAM.

### Mutual TLS / MONGODB-X509

```text
Client certificate + private key
  -> TLS Certificate / CertificateVerify
      -> MONGODB-X509 authentication
```

This requires the missing Zig 0.16 functionality described above.

MongoDB can explicitly allow TLS clients that do not present client certificates with `tlsAllowConnectionsWithoutCertificates`. Bongo's local SCRAM-over-TLS fixture deliberately does **not** configure a server client-CA requirement; it tests the same server-authenticated TLS model Deez needs.

MongoDB reference:

- https://www.mongodb.com/docs/manual/tutorial/configure-ssl/
- https://www.mongodb.com/docs/manual/reference/configuration-options/#mongodb-setting-net.tls.allowConnectionsWithoutCertificates

## Bongo policy on Zig 0.16.0

Bongo will not silently downgrade security.

- `tls=true` means a real encrypted TLS transport.
- Certificate verification remains enabled by default.
- Host-name verification remains enabled by default.
- `tlsInsecure`, `tlsAllowInvalidCertificates`, and `tlsAllowInvalidHostnames` only disable the controls they explicitly represent.
- Supplying `tlsCertificateKeyFile` to the built-in Zig 0.16 transport returns `ClientCertificateUnsupported` until Bongo has a transport capable of presenting it.
- MONGODB-X509 command/configuration code may exist independently, but it must not be described as end-to-end supported until the transport can present a client certificate.

## What Deez requires

Deez's first-class MongoDB backend requires:

- `mongodb://` and `mongodb+srv://` configuration;
- server-authenticated TLS;
- CA and host-name verification;
- SCRAM-SHA-256 (with SHA-1 compatibility useful but not fundamental to Deez);
- bounded connect/socket/operation timeouts;
- topology/server selection for hosted replica-set deployments;
- sessions and transactions so `appendReview` + scheduler-state update can be atomic;
- retry behavior that does not duplicate immutable review records.

Deez does **not** require MONGODB-X509 or mutual TLS for its normal backend.

## Upstream work worth contributing to Zig

A future Zig contribution should add general client-certificate support to `std.crypto.tls.Client`; it should not be MongoDB-specific. A useful design would cover:

- optional client certificate chain;
- signing/private-key callback or explicit supported private-key types;
- TLS 1.2 and TLS 1.3 `CertificateRequest` handling;
- empty-certificate response when no certificate is configured and the server permits it;
- `CertificateVerify` generation;
- tests against a TLS server that optionally requests and one that requires client certificates.

Until that exists in a Zig release Bongo supports, Bongo may either keep MONGODB-X509 transport unsupported or provide a separately maintained TLS backend. Deez does not need that work to proceed.

## Release acceptance tests

The Bongo TLS gate for Deez is:

```bash
./scripts/start-tls-db.sh
zig build tls-integration-test
```

The test must prove all of the following in one run:

1. the TLS handshake completes against real `mongod`;
2. Bongo trusts only the generated fixture certificate via `tlsCAFile`;
3. host-name verification succeeds for `localhost`;
4. SCRAM-SHA-256 authenticates across the TLS transport;
5. a MongoDB `hello` command succeeds after authentication.

A separate future mTLS/X.509 test should remain expected to fail or disabled until Zig/Bongo gains client-certificate support.
