// Tests for module.zig
const std = @import("std");
const types = @import("types.zig");
const inst_mod = @import("inst.zig");
const mod_mod = @import("module.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const BlockId = inst_mod.BlockId;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;
const GlobalId = inst_mod.GlobalId;
const Module = mod_mod.Module;
const Builder = mod_mod.Builder;

test "Builder: build add(a: i64, b: i64) -> i64" {
    const alloc = std.testing.allocator;
    var mod = Module.init(alloc);
    defer mod.deinit();

    var b = Builder.init(&mod);

    const name_add = mod.types.internString("add");
    const name_a = mod.types.internString("a");
    const name_b = mod.types.internString("b");
    const name_entry = mod.types.internString("entry");

    const params = &[_]Function.Param{
        .{ .name = name_a, .ty = .i64 },
        .{ .name = name_b, .ty = .i64 },
    };
    const func_id = b.beginFunction(name_add, params, .i64);

    const entry = b.appendBlock(name_entry, &.{});
    b.switchToBlock(entry);

    // Load params (in real lowering, params are block params of entry)
    const a_ref = b.constInt(0, .i64); // placeholder for param a
    const b_ref = b.constInt(0, .i64); // placeholder for param b
    const sum = b.add(a_ref, b_ref, .i64);
    b.ret(sum, .i64);

    b.finalize();

    // Verify
    const func = mod.getFunction(func_id);
    try std.testing.expectEqual(@as(usize, 2), func.params.len);
    try std.testing.expectEqual(TypeId.i64, func.ret);
    try std.testing.expectEqual(@as(usize, 1), func.blocks.items.len);

    const blk = &func.blocks.items[0];
    try std.testing.expectEqual(@as(usize, 4), blk.insts.items.len); // 2 consts + add + ret
}

test "Builder: conditional branch" {
    const alloc = std.testing.allocator;
    var mod = Module.init(alloc);
    defer mod.deinit();

    var b = Builder.init(&mod);

    const name_fn = mod.types.internString("test_fn");
    const name_entry = mod.types.internString("entry");
    const name_then = mod.types.internString("then");
    const name_else = mod.types.internString("else");
    const name_merge = mod.types.internString("merge");

    _ = b.beginFunction(name_fn, &.{}, .i32);

    const entry = b.appendBlock(name_entry, &.{});
    const then_bb = b.appendBlock(name_then, &.{});
    const else_bb = b.appendBlock(name_else, &.{});
    const merge_bb = b.appendBlock(name_merge, &[_]TypeId{.i32});

    b.switchToBlock(entry);
    const cond = b.constBool(true);
    b.condBr(cond, then_bb, &.{}, else_bb, &.{});

    b.switchToBlock(then_bb);
    const v1 = b.constInt(42, .i32);
    b.br(merge_bb, &.{v1});

    b.switchToBlock(else_bb);
    const v2 = b.constInt(0, .i32);
    b.br(merge_bb, &.{v2});

    b.switchToBlock(merge_bb);
    const result = b.emit(.{ .block_param = .{ .block = merge_bb, .param_index = 0 } }, .i32);
    b.ret(result, .i32);

    b.finalize();

    // Verify: 4 blocks, correct instruction counts
    const func = mod.getFunction(@enumFromInt(0));
    try std.testing.expectEqual(@as(usize, 4), func.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 2), func.blocks.items[0].insts.items.len); // const_bool + cond_br
    try std.testing.expectEqual(@as(usize, 2), func.blocks.items[1].insts.items.len); // const_int + br
    try std.testing.expectEqual(@as(usize, 2), func.blocks.items[2].insts.items.len); // const_int + br
    try std.testing.expectEqual(@as(usize, 2), func.blocks.items[3].insts.items.len); // block_param + ret
}

test "Module: globals" {
    const alloc = std.testing.allocator;
    var mod = Module.init(alloc);
    defer mod.deinit();

    const name = mod.types.internString("counter");
    const id = mod.addGlobal(.{
        .name = name,
        .ty = .i32,
        .init_val = .{ .int = 0 },
    });

    try std.testing.expectEqual(GlobalId.fromIndex(0), id);
    try std.testing.expectEqual(TypeId.i32, mod.globals.items[0].ty);
}

test "Builder.constFloatInfo reads a const_float back, null for non-floats" {
    const alloc = std.testing.allocator;
    var mod = Module.init(alloc);
    defer mod.deinit();

    var b = Builder.init(&mod);
    const name = mod.types.internString("f");
    const entry_name = mod.types.internString("entry");
    _ = b.beginFunction(name, &.{}, .void);
    const entry = b.appendBlock(entry_name, &.{});
    b.switchToBlock(entry);

    // A const_float reads back its value (the implicit float→int rule consults
    // this to fold an integral literal / locate a non-integral one).
    const fref = b.constFloat(4.0, .f64);
    const info = b.constFloatInfo(fref) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 4.0), info.value);

    // A non-float instruction is not a const_float — null.
    const iref = b.constInt(7, .i64);
    try std.testing.expect(b.constFloatInfo(iref) == null);

    b.finalize();
}

test "Builder.getRefOp returns the defining op, null for params/out-of-range" {
    const alloc = std.testing.allocator;
    var mod = Module.init(alloc);
    defer mod.deinit();

    var b = Builder.init(&mod);
    const name = mod.types.internString("f");
    const entry_name = mod.types.internString("entry");
    const param_name = mod.types.internString("p");
    _ = b.beginFunction(name, &[_]Function.Param{.{ .name = param_name, .ty = .i64 }}, .void);
    const entry = b.appendBlock(entry_name, &.{});
    b.switchToBlock(entry);

    // A load's defining op carries the pointer it read through — the
    // protocol-erasure borrow derives its address from this instead of
    // re-lowering (and re-evaluating) the operand AST (issue 0214).
    const slot = b.alloca(.i64);
    const loaded = b.load(slot, .i64);
    const op = b.getRefOp(loaded) orelse return error.TestUnexpectedResult;
    try std.testing.expect(op == .load);
    try std.testing.expectEqual(slot, op.load.operand);

    // A function parameter has no defining instruction.
    try std.testing.expect(b.getRefOp(Ref.fromIndex(0)) == null);
    // An out-of-range ref has none either.
    try std.testing.expect(b.getRefOp(Ref.fromIndex(9999)) == null);

    b.finalize();
}
