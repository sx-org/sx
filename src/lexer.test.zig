const std = @import("std");
const lexer = @import("lexer.zig");
const Tag = @import("token.zig").Tag;
const TokenList = @import("token_list.zig").TokenList;

fn lexT(source: [:0]const u8) !TokenList {
    return lexer.lex(std.testing.allocator, source);
}

fn deinitT(tl: *TokenList) void {
    tl.deinit(std.testing.allocator);
}

// `asm` lexes as the dedicated `kw_asm` keyword, while
// `volatile` / `clobbers` deliberately stay plain identifiers (recognized
// contextually inside an `asm { … }` body, never reserved globally).
test "lex asm keyword; volatile/clobbers stay identifiers" {
    var tl = try lexT("asm volatile clobbers");
    defer deinitT(&tl);
    try std.testing.expectEqualSlices(Tag, &.{ .kw_asm, .identifier, .identifier, .eof }, tl.tags);
}

// The `-` family munches longest-first: `---`, `--`, `->`, `-=`, `-`. `---`
// must be tried before `--`, or every undefined-value literal reads as
// `[--, -]`. Each case asserts the span too, so a munch that stops early is
// caught.
test "lex the `-` family: tag + span" {
    var tl = try lexT("--- -- -> -= -");
    defer deinitT(&tl);
    const Case = struct { tag: Tag, start: u32, end: u32 };
    const cases = [_]Case{
        .{ .tag = .triple_minus, .start = 0, .end = 3 },
        .{ .tag = .minus_minus, .start = 4, .end = 6 },
        .{ .tag = .arrow, .start = 7, .end = 9 },
        .{ .tag = .minus_equal, .start = 10, .end = 12 },
        .{ .tag = .minus, .start = 13, .end = 14 },
    };
    for (cases, 0..) |c, i| {
        try std.testing.expectEqual(c.tag, tl.tags[i]);
        try std.testing.expectEqual(c.start, tl.starts[i]);
        try std.testing.expectEqual(c.end, tl.ends[i]);
    }
    try std.testing.expectEqual(Tag.eof, tl.tags[cases.len]);
}

test "lex `-->` as `--` then `>`" {
    var tl = try lexT("-->");
    defer deinitT(&tl);
    try std.testing.expectEqualSlices(Tag, &.{ .minus_minus, .greater, .eof }, tl.tags);
}

// Number-literal bases + `_` digit separators. The lexer captures the whole
// literal (prefix + digits + separators) in a single token; the parser strips
// the `_`s before computing the value. Each case asserts BOTH the tag and the
// full span so a truncated scan (e.g. a separator or prefix arm that stops
// early) is caught.
test "lex octal / separators: tag + span" {
    const Case = struct { src: [:0]const u8, tag: Tag };
    const cases = [_]Case{
        .{ .src = "0o755", .tag = .int_literal }, // octal
        .{ .src = "0O17", .tag = .int_literal }, // uppercase octal
        .{ .src = "1_000", .tag = .int_literal }, // decimal separator
        .{ .src = "0xFF_FF", .tag = .int_literal }, // hex separator
        .{ .src = "0b1010_1010", .tag = .int_literal }, // binary separator
        .{ .src = "0o7_5_5", .tag = .int_literal }, // octal separators
        .{ .src = "1_0.5_5", .tag = .float_literal }, // float fraction separator
        .{ .src = "0x_FF", .tag = .int_literal }, // separator right after hex prefix
        .{ .src = "0o_17", .tag = .int_literal }, // separator right after octal prefix
        .{ .src = "0b_1010", .tag = .int_literal }, // separator right after binary prefix
    };
    for (cases) |c| {
        var tl = try lexT(c.src);
        defer deinitT(&tl);
        // The single token must span the entire input — no early stop — and
        // the stream ends right after it.
        try std.testing.expectEqual(@as(usize, 2), tl.tags.len);
        try std.testing.expectEqual(c.tag, tl.tags[0]);
        try std.testing.expectEqual(@as(u32, 0), tl.starts[0]);
        try std.testing.expectEqual(@as(u32, @intCast(c.src.len)), tl.ends[0]);
        try std.testing.expectEqual(Tag.eof, tl.tags[1]);
    }
}

// `#context_extend` lexes as its dedicated directive token; a longer
// identifier continuing past the directive spelling stays `.invalid` (the
// table requires a non-identifier boundary), and the exact-match table keeps
// `#context_extended` from silently matching the shorter directive.
test "lex hash_context_extend" {
    var tl = try lexT("#context_extend ui");
    defer deinitT(&tl);
    try std.testing.expectEqualSlices(Tag, &.{ .hash_context_extend, .identifier, .eof }, tl.tags);

    var tl2 = try lexT("#context_extended");
    defer deinitT(&tl2);
    try std.testing.expectEqual(Tag.invalid, tl2.tags[0]);
}

// `private` is the module-scope visibility keyword; the backtick escape keeps
// the literal spelling usable as an identifier, and a longer identifier
// (`privates`) never matches the keyword.
test "lex private keyword; backtick escape stays identifier" {
    var tl = try lexT("private `private privates");
    defer deinitT(&tl);
    try std.testing.expectEqualSlices(Tag, &.{ .kw_private, .identifier, .identifier, .eof }, tl.tags);
    try std.testing.expect(!tl.flags[0].is_raw);
    try std.testing.expect(tl.flags[1].is_raw);
    try std.testing.expect(!tl.flags[2].is_raw);
}

test "empty source emits one eof row" {
    var tl = try lexT("");
    defer deinitT(&tl);
    try std.testing.expectEqual(@as(usize, 1), tl.tags.len);
    try std.testing.expectEqual(Tag.eof, tl.tags[0]);
    try std.testing.expect(!tl.flags[0].glued_left);
    try std.testing.expect(tl.flags[0].newline_left);
    try std.testing.expectEqual(@as(usize, 2), tl.trivia_index.len);
}

test "whitespace-only source emits only eof" {
    var tl = try lexT("  \t\n");
    defer deinitT(&tl);
    try std.testing.expectEqual(@as(usize, 1), tl.tags.len);
    try std.testing.expectEqual(Tag.eof, tl.tags[0]);
    try std.testing.expectEqual(@as(usize, 0), tl.comments.len);
}

test "crlf source correctly sets newline_left and comment ends" {
    const source: [:0]const u8 = "// a\r\na :: 1;\r\n// b\r\nb :: 2;\r\n";
    var tl = try lexT(source);
    defer deinitT(&tl);
    // Both comment rows end before their CR.
    try std.testing.expectEqual(@as(usize, 2), tl.comments.len);
    try std.testing.expectEqual(@as(u32, 0), tl.comments[0].start);
    try std.testing.expectEqual(@as(u32, 4), tl.comments[0].end);
    try std.testing.expectEqual(@as(u32, 15), tl.comments[1].start);
    try std.testing.expectEqual(@as(u32, 19), tl.comments[1].end);
    // Both code rows sit below a line break.
    const a = tl.tokenAtStart(6).?;
    const b = tl.tokenAtStart(21).?;
    try std.testing.expect(tl.flagsOf(a).newline_left);
    try std.testing.expect(tl.flagsOf(b).newline_left);
}

test "lone cr is one comment row" {
    // The comment run stops only at LF, so a CR-separated file is one row.
    const source: [:0]const u8 = "// a\r// b\rx :: 1;";
    var tl = try lexT(source);
    defer deinitT(&tl);
    try std.testing.expectEqual(@as(usize, 1), tl.comments.len);
    try std.testing.expectEqual(@as(u32, 0), tl.comments[0].start);
    try std.testing.expectEqual(@as(u32, @intCast(source.len)), tl.comments[0].end);
    try std.testing.expectEqual(@as(usize, 1), tl.tags.len);
    try std.testing.expectEqual(Tag.eof, tl.tags[0]);
}

test "batch fixture: raw-backtick" {
    var tl = try lexT("*`i2");
    defer deinitT(&tl);
    const id = tl.tokenAtStart(2).?;
    try std.testing.expectEqual(Tag.identifier, tl.tag(id));
    try std.testing.expect(tl.flagsOf(id).is_raw);
    try std.testing.expectEqualStrings("i2", tl.slice(id));
    // The written start is the backtick, so the identifier is glued to `*`.
    try std.testing.expectEqual(@as(u32, 1), tl.writtenStart(id));
    try std.testing.expect(tl.flagsOf(id).glued_left);
}

test "batch fixture: eof-comment-no-newline" {
    const source: [:0]const u8 = "x :: 1;\n// c";
    var tl = try lexT(source);
    defer deinitT(&tl);
    const trailing = tl.commentsFor(tl.last());
    try std.testing.expectEqual(@as(usize, 1), trailing.len);
    try std.testing.expectEqual(@as(u32, 8), trailing[0].start);
    try std.testing.expectEqual(@as(u32, 12), trailing[0].end);
}

fn expectHeredocTerminator(source: [:0]const u8, terminator: Tag) !void {
    var tl = try lexT(source);
    defer deinitT(&tl);
    const heredoc = tl.first();
    try std.testing.expectEqual(Tag.raw_string_literal, tl.tag(heredoc));
    try std.testing.expectEqual(@as(u32, 12), tl.start(heredoc));
    try std.testing.expectEqual(@as(u32, 20), tl.end(heredoc));
    const after = tl.next(heredoc);
    try std.testing.expectEqual(terminator, tl.tag(after));
    // The gap is the terminator word: neither glued nor across a line.
    try std.testing.expect(!tl.flagsOf(after).glued_left);
    try std.testing.expect(!tl.flagsOf(after).newline_left);
}

test "batch fixture: heredoc-glued-semicolon" {
    try expectHeredocTerminator("#string END\ncontent\nEND;", .semicolon);
}

test "batch fixture: heredoc-glued-comma" {
    try expectHeredocTerminator("#string END\ncontent\nEND,", .comma);
}

test "batch fixture: heredoc-glued-paren" {
    try expectHeredocTerminator("#string END\ncontent\nEND)", .r_paren);
}

fn expectSingleInvalid(source: [:0]const u8) !void {
    var tl = try lexT(source);
    defer deinitT(&tl);
    try std.testing.expectEqual(@as(usize, 2), tl.tags.len);
    try std.testing.expectEqual(Tag.invalid, tl.tags[0]);
    try std.testing.expectEqual(@as(u32, 0), tl.starts[0]);
    try std.testing.expectEqual(@as(u32, @intCast(source.len)), tl.ends[0]);
    try std.testing.expectEqual(Tag.eof, tl.tags[1]);
}

test "batch fixture: unterminated-string" {
    try expectSingleInvalid("\"abc");
}

test "unterminated char is reported invalid" {
    try expectSingleInvalid("'a");
}

test "unterminated heredoc is reported invalid" {
    try expectSingleInvalid("#string END\ncontent\n");
}

test "commentsFor attaches leading rows to the following token" {
    const source: [:0]const u8 = "// a\nx :: 1;\n// b\ny :: 2;";
    var tl = try lexT(source);
    defer deinitT(&tl);
    const x = tl.tokenAtStart(5).?;
    const y = tl.tokenAtStart(18).?;
    const x_rows = tl.commentsFor(x);
    try std.testing.expectEqual(@as(usize, 1), x_rows.len);
    try std.testing.expectEqualStrings("// a", source[x_rows[0].start..x_rows[0].end]);
    const y_rows = tl.commentsFor(y);
    try std.testing.expectEqual(@as(usize, 1), y_rows.len);
    try std.testing.expectEqualStrings("// b", source[y_rows[0].start..y_rows[0].end]);
    try std.testing.expectEqual(@as(usize, 0), tl.commentsFor(tl.last()).len);
}

test "commentsFor returns trailing then leading rows in source order" {
    const source: [:0]const u8 = "x :: 1; // t\n// d\ny :: 2;";
    var tl = try lexT(source);
    defer deinitT(&tl);
    const y = tl.tokenAtStart(18).?;
    const rows = tl.commentsFor(y);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("// t", source[rows[0].start..rows[0].end]);
    try std.testing.expectEqualStrings("// d", source[rows[1].start..rows[1].end]);
    try std.testing.expect(!rows[0].line_leading);
    try std.testing.expect(rows[1].line_leading);
}

test "leading comment without blank line sets line_leading but not blank_left" {
    var tl = try lexT("// a\nx :: 1;");
    defer deinitT(&tl);
    const rows = tl.commentsFor(tl.first());
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(rows[0].line_leading);
    try std.testing.expect(!rows[0].blank_left);
    try std.testing.expect(!tl.flagsOf(tl.first()).blank_left);
}

test "blank line between comment and token sets blank_left" {
    var tl = try lexT("// a\n\nx :: 1;");
    defer deinitT(&tl);
    try std.testing.expect(tl.flagsOf(tl.first()).blank_left);
}

test "blank line between comment rows sets blank_left on second row" {
    var tl = try lexT("// a\n\n// b\nx :: 1;");
    defer deinitT(&tl);
    const rows = tl.commentsFor(tl.first());
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expect(!rows[0].blank_left);
    try std.testing.expect(rows[1].blank_left);
}

test "trailing comment is not line-leading" {
    var tl = try lexT("y :: 1; // t\nx :: 2;");
    defer deinitT(&tl);
    const x = tl.tokenAtStart(13).?;
    const rows = tl.commentsFor(x);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(!rows[0].line_leading);
}

test "comment at offset 0 has no blank line above" {
    // The start of the file is one line start, not two.
    var tl = try lexT("// a");
    defer deinitT(&tl);
    const rows = tl.commentsFor(tl.last());
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(!rows[0].blank_left);
}

test "lex under OOM returns error.OutOfMemory and leaks nothing" {
    const source: [:0]const u8 = "// c\nmain :: () { 42; }\n// t";
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (lexer.lex(failing.allocator(), source)) |list| {
            var tl = list;
            tl.deinit(failing.allocator());
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            // Every partially built column was released.
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}
