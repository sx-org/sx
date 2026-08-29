const std = @import("std");
const sxlex = @import("sxlex");
const main = @import("main.zig");
const LineIndex = @import("line_index.zig").LineIndex;

const testing = std.testing;
const TokenList = sxlex.token_list.TokenList;
const Index = sxlex.token_list.Index;

fn lex(source: [:0]const u8) !TokenList {
    return sxlex.lexer.lex(testing.allocator, source);
}

/// Every word token's text, in source order — what the migration iterates.
fn words(source: [:0]const u8) ![][]const u8 {
    var tl = try lex(source);
    defer tl.deinit(testing.allocator);
    var out: std.ArrayList([]const u8) = .empty;
    var i = tl.first();
    while (tl.tag(i) != .eof) : (i = tl.next(i)) {
        if (main.isWord(tl.tag(i))) try out.append(testing.allocator, tl.slice(i));
    }
    return out.toOwnedSlice(testing.allocator);
}

fn expectWords(source: [:0]const u8, expected: []const []const u8) !void {
    const got = try words(source);
    defer testing.allocator.free(got);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

/// The classification of the first word token spelled `name`.
fn categoryOf(source: [:0]const u8, name: []const u8) !main.Category {
    var tl = try lex(source);
    defer tl.deinit(testing.allocator);
    var i = tl.first();
    while (tl.tag(i) != .eof) : (i = tl.next(i)) {
        if (main.isWord(tl.tag(i)) and std.mem.eql(u8, tl.slice(i), name)) {
            return main.classify(tl, i);
        }
    }
    return error.NameNotFound;
}

fn warningsOf(source: [:0]const u8) ![]main.Warning {
    var tl = try lex(source);
    defer tl.deinit(testing.allocator);
    return main.scanWarnings(testing.allocator, tl);
}

fn expectOneWarning(source: [:0]const u8, offset: u32, message: []const u8) !void {
    const got = try warningsOf(source);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(offset, got[0].offset);
    try testing.expectEqualStrings(message, got[0].message);
}

fn expectNoWarnings(source: [:0]const u8) !void {
    const got = try warningsOf(source);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "reserved spellings stay words" {
    try expectWords("private intrinsic package import\n", &.{ "private", "intrinsic", "package", "import" });
    // `@Name` is a compiler-formed type name, never a bare word.
    try expectWords("@Init x\n", &.{"x"});
}

test "comments, strings, chars and heredocs surface no words" {
    try expectWords("// package import\n", &.{});
    try expectWords("s := \"package import\";\n", &.{"s"});
    try expectWords("c := 'p';\n", &.{"c"});
    try expectWords("h :: @string END\npackage import\nEND;\n", &.{"h"});
}

test "an escaped quote does not end its literal" {
    try expectWords("s := \"a\\\"package\";\nimport;\n", &.{ "s", "import" });
    try expectWords("c := '\\'';\nimport;\n", &.{ "c", "import" });
}

test "a backticked name is a word with its backtick excluded" {
    var tl = try lex("`package;\n");
    defer tl.deinit(testing.allocator);
    const i = tl.first();
    try testing.expect(main.isWord(tl.tag(i)));
    try testing.expect(tl.flagsOf(i).is_raw);
    try testing.expectEqualStrings("package", tl.slice(i));
}

test "numbers terminate by the numeric grammar, exposing their identifier tail" {
    try expectWords("1package\n", &.{"package"});
    try expectWords("1e9\n", &.{"e9"});
    try expectWords("0xg\n", &.{"g"});
    try expectWords("0x1f 0b10 0o7 1_000.5\n", &.{});
}

test "an unrecognized directive exposes its word; a real one is opaque" {
    try expectWords("#builtin\n", &.{"builtin"});
    try expectWords("#package #private\n", &.{ "package", "private" });
    try expectWords("@identity @contextExtend\n", &.{});
    try expectWords("#expand\n", &.{"expand"});
    try expectWords("@import \"p\";\n", &.{});
    try expectWords("#importing\n", &.{"importing"});
}

test "positional categories" {
    try testing.expectEqual(main.Category.decl_const, try categoryOf("package :: 1;\n", "package"));
    try testing.expectEqual(main.Category.decl_local, try categoryOf("package := 1;\n", "package"));
    try testing.expectEqual(main.Category.typed_decl, try categoryOf("f :: (package: i32) {}\n", "package"));
    try testing.expectEqual(main.Category.call, try categoryOf("package();\n", "package"));
    try testing.expectEqual(main.Category.assign_or_field_init, try categoryOf("package = 1;\n", "package"));
    try testing.expectEqual(main.Category.member_access, try categoryOf("x.package;\n", "package"));
    try testing.expectEqual(main.Category.member_access, try categoryOf("x?.package;\n", "package"));
    try testing.expectEqual(main.Category.other_use, try categoryOf("y := package + 1;\n", "package"));
    try testing.expectEqual(main.Category.other_use, try categoryOf("package\n", "package"));
}

test "a leading package declaration is recognized" {
    var with = try lex("package alpha;\nx := 1;\n");
    defer with.deinit(testing.allocator);
    try testing.expectEqualStrings("alpha", main.existingPackageDecl(with).?);

    // Comments are trivia, so a header block does not hide the declaration.
    var commented = try lex("// header\n\npackage alpha;\n");
    defer commented.deinit(testing.allocator);
    try testing.expectEqualStrings("alpha", main.existingPackageDecl(commented).?);

    for ([_][:0]const u8{ "", "package;\n", "package alpha\n", "`package alpha;\n", "x := 1;\n" }) |src| {
        var tl = try lex(src);
        defer tl.deinit(testing.allocator);
        try testing.expectEqual(null, main.existingPackageDecl(tl));
    }
}

test "each malformed literal reports its own message and offset" {
    try expectOneWarning("x := \"abc\n", 5, "unterminated string literal (rest of file skipped as literal)");
    try expectOneWarning("x := 'a\n", 5, "unterminated char literal (rest of file skipped as literal)");
    try expectOneWarning("h :: @string 123\n", 5, "@string without delimiter identifier");
    try expectOneWarning("h :: @string END", 5, "unterminated @string heredoc");
    try expectOneWarning("h :: @string END\nbody\n", 5, "unterminated @string heredoc (rest of file skipped as literal)");
}

test "an invalid token that is not a literal warns about nothing" {
    try expectNoWarnings("#builtin\n"); // the lone `#`
    try expectNoWarnings("#stringy\n");
    try expectNoWarnings("#string END\nhello\nEND\n");
    try expectNoWarnings("` \n"); // a backtick with no name after it
    try expectNoWarnings("@ \n");
    try expectNoWarnings("\\\n");
    try expectNoWarnings("h :: @string END\nEND;\n");
}

test "insertion goes after the last blank line of the leading run" {
    try testing.expectEqual(@as(usize, 0), main.insertionOffset("x := 1;\n"));
    try testing.expectEqual(@as(usize, 0), main.insertionOffset("// doc\nx := 1;\n"));
    try testing.expectEqual(@as(usize, 11), main.insertionOffset("// header\n\n// doc\nx := 1;\n"));
    try testing.expectEqual(@as(usize, 11), main.insertionOffset("// header\n\n"));
}

test "line index maps offsets to positions and back to line text" {
    const source = "alpha\nbeta\r\ngamma";
    const idx = try LineIndex.build(testing.allocator, source);
    defer testing.allocator.free(idx.line_starts);
    try testing.expectEqual(@as(usize, 1), idx.pos(0).line);
    try testing.expectEqual(@as(usize, 1), idx.pos(0).col);
    try testing.expectEqual(@as(usize, 2), idx.pos(8).line);
    try testing.expectEqual(@as(usize, 3), idx.pos(8).col);
    try testing.expectEqual(@as(usize, 3), idx.pos(source.len - 1).line);
    try testing.expectEqualStrings("alpha", idx.lineText(source, 1));
    try testing.expectEqualStrings("beta", idx.lineText(source, 2));
    try testing.expectEqualStrings("gamma", idx.lineText(source, 3));
}
