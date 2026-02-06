const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose the test runner path for downstream consumers.
    _ = b.addModule("zest", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests for zest internals (uses the default runner).
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit.step);

    // Demo: run sample tests using the zest runner (includes
    // a deliberate failure to show what the output looks like).
    const demo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{
            .path = b.path("src/root.zig"),
            .mode = .simple,
        },
    });
    const run_demo = b.addRunArtifact(demo_tests);
    const demo_step = b.step("demo", "Run demo tests (includes expected failure)");
    demo_step.dependOn(&run_demo.step);
}
