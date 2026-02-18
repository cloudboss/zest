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

const Runner = struct {
    allocator: std.mem.Allocator,
    ansi: Ansi,
    passed: usize,
    failed: usize,
    leaks: usize,
    skipped: usize,
    before_alls: std.StringHashMap(TestList),
    after_alls: std.StringHashMap(TestList),
    before_eaches: std.StringHashMap(TestList),
    after_eaches: std.StringHashMap(TestList),
    before_all_ran: std.StringHashMap(bool),
    skipped_modules: std.StringHashMap(bool),

    const Self = @This();

    fn init(allocator: std.mem.Allocator) Self {
        const ansi = if (std.fs.File.stderr().supportsAnsiEscapeCodes())
            Ansi.on
        else
            Ansi.off;
        return Self{
            .allocator = allocator,
            .ansi = ansi,
            .passed = 0,
            .failed = 0,
            .leaks = 0,
            .skipped = 0,
            .before_alls = std.StringHashMap(TestList).init(allocator),
            .after_alls = std.StringHashMap(TestList).init(allocator),
            .before_eaches = std.StringHashMap(TestList).init(allocator),
            .after_eaches = std.StringHashMap(TestList).init(allocator),
            .before_all_ran = std.StringHashMap(bool).init(allocator),
            .skipped_modules = std.StringHashMap(bool).init(allocator),
        };
    }

    fn deinit(self: *Self) void {
        const maps = [_]*std.StringHashMap(TestList){
            &self.before_alls,
            &self.after_alls,
            &self.before_eaches,
            &self.after_eaches,
        };
        for (maps) |map| {
            var it = map.valueIterator();
            while (it.next()) |v| v.deinit(self.allocator);
            map.deinit();
        }
        self.before_all_ran.deinit();
        self.skipped_modules.deinit();
    }

    fn groupHooksByModule(self: *Self, test_fns: []const std.builtin.TestFn) void {
        for (test_fns) |t| {
            const prefix = getModulePrefix(t.name);
            if (std.mem.endsWith(u8, t.name, ".zest.beforeAll")) {
                const entry = self.before_alls.getOrPut(prefix) catch continue;
                if (!entry.found_existing) {
                    entry.value_ptr.* = TestList.empty;
                }
                entry.value_ptr.append(self.allocator, t) catch continue;
            } else if (std.mem.endsWith(u8, t.name, ".zest.afterAll")) {
                const entry = self.after_alls.getOrPut(prefix) catch continue;
                if (!entry.found_existing) {
                    entry.value_ptr.* = TestList.empty;
                }
                entry.value_ptr.append(self.allocator, t) catch continue;
            } else if (std.mem.endsWith(u8, t.name, ".zest.beforeEach")) {
                const entry = self.before_eaches.getOrPut(prefix) catch continue;
                if (!entry.found_existing) {
                    entry.value_ptr.* = TestList.empty;
                }
                entry.value_ptr.append(self.allocator, t) catch continue;
            } else if (std.mem.endsWith(u8, t.name, ".zest.afterEach")) {
                const entry = self.after_eaches.getOrPut(prefix) catch continue;
                if (!entry.found_existing) {
                    entry.value_ptr.* = TestList.empty;
                }
                entry.value_ptr.append(self.allocator, t) catch continue;
            }
        }
    }

    fn runTest(self: *Self, t: std.builtin.TestFn) void {
        if (isHook(t.name)) return;

        const prefix = getModulePrefix(t.name);

        // Now ensure any beforeAll hook is run for the current test's module.
        if (!self.before_all_ran.contains(prefix)) {
            if (self.before_alls.get(prefix)) |hooks| {
                for (hooks.items) |hook| {
                    hook.func() catch |err| {
                        std.debug.print("{s}  HOOK FAIL{s}  ", .{ self.ansi.fail, self.ansi.reset });
                        std.debug.print("{s}: zest.beforeAll {s}(error.{s}){s}\n", .{ prefix, self.ansi.dim, @errorName(err), self.ansi.reset });

                        // Mark module as skipped due to beforeAll failure. No further tests in this module will be run.
                        self.skipped_modules.put(prefix, true) catch |put_err| {
                            std.debug.print("Fatal: Failed to track skipped module: {s}\n", .{@errorName(put_err)});
                            std.process.exit(1);
                        };
                        break;
                    };
                }
            }
            // Track that beforeAll has already run for the current test's module so it doesn't run again.
            self.before_all_ran.put(prefix, true) catch |err| {
                std.debug.print("Fatal: Failed to track zest.beforeAll execution: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            if (self.skipped_modules.contains(prefix)) return;
        }

        const dn = DisplayName.from(t.name);

        // Check if module should be skipped due to beforeAll failure.
        if (self.skipped_modules.contains(prefix)) {
            self.skipped += 1;
            std.debug.print("{s}  SKIP{s}  ", .{ self.ansi.skip, self.ansi.reset });
            dn.print(self.ansi);
            std.debug.print(" {s}(module setup failed){s}\n", .{ self.ansi.dim, self.ansi.reset });
            return;
        }

        // Run the current test module's beforeEach hook, if any.
        var skip_test = false;
        if (self.before_eaches.get(prefix)) |hooks| {
            for (hooks.items) |hook| {
                hook.func() catch |err| {
                    std.debug.print("{s}  HOOK FAIL{s}  ", .{ self.ansi.fail, self.ansi.reset });
                    std.debug.print("{s}: zest.beforeEach {s}(error.{s}){s}\n", .{ prefix, self.ansi.dim, @errorName(err), self.ansi.reset });
                    skip_test = true;
                    break;
                };
            }
        }

        if (skip_test) {
            self.skipped += 1;
            std.debug.print("{s}  SKIP{s}  ", .{ self.ansi.skip, self.ansi.reset });
            dn.print(self.ansi);
            std.debug.print(" {s}(zest.beforeEach failed){s}\n", .{ self.ansi.dim, self.ansi.reset });
            return;
        }

        // Now set up the actual test.
        testing.allocator_instance = .{};
        defer {
            if (testing.allocator_instance.deinit() == .leak) {
                self.leaks += 1;
            }
        }
        testing.log_level = .warn;
        log_err_count = 0;

        const t_start = std.time.nanoTimestamp();

        if (t.func()) |_| {
            self.passed += 1;
            const d = duration(t_start);
            std.debug.print("{s}  PASS{s}  ", .{ self.ansi.pass, self.ansi.reset });
            dn.print(self.ansi);
            std.debug.print(
                " {s}({d:.1}{s}){s}\n",
                .{ self.ansi.dim, d.value, d.unit, self.ansi.reset },
            );
        } else |err| {
            if (err == error.SkipZigTest) {
                self.skipped += 1;
                std.debug.print("{s}  SKIP{s}  ", .{ self.ansi.skip, self.ansi.reset });
                dn.print(self.ansi);
                std.debug.print("\n", .{});
            } else {
                self.failed += 1;
                const d = duration(t_start);
                std.debug.print("{s}  FAIL{s}  ", .{ self.ansi.fail, self.ansi.reset });
                dn.print(self.ansi);
                std.debug.print(
                    " {s}({d:.1}{s}){s}\n",
                    .{ self.ansi.dim, d.value, d.unit, self.ansi.reset },
                );
                std.debug.print(
                    "  {s}error.{s}{s}\n",
                    .{ self.ansi.fail, @errorName(err), self.ansi.reset },
                );
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            }
        }

        // Run afterEach hook, even if test failed.
        if (self.after_eaches.get(prefix)) |hooks| {
            for (hooks.items) |hook| {
                hook.func() catch |err| {
                    std.debug.print("{s}  HOOK FAIL{s}  ", .{ self.ansi.fail, self.ansi.reset });
                    std.debug.print("{s}: zest.afterEach {s}(error.{s}){s}\n", .{ prefix, self.ansi.dim, @errorName(err), self.ansi.reset });
                };
            }
        }
    }

    fn runTests(self: *Self, test_fns: []const std.builtin.TestFn) void {
        for (test_fns) |t| {
            self.runTest(t);
        }

        // Run afterAll hook for all modules that ran tests.
        var iter = self.before_all_ran.keyIterator();
        while (iter.next()) |prefix_ptr| {
            const prefix = prefix_ptr.*;
            if (self.after_alls.get(prefix)) |hooks| {
                for (hooks.items) |hook| {
                    hook.func() catch |err| {
                        std.debug.print("{s}  HOOK FAIL{s}  ", .{ self.ansi.fail, self.ansi.reset });
                        std.debug.print("{s}: zest.afterAll {s}(error.{s}){s}\n", .{ prefix, self.ansi.dim, @errorName(err), self.ansi.reset });
                    };
                }
            }
        }
    }

    fn printSummary(self: *Self, start: i128) void {
        const total = duration(start);
        std.debug.print("\n", .{});

        if (self.failed == 0 and self.leaks == 0) {
            std.debug.print(
                "{s}{d} passed{s}",
                .{ self.ansi.pass, self.passed, self.ansi.reset },
            );
        } else {
            std.debug.print("{d} passed", .{self.passed});
            if (self.failed > 0) {
                std.debug.print(
                    ", {s}{d} failed{s}",
                    .{ self.ansi.fail, self.failed, self.ansi.reset },
                );
            }
        }
        if (self.skipped > 0) {
            std.debug.print(
                ", {d} skipped",
                .{self.skipped},
            );
        }
        if (self.leaks > 0) {
            std.debug.print(
                ", {s}{d} leaked{s}",
                .{ self.ansi.fail, self.leaks, self.ansi.reset },
            );
        }
        std.debug.print(
            " {s}in {d:.1}{s}{s}\n",
            .{ self.ansi.dim, total.value, total.unit, self.ansi.reset },
        );

        if (self.failed > 0 or self.leaks > 0 or log_err_count > 0) {
            std.process.exit(1);
        }
    }
};

pub fn main() void {
    const test_fns = builtin.test_functions;

    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = debug_alloc.deinit();

    var runner = Runner.init(debug_alloc.allocator());

    runner.groupHooksByModule(test_fns);

    const start = std.time.nanoTimestamp();

    runner.runTests(test_fns);

    runner.printSummary(start);
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
