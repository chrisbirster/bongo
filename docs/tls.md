# TLS connections

Bongo provides a TLS MongoDB transport backed by Zig's `std.crypto.tls.Client`.

```zig
var options = try bongo.parseConnectionOptions(
    allocator,
    "mongodb://db.example:27017/?tls=true",
);
defer options.deinit();

const tls_options = try bongo.TlsOptions.fromConnectionOptions(options);
var connection = try bongo.TlsConnection.connect(
    io,
    allocator,
    options.hosts[0].name,
    options.hosts[0].port,
    tls_options,
);
defer connection.deinit();
```

By default Bongo verifies both the server certificate chain and the requested host name. When no `tlsCAFile` is configured, the TLS transport loads the operating system trust roots. A custom CA file may be supplied with `tlsCAFile`; the current Zig 0.16 certificate API requires that path to be absolute.

The MongoDB URI verification controls map as follows:

- `tlsInsecure=true` disables both certificate and host-name verification.
- `tlsAllowInvalidCertificates=true` disables certificate-chain verification.
- `tlsAllowInvalidHostnames=true` disables host-name verification while keeping certificate-chain validation enabled.

Bongo never silently ignores client-certificate options. Zig 0.16's standard TLS client does not expose a client-certificate hook, so `TlsConnection.connect` returns `ClientCertificateUnsupported` when a client certificate/key is supplied. MONGODB-X509 therefore has a separate explicit transport boundary rather than pretending mutual TLS was established.

## Local integration fixture

A TLS-enabled MongoDB fixture can be started and tested with:

```bash
./scripts/start-tls-db.sh
zig build tls-integration-test
```

TLS is kept in a dedicated build step so the normal `zig build integration-test` suite only requires the standard MongoDB fixture on `127.0.0.1:27017`.

The TLS fixture uses a short-lived self-signed certificate and listens on `localhost:27018`. The integration test deliberately disables verification for that generated certificate; normal deployments should leave both verification controls enabled or provide a trusted `tlsCAFile`.
