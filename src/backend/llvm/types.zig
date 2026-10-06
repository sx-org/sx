const std = @import("std");
const llvm = @import("../../llvm_api.zig");
const c = llvm.c;
const ir_types = @import("../../ir/types.zig");
const emit = @import("../../ir/emit_llvm.zig");

const TypeId = ir_types.TypeId;
const LLVMEmitter = emit.LLVMEmitter;

/// IR-type → LLVM-type lowering. A backend `*LLVMEmitter` facade (the backend
/// analogue of the IR-side `*Lowering` facades): it borrows the emitter for the cached LLVM
/// handles (`context`/`cached_*`), the IR type table (`ir_mod`), the scratch
/// allocator, and the memoizing composite-type getters
/// (`getStringStructType`/`getAnyStructType`/`getClosureStructType`) that stay
/// on `LLVMEmitter`. `LLVMEmitter.toLLVMType` is a thin wrapper delegating here.
pub const TypeLowering = struct {
    e: *LLVMEmitter,

    pub fn toLLVMType(self: TypeLowering, ty: TypeId) c.LLVMTypeRef {
        const canonical = self.e.ir_mod.types.canonicalType(ty);
        if (canonical != ty) return self.toLLVMType(canonical);
        return switch (ty) {
            .void => self.e.cached_void,
            .bool => self.e.cached_i1,
            .i8 => self.e.cached_i8,
            .i16 => self.e.cached_i16,
            .i32 => self.e.cached_i32,
            .i64 => self.e.cached_i64,
            .u8 => self.e.cached_i8,
            .u16 => self.e.cached_i16,
            .u32 => self.e.cached_i32,
            .u64 => self.e.cached_i64,
            .f32 => self.e.cached_f32,
            .f64 => self.e.cached_f64,
            .any => self.e.getAnyStructType(),
            .noreturn => self.e.cached_void,
            .isize, .usize => if (self.e.target_config.isWasm32()) self.e.cached_i32 else self.e.cached_i64,
            else => self.toLLVMTypeInfo(ty),
        };
    }

    /// Lower a *field* (struct/tuple/array element, or the payload of `?T`). Identical
    /// to `toLLVMType` except that a field which lowers to LLVM's unsized
    /// `void` type (a `void`/`noreturn`/zero-sized field — legitimate, e.g.
    /// `Future(void)`) is substituted with a SIZED zero-byte `[0 x i8]`. LLVM's
    /// `getTypeSizeInBits` traps on an unsized struct element ("Cannot
    /// getTypeInfo() on a type that is unsized!"); `[0 x i8]` reports size 0 and
    /// keeps the element COUNT and INDICES identical, so field-access codegen
    /// (GEP / extractvalue by `field_index`) needs no remapping.
    pub fn fieldLLVMType(self: TypeLowering, ty: TypeId) c.LLVMTypeRef {
        const lowered = self.toLLVMType(ty);
        if (lowered == self.e.cached_void) {
            return c.LLVMArrayType2(self.e.cached_i8, 0);
        }
        return lowered;
    }

    /// An aggregate (struct, union, array, payload enum, optional, failable)
    /// whose ABI size exceeds 64 bytes is memory-resident unless it is a
    /// single-element struct: an IR value of the type is the address of storage
    /// holding it, never a first-class LLVM value. 64 bytes lies past every
    /// supported target's register-passing limit (an AArch64 HFA/HVA is at most
    /// 64 bytes; SysV x86_64, Win64 and AAPCS64 pass larger aggregates in
    /// memory; the wasm32 C ABI passes every aggregate but a single-element
    /// struct indirectly), so such a value never crosses a C boundary in
    /// registers.
    pub fn isMemoryResident(self: TypeLowering, llvm_ty: c.LLVMTypeRef) bool {
        switch (c.LLVMGetTypeKind(llvm_ty)) {
            c.LLVMStructTypeKind, c.LLVMArrayTypeKind => {},
            else => return false,
        }
        const dl = c.LLVMGetModuleDataLayout(self.e.llvm_module);
        if (c.LLVMABISizeOfType(dl, llvm_ty) <= 64) return false;
        return !isSingleElementStruct(dl, llvm_ty);
    }

    /// A struct with one field that, through nested single-field structs and
    /// one-element arrays, reaches a scalar, pointer or vector leaf filling the
    /// struct. C passes it as that leaf.
    pub fn isSingleElementStruct(dl: c.LLVMTargetDataRef, llvm_ty: c.LLVMTypeRef) bool {
        if (c.LLVMGetTypeKind(llvm_ty) != c.LLVMStructTypeKind) return false;
        var cur = llvm_ty;
        while (true) {
            switch (c.LLVMGetTypeKind(cur)) {
                c.LLVMStructTypeKind => {
                    if (c.LLVMCountStructElementTypes(cur) != 1) return false;
                    cur = c.LLVMStructGetTypeAtIndex(cur, 0);
                },
                c.LLVMArrayTypeKind => {
                    if (c.LLVMGetArrayLength2(cur) != 1) return false;
                    cur = c.LLVMGetElementType(cur);
                },
                c.LLVMIntegerTypeKind,
                c.LLVMHalfTypeKind,
                c.LLVMFloatTypeKind,
                c.LLVMDoubleTypeKind,
                c.LLVMFP128TypeKind,
                c.LLVMPointerTypeKind,
                c.LLVMVectorTypeKind,
                => return c.LLVMABISizeOfType(dl, cur) == c.LLVMABISizeOfType(dl, llvm_ty),
                else => return false,
            }
        }
    }

    fn intLLVMType(self: TypeLowering, width: u8) c.LLVMTypeRef {
        return switch (width) {
            1 => self.e.cached_i1,
            8 => self.e.cached_i8,
            16 => self.e.cached_i16,
            32 => self.e.cached_i32,
            64 => self.e.cached_i64,
            else => c.LLVMIntTypeInContext(self.e.context, width),
        };
    }

    fn toLLVMTypeInfo(self: TypeLowering, ty: TypeId) c.LLVMTypeRef {
        const info = self.e.ir_mod.types.get(ty);
        return switch (info) {
            .signed, .unsigned => self.intLLVMType(self.e.ir_mod.types.integerLayout(ty).?.width),
            .f32 => self.e.cached_f32,
            .f64 => self.e.cached_f64,
            .void => self.e.cached_void,
            .bool => self.e.cached_i1,
            .@"error" => |es| {
                const payload_bytes = self.e.ir_mod.types.errorChannelPayloadBytes(es.tags);
                if (payload_bytes == 0) return self.e.cached_i32;
                var field_types: [2]c.LLVMTypeRef = .{
                    self.e.cached_i32,
                    c.LLVMArrayType2(self.e.cached_i8, @intCast(payload_bytes)),
                };
                return c.LLVMStructTypeInContext(self.e.context, &field_types, 2, 0);
            },
            .pointer, .many_pointer, .function => self.e.cached_ptr,
            .closure => self.e.getClosureStructType(),
            .slice => |s| blk: {
                if (s.len_type == .i64) break :blk self.e.getStringStructType();
                var field_types = [_]c.LLVMTypeRef{ self.e.cached_ptr, self.toLLVMType(s.len_type) };
                break :blk c.LLVMStructTypeInContext(self.e.context, &field_types, 2, 0);
            },
            .optional => |opt| switch (self.e.ir_mod.types.optionalShape(opt.child)) {
                .pointer_word => self.toLLVMType(opt.child),
                .high_bit => self.intLLVMType(@intCast(self.e.ir_mod.types.typeSizeBytes(opt.child) * 8)),
                .flag => blk: {
                    var field_types: [2]c.LLVMTypeRef = .{
                        self.fieldLLVMType(opt.child),
                        self.e.cached_i1,
                    };
                    break :blk c.LLVMStructTypeInContext(self.e.context, &field_types, 2, 0);
                },
            },
            .array => |arr| c.LLVMArrayType2(self.fieldLLVMType(arr.element), arr.storageLen()),
            .vector => |vec| {
                const elem = self.toLLVMType(vec.element);
                return c.LLVMVectorType(elem, vec.length);
            },
            .any => self.e.getAnyStructType(),
            // A comptime `Type` value is an 8-byte type handle (a `TypeId` in a
            // word), distinct from the 16-byte boxed Any. It is comptime-only, but
            // the type still lowers (dead comptime-body code / a global slot) as i64.
            .type_value => self.e.cached_i64,
            .noreturn => self.e.cached_void,
            .@"struct" => |s| {
                // Build LLVM struct type from fields
                const n: c_uint = @intCast(s.fields.len);
                const field_llvm_types = self.e.alloc.alloc(c.LLVMTypeRef, s.fields.len) catch unreachable;
                defer self.e.alloc.free(field_llvm_types);
                for (s.fields, 0..) |field, j| {
                    field_llvm_types[j] = self.fieldLLVMType(field.ty);
                }
                return c.LLVMStructTypeInContext(self.e.context, field_llvm_types.ptr, n, 0);
            },
            .@"union" => |u| {
                // Union — just [N x i8]
                var max_size: usize = 0;
                for (u.fields) |field| {
                    const sz = self.e.ir_mod.types.typeSizeBytes(field.ty);
                    if (sz > max_size) max_size = sz;
                }
                if (max_size == 0) max_size = 8;
                return c.LLVMArrayType2(self.e.cached_i8, @intCast(max_size));
            },
            .@"enum" => |u| {
                // A payload-free enum is its tag word. A payload-carrying one is
                // { header, [N x i8] }, or its own layout struct when it states one.
                if (!u.hasPayload() and u.layout == null) return self.toLLVMType(u.tag_type);
                var max_size: usize = 0;
                for (u.variants) |v| {
                    const sz = self.e.ir_mod.types.typeSizeBytes(v.payload);
                    if (sz > max_size) max_size = sz;
                }

                var header_size: usize = self.e.ir_mod.types.typeSizeBytes(u.tag_type);
                if (u.layout) |bt| {
                    const bi = self.e.ir_mod.types.get(bt);
                    if (bi == .@"struct" and bi.@"struct".fields.len > 1) {
                        const bfields = bi.@"struct".fields;
                        // `{ tag, payload }` over the enum's OWN tag word is a
                        // stated LAYOUT — an open set's — and is lowered as
                        // written, so the payload's element type (and therefore the
                        // value's alignment) is delivered rather than assumed.
                        // A wider header (`enum struct { tag: u32; _: u32; … }`)
                        // states the header FIELDS instead, and keeps the default
                        // `{ header, [N x i8] }` shape every payload access reads.
                        if (bfields.len == 2 and bfields[0].ty == u.tag_type) {
                            return self.toLLVMType(bt);
                        }
                        header_size = 0;
                        for (bfields[0 .. bfields.len - 1]) |f| {
                            header_size += self.e.ir_mod.types.typeSizeBytes(f.ty);
                        }
                        const backing_payload = self.e.ir_mod.types.typeSizeBytes(bfields[bfields.len - 1].ty);
                        if (backing_payload > max_size) max_size = backing_payload;
                    }
                }
                // The default shape. A memberless enum with a stated layout has
                // no payload bytes of its own, and the 8-byte floor keeps that
                // case a nonempty aggregate.
                if (max_size == 0) max_size = 8;

                const header_llvm = c.LLVMIntTypeInContext(self.e.context, @intCast(header_size * 8));
                var field_types: [2]c.LLVMTypeRef = .{
                    header_llvm,
                    c.LLVMArrayType2(self.e.cached_i8, @intCast(max_size)),
                };
                return c.LLVMStructTypeInContext(self.e.context, &field_types, 2, 0);
            },
            .failable => |f| {
                const n_vals = self.e.ir_mod.types.failableValueSlotCount(f);
                const n: c_uint = @intCast(n_vals + 1);
                const field_llvm_types = self.e.alloc.alloc(c.LLVMTypeRef, n_vals + 1) catch unreachable;
                defer self.e.alloc.free(field_llvm_types);
                for (0..n_vals) |j| {
                    field_llvm_types[j] = self.fieldLLVMType(self.e.ir_mod.types.failableValueSlotType(f, j));
                }
                field_llvm_types[n_vals] = self.fieldLLVMType(f.err);
                return c.LLVMStructTypeInContext(self.e.context, field_llvm_types.ptr, n, 0);
            },
            .protocol => {
                // Protocol values: { ctx: *void, vtable_or_fn_ptrs... }
                // Represented as an opaque ptr.
                return self.e.cached_ptr;
            },
            .usize, .isize => if (self.e.target_config.isWasm32()) self.e.cached_i32 else self.e.cached_i64,
            // Comptime-only: a pack is expanded to flat positional args before
            // codegen, so it must never reach LLVM type emission.
            .pack => @panic("pack type has no LLVM representation (comptime-only)"),
            // Tripwire: a failed type resolution must have been diagnosed and
            // aborted long before LLVM emission.
            .unresolved => @panic("unresolved type reached LLVM emission — a type resolution failure was not diagnosed/aborted"),
        };
    }
};
