// Parser tests — pin parse-level shapes the example corpus can't isolate
// (the corpus runs the full `sx run` pipeline, never the parser alone).

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const Parser = @import("parser.zig").Parser;

// Lock: the comptime type-metaprogramming surface in `library/modules/std/meta.sx`
// must PARSE — the data types as struct/enum decls, and the four comptime builtins
// (`declare` / `define` / `type_info` / `field_type`) as bodyless `intrinsic`
// consts. Mirrors the exact spellings in meta.sx.
test "parser: comptime type-metaprogramming surface parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\EnumVariant :: struct {
        \\    name: string;
        \\    payload: Type;
        \\}
        \\EnumInfo :: struct {
        \\    name: string;
        \\    variants: []EnumVariant;
        \\}
        \\TypeInfo :: enum {
        \\    `enum: EnumInfo;
        \\}
        \\declare    :: () -> Type intrinsic;
        \\define     :: (handle: Type, info: TypeInfo) -> Type intrinsic;
        \\type_info  :: ($T: Type) -> TypeInfo intrinsic;
        \\field_type :: ($T: Type, idx: i64) -> Type intrinsic;
        \\
    ;
    var parser = Parser.init(alloc, src);
    const root = try parser.parse();

    try std.testing.expect(root.data == .root);
    const decls = root.data.root.decls;
    try std.testing.expectEqual(@as(usize, 7), decls.len);

    const Found = struct {
        // A top-level `Name :: struct/enum {…}` parses to a `.struct_decl` /
        // `.enum_decl` node DIRECTLY (not wrapped in a const_decl); only the
        // `intrinsic` forms are `.fn_decl`. Match on the shared `declName`.
        fn byName(ds: []const *Node, name: []const u8) ?*const Node {
            for (ds) |d| {
                if (d.data.declName()) |n| {
                    if (std.mem.eql(u8, n, name)) return d;
                }
            }
            return null;
        }
    };

    // Data types: struct / struct / enum, parsed as their decl nodes directly.
    const ev = Found.byName(decls, "EnumVariant") orelse return error.MissingDecl;
    try std.testing.expect(ev.data == .struct_decl);
    const ei = Found.byName(decls, "EnumInfo") orelse return error.MissingDecl;
    try std.testing.expect(ei.data == .struct_decl);
    const ti = Found.byName(decls, "TypeInfo") orelse return error.MissingDecl;
    try std.testing.expect(ti.data == .enum_decl);

    // The single `` `enum `` variant of TypeInfo. The backtick raw escape
    // stores the bare keyword as the variant name.
    const ed = ti.data.enum_decl;
    try std.testing.expectEqual(@as(usize, 1), ed.variant_names.len);
    try std.testing.expectEqualStrings("enum", ed.variant_names[0]);

    // Builtins: the `(params) -> Ret intrinsic;` form parses as a `.fn_decl`
    // (the `->` triggers the function-def path) whose body is a `intrinsic`
    // marker — same shape as the existing reflection builtins in core.sx.
    for ([_][]const u8{ "declare", "define", "type_info", "field_type" }) |bn| {
        const d = Found.byName(decls, bn) orelse return error.MissingDecl;
        try std.testing.expect(d.data == .fn_decl);
        try std.testing.expect(d.data.fn_decl.body.data == .intrinsic_expr);
        try std.testing.expect(d.data.fn_decl.return_type != null);
    }
}

// Lock: the `compiler`-library binding surface PARSES — `name :: #library "x";`
// (already supported) plus the postfix `intrinsic` marker, marking a
// compiler-domain / compiler-API function — no `extern`, no fake `#library`. The
// AST must carry `abi == .compiler`, `extern_export == .none`, `extern_lib ==
// null`, and a synthesized empty-block (bodiless) body.

// Lock: a bare `extern` (no abi annotation) leaves `abi == .default` — the
// unannotated case is unchanged by the new `abi(...)` slot.
test "parser: bare extern leaves abi == .default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\puts :: (s: *u8) -> i32 extern;
        \\
    ;
    var parser = Parser.init(alloc, src);
    const root = try parser.parse();
    const decls = root.data.root.decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expect(decls[0].data == .fn_decl);
    const fd = decls[0].data.fn_decl;
    try std.testing.expectEqual(ast.ExternExportModifier.extern_, fd.extern_export);
    try std.testing.expectEqual(ast.ABI.default, fd.abi);
}

// Lock: `abi(.c)` parses standalone (no extern/export) in the postfix slot — the
// migrated spelling of the old `callconv(.c)` on an ordinary function pointer /
// fn decl. And `abi(.naked)` parses (naked-asm ABI).
test "parser: abi(.c) and abi(.naked) parse standalone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\cb :: () -> i64 abi(.c) { 0; }
        \\nk :: () -> i64 abi(.naked) { 0; }
        \\
    ;
    var parser = Parser.init(alloc, src);
    const root = try parser.parse();
    const decls = root.data.root.decls;
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expect(decls[0].data == .fn_decl);
    try std.testing.expectEqual(ast.ABI.c, decls[0].data.fn_decl.abi);
    try std.testing.expectEqual(ast.ExternExportModifier.none, decls[0].data.fn_decl.extern_export);
    try std.testing.expect(decls[1].data == .fn_decl);
    try std.testing.expectEqual(ast.ABI.naked, decls[1].data.fn_decl.abi);
}

// Lock: the postfix `abi(...)` slot PARSES on a STRUCT decl — `Name :: struct
// extern <lib> { … }`. The AST struct_decl carries the abi + the
// library handle in `extern_lib`, with the field list intact. Parse-only — the
// struct-weld semantics were stripped (compiler-API types are VM-native now); this
// just locks that the annotation slot still parses without perturbing fields.

// Lock: an ordinary struct (no binding) leaves `abi == .default` / `extern_lib ==
// null` — the new annotation slot doesn't perturb the common case.
test "parser: plain struct leaves abi == .default, extern_lib == null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\Point :: struct { x: i64; y: i64; }
        \\
    ;
    var parser = Parser.init(alloc, src);
    const root = try parser.parse();
    const decls = root.data.root.decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expect(decls[0].data == .struct_decl);
    const sd = decls[0].data.struct_decl;
    try std.testing.expectEqual(ast.ABI.default, sd.abi);
    try std.testing.expect(sd.extern_lib == null);
}

// ── New tuple syntax (additive; the inline `(a, b)` forms stay valid) ──

// `Tuple(A, B)` magic type id → positional tuple_type_expr, mirroring `(A, B)`.
// Exercised in a genuine type position (a fn return type), since a `::` RHS is
// an EXPRESSION position where `Tuple(...)` is an ordinary call.
test "parser: Tuple(A, B) type parses to positional tuple_type_expr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () -> Tuple(i64, i32) { 0 }");
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .tuple_type_expr);
    const t = rt.data.tuple_type_expr;
    try std.testing.expectEqual(@as(usize, 2), t.field_types.len);
    try std.testing.expect(t.field_names == null);
}

// `Tuple(x: A, y: B)` keeps `:` and stores field names.
test "parser: named Tuple(x: A, y: B) stores field names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () -> Tuple(x: i64, y: i32) { 0 }");
    const root = try parser.parse();
    const t = root.data.root.decls[0].data.fn_decl.return_type.?.data.tuple_type_expr;
    try std.testing.expectEqual(@as(usize, 2), t.field_types.len);
    try std.testing.expect(t.field_names != null);
    try std.testing.expectEqualStrings("x", t.field_names.?[0]);
    try std.testing.expectEqualStrings("y", t.field_names.?[1]);
}

// 1-tuple `Tuple(T)` and empty `Tuple()`. A `Tuple(T)` stays a 1-tuple — unlike
// the inline `(T)` which is a grouping; my block never unwraps.
test "parser: Tuple(T) is a 1-tuple, Tuple() is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p1 = Parser.init(arena.allocator(), "f :: () -> Tuple(i64) { 0 }");
    const r1 = try p1.parse();
    const t1 = r1.data.root.decls[0].data.fn_decl.return_type.?.data.tuple_type_expr;
    try std.testing.expectEqual(@as(usize, 1), t1.field_types.len);

    var p2 = Parser.init(arena.allocator(), "f :: () -> Tuple() { 0 }");
    const r2 = try p2.parse();
    const t2 = r2.data.root.decls[0].data.fn_decl.return_type.?.data.tuple_type_expr;
    try std.testing.expectEqual(@as(usize, 0), t2.field_types.len);
}

// `Tuple(..Ts)` reuses the spread/pack machinery (spread_expr field). Checked
// in a PARAM type position (the inline `(..Ts)` form parses there too — a pack
// tuple in bare RETURN position is a separate pre-existing parser limitation
// that affects `(..Ts)` and `Tuple(..Ts)` identically).
test "parser: Tuple(..Ts) pack field is a spread_expr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: (t: Tuple(..Ts)) { }");
    const root = try parser.parse();
    const t = root.data.root.decls[0].data.fn_decl.params[0].type_expr.data.tuple_type_expr;
    try std.testing.expectEqual(@as(usize, 1), t.field_types.len);
    try std.testing.expect(t.field_types[0].data == .spread_expr);
}

// A trailing `->` after `Tuple(...)` is a hard error (no return type).
test "parser: Tuple(A, B) -> C is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () -> Tuple(i64, i64) -> i64 { 0 }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// A bare `Tuple` not followed by `(` stays an ordinary identifier.
test "parser: bare Tuple (no paren) is an identifier, not a tuple type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () -> i64 { Tuple := 1; Tuple }");
    const root = try parser.parse();
    // Parses without error; the body references `Tuple` as a value name.
    try std.testing.expect(root.data.root.decls[0].data == .fn_decl);
}

// `.( )` is GONE (aggregate ladder Step 1 cutover) — a plain parse error.
test "parser: .(a, b) is rejected after the cutover" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { x := .(1, 2); }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// The typed-prefix form `Tuple(A, B).( … )` is rejected too — typed tuple
// construction is `Tuple(A, B).{ … }`.
test "parser: Tuple(A, B).( ... ) is rejected after the cutover" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { x := Tuple(i64, i64).(1, 2); }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// The brace literal carries positional, named, and spread elements — the
// spread parses as a positional `spread_expr` init.
test "parser: .{ ..t, 3 } parses spread as a positional field init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { x := .{ ..t, 3 }; }");
    const root = try parser.parse();
    const val = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0].data.var_decl.value.?;
    try std.testing.expect(val.data == .struct_literal);
    const fis = val.data.struct_literal.field_inits;
    try std.testing.expectEqual(@as(usize, 2), fis.len);
    try std.testing.expect(fis[0].name == null);
    try std.testing.expect(fis[0].value.data == .spread_expr);
    try std.testing.expect(!fis[0].was_shorthand);
}

// The bare-identifier shorthand records `was_shorthand` (self-typing keys
// the named-vs-positional rule on it).
test "parser: .{ x } shorthand records was_shorthand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { s := .{ x }; }");
    const root = try parser.parse();
    const val = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0].data.var_decl.value.?;
    try std.testing.expect(val.data == .struct_literal);
    const fis = val.data.struct_literal.field_inits;
    try std.testing.expectEqual(@as(usize, 1), fis.len);
    try std.testing.expectEqualStrings("x", fis[0].name.?);
    try std.testing.expect(fis[0].was_shorthand);
}

// The legacy bare trailing-`!` spelling `-> T !` was removed — the canonical
// failable result list is `-> (T, !)`. The bare form is now a parse error.
test "parser: legacy bare `-> T !` is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () -> i64 ! { 0 }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// Likewise the legacy `-> Tuple(A, B) !` spelling — write `-> (A, B, !)`.
test "parser: legacy bare `-> Tuple(A, B) !` is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () -> Tuple(i64, i32) !ParseErr { 0 }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// `-> !` (void + error) stays a bare error_type_expr — the trailing-`!` fold
// must NOT double-wrap it.
test "parser: -> ! stays a bare error_type_expr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () -> ! { }");
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .error_type_expr);
}

// Bare-paren `-> (T, !)` is a SINGLE-value failable return (= `-> T !`): one
// value slot + a trailing error channel. Parses to a `(T, !)` tuple_type_expr —
// NOT a multi-return signature (only ≥2 value slots are `return_type_expr`).
test "parser: -> (T, !) is a single-value failable, not multi-return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () -> (i64, !) { 0 }");
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .tuple_type_expr);
    const fields = rt.data.tuple_type_expr.field_types;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(fields[1].data == .error_type_expr);
}

// A bare-paren list with ≥2 VALUE slots is a MULTI-RETURN signature: it PARSES
// to its OWN `return_type_expr` node (a distinct thing from a `Tuple(…)` value).
// Its rejection OUTSIDE a return position is a RESOLVE-time diagnostic (see the
// corpus), not a parse error.
test "parser: bare-paren (A, B) parses to a return_type_expr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () -> (i64, i32) { 0 }");
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .return_type_expr);
    try std.testing.expectEqual(@as(usize, 2), rt.data.return_type_expr.field_types.len);
}

// Bare-paren tuple VALUE `(a, b)` is gone — rejected (tuple values are annotated `.{...}`).
test "parser: bare-paren tuple value (a, b) is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { x := (1, 2); }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// Bare-paren grouping `(a + b)` still works — single inner, no top-level comma.
test "parser: bare-paren grouping (a + b) still parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () -> i64 { (1 + 2) }");
    const root = try parser.parse();
    try std.testing.expect(root.data.root.decls[0].data == .fn_decl);
}

// Regression (issue 0231): a closure-type alias `CB :: Closure(i32) -> i32;`
// parses. The const-decl RHS routes a `Closure(...)` head through the
// closure-type parse so the `-> R` tail is consumed (a bare `Closure(i32)`
// call used to leave `->` dangling → "expected ';'"). Node shape: a
// `const_decl` whose value is a `closure_type_expr` carrying the return type.
test "parser: closure-type alias in const-decl RHS parses to closure_type_expr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "CB :: Closure(i32) -> i32;");
    const root = try parser.parse();
    const cd = root.data.root.decls[0];
    try std.testing.expect(cd.data == .const_decl);
    const value = cd.data.const_decl.value;
    try std.testing.expect(value.data == .closure_type_expr);
    try std.testing.expectEqual(@as(usize, 1), value.data.closure_type_expr.param_types.len);
    try std.testing.expect(value.data.closure_type_expr.return_type != null);
}

// A NON-Closure call head followed by `->` still errors (no accidental
// broadening of the magic to arbitrary call expressions).
test "parser: non-Closure call followed by '->' still fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "BAD :: foo(1) -> i32;");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// Lock: `#context_extend name: Type = default;` parses at top level to a
// `.context_extend_decl` node carrying {name, name_span, type_expr,
// default_expr}; the `= default` clause may be ABSENT (default_expr == null —
// the collection pass rejects it with the L5 wording, not the parser); and it
// declares no module-scope name (`declName` is null — the field lives in the
// program-global Context namespace).
test "parser: #context_extend parses to context_extend_decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\#context_extend ui: ?*i64 = null;
        \\#context_extend bare: i64;
        \\
    ;
    var parser = Parser.init(alloc, src);
    const root = try parser.parse();
    const decls = root.data.root.decls;
    try std.testing.expectEqual(@as(usize, 2), decls.len);

    try std.testing.expect(decls[0].data == .context_extend_decl);
    const ce = decls[0].data.context_extend_decl;
    try std.testing.expectEqualStrings("ui", ce.name);
    try std.testing.expect(ce.type_expr.data == .optional_type_expr);
    try std.testing.expect(ce.default_expr != null);
    try std.testing.expect(ce.default_expr.?.data == .null_literal);
    try std.testing.expect(decls[0].data.declName() == null);

    const bare = decls[1].data.context_extend_decl;
    try std.testing.expectEqualStrings("bare", bare.name);
    try std.testing.expect(bare.default_expr == null);
}

// Lock: `#context_extend` is top-level-only (L7) — statement position is a
// parse error, not a generic expression-parse fallthrough.
test "parser: #context_extend rejected in statement position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\f :: () {
        \\    #context_extend x: i64 = 0;
        \\}
        \\
    ;
    var parser = Parser.init(alloc, src);
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expect(parser.err_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, parser.err_msg.?, "top level") != null);
}
