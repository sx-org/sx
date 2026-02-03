// Tests for expr_typer.zig — focused on the structural (non-call) expression
// shapes ExprTyper owns, reached via the public `Lowering.inferExprType`
// delegation. These cases need no lexical scope / program-index state, so a
// bare `Lowering.init` suffices.

const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;

const ir_mod = @import("ir.zig");
const TypeId = ir_mod.TypeId;
const Ref = ir_mod.Ref;
const Lowering = ir_mod.Lowering;
const Scope = @import("lower.zig").Scope;

fn node(data: ast.Node.Data) Node {
    return .{ .span = .{ .start = 0, .end = 0 }, .data = data };
}

test "expr_typer: literal shapes" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);

    var int_n = node(.{ .int_literal = .{ .value = 7 } });
    var float_n = node(.{ .float_literal = .{ .value = 1.5 } });
    var bool_n = node(.{ .bool_literal = .{ .value = true } });
    var str_n = node(.{ .string_literal = .{ .raw = "hi" } });

    try std.testing.expectEqual(TypeId.i64, l.inferExprType(&int_n));
    try std.testing.expectEqual(TypeId.f64, l.inferExprType(&float_n));
    try std.testing.expectEqual(TypeId.bool, l.inferExprType(&bool_n));
    try std.testing.expectEqual(TypeId.string, l.inferExprType(&str_n));
}

test "expr_typer: binary comparison is bool, int arithmetic stays int" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);

    var lhs = node(.{ .int_literal = .{ .value = 1 } });
    var rhs = node(.{ .int_literal = .{ .value = 2 } });

    var cmp = node(.{ .binary_op = .{ .op = .eq, .lhs = &lhs, .rhs = &rhs } });
    try std.testing.expectEqual(TypeId.bool, l.inferExprType(&cmp));

    var add = node(.{ .binary_op = .{ .op = .add, .lhs = &lhs, .rhs = &rhs } });
    try std.testing.expectEqual(TypeId.i64, l.inferExprType(&add));
}

// A non-comparison binary op infers the PROMOTED result
// of (lhs, rhs), not the LHS alone — so a mixed int+float op types as the float
// in EITHER operand order (was LHS-biased: `int + float` → i64 while
// `float + int` → f64). This is what feeds the typed-const validation that
// rejected `i64 : 0.5 + M` but not `i64 : M + 0.5`.
test "expr_typer: mixed int+float arithmetic promotes to float, order-independent" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);

    var int_n = node(.{ .int_literal = .{ .value = 2 } });
    var float_n = node(.{ .float_literal = .{ .value = 0.5 } });

    // int LHS, float RHS → f64 (was i64 before the fix).
    var add_if = node(.{ .binary_op = .{ .op = .add, .lhs = &int_n, .rhs = &float_n } });
    try std.testing.expectEqual(TypeId.f64, l.inferExprType(&add_if));

    // float LHS, int RHS → f64 (already correct; confirms order-independence).
    var add_fi = node(.{ .binary_op = .{ .op = .add, .lhs = &float_n, .rhs = &int_n } });
    try std.testing.expectEqual(TypeId.f64, l.inferExprType(&add_fi));

    // Multiplication promotes the same way.
    var mul_if = node(.{ .binary_op = .{ .op = .mul, .lhs = &int_n, .rhs = &float_n } });
    try std.testing.expectEqual(TypeId.f64, l.inferExprType(&mul_if));
}

// The shared promotion helper itself (single source of truth for both
// `lowerBinaryOp`'s value type and `inferExprType`): an integer LHS with a
// floating-point RHS promotes to the float; every other pairing keeps the LHS.
test "arithResultType: int×float promotes to float, else takes lhs" {
    try std.testing.expectEqual(TypeId.f64, Lowering.arithResultType(.i64, .f64));
    try std.testing.expectEqual(TypeId.f32, Lowering.arithResultType(.u32, .f32));
    try std.testing.expectEqual(TypeId.f32, Lowering.arithResultType(.i64, .f32));
    // Non-promoting pairings keep the LHS type.
    try std.testing.expectEqual(TypeId.i64, Lowering.arithResultType(.i64, .i64));
    try std.testing.expectEqual(TypeId.f64, Lowering.arithResultType(.f64, .i64));
    try std.testing.expectEqual(TypeId.f32, Lowering.arithResultType(.f32, .f64));
}

test "expr_typer: unary not is bool, negate preserves operand type" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);

    var b = node(.{ .bool_literal = .{ .value = false } });
    var not_n = node(.{ .unary_op = .{ .op = .not, .operand = &b } });
    try std.testing.expectEqual(TypeId.bool, l.inferExprType(&not_n));

    var f = node(.{ .float_literal = .{ .value = 2.0 } });
    var neg_n = node(.{ .unary_op = .{ .op = .negate, .operand = &f } });
    try std.testing.expectEqual(TypeId.f64, l.inferExprType(&neg_n));
}

test "expr_typer: deref of a non-pointer is unresolved" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);

    var i = node(.{ .int_literal = .{ .value = 0 } });
    var deref_n = node(.{ .deref_expr = .{ .operand = &i } });
    try std.testing.expectEqual(TypeId.unresolved, l.inferExprType(&deref_n));
}

// a raw `` `f64 `` value binding shadows the builtin numeric type
// name — `` `f64.epsilon `` (an `.identifier` receiver) must type as the value's
// field, NOT the float numeric-limit fold. A bare `f64.epsilon` (a `.type_expr`
// receiver, never shadowed) still folds to the queried float type. This pins the
// two-resolver agreement: expr_typer's inference must match lowerNumericLimit.
test "expr_typer: raw value binding shadows numeric-limit, bare type still folds" {
    // Arena-backed (like calls.test.zig's scope tests): the `.identifier`
    // field-access path interns a `obj.field` probe string into `l.alloc`,
    // which the production compiler owns via an arena — an explicit free would
    // not match the real lifetime.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);

    // A struct `Box { epsilon: i64 }` bound to the raw name `` `f64 ``.
    const box_fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = module.types.internString("epsilon"), .ty = .i64 },
    };
    const box_ty = module.types.intern(.{ .@"struct" = .{
        .name = module.types.internString("Box"),
        .fields = &box_fields,
    } });

    var scope = Scope.init(alloc, null);
    defer scope.deinit();
    l.scope = &scope;
    scope.put("f64", .{ .ref = Ref.none, .ty = box_ty, .is_alloca = false });

    // `` `f64.epsilon `` — identifier receiver resolving to the value binding →
    // ordinary field read, types as i64 (the field), not f64.
    var raw_recv = node(.{ .identifier = .{ .name = "f64", .is_raw = true } });
    var raw_fa = node(.{ .field_access = .{ .object = &raw_recv, .field = "epsilon" } });
    try std.testing.expectEqual(TypeId.i64, l.inferExprType(&raw_fa));

    // bare `f64.epsilon` — type_expr receiver, never shadowed → folds to f64.
    var type_recv = node(.{ .type_expr = .{ .name = "f64" } });
    var type_fa = node(.{ .field_access = .{ .object = &type_recv, .field = "epsilon" } });
    try std.testing.expectEqual(TypeId.f64, l.inferExprType(&type_fa));
}

// a raw value binding can shadow a builtin numeric type name through
// any of three sources — lexical scope, program globals, or module
// value constants. The shared `identifierBindsValue` guard consults all three,
// so a global `` `f32 := Box.{…} `` and a module-const `` `i16 :: Box.{…} `` each
// read the value's field (NOT the numeric-limit fold), while a bare `f32.max` /
// `i16.max` (a `.type_expr` receiver) still folds. Pins the guard across the two
// non-lexical sources the attempt-3 scope-only fix missed.
test "expr_typer: global and module-const raw bindings shadow numeric-limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);

    // `Box { max: i64 }` — the struct both raw bindings resolve to.
    const box_fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = module.types.internString("max"), .ty = .i64 },
    };
    const box_ty = module.types.intern(.{ .@"struct" = .{
        .name = module.types.internString("Box"),
        .fields = &box_fields,
    } });

    // GLOBAL raw binding `` `f32 := Box.{…} `` — registered in global_names.
    try l.program_index.global_names.put("f32", .{ .id = @enumFromInt(0), .ty = box_ty });
    // MODULE-CONST raw binding `` `i16 :: Box.{…} `` — registered in module_const_map.
    var const_val = node(.{ .int_literal = .{ .value = 0 } });
    try l.program_index.module_const_map.put("i16", .{ .value = &const_val, .ty = box_ty });

    // The shared guard sees both non-lexical bindings, but not an unbound spelling.
    try std.testing.expect(l.identifierBindsValue("f32"));
    try std.testing.expect(l.identifierBindsValue("i16"));
    try std.testing.expect(!l.identifierBindsValue("u8"));

    // `` `f32.max `` — global raw receiver → ordinary field read, types as i64
    // (the field), not f32 (the fold).
    var g_recv = node(.{ .identifier = .{ .name = "f32", .is_raw = true } });
    var g_fa = node(.{ .field_access = .{ .object = &g_recv, .field = "max" } });
    try std.testing.expectEqual(TypeId.i64, l.inferExprType(&g_fa));

    // `` `i16.max `` — module-const raw receiver → ordinary field read, types as i64.
    var c_recv = node(.{ .identifier = .{ .name = "i16", .is_raw = true } });
    var c_fa = node(.{ .field_access = .{ .object = &c_recv, .field = "max" } });
    try std.testing.expectEqual(TypeId.i64, l.inferExprType(&c_fa));

    // bare `f32.max` — type_expr receiver, never shadowed → folds to f32, even
    // though a global `` `f32 `` value is bound.
    var bare_f32 = node(.{ .type_expr = .{ .name = "f32" } });
    var bare_f32_fa = node(.{ .field_access = .{ .object = &bare_f32, .field = "max" } });
    try std.testing.expectEqual(TypeId.f32, l.inferExprType(&bare_f32_fa));

    // bare `i16.max` — type_expr receiver, never shadowed → folds to the i16
    // type, even though a module-const `` `i16 `` value is bound.
    var bare_i16 = node(.{ .type_expr = .{ .name = "i16" } });
    var bare_i16_fa = node(.{ .field_access = .{ .object = &bare_i16, .field = "max" } });
    try std.testing.expectEqual(TypeId.i16, l.inferExprType(&bare_i16_fa));
}
