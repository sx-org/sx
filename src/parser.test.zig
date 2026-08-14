// Parser tests — pin parse-level shapes the example corpus can't isolate
// (the corpus runs the full `sx run` pipeline, never the parser alone).

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const Parser = @import("parser.zig").Parser;

// The comptime type-metaprogramming surface in `library/modules/std/meta.sx`
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
    var parser = try Parser.init(alloc, src);
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

// The `compiler`-library binding surface PARSES — `name :: #library "x";` plus
// the postfix `intrinsic` marker, marking a compiler-domain / compiler-API
// function — no `extern`, no fake `#library`. The
// AST must carry `abi == .compiler`, `extern_export == .none`, `extern_lib ==
// null`, and a synthesized empty-block (bodiless) body.

// A bare `extern` (no abi annotation) leaves `abi == .default`.
test "parser: bare extern leaves abi == .default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\puts :: (s: *u8) -> i32 extern;
        \\
    ;
    var parser = try Parser.init(alloc, src);
    const root = try parser.parse();
    const decls = root.data.root.decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expect(decls[0].data == .fn_decl);
    const fd = decls[0].data.fn_decl;
    try std.testing.expectEqual(ast.ExternExportModifier.extern_, fd.extern_export);
    try std.testing.expectEqual(ast.ABI.default, fd.abi);
}

// `abi(.c)` parses standalone (no extern/export) in the postfix slot of an
// ordinary function pointer / fn decl. And `abi(.naked)` parses (naked-asm ABI).
test "parser: abi(.c) and abi(.naked) parse standalone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\cb :: () -> i64 abi(.c) { 0; }
        \\nk :: () -> i64 abi(.naked) { 0; }
        \\
    ;
    var parser = try Parser.init(alloc, src);
    const root = try parser.parse();
    const decls = root.data.root.decls;
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expect(decls[0].data == .fn_decl);
    try std.testing.expectEqual(ast.ABI.c, decls[0].data.fn_decl.abi);
    try std.testing.expectEqual(ast.ExternExportModifier.none, decls[0].data.fn_decl.extern_export);
    try std.testing.expect(decls[1].data == .fn_decl);
    try std.testing.expectEqual(ast.ABI.naked, decls[1].data.fn_decl.abi);
}

// The postfix `abi(...)` slot PARSES on a STRUCT decl — `Name :: struct
// extern <lib> { … }`. The AST struct_decl carries the abi + the library
// handle in `extern_lib`, with the field list intact. Parse-only: the
// annotation carries no struct semantics (compiler-API types are VM-native).

// An ordinary struct (no binding) leaves `abi == .default` / `extern_lib == null`.
test "parser: plain struct leaves abi == .default, extern_lib == null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\Point :: struct { x: i64; y: i64; }
        \\
    ;
    var parser = try Parser.init(alloc, src);
    const root = try parser.parse();
    const decls = root.data.root.decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expect(decls[0].data == .struct_decl);
    const sd = decls[0].data.struct_decl;
    try std.testing.expectEqual(ast.ABI.default, sd.abi);
    try std.testing.expect(sd.extern_lib == null);
}

// ── Tuple syntax (the inline `(a, b)` type forms are valid alongside it) ──

// `Tuple(A, B)` magic type id → positional tuple_type_expr, mirroring `(A, B)`.
// Exercised in a genuine type position (a fn return type), since a `::` RHS is
// an EXPRESSION position where `Tuple(...)` is an ordinary call.
test "parser: Tuple(A, B) type parses to positional tuple_type_expr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () -> Tuple(i64, i32) { 0 }");
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
    var parser = try Parser.init(arena.allocator(), "f :: () -> Tuple(x: i64, y: i32) { 0 }");
    const root = try parser.parse();
    const t = root.data.root.decls[0].data.fn_decl.return_type.?.data.tuple_type_expr;
    try std.testing.expectEqual(@as(usize, 2), t.field_types.len);
    try std.testing.expect(t.field_names != null);
    try std.testing.expectEqualStrings("x", t.field_names.?[0]);
    try std.testing.expectEqualStrings("y", t.field_names.?[1]);
}

// 1-tuple `Tuple(T)` and empty `Tuple()`. A `Tuple(T)` stays a 1-tuple — unlike
// the inline `(T)`, which is a grouping.
test "parser: Tuple(T) is a 1-tuple, Tuple() is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p1 = try Parser.init(arena.allocator(), "f :: () -> Tuple(i64) { 0 }");
    const r1 = try p1.parse();
    const t1 = r1.data.root.decls[0].data.fn_decl.return_type.?.data.tuple_type_expr;
    try std.testing.expectEqual(@as(usize, 1), t1.field_types.len);

    var p2 = try Parser.init(arena.allocator(), "f :: () -> Tuple() { 0 }");
    const r2 = try p2.parse();
    const t2 = r2.data.root.decls[0].data.fn_decl.return_type.?.data.tuple_type_expr;
    try std.testing.expectEqual(@as(usize, 0), t2.field_types.len);
}

// `Tuple(..Ts)` reuses the spread/pack machinery (spread_expr field). Checked
// in a PARAM type position (the inline `(..Ts)` form parses there too; neither
// spelling parses in bare RETURN position).
test "parser: Tuple(..Ts) pack field is a spread_expr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: (t: Tuple(..Ts)) { }");
    const root = try parser.parse();
    const t = root.data.root.decls[0].data.fn_decl.params[0].type_expr.data.tuple_type_expr;
    try std.testing.expectEqual(@as(usize, 1), t.field_types.len);
    try std.testing.expect(t.field_types[0].data == .spread_expr);
}

// A trailing `->` after `Tuple(...)` is a hard error (no return type).
test "parser: Tuple(A, B) -> C is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () -> Tuple(i64, i64) -> i64 { 0 }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// A bare `Tuple` not followed by `(` stays an ordinary identifier.
test "parser: bare Tuple (no paren) is an identifier, not a tuple type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () -> i64 { Tuple := 1; Tuple }");
    const root = try parser.parse();
    // Parses without error; the body references `Tuple` as a value name.
    try std.testing.expect(root.data.root.decls[0].data == .fn_decl);
}

// `.( )` is a plain parse error.
test "parser: .(a, b) is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { x := .(1, 2); }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// The typed-prefix form `Tuple(A, B).( … )` is rejected too — typed tuple
// construction is `Tuple(A, B){ … }`.
test "parser: Tuple(A, B).( ... ) is rejected after the cutover" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { x := Tuple(i64, i64).(1, 2); }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// The brace literal carries positional, named, and spread elements — the
// spread parses as a positional `spread_expr` init.
test "parser: .{ ..t, 3 } parses spread as a positional field init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { x := .{ ..t, 3 }; }");
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
    var parser = try Parser.init(arena.allocator(), "f :: () { s := .{ x }; }");
    const root = try parser.parse();
    const val = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0].data.var_decl.value.?;
    try std.testing.expect(val.data == .struct_literal);
    const fis = val.data.struct_literal.field_inits;
    try std.testing.expectEqual(@as(usize, 1), fis.len);
    try std.testing.expectEqualStrings("x", fis[0].name.?);
    try std.testing.expect(fis[0].was_shorthand);
}

// The failable result list is `-> (T, !)`; a bare trailing `!` after the value
// type is a parse error.
test "parser: bare `-> T !` is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () -> i64 ! { 0 }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// Likewise `-> Tuple(A, B) !` — write `-> (A, B, !)`.
test "parser: bare `-> Tuple(A, B) !` is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () -> Tuple(i64, i32) !ParseErr { 0 }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// `-> !` (void + error) stays a bare error_type_expr — the trailing-`!` fold
// must NOT double-wrap it.
test "parser: -> ! stays a bare error_type_expr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () -> ! { }");
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .error_type_expr);
}

// Bare-paren `-> (T, !)` is a SINGLE-value failable return: one value slot +
// a trailing error channel. Parses to a `(T, !)` tuple_type_expr —
// NOT a multi-return signature (only ≥2 value slots are `return_type_expr`).
test "parser: -> (T, !) is a single-value failable, not multi-return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () -> (i64, !) { 0 }");
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
    var parser = try Parser.init(arena.allocator(), "f :: () -> (i64, i32) { 0 }");
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .return_type_expr);
    try std.testing.expectEqual(@as(usize, 2), rt.data.return_type_expr.field_types.len);
}

// A bare-paren tuple VALUE `(a, b)` is rejected — tuple values are annotated `.{...}`.
test "parser: bare-paren tuple value (a, b) is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { x := (1, 2); }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// Bare-paren grouping `(a + b)` still works — single inner, no top-level comma.
test "parser: bare-paren grouping (a + b) still parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () -> i64 { (1 + 2) }");
    const root = try parser.parse();
    try std.testing.expect(root.data.root.decls[0].data == .fn_decl);
}

// A closure-type alias `CB :: Closure(i32) -> i32;`
// parses. The const-decl RHS routes a `Closure(...)` head through the
// closure-type parse so the `-> R` tail is consumed. Node shape: a
// `const_decl` whose value is a `closure_type_expr` carrying the return type.
test "parser: closure-type alias in const-decl RHS parses to closure_type_expr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "CB :: Closure(i32) -> i32;");
    const root = try parser.parse();
    const cd = root.data.root.decls[0];
    try std.testing.expect(cd.data == .const_decl);
    const value = cd.data.const_decl.value;
    try std.testing.expect(value.data == .closure_type_expr);
    try std.testing.expectEqual(@as(usize, 1), value.data.closure_type_expr.param_types.len);
    try std.testing.expect(value.data.closure_type_expr.return_type != null);
}

// A NON-Closure call head followed by `->` errors: the magic is `Closure`'s
// alone, never an arbitrary call expression's.
test "parser: non-Closure call followed by '->' still fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "BAD :: foo(1) -> i32;");
    try std.testing.expectError(error.ParseError, parser.parse());
}

// `#context_extend name: Type = default;` parses at top level to a
// `.context_extend_decl` node carrying {name, name_span, type_expr,
// default_expr}; the `= default` clause may be ABSENT (default_expr == null —
// the collection pass rejects it, not the parser); and it
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
    var parser = try Parser.init(alloc, src);
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

// `#context_extend` is top-level-only — statement position is a parse error,
// not a generic expression-parse fallthrough.
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
    var parser = try Parser.init(alloc, src);
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
    var p = try Parser.init(alloc, src);
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
        var p = try Parser.init(alloc, src);
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
    var p = try Parser.init(alloc, ok_src);
    const root = try p.parse();
    try std.testing.expect(root.data == .root);

    const bad_src =
        \\inline if true {
        \\    outer :: () { private x :: 1; }
        \\}
        \\
    ;
    var p2 = try Parser.init(alloc, bad_src);
    try std.testing.expectError(error.ParseError, p2.parse());
}

// ---- Whitespace is syntax (specs §1) ----
//
// A `(` applies, a `[` indexes, and a prefix `-` / `--` / `*` binds its operand
// across any gap — space and line break alike.

fn parseErrMsg(alloc: std.mem.Allocator, src: [:0]const u8) ![]const u8 {
    var p = try Parser.init(alloc, src);
    try std.testing.expectError(error.ParseError, p.parse());
    return p.err_msg orelse return error.MissingMessage;
}

fn parseOne(alloc: std.mem.Allocator, src: [:0]const u8) !*Node {
    var p = try Parser.init(alloc, src);
    const root = try p.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    try std.testing.expectEqual(@as(usize, 1), body.data.block.stmts.len);
    return body.data.block.stmts[0];
}

test "parser: a postfix `(` applies arguments across any gap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][:0]const u8{
        "f :: () -> i64 { g(1) }",
        "f :: () -> i64 { g (1) }",
        "f :: () -> i64 { g\n(1) }",
    }) |src| {
        try std.testing.expect((try parseOne(alloc, src)).data == .call);
    }
}

test "parser: a postfix `[` indexes across any gap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][:0]const u8{
        "f :: () -> i64 { xs[0] }",
        "f :: () -> i64 { xs [0] }",
        "f :: () -> i64 { xs\n[0] }",
    }) |src| {
        try std.testing.expect((try parseOne(alloc, src)).data == .index_expr);
    }
}

test "parser: a type's arguments apply across any gap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][:0]const u8{
        "f :: (b: Box(i64)) { }",
        "f :: (b: Box (i64)) { }",
        "f :: (b: Box\n(i64)) { }",
        "f :: (c: Closure (i64) -> i64) { }",
        "f :: (b: $B/@BuildBlock (Drawable)) { }",
        "V :: @OpenVariant (View) { }",
        "impl Into (Block) for Row { }",
        "BI :: Box (i64);",
        "f :: (p: * `i2 (i64)) { }",
    }) |src| {
        var p = try Parser.init(alloc, src);
        _ = try p.parse();
    }
}

test "parser: `-` is infix wherever a left operand is complete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Every spacing reads as subtraction, on one line or across a break — the
    // line break is ordinary space and a completed left operand is what makes
    // `-` infix.
    for ([_][:0]const u8{
        "f :: () -> i64 { a - b }",
        "f :: () -> i64 { a-b }",
        "f :: () -> i64 { a -b }",
        "f :: () -> i64 { a- b }",
        "f :: () -> i64 { a\n    - b }",
        "f :: () -> i64 { a-\nb }",
        "f :: () -> i64 { a\n-b }",
        "f :: () -> i64 { a\n-`b }",
    }) |src| {
        var p = try Parser.init(alloc, src);
        const root = try p.parse();
        const body = root.data.root.decls[0].data.fn_decl.body;
        try std.testing.expectEqual(@as(usize, 1), body.data.block.stmts.len);
        try std.testing.expect(body.data.block.stmts[0].data == .binary_op);
    }

    // The `;` is what separates the two statements, so `-b` negates only when
    // one is written.
    var split = try Parser.init(alloc, "f :: () -> i64 { g();\n-b }");
    const split_body = (try split.parse()).data.root.decls[0].data.fn_decl.body;
    try std.testing.expectEqual(@as(usize, 2), split_body.data.block.stmts.len);
    try std.testing.expect(split_body.data.block.stmts[0].data == .call);
    try std.testing.expect(split_body.data.block.stmts[1].data.unary_op.op == .negate);
}

test "parser: a prefix `-` / `--` / `*` binds across a space" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][:0]const u8{
        "f :: () -> i64 { x := -5; y := *n; z := --n; 0 }",
        "f :: () -> i64 { x := - 5; y := * n; z := -- n; 0 }",
        "f :: (p: *i64) { }",
        "f :: (p: * i64) { }",
        "f :: (p: *`i2) { }",
        "f :: (p: * `i2) { }",
    }) |src| {
        var p = try Parser.init(alloc, src);
        _ = try p.parse();
    }
}

// A pack index is an index like any other, in an expression as in a type.
test "parser: a pack index binds across a space" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][:0]const u8{
        "f :: (..$args) -> string { g($args[0]) }",
        "f :: (..$args) -> string { g($args [0]) }",
    }) |src| {
        try std.testing.expect((try parseOne(alloc, src)).data.call.args[0].data == .pack_index_type_expr);
    }
}

// ---- Statement termination (specs §1: Whitespace is Syntax) ----
//
// `;` ends a statement; a line break is ordinary space. These pin the
// positions that end a statement on their own — the `}` that closes the
// enclosing block, a block-form initializer's own `}`, the end of the file —
// and the report everywhere else.

fn parseBody(alloc: std.mem.Allocator, src: [:0]const u8) !*Node {
    var p = try Parser.init(alloc, src);
    const root = try p.parse();
    return root.data.root.decls[0].data.fn_decl.body;
}

test "parser: a `;` ends a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    a := 1;
        \\    b : i64 = 2;
        \\    c :: 3;
        \\    g(a);
        \\    a = b + c;
        \\    if a == b { g(0) }
        \\    defer g(1);
        \\    return a;
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

// A line break is space, so a mid-block statement that omits its `;` runs into
// the one below and the report names the terminator.
test "parser: a mid-block statement without its `;` is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][:0]const u8{
        "f :: () -> i64 { a := 1\n g(a); 0 }",
        "f :: () -> i64 { g(a)\n defer h(); 0 }",
        "f :: () -> i64 { return 1\n 0 }",
    }) |src| {
        const msg = try parseErrMsg(alloc, src);
        try std.testing.expect(std.mem.indexOf(u8, msg, "expected ';'") != null);
    }

    // A `name : T` with no initializer is complete, so the report names the
    // terminator alongside the tails the declaration could still take.
    const typed = try parseErrMsg(alloc, "f :: () -> void { slot : i64\n g(slot); }");
    try std.testing.expect(std.mem.indexOf(u8, typed, "expected ':', '=', ';', or 'extern'") != null);
}

// The declaration forms a file is made of take the same `;`; the last one ends
// at the end of the file.
test "parser: a `;` ends a top-level declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = try Parser.init(alloc,
        \\#import "modules/std.sx";
        \\TAU :: 6;
        \\seed : i64 = 1;
        \\puts :: (s: *u8) -> i32 extern;
        \\add :: (a: i64, b: i64) -> i64 => a + b;
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

// The tail before `}` reads the same written either way: `;` is a separator,
// so a tail that carries one and a tail that omits it leave the same block
// value.
test "parser: the tail before `}` is the block's value however it is written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][:0]const u8{
        "f :: () -> i32 { x }",
        "f :: () -> i32 {\nx\n}",
        "f :: () -> i32 { x; }",
        "f :: () -> i32 {\nx;\n}",
    }) |src| {
        const body = try parseBody(alloc, src);
        try std.testing.expectEqual(@as(usize, 1), body.data.block.stmts.len);
        try std.testing.expect(body.data.block.produces_value);
    }
}

// A nested body classifies its own statements only. Each of these ends its
// INNER tail with a `;`-ended expression while the OUTER tail is a form that
// carries no value — a `::` binding, an assignment, a `defer`. The outer block
// must stay value-less: a nested tail that reclassified its enclosing statement
// would hand the position a void to bind.
test "parser: a nested tail never reclassifies the statement that encloses it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][:0]const u8{
        // A local function whose body ends in a `;`-ended expression.
        "f :: () -> i32 {\nlocal :: () -> i32 { 42; }\n}",
        // A `::` binding to a block expression with a `;`-ended tail.
        "f :: () -> i32 {\nv :: { 1; }\n}",
        // An assignment whose RHS branches both end in `;`.
        "f :: () -> i32 {\nz = if c { 1; } else { 2; };\n}",
        // A match arm ending in a `;`-ended expression.
        "f :: () -> i32 {\nz = match s { case 0: 1; else: 2; };\n}",
        // A `for` arrow body — one statement parsed in place, not a block.
        "f :: () -> i32 {\ndefer { for xs => g(x); }\n}",
        // A `defer` whose braced body ends in a `;`-ended expression.
        "f :: () -> i32 {\ndefer { 1; }\n}",
    }) |src| {
        const body = try parseBody(alloc, src);
        try std.testing.expectEqual(@as(usize, 1), body.data.block.stmts.len);
        try std.testing.expect(!body.data.block.produces_value);
    }
}

// The other half of the isolation: the nested body still classifies ITSELF
// correctly — the local function's `42;` is that function's return value.
test "parser: an isolated nested body keeps its own tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = try parseBody(alloc, "f :: () -> i32 {\nlocal :: () -> i32 { 42; }\n}");
    const inner = body.data.block.stmts[0].data.fn_decl.body;
    try std.testing.expect(inner.data.block.produces_value);
}

// An unterminated statement reads on through the line break, so an operator
// below it is its own continuation.
test "parser: a statement without its `;` reads on across the break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    v := (a << 16)
        \\        | b;
        \\    w := a
        \\        and b
        \\        or c;
        \\    v + w
        \\}
    );
    const stmts = body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 3), stmts.len);
    try std.testing.expectEqual(ast.BinaryOp.Op.bit_or, stmts[0].data.var_decl.value.?.data.binary_op.op);
    try std.testing.expectEqual(ast.BinaryOp.Op.or_op, stmts[1].data.var_decl.value.?.data.binary_op.op);

    // A token that cannot continue the expression it lands under is the
    // missing terminator, reported as such.
    for ([_][:0]const u8{
        "f :: () -> i64 { x := a\n, b;\n0 }",
        "f :: () -> i64 { x := a\n=> b;\n0 }",
        "f :: () -> i64 { x := a\n:: b;\n0 }",
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

// Statements break, expressions chain. A bare scope block in STATEMENT
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

// The value-less forms take the same `;`: a `return` with no value, and a
// `name : type` declaration with no initializer.
test "parser: a `;` terminates the value-less forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = try parseBody(alloc,
        \\f :: () -> void {
        \\    slot : i64;
        \\    g(slot);
        \\    return;
        \\}
    );
    const stmts = body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 3), stmts.len);
    try std.testing.expect(stmts[0].data.var_decl.value == null);
    try std.testing.expect(stmts[1].data == .call);
    try std.testing.expect(stmts[2].data.return_stmt.value == null);

    // A `return` in expression position asks the same question, so the
    // statement after an early `then return;` is not the value it returns.
    const early = try parseBody(alloc,
        \\f :: (c: bool) -> void {
        \\    if c then return;
        \\    g();
        \\}
    );
    const early_stmts = early.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 2), early_stmts.len);
    try std.testing.expect(early_stmts[0].data.if_expr.then_branch.data.return_stmt.value == null);
    try std.testing.expect(early_stmts[1].data == .call);

    // A value before the `;` still belongs to the `return`.
    const valued = try parseBody(alloc,
        \\f :: (c: bool) -> i64 {
        \\    if c then return 7;
        \\    9
        \\}
    );
    const valued_stmts = valued.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 2), valued_stmts.len);
    try std.testing.expect(valued_stmts[0].data.if_expr.then_branch.data.return_stmt.value.?.data == .int_literal);
}

// Nothing follows the last declaration of a file for it to run into, so the
// end of the file ends it.
test "parser: the end of the file ends the last declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = try Parser.init(alloc, "TAU :: 6;\nseed : i64\n");
    const decls = (try p.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expect(decls[0].data == .const_decl);
    try std.testing.expect(decls[1].data.var_decl.value == null);
}

// ---- Linkage tails ----
//
// `[LIB] ["csym"]` after `extern` / `export` is two optional bare names, and the
// declaration's `;` is what closes the tail. A line break inside it is ordinary
// whitespace, so both slots read on through one.

// An empty tail is closed by the declaration's own `;`.
test "parser: an extern tail is closed by its `;`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = try Parser.init(alloc,
        \\puts :: (s: *u8) -> i32 extern;
        \\LIMIT :: 9;
    );
    const decls = (try p.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expect(decls[0].data.fn_decl.extern_lib == null);
    try std.testing.expect(decls[0].data.fn_decl.extern_name == null);
    try std.testing.expect(decls[1].data == .const_decl);

    // Without the `;` the declaration below runs into the tail, and the report
    // names the terminator.
    const merged = try parseErrMsg(alloc,
        \\puts :: (s: *u8) -> i32 extern
        \\LIMIT :: 9;
    );
    try std.testing.expect(std.mem.indexOf(u8, merged, "expected ';'") != null);

    var same = try Parser.init(alloc, "puts :: (s: *u8) -> i32 extern C \"puts\";\n");
    const bound = (try same.parse()).data.root.decls[0].data.fn_decl;
    try std.testing.expectEqualStrings("C", bound.extern_lib.?);
    try std.testing.expectEqualStrings("puts", bound.extern_name.?);
}

// The data-global `extern` tail is closed the same way.
test "parser: an extern data tail is closed by its `;`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = try Parser.init(alloc,
        \\errno_loc : *i32 extern;
        \\LIMIT :: 9;
    );
    const decls = (try p.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expect(decls[0].data.var_decl.is_extern);
    try std.testing.expect(decls[0].data.var_decl.extern_lib == null);
    try std.testing.expect(decls[0].data.var_decl.extern_name == null);
    try std.testing.expect(decls[1].data == .const_decl);

    var same = try Parser.init(alloc, "errno_loc : *i32 extern libc \"__error\";\n");
    const bound = (try same.parse()).data.root.decls[0].data.var_decl;
    try std.testing.expectEqualStrings("libc", bound.extern_lib.?);
    try std.testing.expectEqualStrings("__error", bound.extern_name.?);
}

// Both slots read on through a line break.
test "parser: an export tail reads through a line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = try Parser.init(alloc,
        \\seven :: () -> i64 export
        \\"renamed_c"
        \\{ 7 }
    );
    const fd = (try p.parse()).data.root.decls[0].data.fn_decl;
    try std.testing.expect(fd.extern_lib == null);
    try std.testing.expectEqualStrings("renamed_c", fd.extern_name.?);
    try std.testing.expectEqual(@as(usize, 1), fd.body.data.block.stmts.len);

    var with_lib = try Parser.init(alloc,
        \\seven :: () -> i64 export
        \\C
        \\"renamed_c"
        \\{ 7 }
    );
    const lib_fd = (try with_lib.parse()).data.root.decls[0].data.fn_decl;
    try std.testing.expectEqualStrings("C", lib_fd.extern_lib.?);
    try std.testing.expectEqualStrings("renamed_c", lib_fd.extern_name.?);

    var same = try Parser.init(alloc, "seven :: () -> i64 export C \"renamed_c\" { 7 }\n");
    const same_fd = (try same.parse()).data.root.decls[0].data.fn_decl;
    try std.testing.expectEqualStrings("C", same_fd.extern_lib.?);
    try std.testing.expectEqualStrings("renamed_c", same_fd.extern_name.?);
}

// A struct's `{ … }` is unconditional, so its tail reads through too.
test "parser: a struct linkage tail reads through a line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = try Parser.init(alloc,
        \\Handle :: struct abi(.c) extern
        \\compiler
        \\{ x: i64; }
    );
    const sd = (try p.parse()).data.root.decls[0].data.struct_decl;
    try std.testing.expectEqualStrings("compiler", sd.extern_lib.?);
    try std.testing.expectEqual(ast.ABI.c, sd.abi);
    try std.testing.expectEqual(@as(usize, 1), sd.field_names.len);

    var same = try Parser.init(alloc, "Handle :: struct abi(.c) extern compiler { x: i64; }\n");
    const same_sd = (try same.parse()).data.root.decls[0].data.struct_decl;
    try std.testing.expectEqualStrings("compiler", same_sd.extern_lib.?);
    try std.testing.expectEqual(@as(usize, 1), same_sd.field_names.len);
}

// A `name : T` (or `name :: value`) is a whole declaration without a tail, so
// it asks whether it ended before dispatching on the token below. A tail reads
// on through a line break like any other unterminated statement.
test "parser: a complete binding asks whether it ended before its tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `extern` below a complete `name : T`.
    var ext = try Parser.init(alloc,
        \\errno_loc : *i32
        \\    extern libc "__error"
    );
    const ext_decls = (try ext.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 1), ext_decls.len);
    try std.testing.expect(ext_decls[0].data.var_decl.is_extern);
    try std.testing.expectEqualStrings("libc", ext_decls[0].data.var_decl.extern_lib.?);
    try std.testing.expectEqualStrings("__error", ext_decls[0].data.var_decl.extern_name.?);

    // A split `:` still makes a typed constant.
    var col = try Parser.init(alloc,
        \\LIMIT : i64
        \\    : 1
    );
    const col_decls = (try col.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 1), col_decls.len);
    try std.testing.expect(col_decls[0].data.const_decl.type_annotation != null);
    try std.testing.expect(col_decls[0].data.const_decl.value.data == .int_literal);

    // A split `=` still makes a typed variable.
    var eq = try Parser.init(alloc,
        \\seed : i64
        \\    = 7
    );
    const eq_decls = (try eq.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 1), eq_decls.len);
    try std.testing.expect(eq_decls[0].data.var_decl.value.?.data == .int_literal);

    // A split `intrinsic` still annotates the constant.
    var intr = try Parser.init(alloc,
        \\mystery :: i64
        \\    intrinsic
    );
    const intr_decls = (try intr.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 1), intr_decls.len);
    try std.testing.expect(intr_decls[0].data.const_decl.value.data == .intrinsic_expr);
    try std.testing.expect(intr_decls[0].data.const_decl.type_annotation != null);

    // The ordinary next statement the reorder must still recognize: a bare
    // `name : T` closed by its `;`, followed by an unrelated declaration.
    var plain = try Parser.init(alloc,
        \\slot : i64;
        \\LIMIT :: 9;
    );
    const plain_decls = (try plain.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 2), plain_decls.len);
    try std.testing.expect(plain_decls[0].data.var_decl.value == null);
    try std.testing.expect(!plain_decls[0].data.var_decl.is_extern);
    try std.testing.expect(plain_decls[1].data == .const_decl);
}

// A binary operator below an unterminated expression continues it — the Pratt
// loop consumes it before any terminator query runs.
test "parser: a binary operator below a statement continues it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    inline for (.{ "+", "==", "!=", "<=", ">=", "<<", ">>", "|", "??", "<", ">", "/", "%", "&", "^" }) |op| {
        const body = try parseBody(alloc, "f :: () -> i64 {\n    a := 1\n    " ++ op ++ " 2\n}");
        try std.testing.expectEqual(@as(usize, 1), body.data.block.stmts.len);
    }
    // The same-line controls parse to the same single statement.
    inline for (.{ "+", "<", "&" }) |op| {
        const body = try parseBody(alloc, "f :: () -> i64 {\n    a := 1 " ++ op ++ " 2\n}");
        try std.testing.expectEqual(@as(usize, 1), body.data.block.stmts.len);
    }
}

// The assignment operators continue the same way — the assignment dispatch
// consumes them directly.
test "parser: an assignment operator below a target continues it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    inline for (.{ "=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=" }) |op| {
        // Bare-name target (the identifier fast path).
        const bare = try parseBody(alloc, "f :: () -> i64 {\n    a := 1;\n    a\n    " ++ op ++ " 2;\n    a\n}");
        try std.testing.expectEqual(@as(usize, 3), bare.data.block.stmts.len);
        // Field target (the general expression-target path).
        const field = try parseBody(alloc, "f :: (p: Point) -> i64 {\n    p.x\n    " ++ op ++ " 2;\n    0\n}");
        try std.testing.expectEqual(@as(usize, 2), field.data.block.stmts.len);
        // Same-line control.
        const same = try parseBody(alloc, "f :: () -> i64 {\n    a := 1;\n    a " ++ op ++ " 2;\n    a\n}");
        try std.testing.expectEqual(@as(usize, 3), same.data.block.stmts.len);
    }

    // `::` below a bare name continues it too — a declaration head.
    const decl = try parseBody(alloc, "f :: () -> i64 {\n    N\n    :: 3;\n    N\n}");
    try std.testing.expectEqual(@as(usize, 2), decl.data.block.stmts.len);
    try std.testing.expect(decl.data.block.stmts[0].data == .const_decl);
}

// ---- The binding layer ----
//
// `!` attaches to what precedes it only on that expression's own line, because
// across a break it is the prefix `not`. Every other postfix — `{`, `.`, `?.`,
// `catch` — carries one reading and binds wherever the statement is still open,
// so only a `;` cuts it off.

// `!` is postfix force-unwrap and prefix `not`, so which one a leading `!`
// spells is decided by the line it sits on.
test "parser: a postfix `!` binds only on its own line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const split = try parseBody(alloc,
        \\f :: (a: bool) -> i64 {
        \\    a;
        \\    !a;
        \\    0
        \\}
    );
    try std.testing.expectEqual(@as(usize, 3), split.data.block.stmts.len);
    try std.testing.expect(split.data.block.stmts[0].data == .identifier);
    try std.testing.expectEqual(ast.UnaryOp.Op.not, split.data.block.stmts[1].data.unary_op.op);

    const same = try parseBody(alloc,
        \\f :: (a: ?i64) -> i64 {
        \\    a!
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), same.data.block.stmts.len);
    try std.testing.expect(same.data.block.stmts[0].data == .force_unwrap);
}

// The `;` is what makes the head a statement of its own and the brace group
// after it a scope block, whatever the head was: a type name, a type
// application, or a value call. Without it the brace juxtaposes.
test "parser: `;` cuts a statement off from the brace group after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const type_name = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    Pair;
        \\    { g() }
        \\    0
        \\}
    );
    try std.testing.expectEqual(@as(usize, 3), type_name.data.block.stmts.len);
    try std.testing.expect(type_name.data.block.stmts[0].data == .identifier);
    try std.testing.expect(type_name.data.block.stmts[1].data == .block);

    const value_call = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    mk();
        \\    { g() }
        \\    0
        \\}
    );
    try std.testing.expectEqual(@as(usize, 3), value_call.data.block.stmts.len);
    try std.testing.expect(value_call.data.block.stmts[0].data == .call);
    try std.testing.expect(value_call.data.block.stmts[1].data == .block);

    const type_app = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    Box(i64);
        \\    { g() }
        \\    0
        \\}
    );
    try std.testing.expectEqual(@as(usize, 3), type_app.data.block.stmts.len);
    try std.testing.expect(type_app.data.block.stmts[0].data == .call);
    try std.testing.expect(type_app.data.block.stmts[1].data == .block);

    // Without the `;` the statement is still open, so the brace juxtaposes
    // across the break.
    const wrapped = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    Box(i64)
        \\    { g() }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), wrapped.data.block.stmts.len);
    try std.testing.expect(wrapped.data.block.stmts[0].data == .juxtaposition);

    const aggregate = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    Pair{ a = 1, b = 2 }
        \\}
    );
    try std.testing.expect(aggregate.data.block.stmts[0].data == .juxtaposition);

    const applied = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    Box(i64){ v = 1 }
        \\}
    );
    try std.testing.expect(applied.data.block.stmts[0].data == .juxtaposition);

    const trailing = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    vstack(8) { g() }
        \\}
    );
    const jx = trailing.data.block.stmts[0].data.juxtaposition;
    try std.testing.expect(jx.expr.data == .call);
    try std.testing.expect(!jx.has_header);
}

// ---- Declaration headers across a line break ----
//
// A line break inside a declaration header is ordinary whitespace, so an
// optional slot written on its own line still belongs to the header above it.
// Each slot below is identifier-shaped — the shape that most resembles a
// declaration of its own.

// Enum `flags` and the backing type.
test "parser: an enum header reads through a line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = try Parser.init(alloc,
        \\Perms :: enum
        \\    flags
        \\    u32
        \\    { read; write; }
    );
    const ed = (try p.parse()).data.root.decls[0].data.enum_decl;
    try std.testing.expect(ed.is_flags);
    try std.testing.expect(ed.backing_type != null);
    try std.testing.expectEqual(@as(usize, 2), ed.variant_names.len);

    var same = try Parser.init(alloc, "Perms :: enum flags u32 { read; write; }\n");
    const same_ed = (try same.parse()).data.root.decls[0].data.enum_decl;
    try std.testing.expect(same_ed.is_flags);
    try std.testing.expect(same_ed.backing_type != null);
}

// A `ufcs` alias names its target after the keyword.
test "parser: a ufcs alias target reads through a line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = try Parser.init(alloc,
        \\multiply :: ufcs
        \\    mat4_multiply
    );
    const decls = (try p.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expectEqualStrings("mat4_multiply", decls[0].data.ufcs_alias.target);

    var same = try Parser.init(alloc, "multiply :: ufcs mat4_multiply\n");
    try std.testing.expectEqualStrings("mat4_multiply", (try same.parse()).data.root.decls[0].data.ufcs_alias.target);
}

// A runtime class's linkage word sits in front of a mandatory body.
test "parser: a runtime-class linkage word reads through a line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = try Parser.init(alloc,
        \\NSString :: #objc_class("NSString")
        \\    extern
        \\    { length :: (self: *Self) -> i32; }
    );
    const rc = (try p.parse()).data.root.decls[0].data.runtime_class_decl;
    try std.testing.expect(rc.is_extern);

    var same = try Parser.init(alloc, "NSString :: #objc_class(\"NSString\") extern { length :: (self: *Self) -> i32; }\n");
    try std.testing.expect((try same.parse()).data.root.decls[0].data.runtime_class_decl.is_extern);
}

// A struct's type-parameter list sits in front of a mandatory `{`.
test "parser: a struct type-parameter list reads through a line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = try Parser.init(alloc,
        \\Box :: struct
        \\    ($T: Type)
        \\    { v: T; }
    );
    const sd = (try p.parse()).data.root.decls[0].data.struct_decl;
    try std.testing.expectEqual(@as(usize, 1), sd.type_params.len);
    try std.testing.expectEqual(@as(usize, 1), sd.field_names.len);

    var same = try Parser.init(alloc, "Box :: struct($T: Type) { v: T; }\n");
    try std.testing.expectEqual(@as(usize, 1), (try same.parse()).data.root.decls[0].data.struct_decl.type_params.len);
}

// A protocol's kind word sits in front of a mandatory `{`.
test "parser: a protocol kind word reads through a line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = try Parser.init(alloc,
        \\Lerpable :: protocol
        \\    inline
        \\    { lerp :: (self: *Self, t: f32) -> Self; }
    );
    const pd = (try p.parse()).data.root.decls[0].data.protocol_decl;
    try std.testing.expectEqual(ast.ProtocolKind.@"inline", pd.kind);

    var same = try Parser.init(alloc, "Lerpable :: protocol inline { lerp :: (self: *Self, t: f32) -> Self; }\n");
    try std.testing.expectEqual(ast.ProtocolKind.@"inline", (try same.parse()).data.root.decls[0].data.protocol_decl.kind);
}

// A function header's optional slots all sit in front of a mandatory body.
test "parser: a function header reads through a line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = try Parser.init(alloc,
        \\cb :: ()
        \\    -> i64
        \\    abi(.c)
        \\    { 0 }
    );
    const fd = (try p.parse()).data.root.decls[0].data.fn_decl;
    try std.testing.expect(fd.return_type != null);
    try std.testing.expectEqual(ast.ABI.c, fd.abi);
    try std.testing.expectEqual(@as(usize, 1), fd.body.data.block.stmts.len);
}

// `#context_extend`'s default is optional; the `;` is what ends the
// declaration, so a split default still binds.
test "parser: a #context_extend default reads through a line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var split = try Parser.init(alloc,
        \\#context_extend depth: i64
        \\    = 3
    );
    const split_decls = (try split.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 1), split_decls.len);
    try std.testing.expect(split_decls[0].data.context_extend_decl.default_expr != null);

    var same = try Parser.init(alloc, "#context_extend depth: i64 = 3\n");
    try std.testing.expect((try same.parse()).data.root.decls[0].data.context_extend_decl.default_expr != null);

    // Absent default, and the declaration below is its own.
    var bare = try Parser.init(alloc,
        \\#context_extend depth: i64;
        \\LIMIT :: 9;
    );
    const bare_decls = (try bare.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 2), bare_decls.len);
    try std.testing.expect(bare_decls[0].data.context_extend_decl.default_expr == null);
}

// A value inside a fixed delimiter is owned by that delimiter: the list
// runs to its closer, so a line break inside it never ends anything.
test "parser: values inside fixed delimiters read through a line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A struct field's default.
    var field = try Parser.init(alloc,
        \\Cfg :: struct {
        \\    depth: i64
        \\        = 3;
        \\}
    );
    const sd = (try field.parse()).data.root.decls[0].data.struct_decl;
    try std.testing.expect(sd.field_defaults[0] != null);

    // A parameter's default, and an argument split across lines.
    const body = try parseBody(alloc,
        \\f :: (
        \\    a: i64
        \\        = 1,
        \\    b: i64
        \\) -> i64 {
        \\    g(
        \\        a,
        \\        b
        \\    )
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), body.data.block.stmts.len);
    try std.testing.expectEqual(@as(usize, 2), body.data.block.stmts[0].data.call.args.len);

    // An aggregate's named values.
    const agg = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    p := Point{
        \\        x = 1,
        \\        y = 2,
        \\    };
        \\    p.x
        \\}
    );
    try std.testing.expectEqual(@as(usize, 2), agg.data.block.stmts.len);
    try std.testing.expect(agg.data.block.stmts[0].data.var_decl.value.?.data == .juxtaposition);
}

// The dot-led postfixes chain across a break, on the paths that own them.
test "parser: `?.` and `catch` continue across a line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opt = try parseBody(alloc,
        \\f :: (p: ?Point) -> i64 {
        \\    p
        \\        ?.x
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), opt.data.block.stmts.len);

    const failable = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    g()
        \\        catch |e| 0
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), failable.data.block.stmts.len);
    try std.testing.expect(failable.data.block.stmts[0].data == .catch_expr);
}

// A fixed form's own list keeps its literal separator.
test "parser: a fixed form's list still demands its `;`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `#import c { … }` entries.
    _ = try parseErrMsg(alloc,
        \\c :: #import c {
        \\    #include "stdio.h"
        \\}
    );
    var c_ok = try Parser.init(alloc,
        \\c :: #import c {
        \\    #include "stdio.h";
        \\}
    );
    _ = try c_ok.parse();

    // Runtime-class members.
    _ = try parseErrMsg(alloc,
        \\NSString :: #objc_class("NSString") extern {
        \\    length :: (self: *Self) -> i32
        \\}
    );
}

// An arm body is an ordinary statement list, so every statement in it takes
// its `;` — the `case` below is a statement head, not a terminator.
test "parser: an arm's statements take their `;`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = try parseBody(alloc,
        \\f :: (v: i64) -> i64 {
        \\    match v {
        \\        case 1:
        \\            g();
        \\            10;
        \\        case 2: break;
        \\        case 3: |e| e;
        \\        else:
        \\            0
        \\    }
        \\}
    );
    const match = body.data.block.stmts[0].data.match_expr;
    try std.testing.expectEqual(@as(usize, 4), match.arms.len);
    try std.testing.expectEqual(@as(usize, 2), match.arms[0].body.data.block.stmts.len);
    try std.testing.expect(match.arms[1].is_break);
    try std.testing.expect(match.arms[3].pattern == null);

    // A statement that runs into the next `case` is missing its `;`.
    _ = try parseErrMsg(alloc, "f :: (v: i64) -> i64 { match v { case 1: 10 case 2: 20 } }");
}

// `else` followed by a `:` heads the default arm; every other `else` chains
// the `if` above it, across a line break included.
test "parser: a `:` separates a default arm from a chaining `else`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // An arm-final `if` with no `else` of its own: the `else:` below it is the
    // default arm, not that `if`'s branch.
    const body = try parseBody(alloc,
        \\f :: (v: i64) -> i64 {
        \\    n := 0;
        \\    match v {
        \\        case 1:
        \\            if n == 0 {
        \\                n = 1;
        \\            }
        \\        else:
        \\            n = 3;
        \\    }
        \\    n
        \\}
    );
    const match = body.data.block.stmts[1].data.match_expr;
    try std.testing.expectEqual(@as(usize, 2), match.arms.len);
    try std.testing.expect(match.arms[0].body.data.block.stmts[0].data.if_expr.else_branch == null);
    try std.testing.expect(match.arms[1].pattern == null);

    // The arm-final `if` DOES take a chaining `else`, and `else:` still opens
    // the default arm after it.
    const chained_arm = try parseBody(alloc,
        \\f :: (v: i64) -> i64 {
        \\    n := 0;
        \\    match v {
        \\        case 1:
        \\            if n == 0 {
        \\                n = 1;
        \\            }
        \\            else {
        \\                n = 2;
        \\            }
        \\        else:
        \\            n = 3;
        \\    }
        \\    n
        \\}
    );
    const chained_match = chained_arm.data.block.stmts[1].data.match_expr;
    try std.testing.expectEqual(@as(usize, 2), chained_match.arms.len);
    try std.testing.expect(chained_match.arms[0].body.data.block.stmts[0].data.if_expr.else_branch != null);
    try std.testing.expect(chained_match.arms[1].pattern == null);

    // Without the match, the same `}` NEWLINE `else` still chains.
    const chain = try parseBody(alloc,
        \\f :: () -> i64 {
        \\    if c {
        \\        1
        \\    }
        \\    else {
        \\        2
        \\    }
        \\}
    );
    try std.testing.expect(chain.data.block.stmts[0].data.if_expr.else_branch != null);

    // The gap before the `:` says nothing — `else :` heads the default arm too.
    const spaced = try parseBody(alloc,
        \\f :: (v: i64) -> i64 {
        \\    n := 0;
        \\    match v {
        \\        case 1: n = 1;
        \\        else :
        \\            n = 3;
        \\    }
        \\    n
        \\}
    );
    const spaced_match = spaced.data.block.stmts[1].data.match_expr;
    try std.testing.expectEqual(@as(usize, 2), spaced_match.arms.len);
    try std.testing.expect(spaced_match.arms[1].pattern == null);
}

test "parser: an `@` function declaration is its signature, with an intrinsic body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(),
        \\@va_arg :: ($T: Type, list: *@VaList) -> T;
        \\@va_end :: (list: *@VaList);
    );
    const root = try parser.parse();
    const decls = root.data.root.decls;
    try std.testing.expectEqual(@as(usize, 2), decls.len);

    const arg = decls[0].data.fn_decl;
    try std.testing.expectEqualStrings("@va_arg", arg.name);
    try std.testing.expect(arg.body.data == .intrinsic_expr);
    try std.testing.expectEqual(@as(usize, 2), arg.params.len);
    try std.testing.expect(arg.return_type != null);

    // An omitted return annotation is sx's canonical void.
    const end = decls[1].data.fn_decl;
    try std.testing.expectEqualStrings("@va_end", end.name);
    try std.testing.expect(end.body.data == .intrinsic_expr);
    try std.testing.expect(end.return_type == null);
}

test "parser: an `@` function declaration takes no `intrinsic` marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "@va_end :: (list: *@VaList) intrinsic;");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "parser: an `@` function declaration takes no body, ABI, or linkage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    for ([_][:0]const u8{
        "@f :: (n: i32) -> i32 { return n; }",
        "@f :: (n: i32) -> i32 => n;",
        "@f :: (n: i32) -> i32 abi(.c);",
        "@f :: (n: i32) -> i32 extern;",
        "@f :: (n: i32) -> i32 export;",
    }) |src| {
        var p = try Parser.init(alloc, src);
        try std.testing.expectError(error.ParseError, p.parse());
    }
}

test "parser: a plain bodyless signature is a function-type alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "Fn :: (list: *i32) -> i32;");
    const root = try parser.parse();
    try std.testing.expect(root.data.root.decls[0].data != .fn_decl);
}

test "parser: a bare `..` tail sets the signature flag and binds no parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(),
        \\one :: (n: i32, ..) -> i64 abi(.c) { 0 }
        \\zero :: (..) -> i64 abi(.c) { 0 }
        \\imported :: (fmt: cstring, ..) -> i32 extern;
    );
    const root = try parser.parse();
    const decls = root.data.root.decls;

    const one = decls[0].data.fn_decl;
    try std.testing.expect(one.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 1), one.params.len);

    // Zero fixed parameters is an ordinary count, not a separate case.
    const zero = decls[1].data.fn_decl;
    try std.testing.expect(zero.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 0), zero.params.len);

    const imported = decls[2].data.fn_decl;
    try std.testing.expect(imported.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 1), imported.params.len);
}

test "parser: a tail takes sx's ordinary trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(),
        \\one :: (n: i32, ..,) -> i64 abi(.c) { 0 }
        \\zero :: (..,) -> i64 abi(.c) { 0 }
    );
    const root = try parser.parse();
    try std.testing.expect(root.data.root.decls[0].data.fn_decl.is_c_variadic);
    try std.testing.expect(root.data.root.decls[1].data.fn_decl.is_c_variadic);
}

test "parser: a tail is legal only on an effective-C signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    for ([_][:0]const u8{
        "f :: (n: i32, ..) -> i32 { 0 }", // default convention
        "f :: (n: i32, ..) -> i32 abi(.naked) { 0 }",
        "f :: (n: i32, .., x: i32) -> i32 abi(.c) { 0 }", // not the last entry
        "f :: (n: i32, ..args: []i32, ..) -> i32 abi(.c) { 0 }", // two tails
        "@f :: (n: i32, ..) -> i32;",
    }) |src| {
        var p = try Parser.init(alloc, src);
        try std.testing.expectError(error.ParseError, p.parse());
    }
}

// A spread always carries an operand and the tail never does: one token of
// lookahead separates them.
test "parser: a named variadic form does not set the C-tail flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(),
        \\pack :: (..$args) -> i64 { 0 }
        \\slice :: (n: i32, ..xs: []i32) -> i64 { 0 }
    );
    const root = try parser.parse();
    const pack = root.data.root.decls[0].data.fn_decl;
    try std.testing.expect(!pack.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 1), pack.params.len);
    try std.testing.expect(pack.params[0].is_variadic);

    const slice = root.data.root.decls[1].data.fn_decl;
    try std.testing.expect(!slice.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 2), slice.params.len);
    try std.testing.expect(slice.params[1].is_variadic);
}

// sx has no three-dot token: a three-dot list is `..` then `.` — neither `)`
// nor `,`, so it reads as a named form missing its name.
test "parser: a three-dot parameter list is not a tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: (n: i32, ...) -> i32 abi(.c) { 0 }");
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqualStrings("expected parameter name", parser.err_msg.?);
}

test "parser: a function type carries the bare `..` tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(),
        \\Callback :: (fixed: i32, ..) -> i64 abi(.c);
        \\Zero :: (..) -> i64 abi(.c);
        \\Comma :: (fixed: i32, ..,) -> i64 abi(.c);
        \\Fixed :: (fixed: i32) -> i64 abi(.c);
    );
    const root = try parser.parse();
    const decls = root.data.root.decls;

    const callback = decls[0].data.const_decl.value.data.function_type_expr;
    try std.testing.expect(callback.is_c_variadic);
    try std.testing.expectEqual(ast.ABI.c, callback.abi);
    try std.testing.expectEqual(@as(usize, 1), callback.param_types.len);

    // Zero fixed parameters is an ordinary count, not a separate case.
    const zero = decls[1].data.const_decl.value.data.function_type_expr;
    try std.testing.expect(zero.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 0), zero.param_types.len);

    try std.testing.expect(decls[2].data.const_decl.value.data.function_type_expr.is_c_variadic);
    try std.testing.expect(!decls[3].data.const_decl.value.data.function_type_expr.is_c_variadic);
}

test "parser: a function type's tail requires abi(.c)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    for ([_][:0]const u8{
        "F :: (n: i32, ..) -> i64;",
        "F :: (n: i32, ..) -> i64 abi(.naked);",
        "F :: (n: i32, .., x: i32) -> i64 abi(.c);", // not the last entry
        "F :: (.., ..) -> i64 abi(.c);", // two tails
    }) |src| {
        var p = try Parser.init(alloc, src);
        try std.testing.expectError(error.ParseError, p.parse());
    }
}

// Without a `->` the parens are a grouping, the void type, or a result list —
// a `..` there is the pack spread and keeps its own path.
test "parser: the tail arm leaves grouping, void and pack spreads alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(),
        \\Grouped :: (n: (i64)) -> i64;
        \\Voided :: (n: ()) -> i64;
        \\Spread :: (..Ts) -> i64;
    );
    const root = try parser.parse();
    const decls = root.data.root.decls;

    const grouped = decls[0].data.const_decl.value.data.function_type_expr;
    try std.testing.expect(!grouped.is_c_variadic);
    try std.testing.expectEqualStrings("i64", grouped.param_types[0].data.type_expr.name);

    const voided = decls[1].data.const_decl.value.data.function_type_expr;
    try std.testing.expect(!voided.is_c_variadic);
    try std.testing.expectEqualStrings("void", voided.param_types[0].data.type_expr.name);

    const spread = decls[2].data.const_decl.value.data.function_type_expr;
    try std.testing.expect(!spread.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 1), spread.param_types.len);
    try std.testing.expect(spread.param_types[0].data == .spread_expr);
}

test "parser: abi(...) alone is a convention, not a body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(),
        \\Alias :: (n: i32) -> i64 abi(.c);
        \\defined :: (n: i32) -> i64 abi(.c) { 0 }
        \\imported :: (n: i32) -> i64 abi(.c) extern;
    );
    const root = try parser.parse();
    const decls = root.data.root.decls;
    try std.testing.expect(decls[0].data.const_decl.value.data == .function_type_expr);
    try std.testing.expect(decls[1].data == .fn_decl);
    try std.testing.expect(decls[2].data == .fn_decl);
}

// Reads each name back from its recorded start:
// `source[start .. start + name.len] == name`. Raw names hold — a token's start
// excludes the backtick — but a renamed `_` field does not, so those are
// asserted at their own site.
fn expectNameStarts(src: [:0]const u8, names: []const []const u8, starts: []const u32) !void {
    try std.testing.expectEqual(names.len, starts.len);
    for (names, starts) |name, start| {
        if (start == ast.no_source_start) continue;
        try std.testing.expectEqualStrings(name, src[start .. start + name.len]);
    }
}

test "struct field name starts point at each field's spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\Rec :: struct {
        \\    plain: i32;
        \\    `i2: i64;
        \\}
    ;
    var parser = try Parser.init(arena.allocator(), src);
    const root = try parser.parse();
    const sd = root.data.root.decls[0].data.struct_decl;
    try std.testing.expectEqual(@as(usize, 2), sd.field_names.len);
    try expectNameStarts(src, sd.field_names, sd.field_name_starts);
}

test "a grouped field records every name in source order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 = "Point :: struct { x, y, z: f32; }";
    var parser = try Parser.init(arena.allocator(), src);
    const root = try parser.parse();
    const sd = root.data.root.decls[0].data.struct_decl;
    try expectNameStarts(src, sd.field_names, sd.field_name_starts);
    try std.testing.expectEqual(@as(usize, 3), sd.field_name_starts.len);
    try std.testing.expect(sd.field_name_starts[0] < sd.field_name_starts[1]);
    try std.testing.expect(sd.field_name_starts[1] < sd.field_name_starts[2]);
}

test "a '_' field's start is the '_' token under its renamed name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 = "Holes :: struct { _, x: i32; }";
    var parser = try Parser.init(arena.allocator(), src);
    const root = try parser.parse();
    const sd = root.data.root.decls[0].data.struct_decl;
    try std.testing.expectEqual(@as(usize, 2), sd.field_name_starts.len);
    try std.testing.expectEqualStrings("_0", sd.field_names[0]);
    try std.testing.expectEqualStrings("_", src[sd.field_name_starts[0] .. sd.field_name_starts[0] + 1]);
    try std.testing.expectEqualStrings("x", src[sd.field_name_starts[1] .. sd.field_name_starts[1] + 1]);
}

test "enum variant name starts point at each variant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\Kind :: enum {
        \\    none;
        \\    tagged: i32;
        \\    fixed :: 7;
        \\}
    ;
    var parser = try Parser.init(arena.allocator(), src);
    const root = try parser.parse();
    const ed = root.data.root.decls[0].data.enum_decl;
    try std.testing.expectEqual(@as(usize, 3), ed.variant_names.len);
    try expectNameStarts(src, ed.variant_names, ed.variant_name_starts);
}

test "error tag name starts point at each tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 = "ParseErr :: error { BadDigit, Overflow };";
    var parser = try Parser.init(arena.allocator(), src);
    const root = try parser.parse();
    const esd = root.data.root.decls[0].data.error_set_decl;
    try std.testing.expectEqual(@as(usize, 2), esd.tag_names.len);
    try expectNameStarts(src, esd.tag_names, esd.tag_name_starts);
}

test "an anonymous union field has no source start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\Payload :: union {
        \\    struct { x, y: f32; };
        \\    b: i64;
        \\}
    ;
    var parser = try Parser.init(arena.allocator(), src);
    const root = try parser.parse();
    const ud = root.data.root.decls[0].data.union_decl;
    try std.testing.expectEqualStrings("__anon_0", ud.field_names[0]);
    try std.testing.expectEqual(ast.no_source_start, ud.field_name_starts[0]);
    try expectNameStarts(src, ud.field_names, ud.field_name_starts);
}

test "empty member lists have empty name-start arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(),
        \\S :: struct {}
        \\E :: enum {}
        \\U :: union {}
        \\Er :: error {}
    );
    const decls = (try parser.parse()).data.root.decls;
    try std.testing.expectEqual(@as(usize, 0), decls[0].data.struct_decl.field_name_starts.len);
    try std.testing.expectEqual(@as(usize, 0), decls[1].data.enum_decl.variant_name_starts.len);
    try std.testing.expectEqual(@as(usize, 0), decls[2].data.union_decl.field_name_starts.len);
    try std.testing.expectEqual(@as(usize, 0), decls[3].data.error_set_decl.tag_name_starts.len);
}

test "a struct-body typed constant adds no field name start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\Limits :: struct {
        \\    MAX: i32: 10;
        \\    x: i32;
        \\}
    ;
    var parser = try Parser.init(arena.allocator(), src);
    const root = try parser.parse();
    const sd = root.data.root.decls[0].data.struct_decl;
    try std.testing.expectEqual(@as(usize, 1), sd.field_names.len);
    try expectNameStarts(src, sd.field_names, sd.field_name_starts);
}

test "'#using' leaves the declaration's name starts in step with its names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\Base :: struct { a: i32; }
        \\Derived :: struct {
        \\    #using Base;
        \\    b: i64;
        \\}
    ;
    var parser = try Parser.init(arena.allocator(), src);
    const root = try parser.parse();
    const sd = root.data.root.decls[1].data.struct_decl;
    try std.testing.expectEqual(@as(usize, 1), sd.using_entries.len);
    try expectNameStarts(src, sd.field_names, sd.field_name_starts);
}

test "parser: a for-capture type may contain a brace group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = try parseBody(alloc,
        \\f :: () {
        \\    for x: struct { a: i64 } in items { }
        \\    for p: Pair(struct { a: i64 }, i64) in ps { }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 2), body.data.block.stmts.len);
    const first = body.data.block.stmts[0].data.for_expr;
    try std.testing.expectEqual(@as(usize, 1), first.captures.len);
    try std.testing.expect(first.captures[0].type_annotation != null);
    try std.testing.expect(first.captures[0].type_annotation.?.data == .struct_decl);
    const second = body.data.block.stmts[1].data.for_expr;
    try std.testing.expectEqual(@as(usize, 1), second.captures.len);
    try std.testing.expect(second.captures[0].type_annotation != null);
    try std.testing.expect(second.captures[0].type_annotation.?.data == .parameterized_type_expr);
}
