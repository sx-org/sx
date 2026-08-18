const std = @import("std");
const corpus_paths = @import("corpus_paths");

var g_threaded: ?std.Io.Threaded = null;
fn testIo() std.Io {
    if (g_threaded == null) g_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    return g_threaded.?.io();
}

// The stdlib never writes dest-inferred `xx`. Every opt-in conversion
// names the dest with `.(T)` / `.(T, alloc)`.
test "library contains no xx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testIo();
    var hits: usize = 0;
    try scan(a, io, corpus_paths.library_dir, &hits);
    try std.testing.expectEqual(@as(usize, 0), hits);
}

fn scan(a: std.mem.Allocator, io: std.Io, dir_abs: []const u8, hits: *usize) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var files: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            try dirs.append(a, try a.dupe(u8, entry.name));
        } else if (std.mem.endsWith(u8, entry.name, ".sx")) {
            try files.append(a, try a.dupe(u8, entry.name));
        }
    }
    for (files.items) |f| {
        const path = try std.fs.path.join(a, &.{ dir_abs, f });
        const src = std.Io.Dir.readFileAlloc(.cwd(), io, path, a, .limited(8 << 20)) catch continue;
        var line_no: usize = 1;
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |line| : (line_no += 1) {
            if (hasXxToken(line)) {
                std.debug.print("{s}:{d}: {s}\n", .{ path, line_no, line });
                hits.* += 1;
            }
        }
    }
    for (dirs.items) |d| {
        try scan(a, io, try std.fs.path.join(a, &.{ dir_abs, d }), hits);
    }
}

fn hasXxToken(line: []const u8) bool {
    var i: usize = 0;
    while (i + 2 <= line.len) : (i += 1) {
        if (line[i] != 'x' or line[i + 1] != 'x') continue;
        if (i > 0 and isIdent(line[i - 1])) continue;
        if (i + 2 < line.len and isIdent(line[i + 2])) continue;
        if (i > 0 and line[i - 1] == '.') continue;
        return true;
    }
    return false;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
