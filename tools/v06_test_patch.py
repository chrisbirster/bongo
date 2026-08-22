#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: str, old: str, new: str) -> None:
    p = ROOT / path
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one anchor, found {count}: {old[:100]!r}")
    p.write_text(text.replace(old, new, 1))


def replace_count(path: str, old: str, new: str, expected: int) -> None:
    p = ROOT / path
    text = p.read_text()
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{path}: expected {expected} anchors, found {count}: {old[:100]!r}")
    p.write_text(text.replace(old, new))


# Preserve original network/transport errors. Only server responses that carry
# retry semantics use the internal RetryableWrite sentinel.
replace_count(
    "src/mongo/runtime_client_core.zig",
    '''        const response = self.requestCheckedOut(&transport, request) catch |err| {\n            if (error_response.isRetryableTransportError(err)) return error.RetryableWrite;\n            return err;\n        };''',
    '''        const response = self.requestCheckedOut(&transport, request) catch |err| {\n            return err;\n        };''',
    4,
)

# RetryableWriteError may accompany an ok:1 command with a writeConcernError.
replace_once(
    "src/mongo/error_response.zig",
    '''    pub fn retryableWrite(self: Status) bool {\n        if (self.ok) return false;\n        return self.retryable_write or self.retryable_error;\n    }''',
    '''    pub fn retryableWrite(self: Status) bool {\n        return self.retryable_write or self.retryable_error;\n    }''',
)

# Replica sets are the v0.6 supported retry deployment. Sharded and
# load-balanced modes remain explicitly deferred.
replace_once(
    "src/mongo/runtime_client.zig",
    '''        return switch (self.topologyType()) {\n            .replica_set_no_primary, .replica_set_with_primary, .sharded, .load_balanced => true,\n            .unknown, .single => false,\n        };''',
    '''        return switch (self.topologyType()) {\n            .replica_set_no_primary, .replica_set_with_primary => true,\n            .unknown, .single, .sharded, .load_balanced => false,\n        };''',
)
replace_count(
    "src/mongo/runtime_client.zig",
    '''                if (err == error.RetryableWrite and !retried) {\n                    retried = true;\n                    continue;\n                }\n                return err;''',
    '''                if (isRetryableWriteFailure(err) and !retried) {\n                    retried = true;\n                    continue;\n                }\n                if (err == error.RetryableWrite) return error.CommandFailed;\n                return err;''',
    4,
)
replace_once(
    "src/mongo/runtime_client.zig",
    '''fn isRetryableReadFailure(err: anyerror) bool {\n    return err == error.RetryableRead or error_response.isRetryableTransportError(err);\n}''',
    '''fn isRetryableReadFailure(err: anyerror) bool {\n    return err == error.RetryableRead or error_response.isRetryableTransportError(err);\n}\n\nfn isRetryableWriteFailure(err: anyerror) bool {\n    return err == error.RetryableWrite or error_response.isRetryableTransportError(err);\n}''',
)

# Pool methods require a mutable server-pool receiver.
replace_once(
    "src/mongo/runtime_read.zig",
    '''        for (self.pools.items) |server_pool| {\n            server_pool.pool.clear() catch {};\n            server_pool.pool.ready() catch {};\n        }''',
    '''        for (self.pools.items) |*server_pool| {\n            server_pool.pool.clear() catch {};\n            server_pool.pool.ready() catch {};\n        }''',
)

# failCommand is a MongoDB test command and must be explicitly enabled on the
# live three-member fixture.
replace_once(
    "scripts/ensure-mongo-fixture.sh",
    'FIXTURE_VERSION="2"',
    'FIXTURE_VERSION="3"',
)
replace_count(
    "scripts/ensure-mongo-fixture.sh",
    '--bind_ip_all --fork --logpath',
    '--bind_ip_all --setParameter enableTestCommands=1 --fork --logpath',
    3,
)

# Register retryability and deterministic malformed-input gates.
replace_once(
    "build.zig",
    '''    const spec_tests = b.addTest(.{''',
    '''    const retryability_integration_tests = b.addTest(.{\n        .root_module = b.createModule(.{\n            .root_source_file = b.path("test/integration/45_retryability.zig"),\n            .target = target,\n            .optimize = optimize,\n            .imports = &.{ .{ .name = "bongo", .module = mod } },\n        }),\n    });\n    const run_retryability_integration_tests = b.addRunArtifact(retryability_integration_tests);\n    const retryability_integration_test_step = b.step(\n        "retryability-integration-test",\n        "Run retryable reads, writes, and transaction commit integration tests",\n    );\n    retryability_integration_test_step.dependOn(&run_retryability_integration_tests.step);\n\n    const spec_tests = b.addTest(.{''',
)
replace_once(
    "build.zig",
    '''    const deez_readiness_module = b.createModule(.{''',
    '''    const fuzz_tests = b.addTest(.{\n        .root_module = b.createModule(.{\n            .root_source_file = b.path("test/fuzz.zig"),\n            .target = target,\n            .optimize = optimize,\n            .imports = &.{ .{ .name = "bongo", .module = mod } },\n        }),\n    });\n    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);\n    const fuzz_test_step = b.step("fuzz-test", "Run deterministic malformed-wire stress tests");\n    fuzz_test_step.dependOn(&run_fuzz_tests.step);\n\n    const deez_readiness_module = b.createModule(.{''',
)

replace_once(
    "Makefile",
    '\tsdam-integration-test \\\n\tdeez-readiness-test \\',
    '\tsdam-integration-test \\\n\tretryability-integration-test \\\n\tfuzz-test \\\n\tdeez-readiness-test \\',
)
replace_once(
    "Makefile",
    "\t\t'make sdam-integration-test    Run 3-member SDAM discovery/failover tests' \\\n\t\t'make deez-readiness-test      Test the Deez-facing API surface' \\",
    "\t\t'make sdam-integration-test    Run 3-member SDAM discovery/failover tests' \\\n\t\t'make retryability-integration-test Run retryable read/write/commit tests' \\\n\t\t'make fuzz-test                Run deterministic malformed-wire stress tests' \\\n\t\t'make deez-readiness-test      Test the Deez-facing API surface' \\",
)
replace_once(
    "Makefile",
    '''\t@$(MAKE) sdam-integration-test\n\t@$(MAKE) deez-readiness-test''',
    '''\t@$(MAKE) sdam-integration-test\n\t@$(MAKE) retryability-integration-test\n\t@$(MAKE) fuzz-test\n\t@$(MAKE) deez-readiness-test''',
)
replace_once(
    "Makefile",
    '''sdam-integration-test:\n\t@./scripts/ensure-mongo-fixture.sh sdam\n\tzig build sdam-integration-test\n\ndeez-readiness-test:''',
    '''sdam-integration-test:\n\t@./scripts/ensure-mongo-fixture.sh sdam\n\tzig build sdam-integration-test\n\nretryability-integration-test:\n\t@./scripts/ensure-mongo-fixture.sh sdam\n\tzig build retryability-integration-test\n\nfuzz-test:\n\tzig build fuzz-test\n\ndeez-readiness-test:''',
)

# The upstream-backed retry suites are now first-class supported harness inputs.
replace_once(
    "test/spec.zig",
    '''    .{ .name = "sdam", .disposition = .local_bridge, .note = "Local topology/read-selection bridge is present; upstream fixture ingestion is still incremental." },\n};''',
    '''    .{ .name = "sdam", .disposition = .local_bridge, .note = "Local topology/read-selection bridge is present; upstream fixture ingestion is still incremental." },\n    .{ .name = "retryable-reads", .disposition = .supported, .note = "Pinned upstream find-serverErrors fixture drives the v0.6 supported retry subset." },\n    .{ .name = "retryable-writes", .disposition = .supported, .note = "Pinned upstream insertOne fixture drives the v0.6 supported retry subset." },\n};''',
)
replace_once(
    "test/spec.zig",
    '''    try std.testing.expectEqual(@as(usize, 6), suites.len);\n    try std.testing.expectEqual(@as(usize, 4), supported);\n    try std.testing.expectEqual(@as(usize, 2), local_bridge);''',
    '''    try std.testing.expectEqual(@as(usize, 8), suites.len);\n    try std.testing.expectEqual(@as(usize, 6), supported);\n    try std.testing.expectEqual(@as(usize, 2), local_bridge);''',
)

print("v0.6 validation/retry hardening patch applied")
