const std = @import("std");
const pi = @import("program_index.zig");
const ProgramIndex = pi.ProgramIndex;
const ast = @import("../ast.zig");
const Node = ast.Node;
const types = @import("types.zig");
const inst = @import("inst.zig");

test "ProgramIndex.init starts empty with unset borrowed views" {
    var idx = ProgramIndex.init(std.testing.allocator);
    defer idx.deinit();
    try std.testing.expectEqual(@as(u32, 0), idx.import_flags.count());
    try std.testing.expect(idx.module_scopes == null);
    try std.testing.expect(idx.import_graph == null);
}

test "ProgramIndex.import_flags round-trips imported vs local" {
    var idx = ProgramIndex.init(std.testing.allocator);
    defer idx.deinit();
    try idx.import_flags.put("printf", true);
    try idx.import_flags.put("main", false);
    try std.testing.expectEqual(@as(?bool, true), idx.import_flags.get("printf"));
    try std.testing.expectEqual(@as(?bool, false), idx.import_flags.get("main"));
    try std.testing.expect(idx.import_flags.get("absent") == null);
}

test "ProgramIndex borrows module_scopes / import_graph without owning them" {
    const ScopeMap = std.StringHashMap(std.StringHashMap(@import("../ast.zig").Visibility));
    const ScopeSet = std.StringHashMap(std.StringHashMap(void));
    var scopes = ScopeMap.init(std.testing.allocator);
    defer scopes.deinit();
    var graph = ScopeSet.init(std.testing.allocator);
    defer graph.deinit();

    var idx = ProgramIndex.init(std.testing.allocator);
    defer idx.deinit();
    idx.module_scopes = &scopes;
    idx.import_graph = &graph;

    // Reads go through the borrowed pointer; the backing stays caller-owned,
    // so idx.deinit() must not free it (testing.allocator would flag a
    // double-free / leak otherwise).
    try std.testing.expect(idx.module_scopes.? == &scopes);
    try std.testing.expect(idx.import_graph.? == &graph);
    try std.testing.expectEqual(@as(u32, 0), idx.module_scopes.?.count());
}

test "ProgramIndex declaration maps round-trip (A1.1b)" {
    var idx = ProgramIndex.init(std.testing.allocator);
    defer idx.deinit();

    // Minimal AST node reused wherever a *Node is required.
    var blk = ast.Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = &.{} } } };

    // fn_ast_map: function name → AST decl.
    const fd = ast.FnDecl{ .name = "main", .params = &.{}, .return_type = null, .body = &blk };
    try idx.fn_ast_map.put("main", &fd);
    try std.testing.expect(idx.fn_ast_map.get("main").? == &fd);

    // type_alias_map: alias name → target TypeId.
    try idx.type_alias_map.put("ShaderHandle", .i64);
    try std.testing.expectEqual(@as(?types.TypeId, .i64), idx.type_alias_map.get("ShaderHandle"));

    // global_names: #run global name → GlobalInfo.
    try idx.global_names.put("g", .{ .id = inst.GlobalId.fromIndex(0), .ty = .i64 });
    try std.testing.expect(idx.global_names.get("g").?.id == inst.GlobalId.fromIndex(0));

    // module_const_map: const name → ModuleConstInfo.
    try idx.module_const_map.put("AF_INET", .{ .value = &blk, .ty = .i32 });
    try std.testing.expect(idx.module_const_map.get("AF_INET").?.value == &blk);

    // runtime_class_map: sx alias → RuntimeClassDecl.
    const fcd = ast.RuntimeClassDecl{
        .name = "NSString",
        .runtime_path = "NSString",
        .runtime = .objc_class,
        .members = &.{},
        .is_extern = true,
        .is_main = false,
    };
    try idx.runtime_class_map.put("NSString", &fcd);
    try std.testing.expect(idx.runtime_class_map.get("NSString").? == &fcd);

    // protocol_decl_map: protocol name → ProtocolDeclInfo.
    try idx.protocol_decl_map.put("Show", .{ .name = "Show", .is_inline = false, .methods = &.{} });
    try std.testing.expectEqualStrings("Show", idx.protocol_decl_map.get("Show").?.name);

    // protocol_ast_map: protocol name → AST decl.
    const pd = ast.ProtocolDecl{ .name = "Show", .methods = &.{} };
    try idx.protocol_ast_map.put("Show", &pd);
    try std.testing.expect(idx.protocol_ast_map.get("Show").? == &pd);

    // struct_template_map: generic struct name → template.
    const list_sd = ast.StructDecl{ .name = "List", .field_names = &.{}, .field_types = &.{}, .field_defaults = &.{} };
    try idx.struct_template_map.put("List", .{ .name = "List", .type_params = &.{}, .field_names = &.{}, .field_type_nodes = &.{}, .decl = &list_sd });
    try std.testing.expectEqualStrings("List", idx.struct_template_map.get("List").?.name);

    // ufcs_alias_map: alias name → target function name.
    try idx.ufcs_alias_map.put("len", "list_len");
    try std.testing.expectEqualStrings("list_len", idx.ufcs_alias_map.get("len").?);
}

// E0 (R5 §#4): the source-keyed caches partition by declaring source, so the
// SAME name authored in two different modules lands two DISTINCT entries under
// two source keys — never last-wins. The legacy global maps stay single-keyed
// by name (one entry per name), so the compat readers are untouched.
test "ProgramIndex source-keyed caches partition same-name authors by source" {
    var idx = ProgramIndex.init(std.testing.allocator);
    defer idx.deinit();

    var blk_a = ast.Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = &.{} } } };
    var blk_b = ast.Node{ .span = .{ .start = 1, .end = 1 }, .data = .{ .block = .{ .stmts = &.{} } } };

    // SAME alias name `Foo` authored in two modules → two distinct TypeIds.
    idx.putTypeAliasBySource("a.sx", "Foo", .i64);
    idx.putTypeAliasBySource("b.sx", "Foo", .f64);
    try std.testing.expectEqual(@as(?types.TypeId, .i64), idx.type_aliases_by_source.get("a.sx").?.get("Foo"));
    try std.testing.expectEqual(@as(?types.TypeId, .f64), idx.type_aliases_by_source.get("b.sx").?.get("Foo"));
    try std.testing.expectEqual(@as(u32, 2), idx.type_aliases_by_source.count());

    // SAME const name `K` authored in two modules → two distinct ModuleConstInfos.
    idx.putModuleConstBySource("a.sx", "K", .{ .value = &blk_a, .ty = .i32 });
    idx.putModuleConstBySource("b.sx", "K", .{ .value = &blk_b, .ty = .f32 });
    try std.testing.expect(idx.module_consts_by_source.get("a.sx").?.get("K").?.value == &blk_a);
    try std.testing.expect(idx.module_consts_by_source.get("b.sx").?.get("K").?.value == &blk_b);
    try std.testing.expectEqual(@as(?types.TypeId, .i32), idx.module_consts_by_source.get("a.sx").?.get("K").?.ty);
    try std.testing.expectEqual(@as(?types.TypeId, .f32), idx.module_consts_by_source.get("b.sx").?.get("K").?.ty);

    // SAME global name `g` authored in two modules → two distinct GlobalInfos.
    idx.putGlobalBySource("a.sx", "g", .{ .id = inst.GlobalId.fromIndex(0), .ty = .i64 });
    idx.putGlobalBySource("b.sx", "g", .{ .id = inst.GlobalId.fromIndex(1), .ty = .f64 });
    try std.testing.expect(idx.globals_by_source.get("a.sx").?.get("g").?.id == inst.GlobalId.fromIndex(0));
    try std.testing.expect(idx.globals_by_source.get("b.sx").?.get("g").?.id == inst.GlobalId.fromIndex(1));

    // Compat readers: the legacy global maps stay keyed by NAME alone, so a
    // same-name author is last-wins there — exactly ONE entry for `Foo` / `K`,
    // unchanged by the source-keyed writes above.
    idx.type_alias_map.put("Foo", .i64) catch unreachable;
    idx.type_alias_map.put("Foo", .f64) catch unreachable;
    try std.testing.expectEqual(@as(u32, 1), idx.type_alias_map.count());
    idx.module_const_map.put("K", .{ .value = &blk_a, .ty = .i32 }) catch unreachable;
    idx.module_const_map.put("K", .{ .value = &blk_b, .ty = .f32 }) catch unreachable;
    try std.testing.expectEqual(@as(u32, 1), idx.module_const_map.count());

    // removeModuleConstBySource drops only the named entry under its source.
    idx.removeModuleConstBySource("a.sx", "K");
    try std.testing.expect(idx.module_consts_by_source.get("a.sx").?.get("K") == null);
    try std.testing.expect(idx.module_consts_by_source.get("b.sx").?.get("K").?.value == &blk_b);
}

/// Stand-in for the leaf-name lookup both array-dimension resolvers pass to the
/// shared `evalConstIntExpr`: `M`/`N` resolve to integers, everything else is
/// genuinely non-comptime.
const DimCtx = struct {
    pub fn lookupDimName(_: DimCtx, name: []const u8) ?i64 {
        if (std.mem.eql(u8, name, "M")) return 4;
        if (std.mem.eql(u8, name, "N")) return 6;
        // `K : f64 : 4.0` is an INTEGRAL float const: it folds to 4 through the
        // int delegation (`floatToIntExact`) yet stays float-typed — the case the
        // division guard must still recognise as float division.
        if (std.mem.eql(u8, name, "K")) return 4;
        return null;
    }
    // `xs` stands in for a pack of arity 3; every other name has no pack length.
    pub fn lookupConstAggLen(_: DimCtx, _: []const u8) ?i64 {
        return null;
    }
    pub fn lookupConstArrayElem(_: DimCtx, _: []const u8, _: i64, _: ?ast.Span) ?i64 {
        return null;
    }
    pub fn lookupConstStructField(_: DimCtx, _: []const u8, _: []const u8) ?i64 {
        return null;
    }
    pub fn evalConstCallInt(_: DimCtx, _: *const ast.Node) ?i64 {
        return null;
    }
    pub fn lookupPackLen(_: DimCtx, name: []const u8) ?i64 {
        if (std.mem.eql(u8, name, "xs")) return 3;
        return null;
    }
    // `F` stands in for a NON-INTEGRAL float module const (`F : f64 : 2.5`): the
    // int folder cannot resolve it, so only the float-leaf lookup surfaces it.
    // `K` stands in for an INTEGRAL float const (`K : f64 : 4.0`) — it folds to 4
    // through the int delegation yet is still float-typed. Integer consts (`M`/`N`)
    // are resolved by the int delegation and never reach this arm; `Z` is runtime.
    pub fn lookupFloatName(_: DimCtx, name: []const u8) ?f64 {
        if (std.mem.eql(u8, name, "F")) return 2.5;
        if (std.mem.eql(u8, name, "K")) return 4.0;
        return null;
    }
    // The float-typed-const predicate the division guard consults: `F`/`K` are
    // float-typed module consts, every other name is not.
    pub fn nameIsFloatTyped(_: DimCtx, name: []const u8) bool {
        return std.mem.eql(u8, name, "F") or std.mem.eql(u8, name, "K");
    }
    // This test ctx models no namespace imports — qualified-member consts
    // (`m.CAP`, issue 0192) are exercised end-to-end by the corpus, not here.
    pub fn lookupQualifiedConst(_: DimCtx, _: []const u8, _: []const u8) ?i64 {
        return null;
    }
    pub fn lookupQualifiedConstFloat(_: DimCtx, _: []const u8, _: []const u8) ?f64 {
        return null;
    }
    pub fn qualifiedNameIsFloatTyped(_: DimCtx, _: []const u8, _: []const u8) bool {
        return false;
    }
    pub fn lookupQualifiedConstNode(_: DimCtx, _: *const Node) ?i64 {
        return null;
    }
    pub fn lookupQualifiedConstNodeFloat(_: DimCtx, _: *const Node) ?f64 {
        return null;
    }
    pub fn qualifiedNodeIsFloatTyped(_: DimCtx, _: *const Node) bool {
        return false;
    }
};

fn nLit(v: i64) ast.Node {
    return .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = v } } };
}
fn nFloat(v: f64) ast.Node {
    return .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .float_literal = .{ .value = v } } };
}
fn nIdent(name: []const u8) ast.Node {
    return .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = name } } };
}
/// A backtick RAW identifier (`` `f64 ``): same spelling as a builtin type, but
/// bound as a value — so a field access on it is an ordinary field read, never a
/// numeric-limit fold (F0.11-7).
fn nIdentRaw(name: []const u8) ast.Node {
    return .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = name, .is_raw = true } } };
}
fn nBin(op: ast.BinaryOp.Op, l: *ast.Node, r: *ast.Node) ast.Node {
    return .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .binary_op = .{ .op = op, .lhs = l, .rhs = r } } };
}
fn nNeg(operand: *ast.Node) ast.Node {
    return .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .unary_op = .{ .op = .negate, .operand = operand } } };
}
fn nField(obj: *ast.Node, field: []const u8) ast.Node {
    return .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .field_access = .{ .object = obj, .field = field } } };
}

test "evalConstIntExpr folds constant-expression array dimensions, halts on non-const" {
    const eval = pi.evalConstIntExpr;
    const ctx = DimCtx{};

    var l5 = nLit(5);
    var one = nLit(1);
    var two = nLit(2);
    var zero = nLit(0);
    var m = nIdent("M");
    var n = nIdent("N");
    var z = nIdent("Z"); // unbound — genuinely non-comptime

    // Leaves: literal, named const, unbound name.
    try std.testing.expectEqual(@as(?i64, 5), eval(&l5, ctx));
    try std.testing.expectEqual(@as(?i64, 4), eval(&m, ctx));
    try std.testing.expect(eval(&z, ctx) == null);

    // `M + 1`, `M * N`, `N - M`.
    var add = nBin(.add, &m, &one);
    var mul = nBin(.mul, &m, &n);
    var sub = nBin(.sub, &n, &m);
    try std.testing.expectEqual(@as(?i64, 5), eval(&add, ctx));
    try std.testing.expectEqual(@as(?i64, 24), eval(&mul, ctx));
    try std.testing.expectEqual(@as(?i64, 2), eval(&sub, ctx));

    // Nested `(M + N) - 1` and parenthesised `(M + 1) * 2` (parens carry no node).
    var addmn = nBin(.add, &m, &n);
    var nested = nBin(.sub, &addmn, &one);
    var paren = nBin(.mul, &add, &two);
    try std.testing.expectEqual(@as(?i64, 9), eval(&nested, ctx));
    try std.testing.expectEqual(@as(?i64, 10), eval(&paren, ctx));

    // Unary negate.
    var neg = nNeg(&m);
    try std.testing.expectEqual(@as(?i64, -4), eval(&neg, ctx));

    // `<pack>.len` leaf resolves via `ctx.lookupPackLen` and folds in an
    // expression (`xs.len` → 3, `xs.len - 1` → 2). A `.len` on a non-pack name
    // and a non-`len` field are not compile-time integer leaves → null.
    var xs = nIdent("xs");
    var xslen = nField(&xs, "len");
    var xslen_m1 = nBin(.sub, &xslen, &one);
    try std.testing.expectEqual(@as(?i64, 3), eval(&xslen, ctx));
    try std.testing.expectEqual(@as(?i64, 2), eval(&xslen_m1, ctx));
    var zlen = nField(&z, "len");
    var xscap = nField(&xs, "cap");
    try std.testing.expect(eval(&zlen, ctx) == null);
    try std.testing.expect(eval(&xscap, ctx) == null);

    // Genuinely non-const operand, division by zero, a non-arithmetic operator,
    // and overflow all yield null → the caller's clean compile-halt (no panic,
    // no fabricated length).
    var addz = nBin(.add, &m, &z);
    var divz = nBin(.div, &m, &zero);
    var cmp = nBin(.lt, &m, &n);
    var big = nLit(std.math.maxInt(i64));
    var ovf = nBin(.mul, &big, &two);
    try std.testing.expect(eval(&addz, ctx) == null);
    try std.testing.expect(eval(&divz, ctx) == null);
    try std.testing.expect(eval(&cmp, ctx) == null);
    try std.testing.expect(eval(&ovf, ctx) == null);
}

test "floatToIntExact accepts integral floats, rejects the rest" {
    const f = pi.floatToIntExact;
    // Integral floats (positive, zero, negative) fold to their exact integer.
    try std.testing.expectEqual(@as(?i64, 4), f(4.0));
    try std.testing.expectEqual(@as(?i64, 0), f(0.0));
    try std.testing.expectEqual(@as(?i64, -2), f(-2.0));
    // Non-integral / non-finite → null (the caller's clean halt).
    try std.testing.expect(f(4.5) == null);
    try std.testing.expect(f(0.1) == null);
    try std.testing.expect(f(std.math.inf(f64)) == null);
    try std.testing.expect(f(-std.math.inf(f64)) == null);
    try std.testing.expect(f(std.math.nan(f64)) == null);
    // Out-of-i64-range integral floats → null (no @intFromFloat range panic).
    // `-2^63` is exactly the i64 minimum and IS representable.
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), f(-9223372036854775808.0));
    try std.testing.expect(f(9223372036854775808.0) == null); // 2^63, just past maxInt(i64)
    try std.testing.expect(f(1.0e30) == null);
}

test "moduleConstInt folds expression-RHS consts and rejects cycles" {
    var table = types.TypeTable.init(std.testing.allocator);
    defer table.deinit();
    var map = std.StringHashMap(pi.ModuleConstInfo).init(std.testing.allocator);
    defer map.deinit();

    // M :: 2 (literal), N :: M + 1 (expression), P :: N * 2 (expression over an
    // expression const), F :: 4.0 (integral float), G :: 4.5 (fractional).
    var m_val = nLit(2);
    var m_id = nIdent("M");
    var one = nLit(1);
    var n_val = nBin(.add, &m_id, &one);
    var n_id = nIdent("N");
    var two = nLit(2);
    var p_val = nBin(.mul, &n_id, &two);
    var f_val = nFloat(4.0);
    var g_val = nFloat(4.5);

    try map.put("M", .{ .value = &m_val, .ty = .i64 });
    try map.put("N", .{ .value = &n_val, .ty = .i64 });
    try map.put("P", .{ .value = &p_val, .ty = .i64 });
    try map.put("F", .{ .value = &f_val, .ty = .f64 });
    try map.put("G", .{ .value = &g_val, .ty = .f64 });

    try std.testing.expectEqual(@as(?i64, 2), pi.moduleConstInt(&map, &table, "M"));
    try std.testing.expectEqual(@as(?i64, 3), pi.moduleConstInt(&map, &table, "N"));
    try std.testing.expectEqual(@as(?i64, 6), pi.moduleConstInt(&map, &table, "P"));
    try std.testing.expectEqual(@as(?i64, 4), pi.moduleConstInt(&map, &table, "F"));
    try std.testing.expect(pi.moduleConstInt(&map, &table, "G") == null);
    try std.testing.expect(pi.moduleConstInt(&map, &table, "absent") == null);

    // A cyclic const has no compile-time integer value, and folding it must not
    // recurse forever: mutual `A :: B + 0; B :: A + 0` and self `C :: C + 0` all
    // fold to null via the frame-based cycle guard.
    var a_id = nIdent("A");
    var b_id = nIdent("B");
    var c_id = nIdent("C");
    var zero = nLit(0);
    var a_val = nBin(.add, &b_id, &zero);
    var b_val = nBin(.add, &a_id, &zero);
    var c_val = nBin(.add, &c_id, &zero);
    try map.put("A", .{ .value = &a_val, .ty = .i64 });
    try map.put("B", .{ .value = &b_val, .ty = .i64 });
    try map.put("C", .{ .value = &c_val, .ty = .i64 });
    try std.testing.expect(pi.moduleConstInt(&map, &table, "A") == null);
    try std.testing.expect(pi.moduleConstInt(&map, &table, "B") == null);
    try std.testing.expect(pi.moduleConstInt(&map, &table, "C") == null);
}

test "moduleConstIsFloatTyped judges a const by VALUE, catching untyped float-EXPR consts" {
    var table = types.TypeTable.init(std.testing.allocator);
    defer table.deinit();
    var map = std.StringHashMap(pi.ModuleConstInfo).init(std.testing.allocator);
    defer map.deinit();

    // KT : f64 : 4.0 (typed float), MI :: 2 (untyped int), ML :: 5.0 (untyped
    // float literal → f64), ME :: 4.0 + 1.0 (untyped float EXPRESSION, placeholder
    // type i64 yet float-valued), IE :: 1 + 2 (untyped int expression).
    var kt_val = nFloat(4.0);
    var mi_val = nLit(2);
    var ml_val = nFloat(5.0);
    var four = nFloat(4.0);
    var one_f = nFloat(1.0);
    var me_val = nBin(.add, &four, &one_f);
    var l1 = nLit(1);
    var l2 = nLit(2);
    var ie_val = nBin(.add, &l1, &l2);
    try map.put("KT", .{ .value = &kt_val, .ty = .f64 });
    try map.put("MI", .{ .value = &mi_val, .ty = .i64 });
    try map.put("ML", .{ .value = &ml_val, .ty = .f64 }); // pass-0 stores a float literal as f64
    try map.put("ME", .{ .value = &me_val, .ty = .i64 }); // pass-0 placeholder for a binary_op
    try map.put("IE", .{ .value = &ie_val, .ty = .i64 });

    // Float-valued: a typed float const, an untyped float literal, AND an untyped
    // float EXPRESSION whose declared type is the i64 placeholder (judged by value).
    try std.testing.expect(pi.moduleConstIsFloatTyped(&map, &table, "KT"));
    try std.testing.expect(pi.moduleConstIsFloatTyped(&map, &table, "ML"));
    try std.testing.expect(pi.moduleConstIsFloatTyped(&map, &table, "ME"));
    // NOT float-valued: an int const, an int expression, an absent name.
    try std.testing.expect(!pi.moduleConstIsFloatTyped(&map, &table, "MI"));
    try std.testing.expect(!pi.moduleConstIsFloatTyped(&map, &table, "IE"));
    try std.testing.expect(!pi.moduleConstIsFloatTyped(&map, &table, "absent"));

    // A cyclic const has no value: the frame guard returns false without looping.
    var a_id = nIdent("A");
    var b_id = nIdent("B");
    var az = nFloat(0.0);
    var a_val = nBin(.add, &b_id, &az);
    var b_val = nBin(.add, &a_id, &az);
    try map.put("A", .{ .value = &a_val, .ty = .i64 });
    try map.put("B", .{ .value = &b_val, .ty = .i64 });
    // The `+ 0.0` literal still makes them float-valued (a finite, non-cyclic leaf
    // is reached before the cycle); the point is it TERMINATES.
    try std.testing.expect(pi.moduleConstIsFloatTyped(&map, &table, "A"));
}

test "moduleConstInt gates the fold on the declared type, not the initializer node" {
    var table = types.TypeTable.init(std.testing.allocator);
    defer table.deinit();
    var map = std.StringHashMap(pi.ModuleConstInfo).init(std.testing.allocator);
    defer map.deinit();

    // An `int_literal` value node folds to an integer ONLY when the declared
    // type is numeric. A `string`/`bool`-typed const carrying an integer-looking
    // initializer must never be folded into a count: the count path
    // consults `ModuleConstInfo.ty`, not just the node shape.
    var int_val = nLit(4);
    try map.put("OK", .{ .value = &int_val, .ty = .i64 });
    try map.put("STR", .{ .value = &int_val, .ty = .string });
    try map.put("BOOLEAN", .{ .value = &int_val, .ty = .bool });

    try std.testing.expectEqual(@as(?i64, 4), pi.moduleConstInt(&map, &table, "OK"));
    try std.testing.expect(pi.moduleConstInt(&map, &table, "STR") == null);
    try std.testing.expect(pi.moduleConstInt(&map, &table, "BOOLEAN") == null);

    // The same gate holds for a const-EXPRESSION value node (`M + 2`), not just
    // a bare literal: a `string`-typed const whose initializer is a foldable
    // integer expression must still never fold as a count (the
    // const-expression leak). `KEXPR : i64 : M + 2` (numeric type) folds; the
    // same expression declared `string` does not.
    var m_lit = nLit(2);
    var add2 = nLit(2);
    var expr_val = nBin(.add, &m_lit, &add2);
    try map.put("KEXPR", .{ .value = &expr_val, .ty = .i64 });
    try map.put("STREXPR", .{ .value = &expr_val, .ty = .string });
    try std.testing.expectEqual(@as(?i64, 4), pi.moduleConstInt(&map, &table, "KEXPR"));
    try std.testing.expect(pi.moduleConstInt(&map, &table, "STREXPR") == null);
}

test "evalConstIntExpr folds an integral float literal, halts on a fractional one" {
    const eval = pi.evalConstIntExpr;
    const ctx = DimCtx{};

    var f4 = nFloat(4.0);
    var f45 = nFloat(4.5);
    var one = nLit(1);

    // A direct integral float dimension (`[4.0]T`) folds; `4.5` does not.
    try std.testing.expectEqual(@as(?i64, 4), eval(&f4, ctx));
    try std.testing.expect(eval(&f45, ctx) == null);

    // It composes inside an expression dimension (`4.0 + 1` → 5); a fractional
    // operand poisons the whole fold to null.
    var add = nBin(.add, &f4, &one);
    var addbad = nBin(.add, &f45, &one);
    try std.testing.expectEqual(@as(?i64, 5), eval(&add, ctx));
    try std.testing.expect(eval(&addbad, ctx) == null);
}

test "evalConstFloatExpr folds comptime float expressions, halts on runtime leaves" {
    const eval = pi.evalConstFloatExpr;
    const ctx = DimCtx{}; // M = 4, N = 6

    var half = nFloat(0.5);
    var two_f = nFloat(2.0);
    var m = nIdent("M");
    var z = nIdent("Z"); // unbound — genuinely runtime

    // Leaves: a float literal is itself; an int leaf delegates to the int folder
    // and promotes (`M` → 4.0); an unbound name is not a compile-time float.
    try std.testing.expectEqual(@as(?f64, 0.5), eval(&half, ctx));
    try std.testing.expectEqual(@as(?f64, 4.0), eval(&m, ctx));
    try std.testing.expect(eval(&z, ctx) == null);

    // Mixed int+float arithmetic promotes to f64, order-independent
    // (`M + 0.5` and `0.5 + M` → 4.5). `M + 2.0` is integral (6.0) but still a
    // float value here — `floatToIntExact` is what the narrowing rule applies.
    var mp = nBin(.add, &m, &half);
    var pm = nBin(.add, &half, &m);
    var mi = nBin(.add, &m, &two_f);
    try std.testing.expectEqual(@as(?f64, 4.5), eval(&mp, ctx));
    try std.testing.expectEqual(@as(?f64, 4.5), eval(&pm, ctx));
    try std.testing.expectEqual(@as(?f64, 6.0), eval(&mi, ctx));

    // Unary negate of a float expression.
    var neg = nNeg(&mp);
    try std.testing.expectEqual(@as(?f64, -4.5), eval(&neg, ctx));

    // A NON-INTEGRAL float-const leaf (`F : f64 : 2.5`) resolves through the
    // float-leaf lookup — the int folder cannot fold it (2.5 is not integral), so
    // an expression like `F + 0.25` (= 2.75) is now recognised as a compile-time
    // float and rejected by the narrowing rule instead of silently truncating;
    // `F + 1.5` (= 4.0) is integral and folds. This completes the evaluator for
    // float-const-leaf expressions.
    var f = nIdent("F");
    var quarter = nFloat(0.25);
    var three_half = nFloat(1.5);
    var fq = nBin(.add, &f, &quarter);
    var fh = nBin(.add, &f, &three_half);
    try std.testing.expectEqual(@as(?f64, 2.5), eval(&f, ctx));
    try std.testing.expectEqual(@as(?f64, 2.75), eval(&fq, ctx));
    try std.testing.expectEqual(@as(?f64, 4.0), eval(&fh, ctx));

    // A builtin FLOAT numeric-limit accessor is a compile-time float leaf — the
    // twin of `evalConstIntExpr`'s `<IntType>.min`/`.max` arm, via the shared
    // `type_resolver.floatLimitFor`. It folds as a direct leaf AND inside an
    // expression: `f64.max - f64.max` = 0.0 (integral → folds), `f64.true_min +
    // 0.5` = 0.5 (non-integral → the narrowing rule rejects it). A non-limit
    // field on a float type is not a leaf → null.
    var f64ty = nIdent("f64");
    var f32ty = nIdent("f32");
    var fmax = nField(&f64ty, "max");
    var ftmin = nField(&f64ty, "true_min");
    var feps = nField(&f32ty, "epsilon");
    var fbogus = nField(&f64ty, "bogus");
    try std.testing.expectEqual(@as(?f64, std.math.floatMax(f64)), eval(&fmax, ctx));
    try std.testing.expectEqual(@as(?f64, std.math.floatTrueMin(f64)), eval(&ftmin, ctx));
    try std.testing.expectEqual(@as(?f64, @as(f64, std.math.floatEps(f32))), eval(&feps, ctx));
    try std.testing.expect(eval(&fbogus, ctx) == null);
    var lim_diff = nBin(.sub, &fmax, &fmax);
    var lim_nonint = nBin(.add, &ftmin, &half);
    try std.testing.expectEqual(@as(?f64, 0.0), eval(&lim_diff, ctx));
    try std.testing.expectEqual(@as(?f64, 0.5), eval(&lim_nonint, ctx));

    // `%` mirrors the int folder's `.mod` (and codegen's `frem`): `@rem`. A
    // non-integral-operand remainder (`5.5 % 2.0` = 1.5) reaches this arm (the
    // integral-operand case `6.0 % 4.0` folds via the int delegation); a zero
    // divisor → null.
    var fivehalf = nFloat(5.5);
    var zero_f0 = nFloat(0.0);
    var fmod = nBin(.mod, &fivehalf, &two_f);
    var fmodz = nBin(.mod, &fivehalf, &zero_f0);
    try std.testing.expectEqual(@as(?f64, 1.5), eval(&fmod, ctx));
    try std.testing.expect(eval(&fmodz, ctx) == null);

    // A runtime operand poisons the whole fold; a non-arithmetic operator and a
    // float division by zero are not compile-time float leaves → null.
    var zp = nBin(.add, &z, &half);
    var cmp = nBin(.lt, &m, &half);
    var zero_f = nFloat(0.0);
    var divz = nBin(.div, &half, &zero_f);
    try std.testing.expect(eval(&zp, ctx) == null);
    try std.testing.expect(eval(&cmp, ctx) == null);
    try std.testing.expect(eval(&divz, ctx) == null);
}

test "a backtick raw-shadow receiver is a field read, not a numeric-limit fold (F0.11-7)" {
    const evalf = pi.evalConstFloatExpr;
    const evali = pi.evalConstIntExpr;
    const ctx = DimCtx{};

    // BARE type receiver (`is_raw = false`) → the numeric-limit accessor folds:
    // `f64.epsilon` is the builtin eps, `i8.max` is 127.
    var f64ty = nIdent("f64");
    var s8ty = nIdent("i8");
    var bare_feps = nField(&f64ty, "epsilon");
    var bare_smax = nField(&s8ty, "max");
    try std.testing.expectEqual(@as(?f64, @as(f64, std.math.floatEps(f64))), evalf(&bare_feps, ctx));
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i8)), evali(&bare_smax, ctx));

    // RAW receiver (`` `f64 ``/`` `i8 ``) shadows the builtin with a VALUE — the
    // field access is an ordinary runtime field READ, so it is NOT a compile-time
    // leaf in either evaluator (→ null), exactly as the sibling `isFloatValuedExpr`
    // already treats it. The whole point: a value-shadow can never be misread as
    // the builtin limit.
    var f64raw = nIdentRaw("f64");
    var s8raw = nIdentRaw("i8");
    var raw_feps = nField(&f64raw, "epsilon");
    var raw_smax = nField(&s8raw, "max");
    try std.testing.expect(evalf(&raw_feps, ctx) == null);
    try std.testing.expect(evali(&raw_smax, ctx) == null);
    // The float evaluator must also refuse it (it delegates the int path first):
    try std.testing.expect(evalf(&raw_smax, ctx) == null);

    // `isFloatValuedExpr` (the consistency anchor) agrees: bare float-limit is
    // float-valued, raw shadow is not.
    try std.testing.expect(pi.isFloatValuedExpr(&bare_feps, ctx));
    try std.testing.expect(!pi.isFloatValuedExpr(&raw_feps, ctx));
}

test "foldCountI64 / foldDimU32 fold an integral float count, reject a non-integral one" {
    const ctx = DimCtx{}; // M = 4, F = 2.5 (non-integral float const)

    var five = nLit(5);
    var f4 = nFloat(4.0);
    var f45 = nFloat(4.5);
    var f = nIdent("F");
    var quarter = nFloat(0.25);
    var three_half = nFloat(1.5);
    var fh = nBin(.add, &f, &three_half); // F + 1.5 = 4.0  (integral)
    var fq = nBin(.add, &f, &quarter); //    F + 0.25 = 2.75 (non-integral)
    var z = nIdent("Z"); // unbound — genuinely non-const

    // foldCountI64: integer / integral-float (literal OR float-const-leaf SUM)
    // fold to `.int`; a non-integral compile-time float surfaces as
    // `.non_integral`; a runtime leaf is `.not_const`.
    try std.testing.expectEqual(pi.CountFold{ .int = 5 }, pi.foldCountI64(&five, ctx));
    try std.testing.expectEqual(pi.CountFold{ .int = 4 }, pi.foldCountI64(&f4, ctx));
    try std.testing.expectEqual(pi.CountFold{ .int = 4 }, pi.foldCountI64(&fh, ctx));
    try std.testing.expectEqual(pi.CountFold{ .non_integral = 2.75 }, pi.foldCountI64(&fq, ctx));
    try std.testing.expectEqual(pi.CountFold.not_const, pi.foldCountI64(&z, ctx));

    // foldDimU32 (min 0) inherits the rule: an integral float-const-leaf dim
    // narrows to a `u32` count, a non-integral one reports `.non_integral_float`,
    // a runtime one `.not_const`.
    try std.testing.expectEqual(pi.DimU32{ .ok = 4 }, pi.foldDimU32(&fh, ctx, 0));
    try std.testing.expectEqual(pi.DimU32{ .non_integral_float = 2.75 }, pi.foldDimU32(&fq, ctx, 0));
    try std.testing.expectEqual(pi.DimU32{ .non_integral_float = 4.5 }, pi.foldDimU32(&f45, ctx, 0));
    try std.testing.expectEqual(pi.DimU32.not_const, pi.foldDimU32(&z, ctx, 0));

    // A NEGATIVE integral float folds to its integer first, then the u32 gate
    // rejects it as below-minimum — NOT as a non-integral float (it IS integral).
    var negf = nNeg(&f4); // -4.0 → -4
    try std.testing.expectEqual(pi.DimU32{ .below_min = -4 }, pi.foldDimU32(&negf, ctx, 0));
}

test "the int folder refuses a FLOAT division" {
    const eval = pi.evalConstIntExpr;
    const ctx = DimCtx{}; // K : f64 : 4.0 (integral float const), M = 4 (int const)

    var five = nLit(5);
    var two = nLit(2);
    var six = nLit(6);
    var f5 = nFloat(5.0);
    var f2 = nFloat(2.0);
    var f6 = nFloat(6.0);
    var k = nIdent("K"); // integral float const (folds to 4, yet float-typed)
    var m = nIdent("M"); // integer const (4)

    // Genuine INTEGER division still truncates (`5 / 2` → 2, `6 / 2` → 3).
    var idiv = nBin(.div, &five, &two);
    var idiv2 = nBin(.div, &six, &two);
    try std.testing.expectEqual(@as(?i64, 2), eval(&idiv, ctx));
    try std.testing.expectEqual(@as(?i64, 3), eval(&idiv2, ctx));

    // FLOAT division is REFUSED by the int folder (returns null), even when the
    // result is integral (`6.0 / 2.0`) — so it surfaces through the float folder
    // + the unified narrowing rule instead of truncating. A float operand on
    // either side (literal or float-typed const) is enough.
    var fdiv_nonint = nBin(.div, &f5, &f2); // 5.0 / 2.0 = 2.5
    var fdiv_int = nBin(.div, &f6, &f2); //    6.0 / 2.0 = 3.0 (integral, still refused)
    var fdiv_mixedl = nBin(.div, &f5, &two); // 5.0 / 2   = 2.5 (mixed promotes to float)
    var fdiv_mixedr = nBin(.div, &five, &f2); // 5 / 2.0   = 2.5
    var fdiv_const = nBin(.div, &k, &two); //   K / 2 = 4.0/2 = 2.0 (float const, refused)
    try std.testing.expect(eval(&fdiv_nonint, ctx) == null);
    try std.testing.expect(eval(&fdiv_int, ctx) == null);
    try std.testing.expect(eval(&fdiv_mixedl, ctx) == null);
    try std.testing.expect(eval(&fdiv_mixedr, ctx) == null);
    try std.testing.expect(eval(&fdiv_const, ctx) == null);

    // The float folder recovers the TRUE float value of the refused divisions, so
    // the unified rule can fold the integral one and reject the non-integral one.
    const evalf = pi.evalConstFloatExpr;
    try std.testing.expectEqual(@as(?f64, 2.5), evalf(&fdiv_nonint, ctx));
    try std.testing.expectEqual(@as(?f64, 3.0), evalf(&fdiv_int, ctx));
    try std.testing.expectEqual(@as(?f64, 2.0), evalf(&fdiv_const, ctx));
    // An int-const division (`M / 2` = 4/2) is NOT float division — it truncates.
    var mdiv = nBin(.div, &m, &two);
    try std.testing.expectEqual(@as(?i64, 2), eval(&mdiv, ctx));

    // Non-division float arithmetic is unaffected: `*`/`+`/`-` over integral
    // operands agree between int and float, so they still fold via the int folder
    // (`6.0 * 2.0` → 12, `K - 2.0` → 2).
    var fmul = nBin(.mul, &f6, &f2); // 6.0 * 2.0 = 12
    var ksub = nBin(.sub, &k, &f2); // K - 2.0  = 2
    try std.testing.expectEqual(@as(?i64, 12), eval(&fmul, ctx));
    try std.testing.expectEqual(@as(?i64, 2), eval(&ksub, ctx));
}
