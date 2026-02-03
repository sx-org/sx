// Tests for conversions.zig — the coercion-planning classifier
// (`CoercionResolver`). Reached via `ir.CoercionResolver{ .l = &lowering }`,
// mirroring the other facade tests. These pin the `classify` / `classifyXX`
// DECISIONS; `coerceToType` / `lowerXX` emit them (emission stays in Lowering).

const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;

const ir_mod = @import("ir.zig");
const TypeId = ir_mod.TypeId;
const Lowering = ir_mod.Lowering;
const CoercionResolver = ir_mod.CoercionResolver;
const Plan = CoercionResolver.CoercionPlan;
const XXPlan = CoercionResolver.XXPlan;

fn protoMethodReq(name: []const u8) ast.ProtocolMethodDecl {
    return .{ .name = name, .params = &.{}, .param_names = &.{}, .return_type = null, .default_body = null };
}

test "conversions: classify covers the built-in coercion ladder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CoercionResolver{ .l = &l };
    const tt = &module.types;

    // no-op + Any box/unbox.
    try std.testing.expectEqual(Plan.no_op, cr.classify(.i64, .i64));
    try std.testing.expectEqual(Plan.unbox_any, cr.classify(.any, .i64));
    try std.testing.expectEqual(Plan.box_any, cr.classify(.i64, .any));

    // Numeric / pointer ladder.
    try std.testing.expectEqual(Plan.widen, cr.classify(.i32, .i64));
    try std.testing.expectEqual(Plan.narrow, cr.classify(.i64, .i32));
    try std.testing.expectEqual(Plan.int_to_float, cr.classify(.i32, .f64));
    try std.testing.expectEqual(Plan.float_to_int, cr.classify(.f64, .i32));
    const ptr_i64 = tt.ptrTo(.i64);
    try std.testing.expectEqual(Plan.ptr_int_bitcast, cr.classify(ptr_i64, .i64));
    try std.testing.expectEqual(Plan.ptr_int_bitcast, cr.classify(.i64, ptr_i64));

    // Optional wrap / unwrap, and void → optional.
    const opt_i64 = tt.optionalOf(.i64);
    try std.testing.expectEqual(Plan.optional_wrap, cr.classify(.i64, opt_i64));
    try std.testing.expectEqual(Plan.optional_unwrap, cr.classify(opt_i64, .i64));
    try std.testing.expectEqual(Plan.void_to_optional, cr.classify(.void, opt_i64));

    // `?A → ?B` (differing payloads) is a presence-preserving payload coercion,
    // NOT the always-present unwrap-then-rewrap that the `.optional_wrap` arm
    // produced (issue 0180). Same-payload optionals are `.no_op`.
    const opt_i32 = tt.optionalOf(.i32);
    try std.testing.expectEqual(Plan.optional_to_optional, cr.classify(opt_i32, opt_i64));
    try std.testing.expectEqual(Plan.no_op, cr.classify(opt_i64, opt_i64));

    // `?T → bool` is NOT an unwrap-then-narrow presence test (issue 0169):
    // it must reject, never silently produce `false`. But `?bool → bool`
    // is a genuine unwrap of a bool payload.
    try std.testing.expectEqual(Plan.optional_to_bool_reject, cr.classify(opt_i64, .bool));
    const opt_bool = tt.optionalOf(.bool);
    try std.testing.expectEqual(Plan.optional_unwrap, cr.classify(opt_bool, .bool));

    // Tuple → tuple, same arity.
    const t_ss = tt.intern(.{ .tuple = .{ .fields = &[_]TypeId{ .i64, .i64 }, .names = null } });
    const t_ii = tt.intern(.{ .tuple = .{ .fields = &[_]TypeId{ .i32, .i32 }, .names = null } });
    try std.testing.expectEqual(Plan.tuple_elementwise, cr.classify(t_ss, t_ii));

    // Closure value → bare fn-ptr: rejected.
    const clo = tt.closureType(&.{}, .void);
    const fnp = tt.functionType(&.{}, .void);
    try std.testing.expectEqual(Plan.closure_to_fn_reject, cr.classify(clo, fnp));

    // Two unrelated structs: no built-in applies → `.none` (lowerXX then tries
    // a user `Into`). No silent numeric default.
    const a = tt.intern(.{ .@"struct" = .{ .name = tt.internString("A"), .fields = &.{} } });
    const b = tt.intern(.{ .@"struct" = .{ .name = tt.internString("B"), .fields = &.{} } });
    try std.testing.expectEqual(Plan.none, cr.classify(a, b));
}

test "conversions: classify selects protocol erasure for a concrete source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CoercionResolver{ .l = &l };

    const methods = [_]ast.ProtocolMethodDecl{protoMethodReq("draw")};
    const pd = ast.ProtocolDecl{ .name = "Drawable", .methods = &methods };
    l.registerProtocolDecl(&pd);
    const drawable = module.types.findByName(module.types.internString("Drawable")).?;
    const circle = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("Circle"), .fields = &.{} } });

    // Concrete struct → protocol value: erasure.
    try std.testing.expectEqual(Plan.erase_protocol, cr.classify(circle, drawable));
}

test "conversions: classifyXX picks the xx-operator head decision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CoercionResolver{ .l = &l };
    const tt = &module.types;

    const methods = [_]ast.ProtocolMethodDecl{protoMethodReq("draw")};
    const pd = ast.ProtocolDecl{ .name = "Drawable", .methods = &methods };
    l.registerProtocolDecl(&pd);
    const drawable = tt.findByName(tt.internString("Drawable")).?;

    // Any source unboxes regardless of dst.
    try std.testing.expectEqual(XXPlan.unbox_any, cr.classifyXX(.any, .i64));
    // Same type → no-op.
    try std.testing.expectEqual(XXPlan.no_op, cr.classifyXX(.i64, .i64));
    // dst is a protocol → erasure (checked before the src-protocol case).
    try std.testing.expectEqual(XXPlan.erase_protocol, cr.classifyXX(.i64, drawable));
    // src is a protocol, dst is a pointer → recover the ctx pointer.
    try std.testing.expectEqual(XXPlan.protocol_to_pointer, cr.classifyXX(drawable, tt.ptrTo(.i64)));
    // src is a protocol but dst is NOT a pointer → fall to the ladder.
    try std.testing.expectEqual(XXPlan.coerce, cr.classifyXX(drawable, .i64));
    // Pointer materialization (`xx value` into a `*T` slot, no built-in) defers
    // to the ladder + the user-`Into` pointer fallback in lowerXX.
    const a = tt.intern(.{ .@"struct" = .{ .name = tt.internString("A"), .fields = &.{} } });
    try std.testing.expectEqual(XXPlan.coerce, cr.classifyXX(a, tt.ptrTo(.i32)));

    // dst is `?P` (protocol child): node-aware erase-then-wrap, so an lvalue
    // source BORROWS its storage like the plain erasure — never the ladder's
    // node-less value arm, which heap-boxes a leaked copy (issue 0213).
    const opt_drawable = tt.optionalOf(drawable);
    try std.testing.expectEqual(XXPlan.erase_protocol_wrap, cr.classifyXX(a, opt_drawable));
    // Pointer sources take the same node-aware path (borrow, 0 allocations).
    try std.testing.expectEqual(XXPlan.erase_protocol_wrap, cr.classifyXX(tt.ptrTo(a), opt_drawable));
    // Excluded sources keep their existing plans: the child itself (plain
    // wrap), `void` (the null literal), and an optional source
    // (presence-preserving `?A → ?P`) all defer to the ladder.
    try std.testing.expectEqual(XXPlan.coerce, cr.classifyXX(drawable, opt_drawable));
    try std.testing.expectEqual(XXPlan.coerce, cr.classifyXX(.void, opt_drawable));
    try std.testing.expectEqual(XXPlan.coerce, cr.classifyXX(tt.optionalOf(a), opt_drawable));
}

test "conversions: unmodeled width-mismatched coercion is flagged unsafe (issue 0191)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const cr = CoercionResolver{ .l = &l };
    const tt = &module.types;

    // The issue-0191 weld precondition: a 16-byte `string` flowing into an
    // 8-byte `i64` slot has NO modeled coercion — the ladder yields `.none`,
    // so the passthrough used to bit-reinterpret it. The unsafe-store
    // predicate must flag it (both directions).
    try std.testing.expectEqual(Plan.none, cr.classify(.string, .i64));
    try std.testing.expect(l.noneReinterpretIsUnsafe(.string, .i64));
    try std.testing.expect(l.noneReinterpretIsUnsafe(.i64, .string));

    // A multi-field struct into a scalar slot: same class of weld.
    const p3_fields = &[_]ir_mod.TypeInfo.StructInfo.Field{
        .{ .name = tt.internString("x"), .ty = .i64 },
        .{ .name = tt.internString("y"), .ty = .i64 },
        .{ .name = tt.internString("z"), .ty = .i64 },
    };
    const p3 = tt.intern(.{ .@"struct" = .{ .name = tt.internString("P3"), .fields = alloc.dupe(ir_mod.TypeInfo.StructInfo.Field, p3_fields) catch unreachable } });
    try std.testing.expect(l.noneReinterpretIsUnsafe(p3, .i64));

    // SAME-width unmodeled pairs stay allowed — the long-standing legitimate
    // bit-compatible reinterpretation family (`i64 → isize`-style).
    try std.testing.expect(!l.noneReinterpretIsUnsafe(.i64, .isize));

    // Modeled coercions are never "unsafe none": the ladder handles them.
    try std.testing.expect(!l.noneReinterpretIsUnsafe(.i32, .i64));
    try std.testing.expect(!l.noneReinterpretIsUnsafe(.i64, tt.optionalOf(.i64)));
}
