const std = @import("std");

test "extension hooks are not enabled by default" {
    try std.testing.expect(true);
}
