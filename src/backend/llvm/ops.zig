const std = @import("std");
const llvm = @import("../../llvm_api.zig");
const c = llvm.c;
const emit = @import("../../ir/emit_llvm.zig");
const ir_inst = @import("../../ir/inst.zig");
const ir_types = @import("../../ir/types.zig");
const comptime_vm = @import("../../ir/comptime_vm.zig");

const LLVMEmitter = emit.LLVMEmitter;
const Inst = ir_inst.Inst;
const BinOp = ir_inst.BinOp;
const UnaryOp = ir_inst.UnaryOp;
const Aggregate = ir_inst.Aggregate;
const FieldAccess = ir_inst.FieldAccess;
const EnumInit = ir_inst.EnumInit;
const Subslice = ir_inst.Subslice;
const Store = ir_inst.Store;
const AtomicLoad = ir_inst.AtomicLoad;
const AtomicStore = ir_inst.AtomicStore;
const AtomicRmw = ir_inst.AtomicRmw;
const AtomicCmpxchg = ir_inst.AtomicCmpxchg;
const AtomicFence = ir_inst.AtomicFence;
const Conversion = ir_inst.Conversion;
const GlobalId = ir_inst.GlobalId;
const GlobalSet = ir_inst.GlobalSet;
const FuncId = ir_inst.FuncId;
const Call = ir_inst.Call;
const CallIndirect = ir_inst.CallIndirect;
const ObjcMsgSend = ir_inst.ObjcMsgSend;
const JniMsgSend = ir_inst.JniMsgSend;
const InlineAsm = ir_inst.InlineAsm;
const BuiltinCall = ir_inst.BuiltinCall;
const TriOp = ir_inst.TriOp;
const Branch = ir_inst.Branch;
const CondBranch = ir_inst.CondBranch;
const SwitchBranch = ir_inst.SwitchBranch;
const BoxAny = ir_inst.BoxAny;
const MakeAny = ir_inst.MakeAny;
const ClosureCreate = ir_inst.ClosureCreate;
const BlockParam = ir_inst.BlockParam;
const FieldReflect = ir_inst.FieldReflect;
const TypeId = ir_types.TypeId;
const StringId = ir_types.StringId;
const Ref = ir_inst.Ref;

/// Instruction-emission handlers for `emitInst`: every opcode group — the
/// constant, arithmetic, bitwise, comparison, logical, memory, globals,
/// conversion, pointer, and call opcodes (direct/indirect/objc/jni dispatch
/// plus builtin, compiler, and closure calls), the aggregate ops (struct,
/// enum, union, array/slice, tuple, and optional), and the terminators,
/// box/unbox-Any, reflection, switch-branch, closure-creation, vector,
/// block-param, and misc ops. A backend `*LLVMEmitter` facade (field `e`):
/// each method emits one opcode's LLVM IR via `self.e.*`. The shared infra
/// these bodies call back into (`mapRef`/`resolveRef`/`advanceRefCounter`/
/// `getBlock`/`matchBinOpTypes`/`emitCmp`/`emitCmpOrdered`/`emitStrCmp`/
/// `emitStringConstant`/`reflection`/`emitConversion`/`coerceArg`/
/// `getRefIRType`/`loadJniFn`/`extractSlicePtr`/`emitJniConstructor`/
/// `emitFailableMainRet`/`emitFieldValueGet`/`resolveAggregate`/
/// `resolveGepStructType`) stays on `LLVMEmitter`. `emitInst`'s arms reach
/// these via `self.ops()`.
pub const Ops = struct {
    e: *LLVMEmitter,

    // ── Constants ───────────────────────────────────────────
    pub fn emitConstInt(self: Ops, instruction: *const Inst, val: i64) void {
        const ty = self.e.toLLVMType(instruction.ty);
        const kind = c.LLVMGetTypeKind(ty);
        const llvm_val = if (kind == c.LLVMIntegerTypeKind)
            c.LLVMConstInt(ty, @bitCast(val), 1)
        else if (kind == c.LLVMPointerTypeKind)
            c.LLVMConstNull(ty)
        else
            // void or other non-integer type: emit i64 0 as unused placeholder
            c.LLVMConstInt(c.LLVMInt64TypeInContext(self.e.context), 0, 0);
        self.e.mapRef(llvm_val);
    }

    pub fn emitConstFloat(self: Ops, instruction: *const Inst, val: f64) void {
        const ty = self.e.toLLVMType(instruction.ty);
        const llvm_val = c.LLVMConstReal(ty, val);
        self.e.mapRef(llvm_val);
    }

    pub fn emitConstBool(self: Ops, val: bool) void {
        const llvm_val = c.LLVMConstInt(self.e.cached_i1, @intFromBool(val), 0);
        self.e.mapRef(llvm_val);
    }

    pub fn emitIsComptime(self: Ops) void {
        // Compiled code is never the comptime interpreter → constant
        // `false`. A `if is_comptime() { … }` branch becomes dead.
        self.e.mapRef(c.LLVMConstInt(self.e.cached_i1, 0, 0));
    }

    pub fn emitInterpPrintFrames(self: Ops) void {
        // No interpreter stack in compiled code; this only ever sits in
        // a dead `is_comptime()` branch. Emit nothing.
        self.e.advanceRefCounter();
    }

    pub fn emitTraceFrame(self: Ops, instruction: *const Inst) void {
        self.e.mapRef(self.e.reflection().emitTraceFrame(instruction));
    }

    pub fn emitTraceResolve(self: Ops, u: UnaryOp) void {
        // The operand is a `Frame*` stamped in by `.trace_frame` (as
        // i64); reinterpret and load it.
        const raw = self.e.resolveRef(u.operand);
        const frame_ty = self.e.getFrameStructType();
        const ptr = c.LLVMBuildIntToPtr(self.e.builder, raw, self.e.cached_ptr, "frame.ptr");
        self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, frame_ty, ptr, "frame.val"));
    }

    pub fn emitConstString(self: Ops, str_id: StringId) void {
        const str = self.e.ir_mod.types.getString(str_id);
        const llvm_val = self.e.emitStringConstant(str);
        self.e.mapRef(llvm_val);
    }

    pub fn emitConstNull(self: Ops, instruction: *const Inst) void {
        const ty = if (instruction.ty == .void) self.e.cached_ptr else self.e.toLLVMType(instruction.ty);
        const llvm_val = c.LLVMConstNull(ty);
        self.e.mapRef(llvm_val);
    }

    pub fn emitConstUndef(self: Ops, instruction: *const Inst) void {
        if (instruction.ty == .void) {
            // void has no value — map to undef i64 as placeholder
            self.e.mapRef(c.LLVMGetUndef(self.e.cached_i64));
        } else {
            const ty = self.e.toLLVMType(instruction.ty);
            const llvm_val = c.LLVMGetUndef(ty);
            self.e.mapRef(llvm_val);
        }
    }

    pub fn emitConstType(self: Ops, tid: TypeId) void {
        // A Type value is an 8-byte handle: a bare i64 carrying `tid.index()`
        // (the `.type_value` builtin TypeId), distinct from the 16-byte boxed
        // `.any`. Flowing a Type into an `Any` slot boxes it via the standard
        // box-any coercion (`{ tag = .any.index(), value = tid }`); `case type:`
        // in `any_to_string` then matches tag == `.any.index()`, and runtime
        // `type_name(t)` reads the TypeId through `reflectArgTypeId` (`.bare`
        // when the arg is `.type_value`, `.boxed` when it is an Any).
        const val = c.LLVMConstInt(self.e.cached_i64, tid.index(), 0);
        self.e.mapRef(val);
    }

    // ── Arithmetic ─────────────────────────────────────────
    pub fn emitAdd(self: Ops, instruction: *const Inst, bin: BinOp) void {
        var lhs = self.e.resolveRef(bin.lhs);
        var rhs = self.e.resolveRef(bin.rhs);
        self.e.matchBinOpTypes(&lhs, &rhs, instruction.ty);
        const is_float = emit.isFloatOrVecFloat(instruction.ty, &self.e.ir_mod.types);
        const result = if (is_float)
            c.LLVMBuildFAdd(self.e.builder, lhs, rhs, "fadd")
        else
            c.LLVMBuildAdd(self.e.builder, lhs, rhs, "add");
        self.e.mapRef(result);
    }

    pub fn emitSub(self: Ops, instruction: *const Inst, bin: BinOp) void {
        var lhs = self.e.resolveRef(bin.lhs);
        var rhs = self.e.resolveRef(bin.rhs);
        self.e.matchBinOpTypes(&lhs, &rhs, instruction.ty);
        const is_float = emit.isFloatOrVecFloat(instruction.ty, &self.e.ir_mod.types);
        const result = if (is_float)
            c.LLVMBuildFSub(self.e.builder, lhs, rhs, "fsub")
        else
            c.LLVMBuildSub(self.e.builder, lhs, rhs, "sub");
        self.e.mapRef(result);
    }

    pub fn emitMul(self: Ops, instruction: *const Inst, bin: BinOp) void {
        var lhs = self.e.resolveRef(bin.lhs);
        var rhs = self.e.resolveRef(bin.rhs);
        self.e.matchBinOpTypes(&lhs, &rhs, instruction.ty);
        const is_float = emit.isFloatOrVecFloat(instruction.ty, &self.e.ir_mod.types);
        const result = if (is_float)
            c.LLVMBuildFMul(self.e.builder, lhs, rhs, "fmul")
        else
            c.LLVMBuildMul(self.e.builder, lhs, rhs, "mul");
        self.e.mapRef(result);
    }

    pub fn emitDiv(self: Ops, instruction: *const Inst, bin: BinOp) void {
        var lhs = self.e.resolveRef(bin.lhs);
        var rhs = self.e.resolveRef(bin.rhs);
        self.e.matchBinOpTypes(&lhs, &rhs, instruction.ty);
        const is_float = emit.isFloatOrVecFloat(instruction.ty, &self.e.ir_mod.types);
        const result = if (is_float)
            c.LLVMBuildFDiv(self.e.builder, lhs, rhs, "fdiv")
        else if (emit.isSignedType(instruction.ty))
            c.LLVMBuildSDiv(self.e.builder, lhs, rhs, "sdiv")
        else
            c.LLVMBuildUDiv(self.e.builder, lhs, rhs, "udiv");
        self.e.mapRef(result);
    }

    pub fn emitMod(self: Ops, instruction: *const Inst, bin: BinOp) void {
        var lhs = self.e.resolveRef(bin.lhs);
        var rhs = self.e.resolveRef(bin.rhs);
        self.e.matchBinOpTypes(&lhs, &rhs, instruction.ty);
        const is_float = emit.isFloatOrVecFloat(instruction.ty, &self.e.ir_mod.types);
        const result = if (is_float)
            c.LLVMBuildFRem(self.e.builder, lhs, rhs, "fmod")
        else if (emit.isSignedType(instruction.ty))
            c.LLVMBuildSRem(self.e.builder, lhs, rhs, "srem")
        else
            c.LLVMBuildURem(self.e.builder, lhs, rhs, "urem");
        self.e.mapRef(result);
    }

    pub fn emitNeg(self: Ops, instruction: *const Inst, un: UnaryOp) void {
        const operand = self.e.resolveRef(un.operand);
        const is_float = emit.isFloatOrVecFloat(instruction.ty, &self.e.ir_mod.types);
        const result = if (is_float)
            c.LLVMBuildFNeg(self.e.builder, operand, "fneg")
        else
            c.LLVMBuildNeg(self.e.builder, operand, "neg");
        self.e.mapRef(result);
    }

    // ── Bitwise ────────────────────────────────────────────
    pub fn emitBitAnd(self: Ops, instruction: *const Inst, bin: BinOp) void {
        var lhs = self.e.resolveRef(bin.lhs);
        var rhs = self.e.resolveRef(bin.rhs);
        self.e.matchBinOpTypes(&lhs, &rhs, instruction.ty);
        self.e.mapRef(c.LLVMBuildAnd(self.e.builder, lhs, rhs, "and"));
    }

    pub fn emitBitOr(self: Ops, instruction: *const Inst, bin: BinOp) void {
        var lhs = self.e.resolveRef(bin.lhs);
        var rhs = self.e.resolveRef(bin.rhs);
        self.e.matchBinOpTypes(&lhs, &rhs, instruction.ty);
        self.e.mapRef(c.LLVMBuildOr(self.e.builder, lhs, rhs, "or"));
    }

    pub fn emitBitXor(self: Ops, instruction: *const Inst, bin: BinOp) void {
        var lhs = self.e.resolveRef(bin.lhs);
        var rhs = self.e.resolveRef(bin.rhs);
        self.e.matchBinOpTypes(&lhs, &rhs, instruction.ty);
        self.e.mapRef(c.LLVMBuildXor(self.e.builder, lhs, rhs, "xor"));
    }

    pub fn emitBitNot(self: Ops, un: UnaryOp) void {
        const operand = self.e.resolveRef(un.operand);
        self.e.mapRef(c.LLVMBuildNot(self.e.builder, operand, "not"));
    }

    pub fn emitShl(self: Ops, instruction: *const Inst, bin: BinOp) void {
        var lhs = self.e.resolveRef(bin.lhs);
        var rhs = self.e.resolveRef(bin.rhs);
        self.e.matchBinOpTypes(&lhs, &rhs, instruction.ty);
        self.e.mapRef(c.LLVMBuildShl(self.e.builder, lhs, rhs, "shl"));
    }

    pub fn emitShr(self: Ops, instruction: *const Inst, bin: BinOp) void {
        var lhs = self.e.resolveRef(bin.lhs);
        var rhs = self.e.resolveRef(bin.rhs);
        self.e.matchBinOpTypes(&lhs, &rhs, instruction.ty);
        // Use arithmetic shift right for signed, logical for unsigned
        const result = if (emit.isSignedType(instruction.ty))
            c.LLVMBuildAShr(self.e.builder, lhs, rhs, "ashr")
        else
            c.LLVMBuildLShr(self.e.builder, lhs, rhs, "lshr");
        self.e.mapRef(result);
    }

    // ── Comparisons ───────────────────────────────────────
    pub fn emitCmpEq(self: Ops, instruction: *const Inst, bin: BinOp) void {
        self.e.emitCmp(bin, instruction.ty, c.LLVMIntEQ, c.LLVMRealOEQ);
    }

    pub fn emitCmpNe(self: Ops, instruction: *const Inst, bin: BinOp) void {
        // Float `!=` is UNORDERED not-equal: true if either operand is NaN, so
        // `nan != nan` is true (IEEE 754 / the `x != x` NaN idiom) and `!=` stays
        // the exact complement of `==` (OEQ). UNE == ONE for all non-NaN operands.
        self.e.emitCmp(bin, instruction.ty, c.LLVMIntNE, c.LLVMRealUNE);
    }

    pub fn emitCmpLt(self: Ops, instruction: *const Inst, bin: BinOp) void {
        self.e.emitCmpOrdered(bin, instruction.ty, c.LLVMIntSLT, c.LLVMIntULT, c.LLVMRealOLT);
    }

    pub fn emitCmpLe(self: Ops, instruction: *const Inst, bin: BinOp) void {
        self.e.emitCmpOrdered(bin, instruction.ty, c.LLVMIntSLE, c.LLVMIntULE, c.LLVMRealOLE);
    }

    pub fn emitCmpGt(self: Ops, instruction: *const Inst, bin: BinOp) void {
        self.e.emitCmpOrdered(bin, instruction.ty, c.LLVMIntSGT, c.LLVMIntUGT, c.LLVMRealOGT);
    }

    pub fn emitCmpGe(self: Ops, instruction: *const Inst, bin: BinOp) void {
        self.e.emitCmpOrdered(bin, instruction.ty, c.LLVMIntSGE, c.LLVMIntUGE, c.LLVMRealOGE);
    }

    pub fn emitStrEq(self: Ops, bin: BinOp) void {
        self.e.emitStrCmp(bin, true);
    }

    pub fn emitStrNe(self: Ops, bin: BinOp) void {
        self.e.emitStrCmp(bin, false);
    }

    // ── Logical ───────────────────────────────────────────
    pub fn emitBoolAnd(self: Ops, bin: BinOp) void {
        const lhs = self.e.resolveRef(bin.lhs);
        const rhs = self.e.resolveRef(bin.rhs);
        self.e.mapRef(c.LLVMBuildAnd(self.e.builder, lhs, rhs, "land"));
    }

    pub fn emitBoolOr(self: Ops, bin: BinOp) void {
        const lhs = self.e.resolveRef(bin.lhs);
        const rhs = self.e.resolveRef(bin.rhs);
        self.e.mapRef(c.LLVMBuildOr(self.e.builder, lhs, rhs, "lor"));
    }

    pub fn emitBoolNot(self: Ops, un: UnaryOp) void {
        const operand = self.e.resolveRef(un.operand);
        self.e.mapRef(c.LLVMBuildNot(self.e.builder, operand, "lnot"));
    }

    // ── Memory ────────────────────────────────────────────
    pub fn emitAlloca(self: Ops, elem_ty: TypeId) void {
        const llvm_ty = self.e.toLLVMType(elem_ty);
        const result = self.e.buildEntryAlloca(llvm_ty, "alloca");
        self.e.mapRef(result);
    }

    pub fn emitLoad(self: Ops, instruction: *const Inst, un: UnaryOp) void {
        const ptr = self.e.resolveRef(un.operand);
        const ptr_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(ptr));
        if (ptr_kind == c.LLVMPointerTypeKind and instruction.ty != .void) {
            const llvm_ty = self.e.toLLVMType(instruction.ty);
            const result = c.LLVMBuildLoad2(self.e.builder, llvm_ty, ptr, "load");
            self.e.mapRef(result);
        } else {
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(if (instruction.ty == .void) .i64 else instruction.ty)));
        }
    }

    pub fn emitStore(self: Ops, st: Store) void {
        const ptr = self.e.resolveRef(st.ptr);
        var val = self.e.resolveRef(st.val);
        // Guard: don't store void types or store to non-pointer
        const ptr_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(ptr));
        const val_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(val));
        if (ptr_kind == c.LLVMPointerTypeKind and val_kind != c.LLVMVoidTypeKind) {
            // Coerce value to match the IR-declared pointer target type.
            // E.g. storing i64 to *i8 (from index_gep on string) needs truncation.
            //
            // Only unwrap .pointer (from index_gep/alloca: *element → element).
            // Never unwrap .many_pointer — it only appears as struct_gep field
            // value types (e.g., [*]BigNode), where unwrapping to the element
            // type gives a wrong store size (stores BigNode-sized instead of ptr).
            if (self.e.getRefIRType(st.ptr)) |ptr_ir_ty| {
                const pointee_info = self.e.ir_mod.types.get(ptr_ir_ty);
                const target_ty: ?c.LLVMTypeRef = switch (pointee_info) {
                    .pointer => |p| self.e.toLLVMType(p.pointee),
                    else => null,
                };
                if (target_ty) |tt| {
                    val = self.e.coerceArg(val, tt);
                }
            }
            _ = c.LLVMBuildStore(self.e.builder, val, ptr);
        }
        self.e.advanceRefCounter();
    }

    // ── Atomics ───────────────────────────────────────────
    // Atomic load/store = ordinary LLVMBuildLoad2/Store made atomic via
    // LLVMSetOrdering, with a MANDATORY explicit alignment (the LLVM verifier
    // rejects atomic load/store without it). singleThread stays 0 (cross-thread
    // ordering). The sx ordering tag → LLVM ordering map is explicit (LLVM's
    // enum is non-contiguous), never an identity cast.
    fn llvmOrdering(o: ir_inst.AtomicOrdering) c.LLVMAtomicOrdering {
        return switch (o) {
            .relaxed => c.LLVMAtomicOrderingMonotonic,
            .acquire => c.LLVMAtomicOrderingAcquire,
            .release => c.LLVMAtomicOrderingRelease,
            .acq_rel => c.LLVMAtomicOrderingAcquireRelease,
            .seq_cst => c.LLVMAtomicOrderingSequentiallyConsistent,
        };
    }

    // An atomic access type MUST be byte-sized — LLVM rejects a sub-byte
    // (i1) atomic load/store/rmw/cmpxchg. `bool` lowers to `i1`, so an
    // `Atomic(bool)` op is performed in its byte-sized storage type (`i8`)
    // and the value `trunc`/`zext`'d at the boundary. `bool` is the only
    // sub-byte scalar in sx (atomics are integer/bool/pointer only), so the
    // promotion is a `bool → i8` special-case rather than a general width
    // round-up. Returns null when no promotion is needed (the type is
    // already byte-sized) — callers then use it as-is.
    fn atomicByteType(self: Ops, ir_ty: TypeId) ?c.LLVMTypeRef {
        return if (ir_ty == .bool) self.e.cached_i8 else null;
    }

    pub fn emitAtomicLoad(self: Ops, instruction: *const Inst, a: AtomicLoad) void {
        const ptr = self.e.resolveRef(a.ptr);
        const ptr_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(ptr));
        if (ptr_kind == c.LLVMPointerTypeKind and instruction.ty != .void) {
            const promoted = self.atomicByteType(instruction.ty);
            const llvm_ty = promoted orelse self.e.toLLVMType(instruction.ty);
            const raw = c.LLVMBuildLoad2(self.e.builder, llvm_ty, ptr, "atomic_load");
            c.LLVMSetOrdering(raw, llvmOrdering(a.ordering));
            c.LLVMSetAlignment(raw, @intCast(self.e.ir_mod.types.typeSizeBytes(instruction.ty)));
            // Narrow the byte-sized load back to the value type (i8 → i1).
            const result = if (promoted != null)
                c.LLVMBuildTrunc(self.e.builder, raw, self.e.toLLVMType(instruction.ty), "atomic_load.nb")
            else
                raw;
            self.e.mapRef(result);
        } else {
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(if (instruction.ty == .void) .i64 else instruction.ty)));
        }
    }

    // atomicrmw returns the OLD value. The binop comes from the kind; min/max
    // pick signed vs unsigned from val_ty. singleThread stays 0. LLVM gives the
    // op the type's ABI alignment automatically (no explicit SetAlignment needed,
    // unlike plain load/store).
    fn rmwBinOp(kind: ir_inst.RmwKind, is_unsigned: bool) c.LLVMAtomicRMWBinOp {
        return switch (kind) {
            .add => c.LLVMAtomicRMWBinOpAdd,
            .sub => c.LLVMAtomicRMWBinOpSub,
            .@"and" => c.LLVMAtomicRMWBinOpAnd,
            .@"or" => c.LLVMAtomicRMWBinOpOr,
            .xor => c.LLVMAtomicRMWBinOpXor,
            .min => if (is_unsigned) c.LLVMAtomicRMWBinOpUMin else c.LLVMAtomicRMWBinOpMin,
            .max => if (is_unsigned) c.LLVMAtomicRMWBinOpUMax else c.LLVMAtomicRMWBinOpMax,
            .xchg => c.LLVMAtomicRMWBinOpXchg, // swap
        };
    }

    pub fn emitAtomicRmw(self: Ops, instruction: *const Inst, a: AtomicRmw) void {
        const ptr = self.e.resolveRef(a.ptr);
        const val = self.e.resolveRef(a.operand);
        const ptr_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(ptr));
        if (ptr_kind == c.LLVMPointerTypeKind and instruction.ty != .void) {
            // No sub-byte promotion here: `Atomic(bool)` rmw is rejected at the
            // sx level ("requires an integer type"), so a sub-byte element can
            // never reach this emitter (unlike load/store, which bool uses).
            const is_unsigned = self.e.ir_mod.types.isUnsignedInt(a.val_ty);
            const result = c.LLVMBuildAtomicRMW(self.e.builder, rmwBinOp(a.kind, is_unsigned), ptr, val, llvmOrdering(a.ordering), 0);
            self.e.mapRef(result);
        } else {
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(if (instruction.ty == .void) .i64 else instruction.ty)));
        }
    }

    // LLVMBuildAtomicCmpXchg returns a `{ T, i1 }` pair: field 0 = the value
    // that was loaded (the ACTUAL current value), field 1 = a `success` i1.
    // sx's `?T` (integer T) is also `{ T, i1 }` = `{ payload, has_value }`, but
    // with the OPPOSITE convention: null = SUCCESS. So we build the result as
    // `{ actual, NOT success }` — has_value = xor(success, true). singleThread
    // stays 0; `weak` is set via LLVMSetWeak. Integer-only (recognizer guard),
    // so the optional is never a pointer/niche optional.
    pub fn emitAtomicCmpxchg(self: Ops, instruction: *const Inst, a: AtomicCmpxchg) void {
        const ptr = self.e.resolveRef(a.ptr);
        const cmp = self.e.resolveRef(a.cmp);
        const new = self.e.resolveRef(a.new);
        const ptr_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(ptr));
        if (ptr_kind == c.LLVMPointerTypeKind and instruction.ty != .void) {
            // No sub-byte promotion: `Atomic(bool)` cmpxchg is rejected at the
            // sx level (integer-only), so a sub-byte element never reaches here.
            const pair = c.LLVMBuildAtomicCmpXchg(
                self.e.builder,
                ptr,
                cmp,
                new,
                llvmOrdering(a.success_ordering),
                llvmOrdering(a.failure_ordering),
                0, // singleThread = false
            );
            if (a.weak) c.LLVMSetWeak(pair, 1);
            const actual = c.LLVMBuildExtractValue(self.e.builder, pair, 0, "cas.actual");
            const success = c.LLVMBuildExtractValue(self.e.builder, pair, 1, "cas.success");
            // has_value = NOT success  (sx `?T`: null = success).
            const has = c.LLVMBuildXor(self.e.builder, success, c.LLVMConstInt(self.e.cached_i1, 1, 0), "cas.has");
            // Assemble the `?T` = `{ T, i1 }` result.
            const opt_ty = self.e.toLLVMType(instruction.ty);
            var result = c.LLVMGetUndef(opt_ty);
            result = c.LLVMBuildInsertValue(self.e.builder, result, actual, 0, "cas.val");
            result = c.LLVMBuildInsertValue(self.e.builder, result, has, 1, "cas.opt");
            self.e.mapRef(result);
        } else {
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(if (instruction.ty == .void) .i64 else instruction.ty)));
        }
    }

    // Standalone memory fence — void result, no address. singleThread = 0.
    pub fn emitAtomicFence(self: Ops, a: AtomicFence) void {
        _ = c.LLVMBuildFence(self.e.builder, llvmOrdering(a.ordering), 0, "");
        self.e.advanceRefCounter();
    }

    pub fn emitAtomicStore(self: Ops, a: AtomicStore) void {
        const ptr = self.e.resolveRef(a.ptr);
        var val = self.e.resolveRef(a.val);
        const ptr_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(ptr));
        const val_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(val));
        if (ptr_kind == c.LLVMPointerTypeKind and val_kind != c.LLVMVoidTypeKind) {
            // Coerce the value to the pointer's IR target type, mirroring emitStore.
            if (self.e.getRefIRType(a.ptr)) |ptr_ir_ty| {
                const pointee_info = self.e.ir_mod.types.get(ptr_ir_ty);
                const target_ty: ?c.LLVMTypeRef = switch (pointee_info) {
                    .pointer => |p| self.e.toLLVMType(p.pointee),
                    else => null,
                };
                if (target_ty) |tt| val = self.e.coerceArg(val, tt);
            }
            // Alignment MUST come from the actual stored type — never a fixed
            // fallback (an `.i64`/align-8 default silently over-aligns a sub-8
            // store, which the verifier rejects). Lowering always sets val_ty; a
            // missing one is a compiler bug, so bail loudly rather than guess.
            if (a.val_ty == .void) {
                std.debug.print("error: atomic store missing val_ty (cannot derive alignment)\n", .{});
                self.e.comptime_failed = true;
                self.e.advanceRefCounter();
                return;
            }
            // Widen a sub-byte value (bool/i1) to its byte storage type so the
            // atomic store is byte-sized (LLVM rejects an i1 atomic).
            if (self.atomicByteType(a.val_ty)) |byte_ty| {
                val = c.LLVMBuildZExt(self.e.builder, val, byte_ty, "atomic_store.nb");
            }
            const st = c.LLVMBuildStore(self.e.builder, val, ptr);
            c.LLVMSetOrdering(st, llvmOrdering(a.ordering));
            c.LLVMSetAlignment(st, @intCast(self.e.ir_mod.types.typeSizeBytes(a.val_ty)));
        }
        self.e.advanceRefCounter();
    }

    // ── Globals ───────────────────────────────────────────
    pub fn emitGlobalGet(self: Ops, instruction: *const Inst, gid: GlobalId) void {
        const llvm_global = self.e.global_map.get(gid.index()) orelse {
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
            return;
        };
        const llvm_ty = self.e.toLLVMType(instruction.ty);
        self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, llvm_ty, llvm_global, "gload"));
    }

    pub fn emitGlobalAddr(self: Ops, gid: GlobalId) void {
        const llvm_global = self.e.global_map.get(gid.index()) orelse {
            self.e.mapRef(c.LLVMGetUndef(self.e.cached_ptr));
            return;
        };
        // Return the global's address directly (no load)
        self.e.mapRef(llvm_global);
    }

    pub fn emitFuncRef(self: Ops, fid: FuncId) void {
        // Produce a reference to the function as a function pointer value
        if (self.e.func_map.get(@intFromEnum(fid))) |llvm_func| {
            self.e.mapRef(llvm_func);
        } else {
            self.e.mapRef(c.LLVMGetUndef(self.e.cached_ptr));
        }
    }

    pub fn emitGlobalSet(self: Ops, gs: GlobalSet) void {
        const llvm_global = self.e.global_map.get(gs.global.index()) orelse {
            self.e.advanceRefCounter();
            return;
        };
        const val = self.e.resolveRef(gs.value);
        _ = c.LLVMBuildStore(self.e.builder, val, llvm_global);
        self.e.advanceRefCounter();
    }

    // ── Conversions ───────────────────────────────────────
    pub fn emitWiden(self: Ops, conv: Conversion) void {
        const operand = self.e.resolveRef(conv.operand);
        const to_ty = self.e.toLLVMType(conv.to);
        const result = self.e.emitConversion(operand, conv.from, conv.to, to_ty);
        self.e.mapRef(result);
    }

    pub fn emitNarrow(self: Ops, conv: Conversion) void {
        const operand = self.e.resolveRef(conv.operand);
        const to_ty = self.e.toLLVMType(conv.to);
        const result = self.e.emitConversion(operand, conv.from, conv.to, to_ty);
        self.e.mapRef(result);
    }

    pub fn emitBitcast(self: Ops, conv: Conversion) void {
        const operand = self.e.resolveRef(conv.operand);
        const to_ty = self.e.toLLVMType(conv.to);
        // LLVMBuildBitCast doesn't accept ptr↔int on modern
        // LLVM. Dispatch to PtrToInt / IntToPtr when needed —
        // lower.zig emits a `bitcast` IR op for both shapes.
        const from_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(operand));
        const to_kind = c.LLVMGetTypeKind(to_ty);
        if (from_kind == c.LLVMPointerTypeKind and to_kind == c.LLVMIntegerTypeKind) {
            const i64_val = c.LLVMBuildPtrToInt(self.e.builder, operand, self.e.cached_i64, "pti");
            const w = c.LLVMGetIntTypeWidth(to_ty);
            if (w == 64) {
                self.e.mapRef(i64_val);
            } else if (w < 64) {
                self.e.mapRef(c.LLVMBuildTrunc(self.e.builder, i64_val, to_ty, "pti.tr"));
            } else {
                self.e.mapRef(c.LLVMBuildZExt(self.e.builder, i64_val, to_ty, "pti.ext"));
            }
        } else if (from_kind == c.LLVMIntegerTypeKind and to_kind == c.LLVMPointerTypeKind) {
            self.e.mapRef(c.LLVMBuildIntToPtr(self.e.builder, operand, to_ty, "itp"));
        } else {
            self.e.mapRef(c.LLVMBuildBitCast(self.e.builder, operand, to_ty, "bitcast"));
        }
    }

    pub fn emitIntToFloat(self: Ops, conv: Conversion) void {
        const operand = self.e.resolveRef(conv.operand);
        const to_ty = self.e.toLLVMType(conv.to);
        const result = if (emit.isSignedType(conv.from))
            c.LLVMBuildSIToFP(self.e.builder, operand, to_ty, "sitofp")
        else
            c.LLVMBuildUIToFP(self.e.builder, operand, to_ty, "uitofp");
        self.e.mapRef(result);
    }

    pub fn emitFloatToInt(self: Ops, conv: Conversion) void {
        const operand = self.e.resolveRef(conv.operand);
        const to_ty = self.e.toLLVMType(conv.to);
        const result = if (emit.isSignedType(conv.to))
            c.LLVMBuildFPToSI(self.e.builder, operand, to_ty, "fptosi")
        else
            c.LLVMBuildFPToUI(self.e.builder, operand, to_ty, "fptoui");
        self.e.mapRef(result);
    }

    // ── Pointer ops ───────────────────────────────────────
    pub fn emitAddrOf(self: Ops, un: UnaryOp) void {
        // addr_of returns the pointer directly (the operand is already a ptr from alloca)
        self.e.mapRef(self.e.resolveRef(un.operand));
    }

    pub fn emitDeref(self: Ops, instruction: *const Inst, un: UnaryOp) void {
        const ptr = self.e.resolveRef(un.operand);
        const llvm_ty = self.e.toLLVMType(instruction.ty);
        self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, llvm_ty, ptr, "deref"));
    }

    // ── Calls ─────────────────────────────────────────────
    pub fn emitObjcMsgSend(self: Ops, instruction: *const Inst, msg: ObjcMsgSend) void {
        const msg_send = self.e.getObjcMsgSendValue();
        // Detect the sret case: >16 B non-HFA struct return.
        // Same predicate as the plain-extern-call path so the
        // two arms stay in lockstep.
        const raw_ret_ty = self.e.toLLVMType(instruction.ty);
        const uses_sret = self.e.needsByval(instruction.ty, raw_ret_ty);
        const ret_ty = if (uses_sret) self.e.cached_void else raw_ret_ty;

        // Slot layout:
        //   uses_sret = false → [recv, sel, args...]
        //   uses_sret = true  → [sret_slot, recv, sel, args...]
        const sret_off: usize = if (uses_sret) 1 else 0;
        const total_params: usize = 2 + msg.args.len + sret_off;
        const param_types = self.e.alloc.alloc(c.LLVMTypeRef, total_params) catch unreachable;
        defer self.e.alloc.free(param_types);
        const call_args = self.e.alloc.alloc(c.LLVMValueRef, total_params) catch unreachable;
        defer self.e.alloc.free(call_args);

        var sret_slot: c.LLVMValueRef = null;
        if (uses_sret) {
            sret_slot = self.e.buildEntryAlloca(raw_ret_ty, "objc.sret");
            param_types[0] = self.e.cached_ptr;
            call_args[0] = sret_slot;
        }

        // recv (typed *void from the IR)
        param_types[sret_off] = self.e.cached_ptr;
        call_args[sret_off] = self.e.coerceArg(self.e.resolveRef(msg.recv), self.e.cached_ptr);
        // sel (loaded SEL — opaque ptr)
        param_types[sret_off + 1] = self.e.cached_ptr;
        call_args[sret_off + 1] = self.e.coerceArg(self.e.resolveRef(msg.sel), self.e.cached_ptr);
        // additional args take their IR types, with ABI
        // coercion applied so structs / strings decay the
        // same way they do for any C extern call.
        for (msg.args, 0..) |arg_ref, i| {
            const raw_ty = self.e.argIRTypeOrFail(arg_ref);
            const raw_llvm = self.e.toLLVMType(raw_ty);
            const slot = i + 2 + sret_off;
            // Large non-HFA structs (MTLRegion, MTLScissorRect, ...) pass by
            // reference: caller copy + ptr — same marshaling as the abi(.c)
            // fn-pointer path (issue 0347). coerceArg can't spill these
            // (its struct→ptr arm is the 2-field fat-pointer decay only).
            if (self.e.needsByval(raw_ty, raw_llvm)) {
                param_types[slot] = self.e.cached_ptr;
                call_args[slot] = self.e.materializeByvalArg(self.e.resolveRef(arg_ref), raw_llvm);
                continue;
            }
            const coerced_ty = self.e.abiCoerceParamType(raw_ty, raw_llvm);
            param_types[slot] = coerced_ty;
            call_args[slot] = self.e.coerceArg(self.e.resolveRef(arg_ref), coerced_ty);
        }

        const fn_ty = c.LLVMFunctionType(ret_ty, param_types.ptr, @intCast(total_params), 0);
        const call_label: [*:0]const u8 = if (instruction.ty == .void or uses_sret) "" else "objc.msg";
        var result = c.LLVMBuildCall2(self.e.builder, fn_ty, msg_send, call_args.ptr, @intCast(total_params), call_label);
        if (uses_sret) {
            // Tag the call's arg 0 (sret slot) with the sret
            // attribute so the AArch64 / SysV backends route
            // through the x8 / hidden-pointer convention.
            const sret_kind = c.LLVMGetEnumAttributeKindForName("sret", 4);
            const sret_attr = c.LLVMCreateTypeAttribute(self.e.context, sret_kind, raw_ret_ty);
            const param1_idx: c.LLVMAttributeIndex = @bitCast(@as(i32, 1));
            c.LLVMAddCallSiteAttribute(result, param1_idx, sret_attr);
            result = c.LLVMBuildLoad2(self.e.builder, raw_ret_ty, sret_slot, "objc.sret.load");
        }
        // Always mapRef — the IR Ref counter for this
        // instruction advances regardless of return type,
        // so skipping it would misalign every subsequent
        // ref lookup in this function.
        self.e.mapRef(result);
    }

    pub fn emitJniMsgSend(self: Ops, instruction: *const Inst, msg: JniMsgSend) void {
        // JNI vtable indirection:
        //   ifs = *env                                   // JNINativeInterface*
        //   instance:  cls = ifs[GetObjectClass](env, target)
        //              mid = ifs[GetMethodID](env, cls, name, sig)
        //              ifs[Call<T>Method](env, target, mid, args...)
        //   static:    target IS the jclass — skip GetObjectClass
        //              mid = ifs[GetStaticMethodID](env, target, name, sig)
        //              ifs[CallStatic<T>Method](env, target, mid, args...)
        //   ctor:      cls = ifs[FindClass](env, parent_class_path)
        //              mid = ifs[GetMethodID](env, cls, "<init>", sig)
        //              ifs[NewObject](env, cls, mid, args...) → jobject
        //   nonvirt:   handled below via FindClass + GetMethodID +
        //              CallNonvirtual<T>Method.
        // The cached path (msg.cache_key != null) still shares one
        // (jclass GlobalRef, jmethodID) pair per literal (name, sig).
        if (msg.is_constructor) {
            self.e.emitJniConstructor(msg, instruction.ty);
            return;
        }
        const ret_ty_id = instruction.ty;
        const is_pointer_ret = switch (self.e.ir_mod.types.get(ret_ty_id)) {
            .pointer, .many_pointer => true,
            else => false,
        };
        const call_method_offset: u32 = if (msg.is_static) blk: {
            if (is_pointer_ret) break :blk emit.Jni.CallStaticObjectMethod;
            break :blk switch (ret_ty_id) {
                .void => emit.Jni.CallStaticVoidMethod,
                .i32 => emit.Jni.CallStaticIntMethod,
                .i64 => emit.Jni.CallStaticLongMethod,
                .f32 => emit.Jni.CallStaticFloatMethod,
                .f64 => emit.Jni.CallStaticDoubleMethod,
                .bool => emit.Jni.CallStaticBooleanMethod,
                else => {
                    self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
                    return;
                },
            };
        } else if (msg.is_nonvirtual) blk: {
            if (is_pointer_ret) break :blk emit.Jni.CallNonvirtualObjectMethod;
            break :blk switch (ret_ty_id) {
                .void => emit.Jni.CallNonvirtualVoidMethod,
                .i32 => emit.Jni.CallNonvirtualIntMethod,
                .i64 => emit.Jni.CallNonvirtualLongMethod,
                .f32 => emit.Jni.CallNonvirtualFloatMethod,
                .f64 => emit.Jni.CallNonvirtualDoubleMethod,
                .bool => emit.Jni.CallNonvirtualBooleanMethod,
                else => {
                    self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
                    return;
                },
            };
        } else blk: {
            if (is_pointer_ret) break :blk emit.Jni.CallObjectMethod;
            break :blk switch (ret_ty_id) {
                .void => emit.Jni.CallVoidMethod,
                .i32 => emit.Jni.CallIntMethod,
                .i64 => emit.Jni.CallLongMethod,
                .f32 => emit.Jni.CallFloatMethod,
                .f64 => emit.Jni.CallDoubleMethod,
                .bool => emit.Jni.CallBooleanMethod,
                else => {
                    self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
                    return;
                },
            };
        };
        const get_mid_offset: u32 = if (msg.is_static) emit.Jni.GetStaticMethodID else emit.Jni.GetMethodID;

        const env = self.e.resolveRef(msg.env);
        const target = self.e.resolveRef(msg.target);
        // String literals lower as `{ptr, i64}` slices in sx IR;
        // JNI's `GetMethodID` expects raw C strings, so extract
        // field 0 when the source is a slice.
        const name_ptr = self.e.extractSlicePtr(self.e.resolveRef(msg.name));
        const sig_ptr = self.e.extractSlicePtr(self.e.resolveRef(msg.sig));

        const ifs = c.LLVMBuildLoad2(self.e.builder, self.e.cached_ptr, env, "jni.ifs");

        // Method-ID resolution. When `name` and `sig` are both
        // string literals the call site participates in
        // `(name, sig)` slot interning (step 1.17): a shared
        // pair of static globals holds the `jclass` GlobalRef
        // and the `jmethodID`, populated lazily on the first
        // call to any matching site. Non-literal sites fall
        // back to the per-call `GetObjectClass + GetMethodID`
        // sequence (1.15 shape).
        const mid = if (msg.cache_key) |ck| blk: {
            const pair = self.e.ffiCtors().getOrCreateJniSlots(ck.name_str, ck.sig_str);
            const cached_mid = c.LLVMBuildLoad2(self.e.builder, self.e.cached_ptr, pair.mid_slot, "jni.cached.mid");
            const is_cached = c.LLVMBuildICmp(self.e.builder, c.LLVMIntNE, cached_mid, c.LLVMConstNull(self.e.cached_ptr), "jni.is.cached");

            const cur_fn = c.LLVMGetBasicBlockParent(c.LLVMGetInsertBlock(self.e.builder));
            const miss_bb = c.LLVMAppendBasicBlockInContext(self.e.context, cur_fn, "jni.miss");
            const cont_bb = c.LLVMAppendBasicBlockInContext(self.e.context, cur_fn, "jni.cont");
            const before_bb = c.LLVMGetInsertBlock(self.e.builder);
            _ = c.LLVMBuildCondBr(self.e.builder, is_cached, cont_bb, miss_bb);

            // Miss path:
            //   instance: GetObjectClass → NewGlobalRef → GetMethodID
            //   static:   target IS class → NewGlobalRef(target) → GetStaticMethodID
            c.LLVMPositionBuilderAtEnd(self.e.builder, miss_bb);
            const local_cls = if (msg.is_static) target else inst_cls: {
                const get_obj_cls = self.e.loadJniFn(ifs, emit.Jni.GetObjectClass, "jni.GetObjectClass");
                var gocls_params = [_]c.LLVMTypeRef{ self.e.cached_ptr, self.e.cached_ptr };
                const gocls_ty = c.LLVMFunctionType(self.e.cached_ptr, &gocls_params, 2, 0);
                var gocls_args = [_]c.LLVMValueRef{ env, target };
                break :inst_cls c.LLVMBuildCall2(self.e.builder, gocls_ty, get_obj_cls, &gocls_args, 2, "jni.cls");
            };
            const new_global_ref = self.e.loadJniFn(ifs, emit.Jni.NewGlobalRef, "jni.NewGlobalRef");
            var ngref_params = [_]c.LLVMTypeRef{ self.e.cached_ptr, self.e.cached_ptr };
            const ngref_ty = c.LLVMFunctionType(self.e.cached_ptr, &ngref_params, 2, 0);
            var ngref_args = [_]c.LLVMValueRef{ env, local_cls };
            const global_cls = c.LLVMBuildCall2(self.e.builder, ngref_ty, new_global_ref, &ngref_args, 2, "jni.global.cls");
            _ = c.LLVMBuildStore(self.e.builder, global_cls, pair.cls_slot);
            const get_mid = self.e.loadJniFn(ifs, get_mid_offset, if (msg.is_static) "jni.GetStaticMethodID" else "jni.GetMethodID");
            var gmid_params = [_]c.LLVMTypeRef{ self.e.cached_ptr, self.e.cached_ptr, self.e.cached_ptr, self.e.cached_ptr };
            const gmid_ty = c.LLVMFunctionType(self.e.cached_ptr, &gmid_params, 4, 0);
            var gmid_args = [_]c.LLVMValueRef{ env, global_cls, name_ptr, sig_ptr };
            const fresh_mid = c.LLVMBuildCall2(self.e.builder, gmid_ty, get_mid, &gmid_args, 4, "jni.fresh.mid");
            _ = c.LLVMBuildStore(self.e.builder, fresh_mid, pair.mid_slot);
            const miss_end_bb = c.LLVMGetInsertBlock(self.e.builder);
            _ = c.LLVMBuildBr(self.e.builder, cont_bb);

            // Cont: phi the cached vs fresh mid.
            c.LLVMPositionBuilderAtEnd(self.e.builder, cont_bb);
            const phi = c.LLVMBuildPhi(self.e.builder, self.e.cached_ptr, "jni.mid");
            var phi_vals = [_]c.LLVMValueRef{ cached_mid, fresh_mid };
            var phi_blocks = [_]c.LLVMBasicBlockRef{ before_bb, miss_end_bb };
            c.LLVMAddIncoming(phi, &phi_vals, &phi_blocks, 2);
            break :blk phi;
        } else blk: {
            const cls = if (msg.is_static) target else if (msg.is_nonvirtual) nonvirt_cls: {
                // `super.method(args)`: dispatch is bound to a
                // specific class (the parent), not subclass-override.
                // Resolve via FindClass(parent_path). No caching yet —
                // per-call lookup. The parent path is a NUL-terminated
                // C string emitted as a private LLVM global.
                const path = msg.parent_class_path orelse "";
                const path_global = self.e.emitCStringGlobal(path, "jni.parent.path");
                const find_class = self.e.loadJniFn(ifs, emit.Jni.FindClass, "jni.FindClass");
                var fc_params = [_]c.LLVMTypeRef{ self.e.cached_ptr, self.e.cached_ptr };
                const fc_ty = c.LLVMFunctionType(self.e.cached_ptr, &fc_params, 2, 0);
                var fc_args = [_]c.LLVMValueRef{ env, path_global };
                break :nonvirt_cls c.LLVMBuildCall2(self.e.builder, fc_ty, find_class, &fc_args, 2, "jni.parent.cls");
            } else inst_cls: {
                const get_obj_cls = self.e.loadJniFn(ifs, emit.Jni.GetObjectClass, "jni.GetObjectClass");
                var gocls_params = [_]c.LLVMTypeRef{ self.e.cached_ptr, self.e.cached_ptr };
                const gocls_ty = c.LLVMFunctionType(self.e.cached_ptr, &gocls_params, 2, 0);
                var gocls_args = [_]c.LLVMValueRef{ env, target };
                break :inst_cls c.LLVMBuildCall2(self.e.builder, gocls_ty, get_obj_cls, &gocls_args, 2, "jni.cls");
            };
            const get_mid = self.e.loadJniFn(ifs, get_mid_offset, if (msg.is_static) "jni.GetStaticMethodID" else "jni.GetMethodID");
            var gmid_params = [_]c.LLVMTypeRef{ self.e.cached_ptr, self.e.cached_ptr, self.e.cached_ptr, self.e.cached_ptr };
            const gmid_ty = c.LLVMFunctionType(self.e.cached_ptr, &gmid_params, 4, 0);
            var gmid_args = [_]c.LLVMValueRef{ env, cls, name_ptr, sig_ptr };
            const mid_val = c.LLVMBuildCall2(self.e.builder, gmid_ty, get_mid, &gmid_args, 4, "jni.mid");
            if (msg.is_nonvirtual) {
                // Stash cls in a dummy slot so the call site below
                // can pick it up. Easiest path: do the call right
                // here and return Ref.none, but we need to keep the
                // outer phi shape. Instead, return both via tuple
                // through an auxiliary local — simplest is to attach
                // `cls` to a per-invocation slot. Use a stack alloca.
                const cls_slot = self.e.buildEntryAlloca(self.e.cached_ptr, "jni.parent.cls.slot");
                _ = c.LLVMBuildStore(self.e.builder, cls, cls_slot);
                // Tag the slot pointer onto the phi result via the
                // generated metadata: we'll re-extract by re-running
                // FindClass — actually simpler: lower nonvirtual on
                // the spot below. Drop the implicit `break` here:
                const call_fn = self.e.loadJniFn(ifs, call_method_offset, "jni.callfn.nonvirtual");
                const raw_ret = self.e.toLLVMType(ret_ty_id);
                const total_call_params_nv: usize = 4 + msg.args.len;
                const call_param_types_nv = self.e.alloc.alloc(c.LLVMTypeRef, total_call_params_nv) catch unreachable;
                defer self.e.alloc.free(call_param_types_nv);
                const call_args_nv = self.e.alloc.alloc(c.LLVMValueRef, total_call_params_nv) catch unreachable;
                defer self.e.alloc.free(call_args_nv);
                call_param_types_nv[0] = self.e.cached_ptr;
                call_param_types_nv[1] = self.e.cached_ptr;
                call_param_types_nv[2] = self.e.cached_ptr;
                call_param_types_nv[3] = self.e.cached_ptr;
                call_args_nv[0] = env;
                call_args_nv[1] = target;
                call_args_nv[2] = cls;
                call_args_nv[3] = mid_val;
                for (msg.args, 0..) |arg_ref, i| {
                    const raw_ty = self.e.argIRTypeOrFail(arg_ref);
                    const raw_llvm = self.e.toLLVMType(raw_ty);
                    const coerced_ty = self.e.abiCoerceParamType(raw_ty, raw_llvm);
                    call_param_types_nv[i + 4] = coerced_ty;
                    call_args_nv[i + 4] = self.e.coerceArg(self.e.resolveRef(arg_ref), coerced_ty);
                }
                const call_fn_ty_nv = c.LLVMFunctionType(raw_ret, call_param_types_nv.ptr, @intCast(total_call_params_nv), 0);
                const label_nv: [*:0]const u8 = if (ret_ty_id == .void) "" else "jni.nonvirtual.ret";
                const result_nv = c.LLVMBuildCall2(self.e.builder, call_fn_ty_nv, call_fn, call_args_nv.ptr, @intCast(total_call_params_nv), label_nv);
                self.e.mapRef(result_nv);
                return;
            }
            break :blk mid_val;
        };

        // Call<Type>Method: (JNIEnv*, jobject, jmethodID, args...) -> RetTy
        const call_fn = self.e.loadJniFn(ifs, call_method_offset, "jni.callfn");
        const raw_ret = self.e.toLLVMType(ret_ty_id);
        const total_call_params: usize = 3 + msg.args.len;
        const call_param_types = self.e.alloc.alloc(c.LLVMTypeRef, total_call_params) catch unreachable;
        defer self.e.alloc.free(call_param_types);
        const call_args = self.e.alloc.alloc(c.LLVMValueRef, total_call_params) catch unreachable;
        defer self.e.alloc.free(call_args);
        call_param_types[0] = self.e.cached_ptr;
        call_param_types[1] = self.e.cached_ptr;
        call_param_types[2] = self.e.cached_ptr;
        call_args[0] = env;
        call_args[1] = target;
        call_args[2] = mid;
        for (msg.args, 0..) |arg_ref, i| {
            const raw_ty = self.e.argIRTypeOrFail(arg_ref);
            const raw_llvm = self.e.toLLVMType(raw_ty);
            const coerced_ty = self.e.abiCoerceParamType(raw_ty, raw_llvm);
            call_param_types[i + 3] = coerced_ty;
            call_args[i + 3] = self.e.coerceArg(self.e.resolveRef(arg_ref), coerced_ty);
        }
        const call_fn_ty = c.LLVMFunctionType(raw_ret, call_param_types.ptr, @intCast(total_call_params), 0);
        const label: [*:0]const u8 = if (ret_ty_id == .void) "" else "jni.ret";
        const result = c.LLVMBuildCall2(self.e.builder, call_fn_ty, call_fn, call_args.ptr, @intCast(total_call_params), label);
        self.e.mapRef(result);
    }

    /// Inline assembly (ASM stream Phase D) — the port of Zig's `airAssembly`.
    /// Handles 0 value outputs (void) and 1 (scalar); multi-output tuples are
    /// Phase E (lowering bails before reaching here). Builds the LLVM constraint
    /// string, rewrites the `%[name]` template, then `LLVMGetInlineAsm` +
    /// `LLVMBuildCall2`.
    pub fn emitInlineAsm(self: Ops, instruction: *const Inst, a: InlineAsm) void {
        const e = self.e;
        const alloc = e.alloc;

        var n_inputs: usize = 0;
        var n_rw: usize = 0;
        var n_indirect: usize = 0;
        for (a.operands) |op| {
            if (op.role == .input) n_inputs += 1;
            if (op.role == .out_place and asmIsReadWrite(e, op)) n_rw += 1;
            if (op.role == .out_place and asmIsIndirect(e, op)) n_indirect += 1;
        }
        // Arg layout — MUST match the arg-consuming constraint order. Indirect
        // (`=*m`) outputs sit in the OUTPUT section (their pointer is an arg, no
        // return slot), so they come first; then regular inputs; then read-write
        // (`+`) tied-input seeds (appended last). Direct outputs consume no arg.
        //   [indirect output pointers] ++ [inputs] ++ [read-write seeds]
        const n_args = n_indirect + n_inputs + n_rw;

        // Combined LLVM return type: the DIRECT outputs only (out_value +
        // write-through / read-write out_place), source order. An indirect
        // (`=*m`) output does NOT return a value — the asm writes through its
        // pointer arg — so it is excluded here. 0 → void, 1 → scalar, N → struct.
        var out_llvm: std.ArrayList(c.LLVMTypeRef) = .empty;
        defer out_llvm.deinit(alloc);
        for (a.operands) |op| {
            if (op.role == .input) continue;
            if (asmIsIndirect(e, op)) continue;
            out_llvm.append(alloc, e.toLLVMType(op.out_ty)) catch unreachable;
        }
        const n_out = out_llvm.items.len;
        const ret_ty: c.LLVMTypeRef = switch (n_out) {
            0 => e.cached_void,
            1 => out_llvm.items[0],
            else => c.LLVMStructTypeInContext(e.context, out_llvm.items.ptr, @intCast(n_out), 0),
        };

        // One LLVM call param per input operand (source order), then one per
        // read-write seed (source order) — the arg order MUST match the input
        // constraint order (regular inputs, then tied inputs; see below).
        const param_types = alloc.alloc(c.LLVMTypeRef, n_args) catch unreachable;
        defer alloc.free(param_types);
        const call_args = alloc.alloc(c.LLVMValueRef, n_args) catch unreachable;
        defer alloc.free(call_args);
        {
            var i: usize = 0;
            // Indirect-memory output pointers (source order): the place address,
            // through which the asm writes. Passed as an opaque `ptr`; the
            // pointee type is carried by an `elementtype` attribute added after
            // the call. No return slot.
            for (a.operands) |op| {
                if (op.role != .out_place or !asmIsIndirect(e, op)) continue;
                param_types[i] = e.cached_ptr;
                call_args[i] = e.resolveRef(op.operand);
                i += 1;
            }
            for (a.operands) |op| {
                if (op.role != .input) continue;
                // Symbol operand (`"s"`): a function/global passed as a
                // compile-time constant (its address) — pass the value with its
                // OWN llvm type and NO coercion, so the template's `${N}` emits
                // the platform-mangled symbol (a direct `bl _sym`). Coercing to
                // a register int (the path below) mistypes it (a function value
                // resolves to `ptr`) and fails the LLVM verifier.
                if (asmIsSymbol(e, op)) {
                    const v = e.resolveRef(op.operand);
                    param_types[i] = c.LLVMTypeOf(v);
                    call_args[i] = v;
                    i += 1;
                    continue;
                }
                const raw_ty = e.argIRTypeOrFail(op.operand);
                const llvm_ty = e.toLLVMType(raw_ty);
                param_types[i] = llvm_ty;
                call_args[i] = e.coerceArg(e.resolveRef(op.operand), llvm_ty);
                i += 1;
            }
            // Read-write seeds: load each `+` place's current value (op.operand
            // is its address) and pass it as the tied input's arg.
            for (a.operands) |op| {
                if (op.role != .out_place or !asmIsReadWrite(e, op)) continue;
                const llvm_ty = e.toLLVMType(op.out_ty);
                param_types[i] = llvm_ty;
                call_args[i] = c.LLVMBuildLoad2(e.builder, llvm_ty, e.resolveRef(op.operand), "asm.rw.seed");
                i += 1;
            }
        }

        // ── Constraint string: outputs first, then inputs, then ~{clobber}. ──
        var cons: std.ArrayList(u8) = .empty;
        defer cons.deinit(alloc);
        self.appendAsmConstraints(&cons, a, false); // outputs (out_value / out_place)
        self.appendAsmConstraints(&cons, a, true); // inputs
        // Tied inputs for read-write (`+`) place outputs: each references the
        // LLVM index of the output it ties to (outputs are numbered first, in
        // source order). Appended AFTER the regular inputs so existing operand
        // indices (`%[name]` → `${N}`) are undisturbed.
        {
            var out_idx: usize = 0;
            for (a.operands) |op| {
                if (op.role == .input) continue; // not an output — doesn't advance out_idx
                if (op.role == .out_place and asmIsReadWrite(e, op)) {
                    if (cons.items.len != 0) cons.append(alloc, ',') catch unreachable;
                    var buf: [16]u8 = undefined;
                    const ds = std.fmt.bufPrint(&buf, "{d}", .{out_idx}) catch unreachable;
                    cons.appendSlice(alloc, ds) catch unreachable;
                }
                out_idx += 1;
            }
        }
        for (a.clobbers) |cl| {
            if (cons.items.len != 0) cons.append(alloc, ',') catch unreachable;
            cons.appendSlice(alloc, "~{") catch unreachable;
            cons.appendSlice(alloc, e.ir_mod.types.getString(cl)) catch unreachable;
            cons.append(alloc, '}') catch unreachable;
        }

        // ── Template rewrite: %[name]->${N}, %%->%, $->$$, %=->${:uid}. ──
        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(alloc);
        self.renderAsmTemplate(&rendered, a);

        const fn_ty = c.LLVMFunctionType(ret_ty, param_types.ptr, @intCast(n_args), 0);
        const asm_val = c.LLVMGetInlineAsm(
            fn_ty,
            rendered.items.ptr,
            rendered.items.len,
            cons.items.ptr,
            cons.items.len,
            @intFromBool(a.has_side_effects),
            0, // IsAlignStack
            c.LLVMInlineAsmDialectATT,
            0, // CanThrow
        );
        const label: [*:0]const u8 = if (n_out == 0) "" else "asm";
        const raw_result = c.LLVMBuildCall2(e.builder, fn_ty, asm_val, call_args.ptr, @intCast(n_args), label);

        // Indirect (`=*m`) output args are opaque pointers — LLVM (opaque-pointer
        // era) requires an `elementtype(T)` attribute naming the pointee on each.
        // They occupy arg slots 0..n_indirect-1 (call-site attr index is 1-based).
        if (n_indirect != 0) {
            const et_kind = c.LLVMGetEnumAttributeKindForName("elementtype", 11);
            var j: usize = 0;
            for (a.operands) |op| {
                if (op.role != .out_place or !asmIsIndirect(e, op)) continue;
                const et_attr = c.LLVMCreateTypeAttribute(e.context, et_kind, e.toLLVMType(op.out_ty));
                const idx: c.LLVMAttributeIndex = @bitCast(@as(i32, @intCast(j + 1)));
                c.LLVMAddCallSiteAttribute(raw_result, idx, et_attr);
                j += 1;
            }
        }

        // Fast path — no write-through outputs: every output is a value output,
        // so the asm's return (void / scalar / `{T…}` struct) IS the sx result
        // (the struct already matches sx's tuple representation). No split.
        var has_place = false;
        for (a.operands) |op| {
            if (op.role == .out_place) has_place = true;
        }
        if (!has_place) {
            e.mapRef(raw_result);
            return;
        }

        // ── Mixed/place outputs (source order): out_place → `store` the slot
        // through its address; out_value → collect, then rebuild the sx result
        // (0 → void/place-only call · 1 → that value · N → tuple `insertvalue`). ──
        var value_vals: std.ArrayList(c.LLVMValueRef) = .empty;
        defer value_vals.deinit(alloc);
        var slot: c_uint = 0;
        for (a.operands) |op| {
            if (op.role == .input) continue;
            // Indirect (`=*m`) outputs have no return slot — the asm already
            // wrote through their pointer arg. Skip (no extract, no store-back).
            if (asmIsIndirect(e, op)) continue;
            const v = if (n_out == 1) raw_result else c.LLVMBuildExtractValue(e.builder, raw_result, slot, "asm.out");
            slot += 1;
            if (op.role == .out_place) {
                _ = c.LLVMBuildStore(e.builder, v, e.resolveRef(op.operand));
            } else {
                value_vals.append(alloc, v) catch unreachable;
            }
        }

        const result: c.LLVMValueRef = blk: {
            if (value_vals.items.len == 0) break :blk raw_result;
            if (value_vals.items.len == 1) break :blk value_vals.items[0];
            const tuple_ty = e.toLLVMType(instruction.ty);
            var agg = c.LLVMGetUndef(tuple_ty);
            for (value_vals.items, 0..) |v, j| {
                agg = c.LLVMBuildInsertValue(e.builder, agg, v, @intCast(j), "asm.tup");
            }
            break :blk agg;
        };
        // Always mapRef — the IR Ref counter advances regardless of result type.
        e.mapRef(result);
    }

    /// Append the constraint fragments for one role group (outputs or inputs),
    /// comma-separated, with each operand's `,` rewritten to LLVM's `|`
    /// (alternative-constraint separator). Mirrors `FuncGen.airAssembly`.
    fn appendAsmConstraints(self: Ops, cons: *std.ArrayList(u8), a: InlineAsm, inputs: bool) void {
        const e = self.e;
        const alloc = e.alloc;
        for (a.operands) |op| {
            const is_input = op.role == .input;
            if (is_input != inputs) continue;
            if (cons.items.len != 0) cons.append(alloc, ',') catch unreachable;
            var body = e.ir_mod.types.getString(op.constraint);
            // Read-write (`+`) place outputs lower to an LLVM output `=` plus a
            // tied input (appended separately). LLVM has no `+`, so emit `=` for
            // the output half here.
            if (!is_input and body.len > 0 and body[0] == '+') {
                cons.append(alloc, '=') catch unreachable;
                body = body[1..];
            }
            for (body) |ch| cons.append(alloc, if (ch == ',') '|' else ch) catch unreachable;
        }
    }

    /// True if `op` is a read-write (`+`) place output — its constraint begins
    /// with `+`. Such operands emit an LLVM output `=` plus a tied input seeded
    /// with the place's loaded value.
    fn asmIsReadWrite(e: *LLVMEmitter, op: InlineAsm.AsmOperand) bool {
        const s = e.ir_mod.types.getString(op.constraint);
        return s.len > 0 and s[0] == '+';
    }

    /// True if `op` is an indirect-memory (`=*m`) place output — its constraint
    /// contains `*`. The place address is passed as an opaque pointer arg (with
    /// an `elementtype` attribute) and the asm writes through it; no return slot.
    fn asmIsIndirect(e: *LLVMEmitter, op: InlineAsm.AsmOperand) bool {
        const s = e.ir_mod.types.getString(op.constraint);
        return std.mem.indexOfScalar(u8, s, '*') != null;
    }

    /// True if `op` is a symbol operand — constraint `"s"`. The operand is a
    /// function/global passed as a compile-time constant (its address); the
    /// template's `${N}` emits the platform-mangled symbol name, so a direct
    /// `bl %[fn]` / `call %[fn]` branches straight to it.
    fn asmIsSymbol(e: *LLVMEmitter, op: InlineAsm.AsmOperand) bool {
        const s = e.ir_mod.types.getString(op.constraint);
        return std.mem.eql(u8, s, "s");
    }

    /// The positional index of a named operand in the LLVM operand list
    /// (outputs first, then inputs) — the `N` in `%[name]` → `${N}`. Lowering
    /// guarantees every `%[name]` names an operand, so callers can assume a hit.
    fn asmOperandIndex(self: Ops, a: InlineAsm, name: []const u8) ?usize {
        const e = self.e;
        var idx: usize = 0;
        for ([_]bool{ false, true }) |inputs| {
            for (a.operands) |op| {
                const is_input = op.role == .input;
                if (is_input != inputs) continue;
                if (op.name != .empty and std.mem.eql(u8, e.ir_mod.types.getString(op.name), name)) return idx;
                idx += 1;
            }
        }
        return null;
    }

    /// True if the operand named `name` (effective name) is a symbol operand.
    /// Drives the auto-`:c` injection in `renderAsmTemplate` so `%[fn]` is
    /// portable across targets.
    fn asmNamedIsSymbol(self: Ops, a: InlineAsm, name: []const u8) bool {
        const e = self.e;
        for (a.operands) |op| {
            if (op.name != .empty and std.mem.eql(u8, e.ir_mod.types.getString(op.name), name) and asmIsSymbol(e, op)) return true;
        }
        return false;
    }

    /// Rewrite the asm template into LLVM form. State machine over the bytes:
    /// `$`→`$$`, `%%`→`%`, `%=`→`${:uid}`, `%[name]`→`${N}`, `%[name:mod]`→
    /// `${N:mod}`. Port of `FuncGen.zig`'s template rewriter.
    fn renderAsmTemplate(self: Ops, out: *std.ArrayList(u8), a: InlineAsm) void {
        const e = self.e;
        const alloc = e.alloc;
        const tmpl = e.ir_mod.types.getString(a.template);
        var i: usize = 0;
        while (i < tmpl.len) {
            const ch = tmpl[i];
            if (ch == '$') {
                out.appendSlice(alloc, "$$") catch unreachable;
                i += 1;
                continue;
            }
            if (ch == '%' and i + 1 < tmpl.len) {
                const nxt = tmpl[i + 1];
                if (nxt == '%') {
                    out.append(alloc, '%') catch unreachable;
                    i += 2;
                    continue;
                }
                if (nxt == '=') {
                    out.appendSlice(alloc, "${:uid}") catch unreachable;
                    i += 2;
                    continue;
                }
                if (nxt == '[') {
                    const close = std.mem.indexOfScalarPos(u8, tmpl, i + 2, ']').?; // lowering validated
                    var name = tmpl[i + 2 .. close];
                    var modifier: ?[]const u8 = null;
                    if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
                        modifier = name[colon + 1 ..];
                        name = name[0..colon];
                    }
                    const idx = self.asmOperandIndex(a, name).?; // lowering validated
                    var buf: [16]u8 = undefined;
                    const ds = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch unreachable;
                    out.appendSlice(alloc, "${") catch unreachable;
                    out.appendSlice(alloc, ds) catch unreachable;
                    if (modifier) |m| {
                        out.append(alloc, ':') catch unreachable;
                        out.appendSlice(alloc, m) catch unreachable;
                    } else if (self.asmNamedIsSymbol(a, name)) {
                        // A symbol operand referenced without an explicit
                        // modifier: inject `:c` (bare constant — no punctuation)
                        // so a direct `bl`/`call %[fn]` emits the plain symbol on
                        // EVERY target. Without it x86 prints `$sym` (a bad call
                        // target); aarch64 is unaffected. Keeps the template
                        // portable — the user never writes a per-arch `:P`/`:c`.
                        out.appendSlice(alloc, ":c") catch unreachable;
                    }
                    out.append(alloc, '}') catch unreachable;
                    i = close + 1;
                    continue;
                }
            }
            out.append(alloc, ch) catch unreachable;
            i += 1;
        }
    }

    pub fn emitCall(self: Ops, instruction: *const Inst, call_op: Call) void {
        // Evaluate comptime functions at compile time
        const callee_func = &self.e.ir_mod.functions.items[call_op.callee.index()];

        // Welded `compiler`-library functions are comptime-only — they have no
        // runtime symbol (the comptime interp dispatches them to a Zig handler).
        // A welded call inside a RUNTIME function is illegal; surface a clean
        // build-gating error instead of an undefined-symbol link failure. A
        // welded call inside a COMPTIME function (a `#run` / `::` initializer
        // wrapper, `is_comptime`) is fine — that body is interp-evaluated and its
        // LLVM emission is dead, so skip the gate there.
        const enclosing = &self.e.ir_mod.functions.items[self.e.current_func_idx];
        if (callee_func.is_intrinsic and !enclosing.isComptimeOnly()) {
            const fname = self.e.ir_mod.types.getString(callee_func.name);
            std.debug.print("error: '{s}' runs only at compile time — it cannot be called from the runtime call graph (use it inside #run or a comptime '::')\n", .{fname});
            self.reportRuntimePath(fname);
            self.e.comptime_failed = true;
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
            return;
        }
        // A comptime-only callee (compiler-API or compiler-domain) reached here from
        // a COMPTIME (dead) body — the enclosing `#run`/`::` wrapper whose LLVM is
        // never executed. Such a function has no runtime symbol, so emit `undef`
        // instead of a real `call` (which would leave an undefined reference for the
        // AOT linker). The comptime VALUE is produced by the interp/VM, not this dead
        // body. Mirrors the old `compiler_call` → undef.
        if (callee_func.is_intrinsic) {
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
            return;
        }

        if (callee_func.isComptimeOnly() and !enclosing.isComptimeOnly()) {
            // Inline comptime-call fold: a body-local `#run expr` lowers to a
            // `call` of its `is_comptime` `__ct` wrapper. That wrapper is
            // comptime-ONLY — it must NEVER survive as a runtime call (its body
            // may read `---` storage / depend on comptime-only state). Evaluate
            // it on the VM (the sole evaluator).
            //
            // GATE on `!enclosing.isComptimeOnly()`: only a call reached from a REAL
            // runtime body (e.g. `main`) is an actual `#run` fold site. An
            // `is_comptime` callee that appears INSIDE another comptime wrapper's
            // body (`make_enum` / `declare` / `define` called from a `__ctype`
            // type-fn wrapper) is DEAD LLVM — never executed — and the VM
            // evaluates the whole wrapper itself; standalone-folding such a nested
            // call would mis-`tryEval` it (wrong arg count) and emit a spurious
            // failure. Leave those to the normal (dead) call path.
            //
            // For the live `#run` fold:
            //   - scalar / string result → splat as a constant (the common case);
            //   - a BAIL (`tryEval` null — e.g. an unbridgeable `[2][]i64` return)
            //     is a comptime-init FAILURE. Mirror the GLOBAL `#run` path
            //     (`emitGlobals` → `error: comptime init of 'X' failed: <reason>`,
            //     `comptime_failed`): emit the located diagnostic and gate the
            //     build, NEVER fall through to a runtime call over `---` storage
            //     (issue 0182 — that produced exit-0 garbage with no diagnostic).
            if (comptime_vm.tryEval(self.e.alloc, self.e.ir_mod, call_op.callee, &self.e.build_config, self.e.import_sources)) |result| {
                if (result.asInt()) |v| {
                    self.e.mapRef(c.LLVMConstInt(self.e.toLLVMType(instruction.ty), @bitCast(v), 0));
                    return;
                } else if (result.asFloat()) |v| {
                    self.e.mapRef(c.LLVMConstReal(self.e.toLLVMType(instruction.ty), v));
                    return;
                } else if (result.asBool()) |v| {
                    self.e.mapRef(c.LLVMConstInt(self.e.toLLVMType(instruction.ty), @intFromBool(v), 0));
                    return;
                } else if (result == .string) {
                    self.e.mapRef(self.e.emitStringConstant(result.string));
                    return;
                }
                // A non-scalar bridgeable result (struct / array / `?Arr`) the VM
                // materialized successfully but this scalar fold can't splat.
                // Its `__ct` body runs correctly at runtime, so fall through to
                // the ordinary call path (the established, tested behavior — the
                // result is well-defined data, not `---` garbage). Only a BAIL
                // (handled below) signals an actual comptime failure.
            } else if (comptime_vm.last_bail_was_bridge) {
                // `tryEval` RAN the wrapper but could not BRIDGE its result shape
                // to a host value (e.g. an unbridgeable `[2][]i64` — array of
                // slices). Re-emitting a runtime `call` would re-run the SAME body
                // over its (possibly `---`) storage and produce DIFFERENT garbage
                // with no diagnostic — the exact silent miscompile of issue 0182.
                // Mirror the GLOBAL `#run` path (`emitGlobals` → `error: comptime
                // init of 'X' failed: <reason>`, `comptime_failed`): surface the
                // bridge bail loudly and gate the build.
                const fname = if (callee_func.comptime_display_name) |dn|
                    self.e.ir_mod.types.getString(dn)
                else
                    self.e.ir_mod.types.getString(callee_func.name);
                std.debug.print(
                    "error: comptime init of '{s}' failed: {s}\n",
                    .{ fname, comptime_vm.last_bail_reason orelse "<unknown>" },
                );
                self.e.comptime_failed = true;
                self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
                return;
            }
            // An EXECUTION bail (the VM couldn't run the body — an unported op, a
            // VM `DivisionByZero` that the runtime computes as NaN, …): the
            // established runtime-call fallback computes the correct value. Fall
            // through to the ordinary call path — NOT a build failure.
        }
        const callee = self.e.func_map.get(call_op.callee.index()) orelse {
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
            return;
        };
        const callee_needs_c_abi = callee_func.is_extern or callee_func.call_conv == .c;
        const callee_raw_ret = self.e.toLLVMType(callee_func.ret);
        // Extern string/?string returns receive one `char *` — never sret
        // (must mirror declareFunction's signature classification).
        const cstr_ret = self.e.cstrRetKind(callee_func);
        const callee_uses_sret = callee_needs_c_abi and cstr_ret == .none and self.e.needsByval(callee_func.ret, callee_raw_ret);

        // When the callee uses sret, prepend an alloca for the result.
        // Index alignment: actual_args[0] = sret_slot; actual_args[i+1] = sx arg i.
        const sret_off: usize = if (callee_uses_sret) 1 else 0;
        const total_args = call_op.args.len + sret_off;
        const args = self.e.alloc.alloc(c.LLVMValueRef, total_args) catch unreachable;
        defer self.e.alloc.free(args);
        var sret_slot: c.LLVMValueRef = null;
        if (callee_uses_sret) {
            sret_slot = self.e.buildEntryAlloca(callee_raw_ret, "sret.slot");
            args[0] = sret_slot;
        }
        for (call_op.args, 0..) |arg_ref, j| {
            args[j + sret_off] = self.e.resolveRef(arg_ref);
        }
        const arg_count: c_uint = @intCast(total_args);

        // Get the function type from LLVM and coerce arguments
        const fn_ty = c.LLVMGlobalGetValueType(callee);
        const param_count = c.LLVMCountParamTypes(fn_ty);
        if (param_count > 0) {
            const param_types = self.e.alloc.alloc(c.LLVMTypeRef, param_count) catch unreachable;
            defer self.e.alloc.free(param_types);
            c.LLVMGetParamTypes(fn_ty, param_types.ptr);
            for (0..@min(args.len, param_count)) |j| {
                // The sret slot is already a properly-typed pointer; skip coercion.
                if (callee_uses_sret and j == 0) continue;
                const fn_param_idx = j - sret_off;
                // Materialize byval args before coercion so we pass a ptr instead of the struct value.
                if (callee_needs_c_abi and fn_param_idx < callee_func.params.len) {
                    const ir_ty = callee_func.params[fn_param_idx].ty;
                    const raw_struct = self.e.toLLVMType(ir_ty);
                    if (self.e.needsByval(ir_ty, raw_struct)) {
                        args[j] = self.e.materializeByvalArg(args[j], raw_struct);
                        continue;
                    }
                }
                args[j] = self.e.coerceArg(args[j], param_types[j]);
            }
        }
        // A `void`/`noreturn` call has no value, so it must stay
        // unnamed (LLVM rejects a named void result).
        const call_is_void_like = instruction.ty == .void or instruction.ty == .noreturn;
        const call_label: [*:0]const u8 = if (call_is_void_like or callee_uses_sret) "" else "call";
        var result = c.LLVMBuildCall2(self.e.builder, fn_ty, callee, args.ptr, arg_count, call_label);
        if (callee_uses_sret) {
            // Mirror the function-decl `sret(<T>)` attribute on the call site so the
            // LLVM backend lowers arg 0 via x8 (AAPCS64) / hidden ptr (SysV AMD64).
            const sret_kind = c.LLVMGetEnumAttributeKindForName("sret", 4);
            const sret_attr = c.LLVMCreateTypeAttribute(self.e.context, sret_kind, callee_raw_ret);
            const param1_idx: c.LLVMAttributeIndex = @bitCast(@as(i32, 1));
            c.LLVMAddCallSiteAttribute(result, param1_idx, sret_attr);
            // Load the actual struct value the callee wrote into the slot.
            result = c.LLVMBuildLoad2(self.e.builder, callee_raw_ret, sret_slot, "sret.load");
        } else if (!call_is_void_like and cstr_ret != .none) {
            // The C side returned `char *`; build the fat sx string (and the
            // optional wrapper) from it.
            result = self.e.cstrReturnToSx(result, cstr_ret == .optional);
        } else if (!call_is_void_like and callee_func.is_extern) {
            // Coerce ABI return value (e.g. i64 / [2 x i64]) back to IR struct type if needed
            const expected_ty = self.e.toLLVMType(instruction.ty);
            result = self.e.coerceArg(result, expected_ty);
        }
        self.e.mapRef(result);
    }

    pub fn emitCallIndirect(self: Ops, instruction: *const Inst, call_op: CallIndirect) void {
        const callee = self.e.resolveRef(call_op.callee);

        // Get callee's IR type to resolve parameter types accurately
        const callee_ir_ty = self.e.getRefIRType(call_op.callee);
        const fn_params: ?[]const TypeId = if (callee_ir_ty) |cty| blk: {
            if (!cty.isBuiltin()) {
                const ci = self.e.ir_mod.types.get(cty);
                switch (ci) {
                    .function => |f| break :blk f.params,
                    .closure => |cl| break :blk cl.params,
                    else => {},
                }
            }
            break :blk null;
        } else null;

        // Read the fn-pointer type's calling convention. A `.c` fn pointer's
        // call site must mirror declareFunction's C-ABI signature for an
        // sx-defined abi(.c) callee (issue 0295): coerced params, coerced
        // small-struct return, sret for >16 B non-HFA returns.
        const fp_is_c_abi: bool = if (callee_ir_ty) |cty| blk: {
            if (!cty.isBuiltin()) {
                const ci = self.e.ir_mod.types.get(cty);
                if (ci == .function and ci.function.call_conv == .c) break :blk true;
            }
            break :blk false;
        } else false;

        // Default-conv fn-pointers under implicit-ctx carry a hidden
        // `*void` (the implicit __sx_ctx) at LLVM slot 0. The IR fn
        // type does not include it, so shift fn_params lookups by 1.
        const fp_ctx_slots: usize = if (callee_ir_ty) |cty| blk: {
            if (!self.e.ir_mod.has_implicit_ctx) break :blk 0;
            if (cty.isBuiltin()) break :blk 0;
            const ci = self.e.ir_mod.types.get(cty);
            switch (ci) {
                .function => |f| break :blk if (f.call_conv == .c) @as(usize, 0) else 1,
                else => break :blk 0,
            }
        } else 0;

        const ir_ret: ?TypeId = if (callee_ir_ty) |cty| blk: {
            if (!cty.isBuiltin()) {
                const ci = self.e.ir_mod.types.get(cty);
                switch (ci) {
                    .function => |f| break :blk f.ret,
                    .closure => |cl| break :blk cl.ret,
                    else => {},
                }
            }
            break :blk null;
        } else null;
        const raw_ret_ty = self.e.toLLVMType(ir_ret orelse instruction.ty);

        // An abi(.c) callee returning a >16 B non-HFA struct is declared
        // sret (hidden out-pointer at arg 0, void return); mirror it here.
        const uses_sret = fp_is_c_abi and ir_ret != null and self.e.needsByval(ir_ret.?, raw_ret_ty);
        const sret_off: usize = if (uses_sret) 1 else 0;

        const total_args = call_op.args.len + sret_off;
        const arg_count: c_uint = @intCast(total_args);
        const args = self.e.alloc.alloc(c.LLVMValueRef, total_args) catch unreachable;
        defer self.e.alloc.free(args);
        var sret_slot: c.LLVMValueRef = null;
        if (uses_sret) {
            sret_slot = self.e.buildEntryAlloca(raw_ret_ty, "sret.slot");
            args[0] = sret_slot;
        }
        for (call_op.args, 0..) |arg_ref, j| {
            args[j + sret_off] = self.e.resolveRef(arg_ref);
        }

        const ret_ty = if (uses_sret)
            self.e.cached_void
        else if (fp_is_c_abi and ir_ret != null)
            self.e.abiCoerceParamTypeEx(ir_ret.?, raw_ret_ty, false)
        else
            raw_ret_ty;

        const param_tys = self.e.alloc.alloc(c.LLVMTypeRef, total_args) catch unreachable;
        defer self.e.alloc.free(param_tys);
        if (uses_sret) param_tys[0] = self.e.cached_ptr;
        if (fn_params) |fp| {
            for (0..call_op.args.len) |i| {
                const j = i + sret_off;
                // Slots 0..fp_ctx_slots are the implicit __sx_ctx
                // (passed as opaque ptr; not in fp).
                if (i < fp_ctx_slots) {
                    param_tys[j] = self.e.cached_ptr;
                    args[j] = self.e.coerceArg(args[j], self.e.cached_ptr);
                    continue;
                }
                const fp_idx = i - fp_ctx_slots;
                if (fp_idx < fp.len) {
                    const raw_struct = self.e.toLLVMType(fp[fp_idx]);
                    if (fp_is_c_abi and self.e.needsByval(fp[fp_idx], raw_struct)) {
                        args[j] = self.e.materializeByvalArg(args[j], raw_struct);
                        param_tys[j] = self.e.cached_ptr;
                        continue;
                    }
                    var llvm_pty = raw_struct;
                    if (c.LLVMGetTypeKind(raw_struct) == c.LLVMArrayTypeKind) {
                        // Array params in fn-ptr calls decay to pointers (C ABI)
                        llvm_pty = self.e.cached_ptr;
                    } else if (fp_is_c_abi) {
                        // Mirror declareFunction's C-ABI classification for an
                        // sx-defined abi(.c) callee. is_extern_c_api=false is
                        // the fn-pointer contract (the block-trampoline
                        // convention): fat string/slice preserved, ≤8 B
                        // non-HFA structs → i64, 9–16 B → [2 x i64].
                        llvm_pty = self.e.abiCoerceParamTypeEx(fp[fp_idx], raw_struct, false);
                    } else {
                        // A default-conv callee is declared with the
                        // default-ABI packing (≤8-byte non-HFA structs →
                        // i64); the indirect call type must match it.
                        llvm_pty = self.e.abiCoerceDefaultParamType(fp[fp_idx], raw_struct);
                    }
                    param_tys[j] = llvm_pty;
                    args[j] = self.e.coerceArg(args[j], llvm_pty);
                } else {
                    param_tys[j] = c.LLVMTypeOf(args[j]);
                }
            }
        } else {
            for (0..call_op.args.len) |i| {
                param_tys[i + sret_off] = c.LLVMTypeOf(args[i + sret_off]);
            }
        }
        const fn_ty = c.LLVMFunctionType(ret_ty, param_tys.ptr, arg_count, 0);
        const icall_void_like = instruction.ty == .void or instruction.ty == .noreturn;
        var result = c.LLVMBuildCall2(self.e.builder, fn_ty, callee, args.ptr, arg_count, if (icall_void_like or uses_sret) "" else "icall");

        if (uses_sret) {
            // Mirror the decl-side `sret(<T>)` attribute on the call site so
            // the backend routes arg 0 via x8 (AAPCS64) / hidden ptr (SysV).
            const sret_kind = c.LLVMGetEnumAttributeKindForName("sret", 4);
            const sret_attr = c.LLVMCreateTypeAttribute(self.e.context, sret_kind, raw_ret_ty);
            const param1_idx: c.LLVMAttributeIndex = @bitCast(@as(i32, 1));
            c.LLVMAddCallSiteAttribute(result, param1_idx, sret_attr);
            result = c.LLVMBuildLoad2(self.e.builder, raw_ret_ty, sret_slot, "sret.load");
        }

        // Coerce call result to instruction's expected type
        const expected_ty = self.e.toLLVMType(instruction.ty);
        if (!icall_void_like and c.LLVMTypeOf(result) != expected_ty) {
            result = self.e.coerceArg(result, expected_ty);
        }
        self.e.mapRef(result);
    }

    // ── Call extensions ───────────────────────────────────────
    /// Resolve the `TypeId` (as a runtime `i64`) that a dynamic
    /// `type_name` / `type_is_unsigned` must operate on. A reflection
    /// builtin reads an `Any`'s runtime TYPE-TAG, never its raw payload:
    ///   - `.bare`: a `Type` value (a `.type_value` arg) — a bare i64 `TypeId`
    ///     index (e.g. `type_of(x)` directly) → the value itself.
    ///   - `.boxed`: an `Any` aggregate `{ tag, value }`. When the tag is
    ///     `.type_value`, the box carries a *Type value* (a `Type` boxed into an
    ///     `Any`, `{ .type_value, tid }`) → the TypeId is the payload.
    ///     Otherwise the box carries a *runtime value* whose type IS the tag
    ///     → use the tag as the TypeId. This is what makes `type_name(av)`
    ///     for `av : Any = 6` report `i64` (the held value's type), while
    ///     `type_name(type_of(x))` still names the held type.
    /// `.unresolved` is a hard tripwire: a type-resolution failure reached
    /// emission without a diagnostic.
    fn reflectArgTypeId(self: Ops, arg_ref: Ref, comptime label: []const u8) c.LLVMValueRef {
        const arg_val = self.e.resolveRef(arg_ref);
        return switch (self.e.reflectArgRepr(arg_ref)) {
            .unresolved => @panic(label ++ ": reflection arg IR-type unresolved — a type-resolution failure reached LLVM emission without a diagnostic"),
            .bare => arg_val,
            .boxed => blk: {
                const tag = c.LLVMBuildExtractValue(self.e.builder, arg_val, 1, "refl.tag");
                const payload = c.LLVMBuildExtractValue(self.e.builder, arg_val, 0, "refl.val");
                const type_tag = c.LLVMConstInt(self.e.cached_i64, @intCast(TypeId.type_value.index()), 0);
                const holds_type = c.LLVMBuildICmp(self.e.builder, c.LLVMIntEQ, tag, type_tag, "refl.istype");
                // The data word is the view's ADDRESS. When the box holds a
                // Type value, the TypeId sits BEHIND it (an 8-byte load) —
                // branch rather than select: an unconditional load would
                // overread a view of a smaller-than-8-byte value.
                const cur_fn = c.LLVMGetBasicBlockParent(c.LLVMGetInsertBlock(self.e.builder));
                const from_bb = c.LLVMGetInsertBlock(self.e.builder);
                const load_bb = c.LLVMAppendBasicBlockInContext(self.e.context, cur_fn, "refl.loadtid");
                const join_bb = c.LLVMAppendBasicBlockInContext(self.e.context, cur_fn, "refl.join");
                _ = c.LLVMBuildCondBr(self.e.builder, holds_type, load_bb, join_bb);
                c.LLVMPositionBuilderAtEnd(self.e.builder, load_bb);
                const ptr = c.LLVMBuildIntToPtr(self.e.builder, payload, self.e.cached_ptr, "refl.ptr");
                const loaded = c.LLVMBuildLoad2(self.e.builder, self.e.cached_i64, ptr, "refl.loaded");
                _ = c.LLVMBuildBr(self.e.builder, join_bb);
                c.LLVMPositionBuilderAtEnd(self.e.builder, join_bb);
                const phi = c.LLVMBuildPhi(self.e.builder, self.e.cached_i64, "refl.tid");
                var vals = [2]c.LLVMValueRef{ tag, loaded };
                var bbs = [2]c.LLVMBasicBlockRef{ from_bb, load_bb };
                c.LLVMAddIncoming(phi, &vals, &bbs, 2);
                break :blk phi;
            },
        };
    }

    /// Print how the binary reaches the current function, root first. Without
    /// it the reader sees only the last hop — and the question a staging error
    /// actually raises is "why is this in the runtime graph at all?".
    fn reportRuntimePath(self: Ops, callee_name: []const u8) void {
        const reach = &(self.e.reach orelse return);
        const here = ir_inst.FuncId.fromIndex(self.e.current_func_idx);
        const path = reach.pathTo(self.e.alloc, here) catch return;
        defer self.e.alloc.free(path);
        if (path.len == 0) return; // not reachable from a root: nothing to show
        std.debug.print("  reached from the runtime graph:\n", .{});
        for (path, 0..) |fid, i| {
            const n = self.e.ir_mod.types.getString(self.e.ir_mod.functions.items[fid.index()].name);
            std.debug.print("    {s}{s}\n", .{ if (i == 0) "" else "-> ", n });
        }
        std.debug.print("    -> {s}   (compile-time only)\n", .{callee_name});
    }

    pub fn emitCallBuiltin(self: Ops, instruction: *const Inst, bi: BuiltinCall) void {
        // Builtins that map to libc functions or LLVM intrinsics
        switch (bi.builtin) {
            .sqrt, .sin, .cos, .floor => {
                const val = self.e.resolveRef(bi.args[0]);
                const val_ty = c.LLVMTypeOf(val);
                const val_kind = c.LLVMGetTypeKind(val_ty);
                if (val_kind == c.LLVMFloatTypeKind) {
                    const f = self.e.getOrDeclareMathF32(bi.builtin);
                    var args = [_]c.LLVMValueRef{val};
                    self.e.mapRef(c.LLVMBuildCall2(self.e.builder, self.e.getMathF32Type(), f, &args, 1, @tagName(bi.builtin)));
                } else {
                    const coerced = if (val_kind != c.LLVMDoubleTypeKind) self.e.coerceArg(val, self.e.cached_f64) else val;
                    const f = self.e.getOrDeclareMathF64(bi.builtin);
                    var args = [_]c.LLVMValueRef{coerced};
                    self.e.mapRef(c.LLVMBuildCall2(self.e.builder, self.e.getMathF64Type(), f, &args, 1, @tagName(bi.builtin)));
                }
            },
            .type_name => {
                // Dynamic `type_name(t)` at runtime: resolve the TypeId
                // the arg denotes (reading an `Any`'s runtime type-tag,
                // not its payload — see `reflectArgTypeId`), GEP into the
                // compiler-emitted `__sx_type_names` global, load the
                // string.
                const tid_idx = self.reflectArgTypeId(bi.args[0], "type_name");
                const arr_global = self.e.reflection().getOrBuildTypeNameArray();
                const arr_len = self.e.type_name_array_len;
                const string_ty = self.e.getStringStructType();
                const arr_ty = c.LLVMArrayType(string_ty, arr_len);
                const zero = c.LLVMConstInt(self.e.cached_i64, 0, 0);
                var indices = [2]c.LLVMValueRef{ zero, tid_idx };
                const gep = c.LLVMBuildInBoundsGEP2(self.e.builder, arr_ty, arr_global, &indices, 2, "tn.gep");
                const result = c.LLVMBuildLoad2(self.e.builder, string_ty, gep, "tn.load");
                self.e.mapRef(result);
            },
            .is_unsigned => {
                // Dynamic `type_is_unsigned(t)`: resolve the TypeId the arg
                // denotes (reading an `Any`'s runtime type-tag, not its
                // payload — see `reflectArgTypeId`), GEP into the
                // `__sx_type_is_unsigned` table, load the i1. Mirrors the
                // `type_name` runtime lookup.
                const tid_idx = self.reflectArgTypeId(bi.args[0], "is_unsigned");
                const arr_global = self.e.reflection().getOrBuildTypeIsUnsignedArray();
                const arr_len = self.e.type_is_unsigned_array_len;
                const arr_ty = c.LLVMArrayType(self.e.cached_i1, arr_len);
                const zero = c.LLVMConstInt(self.e.cached_i64, 0, 0);
                var indices = [2]c.LLVMValueRef{ zero, tid_idx };
                const gep = c.LLVMBuildInBoundsGEP2(self.e.builder, arr_ty, arr_global, &indices, 2, "tiu.gep");
                const result = c.LLVMBuildLoad2(self.e.builder, self.e.cached_i1, gep, "tiu.load");
                self.e.mapRef(result);
            },
            .rt_size_of, .rt_align_of, .rt_struct_field_count, .rt_variant_count, .rt_is_flags, .rt_vector_lanes, .rt_variant_tag_width => {
                // Runtime-Type scalar reflection (1a-S2): resolve the tag the
                // arg denotes (any → its type-tag), GEP the builtin's lazy
                // table, load. Same shape as the type_name/is_unsigned arms.
                const kind: @import("reflection.zig").Reflection.ScalarTableKind = switch (bi.builtin) {
                    .rt_size_of => .size,
                    .rt_align_of => .alignment,
                    .rt_struct_field_count => .sf_count,
                    .rt_variant_count => .var_count,
                    .rt_is_flags => .flags,
                    .rt_vector_lanes => .lanes,
                    .rt_variant_tag_width => .tag_width,
                    else => unreachable,
                };
                const tid_idx = self.reflectArgTypeId(bi.args[0], "runtime reflection");
                const arr_global = self.e.reflection().getOrBuildScalarTable(kind);
                const elem_ty = if (kind == .flags) self.e.cached_i1 else self.e.cached_i64;
                const arr_len = switch (kind) {
                    .size => self.e.type_size_array_len,
                    .alignment => self.e.type_align_array_len,
                    .sf_count => self.e.sf_count_array_len,
                    .var_count => self.e.variant_count_array_len,
                    .flags => self.e.is_flags_array_len,
                    .lanes => self.e.vector_lanes_array_len,
                    .tag_width => self.e.variant_tag_width_array_len,
                };
                const arr_ty = c.LLVMArrayType(elem_ty, arr_len);
                const zero = c.LLVMConstInt(self.e.cached_i64, 0, 0);
                var indices = [2]c.LLVMValueRef{ zero, tid_idx };
                const gep = c.LLVMBuildInBoundsGEP2(self.e.builder, arr_ty, arr_global, &indices, 2, "rts.gep");
                self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, elem_ty, gep, "rts.load"));
            },
            .rt_member_name, .rt_member_type, .rt_field_offset, .rt_variant_value => {
                // Field-family runtime reads (1a-S3b): master [N x ptr] by
                // tag → per-type array → [idx]. OOB idx is documented UB
                // (inbounds GEP), same as the static per-type name arrays.
                const refl = self.e.reflection();
                const kind: @import("reflection.zig").Reflection.MemberTableKind = switch (bi.builtin) {
                    .rt_member_name => .names,
                    .rt_member_type => .types,
                    .rt_field_offset => .offsets,
                    .rt_variant_value => .values,
                    else => unreachable,
                };
                const tag = self.reflectArgTypeId(bi.args[0], "runtime reflection");
                var idx = self.e.resolveRef(bi.args[1]);
                if (c.LLVMTypeOf(idx) != self.e.cached_i64)
                    idx = c.LLVMBuildZExt(self.e.builder, idx, self.e.cached_i64, "mi.z");
                const master = refl.getOrBuildMemberPtrs(kind);
                const master_len = switch (kind) {
                    .names => self.e.member_name_ptrs_len,
                    .types => self.e.member_type_ptrs_len,
                    .offsets => self.e.field_offset_ptrs_len,
                    .values => self.e.member_value_ptrs_len,
                };
                const master_ty = c.LLVMArrayType(self.e.cached_ptr, master_len);
                const zero = c.LLVMConstInt(self.e.cached_i64, 0, 0);
                var mindices = [2]c.LLVMValueRef{ zero, tag };
                const slot_gep = c.LLVMBuildInBoundsGEP2(self.e.builder, master_ty, master, &mindices, 2, "mi.slot");
                const per_type = c.LLVMBuildLoad2(self.e.builder, self.e.cached_ptr, slot_gep, "mi.arr");
                const elem_ty = if (kind == .names) self.e.getStringStructType() else self.e.cached_i64;
                var eindices = [1]c.LLVMValueRef{idx};
                const egep = c.LLVMBuildInBoundsGEP2(self.e.builder, elem_ty, per_type, &eindices, 1, "mi.gep");
                self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, elem_ty, egep, "mi.load"));
            },
            .type_info => {
                // Runtime type_info(tp): master [N x ptr] by tag → record ptr
                // → load the whole record AS the sx TypeInfo LLVM type (bytes
                // match by construction).
                const tag = self.reflectArgTypeId(bi.args[0], "type_info");
                const master = self.e.reflection().getOrBuildTypeInfoRecords(instruction.ty);
                const master_len = self.e.type_info_records_len;
                const master_ty = c.LLVMArrayType(self.e.cached_ptr, master_len);
                const zero = c.LLVMConstInt(self.e.cached_i64, 0, 0);
                var indices = [2]c.LLVMValueRef{ zero, tag };
                const slot = c.LLVMBuildInBoundsGEP2(self.e.builder, master_ty, master, &indices, 2, "ti.slot");
                const rec_ptr = c.LLVMBuildLoad2(self.e.builder, self.e.cached_ptr, slot, "ti.rec");
                const ti_llvm = self.e.toLLVMType(instruction.ty);
                self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, ti_llvm, rec_ptr, "ti.val"));
            },
            .rt_type_eq => {
                // Runtime tag compare — Type is an i64 tag; no table.
                const ta = self.reflectArgTypeId(bi.args[0], "type_eq");
                const tb = self.reflectArgTypeId(bi.args[1], "type_eq");
                self.e.mapRef(c.LLVMBuildICmp(self.e.builder, c.LLVMIntEQ, ta, tb, "rteq"));
            },
            else => {
                // size_of, cast — handled by lowering or codegen glue
                self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
            },
        }
    }

    pub fn emitCallClosure(self: Ops, instruction: *const Inst, call_op: CallIndirect) void {
        // Closure: { fn_ptr, env }.
        //
        // ABI (when module.has_implicit_ctx):
        //   trampoline signature: (__sx_ctx, env, args...)
        //   call_op.args[0]      = __sx_ctx (prepended by lowering)
        //   call_op.args[1..]    = user args
        //   extracted env_ptr     = inserted at LLVM slot 1
        //
        // ABI (without implicit_ctx):
        //   trampoline signature: (env, args...)
        //   call_op.args         = user args (no ctx prepend)
        //   extracted env_ptr     = inserted at LLVM slot 0
        const closure = self.e.resolveRef(call_op.callee);
        const cl_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(closure));
        if (cl_kind != c.LLVMStructTypeKind) {
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
            return;
        }
        const fn_ptr = c.LLVMBuildExtractValue(self.e.builder, closure, 0, "cl.fn");
        const env_ptr = c.LLVMBuildExtractValue(self.e.builder, closure, 1, "cl.env");

        // Get the closure's declared parameter types from the IR type system
        const callee_ir_ty = self.e.getRefIRType(call_op.callee);
        const closure_params: ?[]const TypeId = if (callee_ir_ty) |cty| blk: {
            if (!cty.isBuiltin()) {
                const ci = self.e.ir_mod.types.get(cty);
                if (ci == .closure) break :blk ci.closure.params;
            }
            break :blk null;
        } else null;

        const has_ctx = self.e.ir_mod.has_implicit_ctx;
        const user_args_offset_in_op: usize = if (has_ctx) 1 else 0;
        const user_args_count: usize = call_op.args.len -| user_args_offset_in_op;
        const ctx_slots: usize = if (has_ctx) 1 else 0;
        const total_args = ctx_slots + 1 + user_args_count; // [ctx?] + env + user_args

        const args = self.e.alloc.alloc(c.LLVMValueRef, total_args) catch unreachable;
        defer self.e.alloc.free(args);
        if (has_ctx) {
            args[0] = self.e.resolveRef(call_op.args[0]); // ctx
        }
        args[ctx_slots] = env_ptr;
        for (0..user_args_count) |j| {
            args[ctx_slots + 1 + j] = self.e.resolveRef(call_op.args[user_args_offset_in_op + j]);
        }

        // Build function type using declared param types (not arg types).
        // closure_params is user-visible (no ctx, no env), so they line
        // up with args[ctx_slots+1..].
        const ret_ty = self.e.toLLVMType(instruction.ty);
        const param_tys = self.e.alloc.alloc(c.LLVMTypeRef, total_args) catch unreachable;
        defer self.e.alloc.free(param_tys);
        if (has_ctx) param_tys[0] = self.e.cached_ptr; // __sx_ctx
        param_tys[ctx_slots] = self.e.cached_ptr; // env
        if (closure_params) |cp| {
            for (0..user_args_count) |j| {
                const param_ir_ty = if (j < cp.len) cp[j] else null;
                if (param_ir_ty) |pty| {
                    // The trampoline's declared signature carries the
                    // default-ABI packing (≤8-byte non-HFA structs → i64);
                    // the indirect call type must match it.
                    const llvm_pty = self.e.abiCoerceDefaultParamType(pty, self.e.toLLVMType(pty));
                    param_tys[ctx_slots + 1 + j] = llvm_pty;
                    args[ctx_slots + 1 + j] = self.e.coerceArg(args[ctx_slots + 1 + j], llvm_pty);
                } else {
                    param_tys[ctx_slots + 1 + j] = c.LLVMTypeOf(args[ctx_slots + 1 + j]);
                }
            }
        } else {
            for (0..user_args_count) |j| {
                param_tys[ctx_slots + 1 + j] = c.LLVMTypeOf(args[ctx_slots + 1 + j]);
            }
        }
        const fn_ty = c.LLVMFunctionType(ret_ty, param_tys.ptr, @intCast(total_args), 0);

        const is_void = instruction.ty == .void;
        const result = c.LLVMBuildCall2(self.e.builder, fn_ty, fn_ptr, args.ptr, @intCast(total_args), if (is_void) "" else "ccall");
        if (!is_void) {
            self.e.mapRef(result);
        } else {
            self.e.advanceRefCounter();
        }
    }

    // ── Struct ops ────────────────────────────────────────────
    pub fn emitStructInit(self: Ops, instruction: *const Inst, agg: Aggregate) void {
        const struct_ty = self.e.toLLVMType(instruction.ty);
        const type_kind = c.LLVMGetTypeKind(struct_ty);
        // For vector types, use InsertElement instead of InsertValue
        const is_vector = type_kind == c.LLVMVectorTypeKind or type_kind == c.LLVMScalableVectorTypeKind;
        // For array types, get expected element type for coercion
        const is_array = type_kind == c.LLVMArrayTypeKind;
        const elem_llvm_ty = if (is_array) c.LLVMGetElementType(struct_ty) else null;
        var result = c.LLVMGetUndef(struct_ty);
        for (agg.fields, 0..) |field_ref, i| {
            // A `void` (zero-sized) struct/tuple field lowers to a zero-width
            // `[0 x i8]` slot (see `TypeLowering.fieldLLVMType`); it carries no
            // data. Skip inserting a value — the field's lowered ref is an i64
            // placeholder (`emitConstInt`'s void path) whose type mismatches the
            // slot and would corrupt the aggregate. The undef `[0 x i8]` element
            // is already the correct zero-width value.
            const field_is_void = switch (self.e.ir_mod.types.get(instruction.ty)) {
                .@"struct" => |s| i < s.fields.len and s.fields[i].ty == .void,
                .tuple => |t| i < t.fields.len and t.fields[i] == .void,
                else => false,
            };
            if (field_is_void) continue;
            var field_val = self.e.resolveRef(field_ref);
            if (is_vector) {
                // Coerce element to match vector element type
                const vec_elem_ty = c.LLVMGetElementType(struct_ty);
                const val_ty = c.LLVMTypeOf(field_val);
                if (val_ty != vec_elem_ty) {
                    field_val = self.e.coerceArg(field_val, vec_elem_ty);
                }
                const idx = c.LLVMConstInt(self.e.cached_i32, @intCast(i), 0);
                result = c.LLVMBuildInsertElement(self.e.builder, result, field_val, idx, "vi");
            } else {
                // Coerce element to match array element type if needed
                if (elem_llvm_ty) |elt| {
                    const val_ty = c.LLVMTypeOf(field_val);
                    if (val_ty != elt) {
                        const val_kind = c.LLVMGetTypeKind(val_ty);
                        const elt_kind = c.LLVMGetTypeKind(elt);
                        if (val_kind == c.LLVMIntegerTypeKind and elt_kind == c.LLVMIntegerTypeKind) {
                            const val_w = c.LLVMGetIntTypeWidth(val_ty);
                            const elt_w = c.LLVMGetIntTypeWidth(elt);
                            if (val_w > elt_w) {
                                field_val = c.LLVMBuildTrunc(self.e.builder, field_val, elt, "atrunc");
                            } else if (val_w < elt_w) {
                                field_val = c.LLVMBuildZExt(self.e.builder, field_val, elt, "aext");
                            }
                        }
                    }
                } else if (type_kind == c.LLVMStructTypeKind) {
                    // Coerce struct field value to match declared field type
                    const n_elts = c.LLVMCountStructElementTypes(struct_ty);
                    if (n_elts > 0 and i < n_elts) {
                        const field_ty = c.LLVMStructGetTypeAtIndex(struct_ty, @intCast(i));
                        const val_ty = c.LLVMTypeOf(field_val);
                        if (val_ty != field_ty) {
                            field_val = self.e.coerceArg(field_val, field_ty);
                        }
                    }
                }
                result = c.LLVMBuildInsertValue(self.e.builder, result, field_val, @intCast(i), "si");
            }
        }
        self.e.mapRef(result);
    }

    pub fn emitStructGet(self: Ops, instruction: *const Inst, fa: FieldAccess) void {
        const base = self.e.resolveRef(fa.base);
        // Safety: null base means unresolved reference — emit undef
        if (base == null) {
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
        } else {
            // Safety: check that base is an aggregate type (struct/array/vector), not scalar
            const base_ty = c.LLVMTypeOf(base);
            const base_ty_kind = c.LLVMGetTypeKind(base_ty);
            if (base_ty_kind == c.LLVMVectorTypeKind or base_ty_kind == c.LLVMScalableVectorTypeKind) {
                // Vector: use ExtractElement with an index
                const idx = c.LLVMConstInt(self.e.cached_i32, @intCast(fa.field_index), 0);
                const result = c.LLVMBuildExtractElement(self.e.builder, base, idx, "ve");
                self.e.mapRef(result);
            } else if (base_ty_kind == c.LLVMStructTypeKind or base_ty_kind == c.LLVMArrayTypeKind) {
                // Validate field index is in bounds
                const n_fields = if (base_ty_kind == c.LLVMStructTypeKind) c.LLVMCountStructElementTypes(base_ty) else 0;
                // Check builder has valid insert point
                const insert_bb = c.LLVMGetInsertBlock(self.e.builder);
                if (insert_bb == null or (n_fields == 0 and base_ty_kind == c.LLVMStructTypeKind) or (n_fields > 0 and fa.field_index >= n_fields)) {
                    self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
                } else {
                    const result = c.LLVMBuildExtractValue(self.e.builder, base, @intCast(fa.field_index), "sg");
                    self.e.mapRef(result);
                }
            } else {
                // Base is not an aggregate (e.g., placeholder undef of scalar type)
                self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
            }
        }
    }

    pub fn emitStructGep(self: Ops, instruction: *const Inst, fa: FieldAccess) void {
        const base_ptr = self.e.resolveRef(fa.base);
        // Safety: verify base is a pointer before GEP
        const base_ty_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(base_ptr));
        if (base_ty_kind == c.LLVMPointerTypeKind) {
            const struct_llvm_ty = (if (fa.base_type) |bt|
                self.e.toLLVMType(self.e.resolveAggregate(bt))
            else
                self.e.resolveGepStructType(fa.base, instruction)) orelse {
                self.e.failGepTypeResolution("struct_gep", fa.base);
                return;
            };
            if (!LLVMEmitter.isGepAggregateLLVMType(struct_llvm_ty)) {
                self.e.failGepTypeResolution("struct_gep", fa.base);
                return;
            }
            const st_kind = c.LLVMGetTypeKind(struct_llvm_ty);
            if (st_kind == c.LLVMVectorTypeKind or st_kind == c.LLVMScalableVectorTypeKind) {
                // Vector lane address: GEP [0, lane] into the in-memory vector,
                // yielding a pointer to the lane element for a scalar store
                // (vector lane assignment). Mirrors how the read
                // path extracts a lane; here we address it for a store.
                var indices = [_]c.LLVMValueRef{
                    c.LLVMConstInt(self.e.cached_i64, 0, 0),
                    c.LLVMConstInt(self.e.cached_i64, @intCast(fa.field_index), 0),
                };
                const result = c.LLVMBuildGEP2(self.e.builder, struct_llvm_ty, base_ptr, &indices, 2, "vgep");
                self.e.mapRef(result);
            } else if (st_kind == c.LLVMStructTypeKind or st_kind == c.LLVMArrayTypeKind) {
                const result = c.LLVMBuildStructGEP2(self.e.builder, struct_llvm_ty, base_ptr, @intCast(fa.field_index), "gep");
                self.e.mapRef(result);
            } else {
                self.e.failGepTypeResolution("struct_gep", fa.base);
            }
        } else {
            self.e.failGepTypeResolution("struct_gep", fa.base);
        }
    }

    // ── Enum ops ─────────────────────────────────────────────
    pub fn emitEnumInit(self: Ops, instruction: *const Inst, ei: EnumInit) void {
        if (ei.payload.isNone()) {
            // Simple enum (no payload) — just a tag integer
            const ty = self.e.toLLVMType(instruction.ty);
            const ty_kind = c.LLVMGetTypeKind(ty);
            if (ty_kind == c.LLVMIntegerTypeKind) {
                // Plain enum or builtin integer → integer constant
                self.e.mapRef(c.LLVMConstInt(ty, ei.tag, 0));
            } else if (ty_kind == c.LLVMStructTypeKind) {
                // Tagged union with no payload — header field 0 holds the tag
                const header_ty = c.LLVMStructGetTypeAtIndex(ty, 0);
                const tag_val = c.LLVMConstInt(header_ty, ei.tag, 0);
                var result = c.LLVMGetUndef(ty);
                result = c.LLVMBuildInsertValue(self.e.builder, result, tag_val, 0, "ei.tag");
                self.e.mapRef(result);
            } else {
                self.e.mapRef(c.LLVMConstInt(self.e.cached_i64, ei.tag, 0));
            }
        } else {
            // Tagged union with payload — { header, payload_bytes }
            const union_ty = self.e.toLLVMType(instruction.ty);
            const header_ty = c.LLVMStructGetTypeAtIndex(union_ty, 0);
            const tag_val = c.LLVMConstInt(header_ty, ei.tag, 0);
            const payload_val = self.e.resolveRef(ei.payload);

            // alloca union, store tag, bitcast payload area, store payload
            const tmp = self.e.buildEntryAlloca(union_ty, "ei.tmp");
            // Store tag at field 0
            const tag_ptr = c.LLVMBuildStructGEP2(self.e.builder, union_ty, tmp, 0, "ei.tagp");
            _ = c.LLVMBuildStore(self.e.builder, tag_val, tag_ptr);
            // Store payload at field 1 (bitcast the byte array to payload type)
            const payload_ptr = c.LLVMBuildStructGEP2(self.e.builder, union_ty, tmp, 1, "ei.pp");
            const payload_typed_ptr = c.LLVMBuildBitCast(self.e.builder, payload_ptr, self.e.cached_ptr, "ei.pcast");
            _ = c.LLVMBuildStore(self.e.builder, payload_val, payload_typed_ptr);
            // Load the whole union value
            self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, union_ty, tmp, "ei.val"));
        }
    }

    pub fn emitEnumTag(self: Ops, instruction: *const Inst, un: UnaryOp) void {
        const val = self.e.resolveRef(un.operand);
        // Check if this is a plain enum (integer) or tagged union (struct with tag at 0)
        const val_ty = c.LLVMTypeOf(val);
        const kind = c.LLVMGetTypeKind(val_ty);
        if (kind == c.LLVMStructTypeKind) {
            // Tagged union — extract field 0 (tag)
            var tag = c.LLVMBuildExtractValue(self.e.builder, val, 0, "etag");
            // Truncate to declared tag width if needed (e.g. i64 → i32 for u32 tags)
            // This is essential for FFI unions where the i64 tag slot contains
            // a smaller tag + uninitialized padding (e.g. SDL_Event's u32 type + u32 reserved)
            const target_ty = self.e.toLLVMType(instruction.ty);
            const extracted_bits = c.LLVMGetIntTypeWidth(c.LLVMTypeOf(tag));
            const target_bits = c.LLVMGetIntTypeWidth(target_ty);
            if (target_bits < extracted_bits) {
                tag = c.LLVMBuildTrunc(self.e.builder, tag, target_ty, "etag.trunc");
            }
            self.e.mapRef(tag);
        } else {
            // Plain enum — the value IS the tag
            self.e.mapRef(val);
        }
    }

    pub fn emitEnumPayload(self: Ops, instruction: *const Inst, fa: FieldAccess) void {
        const base = self.e.resolveRef(fa.base);
        const result_ty = self.e.toLLVMType(instruction.ty);
        const base_ty = c.LLVMTypeOf(base);
        const base_kind = c.LLVMGetTypeKind(base_ty);
        if (base_kind == c.LLVMStructTypeKind) {
            // Tagged union: alloca, store, GEP field 1 (payload area), bitcast, load
            const tmp = self.e.buildEntryAlloca(base_ty, "ep.tmp");
            _ = c.LLVMBuildStore(self.e.builder, base, tmp);
            const payload_ptr = c.LLVMBuildStructGEP2(self.e.builder, base_ty, tmp, 1, "ep.pp");
            const typed_ptr = c.LLVMBuildBitCast(self.e.builder, payload_ptr, self.e.cached_ptr, "ep.cast");
            self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, result_ty, typed_ptr, "ep.val"));
        } else {
            self.e.mapRef(c.LLVMGetUndef(result_ty));
        }
    }

    // ── Union ops ────────────────────────────────────────────
    pub fn emitUnionGet(self: Ops, instruction: *const Inst, fa: FieldAccess) void {
        const base = self.e.resolveRef(fa.base);
        const result_ty = self.e.toLLVMType(instruction.ty);
        // Union field access: reinterpret the union's data area as the target type
        const base_ty = c.LLVMTypeOf(base);
        const kind = c.LLVMGetTypeKind(base_ty);
        if (kind == c.LLVMStructTypeKind) {
            // Tagged union { header, payload_bytes } — access payload at field 1
            const tmp = self.e.buildEntryAlloca(base_ty, "ug.tmp");
            _ = c.LLVMBuildStore(self.e.builder, base, tmp);
            const payload_ptr = c.LLVMBuildStructGEP2(self.e.builder, base_ty, tmp, 1, "ug.pp");
            self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, result_ty, payload_ptr, "ug.val"));
        } else {
            // Untagged union [N x i8] — alloca, store, reinterpret-load
            const tmp = self.e.buildEntryAlloca(base_ty, "ug.tmp");
            _ = c.LLVMBuildStore(self.e.builder, base, tmp);
            self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, result_ty, tmp, "ug.val"));
        }
    }

    pub fn emitUnionGep(self: Ops, instruction: *const Inst, fa: FieldAccess) void {
        const base_ptr = self.e.resolveRef(fa.base);
        const base_ty_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(base_ptr));
        if (base_ty_kind == c.LLVMPointerTypeKind) {
            const union_llvm_ty = (if (fa.base_type) |bt|
                self.e.toLLVMType(self.e.resolveAggregate(bt))
            else
                self.e.resolveGepStructType(fa.base, instruction)) orelse {
                self.e.failGepTypeResolution("union_gep", fa.base);
                return;
            };
            if (!LLVMEmitter.isGepAggregateLLVMType(union_llvm_ty)) {
                self.e.failGepTypeResolution("union_gep", fa.base);
                return;
            }
            const st_kind = c.LLVMGetTypeKind(union_llvm_ty);
            if (st_kind == c.LLVMStructTypeKind) {
                // Tagged union — payload is at field 1
                const payload_ptr = c.LLVMBuildStructGEP2(self.e.builder, union_llvm_ty, base_ptr, 1, "ugep.pp");
                self.e.mapRef(payload_ptr);
            } else {
                // Untagged union — data starts at offset 0
                self.e.mapRef(base_ptr);
            }
        } else {
            self.e.failGepTypeResolution("union_gep", fa.base);
        }
    }

    // ── Array/Slice ops ───────────────────────────────────────
    pub fn emitIndexGet(self: Ops, instruction: *const Inst, bin: BinOp) void {
        const base = self.e.resolveRef(bin.lhs);
        const idx = self.e.resolveRef(bin.rhs);
        const base_ty = c.LLVMTypeOf(base);
        const kind = c.LLVMGetTypeKind(base_ty);
        if (kind == c.LLVMVectorTypeKind or kind == c.LLVMScalableVectorTypeKind) {
            // Vector — use extractelement
            // Coerce index to i32 if needed
            const idx32 = self.e.coerceArg(idx, self.e.cached_i32);
            self.e.mapRef(c.LLVMBuildExtractElement(self.e.builder, base, idx32, "ve"));
        } else if (kind == c.LLVMArrayTypeKind) {
            // Fixed-size array value — alloca, store, GEP, load
            const tmp = self.e.buildEntryAlloca(base_ty, "ig.tmp");
            _ = c.LLVMBuildStore(self.e.builder, base, tmp);
            const elem_ty = self.e.toLLVMType(instruction.ty);
            var indices = [_]c.LLVMValueRef{ c.LLVMConstInt(self.e.cached_i64, 0, 0), idx };
            const ptr = c.LLVMBuildGEP2(self.e.builder, base_ty, tmp, &indices, 2, "ig.ptr");
            self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, elem_ty, ptr, "ig.val"));
        } else if (kind == c.LLVMPointerTypeKind) {
            // Pointer (many-pointer or raw ptr) — GEP + load
            const elem_ty = self.e.toLLVMType(instruction.ty);
            var indices = [_]c.LLVMValueRef{idx};
            const ptr = c.LLVMBuildGEP2(self.e.builder, elem_ty, base, &indices, 1, "ig.ptr");
            self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, elem_ty, ptr, "ig.val"));
        } else if (kind == c.LLVMStructTypeKind) {
            // Slice/string {ptr, len} — extract ptr, GEP, load
            const data = c.LLVMBuildExtractValue(self.e.builder, base, 0, "ig.data");
            const elem_ty = self.e.toLLVMType(instruction.ty);
            var indices = [_]c.LLVMValueRef{idx};
            const ptr = c.LLVMBuildGEP2(self.e.builder, elem_ty, data, &indices, 1, "ig.ptr");
            self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, elem_ty, ptr, "ig.val"));
        } else {
            // Non-aggregate base (lowering error) — emit undef
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
        }
    }

    pub fn emitIndexGep(self: Ops, instruction: *const Inst, bin: BinOp) void {
        const base = self.e.resolveRef(bin.lhs);
        const idx = self.e.resolveRef(bin.rhs);
        const base_ty = c.LLVMTypeOf(base);
        const kind = c.LLVMGetTypeKind(base_ty);
        if (kind == c.LLVMArrayTypeKind) {
            // Fixed-size array value — alloca, store, GEP
            const tmp = self.e.buildEntryAlloca(base_ty, "igp.tmp");
            _ = c.LLVMBuildStore(self.e.builder, base, tmp);
            var indices = [_]c.LLVMValueRef{ c.LLVMConstInt(self.e.cached_i64, 0, 0), idx };
            self.e.mapRef(c.LLVMBuildGEP2(self.e.builder, base_ty, tmp, &indices, 2, "igp.ptr"));
        } else if (kind == c.LLVMPointerTypeKind) {
            // Pointer — GEP with proper element type
            const gep_elem = blk: {
                // instruction.ty is the result type (ptr to element)
                // Resolve the pointee type for the GEP element size
                const info = self.e.ir_mod.types.get(instruction.ty);
                break :blk switch (info) {
                    .pointer => |p| self.e.toLLVMType(p.pointee),
                    .many_pointer => |p| self.e.toLLVMType(p.element),
                    else => self.e.cached_i8, // fallback
                };
            };
            var indices = [_]c.LLVMValueRef{idx};
            self.e.mapRef(c.LLVMBuildGEP2(self.e.builder, gep_elem, base, &indices, 1, "igp.ptr"));
        } else if (kind == c.LLVMStructTypeKind) {
            // Slice/string {ptr, len} — extract ptr, GEP with proper element type
            const data = c.LLVMBuildExtractValue(self.e.builder, base, 0, "igp.data");
            const gep_elem = blk: {
                const info = self.e.ir_mod.types.get(instruction.ty);
                break :blk switch (info) {
                    .pointer => |p| self.e.toLLVMType(p.pointee),
                    .many_pointer => |p| self.e.toLLVMType(p.element),
                    else => self.e.cached_i8,
                };
            };
            var indices = [_]c.LLVMValueRef{idx};
            self.e.mapRef(c.LLVMBuildGEP2(self.e.builder, gep_elem, data, &indices, 1, "igp.ptr"));
        } else {
            self.e.mapRef(c.LLVMGetUndef(self.e.cached_ptr));
        }
    }

    pub fn emitLength(self: Ops, un: UnaryOp) void {
        const val = self.e.resolveRef(un.operand);
        const val_ty = c.LLVMTypeOf(val);
        const kind = c.LLVMGetTypeKind(val_ty);
        if (kind == c.LLVMArrayTypeKind) {
            const len = c.LLVMGetArrayLength2(val_ty);
            self.e.mapRef(c.LLVMConstInt(self.e.cached_i64, len, 0));
        } else if (kind == c.LLVMVectorTypeKind or kind == c.LLVMScalableVectorTypeKind) {
            // SIMD vector: .len is the lane count, a compile-time constant.
            const lanes = c.LLVMGetVectorSize(val_ty);
            self.e.mapRef(c.LLVMConstInt(self.e.cached_i64, lanes, 0));
        } else if (kind == c.LLVMStructTypeKind) {
            // Slice/string {ptr, len} — extract field 1 (len)
            self.e.mapRef(c.LLVMBuildExtractValue(self.e.builder, val, 1, "len"));
        } else {
            self.e.mapRef(c.LLVMGetUndef(self.e.cached_i64));
        }
    }

    pub fn emitDataPtr(self: Ops, un: UnaryOp) void {
        const val = self.e.resolveRef(un.operand);
        const val_ty = c.LLVMTypeOf(val);
        const kind = c.LLVMGetTypeKind(val_ty);
        if (kind == c.LLVMStructTypeKind) {
            self.e.mapRef(c.LLVMBuildExtractValue(self.e.builder, val, 0, "dptr"));
        } else {
            self.e.mapRef(c.LLVMGetUndef(self.e.cached_ptr));
        }
    }

    pub fn emitSubslice(self: Ops, instruction: *const Inst, ss: Subslice) void {
        const base = self.e.resolveRef(ss.base);
        var lo = self.e.resolveRef(ss.lo);
        var hi = self.e.resolveRef(ss.hi);
        // Normalize lo/hi to i64 for consistent arithmetic (indices are unsigned)
        if (c.LLVMTypeOf(lo) != self.e.cached_i64) {
            lo = c.LLVMBuildZExt(self.e.builder, lo, self.e.cached_i64, "ss.lo64");
        }
        if (c.LLVMTypeOf(hi) != self.e.cached_i64) {
            hi = c.LLVMBuildZExt(self.e.builder, hi, self.e.cached_i64, "ss.hi64");
        }
        const base_ty = c.LLVMTypeOf(base);
        const base_kind = c.LLVMGetTypeKind(base_ty);
        const slice_ty = self.e.toLLVMType(instruction.ty);
        // Resolve element type from the result slice type for correct GEP stride
        const elem_ty = blk: {
            const info = self.e.ir_mod.types.get(instruction.ty);
            break :blk switch (info) {
                .slice => |s| self.e.toLLVMType(s.element),
                else => self.e.cached_i8,
            };
        };
        if (base_kind == c.LLVMStructTypeKind) {
            // Slice/string: extract data ptr, GEP by lo
            const data = c.LLVMBuildExtractValue(self.e.builder, base, 0, "ss.data");
            var lo_indices = [_]c.LLVMValueRef{lo};
            const new_ptr = c.LLVMBuildGEP2(self.e.builder, elem_ty, data, &lo_indices, 1, "ss.ptr");
            var new_len = c.LLVMBuildSub(self.e.builder, hi, lo, "ss.len");
            // Ensure length is i64 for slice struct {ptr, i64}
            if (c.LLVMTypeOf(new_len) != self.e.cached_i64) {
                new_len = c.LLVMBuildSExt(self.e.builder, new_len, self.e.cached_i64, "ss.ext");
            }
            var result = c.LLVMGetUndef(slice_ty);
            result = c.LLVMBuildInsertValue(self.e.builder, result, new_ptr, 0, "ss.wptr");
            result = c.LLVMBuildInsertValue(self.e.builder, result, new_len, 1, "ss.wlen");
            self.e.mapRef(result);
        } else if (base_kind == c.LLVMArrayTypeKind) {
            // Array: alloca, GEP to element at lo, compute len
            const tmp = self.e.buildEntryAlloca(base_ty, "ss.arr");
            _ = c.LLVMBuildStore(self.e.builder, base, tmp);
            var indices = [_]c.LLVMValueRef{ c.LLVMConstInt(self.e.cached_i64, 0, 0), lo };
            const new_ptr = c.LLVMBuildGEP2(self.e.builder, base_ty, tmp, &indices, 2, "ss.ptr");
            var new_len = c.LLVMBuildSub(self.e.builder, hi, lo, "ss.len");
            // Ensure length is i64 for slice struct {ptr, i64}
            if (c.LLVMTypeOf(new_len) != self.e.cached_i64) {
                new_len = c.LLVMBuildSExt(self.e.builder, new_len, self.e.cached_i64, "ss.ext");
            }
            var result = c.LLVMGetUndef(slice_ty);
            result = c.LLVMBuildInsertValue(self.e.builder, result, new_ptr, 0, "ss.wptr");
            result = c.LLVMBuildInsertValue(self.e.builder, result, new_len, 1, "ss.wlen");
            self.e.mapRef(result);
        } else if (base_kind == c.LLVMPointerTypeKind) {
            // Many-pointer `[*]T` (or a raw `*T`): the base value IS the data
            // pointer — GEP by `lo` for the new start, `len = hi - lo`. (issue
            // 0159: a many-pointer base previously fell to the `else` undef arm,
            // producing a slice with a garbage length. The caller supplies the
            // bound via `hi`; no length is read from the unbounded pointer.)
            var lo_indices = [_]c.LLVMValueRef{lo};
            const new_ptr = c.LLVMBuildGEP2(self.e.builder, elem_ty, base, &lo_indices, 1, "ss.ptr");
            var new_len = c.LLVMBuildSub(self.e.builder, hi, lo, "ss.len");
            if (c.LLVMTypeOf(new_len) != self.e.cached_i64) {
                new_len = c.LLVMBuildSExt(self.e.builder, new_len, self.e.cached_i64, "ss.ext");
            }
            var result = c.LLVMGetUndef(slice_ty);
            result = c.LLVMBuildInsertValue(self.e.builder, result, new_ptr, 0, "ss.wptr");
            result = c.LLVMBuildInsertValue(self.e.builder, result, new_len, 1, "ss.wlen");
            self.e.mapRef(result);
        } else {
            self.e.mapRef(c.LLVMGetUndef(slice_ty));
        }
    }

    pub fn emitArrayToSlice(self: Ops, instruction: *const Inst, un: UnaryOp) void {
        const arr = self.e.resolveRef(un.operand);
        const arr_ty = c.LLVMTypeOf(arr);
        const arr_kind = c.LLVMGetTypeKind(arr_ty);
        if (arr_kind == c.LLVMArrayTypeKind) {
            const len = c.LLVMGetArrayLength2(arr_ty);
            const tmp = self.e.buildEntryAlloca(arr_ty, "a2s.tmp");
            _ = c.LLVMBuildStore(self.e.builder, arr, tmp);
            var indices = [_]c.LLVMValueRef{ c.LLVMConstInt(self.e.cached_i64, 0, 0), c.LLVMConstInt(self.e.cached_i64, 0, 0) };
            const elem_ptr = c.LLVMBuildGEP2(self.e.builder, arr_ty, tmp, &indices, 2, "a2s.ptr");
            const slice_ty = self.e.toLLVMType(instruction.ty);
            var result = c.LLVMGetUndef(slice_ty);
            result = c.LLVMBuildInsertValue(self.e.builder, result, elem_ptr, 0, "a2s.wptr");
            const len_val = c.LLVMConstInt(self.e.cached_i64, len, 0);
            result = c.LLVMBuildInsertValue(self.e.builder, result, len_val, 1, "a2s.wlen");
            self.e.mapRef(result);
        } else {
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
        }
    }

    // ── Tuple ops ────────────────────────────────────────────
    pub fn emitTupleInit(self: Ops, instruction: *const Inst, agg: Aggregate) void {
        const tuple_ty = self.e.toLLVMType(instruction.ty);
        var result = c.LLVMGetUndef(tuple_ty);
        for (agg.fields, 0..) |field_ref, i| {
            const field_val = self.e.resolveRef(field_ref);
            result = c.LLVMBuildInsertValue(self.e.builder, result, field_val, @intCast(i), "ti");
        }
        self.e.mapRef(result);
    }

    pub fn emitTupleGet(self: Ops, fa: FieldAccess) void {
        const base = self.e.resolveRef(fa.base);
        self.e.mapRef(c.LLVMBuildExtractValue(self.e.builder, base, @intCast(fa.field_index), "tg"));
    }

    // ── Optional ops ─────────────────────────────────────────
    pub fn emitOptionalWrap(self: Ops, instruction: *const Inst, un: UnaryOp) void {
        var val = self.e.resolveRef(un.operand);
        const opt_ty = self.e.toLLVMType(instruction.ty);
        const opt_kind = c.LLVMGetTypeKind(opt_ty);
        if (opt_kind == c.LLVMPointerTypeKind) {
            // ?*T — pointer is the optional itself (null = none)
            self.e.mapRef(val);
        } else if (opt_kind == c.LLVMStructTypeKind) {
            // Distinguish {T, i1} (real optional) from {ptr, ptr} (?Closure)
            const num_fields = c.LLVMCountStructElementTypes(opt_ty);
            const last_field_ty = if (num_fields > 0) c.LLVMStructGetTypeAtIndex(opt_ty, num_fields - 1) else self.e.cached_i1;
            if (last_field_ty == self.e.cached_i1) {
                // ?T → { T, i1 } — wrap value + true flag
                const inner_ty = c.LLVMStructGetTypeAtIndex(opt_ty, 0);
                val = self.e.coerceArg(val, inner_ty);
                var result = c.LLVMGetUndef(opt_ty);
                result = c.LLVMBuildInsertValue(self.e.builder, result, val, 0, "ow.val");
                result = c.LLVMBuildInsertValue(self.e.builder, result, c.LLVMConstInt(self.e.cached_i1, 1, 0), 1, "ow.has");
                self.e.mapRef(result);
            } else {
                // ?Closure → closure struct IS the optional, just pass through
                self.e.mapRef(val);
            }
        } else {
            self.e.mapRef(val);
        }
    }

    pub fn emitOptionalUnwrap(self: Ops, un: UnaryOp) void {
        const val = self.e.resolveRef(un.operand);
        const val_ty = c.LLVMTypeOf(val);
        const kind = c.LLVMGetTypeKind(val_ty);
        if (kind == c.LLVMStructTypeKind) {
            // Distinguish {T, i1} (real optional) from {ptr, ptr} (?Closure)
            const num_fields = c.LLVMCountStructElementTypes(val_ty);
            const last_field_ty = if (num_fields > 0) c.LLVMStructGetTypeAtIndex(val_ty, num_fields - 1) else self.e.cached_i1;
            if (last_field_ty == self.e.cached_i1) {
                // { T, i1 } → extract field 0
                self.e.mapRef(c.LLVMBuildExtractValue(self.e.builder, val, 0, "ou.val"));
            } else {
                // ?Closure → the struct itself is the value
                self.e.mapRef(val);
            }
        } else {
            // ?*T → pointer is the value itself
            self.e.mapRef(val);
        }
    }

    pub fn emitOptionalHasValue(self: Ops, un: UnaryOp) void {
        const val = self.e.resolveRef(un.operand);
        const val_ty = c.LLVMTypeOf(val);
        const kind = c.LLVMGetTypeKind(val_ty);
        if (kind == c.LLVMStructTypeKind) {
            // Distinguish {T, i1} (real optional) from {ptr, ptr} (?Closure)
            const num_fields = c.LLVMCountStructElementTypes(val_ty);
            const last_field_ty = if (num_fields > 0) c.LLVMStructGetTypeAtIndex(val_ty, num_fields - 1) else self.e.cached_i1;
            if (last_field_ty == self.e.cached_i1) {
                // { T, i1 } → extract has_value flag
                self.e.mapRef(c.LLVMBuildExtractValue(self.e.builder, val, num_fields - 1, "oh.has"));
            } else {
                // ?Closure {fn_ptr, env} → check if fn_ptr is null
                const fn_ptr = c.LLVMBuildExtractValue(self.e.builder, val, 0, "oh.fn");
                self.e.mapRef(c.LLVMBuildICmp(self.e.builder, c.LLVMIntNE, fn_ptr, c.LLVMConstNull(c.LLVMTypeOf(fn_ptr)), "oh.nn"));
            }
        } else {
            // ?*T → compare with null
            const is_nonnull = c.LLVMBuildICmp(self.e.builder, c.LLVMIntNE, val, c.LLVMConstNull(val_ty), "oh.nn");
            self.e.mapRef(is_nonnull);
        }
    }

    pub fn emitOptionalCoalesce(self: Ops, bin: BinOp) void {
        // a ?? b — if a has value, use a's value; otherwise use b
        const a = self.e.resolveRef(bin.lhs);
        var b_val = self.e.resolveRef(bin.rhs);
        const a_ty = c.LLVMTypeOf(a);
        const kind = c.LLVMGetTypeKind(a_ty);
        if (kind == c.LLVMStructTypeKind) {
            const n_fields = c.LLVMCountStructElementTypes(a_ty);
            const f1_ty = if (n_fields >= 2) c.LLVMStructGetTypeAtIndex(a_ty, 1) else null;
            const is_ti1 = if (f1_ty) |ft| c.LLVMGetTypeKind(ft) == c.LLVMIntegerTypeKind and c.LLVMGetIntTypeWidth(ft) == 1 else false;
            if (is_ti1) {
                // Standard optional {T, i1}: extract has_value and unwrap
                const has = c.LLVMBuildExtractValue(self.e.builder, a, 1, "oc.has");
                const unwrapped = c.LLVMBuildExtractValue(self.e.builder, a, 0, "oc.val");
                const uw_ty = c.LLVMTypeOf(unwrapped);
                const b_ty = c.LLVMTypeOf(b_val);
                if (uw_ty != b_ty) {
                    b_val = self.e.coerceArg(b_val, uw_ty);
                }
                self.e.mapRef(c.LLVMBuildSelect(self.e.builder, has, unwrapped, b_val, "oc.sel"));
            } else {
                // ?Closure {fn_ptr, env}: check if fn_ptr is null
                const fn_ptr = c.LLVMBuildExtractValue(self.e.builder, a, 0, "oc.fn");
                const is_nonnull = c.LLVMBuildICmp(self.e.builder, c.LLVMIntNE, fn_ptr, c.LLVMConstNull(c.LLVMTypeOf(fn_ptr)), "oc.nn");
                // Select the full closure struct, not just the fn_ptr
                self.e.mapRef(c.LLVMBuildSelect(self.e.builder, is_nonnull, a, b_val, "oc.sel"));
            }
        } else {
            // ?*T — select on null
            const is_nonnull = c.LLVMBuildICmp(self.e.builder, c.LLVMIntNE, a, c.LLVMConstNull(a_ty), "oc.nn");
            self.e.mapRef(c.LLVMBuildSelect(self.e.builder, is_nonnull, a, b_val, "oc.sel"));
        }
    }

    // ── Terminators ────────────────────────────────────────
    pub fn emitRet(self: Ops, un: UnaryOp) void {
        var val = self.e.resolveRef(un.operand);
        const func = &self.e.ir_mod.functions.items[self.e.current_func_idx];
        // Failable main: wrap the return in the entry-point reporter
        // (ERR E4.2) — exit 0 (or the value) on success, else print the
        // trace + tag to stderr and exit 1 — instead of returning the
        // tag/tuple as the raw exit code. Two shapes:
        //   `-> !`        → `val` is the bare u32 error tag.
        //   `-> (int, !)` → `val` is a `{value, tag}` tuple; extract both.
        if (self.e.current_func_is_main) {
            const rinfo = self.e.ir_mod.types.get(func.ret);
            if (rinfo == .error_set) {
                self.e.emitFailableMainRet(null, val);
                self.e.advanceRefCounter();
                return;
            }
            if (rinfo == .tuple and rinfo.tuple.fields.len == 2 and
                self.e.ir_mod.types.get(rinfo.tuple.fields[1]) == .error_set)
            {
                const value = c.LLVMBuildExtractValue(self.e.builder, val, 0, "main.ret.val");
                const tag = c.LLVMBuildExtractValue(self.e.builder, val, 1, "main.ret.tag");
                self.e.emitFailableMainRet(value, tag);
                self.e.advanceRefCounter();
                return;
            }
        }
        // sret-shaped function: declared return-type-in-IR is
        // the struct, but the LLVM signature is void with a
        // prepended ptr sret param. Store the value through
        // the sret slot and emit ret void.
        const needs_c_abi = func.is_extern or func.call_conv == .c;
        const raw_ret = self.e.toLLVMType(func.ret);
        if (needs_c_abi and self.e.needsByval(func.ret, raw_ret)) {
            const llvm_func2 = c.LLVMGetBasicBlockParent(c.LLVMGetInsertBlock(self.e.builder));
            const sret_ptr = c.LLVMGetParam(llvm_func2, 0);
            _ = c.LLVMBuildStore(self.e.builder, val, sret_ptr);
            _ = c.LLVMBuildRetVoid(self.e.builder);
            self.e.advanceRefCounter();
            return;
        }
        // Coerce return value to match the function's LLVM return type
        const llvm_func = c.LLVMGetBasicBlockParent(c.LLVMGetInsertBlock(self.e.builder));
        const fn_ty = c.LLVMGlobalGetValueType(llvm_func);
        const expected_ret = c.LLVMGetReturnType(fn_ty);
        val = self.e.coerceArg(val, expected_ret);
        // If coercion didn't fix the type (e.g. dead comptime function),
        // emit undef of the correct type to avoid LLVM verification error
        if (c.LLVMTypeOf(val) != expected_ret) {
            val = c.LLVMGetUndef(expected_ret);
        }
        _ = c.LLVMBuildRet(self.e.builder, val);
        self.e.advanceRefCounter();
    }

    pub fn emitRetVoid(self: Ops) void {
        if (self.e.current_func_is_main) {
            // main must return i32 0 for JIT
            _ = c.LLVMBuildRet(self.e.builder, c.LLVMConstInt(self.e.cached_i32, 0, 0));
        } else {
            _ = c.LLVMBuildRetVoid(self.e.builder);
        }
        self.e.advanceRefCounter();
    }

    pub fn emitUnreachable(self: Ops) void {
        _ = c.LLVMBuildUnreachable(self.e.builder);
        self.e.advanceRefCounter();
    }

    pub fn emitBr(self: Ops, branch: Branch, func_idx: u32) void {
        const target = self.e.getBlock(func_idx, branch.target);
        _ = c.LLVMBuildBr(self.e.builder, target);
        self.e.advanceRefCounter();
    }

    pub fn emitCondBr(self: Ops, cbr: CondBranch, func_idx: u32) void {
        var cond = self.e.resolveRef(cbr.cond);
        const then_bb = self.e.getBlock(func_idx, cbr.then_target);
        const else_bb = self.e.getBlock(func_idx, cbr.else_target);
        // Coerce condition to i1 if needed (e.g., loaded bool stored as i64)
        const cond_ty = c.LLVMTypeOf(cond);
        const cond_kind = c.LLVMGetTypeKind(cond_ty);
        if (cond_ty != self.e.cached_i1) {
            if (cond_kind == c.LLVMPointerTypeKind) {
                cond = c.LLVMBuildICmp(self.e.builder, c.LLVMIntNE, cond, c.LLVMConstNull(cond_ty), "tobool");
            } else if (cond_kind == c.LLVMIntegerTypeKind) {
                cond = c.LLVMBuildICmp(self.e.builder, c.LLVMIntNE, cond, c.LLVMConstInt(cond_ty, 0, 0), "tobool");
            } else {
                // UNREACHABLE backend tripwire. A condBr condition must be i1,
                // an integer, or a pointer. Anything else (a struct — e.g. an
                // optional `{T,i1}` aggregate — or a float) is now rejected at
                // lowering with a located type error: `checkConditionType` in
                // src/ir/lower/expr.zig gates every condition site (`if` /
                // `while` / `and` / `or`), and optionals are reduced to their
                // has_value i1 before reaching here (issue 0164). Folding such a
                // condition truthy was a silent miscompile (`if opt { }` always
                // took the present branch); reaching this @panic now means a NEW
                // condition site bypassed `checkConditionType` — add the check
                // there, don't fold truthy.
                @panic("emitCondBr: non-boolean condition reached condBr — should have been rejected at lowering as a type error (issue 0164; see checkConditionType in src/ir/lower/expr.zig)");
            }
        }
        _ = c.LLVMBuildCondBr(self.e.builder, cond, then_bb, else_bb);
        self.e.advanceRefCounter();
    }

    // ── Box/Unbox Any ──────────────────────────────────────
    // `any` = { data: i64 @0, type_id: i64 @8 } where the data word is the
    // ADDRESS of the value (a borrow — Odin's Raw_Any {data, id}, same
    // order). The {ptr, type_id} prefix is SHARED with protocol values.
    // Lowering guarantees box_any's operand is a pointer (borrowed lvalue
    // storage or a spilled frame temp) pointing at exactly
    // size_of(type_id) bytes.
    pub fn emitBoxAny(self: Ops, ba: BoxAny) void {
        const addr = self.e.resolveRef(ba.operand);
        if (c.LLVMGetTypeKind(c.LLVMTypeOf(addr)) != c.LLVMPointerTypeKind) {
            // Backend tripwire: a non-address operand means a lowering site
            // bypassed `boxAnyOf` — fix the site, don't coerce here.
            @panic("emitBoxAny: operand is not an address — box_any takes the value's ADDRESS (route the site through Lowering.boxAnyOf)");
        }
        const any_ty = self.e.getAnyStructType();
        const tag = c.LLVMConstInt(self.e.cached_i64, self.e.anyTag(ba.source_type), 0);
        const data = c.LLVMBuildPtrToInt(self.e.builder, addr, self.e.cached_i64, "ba.data");
        var result = c.LLVMGetUndef(any_ty);
        result = c.LLVMBuildInsertValue(self.e.builder, result, data, 0, "ba.val");
        result = c.LLVMBuildInsertValue(self.e.builder, result, tag, 1, "ba.tag");
        self.e.mapRef(result);
    }

    pub fn emitUnboxAny(self: Ops, instruction: *const Inst, un: UnaryOp) void {
        const any_val = self.e.resolveRef(un.operand);
        const any_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(any_val));
        if (any_kind == c.LLVMStructTypeKind and instruction.ty != .void) {
            // Typed LOAD through the view's data pointer (word 0).
            const raw = c.LLVMBuildExtractValue(self.e.builder, any_val, 0, "ua.raw");
            const ptr = c.LLVMBuildIntToPtr(self.e.builder, raw, self.e.cached_ptr, "ua.ptr");
            const target_ty = self.e.toLLVMType(instruction.ty);
            self.e.mapRef(c.LLVMBuildLoad2(self.e.builder, target_ty, ptr, "ua.load"));
        } else {
            self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
        }
    }

    /// The view's data pointer itself (no load). Result type follows the
    /// instruction (an i64 address word or any pointer type).
    pub fn emitAnyData(self: Ops, instruction: *const Inst, un: UnaryOp) void {
        const any_val = self.e.resolveRef(un.operand);
        const raw = c.LLVMBuildExtractValue(self.e.builder, any_val, 0, "ad.raw");
        const target_ty = self.e.toLLVMType(instruction.ty);
        if (c.LLVMGetTypeKind(target_ty) == c.LLVMPointerTypeKind) {
            self.e.mapRef(c.LLVMBuildIntToPtr(self.e.builder, raw, target_ty, "ad.ptr"));
        } else {
            self.e.mapRef(raw);
        }
    }

    /// Assemble an `any` view from a RUNTIME tag word and an address.
    pub fn emitMakeAny(self: Ops, ma: MakeAny) void {
        const any_ty = self.e.getAnyStructType();
        var tag = self.e.resolveRef(ma.tag);
        if (c.LLVMGetTypeKind(c.LLVMTypeOf(tag)) == c.LLVMPointerTypeKind) {
            tag = c.LLVMBuildPtrToInt(self.e.builder, tag, self.e.cached_i64, "ma.tag");
        }
        var data = self.e.resolveRef(ma.data);
        if (c.LLVMGetTypeKind(c.LLVMTypeOf(data)) == c.LLVMPointerTypeKind) {
            data = c.LLVMBuildPtrToInt(self.e.builder, data, self.e.cached_i64, "ma.data");
        }
        var result = c.LLVMGetUndef(any_ty);
        result = c.LLVMBuildInsertValue(self.e.builder, result, data, 0, "ma.d");
        result = c.LLVMBuildInsertValue(self.e.builder, result, tag, 1, "ma.t");
        self.e.mapRef(result);
    }

    // ── Reflection ops ─────────────────────────────────────
    pub fn emitFieldNameGet(self: Ops, fr: FieldReflect) void {
        // Build global string array for this struct's field names, then GEP at runtime index
        const global = self.e.reflection().getOrBuildFieldNameArray(fr.struct_type);
        const idx = self.e.resolveRef(fr.index);
        const string_ty = self.e.getStringStructType();
        // Size the GEP's array type from the SAME single source of truth
        // (`memberTableLen`) that `getOrBuildFieldNameArray` uses to build the
        // name array, so the two can never disagree (a mismatch was issue 0195:
        // the array was built zero-length for tuples/arrays while this count said
        // N → an out-of-bounds GEP → segfault).
        const field_count: u32 = @intCast(self.e.ir_mod.types.memberTableLen(fr.struct_type) orelse 0);
        const array_ty = c.LLVMArrayType(string_ty, field_count);
        const zero = c.LLVMConstInt(self.e.cached_i64, 0, 0);
        var indices = [2]c.LLVMValueRef{ zero, idx };
        const gep = c.LLVMBuildInBoundsGEP2(self.e.builder, array_ty, global, &indices, 2, "fn.gep");
        const result = c.LLVMBuildLoad2(self.e.builder, string_ty, gep, "fn.load");
        self.e.mapRef(result);
    }

    pub fn emitFieldValueGet(self: Ops, fr: FieldReflect, func_idx: u32) void {
        // Switch on index, each case: extractvalue field k → box as Any
        self.e.emitFieldValueGet(fr, func_idx);
    }

    pub fn emitErrorTagNameGet(self: Ops, u: UnaryOp) void {
        // Tag id → name: GEP into the always-linked tag-name table at
        // the runtime tag id (the error-set value, a u32). Out-of-range
        // ids can't occur — ids come from the same registry the table
        // is built from — so no bounds branch is needed.
        const global = self.e.reflection().getOrBuildTagNameArray();
        const tag_raw = self.e.resolveRef(u.operand);
        const idx = c.LLVMBuildZExt(self.e.builder, tag_raw, self.e.cached_i64, "etn.idx");
        const string_ty = self.e.getStringStructType();
        const n: u32 = @intCast(self.e.ir_mod.types.tags.names.items.len);
        const array_ty = c.LLVMArrayType(string_ty, n);
        const zero = c.LLVMConstInt(self.e.cached_i64, 0, 0);
        var indices = [2]c.LLVMValueRef{ zero, idx };
        const gep = c.LLVMBuildInBoundsGEP2(self.e.builder, array_ty, global, &indices, 2, "etn.gep");
        const result = c.LLVMBuildLoad2(self.e.builder, string_ty, gep, "etn.load");
        self.e.mapRef(result);
    }

    // ── Switch branch ──────────────────────────────────────
    pub fn emitSwitchBr(self: Ops, sw: SwitchBranch, func_idx: u32) void {
        const operand = self.e.resolveRef(sw.operand);
        const default_bb = self.e.getBlock(func_idx, sw.default);
        const switch_inst = c.LLVMBuildSwitch(self.e.builder, operand, default_bb, @intCast(sw.cases.len));
        for (sw.cases) |case| {
            const case_val = c.LLVMConstInt(c.LLVMTypeOf(operand), @bitCast(case.value), 0);
            const case_bb = self.e.getBlock(func_idx, case.target);
            c.LLVMAddCase(switch_inst, case_val, case_bb);
        }
        self.e.advanceRefCounter();
    }

    // ── Closure creation ───────────────────────────────────
    pub fn emitClosureCreate(self: Ops, cc: ClosureCreate) void {
        const fn_val = self.e.func_map.get(cc.func.index()) orelse c.LLVMGetUndef(self.e.cached_ptr);
        const env_val = if (cc.env.isNone()) c.LLVMConstNull(self.e.cached_ptr) else self.e.resolveRef(cc.env);
        const closure_ty = self.e.getClosureStructType();
        var result = c.LLVMGetUndef(closure_ty);
        result = c.LLVMBuildInsertValue(self.e.builder, result, fn_val, 0, "cc.fn");
        result = c.LLVMBuildInsertValue(self.e.builder, result, env_val, 1, "cc.env");
        self.e.mapRef(result);
    }

    // ── Vector ops ─────────────────────────────────────────
    pub fn emitVecSplat(self: Ops, instruction: *const Inst, un: UnaryOp) void {
        const scalar = self.e.resolveRef(un.operand);
        const vec_ty = self.e.toLLVMType(instruction.ty);
        const vec_len = c.LLVMGetVectorSize(vec_ty);
        // Build a splat: insertelement into undef for each lane
        var result = c.LLVMGetUndef(vec_ty);
        var i: c_uint = 0;
        while (i < vec_len) : (i += 1) {
            const idx_val = c.LLVMConstInt(self.e.cached_i32, i, 0);
            result = c.LLVMBuildInsertElement(self.e.builder, result, scalar, idx_val, "splat");
        }
        self.e.mapRef(result);
    }

    pub fn emitVecExtract(self: Ops, bin: BinOp) void {
        const vec = self.e.resolveRef(bin.lhs);
        const idx = self.e.resolveRef(bin.rhs);
        self.e.mapRef(c.LLVMBuildExtractElement(self.e.builder, vec, idx, "vext"));
    }

    pub fn emitVecInsert(self: Ops, tri: TriOp) void {
        const vec = self.e.resolveRef(tri.a);
        const idx = self.e.resolveRef(tri.b);
        const val = self.e.resolveRef(tri.c);
        self.e.mapRef(c.LLVMBuildInsertElement(self.e.builder, vec, val, idx, "vins"));
    }

    // ── Block params ───────────────────────────────────────
    pub fn emitBlockParam(self: Ops, instruction: *const Inst, bp: BlockParam) void {
        // Create a PHI node — incoming values are filled in by fixupPhiNodes
        const ty = self.e.toLLVMType(instruction.ty);
        const phi = c.LLVMBuildPhi(self.e.builder, ty, "bp");
        self.e.pending_phis.append(self.e.alloc, .{
            .phi = phi,
            .block_id = bp.block,
            .param_index = bp.param_index,
        }) catch unreachable;
        self.e.mapRef(phi);
    }

    // ── Misc ───────────────────────────────────────────────
    pub fn emitPlaceholder(self: Ops, instruction: *const Inst) void {
        self.e.mapRef(c.LLVMGetUndef(self.e.toLLVMType(instruction.ty)));
    }
};
