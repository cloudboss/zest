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
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_unit.step);

    const runner_cases = [_]struct {
        name: []const u8,
        leak_in_test: bool = false,
        leak_after_all: bool = false,
        exit_code: u8 = 0,
        summary: []const u8,
    }{
        .{
            .name = "runner_hooks",
            .summary = "2 passed, 1 skipped in ",
        },
        .{
            .name = "runner_test_leaks",
            .leak_in_test = true,
            .exit_code = 1,
            .summary = "2 passed, 1 skipped, 1 leaked in ",
        },
        .{
            .name = "runner_hook_leaks",
            .leak_after_all = true,
            .exit_code = 1,
            .summary = "2 passed, 1 skipped, 1 leaked in ",
        },
    };
    for (runner_cases) |case| {
        const options = b.addOptions();
        options.addOption(bool, "leak_in_test", case.leak_in_test);
        options.addOption(bool, "leak_after_all", case.leak_after_all);

        const root_module = b.createModule(.{
            .root_source_file = b.path("src/runner_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        root_module.addOptions("test_options", options);
        const runner_tests = b.addTest(.{
            .name = case.name,
            .root_module = root_module,
            .test_runner = .{
                .path = b.path("src/root.zig"),
                .mode = .simple,
            },
        });
        const run_runner = b.addRunArtifact(runner_tests);
        run_runner.setEnvironmentVariable("ZEST_TEST_VALUE", "ready");
        run_runner.expectExitCode(case.exit_code);
        run_runner.expectStdErrMatch("hooks completed\n");
        run_runner.expectStdErrMatch(case.summary);
        test_step.dependOn(&run_runner.step);
    }

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

    const check_demo = b.addRunArtifact(demo_tests);
    check_demo.expectExitCode(1);
    check_demo.expectStdErrMatch("error.TestExpectedEqual");
    check_demo.expectStdErrMatch("3 passed, 1 failed, 1 skipped in ");
    test_step.dependOn(&check_demo.step);
}
