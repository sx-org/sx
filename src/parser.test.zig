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
// construction is `Tuple(A, B){ … }`.
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

// `private` prefixes an identifier-headed module-scope declaration and stamps
// the node's visibility; every declaration kind takes it uniformly.
test "parser: private stamps module-scope declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\private Helper :: (x: i64) -> i64 { return x; }
        \\private State :: struct { n: i64; }
        \\private LIMIT :: 21;
        \\private counter : i64 = 0;
        \\private dep :: #import "dep.sx";
        \\private lifted :: use_me;
        \\pub_fn :: () -> i64 { return 0; }
        \\
    ;
    var p = Parser.init(alloc, src);
    const root = try p.parse();
    const decls = root.data.root.decls;
    try std.testing.expectEqual(@as(usize, 7), decls.len);
    for (decls[0..6]) |d| try std.testing.expectEqual(ast.Visibility.private, d.visibility);
    try std.testing.expectEqual(ast.Visibility.public, decls[6].visibility);
    // Kind spot checks: the prefix reaches every declaration form.
    try std.testing.expect(decls[0].data == .const_decl or decls[0].data == .fn_decl);
    try std.testing.expect(decls[1].data == .struct_decl);
    try std.testing.expect(decls[4].data == .import_decl);
}

// `private` is a module-scope modifier only: statements inside function bodies
// reject it, and non-identifier top-level forms reject it with placement
// diagnostics.
test "parser: private rejected on locals and directive forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_][:0]const u8{
        "f :: () { private x := 1; }",
        "private #import \"x.sx\";",
        "private impl P for T {}",
        "private inline if true { a :: 1; }",
        "private #run 1;",
    };
    for (cases) |src| {
        var p = Parser.init(alloc, src);
        try std.testing.expectError(error.ParseError, p.parse());
    }
}

// Top-level `inline if` branches hold module-scope declarations after comptime
// flattening, so `private` stays legal there — but NOT inside a nested
// function body within the branch.
test "parser: private inside top-level inline if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ok_src =
        \\inline if true {
        \\    private tag :: () -> i64 { return 1; }
        \\} else {
        \\    private tag :: () -> i64 { return 2; }
        \\}
        \\
    ;
    var p = Parser.init(alloc, ok_src);
    const root = try p.parse();
    try std.testing.expect(root.data == .root);

    const bad_src =
        \\inline if true {
        \\    outer :: () { private x :: 1; }
        \\}
        \\
    ;
    var p2 = Parser.init(alloc, bad_src);
    try std.testing.expectError(error.ParseError, p2.parse());
}

// ---- Whitespace is syntax (specs §1) ----
//
// The corpus pins the DIAGNOSTICS (examples/diagnostics/2057–2064); these pin
// the two readings the corpus cannot show — a spaced bracket is fatal on one
// line, while across a line it merely stops binding, which is the shape ASI
// then builds on.

fn parseErrMsg(alloc: std.mem.Allocator, src: [:0]const u8) ![]const u8 {
    var p = Parser.init(alloc, src);
    try std.testing.expectError(error.ParseError, p.parse());
    return p.err_msg orelse return error.MissingMessage;
}

test "parser: a postfix `(` binds only when glued" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ok = Parser.init(alloc, "f :: () -> i64 { g(1) }");
    const root = try ok.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    try std.testing.expect(body.data.block.stmts[0].data == .call);

    // Same line: the space is the error, and the report names it.
    const spaced = try parseErrMsg(alloc, "f :: () -> i64 { g (1) }");
    try std.testing.expect(std.mem.indexOf(u8, spaced, "a space before `(`") != null);

    // Across a line the `(` does not bind, so the newline ends the statement
    // and the `(` opens the next one.
    var split = Parser.init(alloc, "f :: () -> i64 { g\n(1) }");
    const split_body = (try split.parse()).data.root.decls[0].data.fn_decl.body;
    try std.testing.expectEqual(@as(usize, 2), split_body.data.block.stmts.len);
    try std.testing.expect(split_body.data.block.stmts[0].data == .identifier);
    try std.testing.expect(split_body.data.block.stmts[1].data == .int_literal);
}

test "parser: a postfix `[` binds only when glued" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ok = Parser.init(alloc, "f :: () -> i64 { xs[0] }");
    const root = try ok.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    try std.testing.expect(body.data.block.stmts[0].data == .index_expr);

    const spaced = try parseErrMsg(alloc, "f :: () -> i64 { xs [0] }");
    try std.testing.expect(std.mem.indexOf(u8, spaced, "a space before `[`") != null);
}

// A type application never crosses a statement boundary, so ANY gap there is
// the spacing mistake — including one written across a line.
test "parser: a type's arguments bind only when glued" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ok = Parser.init(alloc, "f :: (b: Box(i64)) { }");
    _ = try ok.parse();

    for ([_][:0]const u8{
        "f :: (b: Box (i64)) { }",
        "f :: (b: Box\n(i64)) { }",
        "f :: (c: Closure (i64) -> i64) { }",
        "f :: (b: $B/@BuildBlock (Drawable)) { }",
        "V :: @OpenVariant (View) { }",
        "impl Into (Block) for Row { }",
    }) |src| {
        const msg = try parseErrMsg(alloc, src);
        try std.testing.expect(std.mem.indexOf(u8, msg, "a space between a type and its arguments") != null);
    }
}

// `BI :: Box;` alone is a valid alias to the un-applied generic, so nothing
// downstream would have flagged the spelling — the glue check has to fire at
// the `(` for the report to name the space.
test "parser: the spaced alias orphan reports the spacing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ok = Parser.init(alloc, "BI :: Box;");
    _ = try ok.parse();

    const msg = try parseErrMsg(alloc, "BI :: Box (i64);");
    try std.testing.expect(std.mem.indexOf(u8, msg, "write `Box(i64)`") != null);
}

test "parser: `-` is infix only when its gaps match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Matching gaps — present on both sides, absent on both, or spanning a
    // line — all read as subtraction.
    for ([_][:0]const u8{
        "f :: () -> i64 { a - b }",
        "f :: () -> i64 { a-b }",
        "f :: () -> i64 { a\n    - b }",
    }) |src| {
        var p = Parser.init(alloc, src);
        const root = try p.parse();
        const body = root.data.root.decls[0].data.fn_decl.body;
        try std.testing.expect(body.data.block.stmts[0].data == .binary_op);
    }

    // Lopsided on one line: fatal, and the report says which reading the
    // spacing picked.
    const prefix_side = try parseErrMsg(alloc, "f :: () -> i64 { a -b }");
    try std.testing.expect(std.mem.indexOf(u8, prefix_side, "reads as a prefix") != null);
    const mirror = try parseErrMsg(alloc, "f :: () -> i64 { a- b }");
    try std.testing.expect(std.mem.indexOf(u8, mirror, "glued on its left and spaced on its right") != null);

    // Across a line the prefix reading is a fresh operand, not a spacing
    // mistake — so the newline ends the statement and `-b` is the next one.
    var split = Parser.init(alloc, "f :: () -> i64 { g()\n-b }");
    const split_body = (try split.parse()).data.root.decls[0].data.fn_decl.body;
    try std.testing.expectEqual(@as(usize, 2), split_body.data.block.stmts.len);
    try std.testing.expect(split_body.data.block.stmts[0].data == .call);
    try std.testing.expect(split_body.data.block.stmts[1].data.unary_op.op == .negate);
}

test "parser: a prefix `-` / `*` binds only when glued" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ok = Parser.init(alloc, "f :: () -> i64 { x := -5; y := *n; 0 }");
    _ = try ok.parse();

    for ([_][:0]const u8{
        "f :: () -> i64 { x := - 5; 0 }",
        "f :: () -> i64 { y := * n; 0 }",
        "f :: (p: * i64) { }",
    }) |src| {
        const msg = try parseErrMsg(alloc, src);
        try std.testing.expect(std.mem.indexOf(u8, msg, "a prefix operator binds only when glued") != null);
    }
}

// A raw identifier's span excludes its backtick; the whitespace rules read the
// source as typed, so `` *`i2 `` is glued and `` `i2(i64) `` is an application.
test "parser: the glue rules see a raw identifier's backtick" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ok = Parser.init(alloc, "f :: (p: *`i2(i64)) { }");
    _ = try ok.parse();

    const msg = try parseErrMsg(alloc, "f :: (p: * `i2(i64)) { }");
    try std.testing.expect(std.mem.indexOf(u8, msg, "a prefix operator binds only when glued") != null);
}

// A pack index is an index like any other, in an expression as in a type.
test "parser: a pack index binds only when glued" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ok = Parser.init(alloc, "f :: (..$args) -> string { g($args[0]) }");
    const root = try ok.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    try std.testing.expect(body.data.block.stmts[0].data.call.args[0].data == .pack_index_type_expr);

    const spaced = try parseErrMsg(alloc, "f :: (..$args) -> string { g($args [0]) }");
    try std.testing.expect(std.mem.indexOf(u8, spaced, "write `$args[0]`") != null);

    // Across a line the `[` stops binding, leaving the whole pack — no spacing
    // complaint, and the ordinary path reports what follows.
    const split = try parseErrMsg(alloc, "f :: (..$args) -> string { g($args\n[0]) }");
    try std.testing.expect(std.mem.indexOf(u8, split, "a space before `[`") == null);
}

// ---- Statement termination (specs §1: Whitespace is Syntax) ----
//
// A newline ends a statement wherever a `;` would. These pin what the newline
// terminates, what it must NOT, and which token in front of it keeps the
// statement running.

fn parseBody(alloc: std.mem.Allocator, src: [:0]const u8) !*Node {
    var p = Parser.init(alloc, src);
    const root = try p.parse();
    return root.data.root.decls[0].data.fn_decl.body;
}

test "parser: a newline ends a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    a := 1
        \\    b : i64 = 2
        \\    c :: 3
        \\    g(a)
        \\    a = b + c
        \\    if a == b { g(0) }
        \\    defer g(1)
        \\    return a
        \\}
    );
    const stmts = body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 8), stmts.len);
    try std.testing.expect(stmts[0].data == .var_decl);
    try std.testing.expect(stmts[1].data == .var_decl);
    try std.testing.expect(stmts[2].data == .const_decl);
    try std.testing.expect(stmts[3].data == .call);
    try std.testing.expect(stmts[4].data == .assignment);
    try std.testing.expect(stmts[5].data == .if_expr);
    try std.testing.expect(stmts[6].data == .defer_stmt);
    try std.testing.expect(stmts[7].data == .return_stmt);
}

// The declaration forms a file is made of terminate on a newline too.
test "parser: a newline ends a top-level declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = Parser.init(alloc,
        \\#import "modules/std.sx"
        \\TAU :: 6
        \\seed : i64 = 1
        \\puts :: (s: *u8) -> i32 extern
        \\add :: (a: i64, b: i64) -> i64 => a + b
        \\main :: () -> i32 { 0 }
    );
    const decls = (try p.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 6), decls.len);
    try std.testing.expect(decls[0].data == .import_decl);
    try std.testing.expect(decls[1].data == .const_decl);
    try std.testing.expect(decls[2].data == .var_decl);
    try std.testing.expectEqual(ast.ExternExportModifier.extern_, decls[3].data.fn_decl.extern_export);
    try std.testing.expect(decls[4].data.fn_decl.is_arrow);
}

// Demand semantics is a later step: until it lands, `;` before `}` still means
// "discard", so ASI must never insert a terminator there — a `;`-less tail is
// the block's value however it is written.
test "parser: a newline never terminates the tail before `}`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][:0]const u8{
        "f :: () -> i32 { x }",
        "f :: () -> i32 {\nx\n}",
    }) |src| {
        const body = try parseBody(alloc, src);
        try std.testing.expectEqual(@as(usize, 1), body.data.block.stmts.len);
        try std.testing.expect(body.data.block.produces_value);
        try std.testing.expect(body.data.block.discarded_semi == null);
    }

    // The `;` still discards, and still names itself for the diagnostic.
    const discarded = try parseBody(alloc, "f :: () -> i32 {\nx;\n}");
    try std.testing.expect(!discarded.data.block.produces_value);
    try std.testing.expect(discarded.data.block.discarded_semi != null);
}

// A token that cannot start a statement continues the one above it.
test "parser: a continuation token holds the statement open" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    v := (a << 16)
        \\        | b
        \\    w := a
        \\        and b
        \\        or c
        \\    v + w
        \\}
    );
    const stmts = body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 3), stmts.len);
    try std.testing.expectEqual(ast.BinaryOp.Op.bit_or, stmts[0].data.var_decl.value.?.data.binary_op.op);
    try std.testing.expectEqual(ast.BinaryOp.Op.or_op, stmts[1].data.var_decl.value.?.data.binary_op.op);

    // A continuation token that cannot in fact continue is still not a new
    // statement — the terminator it denied is what gets reported.
    for ([_][:0]const u8{
        "f :: () -> i64 { x := a\n, b\n0 }",
        "f :: () -> i64 { x := a\n=> b\n0 }",
        "f :: () -> i64 { x := a\n:: b\n0 }",
    }) |src| {
        const msg = try parseErrMsg(alloc, src);
        try std.testing.expect(std.mem.indexOf(u8, msg, "expected ';'") != null);
    }
}

// `}` then `else` on the next line is one if/else chain, not a statement and
// an orphan.
test "parser: a newline before `else` continues the chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    if c {
        \\        1
        \\    }
        \\    else {
        \\        2
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), body.data.block.stmts.len);
    try std.testing.expect(body.data.block.stmts[0].data.if_expr.else_branch != null);
}

// C1: statements break, expressions chain. A bare scope block in STATEMENT
// position ends at its `}`; an expression that ends in a block does not.
test "parser: a bare scope block statement does not chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const broken = try parseBody(alloc,
        \\f :: () -> Color {
        \\    {
        \\        g()
        \\    }
        \\    .green
        \\}
    );
    try std.testing.expectEqual(@as(usize, 2), broken.data.block.stmts.len);
    try std.testing.expect(broken.data.block.stmts[0].data == .block);

    const chained = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    vstack(1.0) {
        \\        g()
        \\    }
        \\        .show()
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), chained.data.block.stmts.len);
    try std.testing.expect(chained.data.block.stmts[0].data.call.callee.data == .field_access);
}

// The value-less forms take the newline terminator too: a `return` with no
// value, and a `name : type` declaration with no initializer.
test "parser: a newline terminates the value-less forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = try parseBody(alloc,
        \\f :: () -> void {
        \\    slot : i64
        \\    g(slot)
        \\    return
        \\}
    );
    const stmts = body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 3), stmts.len);
    try std.testing.expect(stmts[0].data.var_decl.value == null);
    try std.testing.expect(stmts[1].data == .call);
    try std.testing.expect(stmts[2].data.return_stmt.value == null);

    // A `return` in expression position asks the same question, so the line
    // below an early `then return` is the next statement and not its value.
    const early = try parseBody(alloc,
        \\f :: (c: bool) -> void {
        \\    if c then return
        \\    g()
        \\}
    );
    const early_stmts = early.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 2), early_stmts.len);
    try std.testing.expect(early_stmts[0].data.if_expr.then_branch.data.return_stmt.value == null);
    try std.testing.expect(early_stmts[1].data == .call);

    // A value on the same line still belongs to the `return`.
    const valued = try parseBody(alloc,
        \\f :: (c: bool) -> i64 {
        \\    if c then return 7
        \\    9
        \\}
    );
    const valued_stmts = valued.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 2), valued_stmts.len);
    try std.testing.expect(valued_stmts[0].data.if_expr.then_branch.data.return_stmt.value.?.data == .int_literal);
}

// The last token of a file is followed by a line break like any other, so the
// final declaration needs no terminator either.
test "parser: a newline ends the last declaration in a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = Parser.init(alloc, "TAU :: 6\nseed : i64\n");
    const decls = (try p.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expect(decls[0].data == .const_decl);
    try std.testing.expect(decls[1].data.var_decl.value == null);
}

// An `extern` / `export` tail is two optional bare names, so it binds only on
// the declaration's own line — the name below belongs to the next declaration.
test "parser: an extern tail binds only on its own line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = Parser.init(alloc,
        \\puts :: (s: *u8) -> i32 extern
        \\LIMIT :: 9
    );
    const decls = (try p.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expect(decls[0].data.fn_decl.extern_lib == null);
    try std.testing.expect(decls[0].data.fn_decl.extern_name == null);
    try std.testing.expect(decls[1].data == .const_decl);

    // On its own line the tail still binds.
    var same = Parser.init(alloc, "puts :: (s: *u8) -> i32 extern C \"puts\"\n");
    const bound = (try same.parse()).data.root.decls[0].data.fn_decl;
    try std.testing.expectEqualStrings("C", bound.extern_lib.?);
    try std.testing.expectEqualStrings("puts", bound.extern_name.?);
}
