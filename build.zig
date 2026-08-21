const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.16's std.crypto.tls.Client rejects a TLS CertificateRequest when
    // the application has no client certificate, even though TLS 1.2/1.3
    // define an empty Certificate response for that case. Generate a narrowly
    // patched copy from the *active compiler's* stdlib source. Nothing in the
    // Zig installation is modified. See docs/zig-0.16-tls-gap.md.
    const zig_tls_client_path = b.graph.zig_lib_directory.join(
        b.allocator,
        &.{ "std", "crypto", "tls", "Client.zig" },
    ) catch @panic("unable to resolve Zig stdlib TLS client path");
    const generate_tls_client = b.addSystemCommand(&.{"python3"});
    generate_tls_client.addFileArg(b.path("tools/vendor_zig_0_16_tls_client.py"));
    generate_tls_client.addArg(zig_tls_client_path);
    const patched_tls_source = generate_tls_client.addOutputFileArg(
        "zig_0_16_tls_client.zig",
    );
    const patched_tls_module = b.createModule(.{
        .root_source_file = patched_tls_source,
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("bongo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("bongo_zig_tls_client", patched_tls_module);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bongo", .module = mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step(
        "integration-test",
        "Run MongoDB integration tests",
    );
    integration_test_step.dependOn(&run_integration_tests.step);

    const tls_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration/41_tls.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bongo", .module = mod },
            },
        }),
    });
    const run_tls_integration_tests = b.addRunArtifact(tls_integration_tests);
    const tls_integration_test_step = b.step(
        "tls-integration-test",
        "Run verified MongoDB TLS + SCRAM integration test",
    );
    tls_integration_test_step.dependOn(&run_tls_integration_tests.step);

    const runtime_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration/42_runtime_transaction.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bongo", .module = mod },
            },
        }),
    });
    const run_runtime_integration_tests = b.addRunArtifact(runtime_integration_tests);
    const runtime_integration_test_step = b.step(
        "runtime-integration-test",
        "Run runtime-client session and transaction integration tests",
    );
    runtime_integration_test_step.dependOn(&run_runtime_integration_tests.step);

    const cmap_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration/43_cmap.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bongo", .module = mod },
            },
        }),
    });
    const run_cmap_integration_tests = b.addRunArtifact(cmap_integration_tests);
    const cmap_integration_test_step = b.step(
        "cmap-integration-test",
        "Run CMAP pool lifecycle integration tests",
    );
    cmap_integration_test_step.dependOn(&run_cmap_integration_tests.step);

    const spec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/spec.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bongo", .module = mod },
            },
        }),
    });
    const run_spec_tests = b.addRunArtifact(spec_tests);
    const spec_test_step = b.step(
        "spec-test",
        "Run MongoDB specification harness tests",
    );
    spec_test_step.dependOn(&run_spec_tests.step);

    // Compile the Deez-facing surface through the build graph rather than
    // invoking `zig test src/deez_readiness.zig` directly. That direct command
    // bypasses this build file and therefore cannot see the patched Zig 0.16
    // TLS client module imported by tls_connection.zig.
    const deez_readiness_module = b.createModule(.{
        .root_source_file = b.path("src/deez_readiness.zig"),
        .target = target,
        .optimize = optimize,
    });
    deez_readiness_module.addImport("bongo_zig_tls_client", patched_tls_module);
    const deez_readiness_tests = b.addTest(.{
        .root_module = deez_readiness_module,
    });
    const run_deez_readiness_tests = b.addRunArtifact(deez_readiness_tests);
    const deez_readiness_step = b.step(
        "deez-readiness-test",
        "Compile and test the Deez-facing Bongo surface",
    );
    deez_readiness_step.dependOn(&run_deez_readiness_tests.step);

    const exe = b.addExecutable(.{
        .name = "bongo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bongo", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
