// Tests for the IR-to-LLVM emitter (emit_llvm.zig).

const std = @import("std");
const types = @import("types.zig");
const inst_mod = @import("inst.zig");
const mod_mod = @import("module.zig");
const emit_mod = @import("emit_llvm.zig");
const c = @import("../llvm_api.zig").c;

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;
const Module = mod_mod.Module;
const Builder = mod_mod.Builder;
const LLVMEmitter = emit_mod.LLVMEmitter;

// ── Helper ──────────────────────────────────────────────────────────────

fn str(module: *Module, s: []const u8) types.StringId {
    return module.types.internString(s);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "emit: aggressive optimization runs LLVM's O3 pipeline" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var emitter = LLVMEmitter.init(alloc, &module, "test_o3_pipeline", .{ .opt_level = .aggressive });
    defer emitter.deinit();

    // Build optimizer_probe() { slot = 40; return slot + 2; } directly in
    // LLVM IR. The unoptimized module must contain memory traffic; O3's
    // mem2reg + constant folding must reduce it to `ret i64 42`.
    const fn_ty = c.LLVMFunctionType(emitter.cached_i64, null, 0, 0);
    const func = c.LLVMAddFunction(emitter.llvm_module, "optimizer_probe", fn_ty);
    const entry = c.LLVMAppendBasicBlockInContext(emitter.context, func, "entry");
    c.LLVMPositionBuilderAtEnd(emitter.builder, entry);
    const slot = c.LLVMBuildAlloca(emitter.builder, emitter.cached_i64, "slot");
    _ = c.LLVMBuildStore(emitter.builder, c.LLVMConstInt(emitter.cached_i64, 40, 0), slot);
    const loaded = c.LLVMBuildLoad2(emitter.builder, emitter.cached_i64, slot, "loaded");
    const sum = c.LLVMBuildAdd(emitter.builder, loaded, c.LLVMConstInt(emitter.cached_i64, 2, 0), "sum");
    _ = c.LLVMBuildRet(emitter.builder, sum);

    try emitter.verifyWithMessage();
    const before = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, before, "alloca i64") != null);

    try emitter.optimize();
    try emitter.verifyWithMessage();
    const after = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, after, "alloca i64") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "ret i64 42") != null);
}

test "emit: main() returns 42" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func main() -> i64 { return 42; }
    _ = b.beginFunction(str(&module, "main"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);
    const c42 = b.constInt(42, .i64);
    b.ret(c42, .i64);
    b.finalize();

    // Emit to LLVM
    var emitter = LLVMEmitter.init(alloc, &module, "test_ret42", .{});
    defer emitter.deinit();
    emitter.emit();

    // Verify the module is valid
    try std.testing.expect(emitter.verify());

    // Check LLVM IR contains expected patterns
    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "define") != null);
    // `main` is emitted with the C entry-point convention: it returns i32, so
    // the i64 const 42 is truncated to `ret i32 42`.
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "ret i32 42") != null);
}

test "emit: add(a, b) returns a + b" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func add(a: i64, b: i64) -> i64 { return a + b; }
    const params = &[_]Function.Param{
        .{ .name = str(&module, "a"), .ty = .i64 },
        .{ .name = str(&module, "b"), .ty = .i64 },
    };
    _ = b.beginFunction(str(&module, "add"), params, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    // Parameters are refs 0 and 1 — but in our IR they're passed as
    // arguments to the interpreter. For the LLVM emitter, we need to
    // load them from LLVM function params. For now, use constInt as
    // placeholders since we haven't wired up param→ref mapping yet.
    //
    // Actually, looking at the IR design: the Builder's inst_counter starts
    // at 0, and params are accessed differently. The lowering pass emits
    // alloca+store for params. For this test, we use const_int to test
    // the add instruction directly.
    const a = b.constInt(10, .i64);
    const a_b = b.constInt(32, .i64);
    const sum = b.add(a, a_b, .i64);
    b.ret(sum, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_add", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "add") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "ret i64") != null);
}

test "emit: float arithmetic" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // Operands must be non-constant (function params) or LLVM constant-folds
    // the arithmetic away and no fadd/fmul instruction is emitted.
    _ = b.beginFunction(str(&module, "fmath"), &[_]Function.Param{
        .{ .name = str(&module, "x"), .ty = .f64 },
        .{ .name = str(&module, "y"), .ty = .f64 },
    }, .f64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const a = Ref.fromIndex(0);
    const a_b = Ref.fromIndex(1);
    const sum = b.add(a, a_b, .f64);
    const product = b.mul(sum, a_b, .f64);
    b.ret(product, .f64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_float", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "fadd") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "fmul") != null);
}

test "emit: negation" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // Negating a constant folds; negate a param so `sub 0, %x` is emitted.
    _ = b.beginFunction(str(&module, "negate"), &[_]Function.Param{
        .{ .name = str(&module, "x"), .ty = .i64 },
    }, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const val = Ref.fromIndex(0);
    const neg = b.emit(.{ .neg = .{ .operand = val } }, .i64);
    b.ret(neg, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_neg", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    // LLVM represents neg as "sub nsw i64 0, %val" or "sub i64 0, %val"
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "sub") != null);
}

test "emit: void function" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    _ = b.beginFunction(str(&module, "noop"), &.{}, .void);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);
    b.retVoid();
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_void", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "ret void") != null);
}

test "emit: alloca, store, load" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func f() -> i64 { var x: i64 = 10; return x; }
    _ = b.beginFunction(str(&module, "f"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const x_ptr = b.alloca(.i64); // alloca i64 → *i64
    const ten = b.constInt(10, .i64);
    b.store(x_ptr, ten); // store 10 → *x
    const loaded = b.load(x_ptr, .i64); // load *x → i64
    b.ret(loaded, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_mem", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "alloca") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "store") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "load") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "ret i64") != null);
}

test "emit: atomic load/store (seq_cst, aligned)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func f() -> i64 { var x: i64; atomic_store(&x, 10, seq_cst);
    //                   return atomic_load(&x, seq_cst); }
    _ = b.beginFunction(str(&module, "f"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const x_ptr = b.alloca(.i64);
    const ten = b.constInt(10, .i64);
    b.emitVoid(.{ .atomic_store = .{ .ptr = x_ptr, .val = ten, .val_ty = .i64, .ordering = .seq_cst } }, .void);
    const loaded = b.emit(.{ .atomic_load = .{ .ptr = x_ptr, .ordering = .seq_cst } }, .i64);
    b.ret(loaded, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_atomic", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    // Atomic load/store with seq_cst ordering AND a mandatory alignment.
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "load atomic") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "store atomic") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "seq_cst") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "align 8") != null);
}

test "emit: atomic rmw (add + signed/unsigned min)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    _ = b.beginFunction(str(&module, "f"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const si = b.alloca(.i64);
    const ui = b.alloca(.u64);
    const five = b.constInt(5, .i64);
    _ = b.emit(.{ .atomic_rmw = .{ .ptr = si, .operand = five, .val_ty = .i64, .ordering = .seq_cst, .kind = .add } }, .i64);
    _ = b.emit(.{ .atomic_rmw = .{ .ptr = si, .operand = five, .val_ty = .i64, .ordering = .seq_cst, .kind = .min } }, .i64);
    _ = b.emit(.{ .atomic_rmw = .{ .ptr = ui, .operand = five, .val_ty = .u64, .ordering = .seq_cst, .kind = .min } }, .u64);
    b.ret(five, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_rmw", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "atomicrmw add") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "atomicrmw min") != null); // signed i64
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "atomicrmw umin") != null); // unsigned u64
}

test "emit: atomic swap (xchg) + fence" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    _ = b.beginFunction(str(&module, "f"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const p = b.alloca(.i64);
    const five = b.constInt(5, .i64);
    const old = b.emit(.{ .atomic_rmw = .{ .ptr = p, .operand = five, .val_ty = .i64, .ordering = .acq_rel, .kind = .xchg } }, .i64);
    b.emitVoid(.{ .atomic_fence = .{ .ordering = .seq_cst } }, .void);
    b.ret(old, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_swap_fence", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "atomicrmw xchg") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "fence seq_cst") != null);
}

test "emit: atomic cmpxchg (strong + weak)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    const opt_i64 = module.types.optionalOf(.i64); // ?i64 result type

    _ = b.beginFunction(str(&module, "f"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const p = b.alloca(.i64);
    const exp = b.constInt(1, .i64);
    const des = b.constInt(2, .i64);
    // strong CAS
    _ = b.emit(.{ .atomic_cmpxchg = .{ .ptr = p, .cmp = exp, .new = des, .val_ty = .i64, .success_ordering = .acq_rel, .failure_ordering = .acquire, .weak = false } }, opt_i64);
    // weak CAS
    _ = b.emit(.{ .atomic_cmpxchg = .{ .ptr = p, .cmp = exp, .new = des, .val_ty = .i64, .success_ordering = .seq_cst, .failure_ordering = .seq_cst, .weak = true } }, opt_i64);
    b.ret(exp, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_cas", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "cmpxchg") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "cmpxchg weak") != null); // the weak marker
}

test "emit: comparison and branch" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func f(a, b) -> i64 { if (a < b) return 1; else return 0; }
    // Params (not constants) so the icmp isn't folded.
    _ = b.beginFunction(str(&module, "cmpfn"), &[_]Function.Param{
        .{ .name = str(&module, "a"), .ty = .i64 },
        .{ .name = str(&module, "b"), .ty = .i64 },
    }, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    const then_bb = b.appendBlock(str(&module, "then"), &.{});
    const else_bb = b.appendBlock(str(&module, "else"), &.{});
    b.switchToBlock(entry);

    const a = Ref.fromIndex(0);
    const b_val = Ref.fromIndex(1);
    const cond = b.cmpLt(a, b_val);
    b.condBr(cond, then_bb, &.{}, else_bb, &.{});

    b.switchToBlock(then_bb);
    const one = b.constInt(1, .i64);
    b.ret(one, .i64);

    b.switchToBlock(else_bb);
    const zero = b.constInt(0, .i64);
    b.ret(zero, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_cmp", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "icmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "br i1") != null);
}

test "emit: function call" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func add(a: i64, b: i64) -> i64 { return a + b; }  (using constants)
    const add_id = b.beginFunction(str(&module, "addfn"), &[_]Function.Param{
        .{ .name = str(&module, "a"), .ty = .i64 },
        .{ .name = str(&module, "b"), .ty = .i64 },
    }, .i64);
    const add_entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(add_entry);
    const p0 = b.constInt(0, .i64); // placeholder
    const p1 = b.constInt(0, .i64);
    const sum = b.add(p0, p1, .i64);
    b.ret(sum, .i64);
    b.finalize();

    // func main() -> i64 { return addfn(3, 4); }
    _ = b.beginFunction(str(&module, "main"), &.{}, .i64);
    const main_entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(main_entry);
    const three = b.constInt(3, .i64);
    const four = b.constInt(4, .i64);
    const result = b.call(add_id, &.{ three, four }, .i64);
    b.ret(result, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_call", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "call") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "addfn") != null);
}

test "emit: widen conversion i32 to i64" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // sext of a constant folds; widen a param so `sext` is emitted.
    _ = b.beginFunction(str(&module, "wfn"), &[_]Function.Param{
        .{ .name = str(&module, "x"), .ty = .i32 },
    }, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const val = Ref.fromIndex(0);
    const wide = b.widen(val, .i32, .i64);
    b.ret(wide, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_widen", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "sext") != null);
}

test "emit: type conversion toLLVMType" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var emitter = LLVMEmitter.init(alloc, &module, "test_types", .{});
    defer emitter.deinit();

    // Just verify toLLVMType doesn't crash for all builtin types
    _ = emitter.toLLVMType(.void);
    _ = emitter.toLLVMType(.bool);
    _ = emitter.toLLVMType(.i8);
    _ = emitter.toLLVMType(.i16);
    _ = emitter.toLLVMType(.i32);
    _ = emitter.toLLVMType(.i64);
    _ = emitter.toLLVMType(.u8);
    _ = emitter.toLLVMType(.u16);
    _ = emitter.toLLVMType(.u32);
    _ = emitter.toLLVMType(.u64);
    _ = emitter.toLLVMType(.f32);
    _ = emitter.toLLVMType(.f64);
    _ = emitter.toLLVMType(.string);
    _ = emitter.toLLVMType(.any);
    _ = emitter.toLLVMType(.noreturn);
}

// ── A7.1 scaffolding: ABI param coercion ────────────────────────────
// Lock the C-ABI struct-coercion buckets (abiCoerceParamType / needsByval),
// which feed callconv(.c) / #extern signatures, before they move to
// src/backend/llvm/abi.zig in A7.1 sub-step 2.

const llvm = @import("../llvm_api.zig");
const cc = llvm.c;

fn internStruct(module: *Module, name: []const u8, field_tys: []const TypeId) TypeId {
    var fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
    defer fields.deinit(std.testing.allocator);
    for (field_tys, 0..) |fty, i| {
        var nb: [8]u8 = undefined;
        const fname = std.fmt.bufPrint(&nb, "f{d}", .{i}) catch unreachable;
        fields.append(std.testing.allocator, .{ .name = str(module, fname), .ty = fty }) catch unreachable;
    }
    // Dupe into the module arena so the interned struct's field slice lives for
    // the module's lifetime (freed at module.deinit) — no testing-allocator leak.
    const owned = module.slice_arena.allocator().dupe(types.TypeInfo.StructInfo.Field, fields.items) catch unreachable;
    return module.types.intern(.{ .@"struct" = .{ .name = str(module, name), .fields = owned } });
}

test "emit: abiCoerceParamType coerces C-ABI structs by size bucket" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // Intern the shapes before building the emitter (toLLVMType reads live).
    const small = internStruct(&module, "Small", &.{ .i32, .i32 }); // 8 bytes
    const mid = internStruct(&module, "Mid", &.{ .i64, .i64 }); //    16 bytes
    const big = internStruct(&module, "Big", &.{ .i64, .i64, .i64 }); // 24 bytes
    const hfa_f = internStruct(&module, "HfaF", &.{ .f32, .f32, .f32, .f32 }); // 16, all-float
    const hfa_d = internStruct(&module, "HfaD", &.{ .f64, .f64 }); // 16, all-double
    const sl = module.types.sliceOf(.i32);

    var emitter = LLVMEmitter.init(alloc, &module, "test_abi", .{});
    defer emitter.deinit();

    // ≤ 8 bytes → i64.
    try std.testing.expect(emitter.abiCoerceParamType(small, emitter.toLLVMType(small)) == emitter.cached_i64);
    // 9–16 bytes → [2 x i64].
    try std.testing.expect(emitter.abiCoerceParamType(mid, emitter.toLLVMType(mid)) == cc.LLVMArrayType2(emitter.cached_i64, 2));
    // > 16 bytes → ptr (passed byval at the call/sig sites).
    try std.testing.expect(emitter.abiCoerceParamType(big, emitter.toLLVMType(big)) == emitter.cached_ptr);
    // HFA (all-float / all-double, ≤ 4 fields) → unchanged.
    try std.testing.expect(emitter.abiCoerceParamType(hfa_f, emitter.toLLVMType(hfa_f)) == emitter.toLLVMType(hfa_f));
    try std.testing.expect(emitter.abiCoerceParamType(hfa_d, emitter.toLLVMType(hfa_d)) == emitter.toLLVMType(hfa_d));
    // string / slice collapse to ptr at the C-API boundary (len dropped).
    try std.testing.expect(emitter.abiCoerceParamType(.string, emitter.toLLVMType(.string)) == emitter.cached_ptr);
    try std.testing.expect(emitter.abiCoerceParamType(sl, emitter.toLLVMType(sl)) == emitter.cached_ptr);
    // Scalars pass through unchanged.
    try std.testing.expect(emitter.abiCoerceParamType(.i32, emitter.toLLVMType(.i32)) == emitter.toLLVMType(.i32));
}

// issue 0286: default ABI must pack ≤8-byte non-HFA structs (Color-shaped
// `{i8×4}`) into i64 so AArch64 does not expand them into four i8 args that
// mis-spill. string / HFA / mid / large stay raw.
test "emit: abiCoerceDefaultParamType packs only small non-HFA structs" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    const color = internStruct(&module, "Color", &.{ .u8, .u8, .u8, .u8 }); // 4 bytes
    const pair = internStruct(&module, "Pair", &.{ .i32, .i32 }); // 8 bytes
    const mid = internStruct(&module, "Mid", &.{ .i64, .i64 }); // 16 bytes
    const big = internStruct(&module, "Big", &.{ .i64, .i64, .i64 }); // 24 bytes
    const hfa_f = internStruct(&module, "HfaF", &.{ .f32, .f32 }); // HFA
    const sl = module.types.sliceOf(.i32);

    var emitter = LLVMEmitter.init(alloc, &module, "test_default_abi", .{});
    defer emitter.deinit();

    try std.testing.expect(emitter.abiCoerceDefaultParamType(color, emitter.toLLVMType(color)) == emitter.cached_i64);
    try std.testing.expect(emitter.abiCoerceDefaultParamType(pair, emitter.toLLVMType(pair)) == emitter.cached_i64);
    // Mid / big / HFA / string / slice unchanged on the default path.
    try std.testing.expect(emitter.abiCoerceDefaultParamType(mid, emitter.toLLVMType(mid)) == emitter.toLLVMType(mid));
    try std.testing.expect(emitter.abiCoerceDefaultParamType(big, emitter.toLLVMType(big)) == emitter.toLLVMType(big));
    try std.testing.expect(emitter.abiCoerceDefaultParamType(hfa_f, emitter.toLLVMType(hfa_f)) == emitter.toLLVMType(hfa_f));
    try std.testing.expect(emitter.abiCoerceDefaultParamType(.string, emitter.toLLVMType(.string)) == emitter.toLLVMType(.string));
    try std.testing.expect(emitter.abiCoerceDefaultParamType(sl, emitter.toLLVMType(sl)) == emitter.toLLVMType(sl));
    try std.testing.expect(emitter.abiCoerceDefaultParamType(.i32, emitter.toLLVMType(.i32)) == emitter.toLLVMType(.i32));
}

test "emit: needsByval only for > 16-byte non-HFA structs" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    const small = internStruct(&module, "Small", &.{ .i32, .i32 });
    const mid = internStruct(&module, "Mid", &.{ .i64, .i64 });
    const big = internStruct(&module, "Big", &.{ .i64, .i64, .i64 });
    const hfa_d = internStruct(&module, "HfaD", &.{ .f64, .f64 });
    const sl = module.types.sliceOf(.i32);

    var emitter = LLVMEmitter.init(alloc, &module, "test_byval", .{});
    defer emitter.deinit();

    try std.testing.expect(emitter.needsByval(big, emitter.toLLVMType(big))); // > 16
    try std.testing.expect(!emitter.needsByval(small, emitter.toLLVMType(small)));
    try std.testing.expect(!emitter.needsByval(mid, emitter.toLLVMType(mid))); // exactly 16
    try std.testing.expect(!emitter.needsByval(hfa_d, emitter.toLLVMType(hfa_d))); // HFA
    try std.testing.expect(!emitter.needsByval(.string, emitter.toLLVMType(.string)));
    try std.testing.expect(!emitter.needsByval(sl, emitter.toLLVMType(sl)));
    try std.testing.expect(!emitter.needsByval(.i32, emitter.toLLVMType(.i32))); // non-struct
}

// ── Struct/Enum/Union tests ─────────────────────────────────────────

test "emit: struct_init and struct_get" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // Create a struct type: Point { x: i64, y: i64 }
    const fields = &[_]types.TypeInfo.StructInfo.Field{
        .{ .name = str(&module, "x"), .ty = .i64 },
        .{ .name = str(&module, "y"), .ty = .i64 },
    };
    const owned_fields = alloc.dupe(types.TypeInfo.StructInfo.Field, fields) catch unreachable;
    defer alloc.free(owned_fields);
    const point_ty = module.types.intern(.{ .@"struct" = .{
        .name = str(&module, "Point"),
        .fields = owned_fields,
    } });

    var b = Builder.init(&module);

    // func f(v) -> i64 { p = Point{v, 20}; return p.y; }
    // A param operand keeps the aggregate non-constant so insertvalue /
    // extractvalue survive (a fully-constant struct would be folded).
    _ = b.beginFunction(str(&module, "f"), &[_]Function.Param{
        .{ .name = str(&module, "v"), .ty = .i64 },
    }, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const x = Ref.fromIndex(0);
    const y = b.constInt(20, .i64);
    const p = b.structInit(&.{ x, y }, point_ty);
    const py = b.structGet(p, 1, .i64);
    b.ret(py, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_struct", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "insertvalue") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "extractvalue") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "ret i64") != null);
}

test "emit: struct_gep (pointer to field)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // Create struct type
    const fields = &[_]types.TypeInfo.StructInfo.Field{
        .{ .name = str(&module, "x"), .ty = .i64 },
        .{ .name = str(&module, "y"), .ty = .i64 },
    };
    const owned_fields = alloc.dupe(types.TypeInfo.StructInfo.Field, fields) catch unreachable;
    defer alloc.free(owned_fields);
    const point_ty = module.types.intern(.{ .@"struct" = .{
        .name = str(&module, "Point"),
        .fields = owned_fields,
    } });
    const ptr_i64 = module.types.ptrTo(.i64);

    var b = Builder.init(&module);

    // func f() -> i64 { var p: Point; p.y = 42; return p.y; }
    _ = b.beginFunction(str(&module, "gepfn"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const p_ptr = b.alloca(point_ty);
    const y_ptr = b.structGepTyped(p_ptr, 1, ptr_i64, point_ty);
    const c42 = b.constInt(42, .i64);
    b.store(y_ptr, c42);
    const loaded = b.load(y_ptr, .i64);
    b.ret(loaded, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_gep", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "getelementptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "store") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "ret i64") != null);
}

test "emit: struct_gep with unrecoverable aggregate metadata fails loudly" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);
    _ = b.beginFunction(str(&module, "invalid_struct_gep"), &.{}, .void);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    // A scalar alloca is pointer-shaped at LLVM level, but neither its IR nor
    // LLVM producer metadata names an aggregate. It must not become i64 GEP IR.
    const scalar_ptr = b.alloca(.i64);
    _ = b.structGep(scalar_ptr, 0, module.types.ptrTo(.i64));
    b.retVoid();
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_invalid_struct_gep", .{});
    defer emitter.deinit();
    emitter.print_emission_diagnostics = false;
    emitter.emit();

    try std.testing.expect(emitter.emission_failed);
    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "getelementptr i64") == null);
}

test "emit: union_gep with unrecoverable aggregate metadata fails loudly" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);
    _ = b.beginFunction(str(&module, "invalid_union_gep"), &.{}, .void);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const scalar_ptr = b.alloca(.i64);
    _ = b.emit(.{ .union_gep = .{ .base = scalar_ptr, .field_index = 0 } }, module.types.ptrTo(.i64));
    b.retVoid();
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_invalid_union_gep", .{});
    defer emitter.deinit();
    emitter.print_emission_diagnostics = false;
    emitter.emit();

    try std.testing.expect(emitter.emission_failed);
    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "getelementptr i64") == null);
}

test "emit: enum_init and enum_tag (plain enum)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // Create a plain enum type: Color { Red, Green, Blue }
    const variants = &[_]types.StringId{
        str(&module, "Red"),
        str(&module, "Green"),
        str(&module, "Blue"),
    };
    const owned_variants = alloc.dupe(types.StringId, variants) catch unreachable;
    defer alloc.free(owned_variants);
    const color_ty = module.types.intern(.{ .@"enum" = .{
        .name = str(&module, "Color"),
        .variants = owned_variants,
    } });

    var b = Builder.init(&module);

    // func f() -> i64 { c = Color.Green; return tag(c); }
    _ = b.beginFunction(str(&module, "enumfn"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const green = b.enumInit(1, Ref.none, color_ty); // Green = tag 1
    const tag = b.enumTag(green, .i32);
    // Widen tag from i32 to i64 for the return
    const wide = b.widen(tag, .i32, .i64);
    b.ret(wide, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_enum", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    // Plain enum is just an integer constant
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "ret i64") != null);
}

test "emit: tagged union (enum_init with payload, enum_tag, enum_payload)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // Create a tagged union: Shape { Circle: f64, Rect: i64 }
    const ufields = &[_]types.TypeInfo.StructInfo.Field{
        .{ .name = str(&module, "Circle"), .ty = .f64 },
        .{ .name = str(&module, "Rect"), .ty = .i64 },
    };
    const owned_ufields = alloc.dupe(types.TypeInfo.StructInfo.Field, ufields) catch unreachable;
    defer alloc.free(owned_ufields);
    const shape_ty = module.types.intern(.{ .tagged_union = .{
        .name = str(&module, "Shape"),
        .fields = owned_ufields,
        .tag_type = .i64,
    } });

    var b = Builder.init(&module);

    // func f(r) -> f64 { s = Shape.Circle(r); ...; return payload; }
    // Param payload keeps the union value non-constant (else folded).
    _ = b.beginFunction(str(&module, "unionfn"), &[_]Function.Param{
        .{ .name = str(&module, "r"), .ty = .f64 },
    }, .f64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const radius = Ref.fromIndex(0);
    const shape = b.enumInit(0, radius, shape_ty); // Circle = tag 0
    const tag = b.emit(.{ .enum_tag = .{ .operand = shape } }, .i64);
    _ = tag; // tag is used but we just check it doesn't crash
    const payload = b.emit(.{ .enum_payload = .{ .base = shape, .field_index = 0 } }, .f64);
    b.ret(payload, .f64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_union", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    // Tagged-union enum_init/enum_payload lower to a memory pattern
    // (alloca + GEP + store/load), not SSA insert/extractvalue. enum_tag
    // does emit extractvalue.
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "alloca") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "getelementptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "extractvalue") != null);
}

test "emit: union_get (reinterpret union field)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    // Untagged union: Data { as_int: i64, as_float: f64 }
    const ufields = &[_]types.TypeInfo.StructInfo.Field{
        .{ .name = str(&module, "as_int"), .ty = .i64 },
        .{ .name = str(&module, "as_float"), .ty = .f64 },
    };
    const owned_ufields = alloc.dupe(types.TypeInfo.StructInfo.Field, ufields) catch unreachable;
    defer alloc.free(owned_ufields);
    const data_ty = module.types.intern(.{ .@"union" = .{
        .name = str(&module, "Data"),
        .fields = owned_ufields,
    } });

    var b = Builder.init(&module);

    // func f() -> i64 { d = Data.as_int(42); return union_get(d, 0) as i64; }
    _ = b.beginFunction(str(&module, "ugfn"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const val = b.constInt(42, .i64);
    const d = b.enumInit(0, val, data_ty);
    const got = b.emit(.{ .union_get = .{ .base = d, .field_index = 0 } }, .i64);
    b.ret(got, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_union_get", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    // Should contain alloca + store + GEP + load pattern
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "alloca") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "load") != null);
}

// ── Array/Slice tests ───────────────────────────────────────────────

test "emit: array index_get" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    const arr_ty = module.types.arrayOf(.i64, 3);

    var b = Builder.init(&module);

    // func f() -> i64 { arr: [3]i64 = ---; return arr[1]; }
    _ = b.beginFunction(str(&module, "arr_idx"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const undef_arr = b.emit(.{ .const_undef = {} }, arr_ty);
    const idx = b.constInt(1, .i64);
    const elem = b.emit(.{ .index_get = .{ .lhs = undef_arr, .rhs = idx } }, .i64);
    b.ret(elem, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_arr_idx", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "getelementptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "ret i64") != null);
}

test "emit: length on slice" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func f(s: string) -> i64 { return s.len; }
    // A string param keeps the value non-constant so extractvalue survives.
    _ = b.beginFunction(str(&module, "strlen"), &[_]Function.Param{
        .{ .name = str(&module, "s"), .ty = .string },
    }, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const s = Ref.fromIndex(0);
    const len = b.emit(.{ .length = .{ .operand = s } }, .i64);
    b.ret(len, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_len", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "extractvalue") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "ret i64") != null);
}

test "emit: data_ptr on slice" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    const ptr_ty = module.types.ptrTo(.u8);

    var b = Builder.init(&module);

    // func f(s: string) -> *u8 { return s.ptr; }
    // Param string → extractvalue survives (a constant string would fold).
    _ = b.beginFunction(str(&module, "dptr"), &[_]Function.Param{
        .{ .name = str(&module, "s"), .ty = .string },
    }, ptr_ty);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const s = Ref.fromIndex(0);
    const ptr = b.emit(.{ .data_ptr = .{ .operand = s } }, ptr_ty);
    b.ret(ptr, ptr_ty);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_dptr", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "extractvalue") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "ret ptr") != null);
}

test "emit: array_to_slice" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    const arr_ty = module.types.arrayOf(.i64, 4);
    const slice_ty = module.types.sliceOf(.i64);

    var b = Builder.init(&module);

    // func f() -> []i64 { var arr: [4]i64 = ---; return arr[:]; }
    _ = b.beginFunction(str(&module, "a2s"), &.{}, slice_ty);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const undef_arr = b.emit(.{ .const_undef = {} }, arr_ty);
    const slice = b.emit(.{ .array_to_slice = .{ .operand = undef_arr } }, slice_ty);
    b.ret(slice, slice_ty);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_a2s", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    // Should have GEP for array decay + insertvalue for slice construction
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "getelementptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "insertvalue") != null);
}

test "emit: subslice" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    const slice_ty = module.types.sliceOf(.u8);

    var b = Builder.init(&module);

    // func f(s: []u8, lo: i64, hi: i64) -> []u8 { return s[lo..hi]; }
    // All operands are params: a constant base folds the GEP, and constant
    // lo/hi fold the `hi - lo` subtraction.
    _ = b.beginFunction(str(&module, "ssfn"), &[_]Function.Param{
        .{ .name = str(&module, "s"), .ty = slice_ty },
        .{ .name = str(&module, "lo"), .ty = .i64 },
        .{ .name = str(&module, "hi"), .ty = .i64 },
    }, slice_ty);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const s = Ref.fromIndex(0);
    const lo = Ref.fromIndex(1);
    const hi = Ref.fromIndex(2);
    const sub = b.emit(.{ .subslice = .{ .base = s, .lo = lo, .hi = hi } }, slice_ty);
    b.ret(sub, slice_ty);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_subslice", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    // Should have GEP for ptr+lo and sub for hi-lo
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "getelementptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "sub") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "insertvalue") != null);
}

// ── Optional tests ──────────────────────────────────────────────────

test "emit: optional_wrap and optional_unwrap (value type)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    const opt_ty = module.types.optionalOf(.i64);

    var b = Builder.init(&module);

    // func f(v) -> i64 { opt = wrap(v); return unwrap(opt); }
    // Param value keeps the optional non-constant (else insertvalue folds).
    _ = b.beginFunction(str(&module, "optfn"), &[_]Function.Param{
        .{ .name = str(&module, "v"), .ty = .i64 },
    }, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const val = Ref.fromIndex(0);
    const wrapped = b.optionalWrap(val, opt_ty);
    const unwrapped = b.optionalUnwrap(wrapped, .i64);
    b.ret(unwrapped, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_opt", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    // wrap = insertvalue, unwrap = extractvalue
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "insertvalue") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "extractvalue") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "ret i64") != null);
}

test "emit: optional_has_value" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    const opt_ty = module.types.optionalOf(.i64);

    var b = Builder.init(&module);

    // Param value keeps the optional non-constant (else extractvalue folds).
    _ = b.beginFunction(str(&module, "hasfn"), &[_]Function.Param{
        .{ .name = str(&module, "v"), .ty = .i64 },
    }, .bool);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const val = Ref.fromIndex(0);
    const wrapped = b.optionalWrap(val, opt_ty);
    const has = b.optionalHasValue(wrapped);
    b.ret(has, .bool);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_has", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "extractvalue") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "ret i1") != null);
}

// ── Switch branch test ──────────────────────────────────────────────

test "emit: switch_br" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func f(x: i64) -> i64 { match x { 0 => 10, 1 => 20, _ => 30 } }
    _ = b.beginFunction(str(&module, "swfn"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    const case0 = b.appendBlock(str(&module, "case0"), &.{});
    const case1 = b.appendBlock(str(&module, "case1"), &.{});
    const default_bb = b.appendBlock(str(&module, "default"), &.{});
    b.switchToBlock(entry);

    const x = b.constInt(1, .i64);
    const cases = alloc.dupe(inst_mod.SwitchBranch.Case, &.{
        .{ .value = 0, .target = case0, .args = &.{} },
        .{ .value = 1, .target = case1, .args = &.{} },
    }) catch unreachable;
    defer alloc.free(cases);
    b.emitVoid(.{ .switch_br = .{
        .operand = x,
        .cases = cases,
        .default = default_bb,
        .default_args = &.{},
    } }, .void);

    b.switchToBlock(case0);
    b.ret(b.constInt(10, .i64), .i64);

    b.switchToBlock(case1);
    b.ret(b.constInt(20, .i64), .i64);

    b.switchToBlock(default_bb);
    b.ret(b.constInt(30, .i64), .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_switch", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "switch") != null);
}

// ── Closure test ────────────────────────────────────────────────────

test "emit: closure_create" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    const closure_ty = module.types.closureType(&.{.i64}, .i64);

    var b = Builder.init(&module);

    // Create a dummy trampoline function
    const tramp_id = b.beginFunction(str(&module, "tramp"), &[_]inst_mod.Function.Param{
        .{ .name = str(&module, "env"), .ty = .i64 },
        .{ .name = str(&module, "x"), .ty = .i64 },
    }, .i64);
    const tramp_entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(tramp_entry);
    b.ret(b.constInt(0, .i64), .i64);
    b.finalize();

    // func f(e: *void) -> closure { return closure_create(tramp, e); }
    // A non-constant env keeps the {fn_ptr, env} aggregate non-constant so
    // the insertvalue isn't folded (a null env + constant fn_ptr would fold).
    const env_ty = module.types.ptrTo(.void);
    _ = b.beginFunction(str(&module, "mkclose"), &[_]inst_mod.Function.Param{
        .{ .name = str(&module, "e"), .ty = env_ty },
    }, closure_ty);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const cl = b.emit(.{ .closure_create = .{ .func = tramp_id, .env = Ref.fromIndex(0) } }, closure_ty);
    b.ret(cl, closure_ty);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_closure", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "insertvalue") != null);
}

// ── Box/Unbox Any test ──────────────────────────────────────────────

test "emit: box_any and unbox_any" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func f(v) -> i64 { slot = alloca; *slot = v; a = box(slot); return unbox(a); }
    // box_any takes the value's ADDRESS (the borrow representation); unbox_any
    // loads back through the view. Param value keeps the box non-constant.
    _ = b.beginFunction(str(&module, "anyfn"), &[_]Function.Param{
        .{ .name = str(&module, "v"), .ty = .i64 },
    }, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    const val = Ref.fromIndex(0);
    const slot = b.alloca(.i64);
    b.store(slot, val);
    const boxed = b.emit(.{ .box_any = .{ .operand = slot, .source_type = .i64 } }, .any);
    const unboxed = b.emit(.{ .unbox_any = .{ .operand = boxed } }, .i64);
    b.ret(unboxed, .i64);
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_any", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "insertvalue") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "extractvalue") != null);
}

test "emit: ERR E3.0 — DWARF debug info (compile unit + subprogram + per-inst location)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func main() -> i64 { return 42; } — with the `return` instruction
    // carrying a span that lands on line 3 of the source map below.
    _ = b.beginFunction(str(&module, "main"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);
    // "a\nb\nXYZ" — byte offset 4 ('X') is line 3, col 1.
    b.current_span = .{ .start = 4, .end = 5 };
    const c42 = b.constInt(42, .i64);
    b.ret(c42, .i64);
    b.finalize();

    // Source map keyed on the main file. setDebugContext + opt none
    // turns DWARF emission on (release opt levels skip it entirely).
    var sources = std.StringHashMap([:0]const u8).init(alloc);
    defer sources.deinit();
    try sources.put("probe.sx", "a\nb\nXYZ");

    var emitter = LLVMEmitter.init(alloc, &module, "test_dwarf", .{ .opt_level = .none });
    defer emitter.deinit();
    emitter.setDebugContext(&sources, "probe.sx");
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    // Module flags, compile unit on the main file, a subprogram for main,
    // and the return instruction's location resolved to line 3.
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "\"Debug Info Version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "\"Dwarf Version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "DICompileUnit") != null);
    // Regression: a bare filename (no directory component) must
    // still get a NON-EMPTY `directory:` — an empty `DW_AT_comp_dir` makes ld
    // silently drop the whole debug map, so the binary becomes undebuggable.
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "DIFile(filename: \"probe.sx\", directory: \".\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "DISubprogram(name: \"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "DILocation(line: 3") != null);
}

test "emit: ERR E3.0 — no DWARF without a debug context (unit-test default)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);
    _ = b.beginFunction(str(&module, "main"), &.{}, .i64);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);
    b.ret(b.constInt(42, .i64), .i64);
    b.finalize();

    // No setDebugContext call → no source map → debug info off even at
    // opt none. Confirms the gate keeps the metadata out by default.
    var emitter = LLVMEmitter.init(alloc, &module, "test_no_dwarf", .{ .opt_level = .none });
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());
    const ir_str = emitter.dumpToString();
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "DICompileUnit") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "!dbg") == null);
}

// ── FFI arg-type lookup must fail loudly, never silently `.void` ──
// `argIRTypeOrFail` backs the four FFI call-arg lowering sites (objc_msgSend,
// JNI Call<Type>Method / non-virtual / constructor). A ref it cannot resolve is
// a codegen invariant violation; it must surface the dedicated `.unresolved`
// tripwire sentinel (which `toLLVMType` hard-panics on) rather than the old
// silent `.void` default that would emit a void-typed extern-call argument.
test "emit: argIRTypeOrFail surfaces .unresolved for an unresolvable FFI arg ref (issue 0074)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func ffifn(a: i64, b: f64) -> void { <entry> }
    const fid = b.beginFunction(str(&module, "ffifn"), &[_]Function.Param{
        .{ .name = str(&module, "a"), .ty = .i64 },
        .{ .name = str(&module, "b"), .ty = .f64 },
    }, .void);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);
    b.retVoid();
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_ffi_argty", .{});
    defer emitter.deinit();
    emitter.current_func_idx = fid.index();

    // Happy path: a real arg ref (param 0 / param 1) resolves byte-identically
    // to its declared IR type — the FFI fast path is unchanged.
    try std.testing.expectEqual(TypeId.i64, emitter.argIRTypeOrFail(Ref.fromIndex(0)));
    try std.testing.expectEqual(TypeId.f64, emitter.argIRTypeOrFail(Ref.fromIndex(1)));

    // A ref past every param and instruction is unresolvable.
    const bogus = Ref.fromIndex(100_000);
    try std.testing.expectEqual(@as(?TypeId, null), emitter.getRefIRType(bogus));

    // Fail-before: the old `getRefIRType(arg) orelse .void` would silently
    // yield `.void` here — a real, load-bearing type that downstream ABI
    // coercion treats as a legitimate (void-typed) extern argument.
    try std.testing.expectEqual(TypeId.void, emitter.getRefIRType(bogus) orelse TypeId.void);

    // Pass-after: the helper returns the dedicated `.unresolved` sentinel,
    // never `.void`, so the failure cannot masquerade as a real type.
    try std.testing.expectEqual(TypeId.unresolved, emitter.argIRTypeOrFail(bogus));
    try std.testing.expect(emitter.argIRTypeOrFail(bogus) != .void);
}

// ── reflection-builtin arg-type lookup must fail loudly, never `.i64` ──
// `reflectArgRepr` backs the `type_name` / `type_eq` reflection builtins, which read
// their `Type` arg as a boxed `Any` aggregate (`.any` → extract value field) or a bare
// i64 TypeId index. A ref it cannot resolve is a codegen invariant violation; it must
// surface `.unresolved` (which the emit site hard-panics on) instead of the old silent
// `getRefIRType(arg) orelse .i64` default that would mis-classify a boxed arg as bare
// and read the wrong value with no diagnostic.
test "emit: reflectArgRepr surfaces .unresolved for an unresolvable reflection arg ref (issue 0075)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func reflfn(boxed: any, bare: i64) -> void { <entry> }
    const fid = b.beginFunction(str(&module, "reflfn"), &[_]Function.Param{
        .{ .name = str(&module, "boxed"), .ty = .any },
        .{ .name = str(&module, "bare"), .ty = .i64 },
    }, .void);
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);
    b.retVoid();
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_refl_argty", .{});
    defer emitter.deinit();
    emitter.current_func_idx = fid.index();

    // Happy path: a boxed `.any` Type arg classifies as `.boxed` (extract value
    // field); a bare `.i64` TypeId arg classifies as `.bare` (use directly).
    // These decisions are byte-identical to the pre-fix `== .any` gate.
    try std.testing.expectEqual(LLVMEmitter.ReflectArgRepr.boxed, emitter.reflectArgRepr(Ref.fromIndex(0)));
    try std.testing.expectEqual(LLVMEmitter.ReflectArgRepr.bare, emitter.reflectArgRepr(Ref.fromIndex(1)));

    // A ref past every param and instruction is unresolvable.
    const bogus = Ref.fromIndex(100_000);
    try std.testing.expectEqual(@as(?TypeId, null), emitter.getRefIRType(bogus));

    // Fail-before: the old `getRefIRType(arg) orelse .i64` would silently yield
    // `.i64` here — which `!= .any`, so the reflection arm would treat a failed
    // lookup as a bare i64 and read the wrong value with no diagnostic.
    try std.testing.expectEqual(TypeId.i64, emitter.getRefIRType(bogus) orelse TypeId.i64);
    try std.testing.expect((emitter.getRefIRType(bogus) orelse TypeId.i64) != .any);

    // Pass-after: the classifier returns the dedicated `.unresolved` variant,
    // never `.bare`, so the emit site trips its hard panic instead of silently
    // reading the wrong value.
    try std.testing.expectEqual(LLVMEmitter.ReflectArgRepr.unresolved, emitter.reflectArgRepr(bogus));
    try std.testing.expect(emitter.reflectArgRepr(bogus) != .bare);
}

test "emit: abi(.naked) function gets the naked attribute (no frame-pointer)" {
    const alloc = std.testing.allocator;
    var module = Module.init(alloc);
    defer module.deinit();

    var b = Builder.init(&module);

    // func answer() -> i64 abi(.naked) { asm volatile { "ret" }; unreachable }
    // The naked attribute is keyed off Function.is_naked in the declaration pass,
    // independent of the body — a minimal asm + unreachable body suffices.
    _ = b.beginFunction(str(&module, "answer"), &.{}, .i64);
    b.currentFunc().is_naked = true;
    const entry = b.appendBlock(str(&module, "entry"), &.{});
    b.switchToBlock(entry);

    b.emitVoid(.{ .inline_asm = .{
        .template = str(&module, "ret"),
        .operands = &.{},
        .clobbers = &.{},
        .has_side_effects = true,
    } }, .void);
    b.emitUnreachable();
    b.finalize();

    var emitter = LLVMEmitter.init(alloc, &module, "test_pure", .{});
    defer emitter.deinit();
    emitter.emit();

    try std.testing.expect(emitter.verify());

    const ir_str = emitter.dumpToString();
    // The naked attribute is present; a naked function carries no frame-pointer
    // attribute (incompatible with a frameless function).
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "naked") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir_str, "frame-pointer") == null);
}
