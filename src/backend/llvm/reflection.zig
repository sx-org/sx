const std = @import("std");
const llvm = @import("../../llvm_api.zig");
const c = llvm.c;
const errors = @import("../../errors.zig");
const emit = @import("../../ir/emit_llvm.zig");
const ir_inst = @import("../../ir/inst.zig");
const ir_types = @import("../../ir/types.zig");

const LLVMEmitter = emit.LLVMEmitter;
const Inst = ir_inst.Inst;
const TypeId = ir_types.TypeId;
const StringId = ir_types.StringId;

/// Reflection metadata + trace-frame emission. A backend `*LLVMEmitter`
/// facade (field `e`):
/// the type/tag reflection NAME-ARRAY builders (memoized into
/// `type_name_array`/`tag_name_array` on `LLVMEmitter`) and
/// the error-trace `Frame` builders. Reads cached LLVM handles / the IR type
/// table / the module via `self.e.*`; the memoizing composite getters
/// (`getStringStructType`/`getFrameStructType`) + `emitFieldValueGet` stay on
/// `LLVMEmitter`. Entry points are reached via `self.reflection()`.
pub const Reflection = struct {
    e: *LLVMEmitter,

    /// Lazy global `[N x string]` indexed by `TypeId.index()`, holding each
    /// type's display name. Built on the first dynamic `type_name(t)` call site.
    pub fn getOrBuildTypeNameArray(self: Reflection) c.LLVMValueRef {
        if (self.e.type_name_array) |g| return g;

        const n: u32 = @intCast(self.e.ir_mod.types.infos.items.len);
        const string_ty = self.e.getStringStructType();

        var field_vals = std.ArrayList(c.LLVMValueRef).empty;
        defer field_vals.deinit(self.e.alloc);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const tid = TypeId.fromIndex(i);
            const name_str = self.e.ir_mod.types.formatTypeName(self.e.alloc, tid);
            const str_z = self.e.alloc.dupeZ(u8, name_str) catch unreachable;
            defer self.e.alloc.free(str_z);
            const global_str = c.LLVMAddGlobal(self.e.llvm_module, c.LLVMArrayType(self.e.cached_i8, @intCast(name_str.len + 1)), "tn.str");
            c.LLVMSetInitializer(global_str, c.LLVMConstStringInContext(self.e.context, str_z.ptr, @intCast(name_str.len + 1), 1));
            c.LLVMSetGlobalConstant(global_str, 1);
            c.LLVMSetLinkage(global_str, c.LLVMPrivateLinkage);
            const len_val = c.LLVMConstInt(self.e.cached_i64, name_str.len, 0);
            var struct_fields = [2]c.LLVMValueRef{ global_str, len_val };
            const const_struct = c.LLVMConstStructInContext(self.e.context, &struct_fields, 2, 0);
            field_vals.append(self.e.alloc, const_struct) catch unreachable;
        }

        const arr_ty = c.LLVMArrayType(string_ty, n);
        const arr_init = c.LLVMConstArray(string_ty, field_vals.items.ptr, n);
        const global = c.LLVMAddGlobal(self.e.llvm_module, arr_ty, "__sx_type_names");
        c.LLVMSetInitializer(global, arr_init);
        c.LLVMSetGlobalConstant(global, 1);
        c.LLVMSetLinkage(global, c.LLVMPrivateLinkage);

        self.e.type_name_array = global;
        self.e.type_name_array_len = n;
        return global;
    }

    /// Lazy global `[N x i1]` indexed by `TypeId.index()`: 1 where the type is
    /// an unsigned integer. Built on the first dynamic `type_is_unsigned(t)`
    /// call site; the runtime arm GEPs in at the boxed TypeId and loads the bit.
    /// Derives every entry from `TypeTable.isUnsignedInt` — the single
    /// signedness source-of-truth, so no per-index magic lives in the emitter.
    pub fn getOrBuildTypeIsUnsignedArray(self: Reflection) c.LLVMValueRef {
        if (self.e.type_is_unsigned_array) |g| return g;

        const n: u32 = @intCast(self.e.ir_mod.types.infos.items.len);
        var field_vals = std.ArrayList(c.LLVMValueRef).empty;
        defer field_vals.deinit(self.e.alloc);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const tid = TypeId.fromIndex(i);
            const bit: u64 = if (self.e.ir_mod.types.isUnsignedInt(tid)) 1 else 0;
            field_vals.append(self.e.alloc, c.LLVMConstInt(self.e.cached_i1, bit, 0)) catch unreachable;
        }

        const arr_ty = c.LLVMArrayType(self.e.cached_i1, n);
        const arr_init = c.LLVMConstArray(self.e.cached_i1, field_vals.items.ptr, n);
        const global = c.LLVMAddGlobal(self.e.llvm_module, arr_ty, "__sx_type_is_unsigned");
        c.LLVMSetInitializer(global, arr_init);
        c.LLVMSetGlobalConstant(global, 1);
        c.LLVMSetLinkage(global, c.LLVMPrivateLinkage);

        self.e.type_is_unsigned_array = global;
        self.e.type_is_unsigned_array_len = n;
        return global;
    }

    /// The per-builtin runtime scalar tables — lazy `[N x i64]` (or
    /// `[N x i1]` for flags), tag-indexed, one row per TypeId in table order.
    /// Values come from the SAME type-table queries the comptime folds use,
    /// so the static and dynamic answers can never diverge.
    pub const ScalarTableKind = enum { size, alignment, flags, lanes, member_count, tag_width, slice_len_info, optional_flag };

    pub fn getOrBuildScalarTable(self: Reflection, kind: ScalarTableKind) c.LLVMValueRef {
        const slot: *?c.LLVMValueRef, const len_slot: *u32 = switch (kind) {
            .size => .{ &self.e.type_size_array, &self.e.type_size_array_len },
            .alignment => .{ &self.e.type_align_array, &self.e.type_align_array_len },
            .flags => .{ &self.e.is_flags_array, &self.e.is_flags_array_len },
            .lanes => .{ &self.e.vector_lanes_array, &self.e.vector_lanes_array_len },
            .member_count => .{ &self.e.member_count_array, &self.e.member_count_array_len },
            .tag_width => .{ &self.e.variant_tag_width_array, &self.e.variant_tag_width_array_len },
            .slice_len_info => .{ &self.e.slice_len_info_array, &self.e.slice_len_info_array_len },
            .optional_flag => .{ &self.e.optional_flag_array, &self.e.optional_flag_array_len },
        };
        if (slot.*) |g| return g;

        const tt = &self.e.ir_mod.types;
        const n: u32 = @intCast(tt.infos.items.len);
        const elem_ty = if (kind == .flags) self.e.cached_i1 else self.e.cached_i64;
        var vals = std.ArrayList(c.LLVMValueRef).empty;
        defer vals.deinit(self.e.alloc);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const tid = TypeId.fromIndex(i);
            const v: u64 = switch (kind) {
                .size => @intCast(tt.typeSizeBytes(tid)),
                .alignment => @intCast(tt.typeAlignBytes(tid)),
                .flags => blk: {
                    if (!tid.isBuiltin()) {
                        const info = tt.get(tid);
                        if (info == .@"enum") break :blk @intFromBool(info.@"enum".is_flags);
                    }
                    break :blk 0;
                },
                .lanes => blk: {
                    if (!tid.isBuiltin()) {
                        const info = tt.get(tid);
                        if (info == .vector) break :blk @intCast(info.vector.length);
                    }
                    break :blk 0;
                },
                .member_count => @intCast(tt.memberCount(tid) orelse 0),
                // Sign-encoded (negative = sign-extend); the i64 bit pattern.
                .tag_width => @bitCast(tt.variantTagWidth(tid)),
                .slice_len_info => @bitCast(tt.sliceLenInfo(tid)),
                .optional_flag => @bitCast(tt.optionalFlagOffset(tid)),
            };
            vals.append(self.e.alloc, c.LLVMConstInt(elem_ty, v, 0)) catch unreachable;
        }

        const arr_ty = c.LLVMArrayType(elem_ty, n);
        const arr_init = c.LLVMConstArray(elem_ty, vals.items.ptr, n);
        const gname = switch (kind) {
            .size => "__sx_type_sizes",
            .alignment => "__sx_type_aligns",
            .flags => "__sx_type_flag_bits",
            .lanes => "__sx_vector_lanes",
            .member_count => "__sx_member_counts",
            .tag_width => "__sx_variant_tag_widths",
            .slice_len_info => "__sx_slice_len_infos",
            .optional_flag => "__sx_optional_flags",
        };
        const global = c.LLVMAddGlobal(self.e.llvm_module, arr_ty, gname);
        c.LLVMSetInitializer(global, arr_init);
        c.LLVMSetGlobalConstant(global, 1);
        c.LLVMSetLinkage(global, c.LLVMPrivateLinkage);

        slot.* = global;
        len_slot.* = n;
        return global;
    }

    /// Member-view master-index tables: `[N x ptr]` keyed by TypeId, each slot
    /// the per-type member array (member-type tags / field offsets), or null
    /// for memberless types. Values from the same TypeTable queries the
    /// comptime folds use. Per-type arrays are built eagerly when the master
    /// is first demanded (the master itself is lazy).
    pub const MemberTableKind = enum { types, offsets };

    pub fn getOrBuildMemberPtrs(self: Reflection, kind: MemberTableKind) c.LLVMValueRef {
        const slot: *?c.LLVMValueRef, const len_slot: *u32 = switch (kind) {
            .types => .{ &self.e.member_type_ptrs, &self.e.member_type_ptrs_len },
            .offsets => .{ &self.e.field_offset_ptrs, &self.e.field_offset_ptrs_len },
        };
        if (slot.*) |g| return g;

        const tt = &self.e.ir_mod.types;
        const n: u32 = @intCast(tt.infos.items.len);
        var ptrs = std.ArrayList(c.LLVMValueRef).empty;
        defer ptrs.deinit(self.e.alloc);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const tid = TypeId.fromIndex(i);
            const count = tt.memberTableLen(tid) orelse 0;
            if (count <= 0) {
                ptrs.append(self.e.alloc, c.LLVMConstNull(self.e.cached_ptr)) catch unreachable;
                continue;
            }
            const per_type: c.LLVMValueRef = switch (kind) {
                .types => blk: {
                    var vals = std.ArrayList(c.LLVMValueRef).empty;
                    defer vals.deinit(self.e.alloc);
                    var m: i64 = 0;
                    while (m < count) : (m += 1) {
                        const mt = tt.memberType(tid, m) orelse .void;
                        vals.append(self.e.alloc, c.LLVMConstInt(self.e.cached_i64, @intCast(mt.index()), 0)) catch unreachable;
                    }
                    break :blk self.makeI64Array(vals.items, "__sx_member_types");
                },
                .offsets => blk: {
                    // Member offsets from the single source of truth
                    // (`memberOffsetBytes`): struct/tuple field offsets,
                    // tagged-union PAYLOAD offset (same for every variant),
                    // untagged-union arms at 0. Kinds without addressable
                    // members table 0.
                    var vals = std.ArrayList(c.LLVMValueRef).empty;
                    defer vals.deinit(self.e.alloc);
                    var m: i64 = 0;
                    while (m < count) : (m += 1) {
                        const v: u64 = @intCast(tt.memberOffsetBytes(tid, m) orelse 0);
                        vals.append(self.e.alloc, c.LLVMConstInt(self.e.cached_i64, v, 0)) catch unreachable;
                    }
                    break :blk self.makeI64Array(vals.items, "__sx_field_offsets");
                },
            };
            ptrs.append(self.e.alloc, per_type) catch unreachable;
        }

        const arr_ty = c.LLVMArrayType(self.e.cached_ptr, n);
        const arr_init = c.LLVMConstArray(self.e.cached_ptr, ptrs.items.ptr, n);
        const gname = switch (kind) {
            .types => "__sx_member_type_ptrs",
            .offsets => "__sx_field_offset_ptrs",
        };
        const global = c.LLVMAddGlobal(self.e.llvm_module, arr_ty, gname);
        c.LLVMSetInitializer(global, arr_init);
        c.LLVMSetGlobalConstant(global, 1);
        c.LLVMSetLinkage(global, c.LLVMPrivateLinkage);
        slot.* = global;
        len_slot.* = n;
        return global;
    }

    // ── Runtime `@typeInfo(tp)` const records ────────────────
    //
    // One constant per TypeId whose BYTES match the sx `TypeInfo` tagged
    // union (tag word at 0, payload at tag_size — buildTypeInfo's layout
    // convention), reached through a master `[N x ptr]`. Each record is its
    // own global typed per its kind's payload shape (padding arrays place
    // members at exact offsets); the runtime arm loads the record THROUGH
    // the opaque pointer as the sx TypeInfo LLVM type — valid because the
    // bytes match. Kinds are classified BY NAME against the prelude's
    // TypeInfo declaration, mirroring the comptime VM's buildTypeInfo, so
    // the two sources cannot disagree on variant numbering.

    const Placed = struct { off: usize, val: c.LLVMValueRef, size: usize };

    /// Pack `placed` (sorted by off) into a packed-struct constant of
    /// exactly `total` bytes, zero-padding the gaps.
    fn packRecord(self: Reflection, placed: []const Placed, total: usize) c.LLVMValueRef {
        var members = std.ArrayList(c.LLVMValueRef).empty;
        defer members.deinit(self.e.alloc);
        var at: usize = 0;
        for (placed) |p| {
            if (p.off > at) {
                const pad_ty = c.LLVMArrayType(self.e.cached_i8, @intCast(p.off - at));
                members.append(self.e.alloc, c.LLVMConstNull(pad_ty)) catch unreachable;
                at = p.off;
            }
            members.append(self.e.alloc, p.val) catch unreachable;
            at += p.size;
        }
        if (total > at) {
            const pad_ty = c.LLVMArrayType(self.e.cached_i8, @intCast(total - at));
            members.append(self.e.alloc, c.LLVMConstNull(pad_ty)) catch unreachable;
        }
        return c.LLVMConstStructInContext(self.e.context, members.items.ptr, @intCast(members.items.len), 1);
    }

    fn constGlobal(self: Reflection, val: c.LLVMValueRef, name: [*:0]const u8) c.LLVMValueRef {
        const g = c.LLVMAddGlobal(self.e.llvm_module, c.LLVMTypeOf(val), name);
        c.LLVMSetInitializer(g, val);
        c.LLVMSetGlobalConstant(g, 1);
        c.LLVMSetLinkage(g, c.LLVMPrivateLinkage);
        return g;
    }

    fn constStr(self: Reflection, text: []const u8) [2]c.LLVMValueRef {
        const z = self.e.alloc.dupeZ(u8, text) catch unreachable;
        defer self.e.alloc.free(z);
        const g = c.LLVMAddGlobal(self.e.llvm_module, c.LLVMArrayType(self.e.cached_i8, @intCast(text.len + 1)), "ti.str");
        c.LLVMSetInitializer(g, c.LLVMConstStringInContext(self.e.context, z.ptr, @intCast(text.len + 1), 1));
        c.LLVMSetGlobalConstant(g, 1);
        c.LLVMSetLinkage(g, c.LLVMPrivateLinkage);
        return .{ g, c.LLVMConstInt(self.e.cached_i64, text.len, 0) };
    }

    /// Field offsets within an sx struct type — the same aligned walk
    /// typeSizeBytes uses (mirrors comptime_vm.fieldOffset).
    fn sxFieldOffset(tt: anytype, sty: TypeId, idx: usize) usize {
        const fields = tt.get(sty).@"struct".fields;
        var off: usize = 0;
        for (fields, 0..) |f, i| {
            off = std.mem.alignForward(usize, off, tt.typeAlignBytes(f.ty));
            if (i == idx) return off;
            off += tt.typeSizeBytes(f.ty);
        }
        return off;
    }

    pub fn getOrBuildTypeInfoRecords(self: Reflection, ti_ty: TypeId) c.LLVMValueRef {
        if (self.e.type_info_records) |g| return g;
        const tt = &self.e.ir_mod.types;
        const ti = tt.get(ti_ty).tagged_union;
        const tag_size: usize = tt.typeSizeBytes(ti.tag_type);
        const rec_size: usize = tt.typeSizeBytes(ti_ty);
        const n: u32 = @intCast(tt.infos.items.len);

        // variant name -> ordinal, from the MODULE's TypeInfo declaration.
        var ordinals = std.StringHashMap(u32).init(self.e.alloc);
        defer ordinals.deinit();
        for (ti.fields, 0..) |f, i| ordinals.put(tt.getString(f.name), @intCast(i)) catch unreachable;

        var recs = std.ArrayList(c.LLVMValueRef).empty;
        defer recs.deinit(self.e.alloc);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const tid = TypeId.fromIndex(i);
            recs.append(self.e.alloc, self.buildOneRecord(tt, ti, tag_size, rec_size, &ordinals, tid)) catch unreachable;
        }
        const arr_ty = c.LLVMArrayType(self.e.cached_ptr, n);
        const arr_init = c.LLVMConstArray(self.e.cached_ptr, recs.items.ptr, n);
        const master = c.LLVMAddGlobal(self.e.llvm_module, arr_ty, "__sx_type_infos");
        c.LLVMSetInitializer(master, arr_init);
        c.LLVMSetGlobalConstant(master, 1);
        c.LLVMSetLinkage(master, c.LLVMPrivateLinkage);
        self.e.type_info_records = master;
        self.e.type_info_records_len = n;
        return master;
    }

    fn tyWord(self: Reflection, t: TypeId) c.LLVMValueRef {
        return c.LLVMConstInt(self.e.cached_i64, @intCast(t.index()), 0);
    }

    fn buildOneRecord(self: Reflection, tt: anytype, ti: anytype, tag_size: usize, rec_size: usize, ordinals: *const std.StringHashMap(u32), tid: TypeId) c.LLVMValueRef {
        var placed = std.ArrayList(Placed).empty;
        defer placed.deinit(self.e.alloc);
        const P = tag_size; // payload base offset

        var vname: []const u8 = "typeValue";
        if (tid.isBuiltin()) {
            switch (tid) {
                .bool => vname = "bool",
                .void => vname = "void",
                .string => vname = "string",
                .cstring => vname = "cstring",
                .any => vname = "any",
                .noreturn => vname = "noreturn",
                .type_value, .unresolved => vname = "typeValue",
                .usize, .isize => {
                    vname = "int";
                    placed.append(self.e.alloc, .{ .off = P, .val = c.LLVMConstInt(self.e.cached_i64, @intCast(tt.typeSizeBytes(tid) * 8), 0), .size = 8 }) catch unreachable;
                    placed.append(self.e.alloc, .{ .off = P + 8, .val = c.LLVMConstInt(self.e.cached_i8, @intFromBool(tid == .isize), 0), .size = 1 }) catch unreachable;
                },
                .f32, .f64 => {
                    vname = "float";
                    const bits: u64 = if (tid == .f32) 32 else 64;
                    placed.append(self.e.alloc, .{ .off = P, .val = c.LLVMConstInt(self.e.cached_i64, bits, 0), .size = 8 }) catch unreachable;
                },
                else => {
                    vname = "int";
                    placed.append(self.e.alloc, .{ .off = P, .val = c.LLVMConstInt(self.e.cached_i64, @intCast(tt.typeSizeBytes(tid) * 8), 0), .size = 8 }) catch unreachable;
                    placed.append(self.e.alloc, .{ .off = P + 8, .val = c.LLVMConstInt(self.e.cached_i8, @intFromBool(!tt.isUnsignedInt(tid)), 0), .size = 1 }) catch unreachable;
                },
            }
        } else switch (tt.get(tid)) {
            .signed => |w| {
                vname = "int";
                placed.append(self.e.alloc, .{ .off = P, .val = c.LLVMConstInt(self.e.cached_i64, w, 0), .size = 8 }) catch unreachable;
                placed.append(self.e.alloc, .{ .off = P + 8, .val = c.LLVMConstInt(self.e.cached_i8, 1, 0), .size = 1 }) catch unreachable;
            },
            .unsigned => |w| {
                vname = "int";
                placed.append(self.e.alloc, .{ .off = P, .val = c.LLVMConstInt(self.e.cached_i64, w, 0), .size = 8 }) catch unreachable;
                placed.append(self.e.alloc, .{ .off = P + 8, .val = c.LLVMConstInt(self.e.cached_i8, 0, 0), .size = 1 }) catch unreachable;
            },
            .f32 => {
                vname = "float";
                placed.append(self.e.alloc, .{ .off = P, .val = c.LLVMConstInt(self.e.cached_i64, 32, 0), .size = 8 }) catch unreachable;
            },
            .f64 => {
                vname = "float";
                placed.append(self.e.alloc, .{ .off = P, .val = c.LLVMConstInt(self.e.cached_i64, 64, 0), .size = 8 }) catch unreachable;
            },
            .bool => vname = "bool",
            .void => vname = "void",
            .string => vname = "string",
            .cstring => vname = "cstring",
            .any => vname = "any",
            .noreturn => vname = "noreturn",
            .type_value, .unresolved => vname = "typeValue",
            .usize, .isize => {
                vname = "int";
                placed.append(self.e.alloc, .{ .off = P, .val = c.LLVMConstInt(self.e.cached_i64, @intCast(tt.typeSizeBytes(tid) * 8), 0), .size = 8 }) catch unreachable;
                placed.append(self.e.alloc, .{ .off = P + 8, .val = c.LLVMConstInt(self.e.cached_i8, @intFromBool(tt.get(tid) == .isize), 0), .size = 1 }) catch unreachable;
            },
            .function => vname = "function",
            .closure => vname = "closure",
            .protocol => vname = "protocol",
            .pack => vname = "pack",
            .@"error" => |e| {
                vname = "error";
                const arr = self.memberElems(tt, ti, "error", tid, e.tags.len);
                placed.append(self.e.alloc, .{ .off = P, .val = arr, .size = 8 }) catch unreachable;
                placed.append(self.e.alloc, .{ .off = P + 8, .val = c.LLVMConstInt(self.e.cached_i64, @intCast(e.tags.len), 0), .size = 8 }) catch unreachable;
            },
            .array => |a| {
                vname = "array";
                placed.append(self.e.alloc, .{ .off = P, .val = self.tyWord(a.element), .size = 8 }) catch unreachable;
                placed.append(self.e.alloc, .{ .off = P + 8, .val = c.LLVMConstInt(self.e.cached_i64, @intCast(a.length), 0), .size = 8 }) catch unreachable;
            },
            .vector => |v| {
                vname = "vector";
                placed.append(self.e.alloc, .{ .off = P, .val = self.tyWord(v.element), .size = 8 }) catch unreachable;
                placed.append(self.e.alloc, .{ .off = P + 8, .val = c.LLVMConstInt(self.e.cached_i64, @intCast(v.length), 0), .size = 8 }) catch unreachable;
            },
            .slice => |sl| {
                vname = "slice";
                placed.append(self.e.alloc, .{ .off = P, .val = self.tyWord(sl.element), .size = 8 }) catch unreachable;
            },
            .pointer => |p| {
                vname = "pointer";
                placed.append(self.e.alloc, .{ .off = P, .val = self.tyWord(p.pointee), .size = 8 }) catch unreachable;
            },
            .many_pointer => |mp| {
                vname = "manyPointer";
                placed.append(self.e.alloc, .{ .off = P, .val = self.tyWord(mp.element), .size = 8 }) catch unreachable;
            },
            .optional => |o| {
                vname = "optional";
                placed.append(self.e.alloc, .{ .off = P, .val = self.tyWord(o.child), .size = 8 }) catch unreachable;
            },
            .failable => vname = "void",
            .@"enum" => |e| {
                const members = tt.reflectedErrorMembers(tid);
                const count = if (members) |m| m.len else e.variants.len;
                vname = if (members != null) "error" else "enum";
                const arr = self.memberElems(tt, ti, vname, tid, count);
                placed.append(self.e.alloc, .{ .off = P, .val = arr, .size = 8 }) catch unreachable;
                placed.append(self.e.alloc, .{ .off = P + 8, .val = c.LLVMConstInt(self.e.cached_i64, @intCast(count), 0), .size = 8 }) catch unreachable;
            },
            .tagged_union => |u| {
                vname = "enum";
                const arr = self.memberElems(tt, ti, "enum", tid, u.fields.len);
                placed.append(self.e.alloc, .{ .off = P, .val = arr, .size = 8 }) catch unreachable;
                placed.append(self.e.alloc, .{ .off = P + 8, .val = c.LLVMConstInt(self.e.cached_i64, @intCast(u.fields.len), 0), .size = 8 }) catch unreachable;
            },
            .@"struct" => |st| {
                vname = "struct";
                const arr = self.memberElems(tt, ti, "struct", tid, st.fields.len);
                placed.append(self.e.alloc, .{ .off = P, .val = arr, .size = 8 }) catch unreachable;
                placed.append(self.e.alloc, .{ .off = P + 8, .val = c.LLVMConstInt(self.e.cached_i64, @intCast(st.fields.len), 0), .size = 8 }) catch unreachable;
            },
            .@"union" => |u| {
                vname = "union";
                const arr = self.memberElems(tt, ti, "union", tid, u.fields.len);
                placed.append(self.e.alloc, .{ .off = P, .val = arr, .size = 8 }) catch unreachable;
                placed.append(self.e.alloc, .{ .off = P + 8, .val = c.LLVMConstInt(self.e.cached_i64, @intCast(u.fields.len), 0), .size = 8 }) catch unreachable;
            },
        }

        const ord = ordinals.get(vname) orelse 0;
        var all = std.ArrayList(Placed).empty;
        defer all.deinit(self.e.alloc);
        const tag_llvm_bits: c_uint = @intCast(tag_size * 8);
        const tag_ty = c.LLVMIntTypeInContext(self.e.context, tag_llvm_bits);
        all.append(self.e.alloc, .{ .off = 0, .val = c.LLVMConstInt(tag_ty, ord, 0), .size = tag_size }) catch unreachable;
        for (placed.items) |p| all.append(self.e.alloc, p) catch unreachable;
        const rec = self.packRecord(all.items, rec_size);
        return self.constGlobal(rec, "ti.rec");
    }

    /// One word of a member element, tagged by how it is written. A `text`
    /// occupies the element's two string words.
    const Word = union(enum) { text: []const u8, ty: TypeId, num: i64 };

    /// Per-member element array for an enum/struct/union/error payload slice.
    /// A row fills the element struct's fields in declaration order, and the
    /// element layout is read from the prelude's declaration via the sx offset
    /// walk, so the emitter and the declaration cannot drift.
    fn memberElems(self: Reflection, tt: anytype, ti: anytype, family: []const u8, tid: TypeId, count: usize) c.LLVMValueRef {
        // Find the payload struct + its slice elem type from the TypeInfo decl.
        var elem_sx: TypeId = .void;
        for (ti.fields) |f| {
            if (!std.mem.eql(u8, tt.getString(f.name), family)) continue;
            const pay = tt.get(f.ty).@"struct";
            elem_sx = tt.get(pay.fields[0].ty).slice.element;
            break;
        }
        const esize = tt.typeSizeBytes(elem_sx);
        const is_error = std.mem.eql(u8, family, "error");
        const err_tags: []const u32 = if (is_error) tt.reflectedErrorMembers(tid).? else &.{};

        var elems = std.ArrayList(c.LLVMValueRef).empty;
        defer elems.deinit(self.e.alloc);
        var m: usize = 0;
        while (m < count) : (m += 1) {
            var buf: [4]Word = undefined;
            const row: []const Word = if (is_error) blk: {
                const member = err_tags[m];
                buf[0] = .{ .num = @intCast(member) };
                buf[1] = .{ .ty = tt.memberOwnerType(member) };
                buf[2] = .{ .text = tt.getTagName(member) };
                buf[3] = .{ .ty = tt.memberPayload(member) };
                break :blk buf[0..4];
            } else blk: {
                buf[0] = .{ .text = tt.getString(tt.memberName(tid, @intCast(m)) orelse StringId.empty) };
                buf[1] = .{ .ty = tt.memberType(tid, @intCast(m)) orelse TypeId.void };
                if (std.mem.eql(u8, family, "union")) break :blk buf[0..2];
                if (std.mem.eql(u8, family, "struct")) {
                    buf[2] = .{ .num = @intCast(tt.memberOffsetBytes(tid, @intCast(m)) orelse 0) };
                    buf[3] = .{ .num = @intCast(m) };
                    break :blk buf[0..4];
                }
                buf[2] = .{ .num = tt.memberValue(tid, @intCast(m)) orelse @intCast(m) };
                break :blk buf[0..3];
            };

            var pl = std.ArrayList(Placed).empty;
            defer pl.deinit(self.e.alloc);
            for (row, 0..) |word, f| {
                const off = sxFieldOffset(tt, elem_sx, f);
                switch (word) {
                    .text => |t| {
                        const sc = self.constStr(t);
                        pl.append(self.e.alloc, .{ .off = off, .val = sc[0], .size = 8 }) catch unreachable;
                        pl.append(self.e.alloc, .{ .off = off + 8, .val = sc[1], .size = 8 }) catch unreachable;
                    },
                    .ty => |t| pl.append(self.e.alloc, .{ .off = off, .val = self.tyWord(t), .size = 8 }) catch unreachable,
                    .num => |n| pl.append(self.e.alloc, .{ .off = off, .val = c.LLVMConstInt(self.e.cached_i64, @bitCast(n), 0), .size = 8 }) catch unreachable,
                }
            }
            elems.append(self.e.alloc, self.packRecord(pl.items, esize)) catch unreachable;
        }
        // Uniform packed-struct elems -> array global.
        const ety = if (elems.items.len > 0) c.LLVMTypeOf(elems.items[0]) else self.e.cached_i8;
        const arr_init = c.LLVMConstArray(ety, elems.items.ptr, @intCast(elems.items.len));
        return self.constGlobal(arr_init, "ti.members");
    }

    fn makeI64Array(self: Reflection, vals: []c.LLVMValueRef, name: [*:0]const u8) c.LLVMValueRef {
        const arr_ty = c.LLVMArrayType(self.e.cached_i64, @intCast(vals.len));
        const arr_init = c.LLVMConstArray(self.e.cached_i64, vals.ptr, @intCast(vals.len));
        const g = c.LLVMAddGlobal(self.e.llvm_module, arr_ty, name);
        c.LLVMSetInitializer(g, arr_init);
        c.LLVMSetGlobalConstant(g, 1);
        c.LLVMSetLinkage(g, c.LLVMPrivateLinkage);
        return g;
    }

    /// The always-linked member-name table: a `[N x {ptr, i64}]` global of
    /// member names indexed by member id (the `TagRegistry` namespace; slot 0
    /// is the reserved "" no-error name). `error_member_name_get` GEPs into it at
    /// the runtime member id. Built once per module. Always emitted (not trace-gated)
    /// so `{}` interpolation of an error tag works even in release builds.
    pub fn getOrBuildTagNameArray(self: Reflection) c.LLVMValueRef {
        if (self.e.tag_name_array) |g| return g;

        const string_ty = self.e.getStringStructType();
        const names = self.e.ir_mod.types.tags.names.items;

        var field_vals = std.ArrayList(c.LLVMValueRef).empty;
        defer field_vals.deinit(self.e.alloc);
        for (names) |name_str| {
            const str_z = self.e.alloc.dupeZ(u8, name_str) catch unreachable;
            defer self.e.alloc.free(str_z);
            const global_str = c.LLVMAddGlobal(self.e.llvm_module, c.LLVMArrayType(self.e.cached_i8, @intCast(name_str.len + 1)), "tag.str");
            c.LLVMSetInitializer(global_str, c.LLVMConstStringInContext(self.e.context, str_z.ptr, @intCast(name_str.len + 1), 1));
            c.LLVMSetGlobalConstant(global_str, 1);
            c.LLVMSetLinkage(global_str, c.LLVMPrivateLinkage);
            const len_val = c.LLVMConstInt(self.e.cached_i64, name_str.len, 0);
            var struct_fields = [2]c.LLVMValueRef{ global_str, len_val };
            const const_struct = c.LLVMConstStructInContext(self.e.context, &struct_fields, 2, 0);
            field_vals.append(self.e.alloc, const_struct) catch unreachable;
        }

        const n: u32 = @intCast(names.len);
        const array_ty = c.LLVMArrayType(string_ty, n);
        const array_init = c.LLVMConstArray(string_ty, field_vals.items.ptr, n);
        const global = c.LLVMAddGlobal(self.e.llvm_module, array_ty, "tag_names");
        c.LLVMSetInitializer(global, array_init);
        c.LLVMSetGlobalConstant(global, 1);
        c.LLVMSetLinkage(global, c.LLVMPrivateLinkage);

        self.e.tag_name_array = global;
        return global;
    }

    /// The qualified-name table: a `[N x {ptr, i64}]` global of `Owner.Member`
    /// spellings indexed by member id, parallel to the member-name table.
    /// `error_name_get` GEPs into it at the runtime member id.
    pub fn getOrBuildTagQualifiedNameArray(self: Reflection) c.LLVMValueRef {
        if (self.e.tag_qualified_name_array) |g| return g;

        const string_ty = self.e.getStringStructType();
        const n: u32 = @intCast(self.e.ir_mod.types.tags.names.items.len);

        var field_vals = std.ArrayList(c.LLVMValueRef).empty;
        defer field_vals.deinit(self.e.alloc);
        var id: u32 = 0;
        while (id < n) : (id += 1) {
            const q = self.e.ir_mod.types.memberQualifiedName(self.e.alloc, id);
            defer self.e.alloc.free(q);
            field_vals.append(self.e.alloc, self.buildStringConst(q)) catch unreachable;
        }

        const array_ty = c.LLVMArrayType(string_ty, n);
        const global = c.LLVMAddGlobal(self.e.llvm_module, array_ty, "tag_qualified_names");
        c.LLVMSetInitializer(global, c.LLVMConstArray(string_ty, field_vals.items.ptr, n));
        c.LLVMSetGlobalConstant(global, 1);
        c.LLVMSetLinkage(global, c.LLVMPrivateLinkage);

        self.e.tag_qualified_name_array = global;
        return global;
    }

    /// The owner table: an `[N x i64]` global of the TypeId each member's
    /// declaring error interns to, indexed by member id. `error_owner_get`
    /// GEPs into it at the runtime member id.
    pub fn getOrBuildTagOwnerTypeArray(self: Reflection) c.LLVMValueRef {
        if (self.e.tag_owner_type_array) |g| return g;

        const n: u32 = @intCast(self.e.ir_mod.types.tags.names.items.len);
        var vals = std.ArrayList(c.LLVMValueRef).empty;
        defer vals.deinit(self.e.alloc);
        var id: u32 = 0;
        while (id < n) : (id += 1) {
            vals.append(self.e.alloc, c.LLVMConstInt(self.e.cached_i64, self.e.ir_mod.types.memberOwnerType(id).index(), 0)) catch unreachable;
        }

        const array_ty = c.LLVMArrayType(self.e.cached_i64, n);
        const global = c.LLVMAddGlobal(self.e.llvm_module, array_ty, "tag_owner_types");
        c.LLVMSetInitializer(global, c.LLVMConstArray(self.e.cached_i64, vals.items.ptr, n));
        c.LLVMSetGlobalConstant(global, 1);
        c.LLVMSetLinkage(global, c.LLVMPrivateLinkage);

        self.e.tag_owner_type_array = global;
        return global;
    }

    /// The member-payload-type table: an `[N x i64]` global of member payload
    /// TypeIds indexed by member id, parallel to the member-name table.
    /// `error_payload_view` GEPs into it at the runtime member id to type the
    /// view it hands back.
    pub fn getOrBuildTagPayloadTypeArray(self: Reflection) c.LLVMValueRef {
        if (self.e.tag_payload_type_array) |g| return g;

        const payloads = self.e.ir_mod.types.tags.payloads.items;
        var vals = std.ArrayList(c.LLVMValueRef).empty;
        defer vals.deinit(self.e.alloc);
        for (payloads) |ty| {
            vals.append(self.e.alloc, c.LLVMConstInt(self.e.cached_i64, ty.index(), 0)) catch unreachable;
        }

        const n: u32 = @intCast(payloads.len);
        const array_ty = c.LLVMArrayType(self.e.cached_i64, n);
        const global = c.LLVMAddGlobal(self.e.llvm_module, array_ty, "tag_payload_types");
        c.LLVMSetInitializer(global, c.LLVMConstArray(self.e.cached_i64, vals.items.ptr, n));
        c.LLVMSetGlobalConstant(global, 1);
        c.LLVMSetLinkage(global, c.LLVMPrivateLinkage);

        self.e.tag_payload_type_array = global;
        return global;
    }

    /// An interned constant sx `string` (`{ ptr, i64 }`) of the cached string
    /// struct type, backed by a private NUL-terminated data global. Cached by
    /// content so a path/name shared by many push sites is emitted once.
    fn buildStringConst(self: Reflection, s: []const u8) c.LLVMValueRef {
        if (self.e.frame_str_cache.get(s)) |v| return v;
        const str_z = self.e.alloc.dupeZ(u8, s) catch unreachable;
        defer self.e.alloc.free(str_z);
        const data = c.LLVMAddGlobal(self.e.llvm_module, c.LLVMArrayType(self.e.cached_i8, @intCast(s.len + 1)), "frame.str");
        c.LLVMSetInitializer(data, c.LLVMConstStringInContext(self.e.context, str_z.ptr, @intCast(s.len + 1), 1));
        c.LLVMSetGlobalConstant(data, 1);
        c.LLVMSetLinkage(data, c.LLVMPrivateLinkage);
        c.LLVMSetUnnamedAddress(data, c.LLVMGlobalUnnamedAddr);
        var fields = [_]c.LLVMValueRef{ data, c.LLVMConstInt(self.e.cached_i64, s.len, 0) };
        const str_const = c.LLVMConstNamedStruct(self.e.getStringStructType(), &fields, 2);
        const key = self.e.alloc.dupe(u8, s) catch return str_const;
        self.e.frame_str_cache.put(key, str_const) catch self.e.alloc.free(key);
        return str_const;
    }

    /// Build the interned `Frame` global for a `.trace_frame` push site and
    /// return its address as `i64` (the value `sx_trace_push` stores). Resolves
    /// the instruction's span + current function to `{file,line,col,func}`. The
    /// file is shown as its basename so trace output is machine-independent
    /// (the harness passes absolute paths); full paths live in DWARF.
    pub fn emitTraceFrame(self: Reflection, instruction: *const Inst) c.LLVMValueRef {
        const file = std.fs.path.basename(self.e.current_func_file);
        const src = self.e.sourceForFile(self.e.current_func_file);
        const loc = errors.SourceLoc.compute(src, instruction.span.start);
        const func_name = self.e.ir_mod.types.getString(self.e.ir_mod.functions.items[self.e.current_func_idx].name);

        var fields = [_]c.LLVMValueRef{
            self.buildStringConst(file),
            c.LLVMConstInt(self.e.cached_i32, loc.line, 0),
            c.LLVMConstInt(self.e.cached_i32, loc.col, 0),
            self.buildStringConst(func_name),
            self.buildStringConst(errors.lineAt(src, instruction.span.start)),
        };
        const frame_ty = self.e.getFrameStructType();
        const frame_const = c.LLVMConstNamedStruct(frame_ty, &fields, 5);
        const g = c.LLVMAddGlobal(self.e.llvm_module, frame_ty, "trace.frame");
        c.LLVMSetInitializer(g, frame_const);
        c.LLVMSetGlobalConstant(g, 1);
        c.LLVMSetLinkage(g, c.LLVMPrivateLinkage);
        return c.LLVMConstPtrToInt(g, self.e.cached_i64);
    }
};
