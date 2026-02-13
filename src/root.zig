const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;

const TestList = std.ArrayList(std.builtin.TestFn);

const Ansi = struct {
    pass: []const u8,
    fail: []const u8,
    skip: []const u8,
    dim: []const u8,
    reset: []const u8,

    const on: Ansi = .{
        .pass = "\x1b[32m",
        .fail = "\x1b[31m",
        .skip = "\x1b[33m",
        .dim = "\x1b[2m",
        .reset = "\x1b[0m",
    };
    const off: Ansi = .{
        .pass = "",
        .fail = "",
        .skip = "",
        .dim = "",
        .reset = "",
    };
};

pub fn main() void {
    const test_fns = builtin.test_functions;
    const a: Ansi = if (std.fs.File.stderr().supportsAnsiEscapeCodes())
        Ansi.on
    else
        Ansi.off;

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var leaks: usize = 0;

    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = debug_alloc.deinit();
    const hook_allocator = debug_alloc.allocator();

    var before_alls = std.StringHashMap(TestList).init(hook_allocator);
    var after_alls = std.StringHashMap(TestList).init(hook_allocator);
    var before_eaches = std.StringHashMap(TestList).init(hook_allocator);
    var after_eaches = std.StringHashMap(TestList).init(hook_allocator);
    var before_all_ran = std.StringHashMap(bool).init(hook_allocator);
    var skipped_modules = std.StringHashMap(bool).init(hook_allocator);

    defer cleanupHookMaps(
        hook_allocator,
        &before_alls,
        &after_alls,
        &before_eaches,
        &after_eaches,
        &before_all_ran,
        &skipped_modules,
    );

    groupHooksByModule(
        hook_allocator,
        test_fns,
        &before_alls,
        &after_alls,
        &before_eaches,
        &after_eaches,
    );

    const start = std.time.nanoTimestamp();

    for (test_fns) |t| {
        // Skip function if it is a hook, for now.
        if (isHook(t.name)) continue;

        const prefix = getModulePrefix(t.name);

        // Now ensure any beforeAll hook is run for the current test's module.
        if (!before_all_ran.contains(prefix)) {
            if (before_alls.get(prefix)) |hooks| {
                for (hooks.items) |hook| {
                    hook.func() catch |err| {
                        std.debug.print("{s}  HOOK FAIL{s}  ", .{ a.fail, a.reset });
                        std.debug.print("{s}: zest.beforeAll {s}(error.{s}){s}\n", .{ prefix, a.dim, @errorName(err), a.reset });

                        // Mark module as skipped due to beforeAll failure. No further tests in this module will be run.
                        skipped_modules.put(prefix, true) catch |put_err| {
                            std.debug.print("Fatal: Failed to track skipped module: {s}\n", .{@errorName(put_err)});
                            std.process.exit(1);
                        };
                        break;
                    };
                }
            }
            // Track that beforeAll has already run for the current test's module so it doesn't run again.
            before_all_ran.put(prefix, true) catch |err| {
                std.debug.print("Fatal: Failed to track zest.beforeAll execution: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            if (skipped_modules.contains(prefix)) continue;
        }

        const dn = DisplayName.from(t.name);

        // Check if module should be skipped due to beforeAll failure.
        if (skipped_modules.contains(prefix)) {
            skipped += 1;
            std.debug.print("{s}  SKIP{s}  ", .{ a.skip, a.reset });
            dn.print(a);
            std.debug.print(" {s}(module setup failed){s}\n", .{ a.dim, a.reset });
            continue;
        }

        // Run the current test module's beforeEach hook, if any.
        var skip_test = false;
        if (before_eaches.get(prefix)) |hooks| {
            for (hooks.items) |hook| {
                hook.func() catch |err| {
                    std.debug.print("{s}  HOOK FAIL{s}  ", .{ a.fail, a.reset });
                    std.debug.print("{s}: zest.beforeEach {s}(error.{s}){s}\n", .{ prefix, a.dim, @errorName(err), a.reset });
                    skip_test = true;
                    break;
                };
            }
        }

        if (skip_test) {
            skipped += 1;
            std.debug.print("{s}  SKIP{s}  ", .{ a.skip, a.reset });
            dn.print(a);
            std.debug.print(" {s}(zest.beforeEach failed){s}\n", .{ a.dim, a.reset });
            continue;
        }

        // Now set up the actual test.
        testing.allocator_instance = .{};
        defer {
            if (testing.allocator_instance.deinit() == .leak) {
                leaks += 1;
            }
        }
        testing.log_level = .warn;
        log_err_count = 0;

        const t_start = std.time.nanoTimestamp();

        if (t.func()) |_| {
            passed += 1;
            const d = duration(t_start);
            std.debug.print("{s}  PASS{s}  ", .{ a.pass, a.reset });
            dn.print(a);
            std.debug.print(
                " {s}({d:.1}{s}){s}\n",
                .{ a.dim, d.value, d.unit, a.reset },
            );
        } else |err| {
            if (err == error.SkipZigTest) {
                skipped += 1;
                std.debug.print("{s}  SKIP{s}  ", .{ a.skip, a.reset });
                dn.print(a);
                std.debug.print("\n", .{});
            } else {
                failed += 1;
                const d = duration(t_start);
                std.debug.print("{s}  FAIL{s}  ", .{ a.fail, a.reset });
                dn.print(a);
                std.debug.print(
                    " {s}({d:.1}{s}){s}\n",
                    .{ a.dim, d.value, d.unit, a.reset },
                );
                std.debug.print(
                    "  {s}error.{s}{s}\n",
                    .{ a.fail, @errorName(err), a.reset },
                );
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            }
        }

        // Run afterEach hook, even if test failed.
        if (after_eaches.get(prefix)) |hooks| {
            for (hooks.items) |hook| {
                hook.func() catch |err| {
                    std.debug.print("{s}  HOOK FAIL{s}  ", .{ a.fail, a.reset });
                    std.debug.print("{s}: zest.afterEach {s}(error.{s}){s}\n", .{ prefix, a.dim, @errorName(err), a.reset });
                };
            }
        }
    }

    // Run afterAll hook for all modules that ran tests.
    var it = before_all_ran.keyIterator();
    while (it.next()) |prefix_ptr| {
        const prefix = prefix_ptr.*;
        if (after_alls.get(prefix)) |hooks| {
            for (hooks.items) |hook| {
                hook.func() catch |err| {
                    std.debug.print("{s}  HOOK FAIL{s}  ", .{ a.fail, a.reset });
                    std.debug.print("{s}: zest.afterAll {s}(error.{s}){s}\n", .{ prefix, a.dim, @errorName(err), a.reset });
                };
            }
        }
    }

    const total = duration(start);
    std.debug.print("\n", .{});

    // Summary line
    if (failed == 0 and leaks == 0) {
        std.debug.print(
            "{s}{d} passed{s}",
            .{ a.pass, passed, a.reset },
        );
    } else {
        std.debug.print("{d} passed", .{passed});
        if (failed > 0) {
            std.debug.print(
                ", {s}{d} failed{s}",
                .{ a.fail, failed, a.reset },
            );
        }
    }
    if (skipped > 0) {
        std.debug.print(
            ", {d} skipped",
            .{skipped},
        );
    }
    if (leaks > 0) {
        std.debug.print(
            ", {s}{d} leaked{s}",
            .{ a.fail, leaks, a.reset },
        );
    }
    std.debug.print(
        " {s}in {d:.1}{s}{s}\n",
        .{ a.dim, total.value, total.unit, a.reset },
    );

    if (failed > 0 or leaks > 0 or log_err_count > 0) {
        std.process.exit(1);
    }
}

fn getModulePrefix(name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, ".test.")) |i| {
        return name[0..i];
    }
    return "";
}

fn isHook(name: []const u8) bool {
    const hooks = [_][]const u8{
        ".zest.beforeAll",
        ".zest.afterAll",
        ".zest.beforeEach",
        ".zest.afterEach",
    };
    for (hooks) |h| {
        if (std.mem.endsWith(u8, name, h)) return true;
    }
    return false;
}

fn groupHooksByModule(
    allocator: std.mem.Allocator,
    test_fns: []const std.builtin.TestFn,
    before_all_map: anytype,
    after_all_map: anytype,
    before_each_map: anytype,
    after_each_map: anytype,
) void {
    for (test_fns) |t| {
        const prefix = getModulePrefix(t.name);
        if (std.mem.endsWith(u8, t.name, ".zest.beforeAll")) {
            const entry = before_all_map.getOrPut(prefix) catch continue;
            if (!entry.found_existing) {
                entry.value_ptr.* = TestList.empty;
            }
            entry.value_ptr.append(allocator, t) catch continue;
        } else if (std.mem.endsWith(u8, t.name, ".zest.afterAll")) {
            const entry = after_all_map.getOrPut(prefix) catch continue;
            if (!entry.found_existing) {
                entry.value_ptr.* = TestList.empty;
            }
            entry.value_ptr.append(allocator, t) catch continue;
        } else if (std.mem.endsWith(u8, t.name, ".zest.beforeEach")) {
            const entry = before_each_map.getOrPut(prefix) catch continue;
            if (!entry.found_existing) {
                entry.value_ptr.* = TestList.empty;
            }
            entry.value_ptr.append(allocator, t) catch continue;
        } else if (std.mem.endsWith(u8, t.name, ".zest.afterEach")) {
            const entry = after_each_map.getOrPut(prefix) catch continue;
            if (!entry.found_existing) {
                entry.value_ptr.* = TestList.empty;
            }
            entry.value_ptr.append(allocator, t) catch continue;
        }
    }
}

fn cleanupHookMaps(
    allocator: std.mem.Allocator,
    before_alls: anytype,
    after_alls: anytype,
    before_eaches: anytype,
    after_eaches: anytype,
    before_all_ran: anytype,
    skipped_modules: anytype,
) void {
    const maps = [_]*std.StringHashMap(TestList){
        before_alls,
        after_alls,
        before_eaches,
        after_eaches,
    };
    for (maps) |map| {
        var it = map.valueIterator();
        while (it.next()) |v| v.deinit(allocator);
        map.deinit();
    }
    before_all_ran.deinit();
    skipped_modules.deinit();
}

const DisplayName = struct {
    module: []const u8,
    name: []const u8,

    fn from(raw: []const u8) DisplayName {
        if (std.mem.lastIndexOf(u8, raw, ".test.")) |i| {
            return .{
                .module = raw[0..i],
                .name = raw[i + ".test.".len ..],
            };
        }
        return .{ .module = "", .name = raw };
    }

    fn print(self: DisplayName, a: Ansi) void {
        if (self.module.len > 0) {
            std.debug.print(
                "{s}{s}{s}: {s}",
                .{ a.dim, self.module, a.reset, self.name },
            );
        } else {
            std.debug.print("{s}", .{self.name});
        }
    }
};

const Duration = struct {
    value: f64,
    unit: []const u8,
};

fn duration(start: i128) Duration {
    const ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    if (ns < 1_000) return .{
        .value = @floatFromInt(ns),
        .unit = "ns",
    };
    if (ns < 1_000_000) return .{
        .value = @as(f64, @floatFromInt(ns)) / 1_000.0,
        .unit = "µs",
    };
    if (ns < 1_000_000_000) return .{
        .value = @as(f64, @floatFromInt(ns)) / 1_000_000.0,
        .unit = "ms",
    };
    return .{
        .value = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0,
        .unit = "s",
    };
}

test "DisplayName.from simple module" {
    const dn = DisplayName.from("imds.test.parse");
    try testing.expectEqualStrings("imds", dn.module);
    try testing.expectEqualStrings("parse", dn.name);
}

test "DisplayName.from nested module" {
    const dn = DisplayName.from("aws.imds.test.parse");
    try testing.expectEqualStrings("aws.imds", dn.module);
    try testing.expectEqualStrings("parse", dn.name);
}

test "DisplayName.from module named test" {
    const dn = DisplayName.from("foo.test.test.my test");
    try testing.expectEqualStrings("foo.test", dn.module);
    try testing.expectEqualStrings("my test", dn.name);
}

test "DisplayName.from no .test. delimiter" {
    const dn = DisplayName.from("root.test_0");
    try testing.expectEqualStrings("", dn.module);
    try testing.expectEqualStrings("root.test_0", dn.name);
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
