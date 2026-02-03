const std = @import("std");
const testing = std.testing;
const errors = @import("errors.zig");
const ast = @import("ast.zig");
const Span = ast.Span;

test "extractContext: single-line span at start of file" {
    const source = "hello world\nfoo bar\n";
    var ctx = try errors.extractContext(testing.allocator, source, Span{ .start = 0, .end = 5 });
    defer ctx.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), ctx.lines.len);
    try testing.expectEqual(@as(u32, 1), ctx.lines[0].line_num);
    try testing.expectEqualStrings("hello world", ctx.lines[0].text);
    try testing.expectEqual(@as(u32, 1), ctx.start_col);
    try testing.expectEqual(@as(u32, 6), ctx.end_col);
}

test "extractContext: single-line span in middle of file" {
    const source = "first\nsecond line here\nthird";
    // Offsets: "first" = 0..5, '\n' = 5, "second line here" = 6..22.
    // span covers "line" at offsets 13..17.
    var ctx = try errors.extractContext(testing.allocator, source, Span{ .start = 13, .end = 17 });
    defer ctx.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), ctx.lines.len);
    try testing.expectEqual(@as(u32, 2), ctx.lines[0].line_num);
    try testing.expectEqualStrings("second line here", ctx.lines[0].text);
    try testing.expectEqual(@as(u32, 8), ctx.start_col);
    try testing.expectEqual(@as(u32, 12), ctx.end_col);
}

test "extractContext: multi-line span crossing one newline" {
    const source = "line1\nline2\nline3";
    // Span covers "e1\nlin" at offsets 3..9.
    var ctx = try errors.extractContext(testing.allocator, source, Span{ .start = 3, .end = 9 });
    defer ctx.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), ctx.lines.len);
    try testing.expectEqual(@as(u32, 1), ctx.lines[0].line_num);
    try testing.expectEqualStrings("line1", ctx.lines[0].text);
    try testing.expectEqual(@as(u32, 2), ctx.lines[1].line_num);
    try testing.expectEqualStrings("line2", ctx.lines[1].text);
    try testing.expectEqual(@as(u32, 4), ctx.start_col);
    try testing.expectEqual(@as(u32, 4), ctx.end_col);
}

test "extractContext: multi-line span crossing two newlines" {
    const source = "line1\nline2\nline3\nline4";
    // Span covers offsets 3..14: "e1\nline2\nli".
    var ctx = try errors.extractContext(testing.allocator, source, Span{ .start = 3, .end = 14 });
    defer ctx.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), ctx.lines.len);
    try testing.expectEqualStrings("line1", ctx.lines[0].text);
    try testing.expectEqualStrings("line2", ctx.lines[1].text);
    try testing.expectEqualStrings("line3", ctx.lines[2].text);
    try testing.expectEqual(@as(u32, 4), ctx.start_col);
    try testing.expectEqual(@as(u32, 3), ctx.end_col);
}

test "extractContext: span on empty line" {
    const source = "before\n\nafter";
    // Empty middle line at offset 7 (after the first '\n').
    var ctx = try errors.extractContext(testing.allocator, source, Span{ .start = 7, .end = 7 });
    defer ctx.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), ctx.lines.len);
    try testing.expectEqual(@as(u32, 2), ctx.lines[0].line_num);
    try testing.expectEqualStrings("", ctx.lines[0].text);
    try testing.expectEqual(@as(u32, 1), ctx.start_col);
    try testing.expectEqual(@as(u32, 1), ctx.end_col);
}

test "extractContext: span at end of file (no trailing newline)" {
    const source = "foo\nbar";
    // Span covers "ar" at offsets 5..7.
    var ctx = try errors.extractContext(testing.allocator, source, Span{ .start = 5, .end = 7 });
    defer ctx.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), ctx.lines.len);
    try testing.expectEqual(@as(u32, 2), ctx.lines[0].line_num);
    try testing.expectEqualStrings("bar", ctx.lines[0].text);
    try testing.expectEqual(@as(u32, 2), ctx.start_col);
    try testing.expectEqual(@as(u32, 4), ctx.end_col);
}

test "extractContext: empty source" {
    const source = "";
    var ctx = try errors.extractContext(testing.allocator, source, Span{ .start = 0, .end = 0 });
    defer ctx.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), ctx.lines.len);
    try testing.expectEqual(@as(u32, 1), ctx.lines[0].line_num);
    try testing.expectEqualStrings("", ctx.lines[0].text);
    try testing.expectEqual(@as(u32, 1), ctx.start_col);
    try testing.expectEqual(@as(u32, 1), ctx.end_col);
}

test "extractContext: span beyond source length is clamped" {
    const source = "foo";
    var ctx = try errors.extractContext(testing.allocator, source, Span{ .start = 10, .end = 20 });
    defer ctx.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), ctx.lines.len);
    try testing.expectEqualStrings("foo", ctx.lines[0].text);
    try testing.expectEqual(@as(u32, 4), ctx.start_col);
    try testing.expectEqual(@as(u32, 4), ctx.end_col);
}

// ─── renderExtended tests ────────────────────────────────────────────

fn renderToString(dl: *const errors.DiagnosticList, allocator: std.mem.Allocator) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    try dl.renderExtended(&aw.writer);
    var result = aw.writer.toArrayList();
    return result.toOwnedSlice(allocator);
}

test "renderExtended: single-line span with carets" {
    var dl = errors.DiagnosticList.init(testing.allocator, "hello world\n", "test.sx");
    defer dl.deinit();
    dl.add(.err, "test error", Span{ .start = 6, .end = 11 });

    const output = try renderToString(&dl, testing.allocator);
    defer testing.allocator.free(output);

    const expected =
        \\error: test error
        \\  --> test.sx:1:7
        \\   |
        \\ 1 | hello world
        \\   |       ^^^^^
        \\
    ;
    try testing.expectEqualStrings(expected, output);
}

test "renderExtended: warning level prefix" {
    var dl = errors.DiagnosticList.init(testing.allocator, "abc\n", "w.sx");
    defer dl.deinit();
    dl.add(.warn, "soft warning", Span{ .start = 0, .end = 3 });

    const output = try renderToString(&dl, testing.allocator);
    defer testing.allocator.free(output);

    const expected =
        \\warning: soft warning
        \\  --> w.sx:1:1
        \\   |
        \\ 1 | abc
        \\   | ^^^
        \\
    ;
    try testing.expectEqualStrings(expected, output);
}

test "renderExtended: diagnostic without span emits header only" {
    var dl = errors.DiagnosticList.init(testing.allocator, "", "x.sx");
    defer dl.deinit();
    dl.add(.err, "no source", null);

    const output = try renderToString(&dl, testing.allocator);
    defer testing.allocator.free(output);

    const expected = "error: no source\n";
    try testing.expectEqualStrings(expected, output);
}

test "renderExtended: line-number column widens for triple-digit lines" {
    // Build a source with many newlines so the diagnostic lands on line 100.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var i: u32 = 0;
    while (i < 99) : (i += 1) try src.append(testing.allocator, '\n');
    try src.appendSlice(testing.allocator, "boom");
    const source = src.items;

    var dl = errors.DiagnosticList.init(testing.allocator, source, "big.sx");
    defer dl.deinit();
    const start: u32 = @intCast(source.len - 4);
    const end: u32 = @intCast(source.len);
    dl.add(.err, "out here", Span{ .start = start, .end = end });

    const output = try renderToString(&dl, testing.allocator);
    defer testing.allocator.free(output);

    const expected =
        \\error: out here
        \\  --> big.sx:100:1
        \\    |
        \\100 | boom
        \\    | ^^^^
        \\
    ;
    try testing.expectEqualStrings(expected, output);
}

test "renderExtended: empty span produces single caret" {
    var dl = errors.DiagnosticList.init(testing.allocator, "xyz\n", "p.sx");
    defer dl.deinit();
    dl.add(.err, "point error", Span{ .start = 1, .end = 1 });

    const output = try renderToString(&dl, testing.allocator);
    defer testing.allocator.free(output);

    const expected =
        \\error: point error
        \\  --> p.sx:1:2
        \\   |
        \\ 1 | xyz
        \\   |  ^
        \\
    ;
    try testing.expectEqualStrings(expected, output);
}

test "renderExtended: multi-line span renders each line with carets" {
    var dl = errors.DiagnosticList.init(testing.allocator, "abc\ndef\n", "m.sx");
    defer dl.deinit();
    // span covers "bc\nde" — offsets 1..6.
    dl.add(.err, "spans two lines", Span{ .start = 1, .end = 6 });

    const output = try renderToString(&dl, testing.allocator);
    defer testing.allocator.free(output);

    const expected =
        \\error: spans two lines
        \\  --> m.sx:1:2
        \\   |
        \\ 1 | abc
        \\   |  ^^
        \\ 2 | def
        \\   | ^^
        \\
    ;
    try testing.expectEqualStrings(expected, output);
}

test "renderExtended: primary bundled with one note" {
    var dl = errors.DiagnosticList.init(testing.allocator, "let x = y\nlet y = z\n", "b.sx");
    defer dl.deinit();
    const p = dl.addId(.err, "undefined name", Span{ .start = 8, .end = 9 });
    dl.addNote(p, Span{ .start = 14, .end = 15 }, "declared here");

    const output = try renderToString(&dl, testing.allocator);
    defer testing.allocator.free(output);

    const expected =
        \\error: undefined name
        \\  --> b.sx:1:9
        \\   |
        \\ 1 | let x = y
        \\   |         ^
        \\
        \\note: declared here
        \\  --> b.sx:2:5
        \\   |
        \\ 2 | let y = z
        \\   |     ^
        \\
    ;
    try testing.expectEqualStrings(expected, output);
}

test "renderExtended: primary bundled with help (no fix code)" {
    var dl = errors.DiagnosticList.init(testing.allocator, "foo bar\n", "h.sx");
    defer dl.deinit();
    const p = dl.addId(.err, "bad thing", Span{ .start = 0, .end = 3 });
    dl.addHelp(p, null, "try something else", null);

    const output = try renderToString(&dl, testing.allocator);
    defer testing.allocator.free(output);

    const expected =
        \\error: bad thing
        \\  --> h.sx:1:1
        \\   |
        \\ 1 | foo bar
        \\   | ^^^
        \\
        \\help: try something else
        \\
    ;
    try testing.expectEqualStrings(expected, output);
}

test "renderExtended: help with fix-it code substitutes the line and omits arrow" {
    var dl = errors.DiagnosticList.init(testing.allocator, "  x := foo.value\n", "f.sx");
    defer dl.deinit();
    // primary span covers "value" at columns 12..17.
    const p = dl.addId(.err, "no such field", Span{ .start = 11, .end = 16 });
    dl.addHelp(p, Span{ .start = 11, .end = 16 }, "did you mean `val`?", "  x := foo.val");

    const output = try renderToString(&dl, testing.allocator);
    defer testing.allocator.free(output);

    const expected =
        \\error: no such field
        \\  --> f.sx:1:12
        \\   |
        \\ 1 |   x := foo.value
        \\   |            ^^^^^
        \\
        \\help: did you mean `val`?
        \\   |
        \\ 1 |   x := foo.val
        \\   |            ^^^^^
        \\
    ;
    try testing.expectEqualStrings(expected, output);
}

test "renderExtended: note and help bundle in note-then-help order" {
    var dl = errors.DiagnosticList.init(testing.allocator, "aaa\n", "o.sx");
    defer dl.deinit();
    const p = dl.addId(.err, "primary", Span{ .start = 0, .end = 3 });
    // Add help first, then note: rendering must still emit note before help.
    dl.addHelp(p, null, "the help", null);
    dl.addNote(p, Span{ .start = 0, .end = 3 }, "the note");

    const output = try renderToString(&dl, testing.allocator);
    defer testing.allocator.free(output);

    const expected =
        \\error: primary
        \\  --> o.sx:1:1
        \\   |
        \\ 1 | aaa
        \\   | ^^^
        \\
        \\note: the note
        \\  --> o.sx:1:1
        \\   |
        \\ 1 | aaa
        \\   | ^^^
        \\
        \\help: the help
        \\
    ;
    try testing.expectEqualStrings(expected, output);
}

test "render: compact style still available behind the flag" {
    var dl = errors.DiagnosticList.init(testing.allocator, "abc\n", "c.sx");
    defer dl.deinit();
    dl.render_style = .compact;
    dl.add(.err, "compact error", Span{ .start = 0, .end = 3 });

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer {
        var r = aw.writer.toArrayList();
        r.deinit(testing.allocator);
    }
    try dl.render(&aw.writer);
    var result = aw.writer.toArrayList();
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("c.sx:1:1: error: compact error\n", result.items);
}
