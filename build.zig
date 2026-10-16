const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("zyra", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const host = b.createModule(.{ .root_source_file = b.path("tests/host.zig"), .target = target, .optimize = optimize });
    const test_library = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zyra_host", .module = host }},
    });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zyra", .module = test_library }, .{ .name = "zyra_host", .module = host } },
    }) });
    const run = b.addRunArtifact(tests);
    const library_tests = b.addTest(.{ .root_module = test_library });
    const test_step = b.step("test", "Run standalone Zyra tests");
    test_step.dependOn(&run.step);
    test_step.dependOn(&b.addRunArtifact(library_tests).step);
    const test_build = b.step("test-build", "Compile standalone Zyra tests");
    test_build.dependOn(&b.addInstallArtifact(tests, .{ .dest_sub_path = "zyra-tests" }).step);
    test_build.dependOn(&b.addInstallArtifact(library_tests, .{ .dest_sub_path = "zyra-library-tests" }).step);
}
