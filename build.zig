const std = @import("std");
const workspace = @import("contracts/v1_workspace_graph.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const boundary = b.createModule(.{
        .root_source_file = b.path("contracts/v1_module_boundary.zig"),
        .target = target,
        .optimize = optimize,
    });
    const workspace_graph = b.createModule(.{
        .root_source_file = b.path("contracts/v1_workspace_graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_spec = workspace.package(.core);
    const protocol_spec = workspace.package(.protocol);
    const transport_spec = workspace.package(.transport);
    const topology_spec = workspace.package(.topology);
    const state_spec = workspace.package(.state);
    const runtime_spec = workspace.package(.runtime);
    const c_abi_spec = workspace.package(.c_abi);
    const optional_reference_spec = workspace.package(.optional_reference);
    const networking_spec = workspace.package(.networking);
    const services_spec = workspace.package(.services);
    var workspace_modules: [workspace.packages.len]?*std.Build.Module = .{null} ** workspace.packages.len;
    const core = b.createModule(.{
        .root_source_file = b.path(core_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = workspace.moduleImports(b, .core, &workspace_modules),
    });
    workspace_modules[workspace.moduleSlot(.core)] = core;
    const protocol = b.createModule(.{
        .root_source_file = b.path(protocol_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = workspace.moduleImports(b, .protocol, &workspace_modules),
    });
    workspace_modules[workspace.moduleSlot(.protocol)] = protocol;
    const transport = b.createModule(.{
        .root_source_file = b.path(transport_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = workspace.moduleImports(b, .transport, &workspace_modules),
    });
    workspace_modules[workspace.moduleSlot(.transport)] = transport;
    const topology = b.createModule(.{
        .root_source_file = b.path(topology_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = workspace.moduleImports(b, .topology, &workspace_modules),
    });
    workspace_modules[workspace.moduleSlot(.topology)] = topology;
    const state = b.createModule(.{
        .root_source_file = b.path(state_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = workspace.moduleImports(b, .state, &workspace_modules),
    });
    workspace_modules[workspace.moduleSlot(.state)] = state;
    const runtime = b.createModule(.{
        .root_source_file = b.path(runtime_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = workspace.moduleImports(b, .runtime, &workspace_modules),
    });
    workspace_modules[workspace.moduleSlot(.runtime)] = runtime;
    const c_abi = b.createModule(.{
        .root_source_file = b.path(c_abi_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = workspace.moduleImports(b, .c_abi, &workspace_modules),
    });
    workspace_modules[workspace.moduleSlot(.c_abi)] = c_abi;
    const optional_reference = b.createModule(.{
        .root_source_file = b.path(optional_reference_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = workspace.moduleImports(b, .optional_reference, &workspace_modules),
    });
    workspace_modules[workspace.moduleSlot(.optional_reference)] = optional_reference;
    const public_api = b.createModule(.{
        .root_source_file = b.path("contracts/v1_public_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = protocol_spec.module_name, .module = protocol },
            .{ .name = transport_spec.module_name, .module = transport },
            .{ .name = topology_spec.module_name, .module = topology },
            .{ .name = state_spec.module_name, .module = state },
            .{ .name = runtime_spec.module_name, .module = runtime },
            .{ .name = c_abi_spec.module_name, .module = c_abi },
        },
    });
    const compatibility = b.createModule(.{
        .root_source_file = b.path("contracts/v1_compatibility.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = protocol_spec.module_name, .module = protocol }},
    });
    const naming = b.createModule(.{
        .root_source_file = b.path("contracts/v1_naming.zig"),
        .target = target,
        .optimize = optimize,
    });
    const networking = b.createModule(.{
        .root_source_file = b.path(networking_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = workspace.moduleImports(b, .networking, &workspace_modules),
    });
    workspace_modules[workspace.moduleSlot(.networking)] = networking;
    const services = b.createModule(.{
        .root_source_file = b.path(services_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = workspace.moduleImports(b, .services, &workspace_modules),
    });
    workspace_modules[workspace.moduleSlot(.services)] = services;
    const test_harness = b.createModule(.{
        .root_source_file = b.path("contracts/test_harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = protocol_spec.module_name, .module = protocol },
            .{ .name = transport_spec.module_name, .module = transport },
            .{ .name = topology_spec.module_name, .module = topology },
            .{ .name = state_spec.module_name, .module = state },
            .{ .name = runtime_spec.module_name, .module = runtime },
            .{ .name = c_abi_spec.module_name, .module = c_abi },
        },
    });
    const stun_turn_interop = b.createModule(.{
        .root_source_file = b.path("contracts/stun_turn_interop.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = protocol_spec.module_name, .module = protocol },
            .{ .name = transport_spec.module_name, .module = transport },
            .{ .name = topology_spec.module_name, .module = topology },
        },
    });
    const benchmark_harness = b.createModule(.{
        .root_source_file = b.path("contracts/benchmark_harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = core_spec.module_name, .module = core }},
    });
    const benchmark_authoritative = b.createModule(.{
        .root_source_file = b.path("contracts/benchmark_authoritative.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = protocol_spec.module_name, .module = protocol },
            .{ .name = runtime_spec.module_name, .module = runtime },
        },
    });
    const benchmark_sharded_p2p = b.createModule(.{
        .root_source_file = b.path("contracts/benchmark_sharded_p2p.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = topology_spec.module_name, .module = topology },
        },
    });
    const benchmark_topology_faults = b.createModule(.{
        .root_source_file = b.path("contracts/benchmark_topology_faults.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = runtime_spec.module_name, .module = runtime },
            .{ .name = "minna-san-networking", .module = networking },
        },
    });
    const benchmark_throughput = b.createModule(.{
        .root_source_file = b.path("contracts/benchmark_throughput.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = protocol_spec.module_name, .module = protocol },
        },
    });
    const benchmark_memory = b.createModule(.{
        .root_source_file = b.path("contracts/benchmark_memory.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = protocol_spec.module_name, .module = protocol },
            .{ .name = topology_spec.module_name, .module = topology },
            .{ .name = runtime_spec.module_name, .module = runtime },
        },
    });
    const boundary_tests = b.addTest(.{ .root_module = boundary });
    const workspace_graph_tests = b.addTest(.{ .root_module = workspace_graph });
    const public_api_tests = b.addTest(.{ .root_module = public_api });
    const compatibility_tests = b.addTest(.{ .root_module = compatibility });
    const naming_tests = b.addTest(.{ .root_module = naming });
    const boundary_verifier = b.addExecutable(.{
        .name = "verify-forbidden-import",
        .root_module = b.createModule(.{
            .root_source_file = b.path("contracts/verify_forbidden_import.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const core_tests = b.addTest(.{ .root_module = core });
    const networking_tests = b.addTest(.{ .root_module = networking });
    const protocol_tests = b.addTest(.{ .root_module = protocol });
    const services_tests = b.addTest(.{ .root_module = services });
    const test_harness_tests = b.addTest(.{ .root_module = test_harness });
    const stun_turn_interop_tests = b.addTest(.{ .root_module = stun_turn_interop });
    const benchmark_harness_tests = b.addTest(.{ .root_module = benchmark_harness });
    const benchmark_harness_executable = b.addExecutable(.{ .name = "benchmark-harness", .root_module = benchmark_harness });
    const benchmark_authoritative_tests = b.addTest(.{ .root_module = benchmark_authoritative });
    const benchmark_authoritative_executable = b.addExecutable(.{ .name = "benchmark-authoritative", .root_module = benchmark_authoritative });
    const benchmark_sharded_p2p_tests = b.addTest(.{ .root_module = benchmark_sharded_p2p });
    const benchmark_sharded_p2p_executable = b.addExecutable(.{ .name = "benchmark-sharded-p2p", .root_module = benchmark_sharded_p2p });
    const benchmark_topology_faults_tests = b.addTest(.{ .root_module = benchmark_topology_faults });
    const benchmark_topology_faults_executable = b.addExecutable(.{ .name = "benchmark-topology-faults", .root_module = benchmark_topology_faults });
    const benchmark_throughput_tests = b.addTest(.{ .root_module = benchmark_throughput });
    const benchmark_throughput_executable = b.addExecutable(.{ .name = "benchmark-throughput", .root_module = benchmark_throughput });
    const benchmark_memory_tests = b.addTest(.{ .root_module = benchmark_memory });
    const benchmark_memory_executable = b.addExecutable(.{ .name = "benchmark-memory", .root_module = benchmark_memory });
    const state_tests = b.addTest(.{ .root_module = state });
    const topology_tests = b.addTest(.{ .root_module = topology });
    const transport_tests = b.addTest(.{ .root_module = transport });
    const runtime_tests = b.addTest(.{ .root_module = runtime });
    const c_abi_tests = b.addTest(.{ .root_module = c_abi });
    const c_abi_library = b.addLibrary(.{
        .linkage = .static,
        .name = "minna-san-c-abi-conformance",
        .root_module = c_abi,
    });
    const c_sdk_static = b.addLibrary(.{
        .linkage = .static,
        .name = "minna-san",
        .root_module = c_abi,
    });
    const c_sdk_shared = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "minna-san",
        .root_module = c_abi,
    });
    const install_c_sdk_static = b.addInstallArtifact(c_sdk_static, .{});
    const install_c_sdk_shared = b.addInstallArtifact(c_sdk_shared, .{});
    const c_abi_consumer = b.addExecutable(.{
        .name = "c-abi-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("contracts/c_abi_consumer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    c_abi_consumer.addCSourceFile(.{
        .file = b.path("contracts/fixtures/c_abi_consumer.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    c_abi_consumer.addIncludePath(b.path("packages/c-abi/include"));
    c_abi_consumer.linkLibrary(c_abi_library);
    c_abi_consumer.linkLibC();
    const optional_reference_tests = b.addTest(.{ .root_module = optional_reference });
    const run_boundary = b.addRunArtifact(boundary_tests);
    const run_workspace_graph = b.addRunArtifact(workspace_graph_tests);
    const run_public_api = b.addRunArtifact(public_api_tests);
    const run_compatibility = b.addRunArtifact(compatibility_tests);
    const run_naming = b.addRunArtifact(naming_tests);
    const run_boundary_verifier = b.addRunArtifact(boundary_verifier);
    run_boundary_verifier.setCwd(b.path("."));
    run_boundary_verifier.addArgs(&.{
        b.graph.zig_exe,
        "test",
        "--dep",
        "minna-san-core",
        "-Mroot=contracts/fixtures/forbidden_core_to_runtime.zig",
        "-Mminna-san-core=contracts/fixtures/allowed_core.zig",
    });
    const run_core = b.addRunArtifact(core_tests);
    const run_networking = b.addRunArtifact(networking_tests);
    const run_protocol = b.addRunArtifact(protocol_tests);
    const run_services = b.addRunArtifact(services_tests);
    const run_test_harness = b.addRunArtifact(test_harness_tests);
    const run_stun_turn_interop = b.addRunArtifact(stun_turn_interop_tests);
    const run_benchmark_harness_tests = b.addRunArtifact(benchmark_harness_tests);
    const run_benchmark_harness = b.addRunArtifact(benchmark_harness_executable);
    if (b.args) |args| run_benchmark_harness.addArgs(args);
    const run_benchmark_authoritative_tests = b.addRunArtifact(benchmark_authoritative_tests);
    const run_benchmark_authoritative = b.addRunArtifact(benchmark_authoritative_executable);
    const run_benchmark_sharded_p2p_tests = b.addRunArtifact(benchmark_sharded_p2p_tests);
    const run_benchmark_sharded_p2p = b.addRunArtifact(benchmark_sharded_p2p_executable);
    const run_benchmark_topology_faults_tests = b.addRunArtifact(benchmark_topology_faults_tests);
    const run_benchmark_topology_faults = b.addRunArtifact(benchmark_topology_faults_executable);
    const run_benchmark_throughput_tests = b.addRunArtifact(benchmark_throughput_tests);
    const run_benchmark_throughput = b.addRunArtifact(benchmark_throughput_executable);
    const run_benchmark_memory_tests = b.addRunArtifact(benchmark_memory_tests);
    const run_benchmark_memory = b.addRunArtifact(benchmark_memory_executable);
    const run_state = b.addRunArtifact(state_tests);
    const run_topology = b.addRunArtifact(topology_tests);
    const run_transport = b.addRunArtifact(transport_tests);
    const run_runtime = b.addRunArtifact(runtime_tests);
    const run_c_abi = b.addRunArtifact(c_abi_tests);
    const run_c_abi_consumer = b.addRunArtifact(c_abi_consumer);
    const run_optional_reference = b.addRunArtifact(optional_reference_tests);
    const boundary_step = b.step("contract", "Check the v1 module boundary");
    boundary_step.dependOn(&run_boundary.step);
    boundary_step.dependOn(&run_boundary_verifier.step);
    const workspace_step = b.step("workspace-graph", "Check the explicit v1 workspace graph");
    workspace_step.dependOn(&run_workspace_graph.step);
    const api_step = b.step("api-contract", "Check the stable v1 public API");
    api_step.dependOn(&run_public_api.step);
    const compatibility_step = b.step("compatibility-contract", "Check stable API and wire compatibility");
    compatibility_step.dependOn(&run_public_api.step);
    compatibility_step.dependOn(&run_compatibility.step);
    const quality_check = b.addSystemCommand(&.{ "sh", "script/check_quality.sh" });
    const quality_step = b.step("quality", "Check formatting and source quality without rewrites");
    quality_step.dependOn(&quality_check.step);
    const quality_test = b.addSystemCommand(&.{ "sh", "script/test_quality_gate.sh" });
    const quality_test_step = b.step("quality-test", "Test the non-mutating quality gate");
    quality_test_step.dependOn(&quality_test.step);
    const release_license_check = b.addSystemCommand(&.{ "sh", "script/check_release_license.sh" });
    const release_license_step = b.step("release-license", "Check BSL release metadata");
    release_license_step.dependOn(&release_license_check.step);
    const release_license_test = b.addSystemCommand(&.{ "sh", "script/test_release_license.sh" });
    const release_license_test_step = b.step("release-license-test", "Test BSL release metadata checks");
    release_license_test_step.dependOn(&release_license_test.step);
    const license_metadata_check = b.addSystemCommand(&.{ "sh", "script/check_license_metadata.sh" });
    const license_metadata_step = b.step("license-metadata", "Check BSL SPDX release metadata");
    license_metadata_step.dependOn(&license_metadata_check.step);
    const license_metadata_test = b.addSystemCommand(&.{ "sh", "script/test_license_metadata.sh" });
    const license_metadata_test_step = b.step("license-metadata-test", "Test BSL SPDX metadata checks");
    license_metadata_test_step.dependOn(&license_metadata_test.step);
    const contract_gate_check = b.addSystemCommand(&.{ "sh", "script/check_contract_gate.sh" });
    const contract_gate_step = b.step("contract-gate", "Check the pull request contract workflow");
    contract_gate_step.dependOn(&contract_gate_check.step);
    const contract_gate_test = b.addSystemCommand(&.{ "sh", "script/test_contract_gate.sh" });
    const contract_gate_test_step = b.step("contract-gate-test", "Test the pull request contract workflow checks");
    contract_gate_test_step.dependOn(&contract_gate_test.step);
    const public_api_regression_check = b.addSystemCommand(&.{ "sh", "script/check_public_api_regression.sh" });
    const public_api_regression_step = b.step("public-api-regression", "Check released Zig and C public API contracts");
    public_api_regression_step.dependOn(&public_api_regression_check.step);
    const public_api_regression_test = b.addSystemCommand(&.{ "sh", "script/test_public_api_regression.sh" });
    const public_api_regression_test_step = b.step("public-api-regression-test", "Test released public API contract checks");
    public_api_regression_test_step.dependOn(&public_api_regression_test.step);
    const pre_release_api_contract_test = b.addSystemCommand(&.{ "sh", "script/test_pre_release_api_contract.sh" });
    const pre_release_api_contract_test_step = b.step("pre-release-api-contract-test", "Test pre-release public API extensibility");
    pre_release_api_contract_test_step.dependOn(&pre_release_api_contract_test.step);
    const dependency_check = b.addSystemCommand(&.{ "sh", "script/check_stdlib_only.sh" });
    const dependency_step = b.step("dependency-policy", "Check v1 sources use only std and first-party modules");
    dependency_step.dependOn(&dependency_check.step);
    const dependency_test = b.addSystemCommand(&.{ "sh", "script/test_stdlib_only.sh" });
    const dependency_test_step = b.step("dependency-policy-test", "Test the v1 dependency policy");
    dependency_test_step.dependOn(&dependency_test.step);
    const hermetic_test = b.addSystemCommand(&.{ "sh", "script/test_hermetic_build.sh" });
    const hermetic_step = b.step("hermetic-test", "Test SDK builds with an empty environment");
    hermetic_step.dependOn(&hermetic_test.step);
    const reference_test_step = b.step("reference-test", "Test optional networking and services references");
    reference_test_step.dependOn(&run_networking.step);
    reference_test_step.dependOn(&run_services.step);
    const test_harness_step = b.step("test-harness", "Test deterministic SDK test fixtures");
    test_harness_step.dependOn(&run_test_harness.step);
    const stun_turn_interop_step = b.step("stun-turn-interop", "Run controlled STUN TURN interoperability fixtures");
    stun_turn_interop_step.dependOn(&run_stun_turn_interop.step);
    const benchmark_harness_step = b.step("benchmark-harness", "Run deterministic benchmark harness");
    benchmark_harness_step.dependOn(&run_benchmark_harness.step);
    const benchmark_harness_test_step = b.step("benchmark-harness-test", "Test deterministic benchmark harness");
    benchmark_harness_test_step.dependOn(&run_benchmark_harness_tests.step);
    const benchmark_authoritative_step = b.step("benchmark-authoritative", "Run 1,000-peer authoritative benchmark");
    benchmark_authoritative_step.dependOn(&run_benchmark_authoritative.step);
    const benchmark_authoritative_test_step = b.step("benchmark-authoritative-test", "Test 1,000-peer authoritative benchmark");
    benchmark_authoritative_test_step.dependOn(&run_benchmark_authoritative_tests.step);
    const benchmark_sharded_p2p_step = b.step("benchmark-sharded-p2p", "Run 1,000-peer sharded P2P benchmark");
    benchmark_sharded_p2p_step.dependOn(&run_benchmark_sharded_p2p.step);
    const benchmark_sharded_p2p_test_step = b.step("benchmark-sharded-p2p-test", "Test 1,000-peer sharded P2P benchmark");
    benchmark_sharded_p2p_test_step.dependOn(&run_benchmark_sharded_p2p_tests.step);
    const benchmark_topology_faults_step = b.step("benchmark-topology-faults", "Run bounded topology fault benchmark");
    benchmark_topology_faults_step.dependOn(&run_benchmark_topology_faults.step);
    const benchmark_topology_faults_test_step = b.step("benchmark-topology-faults-test", "Test bounded topology fault benchmark");
    benchmark_topology_faults_test_step.dependOn(&run_benchmark_topology_faults_tests.step);
    const benchmark_throughput_step = b.step("benchmark-throughput", "Run bounded throughput benchmark");
    benchmark_throughput_step.dependOn(&run_benchmark_throughput.step);
    const benchmark_throughput_test_step = b.step("benchmark-throughput-test", "Test bounded throughput benchmark");
    benchmark_throughput_test_step.dependOn(&run_benchmark_throughput_tests.step);
    const benchmark_memory_step = b.step("benchmark-memory", "Run bounded memory benchmark");
    benchmark_memory_step.dependOn(&run_benchmark_memory.step);
    const benchmark_memory_test_step = b.step("benchmark-memory-test", "Test bounded memory benchmark");
    benchmark_memory_test_step.dependOn(&run_benchmark_memory_tests.step);
    const benchmark_regression_check = b.addSystemCommand(&.{ "sh", "script/check_benchmark_regressions.sh" });
    const benchmark_regression_step = b.step("benchmark-regression", "Check benchmark regression thresholds");
    benchmark_regression_step.dependOn(&benchmark_regression_check.step);
    const benchmark_regression_test = b.addSystemCommand(&.{ "sh", "script/test_benchmark_regressions.sh" });
    const benchmark_regression_test_step = b.step("benchmark-regression-test", "Test benchmark regression threshold checks");
    benchmark_regression_test_step.dependOn(&benchmark_regression_test.step);
    const c_header_check = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "cc",
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-c",
        "-o",
        ".zig-cache/c_abi_types.o",
        "-I",
        "packages/c-abi/include",
        "contracts/fixtures/c_abi_types.c",
    });
    const c_header_step = b.step("c-header-contract", "Check stable C ABI declarations compile as C11");
    c_header_step.dependOn(&c_header_check.step);
    const c_abi_parity_step = b.step("c-abi-parity", "Compile and run equivalent C ABI consumer workflows");
    c_abi_parity_step.dependOn(&run_c_abi_consumer.step);
    const c_sdk_static_step = b.step("c-sdk-static", "Build the C SDK static library");
    c_sdk_static_step.dependOn(&install_c_sdk_static.step);
    const c_api_contract_check = b.addSystemCommand(&.{ "sh", "script/check_c_api_contract.sh" });
    c_api_contract_check.step.dependOn(&install_c_sdk_static.step);
    c_api_contract_check.step.dependOn(&c_header_check.step);
    const c_api_contract_step = b.step("c-api-contract", "Check generated C declarations and exported symbols");
    c_api_contract_step.dependOn(&c_api_contract_check.step);
    const c_api_contract_test = b.addSystemCommand(&.{ "sh", "script/test_c_api_contract.sh" });
    c_api_contract_test.step.dependOn(&c_api_contract_check.step);
    const c_api_contract_test_step = b.step("c-api-contract-test", "Test generated C API declaration checks");
    c_api_contract_test_step.dependOn(&c_api_contract_test.step);
    const c_sdk_shared_step = b.step("c-sdk-shared", "Build the C SDK shared library");
    c_sdk_shared_step.dependOn(&install_c_sdk_shared.step);
    const c_sdk_macos_reproducible = b.addSystemCommand(&.{ "sh", "script/test_macos_c_sdk_artifacts.sh" });
    const c_sdk_macos_reproducible_step = b.step("c-sdk-macos-reproducible", "Build reproducible macOS arm64 and x86_64 C SDK libraries");
    c_sdk_macos_reproducible_step.dependOn(&c_sdk_macos_reproducible.step);
    const c_sdk_desktop_reproducible = b.addSystemCommand(&.{ "sh", "script/test_desktop_c_sdk_artifacts.sh" });
    const c_sdk_desktop_reproducible_step = b.step("c-sdk-desktop-reproducible", "Build reproducible Linux and Windows C SDK libraries");
    c_sdk_desktop_reproducible_step.dependOn(&c_sdk_desktop_reproducible.step);
    const c_sdk_static_package = b.addSystemCommand(&.{ "sh", "script/package_static_c_sdk.sh" });
    const c_sdk_static_package_step = b.step("c-sdk-static-package", "Package versioned static C SDK libraries");
    c_sdk_static_package_step.dependOn(&c_sdk_static_package.step);
    const c_sdk_static_package_test = b.addSystemCommand(&.{ "sh", "script/test_static_c_sdk_package.sh" });
    const c_sdk_static_package_test_step = b.step("c-sdk-static-package-test", "Test versioned static C SDK packages");
    c_sdk_static_package_test_step.dependOn(&c_sdk_static_package_test.step);
    const c_sdk_shared_package = b.addSystemCommand(&.{ "sh", "script/package_shared_c_sdk.sh" });
    const c_sdk_shared_package_step = b.step("c-sdk-shared-package", "Package versioned shared C SDK libraries");
    c_sdk_shared_package_step.dependOn(&c_sdk_shared_package.step);
    const c_sdk_shared_package_test = b.addSystemCommand(&.{ "sh", "script/test_shared_c_sdk_package.sh" });
    const c_sdk_shared_package_test_step = b.step("c-sdk-shared-package-test", "Test versioned shared C SDK packages");
    c_sdk_shared_package_test_step.dependOn(&c_sdk_shared_package_test.step);
    const zig_sdk_package = b.addSystemCommand(&.{ "sh", "script/package_zig_sdk.sh" });
    const zig_sdk_package_step = b.step("zig-sdk-package", "Package the versioned Zig SDK source distribution");
    zig_sdk_package_step.dependOn(&zig_sdk_package.step);
    const zig_sdk_package_test = b.addSystemCommand(&.{ "sh", "script/test_zig_sdk_package.sh" });
    const zig_sdk_package_test_step = b.step("zig-sdk-package-test", "Test the versioned Zig SDK source distribution");
    zig_sdk_package_test_step.dependOn(&zig_sdk_package_test.step);
    const c_sdk_headers_package = b.addSystemCommand(&.{ "sh", "script/package_c_sdk_headers.sh" });
    const c_sdk_headers_package_step = b.step("c-sdk-headers-package", "Package versioned C SDK headers");
    c_sdk_headers_package_step.dependOn(&c_sdk_headers_package.step);
    const c_sdk_headers_package_test = b.addSystemCommand(&.{ "sh", "script/test_c_sdk_headers_package.sh" });
    const c_sdk_headers_package_test_step = b.step("c-sdk-headers-package-test", "Test versioned C SDK headers");
    c_sdk_headers_package_test_step.dependOn(&c_sdk_headers_package_test.step);
    const release_checksums = b.addSystemCommand(&.{ "sh", "script/package_release_artifacts.sh" });
    const release_checksums_step = b.step("release-checksums", "Generate release artifact SHA-256 checksums");
    release_checksums_step.dependOn(&release_checksums.step);
    const release_checksums_test = b.addSystemCommand(&.{ "sh", "script/test_release_checksums.sh" });
    const release_checksums_test_step = b.step("release-checksums-test", "Test release artifact SHA-256 checksums");
    release_checksums_test_step.dependOn(&release_checksums_test.step);
    const release_signatures_test = b.addSystemCommand(&.{ "sh", "script/test_release_signatures.sh" });
    const release_signatures_test_step = b.step("release-signatures-test", "Test release artifact signatures");
    release_signatures_test_step.dependOn(&release_signatures_test.step);
    const release_provenance_test = b.addSystemCommand(&.{ "sh", "script/test_release_provenance.sh" });
    const release_provenance_test_step = b.step("release-provenance-test", "Test release artifact provenance");
    release_provenance_test_step.dependOn(&release_provenance_test.step);
    const release_gate_test = b.addSystemCommand(&.{ "sh", "script/test_release_gate_workflow.sh" });
    const release_gate_test_step = b.step("release-gate-test", "Test the release publication gate");
    release_gate_test_step.dependOn(&release_gate_test.step);
    const naming_step = b.step("naming-contract", "Check stable Zig and C naming rules");
    naming_step.dependOn(&run_naming.step);
    const test_step = b.step("test", "Test v1 packages and contracts");
    test_step.dependOn(&run_boundary.step);
    test_step.dependOn(&run_workspace_graph.step);
    test_step.dependOn(&run_public_api.step);
    test_step.dependOn(&run_compatibility.step);
    test_step.dependOn(&run_naming.step);
    test_step.dependOn(&run_boundary_verifier.step);
    test_step.dependOn(&run_core.step);
    test_step.dependOn(&run_protocol.step);
    test_step.dependOn(&run_state.step);
    test_step.dependOn(&run_topology.step);
    test_step.dependOn(&run_transport.step);
    test_step.dependOn(&run_runtime.step);
    test_step.dependOn(&run_c_abi.step);
    test_step.dependOn(&run_c_abi_consumer.step);
    test_step.dependOn(&c_sdk_static_package_test.step);
    test_step.dependOn(&c_sdk_shared_package_test.step);
    test_step.dependOn(&zig_sdk_package_test.step);
    test_step.dependOn(&c_sdk_headers_package_test.step);
    test_step.dependOn(&release_checksums_test.step);
    test_step.dependOn(&release_signatures_test.step);
    test_step.dependOn(&release_provenance_test.step);
    test_step.dependOn(&release_gate_test.step);
    test_step.dependOn(&run_optional_reference.step);
    test_step.dependOn(&run_test_harness.step);
    test_step.dependOn(&run_stun_turn_interop.step);
    test_step.dependOn(&run_benchmark_harness_tests.step);
    test_step.dependOn(&run_benchmark_authoritative_tests.step);
    test_step.dependOn(&run_benchmark_sharded_p2p_tests.step);
    test_step.dependOn(&run_benchmark_topology_faults_tests.step);
    test_step.dependOn(&run_benchmark_throughput_tests.step);
    test_step.dependOn(&run_benchmark_memory_tests.step);
    test_step.dependOn(&benchmark_regression_check.step);
    test_step.dependOn(&benchmark_regression_test.step);
    test_step.dependOn(&c_header_check.step);
    test_step.dependOn(&c_api_contract_check.step);
    test_step.dependOn(&c_api_contract_test.step);
    test_step.dependOn(&release_license_check.step);
    test_step.dependOn(&license_metadata_check.step);
    test_step.dependOn(&contract_gate_check.step);
    test_step.dependOn(&public_api_regression_check.step);
    test_step.dependOn(&public_api_regression_test.step);
    test_step.dependOn(&pre_release_api_contract_test.step);
}
