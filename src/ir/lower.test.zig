// Tests for lower.zig

const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;

const ir_mod = @import("ir.zig");
const TypeId = ir_mod.TypeId;
const Ref = ir_mod.Ref;
const FuncId = ir_mod.FuncId;
const Lowering = ir_mod.Lowering;

const parser = @import("../parser.zig");
const imports = @import("../imports.zig");

test "lower: simple function with arithmetic" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();

    // Build a minimal AST: add :: (a: i64, b: i64) -> i64 { return a + b; }
    const a_type = alloc.create(Node) catch unreachable;
    a_type.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    const b_type = alloc.create(Node) catch unreachable;
    b_type.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    const ret_type = alloc.create(Node) catch unreachable;
    ret_type.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };

    const a_ident = alloc.create(Node) catch unreachable;
    a_ident.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = "a" } } };
    const b_ident = alloc.create(Node) catch unreachable;
    b_ident.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = "b" } } };

    const add_expr = alloc.create(Node) catch unreachable;
    add_expr.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .binary_op = .{
        .op = .add,
        .lhs = a_ident,
        .rhs = b_ident,
    } } };

    const ret_stmt = alloc.create(Node) catch unreachable;
    ret_stmt.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .return_stmt = .{ .value = add_expr } } };

    const body = alloc.create(Node) catch unreachable;
    const stmts: []const *Node = &.{ret_stmt};
    body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = stmts } } };

    defer alloc.destroy(a_type);
    defer alloc.destroy(b_type);
    defer alloc.destroy(ret_type);
    defer alloc.destroy(a_ident);
    defer alloc.destroy(b_ident);
    defer alloc.destroy(add_expr);
    defer alloc.destroy(ret_stmt);
    defer alloc.destroy(body);

    const params: []const ast.Param = &.{
        .{ .name = "a", .name_span = .{ .start = 0, .end = 0 }, .type_expr = a_type },
        .{ .name = "b", .name_span = .{ .start = 0, .end = 0 }, .type_expr = b_type },
    };

    const fn_decl = ast.FnDecl{
        .name = "add",
        .params = params,
        .return_type = ret_type,
        .body = body,
    };

    var lowering = Lowering.init(&module);
    lowering.lowerFunction(&fn_decl, "add", false);

    // Verify
    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    const func = module.getFunction(FuncId.fromIndex(0));
    try std.testing.expectEqual(@as(usize, 2), func.params.len);
    try std.testing.expectEqual(TypeId.i64, func.ret);
    try std.testing.expect(func.blocks.items.len > 0);

    // Print the IR to verify it looks reasonable
    const print_mod = @import("print.zig");
    var aw = std.Io.Writer.Allocating.init(alloc);
    try print_mod.printModule(&module, &aw.writer);
    var result = aw.writer.toArrayList();
    defer result.deinit(alloc);

    const output = result.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "func @add") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "entry:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "add %") != null or std.mem.indexOf(u8, output, "ret %") != null);
}

test "lower: writable slice ptr keeps pointer type on wasm32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try alloc.dupeZ(u8,
        \\main :: () {
        \\    bytes : []u8 = .[];
        \\    data : [*]u8 = ---;
        \\    bytes.ptr = data;
        \\}
        \\
    );
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    module.types.pointer_size = 4;
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);

    try std.testing.expect(!diagnostics.hasErrors());
}

test "lower: bare function values use a pointer-width word on wasm32 (issue 0318)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try alloc.dupeZ(u8,
        \\Callback :: (value: i64) -> i64;
        \\Holder :: struct { callback: Callback; }
        \\accept :: (value: i64) -> i64 => value + 1;
        \\invoke :: (callback: Callback) -> i64 => callback(40);
        \\main :: () -> i64 {
        \\    inferred := accept;
        \\    annotated : Callback = accept;
        \\    holder := Holder.{ callback = accept };
        \\    holder.callback = accept;
        \\    return inferred(annotated(holder.callback(invoke(accept))));
        \\}
        \\
    );
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    module.types.pointer_size = 4;
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);

    try std.testing.expect(!diagnostics.hasErrors());
}

test "lower: instructions carry their AST node's source span (ERR E3.0)" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();

    // probe :: (a: i64, b: i64) -> i64 { return a + b; } — the `a + b` node
    // gets a distinctive span so we can find the emitted `add` instruction and
    // assert it was stamped (not left at the empty {0,0} default).
    const a_type = alloc.create(Node) catch unreachable;
    a_type.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    const b_type = alloc.create(Node) catch unreachable;
    b_type.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    const ret_type = alloc.create(Node) catch unreachable;
    ret_type.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    const a_ident = alloc.create(Node) catch unreachable;
    a_ident.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = "a" } } };
    const b_ident = alloc.create(Node) catch unreachable;
    b_ident.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = "b" } } };
    const add_expr = alloc.create(Node) catch unreachable;
    add_expr.* = .{ .span = .{ .start = 42, .end = 47 }, .data = .{ .binary_op = .{ .op = .add, .lhs = a_ident, .rhs = b_ident } } };
    const ret_stmt = alloc.create(Node) catch unreachable;
    ret_stmt.* = .{ .span = .{ .start = 30, .end = 50 }, .data = .{ .return_stmt = .{ .value = add_expr } } };
    const body = alloc.create(Node) catch unreachable;
    const stmts: []const *Node = &.{ret_stmt};
    body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = stmts } } };
    defer {
        alloc.destroy(a_type);
        alloc.destroy(b_type);
        alloc.destroy(ret_type);
        alloc.destroy(a_ident);
        alloc.destroy(b_ident);
        alloc.destroy(add_expr);
        alloc.destroy(ret_stmt);
        alloc.destroy(body);
    }

    const params: []const ast.Param = &.{
        .{ .name = "a", .name_span = .{ .start = 0, .end = 0 }, .type_expr = a_type },
        .{ .name = "b", .name_span = .{ .start = 0, .end = 0 }, .type_expr = b_type },
    };
    const fn_decl = ast.FnDecl{ .name = "probe", .params = params, .return_type = ret_type, .body = body };

    var lowering = Lowering.init(&module);
    lowering.lowerFunction(&fn_decl, "probe", false);

    // Find the `add` instruction and assert it carries the `a + b` span.
    const func = module.getFunction(FuncId.fromIndex(0));
    var found = false;
    for (func.blocks.items) |blk| {
        for (blk.insts.items) |inst| {
            if (inst.op == .add) {
                try std.testing.expectEqual(@as(u32, 42), inst.span.start);
                try std.testing.expectEqual(@as(u32, 47), inst.span.end);
                found = true;
            }
        }
    }
    try std.testing.expect(found);
}

test "lower: if/else generates basic blocks" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();

    // Build AST: test :: (c: bool) -> i64 { if c { return 1; } else { return 2; } }
    // The condition must be a runtime value (a param) — a constant `if true`
    // is folded by lowering to a single block, defeating the branch test.
    const cond_node = alloc.create(Node) catch unreachable;
    defer alloc.destroy(cond_node);
    cond_node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = "c" } } };

    const cond_ty = alloc.create(Node) catch unreachable;
    defer alloc.destroy(cond_ty);
    cond_ty.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "bool", .is_generic = false } } };

    const ret1_val = alloc.create(Node) catch unreachable;
    defer alloc.destroy(ret1_val);
    ret1_val.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = 1 } } };

    const ret2_val = alloc.create(Node) catch unreachable;
    defer alloc.destroy(ret2_val);
    ret2_val.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = 2 } } };

    const then_ret = alloc.create(Node) catch unreachable;
    defer alloc.destroy(then_ret);
    then_ret.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .return_stmt = .{ .value = ret1_val } } };

    const else_ret = alloc.create(Node) catch unreachable;
    defer alloc.destroy(else_ret);
    else_ret.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .return_stmt = .{ .value = ret2_val } } };

    const then_body = alloc.create(Node) catch unreachable;
    defer alloc.destroy(then_body);
    then_body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = &.{then_ret} } } };

    const else_body = alloc.create(Node) catch unreachable;
    defer alloc.destroy(else_body);
    else_body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = &.{else_ret} } } };

    const if_node = alloc.create(Node) catch unreachable;
    defer alloc.destroy(if_node);
    if_node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .if_expr = .{
        .condition = cond_node,
        .then_branch = then_body,
        .else_branch = else_body,
        .is_inline = false,
    } } };

    const fn_body = alloc.create(Node) catch unreachable;
    defer alloc.destroy(fn_body);
    fn_body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = &.{if_node} } } };

    const ret_type = alloc.create(Node) catch unreachable;
    defer alloc.destroy(ret_type);
    ret_type.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };

    const fn_decl = ast.FnDecl{
        .name = "test_if",
        .params = &.{.{ .name = "c", .name_span = .{ .start = 0, .end = 0 }, .type_expr = cond_ty }},
        .return_type = ret_type,
        .body = fn_body,
    };

    var lowering = Lowering.init(&module);
    lowering.lowerFunction(&fn_decl, "test_if", false);

    // Verify: should have 4 blocks (entry, if.then, if.else, if.merge)
    const func = module.getFunction(FuncId.fromIndex(0));
    try std.testing.expectEqual(@as(usize, 4), func.blocks.items.len);

    // Print and verify structure
    const print_mod = @import("print.zig");
    var aw = std.Io.Writer.Allocating.init(alloc);
    try print_mod.printModule(&module, &aw.writer);
    var result = aw.writer.toArrayList();
    defer result.deinit(alloc);
    const output = result.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "cond_br") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "if.then") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "if.else") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "if.merge") != null);
}

test "lower: while loop generates header/body/exit blocks" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();

    // Build AST: loop :: () { while true { break; } }
    const cond_node = alloc.create(Node) catch unreachable;
    defer alloc.destroy(cond_node);
    cond_node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .bool_literal = .{ .value = true } } };

    const break_node = alloc.create(Node) catch unreachable;
    defer alloc.destroy(break_node);
    break_node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .break_expr };

    const while_body = alloc.create(Node) catch unreachable;
    defer alloc.destroy(while_body);
    while_body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = &.{break_node} } } };

    const while_node = alloc.create(Node) catch unreachable;
    defer alloc.destroy(while_node);
    while_node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .while_expr = .{
        .condition = cond_node,
        .body = while_body,
    } } };

    const fn_body = alloc.create(Node) catch unreachable;
    defer alloc.destroy(fn_body);
    fn_body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = &.{while_node} } } };

    const fn_decl = ast.FnDecl{
        .name = "loop_test",
        .params = &.{},
        .return_type = null,
        .body = fn_body,
    };

    var lowering = Lowering.init(&module);
    lowering.lowerFunction(&fn_decl, "loop_test", false);

    // Verify: should have 4 blocks (entry, while.hdr, while.body, while.exit)
    const func = module.getFunction(FuncId.fromIndex(0));
    try std.testing.expectEqual(@as(usize, 4), func.blocks.items.len);

    // Print and verify structure
    const print_mod = @import("print.zig");
    var aw = std.Io.Writer.Allocating.init(alloc);
    try print_mod.printModule(&module, &aw.writer);
    var result = aw.writer.toArrayList();
    defer result.deinit(alloc);
    const output = result.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "while.hdr") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "while.body") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "while.exit") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "cond_br") != null);
}

// M1.2 A.1 — Obj-C type-encoding helper.
test "lower: objcTypeEncodingFromSignature emits primitive shapes" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // Niladic void method: -(void)greet  →  "v@:"
    const e1 = try lowering.objc().objcTypeEncodingFromSignature(.void, &.{}, null);
    defer alloc.free(e1);
    try std.testing.expectEqualStrings("v@:", e1);

    // Returns i32, takes i32: -(int)add:(int)x  →  "i@:i"
    const e2 = try lowering.objc().objcTypeEncodingFromSignature(.i32, &.{.i32}, null);
    defer alloc.free(e2);
    try std.testing.expectEqualStrings("i@:i", e2);

    // i64 return, two i64 args: "q@:qq"
    const e3 = try lowering.objc().objcTypeEncodingFromSignature(.i64, &.{ .i64, .i64 }, null);
    defer alloc.free(e3);
    try std.testing.expectEqualStrings("q@:qq", e3);

    // BOOL return (i8): "c@:"
    const e4 = try lowering.objc().objcTypeEncodingFromSignature(.i8, &.{}, null);
    defer alloc.free(e4);
    try std.testing.expectEqualStrings("c@:", e4);

    // Float/double: "f@:d"
    const e5 = try lowering.objc().objcTypeEncodingFromSignature(.f32, &.{.f64}, null);
    defer alloc.free(e5);
    try std.testing.expectEqualStrings("f@:d", e5);

    // bool (i1) is `B` — distinct from BOOL (`c`).
    const e6 = try lowering.objc().objcTypeEncodingFromSignature(.bool, &.{.bool}, null);
    defer alloc.free(e6);
    try std.testing.expectEqualStrings("B@:B", e6);

    // usize / isize on the 64-bit target.
    const e7 = try lowering.objc().objcTypeEncodingFromSignature(.usize, &.{.isize}, null);
    defer alloc.free(e7);
    try std.testing.expectEqualStrings("Q@:q", e7);

    // Unsigned variants u8/u16/u32/u64.
    const e8 = try lowering.objc().objcTypeEncodingFromSignature(.u32, &.{ .u8, .u16, .u64 }, null);
    defer alloc.free(e8);
    try std.testing.expectEqualStrings("I@:CSQ", e8);
}

test "lower: objcTypeEncodingFromSignature emits pointer shapes" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // Generic `*void` → `^v`.
    const void_ptr = module.types.ptrTo(.void);
    const e1 = try lowering.objc().objcTypeEncodingFromSignature(void_ptr, &.{void_ptr}, null);
    defer alloc.free(e1);
    try std.testing.expectEqualStrings("^v@:^v", e1);

    // `[*]u8` C-string carrier → `*`.
    const u8_many = module.types.intern(.{ .many_pointer = .{ .element = .u8 } });
    const e2 = try lowering.objc().objcTypeEncodingFromSignature(.void, &.{u8_many}, null);
    defer alloc.free(e2);
    try std.testing.expectEqualStrings("v@:*", e2);

    // `[*]i32` (non-u8 many-pointer) → `^v`.
    const i32_many = module.types.intern(.{ .many_pointer = .{ .element = .i32 } });
    const e3 = try lowering.objc().objcTypeEncodingFromSignature(.void, &.{i32_many}, null);
    defer alloc.free(e3);
    try std.testing.expectEqualStrings("v@:^v", e3);
}

// M1.2 A.2 — sx-defined #objc_class state struct construction.
test "lower: objcDefinedStateStructType collects user-declared fields" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // Synthesize a #objc_class("SxFoo") { counter: i32; ticks: i64; } AST.
    const span = ast.Span{ .start = 0, .end = 0 };
    const counter_type = try alloc.create(Node);
    defer alloc.destroy(counter_type);
    counter_type.* = .{ .span = span, .data = .{ .type_expr = .{ .name = "i32", .is_generic = false } } };
    const ticks_type = try alloc.create(Node);
    defer alloc.destroy(ticks_type);
    ticks_type.* = .{ .span = span, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };

    const members = [_]ast.RuntimeClassMember{
        .{ .field = .{ .name = "counter", .field_type = counter_type } },
        .{ .field = .{ .name = "ticks", .field_type = ticks_type } },
    };
    const fcd = ast.RuntimeClassDecl{
        .name = "SxFoo",
        .runtime_path = "SxFoo",
        .runtime = .objc_class,
        .members = &members,
        .is_extern = false,
        .is_main = false,
    };

    const state_ty = lowering.objc().objcDefinedStateStructType(&fcd);
    const info = module.types.get(state_ty);
    try std.testing.expectEqual(@as(std.meta.Tag(@TypeOf(info)), .@"struct"), std.meta.activeTag(info));

    const s = info.@"struct";
    try std.testing.expectEqualStrings("__SxFooState", module.types.getString(s.name));
    try std.testing.expectEqual(@as(usize, 2), s.fields.len);
    try std.testing.expectEqualStrings("counter", module.types.getString(s.fields[0].name));
    try std.testing.expectEqual(TypeId.i32, s.fields[0].ty);
    try std.testing.expectEqualStrings("ticks", module.types.getString(s.fields[1].name));
    try std.testing.expectEqual(TypeId.i64, s.fields[1].ty);

    // Idempotency: a second call returns the same TypeId (cache hit on name).
    const state_ty2 = lowering.objc().objcDefinedStateStructType(&fcd);
    try std.testing.expectEqual(state_ty, state_ty2);
}

test "lower: objcDefinedStateStructType handles empty field set" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    const fcd = ast.RuntimeClassDecl{
        .name = "SxEmpty",
        .runtime_path = "SxEmpty",
        .runtime = .objc_class,
        .members = &.{},
        .is_extern = false,
        .is_main = false,
    };

    const state_ty = lowering.objc().objcDefinedStateStructType(&fcd);
    const info = module.types.get(state_ty);
    try std.testing.expectEqualStrings("__SxEmptyState", module.types.getString(info.@"struct".name));
    try std.testing.expectEqual(@as(usize, 0), info.@"struct".fields.len);
}

test "lower: objcDefinedStateStructType skips non-field members" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // Mix in #extends and method members — only `.field` contributes.
    const span = ast.Span{ .start = 0, .end = 0 };
    const counter_type = try alloc.create(Node);
    defer alloc.destroy(counter_type);
    counter_type.* = .{ .span = span, .data = .{ .type_expr = .{ .name = "i32", .is_generic = false } } };

    const members = [_]ast.RuntimeClassMember{
        .{ .extends = "NSObject" },
        .{ .field = .{ .name = "counter", .field_type = counter_type } },
        .{ .implements = "UIApplicationDelegate" },
    };
    const fcd = ast.RuntimeClassDecl{
        .name = "SxMixed",
        .runtime_path = "SxMixed",
        .runtime = .objc_class,
        .members = &members,
        .is_extern = false,
        .is_main = false,
    };

    const state_ty = lowering.objc().objcDefinedStateStructType(&fcd);
    const info = module.types.get(state_ty);
    try std.testing.expectEqual(@as(usize, 1), info.@"struct".fields.len);
    try std.testing.expectEqualStrings("counter", module.types.getString(info.@"struct".fields[0].name));
}

test "lower: objcTypeEncodingFromSignature emits @ for Obj-C class pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // Synthesize a runtime Obj-C class entry so the encoder recognises
    // `*NSString` as an object pointer.
    const ns_name = module.types.internString("NSString");
    const ns_struct = module.types.intern(.{ .@"struct" = .{ .name = ns_name, .fields = &.{} } });
    const ns_ptr = module.types.ptrTo(ns_struct);
    var ns_fcd = ast.RuntimeClassDecl{
        .name = "NSString",
        .runtime_path = "NSString",
        .runtime = .objc_class,
        .members = &.{},
        .is_extern = true,
        .is_main = false,
    };
    try lowering.program_index.runtime_class_map.put("NSString", &ns_fcd);

    // Return *NSString, no args: "@@:"
    const e1 = try lowering.objc().objcTypeEncodingFromSignature(ns_ptr, &.{}, null);
    defer alloc.free(e1);
    try std.testing.expectEqualStrings("@@:", e1);

    // Return *NSString, take *NSString: "@@:@"
    const e2 = try lowering.objc().objcTypeEncodingFromSignature(ns_ptr, &.{ns_ptr}, null);
    defer alloc.free(e2);
    try std.testing.expectEqualStrings("@@:@", e2);
}

test "lower: objcTypeEncodingFromSignature unwraps optional to wire type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // Runtime-class `*NSString` so the encoder recognises it as `@`.
    const ns_name = module.types.internString("NSString");
    const ns_struct = module.types.intern(.{ .@"struct" = .{ .name = ns_name, .fields = &.{} } });
    const ns_ptr = module.types.ptrTo(ns_struct);
    var ns_fcd = ast.RuntimeClassDecl{
        .name = "NSString",
        .runtime_path = "NSString",
        .runtime = .objc_class,
        .members = &.{},
        .is_extern = true,
        .is_main = false,
    };
    try lowering.program_index.runtime_class_map.put("NSString", &ns_fcd);

    // `?i64 -> ?*NSString` collapses to `q -> @` at the Obj-C boundary.
    const opt_i64 = module.types.optionalOf(.i64);
    const opt_ns = module.types.optionalOf(ns_ptr);
    const e1 = try lowering.objc().objcTypeEncodingFromSignature(opt_ns, &.{opt_i64}, null);
    defer alloc.free(e1);
    try std.testing.expectEqualStrings("@@:q", e1);

    // Nested optional unwrap (`??f64`) — same as `f64` at the wire.
    const opt_f64 = module.types.optionalOf(.f64);
    const opt_opt_f64 = module.types.optionalOf(opt_f64);
    const e2 = try lowering.objc().objcTypeEncodingFromSignature(.void, &.{opt_opt_f64}, null);
    defer alloc.free(e2);
    try std.testing.expectEqualStrings("v@:d", e2);
}

test "lower: objcTypeEncodingFromSignature emits structs as {Name=fields...}" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // CGPoint :: struct { x: f64; y: f64 } → {CGPoint=dd}
    const cgpoint_name = module.types.internString("CGPoint");
    const cgpoint_x_name = module.types.internString("x");
    const cgpoint_y_name = module.types.internString("y");
    const cgpoint_fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = cgpoint_x_name, .ty = .f64 },
        .{ .name = cgpoint_y_name, .ty = .f64 },
    };
    const cgpoint = module.types.intern(.{ .@"struct" = .{ .name = cgpoint_name, .fields = &cgpoint_fields } });

    // `-(void)setOrigin:(CGPoint)p` → `v@:{CGPoint=dd}`
    const e1 = try lowering.objc().objcTypeEncodingFromSignature(.void, &.{cgpoint}, null);
    defer alloc.free(e1);
    try std.testing.expectEqualStrings("v@:{CGPoint=dd}", e1);

    // `-(CGPoint)origin` → `{CGPoint=dd}@:`
    const e2 = try lowering.objc().objcTypeEncodingFromSignature(cgpoint, &.{}, null);
    defer alloc.free(e2);
    try std.testing.expectEqualStrings("{CGPoint=dd}@:", e2);

    // NSRange ({u64 location; u64 length}) → {_NSRange=QQ} (Apple uses
    // the underscore-prefixed internal name in practice, but we faithfully
    // emit whatever the struct is registered as).
    const nsrange_name = module.types.internString("_NSRange");
    const loc_name = module.types.internString("location");
    const len_name = module.types.internString("length");
    const nsrange_fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = loc_name, .ty = .u64 },
        .{ .name = len_name, .ty = .u64 },
    };
    const nsrange = module.types.intern(.{ .@"struct" = .{ .name = nsrange_name, .fields = &nsrange_fields } });
    const e3 = try lowering.objc().objcTypeEncodingFromSignature(nsrange, &.{ nsrange, .i64 }, null);
    defer alloc.free(e3);
    try std.testing.expectEqualStrings("{_NSRange=QQ}@:{_NSRange=QQ}q", e3);
}

test "lower: objcTypeEncodingFromSignature emits nested structs (CGRect)" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // CGPoint and CGSize, both {f64, f64}.
    const cgpoint_name = module.types.internString("CGPoint");
    const cgsize_name = module.types.internString("CGSize");
    const x_name = module.types.internString("x");
    const y_name = module.types.internString("y");
    const w_name = module.types.internString("width");
    const h_name = module.types.internString("height");

    const cgpoint_fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = x_name, .ty = .f64 },
        .{ .name = y_name, .ty = .f64 },
    };
    const cgsize_fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = w_name, .ty = .f64 },
        .{ .name = h_name, .ty = .f64 },
    };
    const cgpoint = module.types.intern(.{ .@"struct" = .{ .name = cgpoint_name, .fields = &cgpoint_fields } });
    const cgsize = module.types.intern(.{ .@"struct" = .{ .name = cgsize_name, .fields = &cgsize_fields } });

    // CGRect :: struct { origin: CGPoint; size: CGSize } →
    // {CGRect={CGPoint=dd}{CGSize=dd}}
    const cgrect_name = module.types.internString("CGRect");
    const origin_name = module.types.internString("origin");
    const size_name = module.types.internString("size");
    const cgrect_fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = origin_name, .ty = cgpoint },
        .{ .name = size_name, .ty = cgsize },
    };
    const cgrect = module.types.intern(.{ .@"struct" = .{ .name = cgrect_name, .fields = &cgrect_fields } });

    // `-(CGRect)frame` → `{CGRect={CGPoint=dd}{CGSize=dd}}@:`
    const e1 = try lowering.objc().objcTypeEncodingFromSignature(cgrect, &.{}, null);
    defer alloc.free(e1);
    try std.testing.expectEqualStrings("{CGRect={CGPoint=dd}{CGSize=dd}}@:", e1);

    // `-(void)setFrame:(CGRect)f` round-trip.
    const e2 = try lowering.objc().objcTypeEncodingFromSignature(.void, &.{cgrect}, null);
    defer alloc.free(e2);
    try std.testing.expectEqualStrings("v@:{CGRect={CGPoint=dd}{CGSize=dd}}", e2);
}

// ── A6.1 scaffolding: pure Obj-C decision helpers ───────────────────
// Lock selector derivation, property-kind classification, and Obj-C
// class-pointer recognition before they move to `ffi_objc.zig`.

fn objcMethod(name: []const u8) ast.RuntimeMethodDecl {
    return .{ .name = name, .params = &.{}, .param_names = &.{}, .return_type = null };
}

test "lower: deriveObjcSelector — niladic / keyword / multi-keyword / override" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // arity 0 → bare name, no colons, not an override.
    const niladic = lowering.objc().deriveObjcSelector(objcMethod("count"), 0);
    try std.testing.expectEqualStrings("count", niladic.sel);
    try std.testing.expectEqual(@as(usize, 0), niladic.keyword_count);
    try std.testing.expectEqual(false, niladic.is_override);

    // arity ≥ 1, no `_` → single trailing colon, one keyword.
    const single = lowering.objc().deriveObjcSelector(objcMethod("setValue"), 1);
    defer alloc.free(single.sel);
    try std.testing.expectEqualStrings("setValue:", single.sel);
    try std.testing.expectEqual(@as(usize, 1), single.keyword_count);
    try std.testing.expectEqual(false, single.is_override);

    // each `_` → `:`, plus a trailing `:`; piece count = (#`_`) + 1.
    const multi = lowering.objc().deriveObjcSelector(objcMethod("setValue_forKey"), 2);
    defer alloc.free(multi.sel);
    try std.testing.expectEqualStrings("setValue:forKey:", multi.sel);
    try std.testing.expectEqual(@as(usize, 2), multi.keyword_count);
    try std.testing.expectEqual(false, multi.is_override);

    // `#selector(...)` override: used verbatim, keyword_count = #colons.
    var m = objcMethod("init_with_frame_style");
    m.selector_override = "initWithFrame:style:";
    const overridden = lowering.objc().deriveObjcSelector(m, 2);
    try std.testing.expectEqualStrings("initWithFrame:style:", overridden.sel);
    try std.testing.expectEqual(@as(usize, 2), overridden.keyword_count);
    try std.testing.expectEqual(true, overridden.is_override);
}

test "lower: isObjcClassPointer recognises pointer-to-runtime-Obj-C-class" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // *NSString where NSString is a registered Obj-C class → true.
    const ns_name = module.types.internString("NSString");
    const ns_struct = module.types.intern(.{ .@"struct" = .{ .name = ns_name, .fields = &.{} } });
    const ns_ptr = module.types.ptrTo(ns_struct);
    var ns_fcd = ast.RuntimeClassDecl{
        .name = "NSString",
        .runtime_path = "NSString",
        .runtime = .objc_class,
        .members = &.{},
        .is_extern = true,
        .is_main = false,
    };
    try lowering.program_index.runtime_class_map.put("NSString", &ns_fcd);
    try std.testing.expect(lowering.objc().isObjcClassPointer(ns_ptr));

    // *NSCopying where NSCopying is a registered Obj-C *protocol* → also true
    // (the predicate accepts .objc_class OR .objc_protocol).
    const proto_name = module.types.internString("NSCopying");
    const proto_struct = module.types.intern(.{ .@"struct" = .{ .name = proto_name, .fields = &.{} } });
    const proto_ptr = module.types.ptrTo(proto_struct);
    var proto_fcd = ast.RuntimeClassDecl{
        .name = "NSCopying",
        .runtime_path = "NSCopying",
        .runtime = .objc_protocol,
        .members = &.{},
        .is_extern = true,
        .is_main = false,
    };
    try lowering.program_index.runtime_class_map.put("NSCopying", &proto_fcd);
    try std.testing.expect(lowering.objc().isObjcClassPointer(proto_ptr));

    // *Plain where Plain is a non-extern struct → false.
    const plain_name = module.types.internString("Plain");
    const plain_struct = module.types.intern(.{ .@"struct" = .{ .name = plain_name, .fields = &.{} } });
    try std.testing.expect(!lowering.objc().isObjcClassPointer(module.types.ptrTo(plain_struct)));

    // *void and a builtin scalar → false (not object pointers).
    try std.testing.expect(!lowering.objc().isObjcClassPointer(module.types.ptrTo(.void)));
    try std.testing.expect(!lowering.objc().isObjcClassPointer(.i32));
}

test "lower: objcPropertyKind defaults + explicit ARC modifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // Register NSString so `*NSString` resolves to an object pointer.
    const ns_name = module.types.internString("NSString");
    _ = module.types.intern(.{ .@"struct" = .{ .name = ns_name, .fields = &.{} } });
    var ns_fcd = ast.RuntimeClassDecl{
        .name = "NSString",
        .runtime_path = "NSString",
        .runtime = .objc_class,
        .members = &.{},
        .is_extern = true,
        .is_main = false,
    };
    try lowering.program_index.runtime_class_map.put("NSString", &ns_fcd);

    // Primitive field, no modifiers → assign (the non-object default).
    const prim = ast.RuntimeFieldDecl{ .name = "count", .field_type = typeKeyword(alloc, "i32"), .is_property = true };
    defer alloc.destroy(prim.field_type);
    try std.testing.expect(lowering.objc().objcPropertyKind(prim) == .assign);

    // Object-pointer field, no modifiers → strong (the object default).
    const obj_ty = typeKeyword(alloc, "*NSString");
    defer alloc.destroy(obj_ty);
    const obj_default = ast.RuntimeFieldDecl{ .name = "title", .field_type = obj_ty, .is_property = true };
    try std.testing.expect(lowering.objc().objcPropertyKind(obj_default) == .strong);

    // Protocol-pointer field → also strong by default (same object-pointer
    // predicate accepts .objc_protocol).
    const proto_name = module.types.internString("NSCoding");
    _ = module.types.intern(.{ .@"struct" = .{ .name = proto_name, .fields = &.{} } });
    var proto_fcd = ast.RuntimeClassDecl{
        .name = "NSCoding",
        .runtime_path = "NSCoding",
        .runtime = .objc_protocol,
        .members = &.{},
        .is_extern = true,
        .is_main = false,
    };
    try lowering.program_index.runtime_class_map.put("NSCoding", &proto_fcd);
    const proto_ty = typeKeyword(alloc, "*NSCoding");
    defer alloc.destroy(proto_ty);
    const proto_default = ast.RuntimeFieldDecl{ .name = "coder", .field_type = proto_ty, .is_property = true };
    try std.testing.expect(lowering.objc().objcPropertyKind(proto_default) == .strong);

    // Explicit modifiers on an object pointer win over the default.
    const weak_mods = [_][]const u8{"weak"};
    try std.testing.expect(lowering.objc().objcPropertyKind(.{ .name = "delegate", .field_type = obj_ty, .is_property = true, .property_modifiers = &weak_mods }) == .weak);

    const copy_mods = [_][]const u8{"copy"};
    try std.testing.expect(lowering.objc().objcPropertyKind(.{ .name = "name", .field_type = obj_ty, .is_property = true, .property_modifiers = &copy_mods }) == .copy);

    const assign_mods = [_][]const u8{"assign"};
    try std.testing.expect(lowering.objc().objcPropertyKind(.{ .name = "raw", .field_type = obj_ty, .is_property = true, .property_modifiers = &assign_mods }) == .assign);
}

// ── Pack projection name resolution (Feature 1, Step 2.2) ────────────

const errors = @import("../errors.zig");

fn typeKeyword(alloc: std.mem.Allocator, name: []const u8) *Node {
    const n = alloc.create(Node) catch unreachable;
    n.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = name, .is_generic = false } } };
    return n;
}

fn protoMethod(name: []const u8) ast.ProtocolMethodDecl {
    return .{ .name = name, .params = &.{}, .param_names = &.{}, .return_type = null, .default_body = null };
}

test "pack projection: type-arg vs method namespace lookups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // Wrap :: protocol(Target: Type) { wrap :: () -> Target; value :: () -> Target; }
    const type_kw = typeKeyword(alloc, "Type");
    defer alloc.destroy(type_kw);
    const type_params = [_]ast.StructTypeParam{.{ .name = "Target", .constraint = type_kw }};
    const methods = [_]ast.ProtocolMethodDecl{ protoMethod("wrap"), protoMethod("value") };
    const pd = ast.ProtocolDecl{ .name = "Wrap", .methods = &methods, .type_params = &type_params };
    lowering.registerProtocolDecl(&pd);

    // type-arg namespace
    try std.testing.expectEqual(@as(?u32, 0), lowering.lookupProtocolArg("Wrap", "Target"));
    try std.testing.expectEqual(@as(?u32, null), lowering.lookupProtocolArg("Wrap", "wrap"));
    try std.testing.expectEqual(@as(?u32, null), lowering.lookupProtocolArg("Nope", "Target"));

    // method (runtime-accessor) namespace
    try std.testing.expectEqual(@as(?u32, 0), lowering.lookupProtocolField("Wrap", "wrap"));
    try std.testing.expectEqual(@as(?u32, 1), lowering.lookupProtocolField("Wrap", "value"));
    try std.testing.expectEqual(@as(?u32, null), lowering.lookupProtocolField("Wrap", "Target"));
}

test "pack projection: position-driven resolution (Decision 4)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    const type_kw = typeKeyword(alloc, "Type");
    defer alloc.destroy(type_kw);
    const type_params = [_]ast.StructTypeParam{.{ .name = "Target", .constraint = type_kw }};
    const methods = [_]ast.ProtocolMethodDecl{protoMethod("wrap")};
    const pd = ast.ProtocolDecl{ .name = "Wrap", .methods = &methods, .type_params = &type_params };
    lowering.registerProtocolDecl(&pd);

    // type position consults type-args only
    try std.testing.expectEqual(Lowering.PackProjection{ .type_arg = 0 }, lowering.resolvePackProjection("Wrap", "Target", .type_position));
    try std.testing.expectEqual(Lowering.PackProjection.not_found, lowering.resolvePackProjection("Wrap", "wrap", .type_position));

    // value position consults methods only — no cross-namespace fallback
    try std.testing.expectEqual(Lowering.PackProjection{ .method = 0 }, lowering.resolvePackProjection("Wrap", "wrap", .value_position));
    try std.testing.expectEqual(Lowering.PackProjection.not_found, lowering.resolvePackProjection("Wrap", "Target", .value_position));
}

test "pack projection: same-name type-arg + method warns (Decision 4)" {
    // Arena: DiagnosticList.addFmt allocates messages it never frees in deinit
    // (mixed ownership with borrowed literals) — an arena keeps the leak
    // checker clean without changing diagnostic semantics.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;

    // A protocol whose type-arg and method share the name `value`.
    const type_kw = typeKeyword(alloc, "Type");
    defer alloc.destroy(type_kw);
    const type_params = [_]ast.StructTypeParam{.{ .name = "value", .constraint = type_kw }};
    const methods = [_]ast.ProtocolMethodDecl{protoMethod("value")};
    const pd = ast.ProtocolDecl{ .name = "Shadowy", .methods = &methods, .type_params = &type_params };
    lowering.registerProtocolDecl(&pd);

    var warned = false;
    for (diags.items.items) |d| {
        if (d.level == .warn and std.mem.indexOf(u8, d.message, "type-arg and method both named 'value'") != null) warned = true;
    }
    try std.testing.expect(warned);

    // Position still resolves deterministically despite the shadow.
    try std.testing.expectEqual(Lowering.PackProjection{ .type_arg = 0 }, lowering.resolvePackProjection("Shadowy", "value", .type_position));
    try std.testing.expectEqual(Lowering.PackProjection{ .method = 0 }, lowering.resolvePackProjection("Shadowy", "value", .value_position));
}

test "E1.4b converge inferred error sets: empty -> warning, raising -> converged set" {
    // The empty-inferred warning isn't user-visible yet (the compile driver
    // only renders diagnostics on failure — a LANG follow-up), so validate the
    // SCC's emission + set computation directly on the DiagnosticList.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;

    // stub :: () -> ! { return; }   — bare `!`, never raises.
    const stub_rt = alloc.create(Node) catch unreachable;
    stub_rt.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .error_type_expr = .{ .name = null } } };
    const stub_ret = alloc.create(Node) catch unreachable;
    stub_ret.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .return_stmt = .{ .value = null } } };
    const stub_body = alloc.create(Node) catch unreachable;
    const stub_stmts: []const *Node = &.{stub_ret};
    stub_body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = stub_stmts } } };
    const stub_fd = ast.FnDecl{ .name = "stub", .params = &.{}, .return_type = stub_rt, .body = stub_body };

    // raiser :: () -> ! { raise error.Foo; }   — bare `!`, raises Foo.
    const r_rt = alloc.create(Node) catch unreachable;
    r_rt.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .error_type_expr = .{ .name = null } } };
    const r_err = alloc.create(Node) catch unreachable;
    r_err.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = "error" } } };
    const r_fa = alloc.create(Node) catch unreachable;
    r_fa.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .field_access = .{ .object = r_err, .field = "Foo" } } };
    const r_raise = alloc.create(Node) catch unreachable;
    r_raise.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .raise_stmt = .{ .tag = r_fa } } };
    const r_body = alloc.create(Node) catch unreachable;
    const r_stmts: []const *Node = &.{r_raise};
    r_body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = r_stmts } } };
    const raiser_fd = ast.FnDecl{ .name = "raiser", .params = &.{}, .return_type = r_rt, .body = r_body };

    lowering.program_index.fn_ast_map.put("stub", &stub_fd) catch unreachable;
    lowering.program_index.fn_ast_map.put("raiser", &raiser_fd) catch unreachable;

    lowering.convergeInferredErrorSets();

    // raiser converges to {Foo} (non-empty); stub to ∅.
    try std.testing.expectEqual(@as(usize, 1), (lowering.inferred_error_sets.get("raiser") orelse unreachable).len);
    try std.testing.expectEqual(@as(usize, 0), (lowering.inferred_error_sets.get("stub") orelse unreachable).len);

    // The empty-set (stub) warns; the raising one does not.
    var stub_warned = false;
    var raiser_warned = false;
    for (diags.items.items) |d| {
        if (d.level != .warn) continue;
        if (std.mem.indexOf(u8, d.message, "stub") != null) stub_warned = true;
        if (std.mem.indexOf(u8, d.message, "raiser") != null) raiser_warned = true;
    }
    try std.testing.expect(stub_warned);
    try std.testing.expect(!raiser_warned);
}

test "E1.4c noreturn typing: divergence shapes + if-else unification + block propagation" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    const mk = struct {
        fn node(a: std.mem.Allocator, data: ast.Node.Data) *Node {
            const n = a.create(Node) catch unreachable;
            n.* = .{ .span = .{ .start = 0, .end = 0 }, .data = data };
            return n;
        }
    };

    // return; / break; / continue; / raise error.X  → noreturn
    const ret = mk.node(alloc, .{ .return_stmt = .{ .value = null } });
    defer alloc.destroy(ret);
    const brk = mk.node(alloc, .{ .break_expr = {} });
    defer alloc.destroy(brk);
    const cont = mk.node(alloc, .{ .continue_expr = {} });
    defer alloc.destroy(cont);
    const err_id = mk.node(alloc, .{ .identifier = .{ .name = "error" } });
    defer alloc.destroy(err_id);
    const fa = mk.node(alloc, .{ .field_access = .{ .object = err_id, .field = "X" } });
    defer alloc.destroy(fa);
    const raise = mk.node(alloc, .{ .raise_stmt = .{ .tag = fa } });
    defer alloc.destroy(raise);

    try std.testing.expectEqual(TypeId.noreturn, lowering.inferExprType(ret));
    try std.testing.expectEqual(TypeId.noreturn, lowering.inferExprType(brk));
    try std.testing.expectEqual(TypeId.noreturn, lowering.inferExprType(cont));
    try std.testing.expectEqual(TypeId.noreturn, lowering.inferExprType(raise));

    // Block whose last statement diverges → noreturn.
    const five = mk.node(alloc, .{ .int_literal = .{ .value = 5 } });
    defer alloc.destroy(five);
    const blk_stmts: []const *Node = &.{ five, ret };
    const blk = mk.node(alloc, .{ .block = .{ .stmts = blk_stmts, .produces_value = true } });
    defer alloc.destroy(blk);
    try std.testing.expectEqual(TypeId.noreturn, lowering.inferExprType(blk));

    // if-else with one diverging branch unifies to the other branch's type;
    // both diverging → noreturn.
    const lit = mk.node(alloc, .{ .int_literal = .{ .value = 1 } });
    defer alloc.destroy(lit);
    const then_div = mk.node(alloc, .{ .if_expr = .{ .condition = lit, .then_branch = ret, .else_branch = lit, .is_inline = false } });
    defer alloc.destroy(then_div);
    try std.testing.expectEqual(TypeId.i64, lowering.inferExprType(then_div)); // then diverges → else (i64)

    const else_div = mk.node(alloc, .{ .if_expr = .{ .condition = lit, .then_branch = lit, .else_branch = ret, .is_inline = false } });
    defer alloc.destroy(else_div);
    try std.testing.expectEqual(TypeId.i64, lowering.inferExprType(else_div)); // then is i64

    const both_div = mk.node(alloc, .{ .if_expr = .{ .condition = lit, .then_branch = ret, .else_branch = brk, .is_inline = false } });
    defer alloc.destroy(both_div);
    try std.testing.expectEqual(TypeId.noreturn, lowering.inferExprType(both_div));
}

// ── A4.2 test-first scaffolding: protocol-decl registration ──────────
// Lock `registerProtocolDecl`'s method-table output (consumed by protocol
// dispatch + impl planning) before the protocol/impl lookup moves to
// `src/ir/protocols.zig`. Public surface only (registerProtocolDecl +
// getProtocolInfo are pub) — the impl-lookup / conversion plan tests land
// with the registry in sub-step 2 (as A4.1's internal tests landed with
// GenericResolver). Arena: a non-parameterized protocol dupes its method
// infos via the module allocator and never frees them.

test "protocols: registerProtocolDecl builds the dispatch method table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    // Shape :: protocol { area :: () -> f64; scaled :: (factor: f64) -> Self; }
    const methods = [_]ast.ProtocolMethodDecl{
        .{ .name = "area", .params = &.{}, .param_names = &.{}, .return_type = typeKeyword(alloc, "f64"), .default_body = null },
        .{
            .name = "scaled",
            .params = &[_]*Node{typeKeyword(alloc, "f64")},
            .param_names = &[_][]const u8{"factor"},
            .return_type = typeKeyword(alloc, "Self"),
            .default_body = null,
        },
    };
    const pd = ast.ProtocolDecl{ .name = "Shape", .methods = &methods };
    lowering.registerProtocolDecl(&pd);

    // getProtocolInfo resolves the registered protocol struct by type.
    const shape_ty = module.types.findByName(module.types.internString("Shape")).?;
    const info = lowering.getProtocolInfo(shape_ty).?;
    try std.testing.expectEqual(@as(usize, 2), info.methods.len);

    // area :: () -> f64 — no params (self excluded), concrete f64 return,
    // dispatchable (no `Self` past the receiver).
    try std.testing.expectEqualStrings("area", info.methods[0].name);
    try std.testing.expectEqual(@as(usize, 0), info.methods[0].param_types.len);
    try std.testing.expectEqual(TypeId.f64, info.methods[0].ret_type);
    try std.testing.expect(info.methods[0].dispatchable);
    try std.testing.expect(info.methods[0].self_param == null);

    // scaled :: (factor: f64) -> Self — one f64 param; the `Self` return is
    // encoded as `*void` and excludes the method from erased dispatch
    // (Era-2: no expressible type with Self unknown; return position →
    // self_param stays null).
    try std.testing.expectEqualStrings("scaled", info.methods[1].name);
    try std.testing.expectEqual(@as(usize, 1), info.methods[1].param_types.len);
    try std.testing.expectEqual(TypeId.f64, info.methods[1].param_types[0]);
    try std.testing.expect(!info.methods[1].dispatchable);
    try std.testing.expect(info.methods[1].self_param == null);
    try std.testing.expectEqual(module.types.ptrTo(.void), info.methods[1].ret_type);
}

// ── A4.3 test-first scaffolding: coercion planning ───────────────────
// Lock the one coercion-plan decision reachable via the existing public
// surface — the optional wrap/flatten rule — before coercion planning moves to
// `src/ir/conversions.zig`. The lowerXX / coerceToType / coerceOrErase /
// buildProtocolErasure decisions are private + emission-bound, so their
// CoercionPlan unit tests land with the extracted module in sub-step 2 (as the
// generics/protocols plan tests landed with their modules); behavior is locked
// here by the new `.ir` snapshots.

test "conversions: optionalOfFlattened wraps once, flattening a nested optional" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);

    const opt_i64 = module.types.optionalOf(.i64);
    // Wrap a non-optional: T -> ?T.
    try std.testing.expectEqual(opt_i64, l.optionalOfFlattened(.i64));
    // Wrap an already-optional FLATTENS: ?T -> ?T (the coercion never builds ??T).
    try std.testing.expectEqual(opt_i64, l.optionalOfFlattened(opt_i64));
    // Contrast: the plain wrap does NOT flatten — ?T -> ??T (distinct type).
    try std.testing.expect(module.types.optionalOf(opt_i64) != opt_i64);
}

test "lower: vectorLaneIndex maps swizzle components, colour aliases, rejects non-lanes" {
    // Positional swizzle components → lanes 0..3.
    try std.testing.expectEqual(@as(?u32, 0), Lowering.vectorLaneIndex("x"));
    try std.testing.expectEqual(@as(?u32, 1), Lowering.vectorLaneIndex("y"));
    try std.testing.expectEqual(@as(?u32, 2), Lowering.vectorLaneIndex("z"));
    try std.testing.expectEqual(@as(?u32, 3), Lowering.vectorLaneIndex("w"));
    // Colour aliases share the same lane indices.
    try std.testing.expectEqual(@as(?u32, 0), Lowering.vectorLaneIndex("r"));
    try std.testing.expectEqual(@as(?u32, 1), Lowering.vectorLaneIndex("g"));
    try std.testing.expectEqual(@as(?u32, 2), Lowering.vectorLaneIndex("b"));
    try std.testing.expectEqual(@as(?u32, 3), Lowering.vectorLaneIndex("a"));
    // Any non-lane field is rejected (null) so the read and write paths share
    // one rule — a non-lane store no longer falls through to an .unresolved
    // pointee that panics at LLVM emission.
    try std.testing.expectEqual(@as(?u32, null), Lowering.vectorLaneIndex("q"));
    try std.testing.expectEqual(@as(?u32, null), Lowering.vectorLaneIndex("xy"));
    try std.testing.expectEqual(@as(?u32, null), Lowering.vectorLaneIndex("len"));
    try std.testing.expectEqual(@as(?u32, null), Lowering.vectorLaneIndex(""));
}

test "lower: assigning to a missing struct field emits field-not-found, no panic (issue 0094)" {
    // Arena keeps the leak checker quiet — DiagnosticList.addFmt allocates
    // messages it never frees in deinit (mixed ownership with borrowed literals).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    // Register `Point :: struct { x: i64; }` so the struct literal resolves.
    const fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = module.types.internString("x"), .ty = .i64 },
    };
    _ = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("Point"), .fields = &fields } });

    const span = ast.Span{ .start = 0, .end = 0 };

    // main :: () { p := Point.{ x = 1 }; p.q = 2; }  — `q` is not a field of Point.
    var x_val = Node{ .span = span, .data = .{ .int_literal = .{ .value = 1 } } };
    const field_inits = [_]ast.StructFieldInit{.{ .name = "x", .value = &x_val }};
    var lit = Node{ .span = span, .data = .{ .struct_literal = .{ .struct_name = "Point", .field_inits = &field_inits } } };
    var decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "p", .name_span = span, .type_annotation = null, .value = &lit } } };

    var p_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "p" } } };
    var target = Node{ .span = span, .data = .{ .field_access = .{ .object = &p_ident, .field = "q" } } };
    var rhs = Node{ .span = span, .data = .{ .int_literal = .{ .value = 2 } } };
    var assign = Node{ .span = span, .data = .{ .assignment = .{ .target = &target, .op = .assign, .value = &rhs } } };

    const stmts = [_]*Node{ &decl, &assign };
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const fd = ast.FnDecl{ .name = "main", .params = &.{}, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    // Pre-fix this stored through a pointer-to-`.unresolved` that panicked at LLVM
    // emission; the fix bails with the read path's field-not-found diagnostic.
    lowering.lowerFunction(&fd, "main", false);

    var found = false;
    for (diags.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, "field 'q' not found on type 'Point'") != null) found = true;
    }
    try std.testing.expect(found);
}

test "lower: deref-assign struct literal typed from pointee, not fn return type (issue 0215)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    // Register `T :: struct { x: i64; }` so the pointee resolves.
    const fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = module.types.internString("x"), .ty = .i64 },
    };
    _ = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("T"), .fields = &fields } });

    const span = ast.Span{ .start = 0, .end = 0 };

    // mk :: (p: *T) -> i64 { p.* = .{ x = 5 }; return 7; }
    var t_type = Node{ .span = span, .data = .{ .type_expr = .{ .name = "T", .is_generic = false } } };
    var ptr_t = Node{ .span = span, .data = .{ .pointer_type_expr = .{ .pointee_type = &t_type } } };
    var ret_type = Node{ .span = span, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };

    var p_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "p" } } };
    var target = Node{ .span = span, .data = .{ .deref_expr = .{ .operand = &p_ident } } };
    var five = Node{ .span = span, .data = .{ .int_literal = .{ .value = 5 } } };
    const field_inits = [_]ast.StructFieldInit{.{ .name = "x", .value = &five }};
    var lit = Node{ .span = span, .data = .{ .struct_literal = .{ .struct_name = null, .field_inits = &field_inits } } };
    var assign = Node{ .span = span, .data = .{ .assignment = .{ .target = &target, .op = .assign, .value = &lit } } };

    var seven = Node{ .span = span, .data = .{ .int_literal = .{ .value = 7 } } };
    var ret_stmt = Node{ .span = span, .data = .{ .return_stmt = .{ .value = &seven } } };

    const stmts = [_]*Node{ &assign, &ret_stmt };
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const params: []const ast.Param = &.{.{ .name = "p", .name_span = span, .type_expr = &ptr_t }};
    const fd = ast.FnDecl{ .name = "mk", .params = params, .return_type = &ret_type, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    // Pre-fix the deref-LHS assign arm did not seed target_type, so the
    // anonymous literal was typed from the AMBIENT target_type — the fn's
    // return type (i64) — and the store diagnosed "cannot assign 'target'
    // of type 'T' with a value of type 'i64'" (issue 0215). Post-fix the
    // literal takes the pointee type T and lowering is diagnostic-free.
    lowering.lowerFunction(&fd, "mk", false);

    for (diags.items.items) |d| {
        if (d.level == .err) {
            std.debug.print("unexpected error diagnostic: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        }
    }
}

test "lower: assignment to an undeclared identifier is diagnosed, '_' discard stays silent (issue 0216)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    const span = ast.Span{ .start = 0, .end = 0 };

    // main :: () { totl = 42; cnt += 1; _ = 3; }
    // `totl` / `cnt` exist nowhere — pre-fix the RHS lowered and the store
    // was silently DISCARDED (no local slot, failed global lookup had no
    // else branch). Post-fix each emits an "unresolved ... in assignment"
    // error; the `_ = expr` discard idiom stays diagnostic-free.
    var totl_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "totl" } } };
    var forty_two = Node{ .span = span, .data = .{ .int_literal = .{ .value = 42 } } };
    var assign_plain = Node{ .span = span, .data = .{ .assignment = .{ .target = &totl_ident, .op = .assign, .value = &forty_two } } };

    var cnt_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "cnt" } } };
    var one = Node{ .span = span, .data = .{ .int_literal = .{ .value = 1 } } };
    var assign_compound = Node{ .span = span, .data = .{ .assignment = .{ .target = &cnt_ident, .op = .add_assign, .value = &one } } };

    var underscore = Node{ .span = span, .data = .{ .identifier = .{ .name = "_" } } };
    var three = Node{ .span = span, .data = .{ .int_literal = .{ .value = 3 } } };
    var assign_discard = Node{ .span = span, .data = .{ .assignment = .{ .target = &underscore, .op = .assign, .value = &three } } };

    const stmts = [_]*Node{ &assign_plain, &assign_compound, &assign_discard };
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const fd = ast.FnDecl{ .name = "main", .params = &.{}, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    lowering.lowerFunction(&fd, "main", false);

    var found_plain = false;
    var found_compound = false;
    for (diags.items.items) |d| {
        if (d.level != .err) continue;
        if (std.mem.indexOf(u8, d.message, "unresolved 'totl' in assignment") != null) found_plain = true;
        if (std.mem.indexOf(u8, d.message, "unresolved 'cnt' in assignment") != null) found_compound = true;
        // `_ = 3;` must NOT be reported — it is the discard idiom.
        try std.testing.expect(std.mem.indexOf(u8, d.message, "'_'") == null);
    }
    try std.testing.expect(found_plain);
    try std.testing.expect(found_compound);
}

test "lower: multi-assign to an undeclared identifier is diagnosed, '_' discard stays silent (issue 0218)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    const span = ast.Span{ .start = 0, .end = 0 };

    // main :: () { totl, _ = 42, 3; }
    // `totl` exists nowhere — pre-fix the ident-target arm of
    // lowerMultiAssign only consulted local scope and silently DROPPED the
    // store on lookup failure (no global fallback, no diagnostic; the
    // multi-assign sibling of issue 0216). Post-fix it emits an
    // "unresolved ... in assignment" error; the `_` discard leg stays
    // diagnostic-free.
    var totl_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "totl" } } };
    var underscore = Node{ .span = span, .data = .{ .identifier = .{ .name = "_" } } };
    var forty_two = Node{ .span = span, .data = .{ .int_literal = .{ .value = 42 } } };
    var three = Node{ .span = span, .data = .{ .int_literal = .{ .value = 3 } } };
    const targets = [_]*Node{ &totl_ident, &underscore };
    const values = [_]*Node{ &forty_two, &three };
    var multi = Node{ .span = span, .data = .{ .multi_assign = .{ .targets = &targets, .values = &values } } };

    const stmts = [_]*Node{&multi};
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const fd = ast.FnDecl{ .name = "main", .params = &.{}, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    lowering.lowerFunction(&fd, "main", false);

    var found_unresolved = false;
    for (diags.items.items) |d| {
        if (d.level != .err) continue;
        if (std.mem.indexOf(u8, d.message, "unresolved 'totl' in assignment") != null) found_unresolved = true;
        // The `_` leg must NOT be reported — it is the discard idiom.
        try std.testing.expect(std.mem.indexOf(u8, d.message, "'_'") == null);
    }
    try std.testing.expect(found_unresolved);
}

test "lower: multi-assign un-narrows its ident targets, unrelated names stay narrowed (issue 0228)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    const span = ast.Span{ .start = 0, .end = 0 };

    // main :: () {
    //     o : ?i64 = 5;  q : ?i64 = 6;  a := 0;
    //     if o != null and q != null {
    //         o, a = null, 1;    // multi-assign: must un-narrow 'o' only
    //         x := o + 1;        // stale-narrowed use → MUST diagnose
    //         y := q + 1;        // 'q' untouched, still narrowed → NO diagnostic
    //     }
    // }
    // Pre-fix lowerMultiAssign never touched `self.narrowed` (single-assign
    // removes the target name at its top), so `o + 1` compiled and read a
    // now-null optional as its payload. Post-fix the IDENT targets are
    // dropped from the narrowed set before any RHS lowers — 'o' diagnoses,
    // the unrelated 'q' keeps its narrowing.
    var i64_ty_o = Node{ .span = span, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    var opt_ty_o = Node{ .span = span, .data = .{ .optional_type_expr = .{ .inner_type = &i64_ty_o } } };
    var five = Node{ .span = span, .data = .{ .int_literal = .{ .value = 5 } } };
    var o_decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "o", .name_span = span, .type_annotation = &opt_ty_o, .value = &five } } };

    var i64_ty_q = Node{ .span = span, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    var opt_ty_q = Node{ .span = span, .data = .{ .optional_type_expr = .{ .inner_type = &i64_ty_q } } };
    var six = Node{ .span = span, .data = .{ .int_literal = .{ .value = 6 } } };
    var q_decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "q", .name_span = span, .type_annotation = &opt_ty_q, .value = &six } } };

    var zero = Node{ .span = span, .data = .{ .int_literal = .{ .value = 0 } } };
    var a_decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "a", .name_span = span, .type_annotation = null, .value = &zero } } };

    // condition: o != null and q != null
    var o_cond = Node{ .span = span, .data = .{ .identifier = .{ .name = "o" } } };
    var null_a = Node{ .span = span, .data = .null_literal };
    var o_neq = Node{ .span = span, .data = .{ .binary_op = .{ .op = .neq, .lhs = &o_cond, .rhs = &null_a } } };
    var q_cond = Node{ .span = span, .data = .{ .identifier = .{ .name = "q" } } };
    var null_b = Node{ .span = span, .data = .null_literal };
    var q_neq = Node{ .span = span, .data = .{ .binary_op = .{ .op = .neq, .lhs = &q_cond, .rhs = &null_b } } };
    var cond = Node{ .span = span, .data = .{ .binary_op = .{ .op = .and_op, .lhs = &o_neq, .rhs = &q_neq } } };

    // o, a = null, 1;
    var o_tgt = Node{ .span = span, .data = .{ .identifier = .{ .name = "o" } } };
    var a_tgt = Node{ .span = span, .data = .{ .identifier = .{ .name = "a" } } };
    var null_v = Node{ .span = span, .data = .null_literal };
    var one = Node{ .span = span, .data = .{ .int_literal = .{ .value = 1 } } };
    const targets = [_]*Node{ &o_tgt, &a_tgt };
    const values = [_]*Node{ &null_v, &one };
    var multi = Node{ .span = span, .data = .{ .multi_assign = .{ .targets = &targets, .values = &values } } };

    // x := o + 1;  (stale-narrowed use — the o-span is what must diagnose)
    var o_use = Node{ .span = .{ .start = 1, .end = 2 }, .data = .{ .identifier = .{ .name = "o" } } };
    var one_x = Node{ .span = span, .data = .{ .int_literal = .{ .value = 1 } } };
    var o_add = Node{ .span = span, .data = .{ .binary_op = .{ .op = .add, .lhs = &o_use, .rhs = &one_x } } };
    var x_decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "x", .name_span = span, .type_annotation = null, .value = &o_add } } };

    // y := q + 1;  (still narrowed — must stay diagnostic-free)
    var q_use = Node{ .span = span, .data = .{ .identifier = .{ .name = "q" } } };
    var one_y = Node{ .span = span, .data = .{ .int_literal = .{ .value = 1 } } };
    var q_add = Node{ .span = span, .data = .{ .binary_op = .{ .op = .add, .lhs = &q_use, .rhs = &one_y } } };
    var y_decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "y", .name_span = span, .type_annotation = null, .value = &q_add } } };

    const then_stmts = [_]*Node{ &multi, &x_decl, &y_decl };
    var then_block = Node{ .span = span, .data = .{ .block = .{ .stmts = &then_stmts } } };
    var if_node = Node{ .span = span, .data = .{ .if_expr = .{ .condition = &cond, .then_branch = &then_block, .else_branch = null, .is_inline = false } } };

    const stmts = [_]*Node{ &o_decl, &q_decl, &a_decl, &if_node };
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const fd = ast.FnDecl{ .name = "main", .params = &.{}, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    lowering.lowerFunction(&fd, "main", false);

    // Exactly ONE optional-operand error, at the stale 'o' use (span 1..2).
    var err_count: usize = 0;
    for (diags.items.items) |d| {
        if (d.level != .err) continue;
        err_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, d.message, "does not implicitly unwrap") != null);
        try std.testing.expectEqual(@as(u32, 1), (d.span orelse return error.TestUnexpectedResult).start);
    }
    try std.testing.expectEqual(@as(usize, 1), err_count);
}

test "lower: multi-assign to a GLOBAL array index stores in place via global_addr, not a value copy (issue 0249)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    const span = ast.Span{ .start = 0, .end = 0 };

    // Register a mutable module global `g : [3]i64`. With no source file set,
    // `selectGlobalAuthor` returns `.untracked` and `resolveGlobalRef` serves
    // this registration directly.
    const arr_ty = module.types.intern(.{ .array = .{ .element = .i64, .length = 3 } });
    const gid = module.addGlobal(.{ .name = module.types.internString("g"), .ty = arr_ty });

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    lowering.program_index.global_names.put("g", .{ .id = gid, .ty = arr_ty }) catch unreachable;

    // main :: () { a := 0; g[1], a = 77, 4; }
    // Pre-fix lowerMultiAssign's index arm addressed the global base with
    // `lowerExpr` (a `global_get` load of the WHOLE array into a register); the
    // GEP+store hit that throwaway copy and the write was silently dropped.
    // Post-fix the `is_array` branch takes `lowerExprAsPtr` → a `global_addr`,
    // so the GEP+store target the global's storage in place.
    var zero = Node{ .span = span, .data = .{ .int_literal = .{ .value = 0 } } };
    var a_decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "a", .name_span = span, .type_annotation = null, .value = &zero } } };

    var g_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "g" } } };
    var one_idx = Node{ .span = span, .data = .{ .int_literal = .{ .value = 1 } } };
    var g_index = Node{ .span = span, .data = .{ .index_expr = .{ .object = &g_ident, .index = &one_idx } } };
    var a_tgt = Node{ .span = span, .data = .{ .identifier = .{ .name = "a" } } };
    var seventy_seven = Node{ .span = span, .data = .{ .int_literal = .{ .value = 77 } } };
    var four = Node{ .span = span, .data = .{ .int_literal = .{ .value = 4 } } };
    const targets = [_]*Node{ &g_index, &a_tgt };
    const values = [_]*Node{ &seventy_seven, &four };
    var multi = Node{ .span = span, .data = .{ .multi_assign = .{ .targets = &targets, .values = &values } } };

    const stmts = [_]*Node{ &a_decl, &multi };
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const fd = ast.FnDecl{ .name = "main", .params = &.{}, .return_type = null, .body = &body };

    lowering.lowerFunction(&fd, "main", false);
    try std.testing.expect(!diags.hasErrors());

    // The array base must be addressed in place (`global_addr`), feeding an
    // `index_gep` whose result is `store`d — and the array must NOT be loaded
    // by value (`global_get` of `g`) for the store target.
    const main_fn = &module.functions.items[@intFromEnum(lowering.resolveFuncByName("main").?)];
    var saw_global_addr = false;
    var saw_index_gep = false;
    var saw_store = false;
    var saw_array_global_get = false;
    for (main_fn.blocks.items) |blk| {
        for (blk.insts.items) |ins| {
            switch (ins.op) {
                .global_addr => |g| if (g == gid) {
                    saw_global_addr = true;
                },
                .global_get => |g| if (g == gid) {
                    saw_array_global_get = true;
                },
                .index_gep => saw_index_gep = true,
                .store => saw_store = true,
                else => {},
            }
        }
    }
    try std.testing.expect(saw_global_addr);
    try std.testing.expect(saw_index_gep);
    try std.testing.expect(saw_store);
    // A `global_get` of the array itself would mean the store hit a value copy.
    try std.testing.expect(!saw_array_global_get);
}

test "lower: multi-assign to a missing struct field emits field-not-found, no corruption (issue 0094)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    // Register `Point :: struct { x: i64; }` so the struct literal resolves.
    const fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = module.types.internString("x"), .ty = .i64 },
    };
    _ = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("Point"), .fields = &fields } });

    const span = ast.Span{ .start = 0, .end = 0 };

    // main :: () { p := Point.{ x = 1 }; y := 0; p.r, y = 3, 4; }  — `r` is not a field of Point.
    var x_val = Node{ .span = span, .data = .{ .int_literal = .{ .value = 1 } } };
    const field_inits = [_]ast.StructFieldInit{.{ .name = "x", .value = &x_val }};
    var lit = Node{ .span = span, .data = .{ .struct_literal = .{ .struct_name = "Point", .field_inits = &field_inits } } };
    var decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "p", .name_span = span, .type_annotation = null, .value = &lit } } };

    var y_init = Node{ .span = span, .data = .{ .int_literal = .{ .value = 0 } } };
    var y_decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "y", .name_span = span, .type_annotation = null, .value = &y_init } } };

    var p_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "p" } } };
    var target0 = Node{ .span = span, .data = .{ .field_access = .{ .object = &p_ident, .field = "r" } } };
    var target1 = Node{ .span = span, .data = .{ .identifier = .{ .name = "y" } } };
    var v0 = Node{ .span = span, .data = .{ .int_literal = .{ .value = 3 } } };
    var v1 = Node{ .span = span, .data = .{ .int_literal = .{ .value = 4 } } };
    const targets = [_]*Node{ &target0, &target1 };
    const values = [_]*Node{ &v0, &v1 };
    var massign = Node{ .span = span, .data = .{ .multi_assign = .{ .targets = &targets, .values = &values } } };

    const stmts = [_]*Node{ &decl, &y_decl, &massign };
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const fd = ast.FnDecl{ .name = "main", .params = &.{}, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    // Pre-fix the struct-only loop defaulted field_idx 0 / field_ty .unresolved on
    // a miss, silently storing into field 0 (no diagnostic); the fix resolves the
    // target via the shared fieldLvaluePtr and bails with field-not-found.
    lowering.lowerFunction(&fd, "main", false);

    var found = false;
    for (diags.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, "field 'r' not found on type 'Point'") != null) found = true;
    }
    try std.testing.expect(found);
}

test "lower: shared resolver types a pointer-typed field GEP as *field_ty, not field_ty (issue 0094 clobber)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();

    const span = ast.Span{ .start = 0, .end = 0 };

    // Register `S :: struct { p: *i64; }` — the field's own type is a pointer.
    const ptr_i64 = module.types.ptrTo(.i64);
    const fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = module.types.internString("p"), .ty = ptr_i64 },
    };
    _ = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("S"), .fields = &fields } });

    // mutate :: (s: *S, q: *i64) { d := 0; s.p, d = q, 1; }
    // The multi-assign target routes `s.p` through the shared fieldLvaluePtr
    // resolver. Pre-fix that resolver typed the field GEP with the bare field
    // value type (`*i64`), so emitStore unwrapped one level to `i64` and
    // coerceArg's closure auto-promotion stored a 16-byte struct over the
    // 8-byte field, clobbering the neighbour. The resolver now types the GEP
    // `*(*i64)` so emitStore stops at the field's own pointer type.
    var s_pointee = Node{ .span = span, .data = .{ .type_expr = .{ .name = "S", .is_generic = false } } };
    var s_ty = Node{ .span = span, .data = .{ .pointer_type_expr = .{ .pointee_type = &s_pointee } } };
    var q_pointee = Node{ .span = span, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    var q_ty = Node{ .span = span, .data = .{ .pointer_type_expr = .{ .pointee_type = &q_pointee } } };

    var d_init = Node{ .span = span, .data = .{ .int_literal = .{ .value = 0 } } };
    var d_decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "d", .name_span = span, .type_annotation = null, .value = &d_init } } };

    var s_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "s" } } };
    var target0 = Node{ .span = span, .data = .{ .field_access = .{ .object = &s_ident, .field = "p" } } };
    var target1 = Node{ .span = span, .data = .{ .identifier = .{ .name = "d" } } };
    var q_rhs = Node{ .span = span, .data = .{ .identifier = .{ .name = "q" } } };
    var v1 = Node{ .span = span, .data = .{ .int_literal = .{ .value = 1 } } };
    const targets = [_]*Node{ &target0, &target1 };
    const values = [_]*Node{ &q_rhs, &v1 };
    var massign = Node{ .span = span, .data = .{ .multi_assign = .{ .targets = &targets, .values = &values } } };

    const stmts = [_]*Node{ &d_decl, &massign };
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const params = [_]ast.Param{
        .{ .name = "s", .name_span = span, .type_expr = &s_ty },
        .{ .name = "q", .name_span = span, .type_expr = &q_ty },
    };
    const fd = ast.FnDecl{ .name = "mutate", .params = &params, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.lowerFunction(&fd, "mutate", false);

    // The field-store GEP must be typed `*(*i64)`: its pointee is the field's
    // own type (`*i64`), not the field's pointee (`i64`).
    const func = module.getFunction(FuncId.fromIndex(0));
    var found = false;
    for (func.blocks.items) |blk| {
        for (blk.insts.items) |inst| {
            if (inst.op == .struct_gep) {
                const info = module.types.get(inst.ty);
                try std.testing.expect(info == .pointer);
                try std.testing.expectEqual(ptr_i64, info.pointer.pointee);
                found = true;
            }
        }
    }
    try std.testing.expect(found);
}

test "lower: reflectionArgIsType accepts spelled types, rejects plain values (issue 0090)" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);

    const span = ast.Span{ .start = 0, .end = 0 };
    const ty_node = Node{ .span = span, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    const int_node = Node{ .span = span, .data = .{ .int_literal = .{ .value = 6 } } };
    const float_node = Node{ .span = span, .data = .{ .float_literal = .{ .value = 1.5 } } };
    const bool_node = Node{ .span = span, .data = .{ .bool_literal = .{ .value = true } } };

    // A spelled type is a type → the introspection builtins accept it.
    try std.testing.expect(l.reflectionArgIsType(&ty_node));
    // Plain values are NOT types — these are exactly the arguments issue
    // 0090's strict `$T: Type` guard rejects, before a builtin could
    // reinterpret the value as a TypeId index (`type_is_unsigned(6)` → true)
    // or size its `typeof` (`size_of(true)` → 8).
    try std.testing.expect(!l.reflectionArgIsType(&int_node));
    try std.testing.expect(!l.reflectionArgIsType(&float_node));
    try std.testing.expect(!l.reflectionArgIsType(&bool_node));
}

var g_lower_test_threaded: ?std.Io.Threaded = null;
fn lowerTestIo() std.Io {
    if (g_lower_test_threaded == null) {
        g_lower_test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return g_lower_test_threaded.?.io();
}

/// Count functions named `name` that carry a REAL body (promoted from the extern
/// stub: not `is_extern`, at least one basic block).
fn countRealBodies(module: *ir_mod.Module, name: []const u8) usize {
    var n: usize = 0;
    for (module.functions.items) |func| {
        if (!std.mem.eql(u8, module.types.getString(func.name), name)) continue;
        if (func.is_extern) continue;
        if (func.blocks.items.len == 0) continue;
        n += 1;
    }
    return n;
}

// two flat-imported modules each author `greet`. The first-wins merge
// keeps a.sx's author in the merged decl list (the WINNER) and drops b.sx's,
// which the `module_decls` raw facts still retain (0102a). `main` itself can't bare-call `greet`
// — with two flat authors this is ambiguous; two flat authors make that ambiguous — so it calls a.sx's
// `use_greet` wrapper, whose own-author call to `greet` binds a.sx's winner.
// BEFORE the identity-addressable pass, only the winner has a real body — the
// shadowed author has no slot at all (the pre-fix symptom: one `greet`).
// `lowerRetainedSameNameAuthors` declares the shadowed author its OWN same-name
// FuncId and lowers its body there, so BOTH authors carry distinct, non-extern
// bodies, and `resolveFuncByName` still returns the winner (the name-keyed slot).
test "lower: shadowed same-name author gets its own FuncId + real body (fix-0102b)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = lowerTestIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.sx", .data = "greet :: () -> i64 { 1 }\nuse_greet :: () -> i64 { greet() }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.sx", .data = "greet :: () -> i64 { 2 }\n" });
    const main_src =
        \\#import "a.sx";
        \\#import "b.sx";
        \\main :: () -> i64 { use_greet() }
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = main_src });

    var dirbuf: [4096]u8 = undefined;
    const dirlen = try tmp.dir.realPath(io, &dirbuf);
    const absdir = dirbuf[0..dirlen];

    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});
    const main_bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, main_path, alloc, .limited(1 << 20));
    const main_source = try alloc.dupeZ(u8, main_bytes);
    var p = parser.Parser.init(alloc, main_source);
    const root = p.parse() catch return error.ParseFailed;

    var chain = std.StringHashMap(void).init(alloc);
    var cache = imports.ModuleCache.init(alloc);
    var import_graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    var flat_import_graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    const stdlib_paths = [_][]const u8{};

    const mod = try imports.resolveImports(
        alloc,
        io,
        root,
        absdir,
        main_path,
        &chain,
        &cache,
        null,
        null,
        &stdlib_paths,
        &import_graph,
        &flat_import_graph,
        .{},
    );

    // Per-module visibility scopes + authored-function index, wired exactly as
    // `core.zig` does before `lowerRoot`.
    var module_scopes = std.StringHashMap(std.StringHashMap(@import("../ast.zig").Visibility)).init(alloc);
    try module_scopes.put(main_path, mod.scope);
    var cache_it = cache.iterator();
    while (cache_it.next()) |entry| {
        try module_scopes.put(entry.key_ptr.*, entry.value_ptr.scope);
    }
    // Phase A raw facts: both `selectPlainCallableAuthor` (Phase C) and
    // `lowerRetainedSameNameAuthors` read function authors out of `module_decls`.
    // Wired exactly as `core.zig` does.
    var facts = try imports.buildImportFacts(alloc, main_path, mod, &cache);

    const resolved_root = try alloc.create(Node);
    resolved_root.* = .{ .span = root.span, .data = .{ .root = .{ .decls = mod.decls } } };

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, main_source, main_path);
    var lowering = Lowering.init(&module);
    lowering.main_file = main_path;
    lowering.resolved_root = resolved_root;
    lowering.diagnostics = &diagnostics;
    lowering.program_index.module_scopes = &module_scopes;
    lowering.program_index.import_graph = &import_graph;
    lowering.program_index.flat_import_graph = &flat_import_graph;
    lowering.program_index.module_decls = &facts.decls;

    lowering.lowerRoot(resolved_root);
    try std.testing.expect(!diagnostics.hasErrors());

    // Pre-fix symptom: only the winner `greet` (a.sx) has a real body — lowered
    // because `main` calls it; the shadowed author (b.sx) was dropped entirely.
    try std.testing.expectEqual(@as(usize, 1), countRealBodies(&module, "greet"));

    // Identity-addressable pass: the shadowed author gets its OWN FuncId + body.
    lowering.lowerRetainedSameNameAuthors();
    try std.testing.expect(!diagnostics.hasErrors());

    // Both `greet` authors now carry distinct, real (non-extern) bodies, and the
    // two FuncIds are distinct.
    try std.testing.expectEqual(@as(usize, 2), countRealBodies(&module, "greet"));

    const name_id = module.types.internString("greet");
    var first: ?FuncId = null;
    var second: ?FuncId = null;
    for (module.functions.items, 0..) |func, i| {
        if (func.name != name_id) continue;
        if (func.is_extern or func.blocks.items.len == 0) continue;
        if (first == null) first = FuncId.fromIndex(@intCast(i)) else second = FuncId.fromIndex(@intCast(i));
    }
    try std.testing.expect(first != null and second != null);
    try std.testing.expect(first.? != second.?);

    // F1 (attempt-2): the identity map must be keyed by the STABLE AST field
    // pointer for BOTH same-name authors — the exact pointers `fn_ast_map` and
    // the `module_decls` raw facts carry — not a per-iteration switch-capture
    // temporary. If the winner were keyed by `&fd` (the scanDecls bug), this
    // lookup by the stable `fn_ast_map` pointer would miss (null). Bare-call
    // routing goes through exactly these pointers, so the round-trip must hold.
    const winner_fd = lowering.program_index.fn_ast_map.get("greet").?;
    const winner_fid = lowering.fn_decl_fids.get(winner_fd);
    try std.testing.expect(winner_fid != null);
    // Round-trips to the first-wins winner FuncId (resolveFuncByName's pick).
    try std.testing.expectEqual(lowering.resolveFuncByName("greet").?, winner_fid.?);

    // The shadowed author's stable pointer lives in `module_decls`; find the one
    // that is NOT the winner and confirm IT round-trips to a DISTINCT FuncId.
    var shadow_fd: ?*const ast.FnDecl = null;
    var md_it = facts.decls.iterator();
    while (md_it.next()) |path_entry| {
        if (path_entry.value_ptr.names.get("greet")) |ref| {
            if (ref == .fn_decl and ref.fn_decl != winner_fd) shadow_fd = ref.fn_decl;
        }
    }
    try std.testing.expect(shadow_fd != null);
    const shadow_fid = lowering.fn_decl_fids.get(shadow_fd.?);
    try std.testing.expect(shadow_fid != null);
    try std.testing.expect(shadow_fid.? != winner_fid.?);

    // Phase C: THE bare-name selector routes per caller file over the
    // Phase A author collector. `main` flat-imports two `greet` authors and is its
    // own author of neither → a bare `greet()` from `main` is ambiguous. a.sx
    // authors the WINNER, so its bare `greet` resolves through the existing path
    // (`.none`). b.sx authors the SHADOW, so own-author-wins selects b.sx's
    // author — its `*FnDecl` + source, NOT first-wins. The selector does NOT
    // eagerly materialize: it returns the decl, and the FuncId still round-trips
    // to the shadow slot via the identity map (`fn_decl_fids`).
    // Imported modules are keyed by their CANONICAL path (issue 0148).
    const a_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/a.sx", .{absdir}));
    const b_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/b.sx", .{absdir}));
    try std.testing.expect(lowering.selectPlainCallableAuthor("greet", main_path) == .ambiguous);
    try std.testing.expect(lowering.selectPlainCallableAuthor("greet", a_path) == .none);
    switch (lowering.selectPlainCallableAuthor("greet", b_path)) {
        .func => |sf| {
            try std.testing.expectEqual(shadow_fd.?, sf.decl);
            try std.testing.expectEqualStrings(b_path, sf.source);
            try std.testing.expect(sf.materialized == null);
            try std.testing.expectEqual(shadow_fid.?, lowering.fn_decl_fids.get(sf.decl).?);
        },
        else => return error.TestUnexpectedResult,
    }
    // A name no module authors (and no flat import provides) never routes.
    try std.testing.expect(lowering.selectPlainCallableAuthor("nonexistent", b_path) == .none);
}

// E0 (R5 §#4): the scan populates the source-keyed caches partitioned by the
// registering decl's source. Two namespaced modules each author the SAME alias
// name `Color` AND the SAME const name `K`; the scan recurses into each
// namespace's decls (per-source). After lowering, the by-source maps hold TWO
// distinct entries under the two source keys (not last-wins), while the legacy
// global maps stay single-keyed by name — the compat readers are unchanged.
test "lower: scan populates source-keyed caches per declaring source (E0)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = lowerTestIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.sx", .data = "Color :: *u8;\nK :: 5;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.sx", .data = "Color :: *u16;\nK :: 7;\n" });
    const main_src =
        \\na :: #import "a.sx";
        \\nb :: #import "b.sx";
        \\main :: () -> i32 { 0 }
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = main_src });

    var dirbuf: [4096]u8 = undefined;
    const dirlen = try tmp.dir.realPath(io, &dirbuf);
    const absdir = dirbuf[0..dirlen];

    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});
    const main_bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, main_path, alloc, .limited(1 << 20));
    const main_source = try alloc.dupeZ(u8, main_bytes);
    var p = parser.Parser.init(alloc, main_source);
    const root = p.parse() catch return error.ParseFailed;

    var chain = std.StringHashMap(void).init(alloc);
    var cache = imports.ModuleCache.init(alloc);
    var import_graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    var flat_import_graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    const stdlib_paths = [_][]const u8{};

    const mod = try imports.resolveImports(
        alloc,
        io,
        root,
        absdir,
        main_path,
        &chain,
        &cache,
        null,
        null,
        &stdlib_paths,
        &import_graph,
        &flat_import_graph,
        .{},
    );

    var module_scopes = std.StringHashMap(std.StringHashMap(@import("../ast.zig").Visibility)).init(alloc);
    try module_scopes.put(main_path, mod.scope);
    var cache_it = cache.iterator();
    while (cache_it.next()) |entry| {
        try module_scopes.put(entry.key_ptr.*, entry.value_ptr.scope);
    }
    var facts = try imports.buildImportFacts(alloc, main_path, mod, &cache);

    const resolved_root = try alloc.create(Node);
    resolved_root.* = .{ .span = root.span, .data = .{ .root = .{ .decls = mod.decls } } };

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, main_source, main_path);
    var lowering = Lowering.init(&module);
    lowering.main_file = main_path;
    lowering.resolved_root = resolved_root;
    lowering.diagnostics = &diagnostics;
    lowering.program_index.module_scopes = &module_scopes;
    lowering.program_index.import_graph = &import_graph;
    lowering.program_index.flat_import_graph = &flat_import_graph;
    lowering.program_index.module_decls = &facts.decls;

    lowering.lowerRoot(resolved_root);
    try std.testing.expect(!diagnostics.hasErrors());

    // Imported modules are keyed by their CANONICAL path (issue 0148).
    const a_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/a.sx", .{absdir}));
    const b_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/b.sx", .{absdir}));
    const idx = &lowering.program_index;

    // SAME alias name `Color` lands a DISTINCT entry under each source key.
    const color_a = idx.type_aliases_by_source.get(a_path).?.get("Color").?;
    const color_b = idx.type_aliases_by_source.get(b_path).?.get("Color").?;
    try std.testing.expect(color_a != color_b); // *u8 vs *u16 — source-partitioned

    // SAME const name `K` lands a DISTINCT entry (distinct value node) per source.
    const k_a = idx.module_consts_by_source.get(a_path).?.get("K").?;
    const k_b = idx.module_consts_by_source.get(b_path).?.get("K").?;
    try std.testing.expect(k_a.value != k_b.value);

    // Compat readers: the legacy global maps stay keyed by NAME alone — a
    // hashmap key holds exactly one value, so a same-name author is last-wins
    // there (one entry for `Color` / `K`), unchanged by the by-source writes.
    // The single global `Color` is one of the two source-keyed authors (not a
    // merged/duplicated value).
    const global_color = idx.type_alias_map.get("Color").?;
    try std.testing.expect(global_color == color_a or global_color == color_b);
    const global_k = idx.module_const_map.get("K").?;
    try std.testing.expect(global_k.value == k_a.value or global_k.value == k_b.value);
}

test "struct literal: non-aggregate target and uninferable untyped literal diagnose (issues 0161, 0184)" {
    // Arena: DiagnosticList.addFmt allocates messages it never frees in deinit
    // (mixed ownership with borrowed literals) — an arena keeps the leak
    // checker clean without changing diagnostic semantics.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Untyped `.{ }` literals SELF-TYPE now (aggregate ladder Step 1/2) —
    // targetless locals, global consts, inferred returns, and array
    // elements all mint anonymous structs, so only the 0161 arm (a bare
    // literal against a NON-aggregate annotation) still diagnoses here.
    const src =
        \\main :: () {
        \\    x : i64 = .{ a = 1 };
        \\}
        \\
    ;
    const source = try alloc.dupeZ(u8, src);
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);

    // Issue 0161: `.{ a = 1 }` against a scalar target used to reach LLVM
    // emission (`Invalid InsertValueInst operands!`). Issue 0184: an untyped
    // `.{ 1, 2, 3 }` with no target stayed `.unresolved` and panicked the
    // backend. Both must be clean located diagnostics from lowering.
    try std.testing.expect(diagnostics.hasErrors());
    var saw_non_aggregate = false;
    for (diagnostics.items.items) |d| {
        if (d.level != .err) continue;
        if (std.mem.indexOf(u8, d.message, "cannot build a struct literal for non-struct type 'i64'") != null) saw_non_aggregate = true;
    }
    try std.testing.expect(saw_non_aggregate);
}

test "struct literal: formerly-silent untyped shapes SELF-TYPE — global const, inferred return, array element (aggregate ladder Step 1)" {
    // These three shapes used to arrive with a silently-unresolved target
    // and diagnose "cannot infer" (issue 0184). Untyped `.{ }` literals
    // self-type as anonymous structs now — pass-1 inference mints the type
    // — so each compiles with NO diagnostic (corpus pin: 0865).
    const cases = [_][]const u8{
        \\K :: .{ 1, 2, 3 };
        \\main :: () { k := K; }
        \\
        ,
        \\f :: () { return .{ 1 }; }
        \\main :: () { f(); }
        \\
        ,
        \\main :: () { arr := .[ .{ 1 }, .{ 2 } ]; }
        \\
    };
    for (cases) |src| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const source = try alloc.dupeZ(u8, src);
        var p = parser.Parser.init(alloc, source);
        const root = p.parse() catch return error.ParseFailed;

        var module = ir_mod.Module.init(alloc);
        defer module.deinit();
        var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
        var lowering = Lowering.init(&module);
        lowering.diagnostics = &diagnostics;
        lowering.lowerRoot(root);

        try std.testing.expect(!diagnostics.hasErrors());
    }
}

test "lower: match on untagged union subject (payload binding) is diagnosed, not .unresolved (issues 0163/0222)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    // Register `Shape :: union { circle: i64; rect: i64; }` — a plain
    // UNTAGGED union (no discriminant).
    const fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = module.types.internString("circle"), .ty = .i64 },
        .{ .name = module.types.internString("rect"), .ty = .i64 },
    };
    _ = module.types.intern(.{ .@"union" = .{ .name = module.types.internString("Shape"), .fields = &fields } });

    const span = ast.Span{ .start = 0, .end = 0 };

    // main :: (s: Shape) { r := if s == { case .circle: (v) { } }; }
    var shape_type = Node{ .span = span, .data = .{ .type_expr = .{ .name = "Shape", .is_generic = false } } };
    var s_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "s" } } };
    var pat = Node{ .span = span, .data = .{ .enum_literal = .{ .name = "circle" } } };
    var arm_body = Node{ .span = span, .data = .{ .block = .{ .stmts = &.{} } } };
    const arms = [_]ast.MatchArm{
        .{ .pattern = &pat, .body = &arm_body, .is_break = false, .capture = "v" },
    };
    var match = Node{ .span = span, .data = .{ .match_expr = .{ .subject = &s_ident, .arms = &arms } } };
    var decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "r", .name_span = span, .type_annotation = null, .value = &match } } };

    const stmts = [_]*Node{&decl};
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const params: []const ast.Param = &.{.{ .name = "s", .name_span = span, .type_expr = &shape_type }};
    const fd = ast.FnDecl{ .name = "main", .params = params, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    // Pre-0163 the capture's payload type leaked out as .unresolved and
    // panicked at LLVM emission (declareFunction → toLLVMType). The 0222
    // subject-type gate now subsumes the arm-level union rejection: the whole
    // match on an untagged-union subject is refused up front — binding or not.
    lowering.lowerFunction(&fd, "main", false);

    var found = false;
    for (diags.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, "cannot match on untagged union 'Shape'") != null) found = true;
    }
    try std.testing.expect(found);
}

test "lower: match on untagged union subject (no binding) is diagnosed, not invalid IR (issue 0222)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    // Register `Shape :: union { circle: i64; rect: i64; }` — a plain
    // UNTAGGED union (no discriminant).
    const fields = [_]ir_mod.types.TypeInfo.StructInfo.Field{
        .{ .name = module.types.internString("circle"), .ty = .i64 },
        .{ .name = module.types.internString("rect"), .ty = .i64 },
    };
    _ = module.types.intern(.{ .@"union" = .{ .name = module.types.internString("Shape"), .fields = &fields } });

    const span = ast.Span{ .start = 0, .end = 0 };

    // main :: (s: Shape) { r := if s == { case .circle: { } case .rect: { } }; }
    // NO payload binding — pre-fix this slipped past the arm-level 0163 guard
    // and reached the backend as a switch on the raw `[8 x i8]` union storage
    // against `i0` case constants (LLVM verifier failure, no diagnostic).
    var shape_type = Node{ .span = span, .data = .{ .type_expr = .{ .name = "Shape", .is_generic = false } } };
    var s_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "s" } } };
    var pat_a = Node{ .span = span, .data = .{ .enum_literal = .{ .name = "circle" } } };
    var pat_b = Node{ .span = span, .data = .{ .enum_literal = .{ .name = "rect" } } };
    var arm_body_a = Node{ .span = span, .data = .{ .block = .{ .stmts = &.{} } } };
    var arm_body_b = Node{ .span = span, .data = .{ .block = .{ .stmts = &.{} } } };
    const arms = [_]ast.MatchArm{
        .{ .pattern = &pat_a, .body = &arm_body_a, .is_break = false, .capture = null },
        .{ .pattern = &pat_b, .body = &arm_body_b, .is_break = false, .capture = null },
    };
    var match = Node{ .span = span, .data = .{ .match_expr = .{ .subject = &s_ident, .arms = &arms } } };
    var decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "r", .name_span = span, .type_annotation = null, .value = &match } } };

    const stmts = [_]*Node{&decl};
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const params: []const ast.Param = &.{.{ .name = "s", .name_span = span, .type_expr = &shape_type }};
    const fd = ast.FnDecl{ .name = "main", .params = params, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    lowering.lowerFunction(&fd, "main", false);

    var found = false;
    for (diags.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, "cannot match on untagged union 'Shape'") != null) found = true;
    }
    try std.testing.expect(found);
}

test "lower: match on a string subject is diagnosed, not invalid IR (issue 0224)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    const span = ast.Span{ .start = 0, .end = 0 };

    // main :: (s: string) { r := if s == { case "hi": { } }; }
    // Pre-fix this reached the backend as `switch ptr` against integer case
    // constants (LLVM verifier failure, no diagnostic). String subjects are
    // not matchable (specs §Pattern Matching: patterns are enum literals,
    // integer/bool literals, and type categories).
    var string_type = Node{ .span = span, .data = .{ .type_expr = .{ .name = "string", .is_generic = false } } };
    var s_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "s" } } };
    var pat = Node{ .span = span, .data = .{ .string_literal = .{ .raw = "hi" } } };
    var arm_body = Node{ .span = span, .data = .{ .block = .{ .stmts = &.{} } } };
    const arms = [_]ast.MatchArm{
        .{ .pattern = &pat, .body = &arm_body, .is_break = false, .capture = null },
    };
    var match = Node{ .span = span, .data = .{ .match_expr = .{ .subject = &s_ident, .arms = &arms } } };
    var decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "r", .name_span = span, .type_annotation = null, .value = &match } } };

    const stmts = [_]*Node{&decl};
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const params: []const ast.Param = &.{.{ .name = "s", .name_span = span, .type_expr = &string_type }};
    const fd = ast.FnDecl{ .name = "main", .params = params, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    lowering.lowerFunction(&fd, "main", false);

    var found = false;
    for (diags.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, "cannot match on 'string'") != null) found = true;
    }
    try std.testing.expect(found);
}

test "lower: match arms with incompatible result types are diagnosed, not a mixed-type phi (issue 0236)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    const span = ast.Span{ .start = 0, .end = 0 };

    // main :: (s: i64) { r := if s == { case 1: { 1 } case 2: { "hi" } }; }
    // Pre-fix `inferMatchResultType` took the FIRST decisive arm's type
    // without unifying, and the raw string arm value fed the merge phi —
    // an LLVM verifier failure ("PHI node operands are not the same type
    // as the result!") with no diagnostic. The unification pass now
    // diagnoses the true mismatch at the offending arm.
    var int_type = Node{ .span = span, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    var s_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "s" } } };
    var pat_a = Node{ .span = span, .data = .{ .int_literal = .{ .value = 1 } } };
    var pat_b = Node{ .span = span, .data = .{ .int_literal = .{ .value = 2 } } };
    var val_a = Node{ .span = span, .data = .{ .int_literal = .{ .value = 1 } } };
    var val_b = Node{ .span = span, .data = .{ .string_literal = .{ .raw = "hi" } } };
    const stmts_a = [_]*Node{&val_a};
    const stmts_b = [_]*Node{&val_b};
    var arm_body_a = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts_a, .produces_value = true } } };
    var arm_body_b = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts_b, .produces_value = true } } };
    const arms = [_]ast.MatchArm{
        .{ .pattern = &pat_a, .body = &arm_body_a, .is_break = false, .capture = null },
        .{ .pattern = &pat_b, .body = &arm_body_b, .is_break = false, .capture = null },
    };
    var match = Node{ .span = span, .data = .{ .match_expr = .{ .subject = &s_ident, .arms = &arms } } };
    var decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "r", .name_span = span, .type_annotation = null, .value = &match } } };

    const stmts = [_]*Node{&decl};
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const params: []const ast.Param = &.{.{ .name = "s", .name_span = span, .type_expr = &int_type }};
    const fd = ast.FnDecl{ .name = "main", .params = params, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    lowering.lowerFunction(&fd, "main", false);

    var found = false;
    for (diags.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, "match arms have incompatible types: 'i64' vs 'string'") != null) found = true;
    }
    try std.testing.expect(found);
}

test "lower: payload binding on a payload-less enum match is diagnosed, not .unresolved (issue 0163 fold)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    // Register `Color :: enum { red; green; }` — a plain enum, no payloads.
    const variants = [_]ir_mod.types.StringId{
        module.types.internString("red"),
        module.types.internString("green"),
    };
    _ = module.types.intern(.{ .@"enum" = .{ .name = module.types.internString("Color"), .variants = &variants } });

    const span = ast.Span{ .start = 0, .end = 0 };

    // main :: (c: Color) { r := if c == { case .red: (v) { } }; }
    var color_type = Node{ .span = span, .data = .{ .type_expr = .{ .name = "Color", .is_generic = false } } };
    var c_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "c" } } };
    var pat = Node{ .span = span, .data = .{ .enum_literal = .{ .name = "red" } } };
    var arm_body = Node{ .span = span, .data = .{ .block = .{ .stmts = &.{} } } };
    const arms = [_]ast.MatchArm{
        .{ .pattern = &pat, .body = &arm_body, .is_break = false, .capture = "v" },
    };
    var match = Node{ .span = span, .data = .{ .match_expr = .{ .subject = &c_ident, .arms = &arms } } };
    var decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "r", .name_span = span, .type_annotation = null, .value = &match } } };

    const stmts = [_]*Node{&decl};
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const params: []const ast.Param = &.{.{ .name = "c", .name_span = span, .type_expr = &color_type }};
    const fd = ast.FnDecl{ .name = "main", .params = params, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    // Pre-fold this leaked .unresolved through enum_payload just like the
    // untagged-union shape; the generic guard now rejects any binding whose
    // payload type failed to resolve.
    lowering.lowerFunction(&fd, "main", false);

    var found = false;
    for (diags.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, "cannot bind a payload from subject type 'Color'") != null) found = true;
    }
    try std.testing.expect(found);
}

test "call: a local fn-pointer binding shadows a same-named top-level fn (issue 0217)" {
    // The 0217 shape: an (importer's) module-scope fn named like a LOCAL
    // fn-pointer binding must never hijack the call — nor may the
    // non-transitive visibility gate reject it. Call-position resolution
    // honors the lexical scope first, matching value-position resolution
    // (call.zig `callableLocalShadow`).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\h :: (x: i64) -> i64 { return x + 1; }
        \\target :: (x: i64) -> i64 { return x + 2; }
        \\main :: () {
        \\    h : (x: i64) -> i64 = target;
        \\    r := h(3);
        \\    _ := r;
        \\}
        \\
    ;
    const source = try alloc.dupeZ(u8, src);
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);

    try std.testing.expect(!diagnostics.hasErrors());

    // The call inside `main` must dispatch INDIRECTLY through the local
    // binding — never as a direct `.call` of the top-level `h`'s FuncId.
    const h_fid = lowering.resolveFuncByName("h").?;
    const main_fid = lowering.resolveFuncByName("main").?;
    const main_fn = &module.functions.items[@intFromEnum(main_fid)];
    var saw_indirect = false;
    for (main_fn.blocks.items) |blk| {
        for (blk.insts.items) |inst| {
            switch (inst.op) {
                .call_indirect => saw_indirect = true,
                .call => |c| try std.testing.expect(c.callee != h_fid),
                else => {},
            }
        }
    }
    try std.testing.expect(saw_indirect);
}

test "scope: lookupNearest resolves by depth across both local namespaces (issue 0217 review F1)" {
    // `lookup` / `lookupFn` each walk the WHOLE chain of one namespace, so
    // neither can say which declaration is nearest when a value binding and
    // a nested local fn share a name at different depths. `lookupNearest`
    // walks once, consulting both tables per level — innermost wins.
    const lower_mod = @import("lower.zig");
    const Scope = lower_mod.Scope;
    const alloc = std.testing.allocator;

    var outer = Scope.init(alloc, null);
    defer outer.deinit();
    var inner = Scope.init(alloc, &outer);
    defer inner.deinit();

    // Direction A: outer VAR, inner nested FN — the fn is nearest.
    outer.put("h", .{ .ref = Ref.none, .ty = .i64, .is_alloca = false });
    inner.fn_names.put("h", "h__mangled") catch unreachable;
    {
        const near = inner.lookupNearest("h").?;
        try std.testing.expect(near == .local_fn);
        try std.testing.expectEqualStrings("h__mangled", near.local_fn);
        // From the OUTER scope the var is the only (and nearest) decl.
        try std.testing.expect(outer.lookupNearest("h").? == .binding);
    }

    // Direction B: outer nested FN, inner VAR — the var is nearest.
    outer.fn_names.put("g", "g__mangled") catch unreachable;
    inner.put("g", .{ .ref = Ref.none, .ty = .i64, .is_alloca = false });
    {
        const near = inner.lookupNearest("g").?;
        try std.testing.expect(near == .binding);
        try std.testing.expect(outer.lookupNearest("g").? == .local_fn);
    }

    try std.testing.expect(inner.lookupNearest("absent") == null);
}

test "scope: lookupBoundary flags a value binding reached across a nested-fn boundary (issue 0250)" {
    // A static nested `::` fn's body scope keeps its parent chain (so sibling
    // fns + comptime consts still resolve) but sets `is_fn_boundary`. A plain
    // VALUE binding found by crossing that boundary is an enclosing local the
    // static fn has no env to reach — `crossed_fn_boundary` reports it so the
    // identifier site diagnoses instead of emitting the enclosing frame's dead
    // Ref (the miscompile: undef read, exit 0, no diagnostic).
    const lower_mod = @import("lower.zig");
    const Scope = lower_mod.Scope;
    const alloc = std.testing.allocator;

    // enclosing (a fn body / block) — holds the local `x`.
    var enclosing = Scope.init(alloc, null);
    defer enclosing.deinit();
    enclosing.put("x", .{ .ref = Ref.none, .ty = .i64, .is_alloca = true });

    // the nested static fn's body scope — parent chain kept, boundary flagged.
    var nested = Scope.init(alloc, &enclosing);
    nested.is_fn_boundary = true;
    defer nested.deinit();

    // `x` is reachable only by crossing the boundary → reject.
    const crossed = nested.lookupBoundary("x");
    try std.testing.expect(crossed.binding != null);
    try std.testing.expect(crossed.crossed_fn_boundary);

    // The nested fn's OWN local resolves without crossing → accept.
    nested.put("z", .{ .ref = Ref.none, .ty = .i64, .is_alloca = true });
    const own = nested.lookupBoundary("z");
    try std.testing.expect(own.binding != null);
    try std.testing.expect(!own.crossed_fn_boundary);

    // From the enclosing scope itself (no boundary above `x`) → a normal hit.
    const direct = enclosing.lookupBoundary("x");
    try std.testing.expect(direct.binding != null);
    try std.testing.expect(!direct.crossed_fn_boundary);

    // An absent name is a plain miss, never a boundary error.
    const miss = nested.lookupBoundary("absent");
    try std.testing.expect(miss.binding == null);
    try std.testing.expect(!miss.crossed_fn_boundary);
}

test "lower: getExprAlloca diagnoses + returns null across a nested-fn boundary, resolves same-function allocas (issue 0250 fold)" {
    // The review fold: getExprAlloca is the storage resolver behind the
    // indexed-read fast path and the lvalue helpers — pre-fold it handed a
    // nested static fn the ENCLOSING function's alloca Ref (dead in this
    // function's SSA context → segfault / Bus error). Across the boundary it
    // must diagnose and return null (callers fall to their boundary-guarded
    // lowering paths); a SAME-function alloca must keep resolving with no
    // diagnostic (no false positives on ordinary lookups).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();
    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;

    const lower_mod = @import("lower.zig");
    const Scope = lower_mod.Scope;
    const span = ast.Span{ .start = 0, .end = 0 };

    // A live function context so the diagnostic's placeholder emit has a block.
    _ = lowering.builder.beginFunction(module.types.internString("t"), &.{}, .void);
    const entry = lowering.builder.appendBlock(module.types.internString("entry"), &.{});
    lowering.builder.switchToBlock(entry);

    // enclosing fn scope holds alloca `x`; nested static fn scope is flagged.
    var enclosing = Scope.init(alloc, null);
    defer enclosing.deinit();
    const x_slot = lowering.builder.alloca(.i64);
    enclosing.put("x", .{ .ref = x_slot, .ty = .i64, .is_alloca = true });
    var nested = Scope.init(alloc, &enclosing);
    nested.is_fn_boundary = true;
    defer nested.deinit();
    lowering.scope = &nested;

    var x_node = Node{ .span = span, .data = .{ .identifier = .{ .name = "x" } } };

    // Crossed: null + exactly one 0250 diagnostic.
    try std.testing.expect(lowering.getExprAlloca(&x_node) == null);
    var count: usize = 0;
    for (diags.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, "cannot reference the enclosing local 'x'") != null) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);

    // Same-function alloca (`z` in the nested scope itself): resolves, silent.
    const z_slot = lowering.builder.alloca(.i64);
    nested.put("z", .{ .ref = z_slot, .ty = .i64, .is_alloca = true });
    var z_node = Node{ .span = span, .data = .{ .identifier = .{ .name = "z" } } };
    try std.testing.expectEqual(z_slot, lowering.getExprAlloca(&z_node).?);
    try std.testing.expectEqual(diags.items.items.len, @as(usize, 1)); // no new diagnostics

    // From the ENCLOSING scope itself `x` resolves normally (no boundary above it).
    lowering.scope = &enclosing;
    try std.testing.expectEqual(x_slot, lowering.getExprAlloca(&x_node).?);
    try std.testing.expectEqual(diags.items.items.len, @as(usize, 1));
}

test "capture: a scope binding shadowing a fn name resolves to .binding, not skipped (issue 0251)" {
    // The decision `collectCaptures` now makes: at a closure-creation site, a
    // local/param that shadows a global fn name must be CAPTURED (a `.binding`
    // result), never skipped as a "function name". The pre-0251 code consulted
    // the program-wide fn table first, so such a local was dropped and the
    // closure body read/wrote garbage. `lookupNearest` is the single source of
    // truth: `.binding` → capture, `.local_fn`/null → fall through to the
    // fn/type-name skip. A nested local fn (`.local_fn`) is a callable, not a
    // capturable value, so it is correctly NOT captured.
    const lower_mod = @import("lower.zig");
    const Scope = lower_mod.Scope;
    const alloc = std.testing.allocator;

    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    // A value binding named exactly like the (hypothetical) global fn `out`.
    scope.put("out", .{ .ref = Ref.none, .ty = .i64, .is_alloca = true });
    const shadow = scope.lookupNearest("out").?;
    try std.testing.expect(shadow == .binding); // → captured

    // A nested local fn named `helper` is a callable, resolves as `.local_fn`
    // → the capture path leaves it to dispatch, does not place it in the env.
    scope.fn_names.put("helper", "helper__mangled") catch unreachable;
    try std.testing.expect(scope.lookupNearest("helper").? == .local_fn);

    // A name with NO scope binding at all → null → the fn/type-name skip runs.
    try std.testing.expect(scope.lookupNearest("print") == null);
}

test "lower: indexing a scalar pointer diagnoses in write and address-of positions, no unresolved GEP (issue 0155)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    const span = ast.Span{ .start = 0, .end = 0 };

    // f :: (pc: *i64) { pc[0] = 7; q := @pc[0]; }
    // A bare `*T` is not indexable (specs.md, Pointer Types) — both the WRITE
    // (`pc[0] = 7`) and ADDRESS-OF (`@pc[0]`) index paths must diagnose. The
    // READ path was already guarded (issue 0183); pre-fix these two arms still
    // emitted an `index_gep` typed `ptrTo(.unresolved)` that panicked at LLVM
    // emission ("unresolved type reached LLVM emission", issue 0155).
    var i64_type = Node{ .span = span, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    var ptr_i64 = Node{ .span = span, .data = .{ .pointer_type_expr = .{ .pointee_type = &i64_type } } };

    var pc1 = Node{ .span = span, .data = .{ .identifier = .{ .name = "pc" } } };
    var zero1 = Node{ .span = span, .data = .{ .int_literal = .{ .value = 0 } } };
    var target = Node{ .span = span, .data = .{ .index_expr = .{ .object = &pc1, .index = &zero1 } } };
    var seven = Node{ .span = span, .data = .{ .int_literal = .{ .value = 7 } } };
    var assign = Node{ .span = span, .data = .{ .assignment = .{ .target = &target, .op = .assign, .value = &seven } } };

    const span2 = ast.Span{ .start = 9, .end = 9 };
    var pc2 = Node{ .span = span2, .data = .{ .identifier = .{ .name = "pc" } } };
    var zero2 = Node{ .span = span2, .data = .{ .int_literal = .{ .value = 0 } } };
    var idx2 = Node{ .span = span2, .data = .{ .index_expr = .{ .object = &pc2, .index = &zero2 } } };
    var addr = Node{ .span = span, .data = .{ .unary_op = .{ .op = .address_of, .operand = &idx2 } } };
    var qdecl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "q", .name_span = span, .type_annotation = null, .value = &addr } } };

    const stmts = [_]*Node{ &assign, &qdecl };
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const params: []const ast.Param = &.{.{ .name = "pc", .name_span = span, .type_expr = &ptr_i64 }};
    const fd = ast.FnDecl{ .name = "f", .params = params, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    lowering.lowerFunction(&fd, "f", false);

    // One "cannot index a value of type '*i64'" diagnostic per bad position.
    // (The two statements carry DISTINCT spans — the diagnostic list
    // deduplicates identical message+span pairs.)
    var count: usize = 0;
    for (diags.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, "cannot index a value of type '*i64'") != null) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "pack spread: expandSpreadArgNodes expands a pack-name spread into index nodes (issue 0156p2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    const span = ast.Span{ .start = 0, .end = 0 };
    var ppc = std.StringHashMap(u32).init(alloc);
    try ppc.put("args", 2);
    lowering.pack_param_count = ppc;

    var pack_id = Node{ .span = span, .data = .{ .identifier = .{ .name = "args" } } };
    var spread = Node{ .span = span, .data = .{ .spread_expr = .{ .operand = &pack_id } } };
    var fixed = Node{ .span = span, .data = .{ .int_literal = .{ .value = 7 } } };
    const call_args = [_]*Node{ &fixed, &spread };

    const expanded = lowering.expandSpreadArgNodes(&call_args) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), expanded.len);
    // fixed arg passes through untouched
    try std.testing.expect(expanded[0] == &fixed);
    // the spread becomes args[0], args[1] index nodes — no spread node survives
    for (expanded[1..], 0..) |n, i| {
        try std.testing.expect(n.data == .index_expr);
        const ie = n.data.index_expr;
        try std.testing.expect(ie.object.data == .identifier);
        try std.testing.expectEqualStrings("args", ie.object.data.identifier.name);
        try std.testing.expect(ie.index.data == .int_literal);
        try std.testing.expectEqual(@as(i64, @intCast(i)), ie.index.data.int_literal.value);
    }
}

test "pack spread: expandSpreadArgNodes returns null when nothing expands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    const span = ast.Span{ .start = 0, .end = 0 };
    // no spread at all
    var fixed = Node{ .span = span, .data = .{ .int_literal = .{ .value = 1 } } };
    const plain = [_]*Node{&fixed};
    try std.testing.expect(lowering.expandSpreadArgNodes(&plain) == null);

    // a spread whose operand is not a pack / tuple / array (unknown scalar
    // literal operand) stays put — null keeps the caller on the diagnostic path
    var scalar = Node{ .span = span, .data = .{ .int_literal = .{ .value = 5 } } };
    var spread = Node{ .span = span, .data = .{ .spread_expr = .{ .operand = &scalar } } };
    const unexp = [_]*Node{&spread};
    try std.testing.expect(lowering.expandSpreadArgNodes(&unexp) == null);
}

test "lower: closure-value call with wrong arity is diagnosed, extras not silently dropped (issue 0188)" {
    // Arena keeps the leak checker quiet — DiagnosticList.addFmt allocates
    // messages it never frees in deinit (mixed ownership with borrowed literals).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    const span = ast.Span{ .start = 0, .end = 0 };

    // f :: (cb: Closure(i64) -> i64) { cb(1, 2); }  — one param, two args.
    var i64_param = Node{ .span = span, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    var i64_ret = Node{ .span = span, .data = .{ .type_expr = .{ .name = "i64", .is_generic = false } } };
    const cb_params = [_]*Node{&i64_param};
    var cb_type = Node{ .span = span, .data = .{ .closure_type_expr = .{ .param_types = &cb_params, .return_type = &i64_ret } } };

    var cb_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "cb" } } };
    var one = Node{ .span = span, .data = .{ .int_literal = .{ .value = 1 } } };
    var two = Node{ .span = span, .data = .{ .int_literal = .{ .value = 2 } } };
    const call_args = [_]*Node{ &one, &two };
    var call = Node{ .span = span, .data = .{ .call = .{ .callee = &cb_ident, .args = &call_args } } };

    const stmts = [_]*Node{&call};
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const params: []const ast.Param = &.{.{ .name = "cb", .name_span = span, .type_expr = &cb_type }};
    const fd = ast.FnDecl{ .name = "f", .params = params, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    // Pre-fix the closure-value call path had no arity check: the extra arg
    // was silently dropped (and a missing arg read garbage). Post-fix the
    // call diagnoses like a top-level fn call (issue 0188).
    lowering.lowerFunction(&fd, "f", false);

    var found = false;
    for (diags.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, "'cb' expects 1 argument, but 2 were given") != null) found = true;
    }
    try std.testing.expect(found);
}

test "type alias: tuple-type alias registers the structural tuple TypeId (issue 0196)" {
    // `NT :: Tuple(a: i64, b: bool)` / `PT :: Tuple(i64, bool)` must land in
    // `type_alias_map` as the STRUCTURAL tuple TypeId (fields + names), not an
    // opaque nominal placeholder — field access (`x.a` / `x.0`) and comptime
    // reflection (`field_count(NT)`) both key off the tuple TypeInfo.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\NT :: Tuple(a: i64, b: bool);
        \\PT :: Tuple(i64, bool);
        \\main :: () {}
        \\
    ;
    const source = try alloc.dupeZ(u8, src);
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);
    try std.testing.expect(!diagnostics.hasErrors());

    // Named alias: 2 fields (i64, bool), names a/b preserved.
    const nt = lowering.program_index.type_alias_map.get("NT").?;
    const nt_info = module.types.get(nt);
    try std.testing.expect(nt_info == .tuple);
    try std.testing.expectEqual(@as(usize, 2), nt_info.tuple.fields.len);
    try std.testing.expectEqual(TypeId.i64, nt_info.tuple.fields[0]);
    try std.testing.expectEqual(TypeId.bool, nt_info.tuple.fields[1]);
    const names = nt_info.tuple.names.?;
    try std.testing.expectEqualStrings("a", module.types.getString(names[0]));
    try std.testing.expectEqualStrings("b", module.types.getString(names[1]));

    // Positional alias: same fields, no names.
    const pt = lowering.program_index.type_alias_map.get("PT").?;
    const pt_info = module.types.get(pt);
    try std.testing.expect(pt_info == .tuple);
    try std.testing.expectEqual(@as(usize, 2), pt_info.tuple.fields.len);
    try std.testing.expect(pt_info.tuple.names == null);
}

test "type alias: pack-spread tuple alias poisons to .unresolved with a diagnostic (issue 0196)" {
    // `Bad :: Tuple(..Ts)` has no pack binding at a top-level alias; the
    // stateless resolver preserves the pack SHAPE as a tuple carrying an
    // `.unresolved` field. Registering that tuple would panic the LLVM
    // `.unresolved` tripwire at emission — it must poison to `.unresolved`
    // with a clean located diagnostic instead.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\Bad :: Tuple(..Ts);
        \\main :: () {}
        \\
    ;
    const source = try alloc.dupeZ(u8, src);
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);

    try std.testing.expectEqual(TypeId.unresolved, lowering.program_index.type_alias_map.get("Bad").?);
    var saw = false;
    for (diagnostics.items.items) |d| {
        if (d.level != .err) continue;
        if (std.mem.indexOf(u8, d.message, "type alias 'Bad' could not be resolved") != null) saw = true;
    }
    try std.testing.expect(saw);
}

test "type alias: tuple element referencing a LATER-declared alias resolves via the deferred fixpoint (issue 0196 review)" {
    // `A :: Tuple(a: B, c: bool); B :: i64;` — eager in-loop resolution would
    // mint a permanent empty-struct stub under `B` (aliases never adopt
    // stubs), silently corrupting the layout. The deferred fixpoint registers
    // A only after B is known, so the element binds the real i64.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\A :: Tuple(a: B, c: bool);
        \\B :: i64;
        \\main :: () {}
        \\
    ;
    const source = try alloc.dupeZ(u8, src);
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.main_file = "test.sx";
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);
    try std.testing.expect(!diagnostics.hasErrors());

    const a = lowering.program_index.type_alias_map.get("A").?;
    const a_info = module.types.get(a);
    try std.testing.expect(a_info == .tuple);
    try std.testing.expectEqual(@as(usize, 2), a_info.tuple.fields.len);
    try std.testing.expectEqual(TypeId.i64, a_info.tuple.fields[0]); // NOT a stub
    try std.testing.expectEqual(TypeId.bool, a_info.tuple.fields[1]);
}

test "type alias: tuple alias referenced ABOVE its declaration diagnoses instead of an LLVM dump (issue 0196 review)" {
    // `use_it :: (t: NT) …` above `NT :: Tuple(…)`: the fn signature resolves
    // eagerly at scan and binds a stub that no alias registration ever adopts
    // — previously an LLVM "call parameter type mismatch" verifier dump. Must
    // be a clean located diagnostic at the alias decl.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\use_it :: (t: NT) -> i64 { return t.a; }
        \\NT :: Tuple(a: i64, b: bool);
        \\main :: () {}
        \\
    ;
    const source = try alloc.dupeZ(u8, src);
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.main_file = "test.sx";
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);

    var saw = false;
    for (diagnostics.items.items) |d| {
        if (d.level != .err) continue;
        if (std.mem.indexOf(u8, d.message, "tuple alias 'NT' is referenced above its declaration") != null) saw = true;
    }
    try std.testing.expect(saw);
}

test "type alias: mutually-recursive tuple aliases diagnose a reference cycle and poison (issue 0196 review)" {
    // `T1 :: Tuple(a: T2); T2 :: Tuple(b: T1);` can never converge — resolving
    // either member would mint a stub of its peer that the unresolved-check
    // cannot tell from a real empty struct. Both must poison with the cycle
    // diagnostic, never register a lying layout.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\T1 :: Tuple(a: T2);
        \\T2 :: Tuple(b: T1);
        \\main :: () {}
        \\
    ;
    const source = try alloc.dupeZ(u8, src);
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.main_file = "test.sx";
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);

    try std.testing.expectEqual(TypeId.unresolved, lowering.program_index.type_alias_map.get("T1").?);
    try std.testing.expectEqual(TypeId.unresolved, lowering.program_index.type_alias_map.get("T2").?);
    var cycle_count: usize = 0;
    for (diagnostics.items.items) |d| {
        if (d.level != .err) continue;
        if (std.mem.indexOf(u8, d.message, "composite-alias reference cycle") != null) cycle_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), cycle_count);
}

test "type alias: array element referencing a LATER-declared alias resolves via the deferred fixpoint (issue 0230)" {
    // `A :: [2]B; B :: i64;` — eager in-loop resolution would mint a permanent
    // empty-struct stub under `B` (aliases never adopt stubs), silently
    // registering a size-0 element layout. The deferred composite-alias
    // fixpoint registers A only after B is known, so the element binds i64.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\A :: [2]B;
        \\B :: i64;
        \\main :: () {}
        \\
    ;
    const source = try alloc.dupeZ(u8, src);
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.main_file = "test.sx";
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);
    try std.testing.expect(!diagnostics.hasErrors());

    const a = lowering.program_index.type_alias_map.get("A").?;
    const a_info = module.types.get(a);
    try std.testing.expect(a_info == .array);
    try std.testing.expectEqual(@as(u32, 2), a_info.array.length);
    try std.testing.expectEqual(TypeId.i64, a_info.array.element); // NOT a stub
}

test "type alias: forward composite elements across all shapes adopt the real element type (issue 0230)" {
    // The deferred composite-alias fixpoint, generalized to every kind. Each
    // alias' element is declared LATER; the eager path would mint a permanent
    // size-0 empty-struct stub for it. The fixpoint adopts the real i64
    // element/pointee/param in all shapes — array / slice / optional / pointer
    // / function.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\ArrL :: [2]B;
        \\SliceL :: []B;
        \\OptL :: ?B;
        \\PtrL :: *B;
        \\FnL  :: (B) -> B;
        \\B :: i64;
        \\main :: () {}
        \\
    ;
    const source = try alloc.dupeZ(u8, src);
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.main_file = "test.sx";
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);
    try std.testing.expect(!diagnostics.hasErrors());

    const arr = module.types.get(lowering.program_index.type_alias_map.get("ArrL").?);
    try std.testing.expect(arr == .array);
    try std.testing.expectEqual(TypeId.i64, arr.array.element); // NOT a stub

    const sl = module.types.get(lowering.program_index.type_alias_map.get("SliceL").?);
    try std.testing.expect(sl == .slice);
    try std.testing.expectEqual(TypeId.i64, sl.slice.element);

    const opt = module.types.get(lowering.program_index.type_alias_map.get("OptL").?);
    try std.testing.expect(opt == .optional);
    try std.testing.expectEqual(TypeId.i64, opt.optional.child);

    const ptr = module.types.get(lowering.program_index.type_alias_map.get("PtrL").?);
    try std.testing.expect(ptr == .pointer);
    try std.testing.expectEqual(TypeId.i64, ptr.pointer.pointee);

    const fnl = module.types.get(lowering.program_index.type_alias_map.get("FnL").?);
    try std.testing.expect(fnl == .function);
    try std.testing.expectEqual(TypeId.i64, fnl.function.params[0]);
    try std.testing.expectEqual(TypeId.i64, fnl.function.ret);
}

test "type alias: generic-instantiation element in a composite RHS instantiates for real (issue 0230)" {
    // `AL :: [2]Box(i64);` must instantiate the generic element for real — a
    // non-empty struct with a real size — NOT an empty size-0 nominal with a
    // lying size_of (which the eager stateless composite path used to mint).
    // Uses a locally-declared generic so the bare-lower harness needs no std.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\Box :: struct($T: Type) { value: T; }
        \\AL :: [2]Box(i64);
        \\main :: () {}
        \\
    ;
    const source = try alloc.dupeZ(u8, src);
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.main_file = "test.sx";
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);
    try std.testing.expect(!diagnostics.hasErrors());

    const al = lowering.program_index.type_alias_map.get("AL").?;
    const al_info = module.types.get(al);
    try std.testing.expect(al_info == .array);
    try std.testing.expectEqual(@as(u32, 2), al_info.array.length);
    // The element is a real, non-empty instantiated struct (Box(i64) holds an
    // i64), not a size-0 stub.
    const elem_size = module.types.sizeOf(al_info.array.element);
    try std.testing.expect(elem_size >= 8);
}

test "type alias: function-alias with a pointer to a LATER-declared nominal resolves (issue 0230)" {
    // `H :: (rc: *Ctx) -> void; Ctx :: struct {...}` — a pointer to a forward
    // nominal is a well-formed pointer regardless of pointee completeness, so
    // the function alias must resolve to a real function type (the stdlib http
    // `RouteHandler :: (rc: *RouteCtx) -> void` forward-field pattern), not a
    // deferred-then-stubbed value.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\H :: (rc: *Ctx) -> void;
        \\Ctx :: struct { x: i64; }
        \\main :: () {}
        \\
    ;
    const source = try alloc.dupeZ(u8, src);
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;

    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diagnostics = errors.DiagnosticList.init(alloc, source, "test.sx");
    var lowering = Lowering.init(&module);
    lowering.main_file = "test.sx";
    lowering.diagnostics = &diagnostics;
    lowering.lowerRoot(root);
    try std.testing.expect(!diagnostics.hasErrors());

    const h = lowering.program_index.type_alias_map.get("H").?;
    const h_info = module.types.get(h);
    try std.testing.expect(h_info == .function);
    try std.testing.expectEqual(@as(usize, 1), h_info.function.params.len);
    // The single param is a pointer (to the eventually-registered Ctx).
    const p0 = module.types.get(h_info.function.params[0]);
    try std.testing.expect(p0 == .pointer);
}

test "lower: assignment to a by-value loop capture is diagnosed as immutable, a real local is not (issue 0219)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    const span = ast.Span{ .start = 0, .end = 0 };

    // main :: () {
    //     for 0..3 (x) { x += 100; }   // by-value capture → immutable, diagnosed
    //     y := 0;                       // real alloca local
    //     y += 100;                     // legal — NOT diagnosed
    // }
    // The capture `x` is a non-alloca scope binding with no store path
    // (a per-iteration read-only alias). Pre-fix the compound store fell
    // through to a silent no-op — it reached neither a container nor the
    // capture's own copy (issue 0219). Post-fix it emits an "immutable
    // capture" error; the mutation of the ordinary `y` local stays clean.
    var zero = Node{ .span = span, .data = .{ .int_literal = .{ .value = 0 } } };
    var three = Node{ .span = span, .data = .{ .int_literal = .{ .value = 3 } } };
    const iterables = [_]ast.ForIterable{
        .{ .expr = &zero, .range_end = &three, .is_range = true },
    };
    const captures = [_]ast.ForCapture{
        .{ .name = "x", .span = span, .by_ref = false },
    };
    // body: { x += 100; }
    var x_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "x" } } };
    var hundred = Node{ .span = span, .data = .{ .int_literal = .{ .value = 100 } } };
    var x_bump = Node{ .span = span, .data = .{ .assignment = .{ .target = &x_ident, .op = .add_assign, .value = &hundred } } };
    const body_stmts = [_]*Node{&x_bump};
    var for_body = Node{ .span = span, .data = .{ .block = .{ .stmts = &body_stmts } } };
    var for_expr = Node{ .span = span, .data = .{ .for_expr = .{ .iterables = @constCast(&iterables), .captures = @constCast(&captures), .body = &for_body } } };

    // y := 0; y += 100;  (control: a real local mutates freely)
    var zero2 = Node{ .span = span, .data = .{ .int_literal = .{ .value = 0 } } };
    var y_decl = Node{ .span = span, .data = .{ .var_decl = .{ .name = "y", .name_span = span, .type_annotation = null, .value = &zero2 } } };
    var y_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "y" } } };
    var hundred2 = Node{ .span = span, .data = .{ .int_literal = .{ .value = 100 } } };
    var y_bump = Node{ .span = span, .data = .{ .assignment = .{ .target = &y_ident, .op = .add_assign, .value = &hundred2 } } };

    const stmts = [_]*Node{ &for_expr, &y_decl, &y_bump };
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const fd = ast.FnDecl{ .name = "main", .params = &.{}, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    lowering.lowerFunction(&fd, "main", false);

    var found_immutable = false;
    for (diags.items.items) |d| {
        if (d.level != .err) continue;
        if (std.mem.indexOf(u8, d.message, "cannot assign to immutable capture 'x'") != null) found_immutable = true;
        // The ordinary `y` local must NEVER be flagged — it is a real slot.
        try std.testing.expect(std.mem.indexOf(u8, d.message, "capture 'y'") == null);
    }
    try std.testing.expect(found_immutable);
}

test "lower: assignment to a function-local '::' const gets the constant message, not the capture one (0219 review fold)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();

    const span = ast.Span{ .start = 0, .end = 0 };

    // main :: () { c :: 5; c = 10; }
    // A function-local `::` const binds non-alloca (lowerConstDecl), so the
    // assignment lands in the same nonstore_binding arm as captures. It must
    // get the CONSTANT-family message — the capture wording ("capture by
    // reference with '(*c)'") is nonsense for a const. Pre-0219 the store was
    // silently dropped, same as the capture shapes.
    var five = Node{ .span = span, .data = .{ .int_literal = .{ .value = 5 } } };
    var c_decl = Node{ .span = span, .data = .{ .const_decl = .{ .name = "c", .name_span = span, .type_annotation = null, .value = &five, .is_raw = false } } };
    var c_ident = Node{ .span = span, .data = .{ .identifier = .{ .name = "c" } } };
    var ten = Node{ .span = span, .data = .{ .int_literal = .{ .value = 10 } } };
    var c_assign = Node{ .span = span, .data = .{ .assignment = .{ .target = &c_ident, .op = .assign, .value = &ten } } };

    const stmts = [_]*Node{ &c_decl, &c_assign };
    var body = Node{ .span = span, .data = .{ .block = .{ .stmts = &stmts } } };
    const fd = ast.FnDecl{ .name = "main", .params = &.{}, .return_type = null, .body = &body };

    var lowering = Lowering.init(&module);
    lowering.diagnostics = &diags;
    lowering.lowerFunction(&fd, "main", false);

    var found_const = false;
    for (diags.items.items) |d| {
        if (d.level != .err) continue;
        if (std.mem.indexOf(u8, d.message, "cannot assign to constant 'c'") != null) found_const = true;
        // The capture wording must NOT appear for a const.
        try std.testing.expect(std.mem.indexOf(u8, d.message, "immutable capture") == null);
    }
    try std.testing.expect(found_const);
}
