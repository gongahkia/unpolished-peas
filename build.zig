const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const networking_dependency = b.lazyDependency("networking", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san networking package");
    const services_dependency = b.lazyDependency("services", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san services package");
    const networking = networking_dependency.module("minna-san-networking");
    const services = services_dependency.module("minna-san-services");
    const networking_tests = b.addTest(.{ .root_module = networking });
    const services_tests = b.addTest(.{ .root_module = services });
    const run_networking = b.addRunArtifact(networking_tests);
    const run_services = b.addRunArtifact(services_tests);
    const test_step = b.step("test", "Test minna-san networking and services modules");
    test_step.dependOn(&run_networking.step);
    test_step.dependOn(&run_services.step);
}
