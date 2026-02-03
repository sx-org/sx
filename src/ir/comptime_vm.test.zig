// Tests for the byte-addressable comptime machine (Phase 1 of PLAN-COMPILER-VM.md).

const std = @import("std");
const vm = @import("comptime_vm.zig");
const inst_mod = @import("inst.zig");
const types = @import("types.zig");
const Inst = inst_mod.Inst;
const Op = inst_mod.Op;
const Ref = inst_mod.Ref;
const BlockId = inst_mod.BlockId;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;
const Block = inst_mod.Block;
const Module = @import("module.zig").Module;
const Value = @import("comptime_value.zig").Value;
const TypeId = types.TypeId;

const dummy: types.StringId = @enumFromInt(0);

fn ref(i: u32) Ref {
    return Ref.fromIndex(i);
}
fn param(ty: TypeId) Function.Param {
    return .{ .name = dummy, .ty = ty };
}
fn inst(op: Op, ty: TypeId) Inst {
    return .{ .op = op, .ty = ty };
}
fn fromI64(v: i64) vm.Reg {
    return @bitCast(v);
}
fn toI64(w: vm.Reg) i64 {
    return @bitCast(w);
}
fn fromF64(v: f64) vm.Reg {
    return @bitCast(v);
}
fn toF64(w: vm.Reg) f64 {
    return @bitCast(w);
}

/// Minimal hand-builder for tiny IR functions. Blocks MUST be fully populated in
/// order (a block's `first_ref` is fixed at creation from the running ref count),
/// and branch targets reference block indices (0,1,2,…) which are sequential.
const Fb = struct {
    alloc: std.mem.Allocator,
    func: Function,
    next_ref: u32,

    fn init(alloc: std.mem.Allocator, params: []const Function.Param, ret: TypeId) Fb {
        return .{ .alloc = alloc, .func = Function.init(dummy, params, ret), .next_ref = @intCast(params.len) };
    }
    fn deinit(self: *Fb) void {
        self.func.deinit(self.alloc);
    }
    /// Create a block (with `bparams` block-parameter types); returns its index.
    fn block(self: *Fb, bparams: []const TypeId) u32 {
        var blk = Block.init(dummy, bparams);
        blk.first_ref = self.next_ref;
        self.func.blocks.append(self.alloc, blk) catch @panic("OOM");
        return @intCast(self.func.blocks.items.len - 1);
    }
    /// Append an instruction to block `b`; returns the Ref index of its result.
    fn add(self: *Fb, b: u32, i: Inst) u32 {
        self.func.blocks.items[b].insts.append(self.alloc, i) catch @panic("OOM");
        const r = self.next_ref;
        self.next_ref += 1;
        return r;
    }
};

test "comptime_vm exec: integer add of two params" {
    const params = [_]Function.Param{ param(.i64), param(.i64) };
    var fb = Fb.init(std.testing.allocator, &params, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const sum = fb.add(b0, inst(.{ .add = .{ .lhs = ref(0), .rhs = ref(1) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(sum) } }, .void));

    var v = vm.Vm.init(std.testing.allocator);
    defer v.deinit();
    const out = try v.run(&fb.func, &.{ fromI64(3), fromI64(40) });
    try std.testing.expectEqual(@as(i64, 43), toI64(out));
}

test "comptime_vm exec: f64 arithmetic (a*2.0 + 1.0)" {
    const params = [_]Function.Param{param(.f64)};
    var fb = Fb.init(std.testing.allocator, &params, .f64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const two = fb.add(b0, inst(.{ .const_float = 2.0 }, .f64));
    const prod = fb.add(b0, inst(.{ .mul = .{ .lhs = ref(0), .rhs = ref(two) } }, .f64));
    const one = fb.add(b0, inst(.{ .const_float = 1.0 }, .f64));
    const res = fb.add(b0, inst(.{ .add = .{ .lhs = ref(prod), .rhs = ref(one) } }, .f64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(res) } }, .void));

    var v = vm.Vm.init(std.testing.allocator);
    defer v.deinit();
    const out = try v.run(&fb.func, &.{fromF64(3.0)});
    try std.testing.expectEqual(@as(f64, 7.0), toF64(out));
}

test "comptime_vm exec: comparison + cond_br selects a branch" {
    // f(a) = if a < 10 then 100 else 200
    const params = [_]Function.Param{param(.i64)};
    var fb = Fb.init(std.testing.allocator, &params, .i64);
    defer fb.deinit();

    const b0 = fb.block(&.{});
    const ten = fb.add(b0, inst(.{ .const_int = 10 }, .i64));
    const c = fb.add(b0, inst(.{ .cmp_lt = .{ .lhs = ref(0), .rhs = ref(ten) } }, .bool));
    _ = fb.add(b0, inst(.{ .cond_br = .{ .cond = ref(c), .then_target = BlockId.fromIndex(1), .then_args = &.{}, .else_target = BlockId.fromIndex(2), .else_args = &.{} } }, .void));

    const b1 = fb.block(&.{});
    const x = fb.add(b1, inst(.{ .const_int = 100 }, .i64));
    _ = fb.add(b1, inst(.{ .ret = .{ .operand = ref(x) } }, .void));

    const b2 = fb.block(&.{});
    const y = fb.add(b2, inst(.{ .const_int = 200 }, .i64));
    _ = fb.add(b2, inst(.{ .ret = .{ .operand = ref(y) } }, .void));

    var v = vm.Vm.init(std.testing.allocator);
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 100), toI64(try v.run(&fb.func, &.{fromI64(5)})));
    try std.testing.expectEqual(@as(i64, 200), toI64(try v.run(&fb.func, &.{fromI64(15)})));
}

test "comptime_vm exec: loop with block params sums i..1" {
    // sum=0; i=n; while i>0 { sum+=i; i-=1 } return sum   →  n*(n+1)/2
    const params = [_]Function.Param{param(.i64)};
    var fb = Fb.init(std.testing.allocator, &params, .i64);
    defer fb.deinit();
    const loop_p = [_]TypeId{ .i64, .i64 }; // (sum, i)
    const exit_p = [_]TypeId{.i64}; // (sum)

    // b0 entry: br b1(0, n)
    const b0 = fb.block(&.{});
    const zero = fb.add(b0, inst(.{ .const_int = 0 }, .i64));
    _ = fb.add(b0, inst(.{ .br = .{ .target = BlockId.fromIndex(1), .args = &.{ ref(zero), ref(0) } } }, .void));

    // b1 header(sum, i): if i>0 -> b2(sum,i) else b3(sum)
    const b1 = fb.block(&loop_p);
    const sum_h = fb.add(b1, inst(.{ .block_param = .{ .block = BlockId.fromIndex(1), .param_index = 0 } }, .i64));
    const i_h = fb.add(b1, inst(.{ .block_param = .{ .block = BlockId.fromIndex(1), .param_index = 1 } }, .i64));
    const z2 = fb.add(b1, inst(.{ .const_int = 0 }, .i64));
    const cond = fb.add(b1, inst(.{ .cmp_gt = .{ .lhs = ref(i_h), .rhs = ref(z2) } }, .bool));
    _ = fb.add(b1, inst(.{ .cond_br = .{ .cond = ref(cond), .then_target = BlockId.fromIndex(2), .then_args = &.{ ref(sum_h), ref(i_h) }, .else_target = BlockId.fromIndex(3), .else_args = &.{ref(sum_h)} } }, .void));

    // b2 body(sum, i): br b1(sum+i, i-1)
    const b2 = fb.block(&loop_p);
    const sum_b = fb.add(b2, inst(.{ .block_param = .{ .block = BlockId.fromIndex(2), .param_index = 0 } }, .i64));
    const i_b = fb.add(b2, inst(.{ .block_param = .{ .block = BlockId.fromIndex(2), .param_index = 1 } }, .i64));
    const ns = fb.add(b2, inst(.{ .add = .{ .lhs = ref(sum_b), .rhs = ref(i_b) } }, .i64));
    const one = fb.add(b2, inst(.{ .const_int = 1 }, .i64));
    const ni = fb.add(b2, inst(.{ .sub = .{ .lhs = ref(i_b), .rhs = ref(one) } }, .i64));
    _ = fb.add(b2, inst(.{ .br = .{ .target = BlockId.fromIndex(1), .args = &.{ ref(ns), ref(ni) } } }, .void));

    // b3 exit(sum): ret sum
    const b3 = fb.block(&exit_p);
    const sum_e = fb.add(b3, inst(.{ .block_param = .{ .block = BlockId.fromIndex(3), .param_index = 0 } }, .i64));
    _ = fb.add(b3, inst(.{ .ret = .{ .operand = ref(sum_e) } }, .void));

    var v = vm.Vm.init(std.testing.allocator);
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 15), toI64(try v.run(&fb.func, &.{fromI64(5)}))); // 5+4+3+2+1
    try std.testing.expectEqual(@as(i64, 55), toI64(try v.run(&fb.func, &.{fromI64(10)})));
    try std.testing.expectEqual(@as(i64, 0), toI64(try v.run(&fb.func, &.{fromI64(0)})));
}

test "comptime_vm exec: nested value-merge threads inner if value (issue 0259)" {
    // f(a, b) = if a { 100 } else { if b { 42 } else { 0 } }
    // The correct IR (what lowering now emits for both #run forms) chains two
    // value-merge blocks: the OUTER merge's else-edge value IS the INNER merge's
    // block_param result. The VM must thread that inner phi word into the outer
    // phi — the shape the issue-0259 lowering fix relies on being interpreted
    // faithfully. a=false, b=true must yield 42 (not the outer else-const 0).
    const params = [_]Function.Param{ param(.bool), param(.bool) };
    var fb = Fb.init(std.testing.allocator, &params, .i64);
    defer fb.deinit();
    const mp = [_]TypeId{.i64};

    // b0 entry: if a -> b1(then) else b2(outer-else)
    const b0 = fb.block(&.{});
    _ = fb.add(b0, inst(.{ .cond_br = .{ .cond = ref(0), .then_target = BlockId.fromIndex(1), .then_args = &.{}, .else_target = BlockId.fromIndex(2), .else_args = &.{} } }, .void));

    // b1 outer-then: br outer.merge(100)
    const b1 = fb.block(&.{});
    const c100 = fb.add(b1, inst(.{ .const_int = 100 }, .i64));
    _ = fb.add(b1, inst(.{ .br = .{ .target = BlockId.fromIndex(3), .args = &.{ref(c100)} } }, .void));

    // b2 outer-else: if b -> b4(inner-then) else b5(inner-else)
    const b2 = fb.block(&.{});
    _ = fb.add(b2, inst(.{ .cond_br = .{ .cond = ref(1), .then_target = BlockId.fromIndex(4), .then_args = &.{}, .else_target = BlockId.fromIndex(5), .else_args = &.{} } }, .void));

    // b3 outer.merge(v): ret v   (v is 100 or the inner-merge word)
    const b3 = fb.block(&mp);
    const ov = fb.add(b3, inst(.{ .block_param = .{ .block = BlockId.fromIndex(3), .param_index = 0 } }, .i64));
    _ = fb.add(b3, inst(.{ .ret = .{ .operand = ref(ov) } }, .void));

    // b4 inner-then: br inner.merge(42)
    const b4 = fb.block(&.{});
    const c42 = fb.add(b4, inst(.{ .const_int = 42 }, .i64));
    _ = fb.add(b4, inst(.{ .br = .{ .target = BlockId.fromIndex(6), .args = &.{ref(c42)} } }, .void));

    // b5 inner-else: br inner.merge(0)
    const b5 = fb.block(&.{});
    const c0 = fb.add(b5, inst(.{ .const_int = 0 }, .i64));
    _ = fb.add(b5, inst(.{ .br = .{ .target = BlockId.fromIndex(6), .args = &.{ref(c0)} } }, .void));

    // b6 inner.merge(iv): br outer.merge(iv)
    const b6 = fb.block(&mp);
    const iv = fb.add(b6, inst(.{ .block_param = .{ .block = BlockId.fromIndex(6), .param_index = 0 } }, .i64));
    _ = fb.add(b6, inst(.{ .br = .{ .target = BlockId.fromIndex(3), .args = &.{ref(iv)} } }, .void));

    var v = vm.Vm.init(std.testing.allocator);
    defer v.deinit();
    const T = fromI64(1);
    const F = fromI64(0);
    try std.testing.expectEqual(@as(i64, 100), toI64(try v.run(&fb.func, &.{ T, F }))); // a=true
    try std.testing.expectEqual(@as(i64, 42), toI64(try v.run(&fb.func, &.{ F, T }))); // a=false,b=true
    try std.testing.expectEqual(@as(i64, 0), toI64(try v.run(&fb.func, &.{ F, F }))); // a=false,b=false
}

test "comptime_vm exec: struct_init + struct_get round-trips a flat struct" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    // Point :: struct { x: i64, y: i64 }
    const pfields = [_]types.TypeInfo.StructInfo.Field{
        .{ .name = table.internString("x"), .ty = .i64 },
        .{ .name = table.internString("y"), .ty = .i64 },
    };
    const point = table.intern(.{ .@"struct" = .{ .name = table.internString("Point"), .fields = &pfields } });

    // f() -> i64 { p := Point.{ x = 7, y = 9 }; return p.x + p.y }
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const x = fb.add(b0, inst(.{ .const_int = 7 }, .i64));
    const y = fb.add(b0, inst(.{ .const_int = 9 }, .i64));
    const finit = [_]Ref{ ref(x), ref(y) };
    const p = fb.add(b0, inst(.{ .struct_init = .{ .fields = &finit } }, point));
    const px = fb.add(b0, inst(.{ .struct_get = .{ .base = ref(p), .field_index = 0, .base_type = point } }, .i64));
    const py = fb.add(b0, inst(.{ .struct_get = .{ .base = ref(p), .field_index = 1, .base_type = point } }, .i64));
    const s = fb.add(b0, inst(.{ .add = .{ .lhs = ref(px), .rhs = ref(py) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(s) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 16), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: alloca + struct_gep + store + load" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const pfields = [_]types.TypeInfo.StructInfo.Field{
        .{ .name = table.internString("x"), .ty = .i64 },
        .{ .name = table.internString("y"), .ty = .i64 },
    };
    const point = table.intern(.{ .@"struct" = .{ .name = table.internString("Point"), .fields = &pfields } });
    const pptr = table.intern(.{ .pointer = .{ .pointee = point } });

    // p := alloca Point; p.x = 5; p.y = 11; return load p.x + load p.y
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const p = fb.add(b0, inst(.{ .alloca = point }, pptr));
    const gx = fb.add(b0, inst(.{ .struct_gep = .{ .base = ref(p), .field_index = 0, .base_type = point } }, pptr));
    const c5 = fb.add(b0, inst(.{ .const_int = 5 }, .i64));
    _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(gx), .val = ref(c5), .val_ty = .i64 } }, .void));
    const gy = fb.add(b0, inst(.{ .struct_gep = .{ .base = ref(p), .field_index = 1, .base_type = point } }, pptr));
    const c11 = fb.add(b0, inst(.{ .const_int = 11 }, .i64));
    _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(gy), .val = ref(c11), .val_ty = .i64 } }, .void));
    const lx = fb.add(b0, inst(.{ .load = .{ .operand = ref(gx) } }, .i64));
    const ly = fb.add(b0, inst(.{ .load = .{ .operand = ref(gy) } }, .i64));
    const s = fb.add(b0, inst(.{ .add = .{ .lhs = ref(lx), .rhs = ref(ly) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(s) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 16), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: nested struct (aggregate field copy + nested read)" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const pfields = [_]types.TypeInfo.StructInfo.Field{
        .{ .name = table.internString("x"), .ty = .i64 },
        .{ .name = table.internString("y"), .ty = .i64 },
    };
    const point = table.intern(.{ .@"struct" = .{ .name = table.internString("Point"), .fields = &pfields } });
    const lfields = [_]types.TypeInfo.StructInfo.Field{
        .{ .name = table.internString("a"), .ty = point },
        .{ .name = table.internString("b"), .ty = point },
    };
    const line = table.intern(.{ .@"struct" = .{ .name = table.internString("Line"), .fields = &lfields } });

    // L := Line.{ a = Point.{1,2}, b = Point.{3,4} }; return L.a.x + L.b.y  → 1 + 4 = 5
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const c1 = fb.add(b0, inst(.{ .const_int = 1 }, .i64));
    const c2 = fb.add(b0, inst(.{ .const_int = 2 }, .i64));
    const pr = [_]Ref{ ref(c1), ref(c2) };
    const p = fb.add(b0, inst(.{ .struct_init = .{ .fields = &pr } }, point));
    const c3 = fb.add(b0, inst(.{ .const_int = 3 }, .i64));
    const c4 = fb.add(b0, inst(.{ .const_int = 4 }, .i64));
    const qr = [_]Ref{ ref(c3), ref(c4) };
    const q = fb.add(b0, inst(.{ .struct_init = .{ .fields = &qr } }, point));
    const lr = [_]Ref{ ref(p), ref(q) };
    const l = fb.add(b0, inst(.{ .struct_init = .{ .fields = &lr } }, line));
    const la = fb.add(b0, inst(.{ .struct_get = .{ .base = ref(l), .field_index = 0, .base_type = line } }, point));
    const lax = fb.add(b0, inst(.{ .struct_get = .{ .base = ref(la), .field_index = 0, .base_type = point } }, .i64));
    const lb = fb.add(b0, inst(.{ .struct_get = .{ .base = ref(l), .field_index = 1, .base_type = line } }, point));
    const lby = fb.add(b0, inst(.{ .struct_get = .{ .base = ref(lb), .field_index = 1, .base_type = point } }, .i64));
    const s = fb.add(b0, inst(.{ .add = .{ .lhs = ref(lax), .rhs = ref(lby) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(s) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 5), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: tuple_init + tuple_get (mixed i64/f64)" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const tfields = [_]TypeId{ .i64, .f64 };
    const tup = table.intern(.{ .tuple = .{ .fields = &tfields, .names = null } });

    // t := (5, 2.5); return t.0 + int(t.1)  → 5 + 2 = 7
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const a = fb.add(b0, inst(.{ .const_int = 5 }, .i64));
    const b = fb.add(b0, inst(.{ .const_float = 2.5 }, .f64));
    const tinit = [_]Ref{ ref(a), ref(b) };
    const t = fb.add(b0, inst(.{ .tuple_init = .{ .fields = &tinit } }, tup));
    const t0 = fb.add(b0, inst(.{ .tuple_get = .{ .base = ref(t), .field_index = 0, .base_type = tup } }, .i64));
    const t1 = fb.add(b0, inst(.{ .tuple_get = .{ .base = ref(t), .field_index = 1, .base_type = tup } }, .f64));
    const t1i = fb.add(b0, inst(.{ .float_to_int = .{ .operand = ref(t1), .from = .f64, .to = .i64 } }, .i64));
    const s = fb.add(b0, inst(.{ .add = .{ .lhs = ref(t0), .rhs = ref(t1i) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(s) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 7), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: array index_gep/store + index_get sum, and length" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const arr = table.intern(.{ .array = .{ .element = .i64, .length = 3 } });
    const aptr = table.intern(.{ .pointer = .{ .pointee = arr } });
    const i64ptr = table.intern(.{ .pointer = .{ .pointee = .i64 } });

    // a := alloca [3]i64; a[0]=10; a[1]=20; a[2]=12; return a[0]+a[1]+a[2]  → 42
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const a = fb.add(b0, inst(.{ .alloca = arr }, aptr));
    const vals = [_]i64{ 10, 20, 12 };
    var gep: [3]u32 = undefined;
    inline for (0..3) |k| {
        const ik = fb.add(b0, inst(.{ .const_int = @intCast(k) }, .i64));
        gep[k] = fb.add(b0, inst(.{ .index_gep = .{ .lhs = ref(a), .rhs = ref(ik) } }, i64ptr));
        const cv = fb.add(b0, inst(.{ .const_int = vals[k] }, .i64));
        _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(gep[k]), .val = ref(cv), .val_ty = .i64 } }, .void));
    }
    const idx0 = fb.add(b0, inst(.{ .const_int = 0 }, .i64));
    const e0 = fb.add(b0, inst(.{ .index_get = .{ .lhs = ref(a), .rhs = ref(idx0) } }, .i64));
    const idx1 = fb.add(b0, inst(.{ .const_int = 1 }, .i64));
    const e1 = fb.add(b0, inst(.{ .index_get = .{ .lhs = ref(a), .rhs = ref(idx1) } }, .i64));
    const idx2 = fb.add(b0, inst(.{ .const_int = 2 }, .i64));
    const e2 = fb.add(b0, inst(.{ .index_get = .{ .lhs = ref(a), .rhs = ref(idx2) } }, .i64));
    const s01 = fb.add(b0, inst(.{ .add = .{ .lhs = ref(e0), .rhs = ref(e1) } }, .i64));
    const s = fb.add(b0, inst(.{ .add = .{ .lhs = ref(s01), .rhs = ref(e2) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(s) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 42), toI64(try v.run(&fb.func, &.{})));

    // length(array value) → static length 3
    var fb2 = Fb.init(alloc, &.{}, .i64);
    defer fb2.deinit();
    const c0 = fb2.block(&.{});
    const a2 = fb2.add(c0, inst(.{ .alloca = arr }, aptr));
    const av = fb2.add(c0, inst(.{ .load = .{ .operand = ref(a2) } }, arr));
    const len = fb2.add(c0, inst(.{ .length = .{ .operand = ref(av) } }, .i64));
    _ = fb2.add(c0, inst(.{ .ret = .{ .operand = ref(len) } }, .void));
    try std.testing.expectEqual(@as(i64, 3), toI64(try v.run(&fb2.func, &.{})));
}

test "comptime_vm exec: const_string length + str_eq/str_ne" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const foo = table.internString("foo");
    const foo2 = table.internString("foo"); // interns to the same id, but distinct const_string sites
    const bar = table.internString("bar");

    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const a = fb.add(b0, inst(.{ .const_string = foo }, .string));
    const b = fb.add(b0, inst(.{ .const_string = foo2 }, .string));
    const c = fb.add(b0, inst(.{ .const_string = bar }, .string));
    const la = fb.add(b0, inst(.{ .length = .{ .operand = ref(a) } }, .i64)); // 3
    const eq = fb.add(b0, inst(.{ .str_eq = .{ .lhs = ref(a), .rhs = ref(b) } }, .bool)); // true
    const ne = fb.add(b0, inst(.{ .str_ne = .{ .lhs = ref(a), .rhs = ref(c) } }, .bool)); // true
    const both = fb.add(b0, inst(.{ .bool_and = .{ .lhs = ref(eq), .rhs = ref(ne) } }, .bool));
    // return length(a) when both predicates hold, else 0  →  3
    const z = fb.add(b0, inst(.{ .const_int = 0 }, .i64));
    const sel = fb.add(b0, inst(.{ .mul = .{ .lhs = ref(la), .rhs = ref(both) } }, .i64)); // 3 * 1
    _ = z;
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(sel) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 3), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: error_tag_name_get maps a tag id to its name string" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    _ = table.internTag("Foo");
    const bad = table.internTag("Bad"); // the tag we'll resolve

    // return error_tag_name(<bad tag id>)  → the string "Bad"
    var fb = Fb.init(alloc, &.{}, .string);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const id = fb.add(b0, inst(.{ .const_int = @intCast(bad) }, .i64));
    const name = fb.add(b0, inst(.{ .error_tag_name_get = .{ .operand = ref(id) } }, .string));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(name) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    const word = try v.run(&fb.func, &.{});
    const val = try v.regToValue(alloc, &table, word, .string);
    defer alloc.free(val.string); // regToValue dupes the bytes
    try std.testing.expectEqualStrings("Bad", val.string);
}

test "comptime_vm exec: type_is_unsigned(u32) - type_is_unsigned(i64) == 1" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();

    // r_u := type_is_unsigned(u32)  → 1 ; r_s := type_is_unsigned(i64) → 0
    // return r_u - r_s  → 1  (only the correct unsigned/signed verdicts give 1)
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const ct_u = fb.add(b0, inst(.{ .const_type = .u32 }, .type_value));
    const au = [_]Ref{ref(ct_u)};
    const r_u = fb.add(b0, inst(.{ .call_builtin = .{ .builtin = .is_unsigned, .args = &au } }, .bool));
    const ct_s = fb.add(b0, inst(.{ .const_type = .i64 }, .type_value));
    const as = [_]Ref{ref(ct_s)};
    const r_s = fb.add(b0, inst(.{ .call_builtin = .{ .builtin = .is_unsigned, .args = &as } }, .bool));
    const diff = fb.add(b0, inst(.{ .sub = .{ .lhs = ref(r_u), .rhs = ref(r_s) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(diff) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 1), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: array_to_slice + index through slice + slice length" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const arr = table.intern(.{ .array = .{ .element = .i64, .length = 3 } });
    const aptr = table.intern(.{ .pointer = .{ .pointee = arr } });
    const i64ptr = table.intern(.{ .pointer = .{ .pointee = .i64 } });
    const sl = table.intern(.{ .slice = .{ .element = .i64 } });

    // a := alloca [3]i64 = {10,20,12}; s := a[..]; return len(s) + s[1]  → 3 + 20 = 23
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const a = fb.add(b0, inst(.{ .alloca = arr }, aptr));
    const vals = [_]i64{ 10, 20, 12 };
    inline for (0..3) |k| {
        const ik = fb.add(b0, inst(.{ .const_int = @intCast(k) }, .i64));
        const g = fb.add(b0, inst(.{ .index_gep = .{ .lhs = ref(a), .rhs = ref(ik) } }, i64ptr));
        const cv = fb.add(b0, inst(.{ .const_int = vals[k] }, .i64));
        _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(g), .val = ref(cv), .val_ty = .i64 } }, .void));
    }
    const av = fb.add(b0, inst(.{ .load = .{ .operand = ref(a) } }, arr));
    const s = fb.add(b0, inst(.{ .array_to_slice = .{ .operand = ref(av) } }, sl));
    const slen = fb.add(b0, inst(.{ .length = .{ .operand = ref(s) } }, .i64));
    const one = fb.add(b0, inst(.{ .const_int = 1 }, .i64));
    const e1 = fb.add(b0, inst(.{ .index_get = .{ .lhs = ref(s), .rhs = ref(one) } }, .i64));
    const sum = fb.add(b0, inst(.{ .add = .{ .lhs = ref(slen), .rhs = ref(e1) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(sum) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 23), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: subslice of an array" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const arr = table.intern(.{ .array = .{ .element = .i64, .length = 5 } });
    const aptr = table.intern(.{ .pointer = .{ .pointee = arr } });
    const i64ptr = table.intern(.{ .pointer = .{ .pointee = .i64 } });
    const sl = table.intern(.{ .slice = .{ .element = .i64 } });

    // a := {0,10,20,30,40}; s := a[1..4] = {10,20,30}; return len(s) + s[0] + s[2]  → 3+10+30 = 43
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const a = fb.add(b0, inst(.{ .alloca = arr }, aptr));
    inline for (0..5) |k| {
        const ik = fb.add(b0, inst(.{ .const_int = @intCast(k) }, .i64));
        const g = fb.add(b0, inst(.{ .index_gep = .{ .lhs = ref(a), .rhs = ref(ik) } }, i64ptr));
        const cv = fb.add(b0, inst(.{ .const_int = @as(i64, @intCast(k)) * 10 }, .i64));
        _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(g), .val = ref(cv), .val_ty = .i64 } }, .void));
    }
    const av = fb.add(b0, inst(.{ .load = .{ .operand = ref(a) } }, arr));
    const lo = fb.add(b0, inst(.{ .const_int = 1 }, .i64));
    const hi = fb.add(b0, inst(.{ .const_int = 4 }, .i64));
    const s = fb.add(b0, inst(.{ .subslice = .{ .base = ref(av), .lo = ref(lo), .hi = ref(hi), .base_ty = arr } }, sl));
    const slen = fb.add(b0, inst(.{ .length = .{ .operand = ref(s) } }, .i64));
    const z = fb.add(b0, inst(.{ .const_int = 0 }, .i64));
    const e0 = fb.add(b0, inst(.{ .index_get = .{ .lhs = ref(s), .rhs = ref(z) } }, .i64));
    const two = fb.add(b0, inst(.{ .const_int = 2 }, .i64));
    const e2 = fb.add(b0, inst(.{ .index_get = .{ .lhs = ref(s), .rhs = ref(two) } }, .i64));
    const t = fb.add(b0, inst(.{ .add = .{ .lhs = ref(slen), .rhs = ref(e0) } }, .i64));
    const sum = fb.add(b0, inst(.{ .add = .{ .lhs = ref(t), .rhs = ref(e2) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(sum) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 43), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: subslice of a many-pointer ([*]T) — base IS the data pointer" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const arr = table.intern(.{ .array = .{ .element = .i64, .length = 5 } });
    const aptr = table.intern(.{ .pointer = .{ .pointee = arr } });
    const i64ptr = table.intern(.{ .pointer = .{ .pointee = .i64 } });
    const mptr = table.intern(.{ .many_pointer = .{ .element = .i64 } });
    const sl = table.intern(.{ .slice = .{ .element = .i64 } });

    // a := {0,10,20,30,40}; s := ([*]i64 a)[1..4]; return len(s) + s[0] + s[2] → 43
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const a = fb.add(b0, inst(.{ .alloca = arr }, aptr));
    inline for (0..5) |k| {
        const ik = fb.add(b0, inst(.{ .const_int = @intCast(k) }, .i64));
        const g = fb.add(b0, inst(.{ .index_gep = .{ .lhs = ref(a), .rhs = ref(ik) } }, i64ptr));
        const cv = fb.add(b0, inst(.{ .const_int = @as(i64, @intCast(k)) * 10 }, .i64));
        _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(g), .val = ref(cv), .val_ty = .i64 } }, .void));
    }
    // The alloca result IS the array's base address — subslice it as a `[*]i64`.
    const lo = fb.add(b0, inst(.{ .const_int = 1 }, .i64));
    const hi = fb.add(b0, inst(.{ .const_int = 4 }, .i64));
    const s = fb.add(b0, inst(.{ .subslice = .{ .base = ref(a), .lo = ref(lo), .hi = ref(hi), .base_ty = mptr } }, sl));
    const slen = fb.add(b0, inst(.{ .length = .{ .operand = ref(s) } }, .i64));
    const z = fb.add(b0, inst(.{ .const_int = 0 }, .i64));
    const e0 = fb.add(b0, inst(.{ .index_get = .{ .lhs = ref(s), .rhs = ref(z) } }, .i64));
    const two = fb.add(b0, inst(.{ .const_int = 2 }, .i64));
    const e2 = fb.add(b0, inst(.{ .index_get = .{ .lhs = ref(s), .rhs = ref(two) } }, .i64));
    const t = fb.add(b0, inst(.{ .add = .{ .lhs = ref(slen), .rhs = ref(e0) } }, .i64));
    const sum = fb.add(b0, inst(.{ .add = .{ .lhs = ref(t), .rhs = ref(e2) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(sum) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 43), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: struct_gep with an explicit pointer base_type derefs to the field (no panic)" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const s_ty = table.intern(.{ .@"struct" = .{ .name = dummy, .fields = &.{
        .{ .name = dummy, .ty = .i64 },
        .{ .name = dummy, .ty = .i64 },
    } } });
    const sptr = table.intern(.{ .pointer = .{ .pointee = s_ty } });
    const i64ptr = table.intern(.{ .pointer = .{ .pointee = .i64 } });

    // p := alloca S (a *S); struct_gep(p, field 1) with base_type = *S → &p.y;
    // store 80; load → 80. Exercises aggType derefing a POINTER base_type (the
    // List write path sets base_type = *Struct; without the deref fieldOffset panics).
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const p = fb.add(b0, inst(.{ .alloca = s_ty }, sptr));
    const g = fb.add(b0, inst(.{ .struct_gep = .{ .base = ref(p), .field_index = 1, .base_type = sptr } }, i64ptr));
    const v80 = fb.add(b0, inst(.{ .const_int = 80 }, .i64));
    _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(g), .val = ref(v80), .val_ty = .i64 } }, .void));
    const got = fb.add(b0, inst(.{ .load = .{ .operand = ref(g) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(got) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 80), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: non-pointer optional wrap/unwrap/has_value/coalesce" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const opt_i64 = table.intern(.{ .optional = .{ .child = .i64 } });

    // o := ?i64(42); n := null; return (unwrap o + (n ?? 7) + (o ?? 7)) * has_value(o)
    //   = (42 + 7 + 42) * 1 = 91
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const c = fb.add(b0, inst(.{ .const_int = 42 }, .i64));
    const o = fb.add(b0, inst(.{ .optional_wrap = .{ .operand = ref(c) } }, opt_i64));
    const n = fb.add(b0, inst(.const_null, opt_i64));
    const h = fb.add(b0, inst(.{ .optional_has_value = .{ .operand = ref(o) } }, .bool));
    const u = fb.add(b0, inst(.{ .optional_unwrap = .{ .operand = ref(o) } }, .i64));
    const fb7 = fb.add(b0, inst(.{ .const_int = 7 }, .i64));
    const co_n = fb.add(b0, inst(.{ .optional_coalesce = .{ .lhs = ref(n), .rhs = ref(fb7) } }, .i64));
    const co_o = fb.add(b0, inst(.{ .optional_coalesce = .{ .lhs = ref(o), .rhs = ref(fb7) } }, .i64));
    const s1 = fb.add(b0, inst(.{ .add = .{ .lhs = ref(u), .rhs = ref(co_n) } }, .i64));
    const s2 = fb.add(b0, inst(.{ .add = .{ .lhs = ref(s1), .rhs = ref(co_o) } }, .i64));
    const s = fb.add(b0, inst(.{ .mul = .{ .lhs = ref(s2), .rhs = ref(h) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(s) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 91), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: a negative i32 stored and reloaded stays negative (sign-extend)" {
    // Regression (failable cluster): the legacy `.int` model is i64. Storing an
    // i32 -1 writes 0xFFFFFFFF; the load must SIGN-extend (not zero-extend, which
    // would read +4294967295 and make `< 0` false — the bug that hid `raise`).
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const i32ptr = table.intern(.{ .pointer = .{ .pointee = .i32 } });

    // p := alloca i32; *p = -1; return (load p) < 0 ? 1 : 0   → 1
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const p = fb.add(b0, inst(.{ .alloca = .i32 }, i32ptr));
    const neg1 = fb.add(b0, inst(.{ .const_int = -1 }, .i32));
    _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(p), .val = ref(neg1), .val_ty = .i32 } }, .void));
    const ld = fb.add(b0, inst(.{ .load = .{ .operand = ref(p) } }, .i32));
    const z = fb.add(b0, inst(.{ .const_int = 0 }, .i32));
    const lt = fb.add(b0, inst(.{ .cmp_lt = .{ .lhs = ref(ld), .rhs = ref(z) } }, .bool));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(lt) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 1), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: storing a null non-pointer optional into a slot reads back as none" {
    // Regression for the implicit-ctx coverage pass: `y: ?i64 = null` lowers to a
    // store of the `null_addr` optional sentinel into an aggregate slot. writeField
    // must ZERO the slot (→ flag byte 0 → none), not memcpy from address 0 (OOB).
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const opt_i64 = table.intern(.{ .optional = .{ .child = .i64 } });
    const opt_ptr = table.intern(.{ .pointer = .{ .pointee = opt_i64 } });

    // s := alloca ?i64; *s = null; return (load s) ?? 99   → 99
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const s = fb.add(b0, inst(.{ .alloca = opt_i64 }, opt_ptr));
    const n = fb.add(b0, inst(.const_null, opt_i64));
    _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(s), .val = ref(n), .val_ty = opt_i64 } }, .void));
    const ld = fb.add(b0, inst(.{ .load = .{ .operand = ref(s) } }, opt_i64));
    const d = fb.add(b0, inst(.{ .const_int = 99 }, .i64));
    const co = fb.add(b0, inst(.{ .optional_coalesce = .{ .lhs = ref(ld), .rhs = ref(d) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(co) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 99), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: pointer optional (null == 0)" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const i64ptr = table.intern(.{ .pointer = .{ .pointee = .i64 } });
    const opt_ptr = table.intern(.{ .optional = .{ .child = i64ptr } });

    // p := alloca i64; *p = 99; op := ?*i64(p); n := null;
    // return load(unwrap op) * has_value(op) + has_value(n)  → 99 * 1 + 0 = 99
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const p = fb.add(b0, inst(.{ .alloca = .i64 }, i64ptr));
    const c = fb.add(b0, inst(.{ .const_int = 99 }, .i64));
    _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(p), .val = ref(c), .val_ty = .i64 } }, .void));
    const op = fb.add(b0, inst(.{ .optional_wrap = .{ .operand = ref(p) } }, opt_ptr));
    const h = fb.add(b0, inst(.{ .optional_has_value = .{ .operand = ref(op) } }, .bool));
    const up = fb.add(b0, inst(.{ .optional_unwrap = .{ .operand = ref(op) } }, i64ptr));
    const val = fb.add(b0, inst(.{ .load = .{ .operand = ref(up) } }, .i64));
    const n = fb.add(b0, inst(.const_null, opt_ptr));
    const hn = fb.add(b0, inst(.{ .optional_has_value = .{ .operand = ref(n) } }, .bool));
    const prod = fb.add(b0, inst(.{ .mul = .{ .lhs = ref(val), .rhs = ref(h) } }, .i64));
    const s = fb.add(b0, inst(.{ .add = .{ .lhs = ref(prod), .rhs = ref(hn) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(s) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 99), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: payloadless enum_init + enum_tag" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const variants = [_]types.StringId{ table.internString("red"), table.internString("green"), table.internString("blue") };
    const color = table.intern(.{ .@"enum" = .{ .name = table.internString("Color"), .variants = &variants } });

    // g := Color.green (tag 1); return enum_tag(g) + 10  → 11
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const g = fb.add(b0, inst(.{ .enum_init = .{ .tag = 1, .payload = Ref.none } }, color));
    const t = fb.add(b0, inst(.{ .enum_tag = .{ .operand = ref(g) } }, .i64));
    const ten = fb.add(b0, inst(.{ .const_int = 10 }, .i64));
    const s = fb.add(b0, inst(.{ .add = .{ .lhs = ref(t), .rhs = ref(ten) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(s) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 11), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: tagged-union enum_init with payload lays out {tag@0, payload@tag_size}" {
    // The construction primitive `define` reuses: build `E.value(42)` where
    // `E = { value: i64, closed: void }` and verify the comptime bytes — tag 0
    // at offset 0, the i64 payload at offset tag_size (8). Mirrors the LLVM
    // `{ header, [N x i8] }` layout the rest of the compiler reads.
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const ufields = [_]types.TypeInfo.StructInfo.Field{
        .{ .name = table.internString("value"), .ty = .i64 },
        .{ .name = table.internString("closed"), .ty = .void },
    };
    const e = table.intern(.{ .tagged_union = .{ .name = table.internString("E"), .fields = &ufields, .tag_type = .i64 } });

    // return E.value(42)   → the tagged-union value's Addr
    var fb = Fb.init(alloc, &.{}, e);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const p = fb.add(b0, inst(.{ .const_int = 42 }, .i64));
    const g = fb.add(b0, inst(.{ .enum_init = .{ .tag = 0, .payload = ref(p) } }, e));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(g) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    const addr = try v.run(&fb.func, &.{});
    try std.testing.expectEqual(@as(u64, 0), try v.machine.readWord(addr, 8)); // tag
    try std.testing.expectEqual(@as(u64, 42), try v.machine.readWord(addr + 8, 8)); // payload
}

test "comptime_vm exec: box_any/unbox_any round-trips a scalar through the {tag, data} view" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    // slot := alloca i64; *slot = 42; a := box_any(slot, i64); return unbox_any(a)
    // → 42. box_any takes the value's ADDRESS (the borrow representation);
    // unbox_any is a typed load back through the view's data pointer.
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const c = fb.add(b0, inst(.{ .const_int = 42 }, .i64));
    const slot = fb.add(b0, inst(.{ .alloca = .i64 }, .i64));
    _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(slot), .val = ref(c), .val_ty = .i64 } }, .void));
    const a = fb.add(b0, inst(.{ .box_any = .{ .operand = ref(slot), .source_type = .i64 } }, .any));
    const u = fb.add(b0, inst(.{ .unbox_any = .{ .operand = ref(a) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(u) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 42), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: const_type yields a Type-value word; regToValue bridges it to .type_tag" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();

    // return <Type value u32>  → a `.type_value`-typed entry whose word is u32.index()
    var fb = Fb.init(alloc, &.{}, .type_value);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const ct = fb.add(b0, inst(.{ .const_type = .u32 }, .type_value));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(ct) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    const word = try v.run(&fb.func, &.{});
    try std.testing.expectEqual(@as(u64, types.TypeId.u32.index()), word);

    // The legacy boundary maps the word back to a first-class `.type_tag` Value.
    const val = try v.regToValue(alloc, &table, word, .type_value);
    try std.testing.expectEqual(types.TypeId.u32, val.type_tag);
}

test "comptime_vm exec: deref a pointer; addr_of passes through a struct address" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const i64ptr = table.intern(.{ .pointer = .{ .pointee = .i64 } });
    const pfields = [_]types.TypeInfo.StructInfo.Field{
        .{ .name = table.internString("x"), .ty = .i64 },
        .{ .name = table.internString("y"), .ty = .i64 },
    };
    const point = table.intern(.{ .@"struct" = .{ .name = table.internString("Point"), .fields = &pfields } });

    // p := alloca i64; *p = 77; v := p.*; (deref)
    // pt := Point.{3,4}; pa := @pt; px := pa.x  (addr_of pass-through + field read)
    // return v + px  → 77 + 3 = 80
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const p = fb.add(b0, inst(.{ .alloca = .i64 }, i64ptr));
    const c = fb.add(b0, inst(.{ .const_int = 77 }, .i64));
    _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(p), .val = ref(c), .val_ty = .i64 } }, .void));
    const v = fb.add(b0, inst(.{ .deref = .{ .operand = ref(p) } }, .i64));
    const x = fb.add(b0, inst(.{ .const_int = 3 }, .i64));
    const y = fb.add(b0, inst(.{ .const_int = 4 }, .i64));
    const finit = [_]Ref{ ref(x), ref(y) };
    const pt = fb.add(b0, inst(.{ .struct_init = .{ .fields = &finit } }, point));
    const pa = fb.add(b0, inst(.{ .addr_of = .{ .operand = ref(pt) } }, point));
    const px = fb.add(b0, inst(.{ .struct_get = .{ .base = ref(pa), .field_index = 0, .base_type = point } }, .i64));
    const s = fb.add(b0, inst(.{ .add = .{ .lhs = ref(v), .rhs = ref(px) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(s) } }, .void));

    var vm_ = vm.Vm.init(alloc);
    vm_.table = &table;
    defer vm_.deinit();
    try std.testing.expectEqual(@as(i64, 80), toI64(try vm_.run(&fb.func, &.{})));
}

test "comptime_vm exec: f32 store/load round-trips through 4-byte memory" {
    // Float registers hold f64 bits; f32 memory is the 4-byte IEEE-754 single.
    // Regression: storing an f32 must @floatCast (NOT truncate the f64 bits — that
    // wrote zeros for 1.0, since 1.0f64 = 0x3FF0000000000000, low 4 bytes = 0).
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const f32ptr = table.intern(.{ .pointer = .{ .pointee = .f32 } });

    // p := alloca f32; *p = 1.0; return int(load p)   → 1 (was 0 under the bug)
    var fb = Fb.init(alloc, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const p = fb.add(b0, inst(.{ .alloca = .f32 }, f32ptr));
    const c = fb.add(b0, inst(.{ .const_float = 1.0 }, .f32));
    _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(p), .val = ref(c), .val_ty = .f32 } }, .void));
    const l = fb.add(b0, inst(.{ .load = .{ .operand = ref(p) } }, .f32));
    const i = fb.add(b0, inst(.{ .float_to_int = .{ .operand = ref(l), .from = .f32, .to = .i64 } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(i) } }, .void));

    var v = vm.Vm.init(alloc);
    v.table = &table;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 1), toI64(try v.run(&fb.func, &.{})));
}

test "comptime_vm exec: malloc builtin gives usable comptime memory; free is a no-op" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();
    const u8ptr = module.types.intern(.{ .many_pointer = .{ .element = .u8 } });
    const u8single = module.types.intern(.{ .pointer = .{ .pointee = .u8 } });

    // extern malloc(size: usize) -> [*]u8   (FuncId 0, no body)
    const malloc_params = [_]Function.Param{.{ .name = module.types.internString("size"), .ty = .usize }};
    var mfb = Fb.init(alloc, &malloc_params, u8ptr);
    mfb.func.is_extern = true;
    mfb.func.name = module.types.internString("malloc");
    const malloc_id = module.addFunction(mfb.func);

    // extern free(p: [*]u8)   (FuncId 1, no body)
    const free_params = [_]Function.Param{.{ .name = module.types.internString("p"), .ty = u8ptr }};
    var ffb = Fb.init(alloc, &free_params, .void);
    ffb.func.is_extern = true;
    ffb.func.name = module.types.internString("free");
    const free_id = module.addFunction(ffb.func);

    // main(): buf := malloc(8); buf[3] = 0x42; r := buf[3]; free(buf); return r → 66
    var fb = Fb.init(alloc, &.{}, .i64);
    const b0 = fb.block(&.{});
    const sz = fb.add(b0, inst(.{ .const_int = 8 }, .usize));
    const margs = [_]Ref{ref(sz)};
    const buf = fb.add(b0, inst(.{ .call = .{ .callee = malloc_id, .args = &margs } }, u8ptr));
    const idx = fb.add(b0, inst(.{ .const_int = 3 }, .i64));
    const g = fb.add(b0, inst(.{ .index_gep = .{ .lhs = ref(buf), .rhs = ref(idx) } }, u8single));
    const val = fb.add(b0, inst(.{ .const_int = 0x42 }, .u8));
    _ = fb.add(b0, inst(.{ .store = .{ .ptr = ref(g), .val = ref(val), .val_ty = .u8 } }, .void));
    const idx2 = fb.add(b0, inst(.{ .const_int = 3 }, .i64));
    const r = fb.add(b0, inst(.{ .index_get = .{ .lhs = ref(buf), .rhs = ref(idx2) } }, .u8));
    const fargs = [_]Ref{ref(buf)};
    _ = fb.add(b0, inst(.{ .call = .{ .callee = free_id, .args = &fargs } }, .void));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(r) } }, .void));
    const main_id = module.addFunction(fb.func);

    var v = vm.Vm.init(alloc);
    v.table = &module.types;
    v.module = &module;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 66), toI64(try v.run(module.getFunction(main_id), &.{})));
}

test "comptime_vm exec: global_get evaluates a comptime global (lazy + cached)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // fn base() -> i64 { return 25 }   (FuncId 0) — the global's comptime_func
    var bf = Fb.init(alloc, &.{}, .i64);
    const bfb = bf.block(&.{});
    const c25 = bf.add(bfb, inst(.{ .const_int = 25 }, .i64));
    _ = bf.add(bfb, inst(.{ .ret = .{ .operand = ref(c25) } }, .void));
    const base_id = module.addFunction(bf.func);

    // global G :: comptime base()   (GlobalId 0)
    const g = module.addGlobal(.{ .name = module.types.internString("G"), .ty = .i64, .comptime_func = base_id });

    // fn main() -> i64 { return G + G + 5 }  → 25 + 25 + 5 = 55 (second read is cached)
    var fb = Fb.init(alloc, &.{}, .i64);
    const b0 = fb.block(&.{});
    const a = fb.add(b0, inst(.{ .global_get = g }, .i64));
    const b = fb.add(b0, inst(.{ .global_get = g }, .i64));
    const five = fb.add(b0, inst(.{ .const_int = 5 }, .i64));
    const s1 = fb.add(b0, inst(.{ .add = .{ .lhs = ref(a), .rhs = ref(b) } }, .i64));
    const s2 = fb.add(b0, inst(.{ .add = .{ .lhs = ref(s1), .rhs = ref(five) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(s2) } }, .void));
    const main_id = module.addFunction(fb.func);

    var v = vm.Vm.init(alloc);
    v.table = &module.types;
    v.module = &module;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 55), toI64(try v.run(module.getFunction(main_id), &.{})));
}

test "comptime_vm exec: compiler-fn intern/text_of round-trip (native, no legacy interp)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // extern intern(s: string) -> u32 [compiler]   (FuncId 0, no body)
    const ip = [_]Function.Param{.{ .name = module.types.internString("s"), .ty = .string }};
    var ifb = Fb.init(alloc, &ip, .u32);
    ifb.func.is_extern = true;
    ifb.func.is_intrinsic = true;
    ifb.func.name = module.types.internString("raw_intern");
    const intern_id = module.addFunction(ifb.func);

    // extern text_of(id: u32) -> string [compiler]   (FuncId 1, no body)
    const tp = [_]Function.Param{.{ .name = module.types.internString("id"), .ty = .u32 }};
    var tfb = Fb.init(alloc, &tp, .string);
    tfb.func.is_extern = true;
    tfb.func.is_intrinsic = true;
    tfb.func.name = module.types.internString("raw_text_of");
    const textof_id = module.addFunction(tfb.func);

    // main(): return length(text_of(intern("hello")))   → 5
    var fb = Fb.init(alloc, &.{}, .i64);
    const b0 = fb.block(&.{});
    const s = fb.add(b0, inst(.{ .const_string = module.types.internString("hello") }, .string));
    const sargs = [_]Ref{ref(s)};
    const id = fb.add(b0, inst(.{ .call = .{ .callee = intern_id, .args = &sargs } }, .u32));
    const iargs = [_]Ref{ref(id)};
    const back = fb.add(b0, inst(.{ .call = .{ .callee = textof_id, .args = &iargs } }, .string));
    const len = fb.add(b0, inst(.{ .length = .{ .operand = ref(back) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(len) } }, .void));
    const main_id = module.addFunction(fb.func);

    var v = vm.Vm.init(alloc);
    v.table = &module.types;
    v.module = &module;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 5), toI64(try v.run(module.getFunction(main_id), &.{})));
}

test "comptime_vm exec: compiler-fn find_type + type_field_count (native reflection)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // A struct `Point { x, y, z }` registered in the type table (the thing the
    // reflection readers look up by name and count the fields of).
    const point_name = module.types.internString("Point");
    const pfields = [_]types.TypeInfo.StructInfo.Field{
        .{ .name = module.types.internString("x"), .ty = .i64 },
        .{ .name = module.types.internString("y"), .ty = .i64 },
        .{ .name = module.types.internString("z"), .ty = .i64 },
    };
    _ = module.types.intern(.{ .@"struct" = .{ .name = point_name, .fields = &pfields } });

    // extern find_type(name: u32) -> u32 [compiler]   (FuncId 0, no body)
    const fp = [_]Function.Param{.{ .name = module.types.internString("name"), .ty = .u32 }};
    var ffb = Fb.init(alloc, &fp, .u32);
    ffb.func.is_extern = true;
    ffb.func.is_intrinsic = true;
    ffb.func.name = module.types.internString("raw_find_type");
    const find_id = module.addFunction(ffb.func);

    // extern type_field_count(t: u32) -> i64 [compiler]   (FuncId 1, no body)
    const cp = [_]Function.Param{.{ .name = module.types.internString("t"), .ty = .u32 }};
    var cfb = Fb.init(alloc, &cp, .i64);
    cfb.func.is_extern = true;
    cfb.func.is_intrinsic = true;
    cfb.func.name = module.types.internString("raw_field_count");
    const count_id = module.addFunction(cfb.func);

    // main(): return type_field_count(find_type(intern_id_of("Point")))   → 3
    // ("Point" is already interned above; pass its StringId directly.)
    var fb = Fb.init(alloc, &.{}, .i64);
    const b0 = fb.block(&.{});
    const nm = fb.add(b0, inst(.{ .const_int = @intFromEnum(point_name) }, .u32));
    const nargs = [_]Ref{ref(nm)};
    const tid = fb.add(b0, inst(.{ .call = .{ .callee = find_id, .args = &nargs } }, .u32));
    const targs = [_]Ref{ref(tid)};
    const cnt = fb.add(b0, inst(.{ .call = .{ .callee = count_id, .args = &targs } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(cnt) } }, .void));
    const main_id = module.addFunction(fb.func);

    var v = vm.Vm.init(alloc);
    v.table = &module.types;
    v.module = &module;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 3), toI64(try v.run(module.getFunction(main_id), &.{})));

    // A name with no matching type → the `unresolved` (0) sentinel.
    const missing = module.types.internString("Nope");
    var mfb = Fb.init(alloc, &.{}, .u32);
    const mb = mfb.block(&.{});
    const mnm = mfb.add(mb, inst(.{ .const_int = @intFromEnum(missing) }, .u32));
    const margs = [_]Ref{ref(mnm)};
    const mres = mfb.add(mb, inst(.{ .call = .{ .callee = find_id, .args = &margs } }, .u32));
    _ = mfb.add(mb, inst(.{ .ret = .{ .operand = ref(mres) } }, .void));
    const missing_main = module.addFunction(mfb.func);
    try std.testing.expectEqual(
        @as(i64, @intFromEnum(TypeId.unresolved)),
        toI64(try v.run(module.getFunction(missing_main), &.{})),
    );
}

test "comptime_vm exec: compiler-fn type_field_name/type/nominal_name (native reflection)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // Point { x, y } and Pair { lo: Point; hi: Point } in the type table.
    const point_name = module.types.internString("Point");
    const pfields = [_]types.TypeInfo.StructInfo.Field{
        .{ .name = module.types.internString("x"), .ty = .i64 },
        .{ .name = module.types.internString("y"), .ty = .i64 },
    };
    const point = module.types.intern(.{ .@"struct" = .{ .name = point_name, .fields = &pfields } });
    const lo_name = module.types.internString("lo");
    const hi_name = module.types.internString("hi");
    const rfields = [_]types.TypeInfo.StructInfo.Field{
        .{ .name = lo_name, .ty = point },
        .{ .name = hi_name, .ty = point },
    };
    const pair = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("Pair"), .fields = &rfields } });

    // extern type_field_name(t: u32, idx: i64) -> u32 [compiler]   (FuncId 0)
    const fnp = [_]Function.Param{ param(.u32), param(.i64) };
    var fnb = Fb.init(alloc, &fnp, .u32);
    fnb.func.is_extern = true;
    fnb.func.is_intrinsic = true;
    fnb.func.name = module.types.internString("raw_field_name");
    const fname_id = module.addFunction(fnb.func);

    // extern type_field_type(t: u32, idx: i64) -> u32 [compiler]   (FuncId 1)
    const ftp = [_]Function.Param{ param(.u32), param(.i64) };
    var ftb = Fb.init(alloc, &ftp, .u32);
    ftb.func.is_extern = true;
    ftb.func.is_intrinsic = true;
    ftb.func.name = module.types.internString("raw_field_type");
    const ftype_id = module.addFunction(ftb.func);

    // extern type_nominal_name(t: u32) -> u32 [compiler]   (FuncId 2)
    const nnp = [_]Function.Param{param(.u32)};
    var nnb = Fb.init(alloc, &nnp, .u32);
    nnb.func.is_extern = true;
    nnb.func.is_intrinsic = true;
    nnb.func.name = module.types.internString("raw_type_name");
    const nname_id = module.addFunction(nnb.func);

    // main(): return type_field_name(Pair, 1)   → StringId("hi")
    var fb = Fb.init(alloc, &.{}, .u32);
    const b0 = fb.block(&.{});
    const t = fb.add(b0, inst(.{ .const_int = @intFromEnum(pair) }, .u32));
    const one = fb.add(b0, inst(.{ .const_int = 1 }, .i64));
    const nargs = [_]Ref{ ref(t), ref(one) };
    const fn1 = fb.add(b0, inst(.{ .call = .{ .callee = fname_id, .args = &nargs } }, .u32));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(fn1) } }, .void));
    const main_id = module.addFunction(fb.func);

    var v = vm.Vm.init(alloc);
    v.table = &module.types;
    v.module = &module;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, @intFromEnum(hi_name)), toI64(try v.run(module.getFunction(main_id), &.{})));

    // type_nominal_name(type_field_type(Pair, 0)) → StringId("Point")
    var fb2 = Fb.init(alloc, &.{}, .u32);
    const c0 = fb2.block(&.{});
    const t2 = fb2.add(c0, inst(.{ .const_int = @intFromEnum(pair) }, .u32));
    const zero = fb2.add(c0, inst(.{ .const_int = 0 }, .i64));
    const targs = [_]Ref{ ref(t2), ref(zero) };
    const fty = fb2.add(c0, inst(.{ .call = .{ .callee = ftype_id, .args = &targs } }, .u32));
    const nnargs = [_]Ref{ref(fty)};
    const nn = fb2.add(c0, inst(.{ .call = .{ .callee = nname_id, .args = &nnargs } }, .u32));
    _ = fb2.add(c0, inst(.{ .ret = .{ .operand = ref(nn) } }, .void));
    const main2 = module.addFunction(fb2.func);
    try std.testing.expectEqual(@as(i64, @intFromEnum(point_name)), toI64(try v.run(module.getFunction(main2), &.{})));
}

test "comptime_vm exec: compiler-fn type_kind + type_field_value (native reflection)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // A struct and an enum with explicit values.
    const pfields = [_]types.TypeInfo.StructInfo.Field{
        .{ .name = module.types.internString("x"), .ty = .i64 },
        .{ .name = module.types.internString("y"), .ty = .i64 },
    };
    const point = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("Point"), .fields = &pfields } });
    const variants = [_]types.StringId{ module.types.internString("ok"), module.types.internString("missing") };
    const evals = [_]i64{ 200, 404 };
    const status = module.types.intern(.{ .@"enum" = .{
        .name = module.types.internString("Status"),
        .variants = &variants,
        .explicit_values = &evals,
    } });

    // extern type_kind(t: u32) -> i64 [compiler]   (FuncId 0)
    const kp = [_]Function.Param{param(.u32)};
    var kb = Fb.init(alloc, &kp, .i64);
    kb.func.is_extern = true;
    kb.func.is_intrinsic = true;
    kb.func.name = module.types.internString("raw_type_kind");
    const kind_id = module.addFunction(kb.func);

    // extern type_field_value(t: u32, idx: i64) -> i64 [compiler]   (FuncId 1)
    const vp = [_]Function.Param{ param(.u32), param(.i64) };
    var vb = Fb.init(alloc, &vp, .i64);
    vb.func.is_extern = true;
    vb.func.is_intrinsic = true;
    vb.func.name = module.types.internString("raw_variant_value");
    const val_id = module.addFunction(vb.func);

    var v = vm.Vm.init(alloc);
    v.table = &module.types;
    v.module = &module;
    defer v.deinit();

    // type_kind(Point) → 1 (struct); type_kind(Status) → 2 (enum).
    inline for (.{ .{ point, 1 }, .{ status, 2 } }) |case| {
        var fb = Fb.init(alloc, &.{}, .i64);
        const b0 = fb.block(&.{});
        const t = fb.add(b0, inst(.{ .const_int = @intFromEnum(case[0]) }, .u32));
        const kargs = [_]Ref{ref(t)};
        const k = fb.add(b0, inst(.{ .call = .{ .callee = kind_id, .args = &kargs } }, .i64));
        _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(k) } }, .void));
        const mid = module.addFunction(fb.func);
        try std.testing.expectEqual(@as(i64, case[1]), toI64(try v.run(module.getFunction(mid), &.{})));
    }

    // type_field_value(Status, 1) → 404 (explicit value).
    var fb = Fb.init(alloc, &.{}, .i64);
    const b0 = fb.block(&.{});
    const t = fb.add(b0, inst(.{ .const_int = @intFromEnum(status) }, .u32));
    const one = fb.add(b0, inst(.{ .const_int = 1 }, .i64));
    const vargs = [_]Ref{ ref(t), ref(one) };
    const val = fb.add(b0, inst(.{ .call = .{ .callee = val_id, .args = &vargs } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(val) } }, .void));
    const mid = module.addFunction(fb.func);
    try std.testing.expectEqual(@as(i64, 404), toI64(try v.run(module.getFunction(mid), &.{})));
}

test "comptime_vm exec: func_ref + call_indirect dispatch" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // fn dbl(x) = x * 2   (FuncId 0)
    const dbl_params = [_]Function.Param{.{ .name = dummy, .ty = .i64 }};
    var db = Fb.init(alloc, &dbl_params, .i64);
    const dbb = db.block(&.{});
    const two = db.add(dbb, inst(.{ .const_int = 2 }, .i64));
    const prod = db.add(dbb, inst(.{ .mul = .{ .lhs = ref(0), .rhs = ref(two) } }, .i64));
    _ = db.add(dbb, inst(.{ .ret = .{ .operand = ref(prod) } }, .void));
    const dbl_id = module.addFunction(db.func);

    // fn main() = call_indirect(func_ref(dbl), [21])   → 42
    var fb = Fb.init(alloc, &.{}, .i64);
    const b0 = fb.block(&.{});
    const fr = fb.add(b0, inst(.{ .func_ref = dbl_id }, .i64));
    const c21 = fb.add(b0, inst(.{ .const_int = 21 }, .i64));
    const cargs = [_]Ref{ref(c21)};
    const r = fb.add(b0, inst(.{ .call_indirect = .{ .callee = ref(fr), .args = &cargs } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(r) } }, .void));
    const main_id = module.addFunction(fb.func);

    var v = vm.Vm.init(alloc);
    v.table = &module.types;
    v.module = &module;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 42), toI64(try v.run(module.getFunction(main_id), &.{})));
}

test "comptime_vm exec: direct call to another function" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // fn add(a, b) = a + b   (FuncId 0)
    const add_params = [_]Function.Param{ .{ .name = dummy, .ty = .i64 }, .{ .name = dummy, .ty = .i64 } };
    var cb = Fb.init(alloc, &add_params, .i64);
    const cbb = cb.block(&.{});
    const csum = cb.add(cbb, inst(.{ .add = .{ .lhs = ref(0), .rhs = ref(1) } }, .i64));
    _ = cb.add(cbb, inst(.{ .ret = .{ .operand = ref(csum) } }, .void));
    const add_id = module.addFunction(cb.func); // module now owns it (no cb.deinit)

    // fn main() = add(20, 22) + 100   (FuncId 1)
    var fb = Fb.init(alloc, &.{}, .i64);
    const b0 = fb.block(&.{});
    const a20 = fb.add(b0, inst(.{ .const_int = 20 }, .i64));
    const a22 = fb.add(b0, inst(.{ .const_int = 22 }, .i64));
    const cargs = [_]Ref{ ref(a20), ref(a22) };
    const r = fb.add(b0, inst(.{ .call = .{ .callee = add_id, .args = &cargs } }, .i64));
    const c100 = fb.add(b0, inst(.{ .const_int = 100 }, .i64));
    const sum = fb.add(b0, inst(.{ .add = .{ .lhs = ref(r), .rhs = ref(c100) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(sum) } }, .void));
    const main_id = module.addFunction(fb.func);

    var v = vm.Vm.init(alloc);
    v.table = &module.types;
    v.module = &module;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 142), toI64(try v.run(module.getFunction(main_id), &.{})));
}

test "comptime_vm exec: recursive call (sum 0..n)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // fn sum(n) = if n == 0 then 0 else n + sum(n-1)   (FuncId 0 — references itself)
    const self_id = FuncId.fromIndex(0);
    const params = [_]Function.Param{.{ .name = dummy, .ty = .i64 }};
    var fb = Fb.init(alloc, &params, .i64);
    const b0 = fb.block(&.{});
    const z = fb.add(b0, inst(.{ .const_int = 0 }, .i64));
    const c = fb.add(b0, inst(.{ .cmp_eq = .{ .lhs = ref(0), .rhs = ref(z) } }, .bool));
    _ = fb.add(b0, inst(.{ .cond_br = .{ .cond = ref(c), .then_target = BlockId.fromIndex(1), .then_args = &.{}, .else_target = BlockId.fromIndex(2), .else_args = &.{} } }, .void));
    // b1: base case → 0
    const b1 = fb.block(&.{});
    const zero = fb.add(b1, inst(.{ .const_int = 0 }, .i64));
    _ = fb.add(b1, inst(.{ .ret = .{ .operand = ref(zero) } }, .void));
    // b2: recurse → n + sum(n-1)
    const b2 = fb.block(&.{});
    const one = fb.add(b2, inst(.{ .const_int = 1 }, .i64));
    const nm1 = fb.add(b2, inst(.{ .sub = .{ .lhs = ref(0), .rhs = ref(one) } }, .i64));
    const rargs = [_]Ref{ref(nm1)};
    const rec = fb.add(b2, inst(.{ .call = .{ .callee = self_id, .args = &rargs } }, .i64));
    const s = fb.add(b2, inst(.{ .add = .{ .lhs = ref(0), .rhs = ref(rec) } }, .i64));
    _ = fb.add(b2, inst(.{ .ret = .{ .operand = ref(s) } }, .void));
    const sum_id = module.addFunction(fb.func);
    try std.testing.expectEqual(@as(u32, 0), sum_id.index()); // confirms the self-reference id

    var v = vm.Vm.init(alloc);
    v.table = &module.types;
    v.module = &module;
    defer v.deinit();
    try std.testing.expectEqual(@as(i64, 15), toI64(try v.run(module.getFunction(sum_id), &.{fromI64(5)})));
    try std.testing.expectEqual(@as(i64, 55), toI64(try v.run(module.getFunction(sum_id), &.{fromI64(10)})));
}

test "comptime_vm tryEval: pure function → Value; unsupported → null" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // fn k() -> i64 { return 6 * 7 }   → tryEval yields Value.int(42)
    var fb = Fb.init(alloc, &.{}, .i64);
    const b0 = fb.block(&.{});
    const a = fb.add(b0, inst(.{ .const_int = 6 }, .i64));
    const b = fb.add(b0, inst(.{ .const_int = 7 }, .i64));
    const m = fb.add(b0, inst(.{ .mul = .{ .lhs = ref(a), .rhs = ref(b) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(m) } }, .void));
    const ok_id = module.addFunction(fb.func);

    const v = vm.tryEval(alloc, &module, ok_id, null, null) orelse return error.VmShouldHaveHandledIt;
    try std.testing.expectEqual(@as(i64, 42), v.int);

    // fn bad() { vec_splat(...) }  → an unported op → tryEval yields null. The VM
    // bails loudly on any op it does not model (never a silent default); vec_splat
    // is a stable example of one.
    var fb2 = Fb.init(alloc, &.{}, .void);
    const c0 = fb2.block(&.{});
    _ = fb2.add(c0, inst(.{ .vec_splat = .{ .operand = ref(0) } }, .void));
    _ = fb2.add(c0, inst(.ret_void, .void));
    const bad_id = module.addFunction(fb2.func);

    try std.testing.expect(vm.tryEval(alloc, &module, bad_id, null, null) == null);
}

test "comptime_vm tryEval: wasm32 target keeps host pointers intact and restores target width" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();
    module.types.pointer_size = 4;

    var fb = Fb.init(alloc, &.{}, .string);
    const b0 = fb.block(&.{});
    const text_ref = fb.add(b0, inst(.{ .const_string = module.types.internString("wasm") }, .string));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(text_ref) } }, .void));
    const fid = module.addFunction(fb.func);

    const result = vm.tryEval(alloc, &module, fid, null, null) orelse return error.VmShouldHaveHandledIt;
    defer alloc.free(result.string);
    try std.testing.expectEqualStrings("wasm", result.string);
    try std.testing.expectEqual(@as(u8, 4), module.types.pointer_size);
}

test "comptime_vm exec: division by zero and unsupported op bail loudly" {
    // a / b
    {
        const params = [_]Function.Param{ param(.i64), param(.i64) };
        var fb = Fb.init(std.testing.allocator, &params, .i64);
        defer fb.deinit();
        const b0 = fb.block(&.{});
        const q = fb.add(b0, inst(.{ .div = .{ .lhs = ref(0), .rhs = ref(1) } }, .i64));
        _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(q) } }, .void));

        var v = vm.Vm.init(std.testing.allocator);
        defer v.deinit();
        try std.testing.expectEqual(@as(i64, 4), toI64(try v.run(&fb.func, &.{ fromI64(12), fromI64(3) })));
        try std.testing.expectError(error.DivisionByZero, v.run(&fb.func, &.{ fromI64(12), fromI64(0) }));
    }
    // A not-yet-ported op (vec_splat) → Unsupported with the op name in `detail`.
    {
        var fb = Fb.init(std.testing.allocator, &.{}, .void);
        defer fb.deinit();
        const b0 = fb.block(&.{});
        _ = fb.add(b0, inst(.{ .vec_splat = .{ .operand = ref(0) } }, .void));
        _ = fb.add(b0, inst(.ret_void, .void));

        var v = vm.Vm.init(std.testing.allocator);
        defer v.deinit();
        try std.testing.expectError(error.Unsupported, v.run(&fb.func, &.{}));
        try std.testing.expectEqualStrings("vec_splat", v.detail.?);
    }
}

test "comptime_vm: allocBytes never returns null_addr and respects alignment" {
    var m = vm.Machine.init(std.testing.allocator);
    defer m.deinit();

    const a = m.allocBytes(1, 1);
    try std.testing.expect(a != vm.null_addr);

    // An 8-aligned allocation lands on an 8-multiple address.
    const b = m.allocBytes(4, 8);
    try std.testing.expectEqual(@as(u64, 0), b % 8);

    // Distinct allocations don't overlap.
    const c = m.allocBytes(4, 8);
    try std.testing.expect(c >= b + 4);

    // A zero-size allocation is still a valid, non-null, aligned address.
    const z = m.allocBytes(0, 4);
    try std.testing.expect(z != vm.null_addr);
    try std.testing.expectEqual(@as(u64, 0), z % 4);
}

test "comptime_vm: writeWord/readWord round-trip at each scalar size" {
    var m = vm.Machine.init(std.testing.allocator);
    defer m.deinit();

    const sizes = [_]usize{ 1, 2, 4, 8 };
    const vals = [_]u64{ 0xAB, 0xBEEF, 0xDEADBEEF, 0x0123456789ABCDEF };
    for (sizes, vals) |size, val| {
        const addr = m.allocBytes(size, size);
        try m.writeWord(addr, size, val);
        try std.testing.expectEqual(val, try m.readWord(addr, size));
    }
}

test "comptime_vm: writeWord truncates to size and readWord zero-extends" {
    var m = vm.Machine.init(std.testing.allocator);
    defer m.deinit();

    // Write a full 64-bit word's worth of bits through a 1-byte store: only the
    // low byte lands; the read zero-extends it.
    const addr = m.allocBytes(1, 1);
    try m.writeWord(addr, 1, 0xFFFF_FF42);
    try std.testing.expectEqual(@as(u64, 0x42), try m.readWord(addr, 1));
}

test "comptime_vm: bytes() view reflects word writes (little-endian)" {
    var m = vm.Machine.init(std.testing.allocator);
    defer m.deinit();

    const addr = m.allocBytes(4, 4);
    try m.writeWord(addr, 4, 0xDEADBEEF);
    const view = try m.bytes(addr, 4);
    try std.testing.expectEqual(@as(u8, 0xEF), view[0]);
    try std.testing.expectEqual(@as(u8, 0xBE), view[1]);
    try std.testing.expectEqual(@as(u8, 0xAD), view[2]);
    try std.testing.expectEqual(@as(u8, 0xDE), view[3]);
}

test "comptime_vm: a malformed operand ref (Ref.none) bails, not a panic" {
    // A `ret` whose operand is `Ref.none` (0xFFFFFFFF) — the kind of malformed IR
    // an unresolved name leaves behind. `Frame.get` must flip `bad_ref` and the run
    // must bail (error.Unsupported), never index out of bounds and panic.
    var fb = Fb.init(std.testing.allocator, &.{}, .i64);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = Ref.none } }, .void));

    var v = vm.Vm.init(std.testing.allocator);
    defer v.deinit();
    try std.testing.expectError(error.Unsupported, v.run(&fb.func, &.{}));
}

test "comptime_vm: a malformed operand TYPE ref bails (refTy), not a panic" {
    // A comparison whose lhs is `Ref.none` exercises the `ref_types` (type-side)
    // accessor `refTy` — the companion to the value-side `Frame.get` guard. Raw
    // `ref_types[Ref.none.index()]` would index out of bounds and panic; it must
    // bail (error.Unsupported) so the host falls back to the legacy interpreter.
    var fb = Fb.init(std.testing.allocator, &.{}, .bool);
    defer fb.deinit();
    const b0 = fb.block(&.{});
    const c = fb.add(b0, inst(.{ .const_int = 1 }, .i64));
    const r = fb.add(b0, inst(.{ .cmp_lt = .{ .lhs = Ref.none, .rhs = ref(c) } }, .bool));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(r) } }, .void));

    var v = vm.Vm.init(std.testing.allocator);
    defer v.deinit();
    try std.testing.expectError(error.Unsupported, v.run(&fb.func, &.{}));
}

test "comptime_vm: hardened accessors return OutOfBounds on null, not a panic" {
    var m = vm.Machine.init(std.testing.allocator);
    defer m.deinit();

    const addr = m.allocBytes(8, 8);
    try std.testing.expect(addr != vm.null_addr);

    // Null address → OutOfBounds on every accessor (the malformed-IR / null-deref
    // safety contract `tryEval` relies on — bail, never crash).
    try std.testing.expectError(error.OutOfBounds, m.readWord(vm.null_addr, 8));
    try std.testing.expectError(error.OutOfBounds, m.writeWord(vm.null_addr, 8, 0));
    try std.testing.expectError(error.OutOfBounds, m.bytes(vm.null_addr, 4));

    // An oversized scalar read (> 8 bytes) → OutOfBounds.
    try std.testing.expectError(error.OutOfBounds, m.readWord(addr, 16));

    // A zero-length view is always valid (no memory touched), even at null.
    try std.testing.expectEqual(@as(usize, 0), (try m.bytes(vm.null_addr, 0)).len);
}

test "comptime_vm tryEval: deref of a null pointer bails (null, not a crash)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();
    const i64ptr = module.types.intern(.{ .pointer = .{ .pointee = .i64 } });

    // fn bad() -> i64 { p := (null : *i64); return p.* }  → reads through addr 0.
    var fb = Fb.init(alloc, &.{}, .i64);
    const b0 = fb.block(&.{});
    const p = fb.add(b0, inst(.const_null, i64ptr));
    const d = fb.add(b0, inst(.{ .deref = .{ .operand = ref(p) } }, .i64));
    _ = fb.add(b0, inst(.{ .ret = .{ .operand = ref(d) } }, .void));
    const bad_id = module.addFunction(fb.func);

    // The hardened accessors turn the null deref into error.OutOfBounds → run
    // bails → tryEval returns null (legacy fallback), NOT a debug panic.
    try std.testing.expect(vm.tryEval(alloc, &module, bad_id, null, null) == null);
}

test "comptime_vm: arena allocations are aligned, non-null, and stable across grows" {
    var m = vm.Machine.init(std.testing.allocator);
    defer m.deinit();

    const a = m.allocBytes(16, 8);
    try std.testing.expect(a != vm.null_addr);
    try std.testing.expectEqual(@as(u64, 0), a % 8);
    try m.writeWord(a, 8, 0xCAFEBABE);

    // A later (much larger) allocation must NOT move or clobber the first — the
    // arena never relocates an existing allocation (the property the FFI bridge
    // relies on).
    const b = m.allocBytes(1 << 20, 16);
    try std.testing.expect(b != vm.null_addr);
    try std.testing.expectEqual(@as(u64, 0), b % 16);
    try std.testing.expectEqual(@as(u64, 0xCAFEBABE), try m.readWord(a, 8));
}

test "comptime_vm: Frame register file round-trips (no stack reclaim)" {
    var frame = vm.Frame.init(std.testing.allocator, 4);
    defer frame.deinit();

    // Registers default to zero, then round-trip.
    try std.testing.expectEqual(@as(vm.Reg, 0), frame.get(2));
    frame.set(2, 0x1234);
    try std.testing.expectEqual(@as(vm.Reg, 0x1234), frame.get(2));
}
