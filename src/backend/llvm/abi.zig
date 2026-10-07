const std = @import("std");
const llvm = @import("../../llvm_api.zig");
const c = llvm.c;
const ir_types = @import("../../ir/types.zig");
const emit = @import("../../ir/emit_llvm.zig");
const llvm_types = @import("types.zig");

const TypeId = ir_types.TypeId;
const LLVMEmitter = emit.LLVMEmitter;

/// Parameter coercion. A backend `*LLVMEmitter` facade: it borrows the emitter for
/// the cached LLVM handles, the IR type table, the module data layout, and the
/// IR builder. `LLVMEmitter.{abiCoerceParamType, abiCoerceParamTypeEx,
/// abiCoerceDefaultParamType, needsByval, materializeByvalArg}` are thin
/// wrappers delegating here.
///
/// On ARM64 (and x86_64), the C calling convention coerces small aggregate
/// arguments for register passing:
///   - String/slice {ptr, i64} → ptr (extract raw pointer)
///   - AArch64 homogeneous float or short-vector aggregate → `[k x base]`
///   - x86_64 struct of one to four floats or doubles → as-is (LLVM handles it)
///   - Any other struct or union ≤ 8 bytes → i64, 9–16 bytes → `[2 x i64]`
///     (`i128` on AArch64 when 16-byte aligned)
///
/// The default sx ABI applies the same ≤8-byte non-HFA → i64 packing (see
/// `abiCoerceDefaultParamType`) so `{i8×4}` values like UI `Color` are not
/// expanded into four `i8` args that mis-spill on AArch64.
pub const AbiLowering = struct {
    e: *LLVMEmitter,

    /// How a C-boundary value crosses: as an LLVM type, or as a pointer to a
    /// copy the callee owns, returning through `sret`.
    const Crossing = union(enum) {
        direct: c.LLVMTypeRef,
        indirect,
    };

    /// An AAPCS64 homogeneous aggregate: `k` leaves of one `base`, which cross
    /// in `k` consecutive SIMD and FP registers as `[k x base]`.
    const Hfa = struct {
        base: c.LLVMTypeRef,
        k: u32,
    };

    /// The first leaf of a homogeneous aggregate, which every later leaf
    /// matches in kind and size.
    const Leaf = struct {
        base: c.LLVMTypeRef,
        size: usize,
        vector: bool,
    };

    pub fn abiCoerceParamType(self: AbiLowering, ir_ty: TypeId, llvm_ty: c.LLVMTypeRef) c.LLVMTypeRef {
        return self.abiCoerceParamTypeEx(ir_ty, llvm_ty, true);
    }

    /// Same as `abiCoerceParamType` but with an explicit
    /// `is_extern_c_api` knob. When true, sx `string` / `[]T` slices
    /// collapse to `ptr` — the libc convention where the user writes
    /// `string` to mean `char *` and the length is dropped. When
    /// false (sx-internal `abi(.c)` like block trampolines), the
    /// full slice shape is preserved and goes through the general
    /// struct-coerce path (16-byte slice → `[2 x i64]`, lands in two
    /// registers on AArch64 — the true C ABI for a 16-byte
    /// aggregate). Without the split, sx-to-sx calls through a
    /// `(*Block, string) -> void abi(.c)` fn-pointer mismatched
    /// the caller's `{ptr, i64}` value against the trampoline's
    /// collapsed `ptr` param.
    pub fn abiCoerceParamTypeEx(self: AbiLowering, ir_ty: TypeId, llvm_ty: c.LLVMTypeRef, is_extern_c_api: bool) c.LLVMTypeRef {
        return switch (self.crossing(ir_ty, llvm_ty, is_extern_c_api)) {
            .direct => |ty| ty,
            .indirect => self.e.cached_ptr,
        };
    }

    /// Whether a C-boundary value of `ir_ty` passes as a pointer to a copy the
    /// callee owns, and returns through `sret`. `is_extern_c_api` is
    /// `abiCoerceParamTypeEx`'s: an extern's slice is the pointer it collapses to.
    pub fn needsByval(self: AbiLowering, ir_ty: TypeId, raw_llvm_ty: c.LLVMTypeRef, is_extern_c_api: bool) bool {
        return self.crossing(ir_ty, raw_llvm_ty, is_extern_c_api) == .indirect;
    }

    fn crossing(self: AbiLowering, ir_ty: TypeId, llvm_ty: c.LLVMTypeRef, is_extern_c_api: bool) Crossing {
        // A C `va_list` parameter is one pointer-shaped word on every supported
        // target — the size buckets below would classify the cursor's storage
        // instead, and land on `byval` where clang passes a plain pointer.
        if (self.e.ir_mod.types.isCVariadicCursor(ir_ty)) return .{ .direct = self.e.cached_ptr };
        if (self.e.isMemoryResident(ir_ty)) return .indirect;
        const info = self.e.ir_mod.types.get(ir_ty);
        if (is_extern_c_api and info == .slice) return .{ .direct = self.e.cached_ptr };

        if (self.e.target_config.isWasm32()) {
            // WASM32: usize/isize are pointer-sized (i32 on wasm32).
            // Other integer types (i64, u64) keep their declared size — they represent
            // genuinely 64-bit values (SDL_WindowFlags, timestamps, etc.).
            if (ir_ty == .usize or ir_ty == .isize) return .{ .direct = self.e.cached_i32 };
            if (info == .@"union") {
                const member = self.wasmUnionMember(info.@"union") orelse return .indirect;
                return .{ .direct = member };
            }
            if (self.wasmPassesIndirectly(llvm_ty)) return .indirect;
            return .{ .direct = llvm_ty };
        }

        const aarch64 = self.e.target_config.isAarch64();
        if (aarch64) {
            if (self.hfa(ir_ty)) |h| return .{ .direct = c.LLVMArrayType2(h.base, h.k) };
        }
        // A union crosses by its size, whatever its storage member.
        if (info != .@"union") {
            if (c.LLVMGetTypeKind(llvm_ty) != c.LLVMStructTypeKind) return .{ .direct = llvm_ty };
            if (isFlatFloatStruct(llvm_ty)) return .{ .direct = llvm_ty };
        }
        const dl = c.LLVMGetModuleDataLayout(self.e.llvm_module);
        const size = c.LLVMABISizeOfType(dl, llvm_ty);
        if (size <= 8) return .{ .direct = self.e.cached_i64 };
        if (size <= 16) {
            // AAPCS64 starts a 16-byte-aligned aggregate at an even register.
            if (aarch64 and c.LLVMABIAlignmentOfType(dl, llvm_ty) == 16) return .{ .direct = c.LLVMInt128TypeInContext(self.e.context) };
            return .{ .direct = c.LLVMArrayType2(self.e.cached_i64, 2) };
        }
        return .indirect;
    }

    /// Default (sx-internal) ABI param coercion. Packs ≤8-byte non-HFA
    /// structs into `i64` so AArch64 does not expand `{i8,i8,i8,i8}` into
    /// four `i8` args that mis-spill when a second such param overflows the
    /// integer registers. Leaves string/slice fat pointers,
    /// HFAs, mid-size, and large structs as their raw LLVM types — those
    /// paths are already correct without C-style register packing.
    pub fn abiCoerceDefaultParamType(self: AbiLowering, ir_ty: TypeId, llvm_ty: c.LLVMTypeRef) c.LLVMTypeRef {
        if (self.e.isMemoryResident(ir_ty)) return self.e.cached_ptr;
        if (self.e.target_config.isWasm32()) return llvm_ty;
        switch (self.e.ir_mod.types.get(ir_ty)) {
            .slice => return llvm_ty,
            else => {},
        }
        if (c.LLVMGetTypeKind(llvm_ty) != c.LLVMStructTypeKind) return llvm_ty;
        if (isFlatFloatStruct(llvm_ty)) return llvm_ty;
        const size = c.LLVMABISizeOfType(
            c.LLVMGetModuleDataLayout(self.e.llvm_module),
            llvm_ty,
        );
        if (size <= 8) return self.e.cached_i64;
        return llvm_ty;
    }

    /// A first-class struct of one to four fields, all `float` or all `double`.
    fn isFlatFloatStruct(llvm_ty: c.LLVMTypeRef) bool {
        const n_fields = c.LLVMCountStructElementTypes(llvm_ty);
        if (n_fields < 1 or n_fields > 4) return false;
        var all_float = true;
        var all_double = true;
        var fi: c_uint = 0;
        while (fi < n_fields) : (fi += 1) {
            const ft = c.LLVMStructGetTypeAtIndex(llvm_ty, fi);
            const fk = c.LLVMGetTypeKind(ft);
            if (fk != c.LLVMFloatTypeKind) all_float = false;
            if (fk != c.LLVMDoubleTypeKind) all_double = false;
        }
        return all_float or all_double;
    }

    /// A struct or union whose leaves, through members and arrays, are one to
    /// four floats of one type or vectors of one size (8 or 16 bytes), and
    /// fill it. Struct members add their leaves, union members take the
    /// largest count, arrays multiply, and members of no size are skipped.
    fn hfa(self: AbiLowering, ir_ty: TypeId) ?Hfa {
        switch (self.e.ir_mod.types.get(ir_ty)) {
            .@"struct", .@"union" => {},
            else => return null,
        }
        var first: ?Leaf = null;
        const k = self.homogeneousLeaves(ir_ty, &first) orelse return null;
        if (k == 0 or k > 4) return null;
        return .{ .base = first.?.base, .k = @intCast(k) };
    }

    /// The leaf count of `ty` when each leaf matches `first`, which the first
    /// leaf sets; null when `ty` is not homogeneous.
    fn homogeneousLeaves(self: AbiLowering, ty: TypeId, first: *?Leaf) ?u64 {
        const types = &self.e.ir_mod.types;
        return switch (types.get(ty)) {
            .f32, .f64 => self.matchLeaf(ty, false, first),
            .vector => self.matchLeaf(ty, true, first),
            .array => |a| (self.homogeneousLeaves(a.element, first) orelse return null) * a.storageLen(),
            .@"struct" => |s| self.memberLeaves(ty, s.fields, false, first),
            .@"union" => |u| self.memberLeaves(ty, u.fields, true, first),
            else => null,
        };
    }

    fn memberLeaves(self: AbiLowering, ty: TypeId, fields: []const ir_types.TypeInfo.StructInfo.Field, is_union: bool, first: *?Leaf) ?u64 {
        const types = &self.e.ir_mod.types;
        var k: u64 = 0;
        for (fields) |f| {
            if (types.typeSizeBytes(f.ty) == 0) continue;
            const n = self.homogeneousLeaves(f.ty, first) orelse return null;
            k = if (is_union) @max(k, n) else k + n;
        }
        const leaf = first.* orelse return null;
        if (leaf.size * k != types.typeSizeBytes(ty)) return null;
        return k;
    }

    fn matchLeaf(self: AbiLowering, ty: TypeId, vector: bool, first: *?Leaf) ?u64 {
        const types = &self.e.ir_mod.types;
        const size = types.typeSizeBytes(ty);
        if (vector and size != 8 and size != 16) return null;
        if (first.*) |leaf| {
            if (leaf.vector != vector or leaf.size != size) return null;
            return 1;
        }
        const base = if (vector) blk: {
            // A vector whose lane count is not a power of two widens to its storage.
            const element = types.get(ty).vector.element;
            const lanes = size / types.typeSizeBytes(element);
            break :blk c.LLVMVectorType(self.e.toLLVMType(element), @intCast(lanes));
        } else self.e.toLLVMType(ty);
        first.* = .{ .base = base, .size = size, .vector = vector };
        return 1;
    }

    /// The one-field struct of a wasm32 union's only member, when C passes the
    /// union as that struct's single element; null when C passes the union
    /// indirectly.
    fn wasmUnionMember(self: AbiLowering, u: ir_types.TypeInfo.UnionInfo) ?c.LLVMTypeRef {
        if (u.fields.len != 1) return null;
        var member = self.e.fieldLLVMType(u.fields[0].ty);
        const member_struct = c.LLVMStructTypeInContext(self.e.context, &member, 1, 0);
        const dl = c.LLVMGetModuleDataLayout(self.e.llvm_module);
        if (!llvm_types.TypeLowering.isSingleElementStruct(dl, member_struct)) return null;
        return member_struct;
    }

    /// The wasm32 C ABI passes and returns every struct indirectly but an empty
    /// or single-element one, which it passes as that element.
    fn wasmPassesIndirectly(self: AbiLowering, llvm_ty: c.LLVMTypeRef) bool {
        if (c.LLVMGetTypeKind(llvm_ty) != c.LLVMStructTypeKind) return false;
        const dl = c.LLVMGetModuleDataLayout(self.e.llvm_module);
        if (c.LLVMABISizeOfType(dl, llvm_ty) == 0) return false;
        return !llvm_types.TypeLowering.isSingleElementStruct(dl, llvm_ty);
    }

    /// The copy of a by-value C argument its callee owns.
    pub fn materializeByvalArg(self: AbiLowering, val: c.LLVMValueRef, ir_ty: TypeId) c.LLVMValueRef {
        const tmp = self.e.residentSlot(ir_ty);
        if (self.e.isMemoryResident(ir_ty)) {
            self.e.copyResident(tmp, val, ir_ty);
        } else {
            _ = c.LLVMBuildStore(self.e.builder, val, tmp);
        }
        return tmp;
    }
};
