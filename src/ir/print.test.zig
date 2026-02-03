// Tests for print.zig
const std = @import("std");
const types = @import("types.zig");
const inst_mod = @import("inst.zig");
const mod_mod = @import("module.zig");
const print_mod = @import("print.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const BlockId = inst_mod.BlockId;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;
const Module = mod_mod.Module;
const Builder = mod_mod.Builder;

test "print simple add function" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    const name_add = module.types.internString("add");
    const name_a = module.types.internString("a");
    const name_b = module.types.internString("b");
    const name_entry = module.types.internString("entry");

    const params = &[_]Function.Param{
        .{ .name = name_a, .ty = .i64 },
        .{ .name = name_b, .ty = .i64 },
    };
    _ = b.beginFunction(name_add, params, .i64);
    const entry = b.appendBlock(name_entry, &.{});
    b.switchToBlock(entry);

    const a_ref = b.constInt(10, .i64);
    const b_ref = b.constInt(20, .i64);
    const sum = b.add(a_ref, b_ref, .i64);
    b.ret(sum, .i64);
    b.finalize();

    var aw = std.Io.Writer.Allocating.init(alloc);
    try print_mod.printModule(&module, &aw.writer);
    var result = aw.writer.toArrayList();
    defer result.deinit(alloc);

    const output = result.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "func @add(a: i64, b: i64) -> i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "entry:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const 10 : i64") != null);
    // Params occupy value slots %0/%1, so the two consts are %2/%3 and their sum %4.
    try std.testing.expect(std.mem.indexOf(u8, output, "add %2, %3 : i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ret %4") != null);
}

test "print conditional branch" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    _ = b.beginFunction(module.types.internString("test"), &.{}, .i32);
    const entry = b.appendBlock(module.types.internString("entry"), &.{});
    const then_bb = b.appendBlock(module.types.internString("then"), &.{});
    const else_bb = b.appendBlock(module.types.internString("else"), &.{});

    b.switchToBlock(entry);
    const cond = b.constBool(true);
    b.condBr(cond, then_bb, &.{}, else_bb, &.{});

    b.switchToBlock(then_bb);
    const v1 = b.constInt(1, .i32);
    b.ret(v1, .i32);

    b.switchToBlock(else_bb);
    const v2 = b.constInt(0, .i32);
    b.ret(v2, .i32);
    b.finalize();

    var aw = std.Io.Writer.Allocating.init(alloc);
    try print_mod.printModule(&module, &aw.writer);
    var result = aw.writer.toArrayList();
    defer result.deinit(alloc);

    const output = result.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "cond_br %0, bb1, bb2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "then:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "else:") != null);
}
