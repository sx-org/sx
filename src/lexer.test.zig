const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Tag = @import("token.zig").Tag;

// ASM stream Phase A.0: `asm` lexes as the dedicated `kw_asm` keyword, while
// `volatile` / `clobbers` deliberately stay plain identifiers (recognized
// contextually inside an `asm { … }` body, never reserved globally).
test "lex asm keyword; volatile/clobbers stay identifiers" {
    var lex = Lexer.init("asm volatile clobbers");
    const expected = [_]Tag{ .kw_asm, .identifier, .identifier };
    for (expected) |exp| {
        try std.testing.expectEqual(exp, lex.next().tag);
    }
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
        var lex = Lexer.init(c.src);
        const tok = lex.next();
        try std.testing.expectEqual(c.tag, tok.tag);
        // The single token must span the entire input — no early stop.
        try std.testing.expectEqual(@as(u32, 0), tok.loc.start);
        try std.testing.expectEqual(@as(u32, @intCast(c.src.len)), tok.loc.end);
        // And the stream ends right after it.
        try std.testing.expectEqual(Tag.eof, lex.next().tag);
    }
}

// `#context_extend` lexes as its dedicated directive token; a longer
// identifier continuing past the directive spelling stays `.invalid` (the
// table requires a non-identifier boundary), and the exact-match table keeps
// `#context_extended` from silently matching the shorter directive.
test "lex hash_context_extend" {
    var lex = Lexer.init("#context_extend ui");
    try std.testing.expectEqual(Tag.hash_context_extend, lex.next().tag);
    try std.testing.expectEqual(Tag.identifier, lex.next().tag);

    var lex2 = Lexer.init("#context_extended");
    try std.testing.expectEqual(Tag.invalid, lex2.next().tag);
}

// `private` is the module-scope visibility keyword; the backtick escape keeps
// the literal spelling usable as an identifier, and a longer identifier
// (`privates`) never matches the keyword.
test "lex private keyword; backtick escape stays identifier" {
    var lex = Lexer.init("private `private privates");
    const tok1 = lex.next();
    try std.testing.expectEqual(Tag.kw_private, tok1.tag);
    const tok2 = lex.next();
    try std.testing.expectEqual(Tag.identifier, tok2.tag);
    try std.testing.expect(tok2.is_raw);
    const tok3 = lex.next();
    try std.testing.expectEqual(Tag.identifier, tok3.tag);
    try std.testing.expect(!tok3.is_raw);
}
