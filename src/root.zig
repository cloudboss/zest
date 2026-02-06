const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;

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

    const start = std.time.nanoTimestamp();

    for (test_fns) |t| {
        testing.allocator_instance = .{};
        defer {
            if (testing.allocator_instance.deinit() == .leak) {
                leaks += 1;
            }
        }
        testing.log_level = .warn;
        log_err_count = 0;

        const t_start = std.time.nanoTimestamp();

        const dn = DisplayName.from(t.name);

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
