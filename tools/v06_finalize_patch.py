#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def ensure_replace(path: str, old: str, new: str, expected: int = 1) -> None:
    p = ROOT / path
    text = p.read_text()
    if new in text:
        return
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{path}: expected {expected} anchor(s), found {count}: {old[:100]!r}")
    if expected == 1:
        text = text.replace(old, new, 1)
    else:
        text = text.replace(old, new)
    p.write_text(text)


def ensure_append(path: str, addition: str) -> None:
    p = ROOT / path
    text = p.read_text()
    if addition.strip() in text:
        return
    if not text.endswith("\n"):
        text += "\n"
    p.write_text(text + addition)


# Repair the original bootstrap's accidentally escaped fixture-test block.
p = ROOT / "test/spec.zig"
text = p.read_text()
bad_start = '\\ntest "pinned upstream retryable read fixture is executable input"'
if bad_start in text:
    start = text.index(bad_start)
    end_marker = 'const bongo = @import("bongo");'
    end = text.index(end_marker, start)
    text = text[:start] + "\n" + text[end:]
    p.write_text(text)

# Preserve transport errors. Server retry labels use RetryableWrite internally;
# network errors remain inspectable if the second attempt also fails.
ensure_replace(
    "src/mongo/runtime_client_core.zig",
    '''        const response = self.requestCheckedOut(&transport, request) catch |err| {\n            if (error_response.isRetryableTransportError(err)) return error.RetryableWrite;\n            return err;\n        };''',
    '''        const response = self.requestCheckedOut(&transport, request) catch |err| {\n            return err;\n        };''',
    expected=4,
)

ensure_replace(
    "src/mongo/error_response.zig",
    '''    pub fn retryableWrite(self: Status) bool {\n        if (self.ok) return false;\n        return self.retryable_write or self.retryable_error;\n    }''',
    '''    pub fn retryableWrite(self: Status) bool {\n        return self.retryable_write or self.retryable_error;\n    }''',
)

# v0.6 retry support is intentionally replica-set scoped.
ensure_replace(
    "src/mongo/runtime_client.zig",
    '''        return switch (self.topologyType()) {\n            .replica_set_no_primary, .replica_set_with_primary, .sharded, .load_balanced => true,\n            .unknown, .single => false,\n        };''',
    '''        return switch (self.topologyType()) {\n            .replica_set_no_primary, .replica_set_with_primary => true,\n            .unknown, .single, .sharded, .load_balanced => false,\n        };''',
)
ensure_replace(
    "src/mongo/runtime_client.zig",
    '''                if (err == error.RetryableWrite and !retried) {\n                    retried = true;\n                    continue;\n                }\n                return err;''',
    '''                if (isRetryableWriteFailure(err) and !retried) {\n                    retried = true;\n                    continue;\n                }\n                if (err == error.RetryableWrite) return error.CommandFailed;\n                return err;''',
    expected=4,
)
ensure_replace(
    "src/mongo/runtime_client.zig",
    '''fn isRetryableReadFailure(err: anyerror) bool {\n    return err == error.RetryableRead or error_response.isRetryableTransportError(err);\n}''',
    '''fn isRetryableReadFailure(err: anyerror) bool {\n    return err == error.RetryableRead or error_response.isRetryableTransportError(err);\n}\n\nfn isRetryableWriteFailure(err: anyerror) bool {\n    return err == error.RetryableWrite or error_response.isRetryableTransportError(err);\n}''',
)

ensure_replace(
    "src/mongo/runtime_read.zig",
    '''        for (self.pools.items) |server_pool| {\n            server_pool.pool.clear() catch {};\n            server_pool.pool.ready() catch {};\n        }''',
    '''        for (self.pools.items) |*server_pool| {\n            server_pool.pool.clear() catch {};\n            server_pool.pool.ready() catch {};\n        }''',
)

# failCommand is a MongoDB test-only command.
ensure_replace(
    "scripts/ensure-mongo-fixture.sh",
    'FIXTURE_VERSION="2"',
    'FIXTURE_VERSION="3"',
)
ensure_replace(
    "scripts/ensure-mongo-fixture.sh",
    '--bind_ip_all --fork --logpath',
    '--bind_ip_all --setParameter enableTestCommands=1 --fork --logpath',
    expected=3,
)

# Build targets.
ensure_replace(
    "build.zig",
    '''    const spec_tests = b.addTest(.{''',
    '''    const retryability_integration_tests = b.addTest(.{\n        .root_module = b.createModule(.{\n            .root_source_file = b.path("test/integration/45_retryability.zig"),\n            .target = target,\n            .optimize = optimize,\n            .imports = &.{ .{ .name = "bongo", .module = mod } },\n        }),\n    });\n    const run_retryability_integration_tests = b.addRunArtifact(retryability_integration_tests);\n    const retryability_integration_test_step = b.step(\n        "retryability-integration-test",\n        "Run retryable reads, writes, and transaction commit integration tests",\n    );\n    retryability_integration_test_step.dependOn(&run_retryability_integration_tests.step);\n\n    const spec_tests = b.addTest(.{''',
)
ensure_replace(
    "build.zig",
    '''    const deez_readiness_module = b.createModule(.{''',
    '''    const fuzz_tests = b.addTest(.{\n        .root_module = b.createModule(.{\n            .root_source_file = b.path("test/fuzz.zig"),\n            .target = target,\n            .optimize = optimize,\n            .imports = &.{ .{ .name = "bongo", .module = mod } },\n        }),\n    });\n    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);\n    const fuzz_test_step = b.step("fuzz-test", "Run deterministic malformed-wire stress tests");\n    fuzz_test_step.dependOn(&run_fuzz_tests.step);\n\n    const deez_readiness_module = b.createModule(.{''',
)

# Makefile complete gate.
ensure_replace(
    "Makefile",
    '\tsdam-integration-test \\\n\tdeez-readiness-test \\',
    '\tsdam-integration-test \\\n\tretryability-integration-test \\\n\tfuzz-test \\\n\tdeez-readiness-test \\',
)
ensure_replace(
    "Makefile",
    "\t\t'make sdam-integration-test    Run 3-member SDAM discovery/failover tests' \\\n\t\t'make deez-readiness-test      Test the Deez-facing API surface' \\",
    "\t\t'make sdam-integration-test    Run 3-member SDAM discovery/failover tests' \\\n\t\t'make retryability-integration-test Run retryable read/write/commit tests' \\\n\t\t'make fuzz-test                Run deterministic malformed-wire stress tests' \\\n\t\t'make deez-readiness-test      Test the Deez-facing API surface' \\",
)
ensure_replace(
    "Makefile",
    '''\t@$(MAKE) sdam-integration-test\n\t@$(MAKE) deez-readiness-test''',
    '''\t@$(MAKE) sdam-integration-test\n\t@$(MAKE) retryability-integration-test\n\t@$(MAKE) fuzz-test\n\t@$(MAKE) deez-readiness-test''',
)
ensure_replace(
    "Makefile",
    '''sdam-integration-test:\n\t@./scripts/ensure-mongo-fixture.sh sdam\n\tzig build sdam-integration-test\n\ndeez-readiness-test:''',
    '''sdam-integration-test:\n\t@./scripts/ensure-mongo-fixture.sh sdam\n\tzig build sdam-integration-test\n\nretryability-integration-test:\n\t@./scripts/ensure-mongo-fixture.sh sdam\n\tzig build retryability-integration-test\n\nfuzz-test:\n\tzig build fuzz-test\n\ndeez-readiness-test:''',
)

# Honest upstream-backed harness accounting.
ensure_replace(
    "test/spec.zig",
    '''    .{\n        .name = "sdam",\n        .disposition = .local_bridge,\n        .reason = "SDAM discovery, selection, RTT window and failover are gated locally; full upstream fixture ingestion remains incremental",\n    },\n};''',
    '''    .{\n        .name = "sdam",\n        .disposition = .local_bridge,\n        .reason = "SDAM discovery, selection, RTT window and failover are gated locally; full upstream fixture ingestion remains incremental",\n    },\n    .{ .name = "retryable-reads", .disposition = .supported },\n    .{ .name = "retryable-writes", .disposition = .supported },\n};''',
)
ensure_replace(
    "test/spec.zig",
    '''    try std.testing.expectEqual(@as(usize, 6), suites.len);\n    try std.testing.expectEqual(@as(usize, 4), dispositionCount(.supported));''',
    '''    try std.testing.expectEqual(@as(usize, 8), suites.len);\n    try std.testing.expectEqual(@as(usize, 6), dispositionCount(.supported));''',
)

fixture_tests = r'''test "pinned upstream retryable read fixture is executable input" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        upstream_retryable_reads,
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("find-serverErrors", root.get("description").?.string);
    const tests = root.get("tests").?.array.items;
    var found_shutdown = false;
    var found_not_primary = false;
    for (tests) |case| {
        const description = case.object.get("description").?.string;
        if (std.mem.indexOf(u8, description, "ShutdownInProgress") != null) found_shutdown = true;
        if (std.mem.indexOf(u8, description, "NotWritablePrimary") != null) found_not_primary = true;
    }
    try std.testing.expect(found_shutdown);
    try std.testing.expect(found_not_primary);
}

test "pinned upstream retryable write fixture is executable input" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        upstream_retryable_writes,
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("insertOne", root.get("description").?.string);
    try std.testing.expect(root.get("tests").?.array.items.len > 0);
}
'''
ensure_append("test/spec.zig", fixture_tests)

print("v0.6 final validation patch applied")
