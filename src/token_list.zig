const std = @import("std");
const Allocator = std.mem.Allocator;
const token = @import("token.zig");
const Tag = token.Tag;
const Token = token.Token;

/// Position of a token row in a `TokenList`. Opaque on purpose: all index
/// arithmetic lives in this file, consumers move only through the saturating
/// accessors (`next`/`prev`/`peek`), so no lookahead can run off either end.
pub const Index = enum(u32) { _ };

pub const Flags = packed struct(u8) {
    glued_left: bool = false, // ends[i-1] == writtenStart(i)
    newline_left: bool = false, // an LF lies in source[ends[i-1] .. writtenStart(i)]; true for token 0
    blank_left: bool = false, // >= 2 line starts since the nearest preceding lexical item
    is_raw: bool = false,
    _: u4 = 0,
};

/// A `//` run. `start` is the `//` itself; `end` excludes any trailing CR.
pub const Comment = struct {
    start: u32,
    end: u32,
    /// Only spaces/tabs precede the `//` on its line.
    line_leading: bool,
    /// A blank line separates this row from the nearest preceding lexical item.
    blank_left: bool,
};

/// Struct-of-arrays token stream for one source file. `tags` always ends with
/// the single `.eof` row, so every column has at least one entry, and
/// `trivia_index.len == tags.len + 1` (the `.eof` row owns trailing comments).
pub const TokenList = struct {
    source: [:0]const u8, // borrowed
    tags: []const Tag,
    starts: []const u32, // == Token.loc.start, bit-for-bit
    ends: []const u32, // == Token.loc.end
    flags: []const Flags,
    /// Unclosed `(` / `[` / `{` strictly before the row. An opener and its
    /// matching closer both carry the depth OUTSIDE the group, so a group's
    /// contents sit exactly one deeper than the delimiters that hold them.
    depths: []const u32,
    trivia_index: []const u32, // len == tags.len + 1
    comments: []const Comment,

    pub fn first(tl: TokenList) Index {
        _ = tl;
        return @enumFromInt(0);
    }

    pub fn last(tl: TokenList) Index {
        return @enumFromInt(@as(u32, @intCast(tl.tags.len - 1)));
    }

    pub fn next(tl: TokenList, i: Index) Index {
        return tl.peek(i, 1);
    }

    pub fn prev(tl: TokenList, i: Index) Index {
        _ = tl;
        const v = @intFromEnum(i);
        return @enumFromInt(if (v == 0) 0 else v - 1);
    }

    pub fn peek(tl: TokenList, i: Index, n: u32) Index {
        const v = @as(u64, @intFromEnum(i)) + n;
        if (v >= tl.tags.len) return tl.last();
        return @enumFromInt(@as(u32, @intCast(v)));
    }

    pub fn tag(tl: TokenList, i: Index) Tag {
        return tl.tags[@intFromEnum(i)];
    }

    pub fn start(tl: TokenList, i: Index) u32 {
        return tl.starts[@intFromEnum(i)];
    }

    pub fn end(tl: TokenList, i: Index) u32 {
        return tl.ends[@intFromEnum(i)];
    }

    pub fn flagsOf(tl: TokenList, i: Index) Flags {
        return tl.flags[@intFromEnum(i)];
    }

    pub fn depth(tl: TokenList, i: Index) u32 {
        return tl.depths[@intFromEnum(i)];
    }

    /// Where the token was WRITTEN: a raw identifier's `start` excludes its
    /// leading backtick, but the whitespace rules read the source as typed.
    pub fn writtenStart(tl: TokenList, i: Index) u32 {
        const v = @intFromEnum(i);
        return tl.starts[v] - @intFromBool(tl.flags[v].is_raw);
    }

    pub fn slice(tl: TokenList, i: Index) []const u8 {
        const v = @intFromEnum(i);
        return tl.source[tl.starts[v]..tl.ends[v]];
    }

    pub fn token(tl: TokenList, i: Index) Token {
        const v = @intFromEnum(i);
        return .{
            .tag = tl.tags[v],
            .loc = .{ .start = tl.starts[v], .end = tl.ends[v] },
            .is_raw = tl.flags[v].is_raw,
        };
    }

    /// The row whose `start` is exactly `off`; null when no row starts there.
    pub fn tokenAtStart(tl: TokenList, off: u32) ?Index {
        var lo: usize = 0;
        var hi: usize = tl.tags.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (tl.starts[mid] < off) lo = mid + 1 else hi = mid;
        }
        if (lo < tl.tags.len and tl.starts[lo] == off) {
            return @enumFromInt(@as(u32, @intCast(lo)));
        }
        return null;
    }

    /// From `opener` (depth 1), the matching `close` row; null when the group
    /// never closes. Only `open`/`close` tags count — other delimiters pass
    /// through unmatched.
    pub fn scanBalanced(tl: TokenList, opener: Index, open: Tag, close: Tag) ?Index {
        var level: u32 = 1;
        var i: usize = @intFromEnum(opener);
        while (true) {
            i += 1;
            if (i >= tl.tags.len or tl.tags[i] == .eof) return null;
            if (tl.tags[i] == open) {
                level += 1;
            } else if (tl.tags[i] == close) {
                level -= 1;
                if (level == 0) return @enumFromInt(@as(u32, @intCast(i)));
            }
        }
    }

    /// The comment rows owned by row `i` (its leading trivia; the `.eof` row
    /// owns trailing comments).
    pub fn commentsFor(tl: TokenList, i: Index) []const Comment {
        const v = @intFromEnum(i);
        return tl.comments[tl.trivia_index[v]..tl.trivia_index[v + 1]];
    }

    /// The row that opens `i`'s line. Terminates at row 0, whose
    /// `newline_left` the lexer always sets.
    pub fn lineLeading(tl: TokenList, i: Index) Index {
        var j = i;
        while (!tl.flagsOf(j).newline_left) j = tl.prev(j);
        return j;
    }

    /// The doc-comment block attached to `i`, indentation included: the
    /// comment run adjacent to the token that opens `i`'s line, so every name
    /// in `x, y: f32;` shares the block above `x`.
    pub fn docBlock(tl: TokenList, i: Index) ?[]const u8 {
        const j = tl.lineLeading(i);
        const rows = tl.commentsFor(j);
        const run = docRows(rows, tl.flagsOf(j).blank_left) orelse return null;
        return tl.source[lineStartOf(tl.source, rows[run.lo].start)..rows[run.hi].end];
    }

    pub fn deinit(tl: *TokenList, allocator: Allocator) void {
        allocator.free(tl.tags);
        allocator.free(tl.starts);
        allocator.free(tl.ends);
        allocator.free(tl.flags);
        allocator.free(tl.depths);
        allocator.free(tl.trivia_index);
        allocator.free(tl.comments);
        tl.* = undefined;
    }
};

/// The start of the line `off` sits on, given that only spaces/tabs precede
/// `off` there.
fn lineStartOf(source: []const u8, off: u32) u32 {
    var p = off;
    while (p > 0 and (source[p - 1] == ' ' or source[p - 1] == '\t')) : (p -= 1) {}
    return p;
}

/// The attached doc block for a line-leading token: the maximal run of
/// line-leading comment rows adjacent to it, as row bounds into `rows`. Null
/// when a blank line separates the run from the token, or when the nearest row
/// is trailing. A blank line ABOVE the run bounds it rather than rejecting it.
pub fn docRows(rows: []const Comment, anchor_blank_left: bool) ?struct { lo: usize, hi: usize } {
    if (rows.len == 0 or anchor_blank_left) return null;
    var lo = rows.len;
    var i = rows.len;
    while (i > 0) : (i -= 1) {
        const r = rows[i - 1];
        if (!r.line_leading) break;
        lo = i - 1;
        if (r.blank_left) break;
    }
    if (lo == rows.len) return null;
    return .{ .lo = lo, .hi = rows.len - 1 };
}

fn expectIdx(expected: u32, actual: Index) !void {
    try std.testing.expectEqual(expected, @intFromEnum(actual));
}

/// `( a ( b ) c )` — nested group, matching closer is the last row.
const balanced = TokenList{
    .source = "",
    .tags = &.{ .l_paren, .identifier, .l_paren, .identifier, .r_paren, .identifier, .r_paren, .eof },
    .starts = &.{ 0, 2, 4, 6, 8, 10, 12, 13 },
    .ends = &.{ 1, 3, 5, 7, 9, 11, 13, 13 },
    .flags = &(.{Flags{}} ** 8),
    .depths = &.{ 0, 1, 1, 2, 1, 1, 0, 0 },
    .trivia_index = &(.{0} ** 9),
    .comments = &.{},
};

test "nested groups close at their own depth" {
    const close = balanced.scanBalanced(balanced.first(), .l_paren, .r_paren).?;
    try expectIdx(6, close);
    const inner = balanced.scanBalanced(@enumFromInt(2), .l_paren, .r_paren).?;
    try expectIdx(4, inner);
}

test "a group without a matching closer returns null" {
    // `( a (` — a second opener with no closer at all.
    const unbalanced = TokenList{
        .source = "",
        .tags = &.{ .l_paren, .identifier, .l_paren, .eof },
        .starts = &.{ 0, 2, 4, 5 },
        .ends = &.{ 1, 3, 5, 5 },
        .flags = &(.{Flags{}} ** 4),
        .depths = &.{ 0, 1, 1, 2 },
        .trivia_index = &(.{0} ** 5),
        .comments = &.{},
    };
    try std.testing.expectEqual(null, unbalanced.scanBalanced(unbalanced.first(), .l_paren, .r_paren));
    // `( a` — the list ends before any closer.
    const truncated = TokenList{
        .source = "",
        .tags = &.{ .l_paren, .identifier, .eof },
        .starts = &.{ 0, 2, 3 },
        .ends = &.{ 1, 3, 3 },
        .flags = &(.{Flags{}} ** 3),
        .depths = &.{ 0, 1, 1 },
        .trivia_index = &(.{0} ** 4),
        .comments = &.{},
    };
    try std.testing.expectEqual(null, truncated.scanBalanced(truncated.first(), .l_paren, .r_paren));
}

test "a balanced scan ignores the other delimiter kinds" {
    // `( [ ) ]`
    const mixed = TokenList{
        .source = "",
        .tags = &.{ .l_paren, .l_bracket, .r_paren, .r_bracket, .eof },
        .starts = &.{ 0, 2, 4, 6, 7 },
        .ends = &.{ 1, 3, 5, 7, 7 },
        .flags = &(.{Flags{}} ** 5),
        .depths = &.{ 0, 1, 1, 0, 0 },
        .trivia_index = &(.{0} ** 6),
        .comments = &.{},
    };
    try expectIdx(2, mixed.scanBalanced(mixed.first(), .l_paren, .r_paren).?);
    try expectIdx(3, mixed.scanBalanced(@enumFromInt(1), .l_bracket, .r_bracket).?);
}

test "exact-start lookup distinguishes raw names, heredoc interiors and the eof row" {
    // `*`i2` — the raw identifier's start excludes the backtick.
    const raw = TokenList{
        .source = "*`i2",
        .tags = &.{ .star, .identifier, .eof },
        .starts = &.{ 0, 2, 4 },
        .ends = &.{ 1, 4, 4 },
        .flags = &.{ .{}, .{ .is_raw = true }, .{} },
        .depths = &(.{0} ** 3),
        .trivia_index = &(.{0} ** 4),
        .comments = &.{},
    };
    try expectIdx(1, raw.tokenAtStart(2).?);
    try std.testing.expectEqual(@as(u32, 1), raw.writtenStart(@enumFromInt(1)));
    try std.testing.expectEqual(null, raw.tokenAtStart(1));

    // `@string END\ncontent\nEND;` — the heredoc row starts at its content;
    // offsets inside the body match no row.
    const heredoc = TokenList{
        .source = "@string END\ncontent\nEND;",
        .tags = &.{ .raw_string_literal, .semicolon, .eof },
        .starts = &.{ 12, 23, 24 },
        .ends = &.{ 20, 24, 24 },
        .flags = &(.{Flags{}} ** 3),
        .depths = &(.{0} ** 3),
        .trivia_index = &(.{0} ** 4),
        .comments = &.{},
    };
    try expectIdx(0, heredoc.tokenAtStart(12).?);
    try std.testing.expectEqual(null, heredoc.tokenAtStart(15));
    try expectIdx(2, heredoc.tokenAtStart(24).?);
}

fn row(line_leading: bool, blank_left: bool) Comment {
    return .{ .start = 0, .end = 0, .line_leading = line_leading, .blank_left = blank_left };
}

fn expectRun(lo: usize, hi: usize, actual: anytype) !void {
    try std.testing.expectEqual(lo, actual.?.lo);
    try std.testing.expectEqual(hi, actual.?.hi);
}

test "a doc run is the adjacent line-leading rows above its anchor" {
    try std.testing.expectEqual(null, docRows(&.{}, false));
    try expectRun(0, 0, docRows(&.{row(true, false)}, false));
    try expectRun(0, 2, docRows(&.{ row(true, false), row(true, false), row(true, false) }, false));
}

test "only a blank line under the run cuts it; one above bounds it" {
    try std.testing.expectEqual(null, docRows(&.{row(true, false)}, true));
    try expectRun(0, 0, docRows(&.{row(true, true)}, false));
    try expectRun(1, 2, docRows(&.{ row(true, false), row(true, true), row(true, false) }, false));
}

test "a trailing row never attaches and bounds the run below it" {
    try std.testing.expectEqual(null, docRows(&.{row(false, false)}, false));
    try std.testing.expectEqual(null, docRows(&.{ row(true, false), row(false, false) }, false));
    try expectRun(1, 1, docRows(&.{ row(false, false), row(true, false) }, false));
}

test "next/prev/peek saturate at the list edges" {
    try expectIdx(0, balanced.prev(balanced.first()));
    try expectIdx(7, balanced.peek(balanced.last(), 5));
    try expectIdx(7, balanced.next(balanced.last()));
    try expectIdx(7, balanced.peek(balanced.first(), 100));
    try expectIdx(1, balanced.next(balanced.first()));
}
