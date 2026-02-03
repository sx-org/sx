const std = @import("std");
const llvm = @import("../../llvm_api.zig");
const c = llvm.c;
const ir_types = @import("../../ir/types.zig");
const emit = @import("../../ir/emit_llvm.zig");

const TypeId = ir_types.TypeId;
const LLVMEmitter = emit.LLVMEmitter;

/// IR-type → LLVM-type lowering (architecture phase A7.1), extracted from
/// `LLVMEmitter`. A backend `*LLVMEmitter` facade (the backend analogue of the
/// IR-side `*Lowering` facades): it borrows the emitter for the cached LLVM
/// handles (`context`/`cached_*`), the IR type table (`ir_mod`), the scratch
/// allocator, and the memoizing composite-type getters
/// (`getStringStructType`/`getAnyStructType`/`getClosureStructType`) that stay
/// on `LLVMEmitter`. `LLVMEmitter.toLLVMType` is a thin wrapper delegating here.
pub const TypeLowering = struct {
    e: *LLVMEmitter,

    pub fn toLLVMType(self: TypeLowering, ty: TypeId) c.LLVMTypeRef {
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
            .string => self.e.getStringStructType(),
            .any => self.e.getAnyStructType(),
            .noreturn => self.e.cached_void,
            .isize, .usize => if (self.e.target_config.isWasm32()) self.e.cached_i32 else self.e.cached_i64,
            else => self.toLLVMTypeInfo(ty),
        };
    }

    /// Lower a *field* (struct/tuple element, or the payload of `?T`). Identical
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

    fn toLLVMTypeInfo(self: TypeLowering, ty: TypeId) c.LLVMTypeRef {
        const info = self.e.ir_mod.types.get(ty);
        return switch (info) {
            .signed => |w| switch (w) {
                1 => self.e.cached_i1,
                8 => self.e.cached_i8,
                16 => self.e.cached_i16,
                32 => self.e.cached_i32,
                64 => self.e.cached_i64,
                else => c.LLVMIntTypeInContext(self.e.context, w),
            },
            .unsigned => |w| switch (w) {
                1 => self.e.cached_i1,
                8 => self.e.cached_i8,
                16 => self.e.cached_i16,
                32 => self.e.cached_i32,
                64 => self.e.cached_i64,
                else => c.LLVMIntTypeInContext(self.e.context, w),
            },
            .f32 => self.e.cached_f32,
            .f64 => self.e.cached_f64,
            .void => self.e.cached_void,
            .bool => self.e.cached_i1,
            .error_set => self.e.cached_i32, // u32 tag id on the error channel
            .string => self.e.getStringStructType(),
            .cstring => self.e.cached_ptr,
            .pointer, .many_pointer, .function => self.e.cached_ptr,
            .closure => self.e.getClosureStructType(),
            .slice => self.e.getStringStructType(), // same {ptr, i64} layout
            .optional => |opt| {
                // ?*T / ?fn → bare pointer (null = none)
                const child_info = self.e.ir_mod.types.get(opt.child);
                if (child_info == .pointer or child_info == .many_pointer or child_info == .function or child_info == .cstring) {
                    return self.e.cached_ptr;
                }
                if (child_info == .closure) {
                    return self.e.getClosureStructType();
                }
                // ?Protocol → protocol struct (ctx ptr = field 0 is null when none).
                if (child_info == .@"struct" and child_info.@"struct".is_protocol) {
                    return self.toLLVMType(opt.child);
                }
                // ?T → { T, i1 }
                var field_types: [2]c.LLVMTypeRef = .{
                    self.fieldLLVMType(opt.child),
                    self.e.cached_i1,
                };
                return c.LLVMStructTypeInContext(self.e.context, &field_types, 2, 0);
            },
            .array => |arr| {
                const elem = self.toLLVMType(arr.element);
                return c.LLVMArrayType2(elem, arr.length);
            },
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
            .@"enum" => |e| {
                // Use backing type if declared (e.g. enum u32 → i32), else i64
                if (e.backing_type) |bt| return self.toLLVMType(bt);
                return self.e.cached_i64;
            },
            .@"union" => |u| {
                // Untagged union — just [N x i8]
                var max_size: usize = 0;
                for (u.fields) |field| {
                    const sz = self.e.ir_mod.types.typeSizeBytes(field.ty);
                    if (sz > max_size) max_size = sz;
                }
                if (max_size == 0) max_size = 8;
                return c.LLVMArrayType2(self.e.cached_i8, @intCast(max_size));
            },
            .tagged_union => |u| {
                // Tagged union — { header, [N x i8] }
                var max_size: usize = 0;
                for (u.fields) |field| {
                    const sz = self.e.ir_mod.types.typeSizeBytes(field.ty);
                    if (sz > max_size) max_size = sz;
                }
                if (max_size == 0) max_size = 8;

                var header_size: usize = self.e.ir_mod.types.typeSizeBytes(u.tag_type);
                if (u.backing_type) |bt| {
                    const bi = self.e.ir_mod.types.get(bt);
                    if (bi == .@"struct" and bi.@"struct".fields.len > 1) {
                        header_size = 0;
                        const fields = bi.@"struct".fields;
                        for (fields[0 .. fields.len - 1]) |f| {
                            header_size += self.e.ir_mod.types.typeSizeBytes(f.ty);
                        }
                        const backing_payload = self.e.ir_mod.types.typeSizeBytes(fields[fields.len - 1].ty);
                        if (backing_payload > max_size) max_size = backing_payload;
                    }
                }

                const header_llvm = c.LLVMIntTypeInContext(self.e.context, @intCast(header_size * 8));
                var field_types: [2]c.LLVMTypeRef = .{
                    header_llvm,
                    c.LLVMArrayType2(self.e.cached_i8, @intCast(max_size)),
                };
                return c.LLVMStructTypeInContext(self.e.context, &field_types, 2, 0);
            },
            .tuple => |t| {
                const n: c_uint = @intCast(t.fields.len);
                const field_llvm_types = self.e.alloc.alloc(c.LLVMTypeRef, t.fields.len) catch unreachable;
                defer self.e.alloc.free(field_llvm_types);
                for (t.fields, 0..) |f, j| {
                    field_llvm_types[j] = self.fieldLLVMType(f);
                }
                return c.LLVMStructTypeInContext(self.e.context, field_llvm_types.ptr, n, 0);
            },
            .protocol => {
                // Protocol values: { ctx: *void, vtable_or_fn_ptrs... }
                // For now, use opaque ptr
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
