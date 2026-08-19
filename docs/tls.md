# TLS configuration

Bongo v0.3 parses and validates MongoDB TLS connection-string options, but it does **not** ship a built-in TLS transport.

The URI/configuration layer recognizes settings such as `tls`, `ssl`, `tlsCAFile`, `tlsCertificateKeyFile`, `tlsCertificateKeyFilePassword`, `tlsInsecure`, `tlsAllowInvalidCertificates`, and `tlsAllowInvalidHostnames`. Keeping these fields in the normalized connection options preserves the MongoDB connection-string model and avoids an API change when runtime TLS support is added.

## Runtime transport status

Runtime TLS remains tracked by BONGO-0042.

Release validation against a TLS-enabled `mongod` exposed a limitation in Zig 0.16's `std.crypto.tls.Client` handshake path. MongoDB configures its server TLS context to request a peer/client certificate when a CA is configured. Zig 0.16's standard TLS client does not provide the client-certificate handshake support Bongo needs for that MongoDB exchange, and the handshake returns `TlsUnexpectedMessage` before any MongoDB wire message is sent.

Because the transport cannot currently complete a real MongoDB TLS handshake reliably, v0.3 does not expose `TlsConnection` or claim runtime TLS support. Bongo will add TLS transport support when it can be validated end-to-end against MongoDB rather than shipping a partially working abstraction.

## X.509

MONGODB-X509 command/configuration support remains available separately. The authentication command is generic over a request-capable secure transport, but end-to-end X.509 still requires a TLS implementation that can present a client certificate.
