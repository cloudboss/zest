# zest

A custom test runner for Zig that always prints per-test output.

```
  PASS  credentials: static credentials (9.1µs)
  PASS  signing: formatAmzDate (17.0µs)
  FAIL  imds: parseJsonField (410.0µs)
  error.TestExpectedEqual
  SKIP  network: requires interface

84 passed, 1 failed, 1 skipped in 6.0ms
```

Features:

- Always prints per-test results with PASS/FAIL/SKIP status
- Colored output when stderr supports ANSI escape codes
- Per-test and total timing
- Clean test names: `imds.test.parseJsonField` displays as `imds: parseJsonField`
- Memory leak detection via `std.testing.allocator`
- Stack traces on failure

Requires Zig 0.15.0 or later.

## Usage

Add zest as a dependency:

```
zig fetch --save git+https://github.com/cloudboss/zest
```

Then set it as the test runner in your `build.zig`:

```zig
const zest = b.dependency("zest", .{});

const tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }),
    .test_runner = .{
        .path = zest.path("src/root.zig"),
        .mode = .simple,
    },
});

const run = b.addRunArtifact(tests);
const test_step = b.step("test", "Run tests");
test_step.dependOn(&run.step);
```

## Development

Run unit tests:

```
zig build test
```

Run demo (includes a deliberate failure to show output format):

```
zig build demo
```

## License

MIT
