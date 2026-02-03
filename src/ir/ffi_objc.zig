const std = @import("std");
const ast = @import("../ast.zig");
const lower = @import("lower.zig");
const types = @import("types.zig");

const Lowering = lower.Lowering;
const TypeId = types.TypeId;

/// Tracks struct TypeIds currently being emitted so a struct field of
/// `*Self` (or a transitive pointee that cycles back) emits the
/// abbreviated `{Name}` form instead of recursing forever. Bounded to
/// `cap` — well above any realistic Obj-C struct nesting depth.
const ObjcEncodingStack = struct {
    const cap = 16;
    items: [cap]TypeId = undefined,
    len: u8 = 0,

    fn push(self: *ObjcEncodingStack, tid: TypeId) bool {
        if (self.len >= cap) return false;
        self.items[self.len] = tid;
        self.len += 1;
        return true;
    }

    fn pop(self: *ObjcEncodingStack) void {
        std.debug.assert(self.len > 0);
        self.len -= 1;
    }

    fn contains(self: *const ObjcEncodingStack, tid: TypeId) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.items[i] == tid) return true;
        }
        return false;
    }
};

/// `assign` is the default for primitives (direct store, no ARC ops);
/// `strong` is the default for pointer-to-object types (retain on
/// assign, release on dealloc); `weak` and `copy` are explicit. The
/// helper rejects ambiguous combinations loudly per the silent-error
/// budget — `*void` requires explicit modifier, `weak` requires an
/// object-pointer slot.
const ObjcPropertyKind = enum {
    assign,    // primitives or explicitly opted-out object slots
    strong,    // default for *<ObjC-class> — retain on assign, release on dealloc
    weak,      // objc_storeWeak / objc_loadWeakRetained — auto-nilling
    copy,      // [val copy] on assign — for immutable-wanting String/Array slots

    pub fn isObject(k: ObjcPropertyKind) bool {
        return k == .strong or k == .weak or k == .copy;
    }
};

/// Pure Obj-C decision helpers (architecture phase A6.1), extracted from
/// `Lowering`. A `*Lowering` facade (Principle 5, like `ErrorAnalysis`/
/// `CoercionResolver`): selector derivation, type-encoding-string derivation,
/// ARC property-kind classification, Obj-C class-pointer recognition, and
/// hidden-state-struct planning. No IR is emitted here — the emission-heavy IMP
/// builders / `lowerObjc*Call` dispatch stay in `Lowering` (PLAN-ARCH A6.1
/// step 6). Reads `self.l.{alloc, module, program_index, diagnostics}` and the
/// `self.l.resolveType` resolver.
pub const ObjcLowering = struct {
    l: *Lowering,

    pub fn deriveObjcSelector(self: ObjcLowering, method: ast.RuntimeMethodDecl, arity: usize) struct { sel: []const u8, keyword_count: usize, is_override: bool } {
        if (method.selector_override) |sel| {
            var colons: usize = 0;
            for (sel) |ch| {
                if (ch == ':') colons += 1;
            }
            return .{ .sel = sel, .keyword_count = colons, .is_override = true };
        }
        if (arity == 0) {
            return .{ .sel = method.name, .keyword_count = 0, .is_override = false };
        }
        // Each `_` in the sx name becomes a `:` (one-byte-for-one), plus
        // one trailing `:` regardless of how many pieces. Piece count
        // = (number of `_`) + 1.
        var pieces: usize = 1;
        for (method.name) |ch| {
            if (ch == '_') pieces += 1;
        }
        const out = self.l.alloc.alloc(u8, method.name.len + 1) catch unreachable;
        for (method.name, 0..) |ch, i| {
            out[i] = if (ch == '_') ':' else ch;
        }
        out[method.name.len] = ':';
        return .{ .sel = out, .keyword_count = pieces, .is_override = false };
    }

    /// Derive an Obj-C type-encoding string for a synthesized IMP
    /// signature (M1.2 A.1). Apple's runtime accepts these strings on
    /// `class_addMethod(cls, sel, imp, types)`; the encoding tells the
    /// runtime the IMP's argument layout for KVC, NSCoder, and reflective
    /// dispatch.
    ///
    /// Layout: `<ret> @ : <param0> <param1> ...`. The `@` slot is the
    /// receiver (self); `:` is `_cmd`. Caller passes user-declared params
    /// AFTER stripping `self`.
    ///
    /// Single-character encodings (the common case):
    ///   v=void  B=bool  c=i8/BOOL  s=i16  i=i32  q=i64
    ///   C=u8    S=u16   I=u32      Q=u64  f=f32  d=f64
    ///   @=id    #=Class :=SEL      *=C string  ^v=void* / generic ptr
    ///
    /// Runtime-class pointers (`*UIView` etc.) encode as `@` (object
    /// pointer). Other pointers fall to `^v` — the encoding is metadata,
    /// not ABI, so being conservative here is safe. Pass-by-value
    /// structs encode as `{Name=field0field1...}`; nested structs
    /// recurse with cycle-break via `ObjcEncodingStack`. Tagged-union /
    /// array / vector / function shapes BAIL loudly via diagnostics
    /// rather than silently mis-encoding (per CLAUDE.md rejected-
    /// patterns rule).
    ///
    /// Returns an allocator-owned slice; caller frees via `self.l.alloc`.
    pub fn objcTypeEncodingFromSignature(
        self: ObjcLowering,
        return_ty: TypeId,
        param_tys: []const TypeId,
        span: ?ast.Span,
    ) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.l.alloc);

        var stack: ObjcEncodingStack = .{};
        try self.appendObjcEncoding(&out, return_ty, span, &stack);
        try out.append(self.l.alloc, '@'); // self
        try out.append(self.l.alloc, ':'); // _cmd
        for (param_tys) |pty| {
            try self.appendObjcEncoding(&out, pty, span, &stack);
        }

        return try out.toOwnedSlice(self.l.alloc);
    }

    fn appendObjcEncoding(
        self: ObjcLowering,
        out: *std.ArrayList(u8),
        ty: TypeId,
        span: ?ast.Span,
        stack: *ObjcEncodingStack,
    ) !void {
        const info = self.l.module.types.get(ty);
        switch (info) {
            .void => try out.append(self.l.alloc, 'v'),
            .bool => try out.append(self.l.alloc, 'B'),
            .signed => |bits| {
                const ch: u8 = switch (bits) {
                    8 => 'c',
                    16 => 's',
                    32 => 'i',
                    64 => 'q',
                    else => return self.bailObjcEncoding(span, "signed integer with non-standard bit width", bits),
                };
                try out.append(self.l.alloc, ch);
            },
            .unsigned => |bits| {
                const ch: u8 = switch (bits) {
                    8 => 'C',
                    16 => 'S',
                    32 => 'I',
                    64 => 'Q',
                    else => return self.bailObjcEncoding(span, "unsigned integer with non-standard bit width", bits),
                };
                try out.append(self.l.alloc, ch);
            },
            .f32 => try out.append(self.l.alloc, 'f'),
            .f64 => try out.append(self.l.alloc, 'd'),
            // sx-target arm64 — pointer-sized aliases match i64/u64.
            .isize => try out.append(self.l.alloc, 'q'),
            .usize => try out.append(self.l.alloc, 'Q'),
            .pointer => |p| {
                // Pointer to a runtime Obj-C class (or sx-defined #objc_class)
                // encodes as `@`. Anything else falls to `^v` — generic
                // pointer; the runtime treats it as opaque.
                const pointee_info = self.l.module.types.get(p.pointee);
                const is_objc_obj = blk: {
                    if (pointee_info != .@"struct") break :blk false;
                    const name = self.l.module.types.getString(pointee_info.@"struct".name);
                    break :blk self.l.program_index.runtime_class_map.get(name) != null;
                };
                if (is_objc_obj) {
                    try out.append(self.l.alloc, '@');
                } else {
                    try out.appendSlice(self.l.alloc, "^v");
                }
            },
            .many_pointer => |mp| {
                // `[*]u8` is the canonical C-string carrier — encode as `*`.
                // Other element types fall to generic `^v`.
                const el = self.l.module.types.get(mp.element);
                if (el == .unsigned and el.unsigned == 8) {
                    try out.append(self.l.alloc, '*');
                } else {
                    try out.appendSlice(self.l.alloc, "^v");
                }
            },
            .optional => |o| {
                // sx's `?T` is a nullable T. At the Obj-C ABI boundary
                // nullability is just "this pointer may be null" — the
                // wire-level encoding is the same as T. Unwrap and
                // recurse. (Same goes for `?*UIView` etc. — the
                // underlying pointer kind drives the encoding char.)
                return self.appendObjcEncoding(out, o.child, span, stack);
            },
            .@"struct" => |s| {
                // Pass-by-value struct argument or return: Apple's
                // encoding is `{Name=field0field1...}`. A struct
                // already on the encoding stack (i.e. transitively
                // referenced through a struct field — extremely rare
                // since sx structs don't recurse by value) gets the
                // abbreviated `{Name}` form. Recursion through
                // POINTERS is fine because `.pointer` collapses to
                // `^v` regardless of pointee shape.
                const name = self.l.module.types.getString(s.name);
                try out.append(self.l.alloc, '{');
                try out.appendSlice(self.l.alloc, name);
                if (stack.contains(ty)) {
                    try out.append(self.l.alloc, '}');
                    return;
                }
                if (!stack.push(ty)) {
                    return self.bailObjcEncoding(span, "Obj-C struct encoding nested deeper than supported", ObjcEncodingStack.cap);
                }
                defer stack.pop();
                try out.append(self.l.alloc, '=');
                for (s.fields) |f| {
                    try self.appendObjcEncoding(out, f.ty, span, stack);
                }
                try out.append(self.l.alloc, '}');
            },
            else => return self.bailObjcEncoding(span, "type kind not yet supported by Obj-C encoding", @intFromEnum(std.meta.activeTag(info))),
        }
    }

    fn bailObjcEncoding(self: ObjcLowering, span: ?ast.Span, reason: []const u8, detail: anytype) anyerror {
        if (self.l.diagnostics) |d| {
            d.addFmt(.err, span, "cannot derive Obj-C type encoding: {s} (detail={any})", .{ reason, detail });
        }
        return error.ObjcEncodingUnsupported;
    }

    /// Build (and cache) the hidden sx-state struct type for an sx-defined
    /// `#objc_class`. The state struct is what the runtime's `__sx_state`
    /// ivar points at — separate from the Obj-C object itself, which stays
    /// opaque. Layout (M1.2 A.2):
    ///
    ///   __<ClassName>State {
    ///       user_field_0,
    ///       user_field_1,
    ///       ...
    ///   }
    ///
    /// M1.2 A.5 will prepend `__sx_allocator: Allocator` so `-dealloc`
    /// can free through the per-instance allocator and method bodies can
    /// access `self.allocator`. For A.2 the struct holds only the
    /// user-declared fields — sufficient for the body lowering +
    /// `self.field` access work in A.2/A.3. Field-by-name resolution
    /// stays correct across the future repositioning.
    ///
    /// Runtime-class members other than `.field` are ignored here —
    /// methods / `#extends` / `#implements` don't contribute to the
    /// state layout.
    pub fn objcDefinedStateStructType(self: ObjcLowering, fcd: *const ast.RuntimeClassDecl) TypeId {
        const state_name = std.fmt.allocPrint(self.l.alloc, "__{s}State", .{fcd.name}) catch unreachable;
        defer self.l.alloc.free(state_name); // internString copies; the temp isn't needed after.
        const name_id = self.l.module.types.internString(state_name);
        if (self.l.module.types.findByName(name_id)) |existing| return existing;

        // The interned struct's `fields` slice lives for the module's lifetime;
        // allocate it (and the building ArrayList) in the module arena so it's
        // freed at module deinit rather than leaking through `self.l.alloc`.
        const field_alloc = self.l.module.slice_arena.allocator();
        var fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
        // M4.0: prepend __sx_allocator at field index 0 — captured at +alloc
        // time, read at -dealloc time to free the state struct through the
        // same allocator. Lookup by name (the existing by-name resolution in
        // emitObjcDefinedClassPropertyImps + lookupObjcDefinedStateFieldOnPointer)
        // naturally finds user fields at their post-shift indices.
        if (self.objcStateAllocatorType()) |allocator_ty| {
            fields.append(field_alloc, .{
                .name = self.l.module.types.internString("__sx_allocator"),
                .ty = allocator_ty,
            }) catch unreachable;
        }
        for (fcd.members) |m| {
            switch (m) {
                .field => |f| {
                    const f_name_id = self.l.module.types.internString(f.name);
                    const f_ty = self.l.resolveType(f.field_type);
                    fields.append(field_alloc, .{ .name = f_name_id, .ty = f_ty }) catch unreachable;
                },
                else => {},
            }
        }
        return self.l.module.types.intern(.{ .@"struct" = .{
            .name = name_id,
            .fields = fields.toOwnedSlice(field_alloc) catch unreachable,
        } });
    }

    /// Return the `Allocator` protocol TypeId (the value-shape used in
    /// Context.allocator), resolved BY NAME against the assembled Context.
    /// Falls back to null if Context isn't registered yet (early-init
    /// paths); callers omit the field in that case.
    fn objcStateAllocatorType(self: ObjcLowering) ?TypeId {
        return (self.l.contextFieldByName("allocator") orelse return null).ty;
    }

    pub fn isObjcClassPointer(self: ObjcLowering, ty: TypeId) bool {
        if (ty.isBuiltin()) return false;
        const ptr_info = self.l.module.types.get(ty);
        if (ptr_info != .pointer) return false;
        const pointee_info = self.l.module.types.get(ptr_info.pointer.pointee);
        if (pointee_info != .@"struct") return false;
        const struct_name = self.l.module.types.getString(pointee_info.@"struct".name);
        const fcd = self.l.program_index.runtime_class_map.get(struct_name) orelse return false;
        return fcd.runtime == .objc_class or fcd.runtime == .objc_protocol;
    }

    /// Resolve a `#property(...)` field's ARC kind. Loud at compile time
    /// for known footguns (per the silent-error budget in the plan):
    ///   - unknown modifier name (typo) → diagnostic
    ///   - `weak` on a non-object field type → diagnostic
    ///   - `strong` (explicit or defaulted) on `*void` (ambiguous: Obj-C
    ///     object vs raw memory) → require explicit modifier
    pub fn objcPropertyKind(self: ObjcLowering, field: ast.RuntimeFieldDecl) ObjcPropertyKind {
        // Survey the modifier list.
        var has_strong = false;
        var has_weak   = false;
        var has_copy   = false;
        var has_assign = false;
        for (field.property_modifiers) |mod| {
            if (std.mem.eql(u8, mod, "strong")) has_strong = true
            else if (std.mem.eql(u8, mod, "weak"))   has_weak   = true
            else if (std.mem.eql(u8, mod, "copy"))   has_copy   = true
            else if (std.mem.eql(u8, mod, "assign")) has_assign = true
            else if (std.mem.eql(u8, mod, "readonly")) {
                // Orthogonal to ARC kind — no-op here.
            }
            else if (std.mem.eql(u8, mod, "nonatomic") or std.mem.eql(u8, mod, "atomic")) {
                // Atomicity — recorded for the property attribute string;
                // doesn't affect the ARC kind.
            }
            else if (std.mem.startsWith(u8, mod, "getter(") or std.mem.startsWith(u8, mod, "setter(")) {
                // Selector overrides — handled elsewhere.
            }
            else {
                if (self.l.diagnostics) |d| {
                    const span = ast.Span{ .start = 0, .end = 0 };
                    d.addFmt(.err, span, "unknown #property modifier '{s}' on field '{s}' — expected one of: strong, weak, copy, assign, readonly, nonatomic, atomic, getter(\"...\"), setter(\"...\")", .{ mod, field.name });
                }
            }
        }

        // Mutually-exclusive ARC modifiers — at most one.
        const explicit_count: u32 =
            (@as(u32, if (has_strong) 1 else 0)) +
            (@as(u32, if (has_weak)   1 else 0)) +
            (@as(u32, if (has_copy)   1 else 0)) +
            (@as(u32, if (has_assign) 1 else 0));
        if (explicit_count > 1) {
            if (self.l.diagnostics) |d| {
                const span = ast.Span{ .start = 0, .end = 0 };
                d.addFmt(.err, span, "conflicting #property modifiers on field '{s}' — strong/weak/copy/assign are mutually exclusive", .{field.name});
            }
        }

        // Resolve the field's type to decide defaults + validate.
        const field_ty = self.l.resolveType(field.field_type);
        const is_pointer = !field_ty.isBuiltin() and self.l.module.types.get(field_ty) == .pointer;
        const is_object_ptr = is_pointer and blk: {
            const pointee = self.l.module.types.get(field_ty).pointer.pointee;
            // `*void` is NOT considered an object pointer — ambiguous.
            if (pointee == .void) break :blk false;
            // `*T` where T is a runtime-class struct (Obj-C class).
            if (pointee.isBuiltin()) break :blk false;
            const pointee_info = self.l.module.types.get(pointee);
            if (pointee_info != .@"struct") break :blk false;
            const struct_name = self.l.module.types.getString(pointee_info.@"struct".name);
            const fcd = self.l.program_index.runtime_class_map.get(struct_name) orelse break :blk false;
            break :blk fcd.runtime == .objc_class or fcd.runtime == .objc_protocol;
        };

        // `weak` requires an object pointer — `weak i32` is meaningless and
        // would invoke objc_storeWeak on a non-object slot.
        if (has_weak and !is_object_ptr) {
            if (self.l.diagnostics) |d| {
                const span = ast.Span{ .start = 0, .end = 0 };
                d.addFmt(.err, span, "#property(weak) on field '{s}' requires a pointer-to-Obj-C-class type; got '{s}'", .{ field.name, self.l.module.types.typeName(field_ty) });
            }
        }

        // `copy` requires an object pointer — `copy i32` makes no sense.
        if (has_copy and !is_object_ptr) {
            if (self.l.diagnostics) |d| {
                const span = ast.Span{ .start = 0, .end = 0 };
                d.addFmt(.err, span, "#property(copy) on field '{s}' requires a pointer-to-Obj-C-class type (typically NSString or NSArray)", .{field.name});
            }
        }

        // `*void` is ambiguous (Obj-C object vs raw memory): require explicit
        // modifier so the user opts into ARC semantics consciously.
        if (is_pointer) {
            const pointee = self.l.module.types.get(field_ty).pointer.pointee;
            if (pointee == .void and explicit_count == 0) {
                if (self.l.diagnostics) |d| {
                    const span = ast.Span{ .start = 0, .end = 0 };
                    d.addFmt(.err, span, "#property on field '{s}' of type '*void' is ambiguous — specify `#property(strong|weak|copy|assign)` explicitly (Obj-C object vs raw memory)", .{field.name});
                }
                return .assign; // assume safe default to keep compilation going
            }
        }

        // Apply explicit modifier or default.
        if (has_weak)   return .weak;
        if (has_copy)   return .copy;
        if (has_strong) return .strong;
        if (has_assign) return .assign;
        // Default: object pointers → strong; everything else → assign.
        return if (is_object_ptr) .strong else .assign;
    }
};
