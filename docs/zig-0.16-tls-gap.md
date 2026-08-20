# Zig 0.16 networking/TLS gaps and Bongo's compatibility boundary

This document is the canonical record of the Zig standard-library limitations Bongo found while validating MongoDB connections on **Zig 0.16.0**. Keep it updated whenever Bongo changes networking/TLS behavior or raises its minimum Zig version.

## Executive summary

Bongo can use Zig 0.16.0's `std.crypto.tls.Client` for the TLS mode Deez needs:

- the MongoDB server presents a certificate;
- Bongo verifies the server certificate chain;
- Bongo verifies the requested host name;
- the client does **not** present a client certificate;
- MongoDB authentication happens after TLS with SCRAM-SHA-256 or SCRAM-SHA-1.

Zig 0.16.0 has two relevant standard-library gaps Bongo must account for:

1. `std.crypto.tls.Client` does not expose the client-certificate/private-key handshake support needed for mutual TLS and end-to-end `MONGODB-X509`.
2. `std.Io.Threaded` on POSIX exposes connect-timeout options but `netConnectIpPosix` panics when the timeout is non-none because that implementation is still a TODO.

The first limitation does **not** block Deez because Deez uses SCRAM over server-authenticated TLS. The second is worked around inside Bongo by racing an ordinary timeout-free connect against an `Io.Select` awake-clock deadline.

## Environment where the gaps were reproduced

The release/dependency gates exposed the problems with:

```text
Zig: 0.16.0
Homebrew install seen locally: /opt/homebrew/Cellar/zig/0.16.0_1
CI: Zig 0.16.0 x86_64 Linux
MongoDB fixture: mongo:latest
TLS client: std.crypto.tls.Client
I/O backend: std.Io.Threaded
```

The original TLS-handshake investigation returned:

```text
error.TlsUnexpectedMessage
```

The first Bongo cleanup implementation then obscured that error with a second bug: both the local socket cleanup and the heap-owned TLS connection cleanup closed the same file descriptor, causing Zig's debug `Io.Threaded` backend to abort on `BADF`. Bongo's TLS implementation now keeps exactly one cleanup owner at every point in `connect`.

When the live TLS fixture subsequently exercised `connectTimeoutMS` on Linux, Zig 0.16.0 aborted with the exact standard-library panic:

```text
panic: TODO implement netConnectIpPosix with timeout
std/Io/Threaded.zig: netConnectIpPosix
```

That panic occurs before the TLS handshake. It is independent of MongoDB and independent of certificate validation.

## What Zig 0.16.0 provides

The final Zig 0.16.0 `std.crypto.tls.Client.Options` used by Bongo includes:

- host verification (`host`);
- CA verification (`ca`);
- caller-owned read/write buffers;
- caller-provided cryptographic entropy;
- current wall-clock time;
- normal TLS 1.2/1.3 client handshakes.

For CA-bundle verification, Zig 0.16.0 expects a context containing the allocator, `std.Io`, an `std.Io.RwLock`, and a pointer to `Certificate.Bundle`. The final 0.16.0 client also requires 240 bytes of handshake entropy.

Zig 0.16.0's networking API also models connection timeouts through `Io.net` connect options. Bongo cannot directly rely on that option on the Threaded POSIX backend because the backend implementation panics for a non-none timeout.

Bongo intentionally treats the installed/final Zig 0.16.0 standard library as authoritative rather than relying on pre-release 0.16 snapshots, because those snapshots used different TLS and I/O API shapes.

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

### 3. POSIX `Io.Threaded` connect timeout is not implemented

Zig 0.16.0 lets callers pass a timeout to `Io.net` connection APIs, but the Threaded POSIX implementation contains an explicit panic when that timeout reaches `netConnectIpPosix`:

```text
TODO implement netConnectIpPosix with timeout
```

Bongo must not pass MongoDB `connectTimeoutMS` directly through that unfinished path.

Bongo's workaround lives in `src/mongo/connect_timeout.zig`:

```text
HostName.connect(... timeout = none)
        |                    awake-clock deadline
        +---------- Io.Select ----------+
```

If the connection wins, Bongo returns the stream. If the timer wins, the connect task is cancelled/discarded and Bongo returns `ConnectTimeout`. Both plain TCP and TLS transports use this helper, so callers get the same behavior on Zig 0.16.0 without a stdlib panic.

This workaround should be removable once the Zig version Bongo targets implements POSIX connect timeouts natively.

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

Current MongoDB server versions require a CA trust source when TLS is enabled. Bongo's live fixture therefore supplies its generated CA certificate to `mongod` and also sets `tlsAllowConnectionsWithoutCertificates`. That keeps TLS certificate validation enabled while allowing the Bongo client to authenticate with SCRAM rather than presenting a client certificate.

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
- `connectTimeoutMS` is implemented by Bongo's own `Io.Select` deadline race on Zig 0.16 rather than passed to the unfinished POSIX stdlib timeout path.

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

Two independent contributions would remove Bongo workarounds/limitations:

### TLS client certificates

A future Zig contribution should add general client-certificate support to `std.crypto.tls.Client`; it should not be MongoDB-specific. A useful design would cover:

- optional client certificate chain;
- signing/private-key callback or explicit supported private-key types;
- TLS 1.2 and TLS 1.3 `CertificateRequest` handling;
- empty-certificate response when no certificate is configured and the server permits it;
- `CertificateVerify` generation;
- tests against a TLS server that optionally requests and one that requires client certificates.

### Threaded POSIX connect timeouts

`std.Io.Threaded` should implement the timeout case in `netConnectIpPosix` rather than panicking. A useful upstream test should cover successful connection before deadline, timeout to an unreachable endpoint, cancellation, and resource cleanup.

Until client-certificate support exists in a Zig release Bongo supports, Bongo may either keep MONGODB-X509 transport unsupported or provide a separately maintained TLS backend. Deez does not need that work to proceed.

## Release acceptance tests

The Bongo TLS gate for Deez is:

```bash
bash ./scripts/start-tls-db.sh
zig build tls-integration-test
```

The test must prove all of the following in one run:

1. the TCP connect deadline does not enter Zig 0.16's unfinished POSIX timeout path;
2. the TLS handshake completes against real `mongod`;
3. Bongo trusts only the generated fixture certificate via `tlsCAFile`;
4. host-name verification succeeds for `localhost`;
5. SCRAM-SHA-256 authenticates across the TLS transport;
6. a MongoDB `hello` command succeeds after authentication.

The transaction gate is:

```bash
bash ./scripts/start-replica-db.sh
zig build runtime-integration-test
```

A separate future mTLS/X.509 test should remain expected to fail or disabled until Zig/Bongo gains client-certificate support.
