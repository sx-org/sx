const std = @import("std");
const corpus_paths = @import("corpus_paths");

var g_threaded: ?std.Io.Threaded = null;
fn testIo() std.Io {
    if (g_threaded == null) g_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    return g_threaded.?.io();
}

fn runSx(a: std.mem.Allocator, args: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, corpus_paths.sx_exe);
    try argv.appendSlice(a, args);
    return std.process.run(a, testIo(), .{ .argv = argv.items });
}

test "an unknown flag exits 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runSx(arena.allocator(), &.{ "build", "cli-error.sx", "--not-a-real-flag" });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, r.term);
    try std.testing.expectEqualStrings("error: unknown flag '--not-a-real-flag'\n", r.stderr);
}

test "an unknown command prints usage and exits 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runSx(arena.allocator(), &.{ "biuld", "cli-error.sx" });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, r.term);
    try std.testing.expect(std.mem.startsWith(u8, r.stderr, "Usage: sx "));
}

test "sx without arguments prints usage and exits 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runSx(arena.allocator(), &.{});
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expect(std.mem.startsWith(u8, r.stderr, "Usage: sx "));
}
