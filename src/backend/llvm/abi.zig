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
/// On ARM64 (and x86_64), the C calling convention coerces small struct
/// arguments to integers for register passing:
///   - String/slice {ptr, i64} → ptr (extract raw pointer)
///   - Small integer struct (≤ 8 bytes, non-HFA) → i64
///   - HFA (homogeneous float aggregate) → leave as-is (LLVM handles it)
///
/// The default sx ABI applies the same ≤8-byte non-HFA → i64 packing (see
/// `abiCoerceDefaultParamType`) so `{i8×4}` values like UI `Color` are not
/// expanded into four `i8` args that mis-spill on AArch64.
pub const AbiLowering = struct {
    e: *LLVMEmitter,

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
        // A C `va_list` parameter is one pointer-shaped word on every supported
        // target — the size buckets below would classify the cursor's storage
        // instead, and land on `byval` where clang passes a plain pointer.
        if (self.e.ir_mod.types.isCVariadicCursor(ir_ty)) return self.e.cached_ptr;
        if (self.e.isMemoryResident(ir_ty)) return self.e.cached_ptr;

        if (is_extern_c_api) switch (self.e.ir_mod.types.get(ir_ty)) {
            .slice => return self.e.cached_ptr,
            else => {},
        };

        // WASM32: usize/isize are pointer-sized (i32 on wasm32).
        // Other integer types (i64, u64) keep their declared size — they represent
        // genuinely 64-bit values (SDL_WindowFlags, timestamps, etc.).
        if (self.e.target_config.isWasm32()) {
            if (ir_ty == .usize or ir_ty == .isize) return self.e.cached_i32;
            if (self.wasmPassesIndirectly(llvm_ty)) return self.e.cached_ptr;
            return llvm_ty;
        }

        // Only coerce struct types
        if (c.LLVMGetTypeKind(llvm_ty) != c.LLVMStructTypeKind) return llvm_ty;

        // Check if it's an HFA (all float or all double fields) — leave as-is
        if (self.isHfa(llvm_ty)) return llvm_ty;

        // Small struct (≤ 8 bytes) → coerce to i64
        const size = c.LLVMABISizeOfType(
            c.LLVMGetModuleDataLayout(self.e.llvm_module),
            llvm_ty,
        );
        if (size <= 8) return self.e.cached_i64;

        // Medium struct (9-16 bytes) → coerce to [2 x i64]
        if (size <= 16) {
            return c.LLVMArrayType2(self.e.cached_i64, 2);
        }

        // Large composite (> 16 bytes) → pass by reference: ptr + byval(<T>) at
        // the call/sig sites. LLVM's AArch64/x86_64 backend lowers byval to
        // the right ABI sequence (caller copy + indirect arg).
        return self.e.cached_ptr;
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
        if (self.isHfa(llvm_ty)) return llvm_ty;
        const size = c.LLVMABISizeOfType(
            c.LLVMGetModuleDataLayout(self.e.llvm_module),
            llvm_ty,
        );
        if (size <= 8) return self.e.cached_i64;
        return llvm_ty;
    }

    fn isHfa(self: AbiLowering, llvm_ty: c.LLVMTypeRef) bool {
        _ = self;
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

    /// Whether a C-boundary value of `ir_ty` passes as a pointer to a copy the
    /// callee owns, and returns through `sret`. `is_extern_c_api` is
    /// `abiCoerceParamTypeEx`'s: an extern's slice is the pointer it collapses to.
    pub fn needsByval(self: AbiLowering, ir_ty: TypeId, raw_llvm_ty: c.LLVMTypeRef, is_extern_c_api: bool) bool {
        if (self.e.isMemoryResident(ir_ty)) return true;
        if (self.e.ir_mod.types.isCVariadicCursor(ir_ty)) return false;
        const wasm32 = self.e.target_config.isWasm32();
        switch (self.e.ir_mod.types.get(ir_ty)) {
            .slice => if (is_extern_c_api or !wasm32) return false,
            else => {},
        }
        if (wasm32) return self.wasmPassesIndirectly(raw_llvm_ty);
        if (c.LLVMGetTypeKind(raw_llvm_ty) != c.LLVMStructTypeKind) return false;
        if (self.isHfa(raw_llvm_ty)) return false;
        const size = c.LLVMABISizeOfType(c.LLVMGetModuleDataLayout(self.e.llvm_module), raw_llvm_ty);
        return size > 16;
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
