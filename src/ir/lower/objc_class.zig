const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const mod_mod = @import("../module.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;
const Module = mod_mod.Module;


const lower = @import("../lower.zig");
const Lowering = lower.Lowering;

/// Emit a C-ABI exported function for every bodied method on a
/// `#jni_main #jni_class("...")` declaration. The symbol name follows
/// JNI's name-mangling convention so Android's JNI runtime can resolve
/// `private native sx_<method>(...)` (declared in the bundled
/// classes.dex by `jni_java_emit`) without an explicit `RegisterNatives`
/// call — i.e. `Java_<pkg-mangled>_<Class>_sx_1<method-mangled>`.
///
/// Param ABI: prepended `(env: *void, self: *void)` (JNIEnv* + jobject
/// receiver), followed by the user-declared params with pointer types
/// type-erased to `*void` (JNI carries jobjects, not sx-typed handles —
/// future work can keep richer typing inside the body when needed).
/// Eagerly lower bodied instance methods on every sx-defined
/// `#objc_class`. The Obj-C runtime invokes these via the IMP
/// pointers wired up in M1.2 A.4 — no sx-side call path triggers
/// lazy lowering, so we walk the cache and force-lower here.
/// `lowerFunction` sets `current_runtime_class` automatically based
/// on the qualified name, so `*Self` substitutions in the body
/// resolve correctly (M1.2 A.2b). After the bodies are lowered,
/// `emitObjcDefinedClassImps` wraps each with a C-ABI trampoline
/// (M1.2 A.4b.ii).
pub fn lowerObjcDefinedClassMethods(self: *Lowering) void {
    for (self.module.objc_defined_class_cache.items) |entry| {
        const fcd = entry.decl;
        for (fcd.members) |m| {
            const method = switch (m) {
                .method => |md| md,
                else => continue,
            };
            if (method.body == null) continue;
            const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ fcd.name, method.name }) catch continue;
            self.lazyLowerFunction(qualified);
        }
    }
    // Now the bodies are lowered — emit the C-ABI IMP trampolines
    // that bridge `objc_msgSend` invocations to them.
    self.emitObjcDefinedClassImps();
}

/// If `obj_expr` is typed as a pointer to a runtime Obj-C class
/// and that class (or any of its `#extends` ancestors) declares a
/// `#property` field with the given name, return the
/// `RuntimeFieldDecl`. M2.2 + M2.3.
pub fn lookupObjcPropertyOnPointer(self: *Lowering, obj_expr: *const ast.Node, field_name: []const u8) ?ast.RuntimeFieldDecl {
    const obj_ty = self.inferExprType(obj_expr);
    if (obj_ty.isBuiltin()) return null;
    const ptr_info = self.module.types.get(obj_ty);
    if (ptr_info != .pointer) return null;
    const pointee_info = self.module.types.get(ptr_info.pointer.pointee);
    if (pointee_info != .@"struct") return null;
    const struct_name = self.module.types.getString(pointee_info.@"struct".name);
    const fcd = self.program_index.runtime_class_map.get(struct_name) orelse return null;
    if (fcd.runtime != .objc_class and fcd.runtime != .objc_protocol) return null;
    return self.findRuntimePropertyInChain(fcd, field_name);
}

/// Walk the `#extends` chain looking for a method by name. M2.3.
/// Returns the owning fcd + the method decl, or null if no ancestor
/// declares it. Depth-capped at 16 to break accidental cycles
/// (real Obj-C class chains rarely exceed 6 levels).
pub fn findRuntimeMethodInChain(self: *Lowering, fcd: *const ast.RuntimeClassDecl, method_name: []const u8) ?struct { fcd: *const ast.RuntimeClassDecl, method: ast.RuntimeMethodDecl } {
    var current: *const ast.RuntimeClassDecl = fcd;
    var depth: u32 = 0;
    while (depth < 16) : (depth += 1) {
        for (current.members) |m| switch (m) {
            .method => |md| if (std.mem.eql(u8, md.name, method_name)) return .{ .fcd = current, .method = md },
            else => {},
        };
        // Not on this level — follow `#extends ParentName`.
        const parent = blk: {
            for (current.members) |m| switch (m) {
                .extends => |p| break :blk p,
                else => {},
            };
            break :blk null;
        } orelse return null;
        current = self.program_index.runtime_class_map.get(parent) orelse return null;
    }
    return null;
}

/// Walk the `#extends` chain looking for a `#property` field by
/// name. M2.3 companion to findRuntimeMethodInChain.
pub fn findRuntimePropertyInChain(self: *Lowering, fcd: *const ast.RuntimeClassDecl, field_name: []const u8) ?ast.RuntimeFieldDecl {
    var current: *const ast.RuntimeClassDecl = fcd;
    var depth: u32 = 0;
    while (depth < 16) : (depth += 1) {
        for (current.members) |m| switch (m) {
            .field => |f| if (f.is_property and std.mem.eql(u8, f.name, field_name)) return f,
            else => {},
        };
        const parent = blk: {
            for (current.members) |m| switch (m) {
                .extends => |p| break :blk p,
                else => {},
            };
            break :blk null;
        } orelse return null;
        current = self.program_index.runtime_class_map.get(parent) orelse return null;
    }
    return null;
}

const ObjcDefinedStateField = struct {
    field_ty: TypeId,
    state_ty: TypeId,
    field_idx: u32,
    fcd: *const ast.RuntimeClassDecl,
};

/// State-field-access info: if obj_expr is *<sx-defined-class>
/// and `field_name` is in the state struct (not a property),
/// returns the field's TypeId, the state struct's TypeId, and
/// the field's index. M1.2 A.3 supports.
pub fn lookupObjcDefinedStateFieldOnPointer(self: *Lowering, obj_expr: *const ast.Node, field_name: []const u8) ?ObjcDefinedStateField {
    const obj_ty = self.inferExprType(obj_expr);
    if (obj_ty.isBuiltin()) return null;
    const ptr_info = self.module.types.get(obj_ty);
    if (ptr_info != .pointer) return null;
    const pointee_info = self.module.types.get(ptr_info.pointer.pointee);
    if (pointee_info != .@"struct") return null;
    const struct_name = self.module.types.getString(pointee_info.@"struct".name);
    const fcd = self.program_index.runtime_class_map.get(struct_name) orelse return null;
    // Only sx-defined Obj-C classes have a state struct. Extern (referenced)
    // runtime classes' fields are purely declaration metadata (no state).
    if (fcd.is_extern or fcd.runtime != .objc_class) return null;
    // Skip property fields — those dispatch via the M2.2 getter/setter
    // path. Plain instance fields take the ivar+gep path.
    for (fcd.members) |m| switch (m) {
        .field => |f| {
            if (std.mem.eql(u8, f.name, field_name)) {
                if (f.is_property) return null;
                const state_ty = self.objc().objcDefinedStateStructType(fcd);
                const state_info = self.module.types.get(state_ty);
                if (state_info != .@"struct") return null;
                const fname_id = self.module.types.internString(f.name);
                for (state_info.@"struct".fields, 0..) |sf, idx| {
                    if (sf.name == fname_id) {
                        return .{
                            .field_ty = sf.ty,
                            .state_ty = state_ty,
                            .field_idx = @intCast(idx),
                            .fcd = fcd,
                        };
                    }
                }
                return null;
            }
        },
        else => {},
    };
    return null;
}

/// Lower a read of `self.field` (or `obj.field`) on a sx-defined
/// Obj-C class: `state = object_getIvar(self, load(ivar_global))`
/// then `struct_gep(state, idx)` + load. M1.2 A.3 — the runtime
/// hop through the hidden ivar.
pub fn lowerObjcDefinedStateFieldRead(
    self: *Lowering,
    obj_expr: *const ast.Node,
    info: ObjcDefinedStateField,
) Ref {
    const obj_ref = self.lowerExpr(obj_expr);
    const state_ptr = self.lowerObjcDefinedStateForObj(obj_ref, info.fcd) orelse return Ref.none;
    const ptr_void = self.module.types.ptrTo(.void);
    const field_addr = self.builder.emit(.{ .struct_gep = .{
        .base = state_ptr,
        .field_index = info.field_idx,
        .base_type = info.state_ty,
    } }, ptr_void);
    return self.builder.load(field_addr, info.field_ty);
}

/// `state = object_getIvar(obj, load(__<Cls>_state_ivar))`. Shared
/// helper for state-field read + write (M1.2 A.3).
pub fn lowerObjcDefinedStateForObj(self: *Lowering, obj_ref: Ref, fcd: *const ast.RuntimeClassDecl) ?Ref {
    const ptr_void = self.module.types.ptrTo(.void);
    const ivar_global_name = std.fmt.allocPrint(self.alloc, "__{s}_state_ivar", .{fcd.name}) catch return null;
    defer self.alloc.free(ivar_global_name);
    const ivar_global_id = self.lookupGlobalIdByName(ivar_global_name) orelse return null;
    const ivar_addr = self.builder.emit(.{ .global_addr = ivar_global_id }, ptr_void);
    const ivar_handle = self.builder.load(ivar_addr, ptr_void);
    const get_ivar_fid = self.ensureCRuntimeDecl("object_getIvar", &.{ ptr_void, ptr_void }, ptr_void);
    const args = self.alloc.alloc(Ref, 2) catch return null;
    args[0] = obj_ref;
    args[1] = ivar_handle;
    return self.builder.emit(.{ .call = .{ .callee = get_ivar_fid, .args = args } }, ptr_void);
}

/// Lower `obj.field` for an Obj-C `#property` field as
/// `objc_msg_send(obj, sel_<fieldName>)`. M2.2 — getter side.
/// The setter side lives in the assignment-statement lowering.
pub fn lowerObjcPropertyGetter(self: *Lowering, obj_expr: *const ast.Node, field: ast.RuntimeFieldDecl, _: []const u8, _: ast.Span) Ref {
    const obj_ref = self.lowerExpr(obj_expr);
    const ret_ty = self.resolveType(field.field_type);
    const vptr_ty = self.module.types.ptrTo(.void);
    // The selector for a property getter is the field name verbatim
    // (Obj-C convention; the override hook is for niche cases like
    // `isHidden` and lands with M2.2's modifier handling).
    const sel_slot_gid = self.internObjcSelector(field.name);
    const slot_ptr = self.builder.emit(.{ .global_addr = sel_slot_gid }, self.module.types.ptrTo(vptr_ty));
    const sel = self.builder.emit(.{ .load = .{ .operand = slot_ptr } }, vptr_ty);
    return self.builder.emit(.{ .objc_msg_send = .{
        .recv = obj_ref,
        .sel = sel,
        .args = &.{},
    } }, ret_ty);
}

/// Lower `obj.field = val` for an Obj-C `#property` field as
/// `objc_msg_send(obj, sel_set<Field>:, val)`. M2.2 — setter side.
/// Selector: prepend "set", capitalize the first letter of the
/// field name, append ":".  `backgroundColor` → `setBackgroundColor:`.
pub fn lowerObjcPropertySetter(self: *Lowering, obj_expr: *const ast.Node, field: ast.RuntimeFieldDecl, val: Ref) void {
    const obj_ref = self.lowerExpr(obj_expr);
    const vptr_ty = self.module.types.ptrTo(.void);

    // Build the setter selector.
    var sel_buf = std.ArrayList(u8).empty;
    defer sel_buf.deinit(self.alloc);
    sel_buf.appendSlice(self.alloc, "set") catch unreachable;
    if (field.name.len > 0) {
        sel_buf.append(self.alloc, std.ascii.toUpper(field.name[0])) catch unreachable;
        sel_buf.appendSlice(self.alloc, field.name[1..]) catch unreachable;
    }
    sel_buf.append(self.alloc, ':') catch unreachable;
    const sel_str = self.alloc.dupe(u8, sel_buf.items) catch unreachable;

    const sel_slot_gid = self.internObjcSelector(sel_str);
    const slot_ptr = self.builder.emit(.{ .global_addr = sel_slot_gid }, self.module.types.ptrTo(vptr_ty));
    const sel = self.builder.emit(.{ .load = .{ .operand = slot_ptr } }, vptr_ty);
    const args = self.alloc.alloc(Ref, 1) catch unreachable;
    args[0] = val;
    _ = self.builder.emit(.{ .objc_msg_send = .{
        .recv = obj_ref,
        .sel = sel,
        .args = args,
    } }, .void);
}

/// Get a FuncId for an external C-ABI function. If a function
/// with this exported name already exists in the module (e.g.
/// declared by stdlib `extern` decl), return it; otherwise
/// declare it fresh with the given signature.
///
/// One helper instead of a `get<Name>Fid` per runtime function —
/// avoids per-function cache fields and per-function boilerplate.
pub fn ensureCRuntimeDecl(self: *Lowering, name: []const u8, param_tys: []const TypeId, ret_ty: TypeId) FuncId {
    const name_id = self.module.types.internString(name);
    for (self.module.functions.items, 0..) |f, i| {
        if (f.name == name_id) return FuncId.fromIndex(@intCast(i));
    }
    var params = std.ArrayList(inst_mod.Function.Param).empty;
    for (param_tys, 0..) |pty, i| {
        // Param names don't matter at the LLVM ABI boundary —
        // synthesize generic ones (`a0`, `a1`, ...) so we don't
        // need a parallel name list per call site.
        const synth = std.fmt.allocPrint(self.alloc, "a{d}", .{i}) catch unreachable;
        params.append(self.alloc, .{
            .name = self.module.types.internString(synth),
            .ty = pty,
        }) catch unreachable;
    }
    const fid = self.builder.declareExtern(name_id, params.toOwnedSlice(self.alloc) catch unreachable, ret_ty);
    self.module.getFunctionMut(fid).call_conv = .c;
    return fid;
}

/// For each bodied instance method on a sx-defined `#objc_class`,
/// emit a C-ABI IMP trampoline that the Obj-C runtime calls (after
/// the dispatch path from `objc_msgSend`). The trampoline:
///   1. Loads the cached ivar handle from `@__<Cls>_state_ivar`.
///   2. Calls `object_getIvar(obj, ivar)` to get the `*<Cls>State`
///      state pointer.
///   3. Calls the sx body `@<Cls>.<method>(__sx_default_context,
///      state, ...user_args)` (default sx convention).
///   4. Returns the result (or `ret void`).
///
/// IMP name: `__<ClassName>_<methodName>_imp`. emit_llvm's
/// constructor (A.4b.ii companion) registers this via
/// `class_addMethod` with a derived selector + type encoding.
pub fn emitObjcDefinedClassImps(self: *Lowering) void {
    for (self.module.objc_defined_class_cache.items) |entry| {
        const fcd = entry.decl;
        // Pin to the class's defining module (E4) so the IMP trampolines'
        // method-signature types (`-> BOOL`, param types) resolve where they
        // are visible, not at whatever lowering site triggered emission.
        const saved_src = self.current_source_file;
        defer self.setCurrentSourceFile(saved_src);
        if (fcd.source_file) |src| self.setCurrentSourceFile(src);
        // Synthesize +alloc (M1.2 A.5) and -dealloc (M1.2 A.6). emit_llvm
        // registers +alloc on the metaclass and -dealloc on the class
        // itself after objc_registerClassPair.
        self.emitObjcDefinedClassAllocImp(fcd);
        self.emitObjcDefinedClassDeallocImp(fcd);
        for (fcd.members) |m| {
            switch (m) {
                .method => |method| {
                    if (method.body == null) continue;
                    self.emitObjcDefinedClassImp(fcd, method);
                },
                .field => |field| {
                    // M2.2 second pass — sx-defined property fields
                    // synthesize getter (+ setter unless `readonly`)
                    // IMPs that GEP into the state struct.
                    if (field.is_property) {
                        self.emitObjcDefinedClassPropertyImps(fcd, field);
                    }
                },
                else => {},
            }
        }
    }
}

/// Lazily declare libobjc's ARC runtime helpers. Idempotent — uses
/// `ensureCRuntimeDecl` which skips already-declared symbols. Called
/// from the property setter/getter and -dealloc emission paths when
/// they need to emit a retain/release/storeWeak/etc.
pub fn ensureArcRuntimeDecls(self: *Lowering) void {
    const ptr_void = self.module.types.ptrTo(.void);
    _ = self.ensureCRuntimeDecl("objc_retain", &.{ptr_void}, ptr_void);
    _ = self.ensureCRuntimeDecl("objc_release", &.{ptr_void}, .void);
    _ = self.ensureCRuntimeDecl("objc_storeWeak", &.{ ptr_void, ptr_void }, ptr_void);
    _ = self.ensureCRuntimeDecl("objc_loadWeakRetained", &.{ptr_void}, ptr_void);
    _ = self.ensureCRuntimeDecl("objc_initWeak", &.{ ptr_void, ptr_void }, ptr_void);
    _ = self.ensureCRuntimeDecl("objc_destroyWeak", &.{ptr_void}, .void);
}

/// M2.2 second pass — emit synthesized getter/setter IMPs for a
/// property field on a sx-defined `#objc_class`. The state struct
/// already holds the field (via objcDefinedStateStructType); the
/// IMPs just dispatch a load/store through the `__sx_state` ivar.
///
/// Getter IMP:   `__<Cls>_<field>_imp(self, _cmd) -> T`
///   state = object_getIvar(self, load(__<Cls>_state_ivar))
///   return state.<field>
///
/// Setter IMP (skipped if `readonly` in modifiers):
/// `__<Cls>_set<Field>_imp(self, _cmd, val) -> void`
///   state = object_getIvar(self, load(__<Cls>_state_ivar))
///   state.<field> = val
///
/// Both IMPs land in the cache's methods slice with appropriate
/// selectors + encodings; emit_llvm's class_addMethod loop wires
/// them up like any other instance method.
pub fn emitObjcDefinedClassPropertyImps(self: *Lowering, fcd: *const ast.RuntimeClassDecl, field: ast.RuntimeFieldDecl) void {
    const state_ty = self.objc().objcDefinedStateStructType(fcd);
    const state_info = self.module.types.get(state_ty);
    if (state_info != .@"struct") return;
    // Find the field's index in the state struct.
    const field_name_id = self.module.types.internString(field.name);
    var field_idx: ?u32 = null;
    for (state_info.@"struct".fields, 0..) |sf, i| {
        if (sf.name == field_name_id) {
            field_idx = @intCast(i);
            break;
        }
    }
    const fidx = field_idx orelse return;
    const field_ty = self.resolveType(field.field_type);

    // M4.B: validate modifiers + resolve ARC kind. Side-effect: emits
    // diagnostics for typos, weak-on-non-object, ambiguous *void, etc.
    // For now the setter/getter still emit bare load/store; subsequent
    // M4.B commits wire the actual ARC ops keyed on this kind.
    _ = self.objc().objcPropertyKind(field);

    // (1) Getter: __<Cls>_<field>_imp
    self.emitObjcDefinedPropertyGetter(fcd, field, state_ty, fidx, field_ty);

    // (2) Setter — skipped for `readonly`.
    var is_readonly = false;
    for (field.property_modifiers) |mod| {
        if (std.mem.eql(u8, mod, "readonly")) {
            is_readonly = true;
            break;
        }
    }
    if (!is_readonly) {
        self.emitObjcDefinedPropertySetter(fcd, field, state_ty, fidx, field_ty);
    }

    // (3) Register in the cache's methods slice. Both IMPs use the
    // method-registration pipeline that lands in class_addMethod
    // calls from emit_llvm.
    self.registerObjcDefinedPropertyMethodEntries(fcd, field, field_ty, is_readonly);
}

pub fn emitObjcDefinedPropertyGetter(self: *Lowering, fcd: *const ast.RuntimeClassDecl, field: ast.RuntimeFieldDecl, state_ty: TypeId, fidx: u32, field_ty: TypeId) void {
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    defer {
        self.builder.func = saved_func;
        self.builder.current_block = saved_block;
        self.builder.inst_counter = saved_counter;
    }

    const imp_name = std.fmt.allocPrint(self.alloc, "__{s}_{s}_imp", .{ fcd.name, field.name }) catch return;
    const name_id = self.module.types.internString(imp_name);
    const ptr_void = self.module.types.ptrTo(.void);

    var params = std.ArrayList(inst_mod.Function.Param).empty;
    params.append(self.alloc, .{ .name = self.module.types.internString("self"), .ty = ptr_void }) catch return;
    params.append(self.alloc, .{ .name = self.module.types.internString("_cmd"), .ty = ptr_void }) catch return;
    const params_slice = params.toOwnedSlice(self.alloc) catch return;

    _ = self.builder.beginFunction(name_id, params_slice, field_ty);
    const func = self.builder.currentFunc();
    func.linkage = .external;
    func.call_conv = .c;
    func.has_implicit_ctx = false;

    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);

    // state = object_getIvar(self, load @__<Cls>_state_ivar)
    const self_ref = Ref.fromIndex(0);
    const ivar_global_name = std.fmt.allocPrint(self.alloc, "__{s}_state_ivar", .{fcd.name}) catch return;
    defer self.alloc.free(ivar_global_name);
    const ivar_global_id = self.lookupGlobalIdByName(ivar_global_name) orelse return;
    const ivar_addr = self.builder.emit(.{ .global_addr = ivar_global_id }, ptr_void);
    const ivar_handle = self.builder.load(ivar_addr, ptr_void);
    const get_ivar_fid = self.ensureCRuntimeDecl("object_getIvar", &.{ ptr_void, ptr_void }, ptr_void);
    const get_args = self.alloc.alloc(Ref, 2) catch return;
    get_args[0] = self_ref;
    get_args[1] = ivar_handle;
    const state_ptr = self.builder.emit(.{ .call = .{ .callee = get_ivar_fid, .args = get_args } }, ptr_void);

    const field_addr = self.builder.emit(.{ .struct_gep = .{ .base = state_ptr, .field_index = fidx, .base_type = state_ty } }, ptr_void);

    // M4.B getter — weak fields go through objc_loadWeakRetained +
    // objc_autorelease for race-safe reads. The bare-load path
    // (strong/copy/assign) is the common case and reads the slot
    // directly.
    const kind = self.objc().objcPropertyKind(field);
    if (kind == .weak) {
        self.ensureArcRuntimeDecls();
        const load_weak_fid = self.ensureCRuntimeDecl("objc_loadWeakRetained", &.{ptr_void}, ptr_void);
        const autorelease_fid = self.ensureCRuntimeDecl("objc_autorelease", &.{ptr_void}, ptr_void);

        // retained = objc_loadWeakRetained(field_addr)
        //   - atomic upgrade-to-strong via libobjc's side-table; if the
        //     target deinitialised, returns null. The caller gets a
        //     +1 retained reference (or null).
        const load_args = self.alloc.alloc(Ref, 1) catch return;
        load_args[0] = field_addr;
        const retained = self.builder.emit(.{ .call = .{ .callee = load_weak_fid, .args = load_args } }, ptr_void);

        // autoreleased = objc_autorelease(retained)
        //   - drops it into the current pool so the caller doesn't need
        //     to manually release. Returns the same pointer (typed).
        const ar_args = self.alloc.alloc(Ref, 1) catch return;
        ar_args[0] = retained;
        const autoreleased = self.builder.emit(.{ .call = .{ .callee = autorelease_fid, .args = ar_args } }, ptr_void);

        self.builder.ret(autoreleased, field_ty);
        self.builder.finalize();
        return;
    }

    // strong / copy / assign — bare load.
    const val = self.builder.load(field_addr, field_ty);
    self.builder.ret(val, field_ty);
    self.builder.finalize();
}

pub fn emitObjcDefinedPropertySetter(self: *Lowering, fcd: *const ast.RuntimeClassDecl, field: ast.RuntimeFieldDecl, state_ty: TypeId, fidx: u32, field_ty: TypeId) void {
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    defer {
        self.builder.func = saved_func;
        self.builder.current_block = saved_block;
        self.builder.inst_counter = saved_counter;
    }

    // Setter selector: set<Field>:  →  imp name: __<Cls>_set<Field>_imp
    var setter_field_buf = std.ArrayList(u8).empty;
    defer setter_field_buf.deinit(self.alloc);
    setter_field_buf.appendSlice(self.alloc, "set") catch unreachable;
    if (field.name.len > 0) {
        setter_field_buf.append(self.alloc, std.ascii.toUpper(field.name[0])) catch unreachable;
        setter_field_buf.appendSlice(self.alloc, field.name[1..]) catch unreachable;
    }
    const imp_name = std.fmt.allocPrint(self.alloc, "__{s}_{s}_imp", .{ fcd.name, setter_field_buf.items }) catch return;
    const name_id = self.module.types.internString(imp_name);
    const ptr_void = self.module.types.ptrTo(.void);

    var params = std.ArrayList(inst_mod.Function.Param).empty;
    params.append(self.alloc, .{ .name = self.module.types.internString("self"), .ty = ptr_void }) catch return;
    params.append(self.alloc, .{ .name = self.module.types.internString("_cmd"), .ty = ptr_void }) catch return;
    params.append(self.alloc, .{ .name = self.module.types.internString("val"), .ty = field_ty }) catch return;
    const params_slice = params.toOwnedSlice(self.alloc) catch return;

    _ = self.builder.beginFunction(name_id, params_slice, .void);
    const func = self.builder.currentFunc();
    func.linkage = .external;
    func.call_conv = .c;
    func.has_implicit_ctx = false;

    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);

    const self_ref = Ref.fromIndex(0);
    const val_ref = Ref.fromIndex(2);
    const ivar_global_name = std.fmt.allocPrint(self.alloc, "__{s}_state_ivar", .{fcd.name}) catch return;
    defer self.alloc.free(ivar_global_name);
    const ivar_global_id = self.lookupGlobalIdByName(ivar_global_name) orelse return;
    const ivar_addr = self.builder.emit(.{ .global_addr = ivar_global_id }, ptr_void);
    const ivar_handle = self.builder.load(ivar_addr, ptr_void);
    const get_ivar_fid = self.ensureCRuntimeDecl("object_getIvar", &.{ ptr_void, ptr_void }, ptr_void);
    const get_args = self.alloc.alloc(Ref, 2) catch return;
    get_args[0] = self_ref;
    get_args[1] = ivar_handle;
    const state_ptr = self.builder.emit(.{ .call = .{ .callee = get_ivar_fid, .args = get_args } }, ptr_void);

    const field_addr = self.builder.emit(.{ .struct_gep = .{ .base = state_ptr, .field_index = fidx, .base_type = state_ty } }, ptr_void);

    // M4.B setter — emit ARC ops based on the property's modifier kind.
    const kind = self.objc().objcPropertyKind(field);
    switch (kind) {
        .assign => {
            // Primitives or explicit assign: bare store, no ARC.
            self.builder.store(field_addr, val_ref);
        },
        .strong => {
            // Retain new, release old. Order matters: retain first
            // (in case val == old, we don't release before retain).
            self.ensureArcRuntimeDecls();
            const retain_fid = self.ensureCRuntimeDecl("objc_retain", &.{ptr_void}, ptr_void);
            const release_fid = self.ensureCRuntimeDecl("objc_release", &.{ptr_void}, .void);

            // old = load field_addr
            const old_val = self.builder.load(field_addr, field_ty);
            // new = objc_retain(val)
            const retain_args = self.alloc.alloc(Ref, 1) catch return;
            retain_args[0] = val_ref;
            _ = self.builder.emit(.{ .call = .{ .callee = retain_fid, .args = retain_args } }, ptr_void);
            // store field_addr, val
            self.builder.store(field_addr, val_ref);
            // objc_release(old)  — Apple's runtime treats release(NULL) as a no-op,
            // so we skip an explicit null-check (saves a branch on every assign).
            const release_args = self.alloc.alloc(Ref, 1) catch return;
            release_args[0] = old_val;
            _ = self.builder.emit(.{ .call = .{ .callee = release_fid, .args = release_args } }, .void);
        },
        .weak => {
            // objc_storeWeak(field_addr, val) handles first-store
            // (init) and re-store (destroy old + init new) atomically.
            self.ensureArcRuntimeDecls();
            const store_weak_fid = self.ensureCRuntimeDecl("objc_storeWeak", &.{ ptr_void, ptr_void }, ptr_void);
            const store_args = self.alloc.alloc(Ref, 2) catch return;
            store_args[0] = field_addr;
            store_args[1] = val_ref;
            _ = self.builder.emit(.{ .call = .{ .callee = store_weak_fid, .args = store_args } }, ptr_void);
        },
        .copy => {
            // copy = objc_msgSend(val, sel_copy)  — returns retained
            //                                       (NSCopying contract).
            // Release old, then store the copy.
            self.ensureArcRuntimeDecls();
            const release_fid = self.ensureCRuntimeDecl("objc_release", &.{ptr_void}, .void);

            // Load + cache the `copy` selector slot.
            const sel_copy_gid = self.internObjcSelector("copy");
            const sel_slot_ptr = self.builder.emit(.{ .global_addr = sel_copy_gid }, self.module.types.ptrTo(ptr_void));
            const sel_copy = self.builder.emit(.{ .load = .{ .operand = sel_slot_ptr } }, ptr_void);

            // copy = [val copy]
            const copy_args = self.alloc.alloc(Ref, 0) catch return;
            const copied = self.builder.emit(.{ .objc_msg_send = .{
                .recv = val_ref,
                .sel = sel_copy,
                .args = copy_args,
            } }, ptr_void);

            const old_val = self.builder.load(field_addr, field_ty);
            self.builder.store(field_addr, copied);
            const release_args = self.alloc.alloc(Ref, 1) catch return;
            release_args[0] = old_val;
            _ = self.builder.emit(.{ .call = .{ .callee = release_fid, .args = release_args } }, .void);
        },
    }
    self.builder.retVoid();
    self.builder.finalize();
}

/// Append the property's getter (and setter, unless readonly)
/// entries to the class's method-registration slice so emit_llvm
/// calls class_addMethod on each. Selectors + encodings derived
/// from the field type.
pub fn registerObjcDefinedPropertyMethodEntries(self: *Lowering, fcd: *const ast.RuntimeClassDecl, field: ast.RuntimeFieldDecl, field_ty: TypeId, is_readonly: bool) void {
    const cur = self.module.lookupObjcDefinedClass(fcd.name) orelse return;
    _ = cur;
    // Find the existing entry and grow its methods slice.
    var new_methods = std.ArrayList(Module.ObjcDefinedMethodEntry).empty;
    for (self.module.objc_defined_class_cache.items) |entry| {
        if (!std.mem.eql(u8, entry.name, fcd.name)) continue;
        for (entry.methods) |m| new_methods.append(self.alloc, m) catch unreachable;

        // Getter entry — selector = field name, encoding = "<ret>@:".
        const getter_enc = self.objc().objcTypeEncodingFromSignature(field_ty, &.{}, null) catch return;
        const getter_imp_name = std.fmt.allocPrint(self.alloc, "__{s}_{s}_imp", .{ fcd.name, field.name }) catch return;
        new_methods.append(self.alloc, .{
            .sel = field.name,
            .encoding = getter_enc,
            .imp_name = getter_imp_name,
            .is_class = false,
        }) catch unreachable;

        // Setter entry — selector = set<Field>:, encoding = "v@:<ty>".
        if (!is_readonly) {
            var sel_buf = std.ArrayList(u8).empty;
            defer sel_buf.deinit(self.alloc);
            sel_buf.appendSlice(self.alloc, "set") catch unreachable;
            if (field.name.len > 0) {
                sel_buf.append(self.alloc, std.ascii.toUpper(field.name[0])) catch unreachable;
                sel_buf.appendSlice(self.alloc, field.name[1..]) catch unreachable;
            }
            sel_buf.append(self.alloc, ':') catch unreachable;
            const setter_sel = self.alloc.dupe(u8, sel_buf.items) catch return;

            const setter_enc = self.objc().objcTypeEncodingFromSignature(.void, &.{field_ty}, null) catch return;

            var setter_imp_field_buf = std.ArrayList(u8).empty;
            defer setter_imp_field_buf.deinit(self.alloc);
            setter_imp_field_buf.appendSlice(self.alloc, "set") catch unreachable;
            if (field.name.len > 0) {
                setter_imp_field_buf.append(self.alloc, std.ascii.toUpper(field.name[0])) catch unreachable;
                setter_imp_field_buf.appendSlice(self.alloc, field.name[1..]) catch unreachable;
            }
            const setter_imp_name = std.fmt.allocPrint(self.alloc, "__{s}_{s}_imp", .{ fcd.name, setter_imp_field_buf.items }) catch return;

            new_methods.append(self.alloc, .{
                .sel = setter_sel,
                .encoding = setter_enc,
                .imp_name = setter_imp_name,
                .is_class = false,
            }) catch unreachable;
        }
        break;
    }
    const slice = new_methods.toOwnedSlice(self.alloc) catch return;
    self.module.setObjcDefinedClassMethods(fcd.name, slice);
}

pub fn emitObjcDefinedClassImp(self: *Lowering, fcd: *const ast.RuntimeClassDecl, md: ast.RuntimeMethodDecl) void {
    // Class methods (no `*Self` first param) skip the ivar read —
    // they have no instance state to thread through.
    if (md.is_static) {
        self.emitObjcDefinedClassStaticImp(fcd, md);
        return;
    }

    // Save+restore builder state — we're switching into a new fn
    // mid-pass and need to restore for the next emit_llvm steps.
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    defer {
        self.builder.func = saved_func;
        self.builder.current_block = saved_block;
        self.builder.inst_counter = saved_counter;
    }

    const imp_name = std.fmt.allocPrint(self.alloc, "__{s}_{s}_imp", .{ fcd.name, md.name }) catch return;
    const name_id = self.module.types.internString(imp_name);
    const ptr_void = self.module.types.ptrTo(.void);

    // C-ABI signature: (obj: *void, _cmd: *void, ...user_args) -> ret.
    // User params skip index 0 (which is *Self).
    var params = std.ArrayList(inst_mod.Function.Param).empty;
    params.append(self.alloc, .{ .name = self.module.types.internString("obj"), .ty = ptr_void }) catch return;
    params.append(self.alloc, .{ .name = self.module.types.internString("_cmd"), .ty = ptr_void }) catch return;

    // Set current_runtime_class so *Self in user-param resolution
    // resolves to *<Cls>State (M1.2 A.2b). Save+restore.
    const saved_fc = self.current_runtime_class;
    self.current_runtime_class = fcd;
    defer self.current_runtime_class = saved_fc;

    const param_start: usize = 1;
    for (md.params[param_start..], 0..) |p_node, i| {
        // User params are reflected at the C-ABI boundary AS-IS —
        // the runtime trampoline forwards them through to the body.
        // *Self here would be a programming error (only the implicit
        // self at index 0 is *Self), but we use resolveType to handle
        // pointer types correctly.
        const pty = self.resolveType(p_node);
        params.append(self.alloc, .{
            .name = self.module.types.internString(md.param_names[param_start + i]),
            .ty = pty,
        }) catch return;
    }

    const ret_ty: TypeId = if (md.return_type) |rt| self.resolveType(rt) else .void;
    const params_slice = params.toOwnedSlice(self.alloc) catch return;

    _ = self.builder.beginFunction(name_id, params_slice, ret_ty);
    const func = self.builder.currentFunc();
    func.linkage = .external;
    func.call_conv = .c;
    func.has_implicit_ctx = false;

    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);

    // Pass the Obj-C receiver pointer through to the sx body as
    // `self`. The body's `self: *Self` type resolves to the
    // runtime-class stub (the opaque Obj-C type), matching Apple's
    // Obj-C semantics where `self` IS the object. `self.field`
    // access on a sx-defined class is rewritten by lowerFieldAccess
    // to go through `object_getIvar(self, __sx_state_ivar)` and
    // a struct_gep on the state struct — see M1.2 A.3.
    const obj_ref = Ref.fromIndex(0);

    // Call sx body `@<Cls>.<method>(default_ctx, self, ...user_args)`.
    const body_name = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ fcd.name, md.name }) catch return;
    defer self.alloc.free(body_name);
    const body_fid = self.resolveFuncByName(body_name) orelse return;

    const ctx_ref: ?Ref = blk: {
        if (!self.implicit_ctx_enabled) break :blk null;
        const dctx_gi = self.program_index.global_names.get("__sx_default_context") orelse break :blk null;
        break :blk self.builder.emit(.{ .global_addr = dctx_gi.id }, ptr_void);
    };

    // Build arg list: [ctx?] + self + user_args.
    const num_user_args = params_slice.len - 2; // minus obj + _cmd
    const num_call_args = (if (ctx_ref != null) @as(usize, 1) else 0) + 1 + num_user_args;
    const call_args = self.alloc.alloc(Ref, num_call_args) catch return;
    var idx: usize = 0;
    if (ctx_ref) |c_ref| {
        call_args[idx] = c_ref;
        idx += 1;
    }
    call_args[idx] = obj_ref;
    idx += 1;
    var ip: usize = 2;
    while (ip < params_slice.len) : (ip += 1) {
        call_args[idx] = Ref.fromIndex(@intCast(ip));
        idx += 1;
    }

    const call_ref = self.builder.emit(.{ .call = .{
        .callee = body_fid,
        .args = call_args,
    } }, ret_ty);

    // (4) Return.
    if (ret_ty == .void) {
        self.builder.retVoid();
    } else {
        self.builder.ret(call_ref, ret_ty);
    }

    self.builder.finalize();
}

/// Synthesize the `+alloc` IMP for an sx-defined `#objc_class`.
/// Class method registered on the metaclass — when `[SxFoo alloc]`
/// runs from Apple's runtime (Info.plist principal class,
/// NSCoder unarchive, UIKit reflection), this IMP fires.
///
/// C-ABI: `(cls: id, _cmd: SEL) -> id`. No implicit ctx.
///
/// Body (M4.0):
///   %instance = class_createInstance(cls, 0)
///   %ctx_addr = &__sx_default_context
///   %state    = ctx_addr.allocator.alloc(STATE_SIZE)
///   memset(state, 0, STATE_SIZE)
///   state[0]  = allocator                    ← capture for -dealloc
///   object_setIvar(instance, __sx_state_ivar, state)
///   ret instance
///
/// Sx-side `Cls.alloc()` is intercepted at the call site (see
/// `lowerObjcStaticCall`) and emits the same sequence inline with
/// `current_ctx_ref` as the ctx — so `push Context.{ allocator = ... }`
/// flows through to per-instance allocator capture without going via
/// the IMP.
pub fn emitObjcDefinedClassAllocImp(self: *Lowering, fcd: *const ast.RuntimeClassDecl) void {
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    defer {
        self.builder.func = saved_func;
        self.builder.current_block = saved_block;
        self.builder.inst_counter = saved_counter;
    }

    const imp_name = std.fmt.allocPrint(self.alloc, "__{s}_alloc_imp", .{fcd.name}) catch return;
    const name_id = self.module.types.internString(imp_name);
    const ptr_void = self.module.types.ptrTo(.void);

    var params = std.ArrayList(inst_mod.Function.Param).empty;
    params.append(self.alloc, .{ .name = self.module.types.internString("cls"), .ty = ptr_void }) catch return;
    params.append(self.alloc, .{ .name = self.module.types.internString("_cmd"), .ty = ptr_void }) catch return;
    const params_slice = params.toOwnedSlice(self.alloc) catch return;

    _ = self.builder.beginFunction(name_id, params_slice, ptr_void);
    const func = self.builder.currentFunc();
    func.linkage = .external;
    func.call_conv = .c;
    func.has_implicit_ctx = false;

    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);

    // ctx_addr = &__sx_default_context — IMP runs in Apple's runtime
    // context, no implicit sx ctx to inherit, so use the process-wide
    // default allocator. Sx-side callers bypass this IMP entirely
    // (compiler intercepts Cls.alloc()) and use their own
    // `context.allocator`.
    const default_ctx_gi = self.program_index.global_names.get("__sx_default_context") orelse {
        if (self.diagnostics) |d| {
            d.addFmt(.err, ast.Span{ .start = 0, .end = 0 }, "emitObjcDefinedClassAllocImp: __sx_default_context global missing for class '{s}' (compiler bug — scan pass did not register the default context)", .{fcd.name});
        }
        return;
    };
    const ctx_addr = self.builder.emit(.{ .global_addr = default_ctx_gi.id }, ptr_void);

    const cls_ref = Ref.fromIndex(0);
    const instance = self.emitObjcDefinedAllocAndInit(fcd, cls_ref, ctx_addr) orelse return;

    self.builder.ret(instance, ptr_void);
    self.builder.finalize();
}

/// Shared inline sequence: allocate Obj-C instance + sx state struct,
/// capture the allocator, bind to the `__sx_state` ivar. Used by both
/// the `+alloc` IMP (ctx_addr = &__sx_default_context) and the sx-side
/// `Cls.alloc()` interception (ctx_addr = current_ctx_ref).
///
/// Returns the new instance pointer, or `null` if a required global is
/// missing (compiler bug — should be impossible after scan pass).
pub fn emitObjcDefinedAllocAndInit(
    self: *Lowering,
    fcd: *const ast.RuntimeClassDecl,
    cls_ref: Ref,
    ctx_addr: Ref,
) ?Ref {
    const ptr_void = self.module.types.ptrTo(.void);

    // (1) instance = class_createInstance(cls, 0)
    const create_fid = self.ensureCRuntimeDecl("class_createInstance", &.{ ptr_void, .u64 }, ptr_void);
    const create_args = self.alloc.alloc(Ref, 2) catch return null;
    create_args[0] = cls_ref;
    create_args[1] = self.builder.constInt(0, .u64);
    const instance = self.builder.emit(.{ .call = .{ .callee = create_fid, .args = create_args } }, ptr_void);

    // STATE_SIZE = max(typeSizeBytes(__<Cls>State), 1).
    const state_struct_ty = self.objc().objcDefinedStateStructType(fcd);
    const raw_size = self.module.types.typeSizeBytes(state_struct_ty);
    const state_size: u64 = if (raw_size == 0) 1 else @intCast(raw_size);
    const size_const = self.builder.constInt(@intCast(state_size), .u64);

    // (2) Dispatch through Context.allocator at ctx_addr (resolved BY NAME
    //     against the assembled layout):
    //       state = allocator.alloc(size)  (via inline-protocol fn-ptr)
    const ctx_ty = self.module.types.findByName(self.module.types.internString("Context")) orelse {
        if (self.diagnostics) |d| {
            d.addFmt(.err, ast.Span{ .start = 0, .end = 0 }, "emitObjcDefinedAllocAndInit: Context type not found in module for class '{s}' (compiler bug)", .{fcd.name});
        }
        return null;
    };
    const af = self.contextFieldByName("allocator") orelse {
        if (self.diagnostics) |d| {
            d.addFmt(.err, ast.Span{ .start = 0, .end = 0 }, "emitObjcDefinedAllocAndInit: Context has no 'allocator' field for class '{s}' (compiler bug)", .{fcd.name});
        }
        return null;
    };
    const ctx_val = self.builder.load(ctx_addr, ctx_ty);
    const allocator = self.builder.structGet(ctx_val, af.index, af.ty);
    const alloc_ctx = self.builder.structGet(allocator, 0, ptr_void);
    const alloc_fn_ptr = self.builder.structGet(allocator, 2, ptr_void);
    const call_args = self.alloc.dupe(Ref, &.{ ctx_addr, alloc_ctx, size_const }) catch return null;
    const state = self.builder.emit(.{ .call_indirect = .{
        .callee = alloc_fn_ptr,
        .args = call_args,
    } }, ptr_void);

    // (3) memset(state, 0, STATE_SIZE) — zero everything including the
    // allocator slot; the next store re-writes the allocator slot.
    const memset_fid = self.ensureCRuntimeDecl("memset", &.{ ptr_void, .i32, .u64 }, ptr_void);
    const memset_args = self.alloc.alloc(Ref, 3) catch return null;
    memset_args[0] = state;
    memset_args[1] = self.builder.constInt(0, .i32);
    memset_args[2] = size_const;
    _ = self.builder.emit(.{ .call = .{ .callee = memset_fid, .args = memset_args } }, ptr_void);

    // (4) Capture allocator at state[0] — `-dealloc` reads it back.
    const state_alloc_addr = self.builder.emit(.{ .struct_gep = .{
        .base = state,
        .field_index = 0,
        .base_type = state_struct_ty,
    } }, ptr_void);
    self.builder.store(state_alloc_addr, allocator);

    // (5) object_setIvar(instance, load(@__<Cls>_state_ivar), state)
    const ivar_global_name = std.fmt.allocPrint(self.alloc, "__{s}_state_ivar", .{fcd.name}) catch return null;
    defer self.alloc.free(ivar_global_name);
    const ivar_global_id = self.lookupGlobalIdByName(ivar_global_name) orelse {
        if (self.diagnostics) |d| {
            d.addFmt(.err, ast.Span{ .start = 0, .end = 0 }, "emitObjcDefinedAllocAndInit: ivar global '{s}' missing (scan-pass bug)", .{ivar_global_name});
        }
        return null;
    };
    const ivar_addr_v = self.builder.emit(.{ .global_addr = ivar_global_id }, ptr_void);
    const ivar_handle = self.builder.load(ivar_addr_v, ptr_void);
    const set_ivar_fid = self.ensureCRuntimeDecl("object_setIvar", &.{ ptr_void, ptr_void, ptr_void }, .void);
    const set_args = self.alloc.alloc(Ref, 3) catch return null;
    set_args[0] = instance;
    set_args[1] = ivar_handle;
    set_args[2] = state;
    _ = self.builder.emit(.{ .call = .{ .callee = set_ivar_fid, .args = set_args } }, .void);

    return instance;
}

/// Emit a C-ABI IMP trampoline for a CLASS method (no `*Self`
/// first param) on a sx-defined `#objc_class`. M2.1(b).
/// Registered on the metaclass by emit_llvm.
///
/// C-ABI: `(cls: Class, _cmd: SEL, ...user_args) -> ret`
///
/// Body:
///   call @<Cls>.<method>(__sx_default_context, ...user_args)
///   ret <result>
///
/// No ivar read — class methods have no per-instance state.
pub fn emitObjcDefinedClassStaticImp(self: *Lowering, fcd: *const ast.RuntimeClassDecl, md: ast.RuntimeMethodDecl) void {
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    defer {
        self.builder.func = saved_func;
        self.builder.current_block = saved_block;
        self.builder.inst_counter = saved_counter;
    }

    const imp_name = std.fmt.allocPrint(self.alloc, "__{s}_{s}_imp", .{ fcd.name, md.name }) catch return;
    const name_id = self.module.types.internString(imp_name);
    const ptr_void = self.module.types.ptrTo(.void);

    var params = std.ArrayList(inst_mod.Function.Param).empty;
    params.append(self.alloc, .{ .name = self.module.types.internString("cls"), .ty = ptr_void }) catch return;
    params.append(self.alloc, .{ .name = self.module.types.internString("_cmd"), .ty = ptr_void }) catch return;

    // current_runtime_class lets `*Self` (if it appears in
    // user-arg types — rare for class methods) resolve to the
    // state-struct type. Save+restore.
    const saved_fc = self.current_runtime_class;
    self.current_runtime_class = fcd;
    defer self.current_runtime_class = saved_fc;

    for (md.params, 0..) |p_node, i| {
        const pty = self.resolveType(p_node);
        params.append(self.alloc, .{
            .name = self.module.types.internString(md.param_names[i]),
            .ty = pty,
        }) catch return;
    }

    const ret_ty: TypeId = if (md.return_type) |rt| self.resolveType(rt) else .void;
    const params_slice = params.toOwnedSlice(self.alloc) catch return;

    _ = self.builder.beginFunction(name_id, params_slice, ret_ty);
    const func = self.builder.currentFunc();
    func.linkage = .external;
    func.call_conv = .c;
    func.has_implicit_ctx = false;

    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);

    // Call @<Cls>.<method>(default_ctx, ...user_args).
    const body_name = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ fcd.name, md.name }) catch return;
    defer self.alloc.free(body_name);
    const body_fid = self.resolveFuncByName(body_name) orelse return;

    const ctx_ref: ?Ref = blk: {
        if (!self.implicit_ctx_enabled) break :blk null;
        const dctx_gi = self.program_index.global_names.get("__sx_default_context") orelse break :blk null;
        break :blk self.builder.emit(.{ .global_addr = dctx_gi.id }, ptr_void);
    };

    const num_user_args = params_slice.len - 2; // minus cls + _cmd
    const num_call_args = (if (ctx_ref != null) @as(usize, 1) else 0) + num_user_args;
    const call_args = self.alloc.alloc(Ref, num_call_args) catch return;
    var idx: usize = 0;
    if (ctx_ref) |c_ref| {
        call_args[idx] = c_ref;
        idx += 1;
    }
    var ip: usize = 2;
    while (ip < params_slice.len) : (ip += 1) {
        call_args[idx] = Ref.fromIndex(@intCast(ip));
        idx += 1;
    }

    const call_ref = self.builder.emit(.{ .call = .{
        .callee = body_fid,
        .args = call_args,
    } }, ret_ty);

    if (ret_ty == .void) self.builder.retVoid() else self.builder.ret(call_ref, ret_ty);
    self.builder.finalize();
}

/// Synthesize the `-dealloc` IMP for an sx-defined `#objc_class`.
/// Runs when the Obj-C runtime drops the last retain on an instance.
///
/// C-ABI: `(self: id, _cmd: SEL) -> void`. No implicit sx ctx.
///
/// Body (M4.0c):
///   %state     = object_getIvar(self, load @__<Cls>_state_ivar)
///   %allocator = load struct_gep(state, 0)          ← __sx_allocator (M4.0a)
///   allocator.dealloc(state)                         ← via inline-protocol fn-ptr
///   object_setIvar(self, ivar, null)
///   [super dealloc]   // objc_msgSendSuper2(&super, sel_dealloc)
///   ret void
///
/// The state struct's first field is the allocator captured at
/// +alloc time (M4.0a + M4.0b). Reading it back lets -dealloc free
/// through the same allocator the instance was constructed with —
/// the per-instance allocator design from M1.2 A.5, now realised.
pub fn emitObjcDefinedClassDeallocImp(self: *Lowering, fcd: *const ast.RuntimeClassDecl) void {
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    defer {
        self.builder.func = saved_func;
        self.builder.current_block = saved_block;
        self.builder.inst_counter = saved_counter;
    }

    const imp_name = std.fmt.allocPrint(self.alloc, "__{s}_dealloc_imp", .{fcd.name}) catch return;
    const name_id = self.module.types.internString(imp_name);
    const ptr_void = self.module.types.ptrTo(.void);

    var params = std.ArrayList(inst_mod.Function.Param).empty;
    params.append(self.alloc, .{ .name = self.module.types.internString("self"), .ty = ptr_void }) catch return;
    params.append(self.alloc, .{ .name = self.module.types.internString("_cmd"), .ty = ptr_void }) catch return;
    const params_slice = params.toOwnedSlice(self.alloc) catch return;

    _ = self.builder.beginFunction(name_id, params_slice, .void);
    const func = self.builder.currentFunc();
    func.linkage = .external;
    func.call_conv = .c;
    func.has_implicit_ctx = false;

    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);

    const self_ref = Ref.fromIndex(0);

    // (1) state = object_getIvar(self, load @__<Cls>_state_ivar)
    const ivar_global_name = std.fmt.allocPrint(self.alloc, "__{s}_state_ivar", .{fcd.name}) catch return;
    defer self.alloc.free(ivar_global_name);
    const ivar_global_id = self.lookupGlobalIdByName(ivar_global_name) orelse return;
    const ivar_addr = self.builder.emit(.{ .global_addr = ivar_global_id }, ptr_void);
    const ivar_handle = self.builder.load(ivar_addr, ptr_void);

    const get_ivar_fid = self.ensureCRuntimeDecl("object_getIvar", &.{ ptr_void, ptr_void }, ptr_void);
    const get_args = self.alloc.alloc(Ref, 2) catch return;
    get_args[0] = self_ref;
    get_args[1] = ivar_handle;
    const state = self.builder.emit(.{ .call = .{ .callee = get_ivar_fid, .args = get_args } }, ptr_void);

    // (2) M4.B dealloc — release strong/copy property ivars and
    // destroyWeak weak property ivars BEFORE freeing the state struct
    // (which would invalidate the pointers we need to read). Property
    // metadata is re-derived from `fcd.members`; the state struct is
    // already interned via objcDefinedStateStructType.
    const state_struct_ty = self.objc().objcDefinedStateStructType(fcd);
    const state_info_check = self.module.types.get(state_struct_ty);
    if (state_info_check == .@"struct") {
        const state_fields = state_info_check.@"struct".fields;
        for (fcd.members) |m| switch (m) {
            .field => |f| {
                if (!f.is_property) continue;
                // Find the field index in the state struct (by name —
                // M4.0a's prepended __sx_allocator shifted user fields).
                const field_name_id = self.module.types.internString(f.name);
                var pfidx: ?u32 = null;
                for (state_fields, 0..) |sf, i| {
                    if (sf.name == field_name_id) {
                        pfidx = @intCast(i);
                        break;
                    }
                }
                const fidx = pfidx orelse continue;
                const field_ty = self.resolveType(f.field_type);
                const kind = self.objc().objcPropertyKind(f);

                switch (kind) {
                    .assign => {}, // no ARC ops
                    .strong, .copy => {
                        // val = load field; objc_release(val) — release(NULL) is a no-op.
                        self.ensureArcRuntimeDecls();
                        const release_fid = self.ensureCRuntimeDecl("objc_release", &.{ptr_void}, .void);
                        const field_addr = self.builder.emit(.{ .struct_gep = .{
                            .base = state,
                            .field_index = fidx,
                            .base_type = state_struct_ty,
                        } }, ptr_void);
                        const val = self.builder.load(field_addr, field_ty);
                        const args = self.alloc.alloc(Ref, 1) catch continue;
                        args[0] = val;
                        _ = self.builder.emit(.{ .call = .{ .callee = release_fid, .args = args } }, .void);
                    },
                    .weak => {
                        // objc_destroyWeak(&field) — unregisters the slot
                        // from libobjc's side-table.
                        self.ensureArcRuntimeDecls();
                        const destroy_weak_fid = self.ensureCRuntimeDecl("objc_destroyWeak", &.{ptr_void}, .void);
                        const field_addr = self.builder.emit(.{ .struct_gep = .{
                            .base = state,
                            .field_index = fidx,
                            .base_type = state_struct_ty,
                        } }, ptr_void);
                        const args = self.alloc.alloc(Ref, 1) catch continue;
                        args[0] = field_addr;
                        _ = self.builder.emit(.{ .call = .{ .callee = destroy_weak_fid, .args = args } }, .void);
                    },
                }
            },
            else => {},
        };
    }

    // (3) Free state through the captured allocator (M4.0a + M4.0b):
    //       allocator = load struct_gep(state, 0)   ← __sx_allocator field
    //       allocator.dealloc(state)                 ← inline-protocol fn-ptr at field 2
    // Compare to the old `free(state)` — that ignored the per-instance
    // allocator and went straight to libc. Now `push Context.{ allocator = arena }`
    // round-trips correctly: arena.alloc on construction, arena.dealloc here.
    if (self.module.types.findByName(self.module.types.internString("Context")) == null) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, ast.Span{ .start = 0, .end = 0 }, "emitObjcDefinedClassDeallocImp: Context type not found for class '{s}' (compiler bug)", .{fcd.name});
        }
        return;
    }
    // The Allocator protocol type, resolved by NAME from the assembled
    // Context (the state struct's own `__sx_allocator` slot stays index 0 —
    // that is the state struct's layout, not Context's).
    const allocator_ty = (self.contextFieldByName("allocator") orelse {
        if (self.diagnostics) |d| {
            d.addFmt(.err, ast.Span{ .start = 0, .end = 0 }, "emitObjcDefinedClassDeallocImp: Context has no 'allocator' field for class '{s}'", .{fcd.name});
        }
        return;
    }).ty;

    const state_alloc_addr = self.builder.emit(.{ .struct_gep = .{
        .base = state,
        .field_index = 0,
        .base_type = state_struct_ty,
    } }, ptr_void);
    const allocator = self.builder.load(state_alloc_addr, allocator_ty);

    // Default-context address for the implicit __sx_ctx the dealloc
    // fn-ptr takes as its first arg (the dealloc body might allocate
    // internally; default GPA is the safe baseline).
    const default_ctx_gi = self.program_index.global_names.get("__sx_default_context") orelse {
        if (self.diagnostics) |d| {
            d.addFmt(.err, ast.Span{ .start = 0, .end = 0 }, "emitObjcDefinedClassDeallocImp: __sx_default_context global missing for class '{s}'", .{fcd.name});
        }
        return;
    };
    const default_ctx_addr = self.builder.emit(.{ .global_addr = default_ctx_gi.id }, ptr_void);
    const alloc_ctx = self.builder.structGet(allocator, 0, ptr_void);
    const dealloc_fn_ptr = self.builder.structGet(allocator, 3, ptr_void);
    const dealloc_args = self.alloc.dupe(Ref, &.{ default_ctx_addr, alloc_ctx, state }) catch return;
    _ = self.builder.emit(.{ .call_indirect = .{
        .callee = dealloc_fn_ptr,
        .args = dealloc_args,
    } }, .void);

    // (3) object_setIvar(self, ivar, null)
    const set_ivar_fid = self.ensureCRuntimeDecl("object_setIvar", &.{ ptr_void, ptr_void, ptr_void }, .void);
    const null_ptr = self.builder.constInt(0, ptr_void);
    const set_args = self.alloc.alloc(Ref, 3) catch return;
    set_args[0] = self_ref;
    set_args[1] = ivar_handle;
    set_args[2] = null_ptr;
    _ = self.builder.emit(.{ .call = .{ .callee = set_ivar_fid, .args = set_args } }, .void);

    // (4) [super dealloc]
    //
    // objc_super = struct { receiver: id, super_class: Class }
    const super_struct_ty = self.module.types.intern(.{ .@"struct" = .{
        .name = self.module.types.internString("__sx_objc_super"),
        .fields = blk: {
            var f = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
            f.append(self.alloc, .{ .name = self.module.types.internString("receiver"), .ty = ptr_void }) catch unreachable;
            f.append(self.alloc, .{ .name = self.module.types.internString("super_class"), .ty = ptr_void }) catch unreachable;
            break :blk f.toOwnedSlice(self.alloc) catch unreachable;
        },
    } });
    const super_alloca = self.builder.alloca(super_struct_ty);

    // store receiver
    const recv_gep = self.builder.emit(.{ .struct_gep = .{ .base = super_alloca, .field_index = 0, .base_type = super_struct_ty } }, ptr_void);
    self.builder.store(recv_gep, self_ref);

    // store super_class = load @__<Cls>_class
    const class_global_name = std.fmt.allocPrint(self.alloc, "__{s}_class", .{fcd.name}) catch return;
    defer self.alloc.free(class_global_name);
    const class_global_id = self.lookupGlobalIdByName(class_global_name) orelse return;
    const class_addr = self.builder.emit(.{ .global_addr = class_global_id }, ptr_void);
    const class_val = self.builder.load(class_addr, ptr_void);
    const cls_gep = self.builder.emit(.{ .struct_gep = .{ .base = super_alloca, .field_index = 1, .base_type = super_struct_ty } }, ptr_void);
    self.builder.store(cls_gep, class_val);

    // sel_dealloc = sel_registerName("dealloc")
    const sel_reg_fid = self.ensureCRuntimeDecl("sel_registerName", &.{ptr_void}, ptr_void);
    const sel_str_gid = self.internStringConstantGlobal("dealloc");
    const sel_str_addr = self.builder.emit(.{ .global_addr = sel_str_gid }, ptr_void);
    const sel_args = self.alloc.alloc(Ref, 1) catch return;
    sel_args[0] = sel_str_addr;
    const sel_dealloc = self.builder.emit(.{ .call = .{ .callee = sel_reg_fid, .args = sel_args } }, ptr_void);

    // objc_msgSendSuper2(&super, sel_dealloc)
    const send_super_fid = self.ensureCRuntimeDecl("objc_msgSendSuper2", &.{ ptr_void, ptr_void }, .void);
    const send_args = self.alloc.alloc(Ref, 2) catch return;
    send_args[0] = super_alloca;
    send_args[1] = sel_dealloc;
    _ = self.builder.emit(.{ .call = .{ .callee = send_super_fid, .args = send_args } }, .void);

    self.builder.retVoid();
    self.builder.finalize();
}

/// Intern a C-string constant as a `[N:0]u8` global and return
/// its GlobalId. Used by IMP trampolines that need to pass a
/// literal string to runtime helpers (e.g. selector names).
pub fn internStringConstantGlobal(self: *Lowering, s: []const u8) inst_mod.GlobalId {
    const z = self.alloc.allocSentinel(u8, s.len, 0) catch unreachable;
    @memcpy(z[0..s.len], s);
    const arr_ty = self.module.types.arrayOf(.u8, @intCast(s.len + 1));
    const slot_name = std.fmt.allocPrint(self.alloc, "__sx_objc_cstr_{s}", .{s}) catch unreachable;
    const name_id = self.module.types.internString(slot_name);
    if (self.lookupGlobalIdByName(slot_name)) |existing| {
        self.alloc.free(z);
        return existing;
    }
    var bytes_vec = std.ArrayList(inst_mod.ConstantValue).empty;
    for (z[0 .. s.len + 1]) |b| {
        bytes_vec.append(self.alloc, .{ .int = b }) catch unreachable;
    }
    const init_val: inst_mod.ConstantValue = .{ .aggregate = bytes_vec.toOwnedSlice(self.alloc) catch unreachable };
    return self.module.addGlobal(.{
        .name = name_id,
        .ty = arr_ty,
        .init_val = init_val,
        .is_extern = false,
        .is_const = true,
    });
}

/// Linear scan over module globals for a given name. Used for
/// looking up the per-class ivar handle global from inside IMP
/// trampoline emission.
pub fn lookupGlobalIdByName(self: *Lowering, name: []const u8) ?inst_mod.GlobalId {
    const name_id = self.module.types.internString(name);
    for (self.module.globals.items, 0..) |g, i| {
        if (g.name == name_id) return inst_mod.GlobalId.fromIndex(@intCast(i));
    }
    return null;
}
