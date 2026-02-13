# zest

A custom test runner for Zig that prints per-test output and enables setup and teardown hooks in tests.

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
- Enables defining setup and teardown hooks `zest.beforeAll`, `zest.afterAll`, `zest.beforeEach`, and `zest.afterEach`

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

### Using hooks

Tests with the special names `zest.beforeAll`, `zest.afterAll`, `zest.beforeEach`, `zest.afterEach` will run as hooks instead of regular tests.

`zest.beforeAll` - runs before all tests in a module.

`zest.afterAll` - runs after all tests in a module.

`zest.beforeEach` - runs before each test in a module.

`zest.afterEach` - runs after each test in a module.

```
test "zest.beforeAll" {
    std.debug.print("Setting up database connection...\n", .{});
    db_connection = try Database.connect();
}

test "zest.afterAll" {
    std.debug.print("Closing database connection...\n", .{});
    if (db_connection) |db| {
        db.close();
        db_connection = null;
    }
}

test "zest.beforeEach" {
    std.debug.print("Starting transaction...\n", .{});
    transaction = try Transaction.begin();
}

test "zest.afterEach" {
    std.debug.print("Rolling back transaction...\n", .{});
    if (transaction) |txn| {
        txn.rollback();
        transaction = null;
    }
}

test "can query database" {
    try testing.expect(db_connection != null);
    try testing.expect(db_connection.?.connected);
}

test "can modify data in transaction" {
    try testing.expect(transaction != null);
    try testing.expect(transaction.?.active);
}

test "database persists across tests" {
    try testing.expect(db_connection != null);
    try testing.expect(db_connection.?.connected);
}
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
