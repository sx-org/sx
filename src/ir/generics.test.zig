// Tests for generics.zig — the generic substitution + mono-key owner
// (`GenericResolver`). Reached via `ir.GenericResolver{ .l = &lowering }`,
// mirroring how calls.test.zig drives `CallResolver`. Moved here from
// lower.test.zig when the helpers moved out of `Lowering` (A4.1 sub-step 2).

const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;

const ir_mod = @import("ir.zig");
const TypeId = ir_mod.TypeId;
const Lowering = ir_mod.Lowering;
const GenericResolver = ir_mod.GenericResolver;

fn typeKeyword(alloc: std.mem.Allocator, name: []const u8) *Node {
    const n = alloc.create(Node) catch unreachable;
    n.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = name, .is_generic = false } } };
    return n;
}

test "generics: mangleTypeName encodes the mono-key fragment per type shape" {
    // Arena: the compound arms allocate fragment strings via the module
    // allocator (`allocPrint` / ArrayList) and never free them — the real
    // compiler runs in the compile arena, so an arena keeps the leak checker
    // clean without changing the encoding under test.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const gr = GenericResolver{ .l = &l };
    const tt = &module.types;

    // Builtins — the leaf fragments `mangleGenericName` concatenates per
    // bound type param (`base__<frag>...`).
    try std.testing.expectEqualStrings("i64", gr.mangleTypeName(.i64));
    try std.testing.expectEqualStrings("u8", gr.mangleTypeName(.u8));
    try std.testing.expectEqualStrings("f32", gr.mangleTypeName(.f32));
    try std.testing.expectEqualStrings("bool", gr.mangleTypeName(.bool));
    try std.testing.expectEqualStrings("any", gr.mangleTypeName(.any));
    try std.testing.expectEqualStrings("string", gr.mangleTypeName(.string));

    // Compound shapes — prefix + recursive inner fragment.
    try std.testing.expectEqualStrings("ptr_i64", gr.mangleTypeName(tt.ptrTo(.i64)));
    try std.testing.expectEqualStrings("opt_i64", gr.mangleTypeName(tt.optionalOf(.i64)));
    try std.testing.expectEqualStrings("ptr_opt_u8", gr.mangleTypeName(tt.ptrTo(tt.optionalOf(.u8))));
    try std.testing.expectEqualStrings("SL_f64", gr.mangleTypeName(tt.intern(.{ .slice = .{ .element = .f64 } })));
    try std.testing.expectEqualStrings("mptr_u8", gr.mangleTypeName(tt.intern(.{ .many_pointer = .{ .element = .u8 } })));
    try std.testing.expectEqualStrings("AR_4_i32", gr.mangleTypeName(tt.intern(.{ .array = .{ .element = .i32, .length = 4 } })));
    try std.testing.expectEqualStrings("vec_3_f32", gr.mangleTypeName(tt.intern(.{ .vector = .{ .element = .f32, .length = 3 } })));

    // Named aggregate → its declared name.
    const pt = tt.intern(.{ .@"struct" = .{ .name = tt.internString("Point"), .fields = &.{} } });
    try std.testing.expectEqualStrings("Point", gr.mangleTypeName(pt));

    // Tuple: "tu" + "_<frag>" per field.
    const tup = tt.intern(.{ .tuple = .{ .fields = &[_]TypeId{ .i64, .bool }, .names = null } });
    try std.testing.expectEqualStrings("tu_i64_bool", gr.mangleTypeName(tup));

    // The `Lowering` wrapper delegates here — same result.
    try std.testing.expectEqualStrings("ptr_i64", l.mangleTypeName(tt.ptrTo(.i64)));
}

test "generics: inferGenericReturnType binds explicit type args, resolves return, restores bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const gr = GenericResolver{ .l = &l };

    // pair :: ($T: Type, a: T, b: T) -> T — the return type IS the bound `T`.
    const tps = [_]ast.StructTypeParam{.{ .name = "T", .constraint = typeKeyword(alloc, "Type") }};
    const params = [_]ast.Param{
        .{ .name = "T", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeKeyword(alloc, "Type") },
        .{ .name = "a", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeKeyword(alloc, "T") },
        .{ .name = "b", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeKeyword(alloc, "T") },
    };
    const body = alloc.create(Node) catch unreachable;
    body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = &.{} } } };
    const fd = ast.FnDecl{ .name = "pair", .params = &params, .return_type = typeKeyword(alloc, "T"), .body = body, .type_params = &tps };

    // Explicit type arg in position 0 binds `T`; the inferred return follows it.
    const mkCall = struct {
        fn f(a: std.mem.Allocator, type_name: []const u8) ast.Call {
            const targ = typeKeyword(a, type_name);
            const x = a.create(Node) catch unreachable;
            x.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = 1 } } };
            const y = a.create(Node) catch unreachable;
            y.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = 2 } } };
            const callee = a.create(Node) catch unreachable;
            callee.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = "pair" } } };
            const args = a.alloc(*Node, 3) catch unreachable;
            args[0] = targ;
            args[1] = x;
            args[2] = y;
            return .{ .callee = callee, .args = args };
        }
    }.f;

    const c_i64 = mkCall(alloc, "i64");
    try std.testing.expectEqual(TypeId.i64, gr.inferGenericReturnType(&fd, &c_i64));
    const c_f64 = mkCall(alloc, "f64");
    try std.testing.expectEqual(TypeId.f64, gr.inferGenericReturnType(&fd, &c_f64));

    // The scoped binding env restores the prior `type_bindings` (null here) —
    // it must NOT leak the call's temporary bindings (the issue-0048/0050 class).
    try std.testing.expect(l.type_bindings == null);
}

test "generics: buildTypeBindings infers a type param from value args, widest wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const gr = GenericResolver{ .l = &l };

    // add :: (a: T, b: T) -> T  with type param T — NO leading `$T: Type` decl,
    // so T is inferred from the value args (strategy 2), not passed explicitly.
    const tps = [_]ast.StructTypeParam{.{ .name = "T", .constraint = typeKeyword(alloc, "Type") }};
    const params = [_]ast.Param{
        .{ .name = "a", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeKeyword(alloc, "T") },
        .{ .name = "b", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeKeyword(alloc, "T") },
    };
    const body = alloc.create(Node) catch unreachable;
    body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = &.{} } } };
    const fd = ast.FnDecl{ .name = "add", .params = &params, .return_type = typeKeyword(alloc, "T"), .body = body, .type_params = &tps };

    const intLit = struct {
        fn f(a: std.mem.Allocator, v: i64) *Node {
            const n = a.create(Node) catch unreachable;
            n.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = v } } };
            return n;
        }
    }.f;
    const floatLit = struct {
        fn f(a: std.mem.Allocator, v: f64) *Node {
            const n = a.create(Node) catch unreachable;
            n.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .float_literal = .{ .value = v } } };
            return n;
        }
    }.f;

    // add(1, 2) — both args i64 → T = i64.
    {
        const args = [_]*const Node{ intLit(alloc, 1), intLit(alloc, 2) };
        var bindings = gr.buildTypeBindings(&fd, &args);
        defer bindings.deinit();
        try std.testing.expectEqual(TypeId.i64, bindings.get("T").?);
    }
    // add(1.0, 2) — mixed f64/i64 → widest f64 wins regardless of order.
    {
        const args = [_]*const Node{ floatLit(alloc, 1.0), intLit(alloc, 2) };
        var bindings = gr.buildTypeBindings(&fd, &args);
        defer bindings.deinit();
        try std.testing.expectEqual(TypeId.f64, bindings.get("T").?);
    }
    {
        const args = [_]*const Node{ intLit(alloc, 1), floatLit(alloc, 2.0) };
        var bindings = gr.buildTypeBindings(&fd, &args);
        defer bindings.deinit();
        try std.testing.expectEqual(TypeId.f64, bindings.get("T").?);
    }
}
