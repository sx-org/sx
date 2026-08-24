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
// A COMPOUND raw type (`*`i8`, `?`i8`, `[N]`i8`, …) stores its inner name as a
// bare string on the Type's info struct; the resolver re-reads that name via
// `resolveTypeNameStr`, threading `is_raw` ALONGSIDE it. Without the raw flag
// the resolver passes `skip_builtin = false` and the LSP index reclassifies a
// user type named `i8` as the builtin int, diverging from codegen. These pin
// every compound form: the raw inner resolves to the user type, the bare inner
// stays the builtin (control).

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

// Parameterized raw type (`` `i8(i64) ``). Unlike the shapes above this never
// had the divergence — instantiation resolves the base name straight against
// `struct_types` (no builtin classifier in the path), so it passes before AND
// after. Included as coverage that the universal model holds for the
// parameterized form too: a `` `i8 ``-declared generic instantiates and its
// field resolves.
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
