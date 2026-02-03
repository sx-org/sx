// Tests for inst.zig

const std = @import("std");
const types = @import("types.zig");
const inst_mod = @import("inst.zig");

const Ref = inst_mod.Ref;
const BlockId = inst_mod.BlockId;
const FuncId = inst_mod.FuncId;
const Inst = inst_mod.Inst;
const Block = inst_mod.Block;
const Function = inst_mod.Function;
const InlineAsm = inst_mod.InlineAsm;
const StringId = types.StringId;

test "Ref none sentinel" {
    try std.testing.expect(Ref.none.isNone());
    try std.testing.expect(!Ref.fromIndex(0).isNone());
}

test "basic instruction creation" {
    const inst = Inst{
        .op = .{ .add = .{ .lhs = Ref.fromIndex(0), .rhs = Ref.fromIndex(1) } },
        .ty = .i32,
    };
    try std.testing.expectEqual(types.TypeId.i32, inst.ty);
    switch (inst.op) {
        .add => |bin| {
            try std.testing.expectEqual(Ref.fromIndex(0), bin.lhs);
            try std.testing.expectEqual(Ref.fromIndex(1), bin.rhs);
        },
        else => unreachable,
    }
}

test "block creation" {
    const alloc = std.testing.allocator;
    var block = Block.init(@enumFromInt(1), &.{});
    defer block.deinit(alloc);

    block.insts.append(alloc, .{
        .op = .{ .const_int = 42 },
        .ty = .i64,
    }) catch unreachable;
    block.insts.append(alloc, .{
        .op = .{ .ret = .{ .operand = Ref.fromIndex(0) } },
        .ty = .i64,
    }) catch unreachable;

    try std.testing.expectEqual(@as(usize, 2), block.insts.items.len);
}

test "inline_asm op shape (ASM stream Phase C.0)" {
    // out_value (yields the value, operand = .none) + a named-less input,
    // plus two clobbers; result rides on Inst.ty.
    const operands = [_]InlineAsm.AsmOperand{
        .{ .role = .out_value, .name = @enumFromInt(1), .constraint = @enumFromInt(2), .operand = Ref.none },
        .{ .role = .input, .name = .empty, .constraint = @enumFromInt(3), .operand = Ref.fromIndex(5) },
    };
    const clobbers = [_]StringId{ @enumFromInt(4), @enumFromInt(6) };
    const inst = Inst{
        .op = .{ .inline_asm = .{
            .template = @enumFromInt(10),
            .operands = &operands,
            .clobbers = &clobbers,
            .has_side_effects = true,
        } },
        .ty = .i64,
    };
    switch (inst.op) {
        .inline_asm => |a| {
            try std.testing.expect(a.has_side_effects);
            try std.testing.expectEqual(@as(usize, 2), a.operands.len);
            try std.testing.expectEqual(@as(usize, 2), a.clobbers.len);
            try std.testing.expectEqual(InlineAsm.AsmOperand.Role.out_value, a.operands[0].role);
            // an out_value operand carries no input Ref — the asm yields it
            try std.testing.expect(a.operands[0].operand.isNone());
            try std.testing.expectEqual(InlineAsm.AsmOperand.Role.input, a.operands[1].role);
            try std.testing.expectEqual(Ref.fromIndex(5), a.operands[1].operand);
            // an anonymous operand uses the `.empty` StringId sentinel
            try std.testing.expectEqual(StringId.empty, a.operands[1].name);
        },
        else => unreachable,
    }
}

test "function creation" {
    const alloc = std.testing.allocator;
    const params = &[_]Function.Param{
        .{ .name = @enumFromInt(1), .ty = .i32 },
        .{ .name = @enumFromInt(2), .ty = .i32 },
    };
    var func = Function.init(@enumFromInt(3), params, .i64);
    defer func.deinit(alloc);

    try std.testing.expectEqual(types.TypeId.i64, func.ret);
    try std.testing.expectEqual(@as(usize, 2), func.params.len);
}
