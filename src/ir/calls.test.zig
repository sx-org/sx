// Tests for calls.zig.
//
// Two layers:
//   1. Result-type delegation reached via the public `Lowering.inferExprType`
//      (builtin / reflection classification, cast, dot-shorthand fallthrough) —
//      these need no lexical scope / fn registration.
//   2. The `CallPlan` object built by `CallResolver.plan` — its selected
//      kind / target / variant and the receiver / `__sx_ctx` / default-arg
//      properties, across every call form pinned by A3.2 sub-step 1
//      (direct / UFCS / protocol / closure / fn-pointer / extern / enum /
//      namespace). `resultType` is just `plan(c).return_type`, so these also
//      lock the typing the regression suite relies on.

const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;

const ir_mod = @import("ir.zig");
const TypeId = ir_mod.TypeId;
const FuncId = ir_mod.FuncId;
const Ref = ir_mod.Ref;
const Lowering = ir_mod.Lowering;
const CallResolver = ir_mod.CallResolver;
const CallPlan = ir_mod.CallPlan;

const lower = @import("lower.zig");
const Scope = lower.Scope;
const Binding = lower.Binding;
const BuiltinId = @import("inst.zig").BuiltinId;

fn node(data: ast.Node.Data) Node {
    return .{ .span = .{ .start = 0, .end = 0 }, .data = data };
}

// ── AST builders (heap-allocated so the call graph outlives one statement) ──

fn mk(alloc: std.mem.Allocator, data: ast.Node.Data) *Node {
    const n = alloc.create(Node) catch unreachable;
    n.* = .{ .span = .{ .start = 0, .end = 0 }, .data = data };
    return n;
}
fn ident(alloc: std.mem.Allocator, name: []const u8) *Node {
    return mk(alloc, .{ .identifier = .{ .name = name } });
}
fn typeExpr(alloc: std.mem.Allocator, name: []const u8) *Node {
    return mk(alloc, .{ .type_expr = .{ .name = name } });
}
fn intLit(alloc: std.mem.Allocator, v: i64) *Node {
    return mk(alloc, .{ .int_literal = .{ .value = v } });
}
fn emptyBody(alloc: std.mem.Allocator) *Node {
    return mk(alloc, .{ .block = .{ .stmts = &.{} } });
}
fn fieldAccess(alloc: std.mem.Allocator, obj: *Node, field: []const u8) *Node {
    return mk(alloc, .{ .field_access = .{ .object = obj, .field = field } });
}
fn callNode(alloc: std.mem.Allocator, callee: *Node, args: []const *Node) *Node {
    return mk(alloc, .{ .call = .{ .callee = callee, .args = args } });
}
fn postfixCast(alloc: std.mem.Allocator, operand: *Node, target: []const u8) *Node {
    return mk(alloc, .{ .postfix_cast = .{ .operand = operand, .type_expr = typeExpr(alloc, target) } });
}

// ── Layer 1: result-type delegation (no scope / registration needed) ────────

test "calls: builtin and reflection result types, unknown fallthrough" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);

    // One shared throwaway argument — the classified builtins below type by
    // callee name and don't inspect it.
    var arg = node(.{ .int_literal = .{ .value = 1 } });
    var args = [_]*Node{&arg};

    const cases = [_]struct { name: []const u8, want: TypeId }{
        .{ .name = "size_of", .want = .i64 },
        .{ .name = "align_of", .want = .i64 },
        // Reflection builtins (resolved by callee name, outside the
        // `resolveBuiltin` table) — each must keep its own result tag so a
        // pack-fn caller boxes the value with the right type.
        .{ .name = "type_name", .want = .string },
        .{ .name = "type_eq", .want = .bool },
        .{ .name = "has_impl", .want = .bool },
        .{ .name = "struct_field_count", .want = .i64 },
        .{ .name = "variant_index", .want = .i64 },
        .{ .name = "struct_field_name", .want = .string },
        .{ .name = "error_name", .want = .string },
        .{ .name = "is_comptime", .want = .bool },
        .{ .name = "is_flags", .want = .bool },
        .{ .name = "type_of", .want = .type_value },
        .{ .name = "struct_field_value", .want = .any },
        .{ .name = "__interp_print_frames", .want = .void },
        // A math builtin with a non-`f32` argument widens to `f64` (the int
        // literal arg is not `f32`, so the `f32` fast-path is not taken).
        .{ .name = "sqrt", .want = .f64 },
        // Unknown bare callee with no builtin / declared fn / scope binding
        // types as unresolved, not a fabricated guess.
        .{ .name = "definitely_not_a_fn", .want = .unresolved },
    };

    for (cases) |tc| {
        var callee = node(.{ .identifier = .{ .name = tc.name } });
        var call = node(.{ .call = .{ .callee = &callee, .args = &args } });
        try std.testing.expectEqual(tc.want, l.inferExprType(&call));
    }
}

test "calls: postfix cast result type is its resolved target" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);

    // `x.(i64)` types as the resolved target type — resolved via
    // `resolveTypeArg` (a primitive needs no scope / registration).
    var value = node(.{ .int_literal = .{ .value = 1 } });
    var target = node(.{ .type_expr = .{ .name = "i64" } });
    var pc = node(.{ .postfix_cast = .{ .operand = &value, .type_expr = &target } });
    try std.testing.expectEqual(TypeId.i64, l.inferExprType(&pc));
}

test "calls: dot-shorthand enum construction types as the target type" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);

    // `.Variant(args)` carries no callee name; its result type is whatever
    // target type is in scope. Absent one, it stays unresolved (not a guess).
    var enum_callee = node(.{ .enum_literal = .{ .name = "Variant" } });
    var arg = node(.{ .int_literal = .{ .value = 1 } });
    var args = [_]*Node{&arg};
    var enum_call = node(.{ .call = .{ .callee = &enum_callee, .args = &args } });

    try std.testing.expectEqual(TypeId.unresolved, l.inferExprType(&enum_call));

    l.target_type = .i32;
    try std.testing.expectEqual(TypeId.i32, l.inferExprType(&enum_call));
}

// ── Layer 2: the CallPlan object (kind / target / variant / properties) ─────

test "plan: builtin and reflection carry kind + target" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CallResolver{ .l = &l };

    var arg = node(.{ .int_literal = .{ .value = 1 } });
    var args = [_]*Node{&arg};

    var so_callee = node(.{ .identifier = .{ .name = "size_of" } });
    var so_call = node(.{ .call = .{ .callee = &so_callee, .args = &args } });
    const so = cr.plan(&so_call.data.call);
    try std.testing.expectEqual(CallPlan.Kind.builtin, so.kind);
    try std.testing.expectEqual(BuiltinId.size_of, so.target.builtin);
    try std.testing.expectEqual(TypeId.i64, so.return_type);

    var tn_callee = node(.{ .identifier = .{ .name = "type_name" } });
    var tn_call = node(.{ .call = .{ .callee = &tn_callee, .args = &args } });
    const tn = cr.plan(&tn_call.data.call);
    try std.testing.expectEqual(CallPlan.Kind.reflection, tn.kind);
    try std.testing.expectEqualStrings("type_name", tn.target.named);
    try std.testing.expectEqual(TypeId.string, tn.return_type);
}

test "plan: unresolved bare callee" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CallResolver{ .l = &l };

    var callee = node(.{ .identifier = .{ .name = "nope" } });
    var call = node(.{ .call = .{ .callee = &callee, .args = &.{} } });
    const p = cr.plan(&call.data.call);
    try std.testing.expectEqual(CallPlan.Kind.unresolved, p.kind);
    try std.testing.expectEqual(TypeId.unresolved, p.return_type);
}

test "plan: lazy free fn classifies as direct_fn and flags default-arg expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CallResolver{ .l = &l };

    // greet :: (a: i64, b: i64 = 0) -> i64  — registered but NOT lowered, so
    // it resolves through the AST (lazy) arm and `b`'s default is splice-able.
    const params = [_]ast.Param{
        .{ .name = "a", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeExpr(alloc, "i64") },
        .{ .name = "b", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeExpr(alloc, "i64"), .default_expr = intLit(alloc, 0) },
    };
    const fd = ast.FnDecl{ .name = "greet", .params = &params, .return_type = typeExpr(alloc, "i64"), .body = emptyBody(alloc) };
    l.program_index.fn_ast_map.put("greet", &fd) catch unreachable;

    // greet(1) — omits `b`, so its default is spliced in.
    {
        const one = [_]*Node{intLit(alloc, 1)};
        const call = callNode(alloc, ident(alloc, "greet"), &one);
        const p = cr.plan(&call.data.call);
        try std.testing.expectEqual(CallPlan.Kind.direct_fn, p.kind);
        try std.testing.expectEqualStrings("greet", p.target.named);
        try std.testing.expectEqual(TypeId.i64, p.return_type);
        try std.testing.expect(p.expands_defaults);
        try std.testing.expect(!p.prepends_receiver);
    }
    // greet(1, 2) — all args supplied, no expansion.
    {
        const two = [_]*Node{ intLit(alloc, 1), intLit(alloc, 2) };
        const call = callNode(alloc, ident(alloc, "greet"), &two);
        const p = cr.plan(&call.data.call);
        try std.testing.expectEqual(CallPlan.Kind.direct_fn, p.kind);
        try std.testing.expect(!p.expands_defaults);
    }
}

test "plan: resolved free fn carries func target + __sx_ctx prepend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CallResolver{ .l = &l };

    // noop :: () { } — lowered, so it resolves to a concrete FuncId.
    const fd = ast.FnDecl{ .name = "noop", .params = &.{}, .return_type = null, .body = emptyBody(alloc) };
    l.lowerFunction(&fd, "noop", false);
    const fid = l.resolveFuncByName("noop").?;
    // Stamp the implicit-ctx flag the way the implicit-Context machinery would.
    module.functions.items[@intFromEnum(fid)].has_implicit_ctx = true;

    var callee = node(.{ .identifier = .{ .name = "noop" } });
    var call = node(.{ .call = .{ .callee = &callee, .args = &.{} } });
    const p = cr.plan(&call.data.call);
    try std.testing.expectEqual(CallPlan.Kind.direct_fn, p.kind);
    try std.testing.expectEqual(fid, p.target.func);
    try std.testing.expectEqual(TypeId.void, p.return_type);
    try std.testing.expect(p.prepends_ctx);
}

test "plan: closure and fn-pointer callees, __sx_ctx by calling convention" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    l.implicit_ctx_enabled = true;
    const cr = CallResolver{ .l = &l };

    var scope = Scope.init(alloc, null);
    defer scope.deinit();
    l.scope = &scope;

    // cb : Closure() -> bool  — sx-side closure, carries ctx at slot 0.
    const closure_ty = module.types.closureType(&.{}, .bool);
    scope.put("cb", .{ .ref = Ref.none, .ty = closure_ty, .is_alloca = false });
    {
        const call = callNode(alloc, ident(alloc, "cb"), &.{});
        const p = cr.plan(&call.data.call);
        try std.testing.expectEqual(CallPlan.Kind.closure, p.kind);
        try std.testing.expectEqualStrings("cb", p.target.named);
        try std.testing.expectEqual(TypeId.bool, p.return_type);
        try std.testing.expect(p.prepends_ctx);
    }

    // fp : () -> i32 (default conv) — sx fn-pointer, carries ctx.
    const fp_ty = module.types.functionType(&.{}, .i32);
    scope.put("fp", .{ .ref = Ref.none, .ty = fp_ty, .is_alloca = false });
    {
        const call = callNode(alloc, ident(alloc, "fp"), &.{});
        const p = cr.plan(&call.data.call);
        try std.testing.expectEqual(CallPlan.Kind.fn_pointer, p.kind);
        try std.testing.expectEqual(TypeId.i32, p.return_type);
        try std.testing.expect(p.prepends_ctx);
    }

    // cfp : () -> i32 (C conv) — C fn-pointer, NO implicit ctx.
    const cfp_ty = module.types.functionTypeCC(&.{}, .i32, .c);
    scope.put("cfp", .{ .ref = Ref.none, .ty = cfp_ty, .is_alloca = false });
    {
        const call = callNode(alloc, ident(alloc, "cfp"), &.{});
        const p = cr.plan(&call.data.call);
        try std.testing.expectEqual(CallPlan.Kind.fn_pointer, p.kind);
        try std.testing.expect(!p.prepends_ctx);
    }
}

test "plan: protocol dispatch selects method index + prepends receiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CallResolver{ .l = &l };

    // Drawable :: protocol { measure :: () -> i64; draw :: () -> bool; }
    const methods = [_]ast.ProtocolMethodDecl{
        .{ .name = "measure", .params = &.{}, .param_names = &.{}, .return_type = typeExpr(alloc, "i64"), .default_body = null },
        .{ .name = "draw", .params = &.{}, .param_names = &.{}, .return_type = typeExpr(alloc, "bool"), .default_body = null },
    };
    const pd = ast.ProtocolDecl{ .name = "Drawable", .methods = &methods };
    l.registerProtocolDecl(&pd);

    // A receiver typed as the protocol: `_.(Drawable)`.
    const recv = postfixCast(alloc, intLit(alloc, 0), "Drawable");
    const call = callNode(alloc, fieldAccess(alloc, recv, "draw"), &.{});
    const p = cr.plan(&call.data.call);
    try std.testing.expectEqual(CallPlan.Kind.protocol_dispatch, p.kind);
    try std.testing.expectEqual(@as(u32, 1), p.target.protocol_method);
    try std.testing.expectEqual(TypeId.bool, p.return_type);
    try std.testing.expect(p.prepends_receiver);
}

test "plan: runtime-class instance vs static dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CallResolver{ .l = &l };

    const members = [_]ast.RuntimeClassMember{
        .{ .method = .{ .name = "length", .params = &.{}, .param_names = &.{}, .return_type = typeExpr(alloc, "i64"), .is_static = false } },
        .{ .method = .{ .name = "stringWithUTF8String", .params = &.{}, .param_names = &.{}, .return_type = typeExpr(alloc, "i64"), .is_static = true } },
    };
    var fcd = ast.RuntimeClassDecl{ .name = "NSString", .runtime_path = "NSString", .runtime = .objc_class, .members = &members };
    l.program_index.runtime_class_map.put("NSString", &fcd) catch unreachable;
    _ = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("NSString"), .fields = &.{} } });

    // Instance: `_.(NSString).length` — receiver prepended.
    {
        const recv = postfixCast(alloc, intLit(alloc, 0), "NSString");
        const call = callNode(alloc, fieldAccess(alloc, recv, "length"), &.{});
        const p = cr.plan(&call.data.call);
        try std.testing.expectEqual(CallPlan.Kind.runtime_instance, p.kind);
        try std.testing.expectEqualStrings("length", p.target.runtime_method.name);
        try std.testing.expect(!p.target.runtime_method.is_static);
        try std.testing.expectEqual(TypeId.i64, p.return_type);
        try std.testing.expect(p.prepends_receiver);
    }
    // Static: `NSString.stringWithUTF8String(...)` — no receiver.
    {
        const call = callNode(alloc, fieldAccess(alloc, ident(alloc, "NSString"), "stringWithUTF8String"), &.{});
        const p = cr.plan(&call.data.call);
        try std.testing.expectEqual(CallPlan.Kind.runtime_static, p.kind);
        try std.testing.expectEqualStrings("stringWithUTF8String", p.target.runtime_method.name);
        try std.testing.expect(p.target.runtime_method.is_static);
        try std.testing.expect(!p.prepends_receiver);
    }
}

test "plan: enum construction (qualified + dot-shorthand) carries variant tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CallResolver{ .l = &l };

    const red = module.types.internString("Red");
    const green = module.types.internString("Green");
    const variants = [_]@TypeOf(red){ red, green };
    const color = module.types.intern(.{ .@"enum" = .{ .name = module.types.internString("Color"), .variants = &variants } });

    // Qualified: `Color.Green`.
    {
        const call = callNode(alloc, fieldAccess(alloc, typeExpr(alloc, "Color"), "Green"), &.{});
        const p = cr.plan(&call.data.call);
        try std.testing.expectEqual(CallPlan.Kind.enum_construct, p.kind);
        try std.testing.expectEqual(color, p.target.constructed);
        try std.testing.expectEqual(@as(?u32, 1), p.variant);
        try std.testing.expectEqual(color, p.return_type);
    }
    // Dot-shorthand: `.Green` with the union as the target type.
    {
        l.target_type = color;
        const call = callNode(alloc, mk(alloc, .{ .enum_literal = .{ .name = "Green" } }), &.{});
        const p = cr.plan(&call.data.call);
        try std.testing.expectEqual(CallPlan.Kind.enum_shorthand, p.kind);
        try std.testing.expectEqual(color, p.target.constructed);
        try std.testing.expectEqual(@as(?u32, 1), p.variant);
        try std.testing.expectEqual(color, p.return_type);
    }
}

test "plan: free-function UFCS prepends receiver, distinct from namespace_fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CallResolver{ .l = &l };

    // struct Counter, and a FREE ufcs function `bump :: ufcs (c: Counter) ->
    // i32` — NOT registered as `Counter.bump`, so it can only be reached via
    // UFCS. Dot-dispatch is OPT-IN: the fn carries `is_ufcs` and is
    // registered in `fn_ast_map`, where the plan's opt-in gate reads it.
    const counter = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("Counter"), .fields = &.{} } });
    const c_param = ast.Param{ .name = "c", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeExpr(alloc, "Counter") };
    const params = [_]ast.Param{c_param};
    const ret_stmt = mk(alloc, .{ .return_stmt = .{ .value = intLit(alloc, 7) } });
    const body = mk(alloc, .{ .block = .{ .stmts = &[_]*Node{ret_stmt} } });
    const fd = ast.FnDecl{ .name = "bump", .params = &params, .return_type = typeExpr(alloc, "i32"), .body = body, .is_ufcs = true };
    l.program_index.fn_ast_map.put("bump", &fd) catch unreachable;
    l.lowerFunction(&fd, "bump", false);
    const fid = l.resolveFuncByName("bump").?;
    module.functions.items[@intFromEnum(fid)].has_implicit_ctx = true;

    // A value receiver in scope: `c : Counter`. `c.bump()` is UFCS, not a
    // namespace call — the receiver must be prepended.
    var scope = Scope.init(alloc, null);
    defer scope.deinit();
    scope.put("c", .{ .ref = Ref.none, .ty = counter, .is_alloca = false });
    l.scope = &scope;

    const call = callNode(alloc, fieldAccess(alloc, ident(alloc, "c"), "bump"), &.{});
    const p = cr.plan(&call.data.call);
    try std.testing.expectEqual(CallPlan.Kind.free_fn_ufcs, p.kind);
    try std.testing.expectEqual(fid, p.target.func);
    try std.testing.expect(p.prepends_receiver);
    try std.testing.expect(p.prepends_ctx);
    try std.testing.expectEqual(TypeId.i32, p.return_type);
}

test "plan: qualified namespace function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CallResolver{ .l = &l };

    // mathlib.square :: () -> i64  — registered under its qualified name, lazy.
    const fd = ast.FnDecl{ .name = "mathlib.square", .params = &.{}, .return_type = typeExpr(alloc, "i64"), .body = emptyBody(alloc) };
    l.program_index.fn_ast_map.put("mathlib.square", &fd) catch unreachable;

    const call = callNode(alloc, fieldAccess(alloc, ident(alloc, "mathlib"), "square"), &.{});
    const p = cr.plan(&call.data.call);
    try std.testing.expectEqual(CallPlan.Kind.namespace_fn, p.kind);
    try std.testing.expectEqualStrings("mathlib.square", p.target.named);
    try std.testing.expectEqual(TypeId.i64, p.return_type);
}
