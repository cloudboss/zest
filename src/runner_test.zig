const std = @import("std");
const testing = std.testing;
const options = @import("test_options");

var before_all_count: usize = 0;
var before_each_count: usize = 0;
var after_each_count: usize = 0;

test "zest.beforeAll" {
    before_all_count += 1;
    const bytes = try testing.allocator.dupe(u8, "beforeAll");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("beforeAll", bytes);

    const value = try testing.environ.getAlloc(testing.allocator, "ZEST_TEST_VALUE");
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("ready", value);
    _ = std.Io.Timestamp.now(testing.io, .awake);
}

test "zest.afterAll" {
    try testing.expectEqual(@as(usize, 1), before_all_count);
    try testing.expectEqual(@as(usize, 3), before_each_count);
    try testing.expectEqual(@as(usize, 3), after_each_count);

    const bytes = try testing.allocator.dupe(u8, "afterAll");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("afterAll", bytes);
    _ = std.Io.Timestamp.now(testing.io, .awake);

    if (options.leak_after_all) {
        _ = try testing.allocator.dupe(u8, "afterAll leak");
    }
    std.debug.print("hooks completed\n", .{});
}

test "zest.beforeEach" {
    before_each_count += 1;
    const bytes = try testing.allocator.dupe(u8, "beforeEach");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("beforeEach", bytes);
    _ = std.Io.Timestamp.now(testing.io, .awake);
}

test "zest.afterEach" {
    after_each_count += 1;
    const bytes = try testing.allocator.dupe(u8, "afterEach");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("afterEach", bytes);
    _ = std.Io.Timestamp.now(testing.io, .awake);
}

test "allocation and io" {
    const bytes = try testing.allocator.dupe(u8, "test");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("test", bytes);
    _ = std.Io.Timestamp.now(testing.io, .awake);

    if (options.leak_in_test) {
        _ = try testing.allocator.alloc(u8, 8);
        _ = try testing.allocator.alloc(u8, 32);
    }
}

test "skip" {
    return error.SkipZigTest;
}

test "hooks run per test" {
    try testing.expectEqual(@as(usize, 1), before_all_count);
    try testing.expectEqual(after_each_count + 1, before_each_count);
}
