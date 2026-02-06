const std = @import("std");
const testing = std.testing;

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
