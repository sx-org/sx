// sema.zig is the editor/LSP type classifier (the SECOND resolver, distinct
// from the codegen-side `ir/type_resolver.zig`). These pin behavior
// the example suite can't reach: the example runner exercises the codegen
// path (`sx run`), never sema's hover/completion/index resolution.

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const Parser = @import("parser.zig").Parser;
const sema = @import("sema.zig");
const types = @import("types.zig");
const Type = types.Type;

test "sema: indexed addresses are many-pointers and object addresses retain their shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\main :: () {
        \\    a: [2]i64 = .[1, 2];
        \\    x: i64 = 3;
        \\    array := *a;
        \\    element := *array[0];
        \\    object := *x;
        \\}
    ;
    var parser = try Parser.init(alloc, source);
    const root = try parser.parse();
    var analyzer = sema.Analyzer.init(alloc);
    const result = try analyzer.analyze(root);
    const expected = [_]struct { name: []const u8, display: []const u8 }{
        .{ .name = "element", .display = "[*]i64" },
        .{ .name = "array", .display = "*[2]i64" },
        .{ .name = "object", .display = "*i64" },
    };
    for (expected) |want| {
        var found = false;
        for (result.symbols) |symbol| {
            if (!std.mem.eql(u8, symbol.name, want.name)) continue;
            try std.testing.expectEqualStrings(want.display, try symbol.ty.?.displayName(alloc));
            found = true;
        }
        try std.testing.expect(found);
    }
}

test "sema: intCast exposes its error channel and handlers retain the integer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\main :: () {
        \\    n: i64 = 300;
        \\    result := @intCast(u8, n);
        \\    caught := @intCast(u8, n) catch |err| { 7 };
        \\    propagated := try @intCast(u8, n);
        \\    defaulted := @intCast(u8, n) ?? 7;
        \\    value, failure := @intCast(u8, n);
        \\    bits := @intCast(@int(3, .unsigned), n) ?? 0;
        \\}
    ;
    var parser = try Parser.init(alloc, source);
    const root = try parser.parse();
    var analyzer = sema.Analyzer.init(alloc);
    const result = try analyzer.analyze(root);
    const expected = [_]struct { name: []const u8, display: []const u8 }{
        .{ .name = "result", .display = "(u8, !IntCastError)" },
        .{ .name = "caught", .display = "u8" },
        .{ .name = "err", .display = "!IntCastError" },
        .{ .name = "propagated", .display = "u8" },
        .{ .name = "defaulted", .display = "u8" },
        .{ .name = "value", .display = "u8" },
        .{ .name = "failure", .display = "!IntCastError" },
        .{ .name = "bits", .display = "@int(3, .unsigned)" },
    };
    for (expected) |want| {
        var found = false;
        for (result.symbols) |symbol| {
            if (!std.mem.eql(u8, symbol.name, want.name)) continue;
            try std.testing.expectEqualStrings(want.display, try symbol.ty.?.displayName(alloc));
            found = true;
        }
        try std.testing.expect(found);
    }
}

test "sema: field indices retain concrete types and runtime indices produce views" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\Record :: struct { small: i16; text: string; }
        \\I :: 0;
        \\main :: () {
        \\    r: Record = ---;
        \\    t := .{ 7, "tuple" };
        \\    small := @field(r, I + 0);
        \\    text := @field(t, 1);
        \\    I := 0;
        \\    view := @field(r, I);
        \\    invalid := t[0];
        \\}
    ;
    var parser = try Parser.init(alloc, source);
    const root = try parser.parse();
    var analyzer = sema.Analyzer.init(alloc);
    const result = try analyzer.analyze(root);
    const expected = [_]struct { name: []const u8, ty: Type }{
        .{ .name = "small", .ty = Type.s(16) },
        .{ .name = "text", .ty = .string_type },
        .{ .name = "view", .ty = .any_type },
        .{ .name = "invalid", .ty = .unresolved },
    };
    for (expected) |want| {
        var found = false;
        for (result.symbols) |symbol| {
            if (!std.mem.eql(u8, symbol.name, want.name) or symbol.kind != .variable) continue;
            try std.testing.expectEqualDeep(want.ty, symbol.ty.?);
            found = true;
        }
        try std.testing.expect(found);
    }
}

// the backtick raw escape must hold in BOTH classifiers. A raw
// reserved-name type reference (`` `i8 ``) resolves to the user-declared type,
// while a BARE `i8` stays the builtin int. Sema's `resolveTypeNode` honours
// `is_raw` before `Type.fromName`; ignoring it makes the editor index show the
// builtin for backtick code, diverging from codegen.
test "sema: backtick raw type reference resolves to the user type; bare stays builtin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\`i8 :: struct { x: i64; }
        \\
    ;
    var parser = try Parser.init(alloc, src);
    const root = try parser.parse();

    var analyzer = sema.Analyzer.init(alloc);
    _ = try analyzer.analyze(root);

    // The reserved-spelled user type registered under its plain name.
    try std.testing.expect(analyzer.struct_types.contains("i8"));

    // RAW reference (`` `i8 ``) → the user struct, NOT the 8-bit signed int.
    var raw_node = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "i8", .is_raw = true } } };
    const raw_ty = analyzer.resolveTypeNode(&raw_node);
    try std.testing.expect(raw_ty == .struct_type);
    try std.testing.expectEqualStrings("i8", raw_ty.struct_type);

    // BARE `i8` → the builtin 8-bit signed int.
    var bare_node = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "i8", .is_raw = false } } };
    const bare_ty = analyzer.resolveTypeNode(&bare_node);
    try std.testing.expect(bare_ty == .signed);
    try std.testing.expectEqual(@as(u8, 8), bare_ty.signed);
}

// The same divergence guard for the string-keyed entry (`resolveTypeNameStr`,
// reached via `fieldType` when registering struct field types): a raw field
// annotation (`` `u8 ``) resolves to the user struct, a bare one (`u8`) to the
// builtin. Driven through the real analyze pipeline (no private access).
test "sema: a raw struct-field annotation resolves to the user type; bare stays builtin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\`u8 :: struct { y: i64; }
        \\Holder :: struct { a: `u8; b: u8; }
        \\
    ;
    var parser = try Parser.init(alloc, src);
    const root = try parser.parse();

    var analyzer = sema.Analyzer.init(alloc);
    _ = try analyzer.analyze(root);

    const holder = analyzer.struct_types.get("Holder").?;
    var a_ty: ?Type = null;
    var b_ty: ?Type = null;
    for (holder.field_names, holder.field_types) |fname, fty| {
        if (std.mem.eql(u8, fname, "a")) a_ty = fty;
        if (std.mem.eql(u8, fname, "b")) b_ty = fty;
    }

    // field `a : `u8` → the user struct named "u8".
    try std.testing.expect(a_ty.? == .struct_type);
    try std.testing.expectEqualStrings("u8", a_ty.?.struct_type);

    // field `b : u8` → the builtin unsigned 8-bit int.
    try std.testing.expect(b_ty.? == .unsigned);
    try std.testing.expectEqual(@as(u8, 8), b_ty.?.unsigned);
}

// ── raw provenance through sema's COMPOUND type metadata ────────
//
// A COMPOUND raw type (`*`i8`, `?`i8`, `[N]`i8`) stores its inner name as a
// bare string on the Type's info struct; the resolver re-reads that name via
// `resolveTypeNameStr`, threading `is_raw` ALONGSIDE it. Without the raw flag
// the resolver passes `skip_builtin = false` and the LSP index reclassifies a
// user type named `i8` as the builtin int, diverging from codegen. The raw
// inner is the user type; the bare inner is the builtin.

fn symType(res: sema.SemaResult, name: []const u8) ?Type {
    for (res.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, name)) return sym.ty;
    }
    return null;
}

test "sema: field access through a raw `*`i8` pointer resolves the user field; bare `*i8` stays builtin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\`i8 :: struct { x: i64; }
        \\f :: (p: *`i8) { y := p.x; }
        \\g :: (q: *i8) { w := q.*; }
        \\
    ;
    var parser = try Parser.init(alloc, src);
    const root = try parser.parse();
    var analyzer = sema.Analyzer.init(alloc);
    const res = try analyzer.analyze(root);

    // RAW: `p: *`i8` → field `x` on the user struct → i64. (Reclassifying the
    // pointee `i8` to the 8-bit int loses `.x` → unresolved.)
    const y = symType(res, "y") orelse return error.MissingSymbol;
    try std.testing.expect(y == .signed);
    try std.testing.expectEqual(@as(u8, 64), y.signed);

    // CONTROL: `q: *i8` (bare) → deref yields the builtin 8-bit signed int.
    const w = symType(res, "w") orelse return error.MissingSymbol;
    try std.testing.expect(w == .signed);
    try std.testing.expectEqual(@as(u8, 8), w.signed);
}

test "sema: unwrapping a raw `?`i8` optional resolves the user field; bare `?i8` stays builtin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\`i8 :: struct { x: i64; }
        \\f :: (o: ?`i8) { if val := o { y := val.x; } }
        \\g :: (b: ?i8) { if v := b { w := v; } }
        \\
    ;
    var parser = try Parser.init(alloc, src);
    const root = try parser.parse();
    var analyzer = sema.Analyzer.init(alloc);
    const res = try analyzer.analyze(root);

    // RAW: `o: ?`i8` → `if val := o` unwraps to the user struct → `val.x` is i64.
    // (The optional child `i8` must not reclassify to the 8-bit int.)
    const y = symType(res, "y") orelse return error.MissingSymbol;
    try std.testing.expect(y == .signed);
    try std.testing.expectEqual(@as(u8, 64), y.signed);

    // CONTROL: `b: ?i8` (bare) unwraps to the builtin 8-bit signed int.
    const w = symType(res, "w") orelse return error.MissingSymbol;
    try std.testing.expect(w == .signed);
    try std.testing.expectEqual(@as(u8, 8), w.signed);
}

test "sema: indexing a raw `[N]`i8` array resolves the user element; bare `[N]i8` stays builtin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\`i8 :: struct { x: i64; }
        \\f :: (a: [4]`i8, b: [4]i8) { y := a[0]; w := b[0]; }
        \\
    ;
    var parser = try Parser.init(alloc, src);
    const root = try parser.parse();
    var analyzer = sema.Analyzer.init(alloc);
    const res = try analyzer.analyze(root);

    // RAW: `a: [4]`i8` → element is the user struct, never the 8-bit int.
    const y = symType(res, "y") orelse return error.MissingSymbol;
    try std.testing.expect(y == .struct_type);
    try std.testing.expectEqualStrings("i8", y.struct_type);

    // CONTROL: `b: [4]i8` (bare) → element is the builtin 8-bit signed int.
    const w = symType(res, "w") orelse return error.MissingSymbol;
    try std.testing.expect(w == .signed);
    try std.testing.expectEqual(@as(u8, 8), w.signed);
}

// Parameterized raw type (`` `i8(i64) ``). Instantiation resolves the base
// name against `struct_types` (no builtin classifier in the path): a
// `` `i8 ``-declared generic instantiates and its field resolves.
test "sema: a raw parameterized type `` `i8(i64) `` instantiates the user generic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\`i8 :: struct ($T: Type) { items: [*]T = null; n: i64 = 0; }
        \\f :: (v: `i8(i64)) { y := v.n; }
        \\
    ;
    var parser = try Parser.init(alloc, src);
    const root = try parser.parse();
    var analyzer = sema.Analyzer.init(alloc);
    const res = try analyzer.analyze(root);

    // `v: `i8(i64)` instantiates the `` `i8 ``-declared generic; its concrete
    // field `n` resolves to i64 (the raw base name was not misread as a builtin).
    const y = symType(res, "y") orelse return error.MissingSymbol;
    try std.testing.expect(y == .signed);
    try std.testing.expectEqual(@as(u8, 64), y.signed);
}

test "sema: terminated array, slice and many-pointer types display their terminator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "[4:0]u8", .want = "[4:0]u8" },
        .{ .src = "[:1]u8", .want = "[:1]u8" },
        .{ .src = "[*:0]i8", .want = "[*:0]i8" },
        .{ .src = "[4]u8", .want = "[4]u8" },
        .{ .src = "[]u8", .want = "[]u8" },
        .{ .src = "[*]i8", .want = "[*]i8" },
    };
    for (cases) |case| {
        const src = try std.fmt.allocPrintSentinel(alloc, "f :: (x: {s}) {{ 0; }}", .{case.src}, 0);
        var parser = try Parser.init(alloc, src);
        const root = try parser.parse();
        var analyzer = sema.Analyzer.init(alloc);
        _ = try analyzer.analyze(root);
        const node = root.data.root.decls[0].data.fn_decl.params[0].type_expr;
        const ty = analyzer.resolveTypeNode(node);
        try std.testing.expectEqualStrings(case.want, try ty.displayName(alloc));
    }
}
