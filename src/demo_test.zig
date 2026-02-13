const std = @import("std");
const testing = std.testing;

var setup_count: usize = 0;
var teardown_count: usize = 0;

test "zest.beforeAll" {
    setup_count = 0;
    teardown_count = 0;
}

test "zest.afterAll" {
    // Verify hooks ran, once for each non-hook test.
    try testing.expect(setup_count == 5);
    try testing.expect(teardown_count == 5);
}

test "zest.beforeEach" {
    setup_count += 1;
}

test "zest.afterEach" {
    teardown_count += 1;
}

test "addition" {
    try testing.expectEqual(@as(i32, 4), 2 + 2);
}

test "string equality" {
    try testing.expectEqualStrings("hello", "hello");
}

test "deliberate failure" {
    try testing.expectEqual(@as(i32, 5), 2 + 2);
}

test "skip example" {
    return error.SkipZigTest;
}

test "slice contains" {
    const haystack = [_]u8{ 1, 2, 3, 4, 5 };
    try testing.expect(std.mem.indexOfScalar(u8, &haystack, 3) != null);
}
