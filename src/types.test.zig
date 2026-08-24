const std = @import("std");
const types = @import("types.zig");
const Type = types.Type;

test "Type.fromName: the eight integer aliases, nothing else with a width" {
    try std.testing.expectEqual(@as(u8, 8), Type.fromName("i8").?.signed);
    try std.testing.expectEqual(@as(u8, 64), Type.fromName("u64").?.unsigned);
    for ([_][]const u8{ "i2", "i7", "u1", "u24", "i128" }) |n| {
        try std.testing.expect(Type.fromName(n) == null);
    }
    try std.testing.expect(Type.fromName("usize").? == .usize_type);
    try std.testing.expect(Type.fromName("isize").? == .isize_type);
}
