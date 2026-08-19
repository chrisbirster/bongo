# `mongodb+srv` discovery

Bongo can resolve an SRV connection string into the same owned option model used by normal `mongodb://` parsing:

```zig
var options = try bongo.resolveSrvConnectionOptions(
    io,
    allocator,
    "mongodb+srv://alice:secret@cluster.example/app",
);
defer options.deinit();
```

Resolution happens before a MongoDB connection is attempted. Bongo queries `_{srvServiceName}._tcp.<host>` for SRV records and the original host for TXT defaults, validates every returned SRV target against the original parent domain, and returns normalized hosts with their discovered ports.

The implementation follows MongoDB's Initial DNS Seedlist Discovery rules:

- SRV URIs contain exactly one hostname and no explicit port.
- `srvServiceName` defaults to `mongodb`.
- `srvMaxHosts` selects a random subset when it is positive and smaller than the discovered seed list.
- TXT records may provide only `authSource`, `replicaSet`, and `loadBalanced` defaults.
- Explicit URI options override TXT defaults.
- SRV implicitly enables TLS unless the URI explicitly sets `tls`/`ssl`.
- Positive `srvMaxHosts` is incompatible with `replicaSet` and `loadBalanced=true`.
- Returned SRV hostnames must satisfy MongoDB's parent-domain security check before they are exposed to the client layer.

The resolver uses the system DNS configuration exposed by Zig's `std.Io.net.HostName.ResolvConf` and sends bounded UDP DNS queries to the configured name servers. DNS failures, malformed replies, missing SRV records, multiple TXT records, and invalid TXT keys are surfaced as errors rather than silently producing an unusable seed list.

Bongo v0.3 still uses one connection per `Client`; connection pooling and topology-aware server selection are later milestones. The SRV result nevertheless feeds directly into `NormalizedConnectionOptions.hosts`, which is the input those later topology layers will consume.
