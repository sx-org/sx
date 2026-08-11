const std = @import("std");

/// Byte-offset -> 1-based line/col (col counted in bytes).
pub const LineIndex = struct {
    /// Byte offset of the start of each line (line_starts[0] == 0).
    line_starts: []usize,

    pub fn build(allocator: std.mem.Allocator, source: []const u8) !LineIndex {
        var starts: std.ArrayList(usize) = .empty;
        try starts.append(allocator, 0);
        for (source, 0..) |c, idx| {
            if (c == '\n') try starts.append(allocator, idx + 1);
        }
        return .{ .line_starts = try starts.toOwnedSlice(allocator) };
    }

    pub const Pos = struct { line: usize, col: usize };

    pub fn pos(self: LineIndex, offset: usize) Pos {
        // Binary search for the last line start <= offset.
        var lo: usize = 0;
        var hi: usize = self.line_starts.len; // exclusive
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts[mid] <= offset) lo = mid else hi = mid;
        }
        return .{ .line = lo + 1, .col = offset - self.line_starts[lo] + 1 };
    }

    /// The full text of the (1-based) line containing `offset`, newline
    /// excluded.
    pub fn lineText(self: LineIndex, source: []const u8, line: usize) []const u8 {
        const start = self.line_starts[line - 1];
        var end = if (line < self.line_starts.len) self.line_starts[line] else source.len;
        while (end > start and (source[end - 1] == '\n' or source[end - 1] == '\r')) end -= 1;
        return source[start..end];
    }
};
