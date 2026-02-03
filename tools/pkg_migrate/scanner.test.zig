//! Unit tests for the pkg_migrate scanner. Run directly (no build wiring):
//!
//!   zig test tools/pkg_migrate/scanner.test.zig

const std = @import("std");
const scanner = @import("scanner.zig");

const testing = std.testing;

fn scanAll(allocator: std.mem.Allocator, src: []const u8) !scanner.ScanResult {
    return scanner.scan(allocator, src);
}

/// Collect the texts of all identifier tokens.
fn identTexts(allocator: std.mem.Allocator, src: []const u8, res: scanner.ScanResult) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (res.tokens) |t| {
        if (t.kind == .identifier) try list.append(allocator, t.slice(src));
    }
    return list.toOwnedSlice(allocator);
}

test "identifier in comment does not count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "// package import private intrinsic\nx :: 1;\n";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("x", ids[0]);
    // and the comment IS surfaced as a token (top-of-file structure)
    try testing.expectEqual(scanner.TokenKind.comment, res.tokens[0].kind);
}

test "identifier in string literal does not count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "s := \"package private\"; t := package;";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    // s, t, package — but never the words inside the string
    try testing.expectEqual(@as(usize, 3), ids.len);
    try testing.expectEqualStrings("s", ids[0]);
    try testing.expectEqualStrings("t", ids[1]);
    try testing.expectEqualStrings("package", ids[2]);
}

test "escaped quote inside string does not terminate it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "s := \"a \\\" package \"; x := 1;";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("s", ids[0]);
    try testing.expectEqualStrings("x", ids[1]);
}

test "char literal with escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "c := '\\''; d := 'p'; package := 1;";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    try testing.expectEqual(@as(usize, 3), ids.len);
    try testing.expectEqualStrings("package", ids[2]);
    try testing.expectEqual(@as(usize, 0), res.warnings.len);
}

test "heredoc body is opaque" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        "h := #string XML\n" ++
        "package import private intrinsic \"unterminated\n" ++
        "XML;\n" ++
        "after :: 1;\n";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("h", ids[0]);
    try testing.expectEqualStrings("after", ids[1]);
    var saw_heredoc = false;
    for (res.tokens) |t| {
        if (t.kind == .heredoc) saw_heredoc = true;
    }
    try testing.expect(saw_heredoc);
}

test "backtick raw identifier is flagged and bare-named" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "x := `import;";
    const res = try scanAll(a, src);
    var found = false;
    for (res.tokens) |t| {
        if (t.kind == .identifier and t.is_raw) {
            try testing.expectEqualStrings("import", t.slice(src));
            found = true;
        }
    }
    try testing.expect(found);
}

test "number literals never leak identifier fragments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "a := 0x1f; b := 1_000; c := 3.14; d := 0b1010; e := 0o777;";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    try testing.expectEqual(@as(usize, 5), ids.len); // a b c d e only
}

test "plain number at space/punct boundary still lexes as before" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "x := 1000 ;\ny := 42;\nz := 1.method();";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    try testing.expectEqual(@as(usize, 4), ids.len); // x y z method
    try testing.expectEqualStrings("x", ids[0]);
    try testing.expectEqualStrings("y", ids[1]);
    try testing.expectEqualStrings("z", ids[2]);
    try testing.expectEqualStrings("method", ids[3]);
    var num_texts: std.ArrayList([]const u8) = .empty;
    for (res.tokens) |t| {
        if (t.kind == .number) try num_texts.append(a, t.slice(src));
    }
    try testing.expectEqual(@as(usize, 3), num_texts.items.len);
    try testing.expectEqualStrings("1000", num_texts.items[0]);
    try testing.expectEqualStrings("42", num_texts.items[1]);
    try testing.expectEqualStrings("1", num_texts.items[2]); // `.method` is not a fraction
}

test "number termination follows the real lexer's numeric grammar: 1package exposes identifier package" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "x := 1package;";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    // Real lexer: int `1`, then identifier `package` — the D9 inventory must
    // see that identifier.
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("x", ids[0]);
    try testing.expectEqualStrings("package", ids[1]);
    var saw_number_1 = false;
    for (res.tokens) |t| {
        if (t.kind == .number and std.mem.eql(u8, t.slice(src), "1")) saw_number_1 = true;
    }
    try testing.expect(saw_number_1);
}

test "no exponent grammar: 1e9 is number 1 plus identifier e9 (matches real lexer)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "d := 1e9; h := 0xg;";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    // src/lexer.zig has no exponent syntax: `1e9` = int `1` + ident `e9`.
    // Likewise `0xg` = int `0x` (empty hex digits) + ident `g`.
    try testing.expectEqual(@as(usize, 4), ids.len);
    try testing.expectEqualStrings("d", ids[0]);
    try testing.expectEqualStrings("e9", ids[1]);
    try testing.expectEqualStrings("h", ids[2]);
    try testing.expectEqualStrings("g", ids[3]);
}

test "directive token for #import and the following string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "#import \"modules/std.sx\";\n";
    const res = try scanAll(a, src);
    try testing.expectEqual(scanner.TokenKind.directive, res.tokens[0].kind);
    try testing.expectEqualStrings("#import", res.tokens[0].slice(src));
    try testing.expectEqual(scanner.TokenKind.string, res.tokens[1].kind);
    try testing.expectEqualStrings("\"modules/std.sx\"", res.tokens[1].slice(src));
}

test "unknown directive #private yields identifier private, not a directive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "#private\nx :: 1;\n";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    // Real lexer: invalid `#`, then ordinary identifier `private` — it must
    // be visible to the D9 inventory.
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("private", ids[0]);
    try testing.expectEqualStrings("x", ids[1]);
    for (res.tokens) |t| {
        try testing.expect(t.kind != .directive);
    }
    // The lone `#` is surfaced as a one-byte punct token.
    try testing.expectEqual(scanner.TokenKind.punct, res.tokens[0].kind);
    try testing.expectEqualStrings("#", res.tokens[0].slice(src));
}

test "unknown directive #package yields identifier package" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "#package foo;\n";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("package", ids[0]);
    try testing.expectEqualStrings("foo", ids[1]);
    for (res.tokens) |t| {
        try testing.expect(t.kind != .directive);
    }
}

test "whitelisted directive is still one directive token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "#import \"modules/std.sx\";\n#run main();\n";
    const res = try scanAll(a, src);
    var directive_texts: std.ArrayList([]const u8) = .empty;
    for (res.tokens) |t| {
        if (t.kind == .directive) try directive_texts.append(a, t.slice(src));
    }
    try testing.expectEqual(@as(usize, 2), directive_texts.items.len);
    try testing.expectEqualStrings("#import", directive_texts.items[0]);
    try testing.expectEqualStrings("#run", directive_texts.items[1]);
    // and neither `import` nor `run` leaks as an identifier
    const ids = try identTexts(a, src, res);
    try testing.expectEqual(@as(usize, 1), ids.len); // just `main`
    try testing.expectEqualStrings("main", ids[0]);
}

test "directive whitelist boundary: #importing is not #import" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "#importing;\n";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    // Real lexer: boundary check fails (`i` is ident-continue after
    // "#import"), so invalid `#` + identifier `importing`.
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("importing", ids[0]);
    for (res.tokens) |t| {
        try testing.expect(t.kind != .directive);
    }
}

test "heredoc still opaque after directive whitelist change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        "h := #string XML\n" ++
        "#private package import 1package\n" ++
        "XML;\n";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("h", ids[0]);
    try testing.expectEqual(scanner.TokenKind.heredoc, res.tokens[2].kind);
}

test "multi-byte punct :: := == are single tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "a :: 1; b := 2; c = a == b;";
    const res = try scanAll(a, src);
    var texts: std.ArrayList([]const u8) = .empty;
    for (res.tokens) |t| {
        if (t.kind == .punct) try texts.append(a, t.slice(src));
    }
    try testing.expectEqualStrings("::", texts.items[0]);
    try testing.expectEqualStrings(":=", texts.items[2]);
    // c = ... : lone '='
    try testing.expectEqualStrings("=", texts.items[4]);
    try testing.expectEqualStrings("==", texts.items[5]);
}

test "unterminated string produces invalid token plus warning, not identifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "s := \"never closed package private";
    const res = try scanAll(a, src);
    const ids = try identTexts(a, src, res);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("s", ids[0]);
    try testing.expectEqual(@as(usize, 1), res.warnings.len);
}

test "line index positions are 1-based line and col" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "abc\nde fgh\n";
    const idx = try scanner.LineIndex.build(a, src);
    try testing.expectEqual(@as(usize, 1), idx.pos(0).line);
    try testing.expectEqual(@as(usize, 1), idx.pos(0).col);
    try testing.expectEqual(@as(usize, 2), idx.pos(4).line); // 'd'
    try testing.expectEqual(@as(usize, 1), idx.pos(4).col);
    try testing.expectEqual(@as(usize, 2), idx.pos(7).line); // 'f'
    try testing.expectEqual(@as(usize, 4), idx.pos(7).col);
    try testing.expectEqualStrings("de fgh", idx.lineText(src, 2));
}
