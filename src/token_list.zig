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
        var depth: u32 = 1;
        var i: usize = @intFromEnum(opener);
        while (true) {
            i += 1;
            if (i >= tl.tags.len or tl.tags[i] == .eof) return null;
            if (tl.tags[i] == open) {
                depth += 1;
            } else if (tl.tags[i] == close) {
                depth -= 1;
                if (depth == 0) return @enumFromInt(@as(u32, @intCast(i)));
            }
        }
    }

    /// The comment rows owned by row `i` (its leading trivia; the `.eof` row
    /// owns trailing comments).
    pub fn commentsFor(tl: TokenList, i: Index) []const Comment {
        const v = @intFromEnum(i);
        return tl.comments[tl.trivia_index[v]..tl.trivia_index[v + 1]];
    }

    pub fn deinit(tl: *TokenList, allocator: Allocator) void {
        allocator.free(tl.tags);
        allocator.free(tl.starts);
        allocator.free(tl.ends);
        allocator.free(tl.flags);
        allocator.free(tl.trivia_index);
        allocator.free(tl.comments);
        tl.* = undefined;
    }
};



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
    .trivia_index = &(.{0} ** 9),
    .comments = &.{},
};

test "scanBalanced: balanced nested group" {
    const close = balanced.scanBalanced(balanced.first(), .l_paren, .r_paren).?;
    try expectIdx(6, close);
    // The inner group closes at its own depth.
    const inner = balanced.scanBalanced(@enumFromInt(2), .l_paren, .r_paren).?;
    try expectIdx(4, inner);
}

test "scanBalanced: unbalanced and EOF-truncated input" {
    // `( a (` — a second opener with no closer at all.
    const unbalanced = TokenList{
        .source = "",
        .tags = &.{ .l_paren, .identifier, .l_paren, .eof },
        .starts = &.{ 0, 2, 4, 5 },
        .ends = &.{ 1, 3, 5, 5 },
        .flags = &(.{Flags{}} ** 4),
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
        .trivia_index = &(.{0} ** 4),
        .comments = &.{},
    };
    try std.testing.expectEqual(null, truncated.scanBalanced(truncated.first(), .l_paren, .r_paren));
}

test "scanBalanced: mixed delimiters pass through unmatched" {
    // `( [ ) ]` — the paren scan ignores brackets and vice versa.
    const mixed = TokenList{
        .source = "",
        .tags = &.{ .l_paren, .l_bracket, .r_paren, .r_bracket, .eof },
        .starts = &.{ 0, 2, 4, 6, 7 },
        .ends = &.{ 1, 3, 5, 7, 7 },
        .flags = &(.{Flags{}} ** 5),
        .trivia_index = &(.{0} ** 6),
        .comments = &.{},
    };
    try expectIdx(2, mixed.scanBalanced(mixed.first(), .l_paren, .r_paren).?);
    try expectIdx(3, mixed.scanBalanced(@enumFromInt(1), .l_bracket, .r_bracket).?);
}

test "tokenAtStart: raw identifier start, heredoc body, eof row" {
    // `*`i2` — the raw identifier's start excludes the backtick.
    const raw = TokenList{
        .source = "*`i2",
        .tags = &.{ .star, .identifier, .eof },
        .starts = &.{ 0, 2, 4 },
        .ends = &.{ 1, 4, 4 },
        .flags = &.{ .{}, .{ .is_raw = true }, .{} },
        .trivia_index = &(.{0} ** 4),
        .comments = &.{},
    };
    try expectIdx(1, raw.tokenAtStart(2).?);
    try std.testing.expectEqual(@as(u32, 1), raw.writtenStart(@enumFromInt(1)));
    try std.testing.expectEqual(null, raw.tokenAtStart(1));

    // `#string END\ncontent\nEND;` — the heredoc row starts at its content;
    // offsets inside the body match no row.
    const heredoc = TokenList{
        .source = "#string END\ncontent\nEND;",
        .tags = &.{ .raw_string_literal, .semicolon, .eof },
        .starts = &.{ 12, 23, 24 },
        .ends = &.{ 20, 24, 24 },
        .flags = &(.{Flags{}} ** 3),
        .trivia_index = &(.{0} ** 4),
        .comments = &.{},
    };
    try expectIdx(0, heredoc.tokenAtStart(12).?);
    try std.testing.expectEqual(null, heredoc.tokenAtStart(15));
    try expectIdx(2, heredoc.tokenAtStart(24).?);
}

test "next/prev/peek saturate at the list edges" {
    try expectIdx(0, balanced.prev(balanced.first()));
    try expectIdx(7, balanced.peek(balanced.last(), 5));
    try expectIdx(7, balanced.next(balanced.last()));
    try expectIdx(7, balanced.peek(balanced.first(), 100));
    try expectIdx(1, balanced.next(balanced.first()));
}
