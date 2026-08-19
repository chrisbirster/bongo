# Wire compression

Bongo v0.3 implements MongoDB `OP_COMPRESSED` with the zlib codec.

The authentication handshake advertises `compression: ["zlib"]`. If the server returns zlib in its compression intersection, Bongo records that selection but does not enable it until SCRAM authentication is complete. Hello, speculative authentication, `saslStart`, and `saslContinue` therefore remain uncompressed as required by the MongoDB compression specification.

After authentication, normal `Connection.request` calls automatically:

1. compress the original wire-message body (everything after the 16-byte MongoDB header),
2. wrap it in opcode `2012` (`OP_COMPRESSED`), and
3. transparently decode compressed responses back into the original MongoDB wire-message shape before higher-level code sees them.

The decoder validates the wrapper length, original opcode, advertised uncompressed size, compressor id, and Bongo's defensive maximum message size before allocating the reconstructed message.

Bongo's URI layer already recognizes `snappy`, `zlib`, and `zstd` names. In v0.3 only zlib has an in-tree wire codec, so only zlib is advertised and selected. Additional codecs can be added without changing `Connection`'s framing contract.

The existing auth-handshake integration test authenticates against the local MongoDB fixture, asserts that zlib was negotiated, and then sends a ping through the compressed request path.
