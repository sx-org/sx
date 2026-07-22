const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const mod_mod = @import("../module.zig");
const type_bridge = @import("../type_bridge.zig");
const jni_descriptor = @import("../jni_descriptor.zig");
const ObjcLowering = @import("../ffi_objc.zig").ObjcLowering;

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;
const Module = mod_mod.Module;


const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const Scope = lower.Scope;

/// Intern an Obj-C selector string into a module-scoped `SEL*` slot.
/// First call creates the global; subsequent calls return the same
/// `GlobalId`. emit_llvm.zig walks `module.objc_selector_cache` and
/// synthesizes a constructor that populates each slot via
/// `sel_registerName` exactly once at module load.
///
/// Slot name matches clang's convention: `OBJC_SELECTOR_REFERENCES_<sel>`
/// with `:` replaced by `_` to keep the symbol name valid.
pub fn internObjcSelector(self: *Lowering, sel_str: []const u8) inst_mod.GlobalId {
    if (self.module.lookupObjcSelector(sel_str)) |gid| return gid;

    // Mangle selector: replace colons with underscores. Apple's
    // toolchain does the same (foo:bar: → foo_bar_).
    var mangled = std.ArrayList(u8).empty;
    defer mangled.deinit(self.alloc);
    mangled.appendSlice(self.alloc, "OBJC_SELECTOR_REFERENCES_") catch unreachable;
    for (sel_str) |ch| {
        mangled.append(self.alloc, if (ch == ':') '_' else ch) catch unreachable;
    }
    const slot_name = self.module.types.internString(mangled.items);
    const vptr_ty = self.module.types.ptrTo(.void);
    const gid = self.module.addGlobal(.{
        .name = slot_name,
        .ty = vptr_ty,
        .init_val = .null_val,
        .is_extern = false,
        .is_const = false,
    });
    self.module.appendObjcSelector(sel_str, gid);
    return gid;
}

/// Intern an Obj-C class name into a module-scoped `Class*` slot.
/// First call creates the global; subsequent calls return the same
/// `GlobalId`. emit_llvm.zig walks `module.objc_class_cache` and
/// synthesizes a constructor that populates each slot via
/// `objc_getClass` exactly once at module load.
///
/// Slot name matches clang's convention: `OBJC_CLASSLIST_REFERENCES_<Cls>`.
pub fn internObjcClassObject(self: *Lowering, class_name: []const u8) inst_mod.GlobalId {
    if (self.module.lookupObjcClass(class_name)) |gid| return gid;

    var mangled = std.ArrayList(u8).empty;
    defer mangled.deinit(self.alloc);
    mangled.appendSlice(self.alloc, "OBJC_CLASSLIST_REFERENCES_") catch unreachable;
    mangled.appendSlice(self.alloc, class_name) catch unreachable;
    const slot_name = self.module.types.internString(mangled.items);
    const vptr_ty = self.module.types.ptrTo(.void);
    const gid = self.module.addGlobal(.{
        .name = slot_name,
        .ty = vptr_ty,
        .init_val = .null_val,
        .is_extern = false,
        .is_const = false,
    });
    self.module.appendObjcClass(class_name, gid);
    return gid;
}

/// Lazily declare `sel_registerName(name: *u8) -> *void` as an extern.
/// Cached per Lowering instance so multiple `#objc_call` sites share
/// one declaration.
pub fn getSelRegisterNameFid(self: *Lowering) FuncId {
    if (self.sel_register_name_fid) |fid| return fid;
    var params = std.ArrayList(inst_mod.Function.Param).empty;
    const name_str = self.module.types.internString("name");
    const ptr_ty = self.module.types.ptrTo(.u8);
    params.append(self.alloc, .{ .name = name_str, .ty = ptr_ty }) catch unreachable;
    const fn_name = self.module.types.internString("sel_registerName");
    const ret_ty = self.module.types.ptrTo(.void);
    const fid = self.builder.declareExtern(fn_name, params.toOwnedSlice(self.alloc) catch unreachable, ret_ty);
    const func = self.module.getFunctionMut(fid);
    func.call_conv = .c;
    self.sel_register_name_fid = fid;
    return fid;
}

/// Lower `#objc_call(T)(recv, "sel:", args...)` to:
///   %sel = call ptr @sel_registerName(<"sel:">)
///   %ret = call <ABI(T)> @objc_msgSend(recv, %sel, args...)
/// For Phase 1.3 only the (void return, no extra args) form is
/// fully wired. Extra arities + non-void returns will land in
/// subsequent phase-1 steps.
pub fn lowerFfiIntrinsicCall(self: *Lowering, fic: *const ast.FfiIntrinsicCall) Ref {
    if (fic.kind == .jni_call or fic.kind == .jni_static_call) {
        return self.lowerJniCall(fic);
    }

    if (fic.args.len < 2) {
        if (self.diagnostics) |d| {
            d.add(.err, "#objc_call requires at least a receiver and a selector", null);
        }
        return Ref.none;
    }

    // Resolve the return type from the syntactic slot.
    const ret_ty = self.resolveType(fic.return_type);

    if (fic.args.len < 2) {
        if (self.diagnostics) |d| {
            d.add(.err, "#objc_call requires at least a receiver and a selector", null);
        }
        return Ref.none;
    }

    // Receiver expression.
    const recv = self.lowerExpr(fic.args[0]);

    // Selector. Literal selectors get interned into a module-
    // scoped `SEL*` slot — emit_llvm.zig tags the slot into
    // `__DATA,__objc_selrefs` so dyld populates it at load time
    // (matches clang's `@selector(...)` lowering exactly).
    // Non-literal selectors keep the per-call `sel_registerName`
    // fallback.
    const sel_arg_node = fic.args[1];
    const vptr_ty = self.module.types.ptrTo(.void);
    const sel = blk: {
        if (sel_arg_node.data == .string_literal) {
            const raw = sel_arg_node.data.string_literal.raw;
            const slot_gid = self.internObjcSelector(raw);
            const slot_ptr = self.builder.emit(.{ .global_addr = slot_gid }, self.module.types.ptrTo(vptr_ty));
            break :blk self.builder.emit(.{ .load = .{ .operand = slot_ptr } }, vptr_ty);
        }
        const sel_ref = self.lowerExpr(sel_arg_node);
        const sel_fid = self.getSelRegisterNameFid();
        var sel_args = std.ArrayList(Ref).empty;
        sel_args.append(self.alloc, sel_ref) catch unreachable;
        const sel_owned = sel_args.toOwnedSlice(self.alloc) catch unreachable;
        break :blk self.builder.emit(.{ .call = .{ .callee = sel_fid, .args = sel_owned } }, vptr_ty);
    };

    // Additional args after recv + selector.
    var extra = std.ArrayList(Ref).empty;
    var ai: usize = 2;
    while (ai < fic.args.len) : (ai += 1) {
        extra.append(self.alloc, self.lowerExpr(fic.args[ai])) catch unreachable;
    }
    const extra_owned = extra.toOwnedSlice(self.alloc) catch unreachable;

    return self.builder.emit(.{ .objc_msg_send = .{
        .recv = recv,
        .sel = sel,
        .args = extra_owned,
    } }, ret_ty);
}

pub fn lowerJniCall(self: *Lowering, fic: *const ast.FfiIntrinsicCall) Ref {
    // env is always implicit: lexical-direct from the enclosing `#jni_env(env)`
    // block (2.16b, cheap), else the thread-local slot the block populated
    // at runtime (2.16c, one TL load per call). Surface form is uniform:
    //   #jni_call(T)(target, "name", "sig", method-args...)        (≥3 args)
    if (fic.args.len < 3) {
        if (self.diagnostics) |d| {
            d.add(.err, "#jni_call requires target, method name, and signature", null);
        }
        return Ref.none;
    }

    const ret_ty = self.resolveType(fic.return_type);

    const env_ref = if (self.jni_env_stack.items.len > self.jni_env_stack_base)
        self.jni_env_stack.items[self.jni_env_stack.items.len - 1]
    else blk: {
        const fids = self.getJniEnvTlFids();
        const ptr_ty = self.module.types.ptrTo(.void);
        break :blk self.builder.emit(.{ .call = .{ .callee = fids.get, .args = &.{} } }, ptr_ty);
    };

    const target_idx: usize = 0;
    const name_idx: usize = 1;
    const sig_idx: usize = 2;
    const first_method_arg_idx: usize = 3;

    const target_ref = self.lowerExpr(fic.args[target_idx]);
    const name_node = fic.args[name_idx];
    const sig_node = fic.args[sig_idx];
    const name_ref = self.lowerExpr(name_node);
    const sig_ref = self.lowerExpr(sig_node);

    // Capture the (name, sig) literal content when both args are
    // string literals — emit_llvm uses this as the intern key for
    // the shared `jclass`/`jmethodID` slot pair (step 1.17).
    const cache_key: ?inst_mod.CacheKey = if (name_node.data == .string_literal and sig_node.data == .string_literal)
        inst_mod.CacheKey{
            .name_str = name_node.data.string_literal.raw,
            .sig_str = sig_node.data.string_literal.raw,
        }
    else
        null;

    var extra = std.ArrayList(Ref).empty;
    var ai: usize = first_method_arg_idx;
    while (ai < fic.args.len) : (ai += 1) {
        extra.append(self.alloc, self.lowerExpr(fic.args[ai])) catch unreachable;
    }
    const extra_owned = extra.toOwnedSlice(self.alloc) catch unreachable;

    return self.builder.emit(.{ .jni_msg_send = .{
        .env = env_ref,
        .target = target_ref,
        .name = name_ref,
        .sig = sig_ref,
        .args = extra_owned,
        .is_static = fic.kind == .jni_static_call,
        .cache_key = cache_key,
    } }, ret_ty);
}

/// Lower an `inst.method(args)` call where `inst`'s type is a runtime-class
/// alias declared by `#jni_class("...") { ... }` (or its parallel forms).
/// JNI runtimes lower directly to `jni_msg_send` with a descriptor derived
/// from the method's sx signature; Obj-C / Swift runtimes are deferred to
/// Phase 3/4 and currently surface a clear diagnostic.
pub fn lowerRuntimeMethodCall(
    self: *Lowering,
    fcd: *const ast.RuntimeClassDecl,
    method_name: []const u8,
    target: Ref,
    method_args: []const Ref,
    span: ast.Span,
) Ref {
    // M2.3 — walk the `#extends` chain when the method isn't
    // declared directly on this fcd. The dispatch target stays
    // the original receiver — objc_msgSend's runtime walks the
    // class hierarchy by isa, so we just need to find ANY
    // ancestor that declared the method (for the selector
    // mangling + signature info). The receiver-class fcd is
    // still used for `*Self` substitution at the dispatch site
    // — the inherited method's *Self should resolve to the
    // child receiver, not the parent.
    const found = self.findRuntimeMethodInChain(fcd, method_name) orelse {
        if (self.diagnostics) |d| {
            d.addFmt(.err, span, "no method '{s}' on runtime class '{s}' (or any `#extends` ancestor)", .{ method_name, fcd.name });
        }
        return Ref.none;
    };
    const method = found.method;

    // Obj-C instance dispatch (Phase 3 step 3.0 + M1.2 A.7).
    // `inst.method(args)` on an `#objc_class` / `#objc_protocol`
    // receiver derives a selector from the sx method name (default
    // mangling: split on `_`, each piece becomes a keyword with a
    // trailing `:`; niladic stays verbatim) and lowers to
    // `objc_msg_send`. Both runtime and sx-defined classes flow
    // through the same path — sx-defined classes have their IMPs
    // registered at module-init (M1.2 A.4b.iii) so `objc_msgSend`
    // finds them. The Swift runtimes still bail — Phase 4.
    if (fcd.runtime == .objc_class or fcd.runtime == .objc_protocol) {
        return self.lowerObjcMethodCall(fcd, method, target, method_args, span);
    }
    if (!fcd.is_extern) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, span, "sx-defined classes on non-Obj-C runtimes can't yet be dispatched into (class '{s}', runtime '{s}')", .{ fcd.name, @tagName(fcd.runtime) });
        }
        return Ref.none;
    }
    if (fcd.runtime != .jni_class and fcd.runtime != .jni_interface) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, span, "method calls on '{s}' runtime not yet supported (Phase 3/4)", .{@tagName(fcd.runtime)});
        }
        return Ref.none;
    }

    if (self.jni_env_stack.items.len == 0) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, span, "method call on '{s}' requires an enclosing '#jni_env' scope", .{fcd.name});
        }
        return Ref.none;
    }
    const env_ref = self.jni_env_stack.items[self.jni_env_stack.items.len - 1];

    // Build a ClassRegistry snapshot so descriptor derivation can
    // resolve `*Foo` cross-class refs to their runtime paths.
    var registry = jni_descriptor.ClassRegistry.init(self.alloc);
    defer registry.deinit();
    var it = self.program_index.runtime_class_map.iterator();
    while (it.next()) |entry| {
        registry.put(entry.key_ptr.*, entry.value_ptr.*.runtime_path) catch {};
    }

    const desc_str = jni_descriptor.deriveMethod(self.alloc, .{
        .enclosing_path = fcd.runtime_path,
        .classes = &registry,
    }, method) catch |err| {
        if (self.diagnostics) |d| {
            d.addFmt(.err, span, "JNI descriptor derivation failed for '{s}.{s}': {s}", .{ fcd.name, method.name, @errorName(err) });
        }
        return Ref.none;
    };

    const name_sid = self.module.types.internString(method_name);
    const name_ref = self.builder.constString(name_sid);
    const sig_sid = self.module.types.internString(desc_str);
    const sig_ref = self.builder.constString(sig_sid);

    const ret_ty = if (method.return_type) |rt| self.resolveType(rt) else .void;

    // Reject return types the JNI emit path can't dispatch — emit_llvm's
    // Call<T>Method switch only covers void / bool / i32 / i64 / f32 / f64
    // / pointer-returning. Anything else (i8 / i16 / u8 / u16 / aggregates)
    // would silently lower to LLVMGetUndef and produce wrong arguments at
    // the call site (chess Android touch shipped broken because i32→i32+
    // f32 returns hit the undef path before .f32 was wired up).
    if (!jni_descriptor.isJniReturnTypeSupported(&self.module.types, ret_ty)) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, span, "JNI method '{s}.{s}' returns '{s}', which isn't supported by the JNI call-method lowering yet — only void/bool/i32/i64/f32/f64 and pointers are wired up", .{ fcd.name, method.name, self.module.types.typeName(ret_ty) });
        }
        return Ref.none;
    }

    const cache_key: inst_mod.CacheKey = .{
        .name_str = method_name,
        .sig_str = desc_str,
    };

    const args_owned = self.alloc.dupe(Ref, method_args) catch unreachable;
    return self.builder.emit(.{ .jni_msg_send = .{
        .env = env_ref,
        .target = target,
        .name = name_ref,
        .sig = sig_ref,
        .args = args_owned,
        .is_static = method.is_static,
        .cache_key = cache_key,
    } }, ret_ty);
}

// Pure Obj-C decision helpers (selector derivation, type-encoding, ARC
// property-kind, class-pointer recognition, state-struct planning) live in
// `ffi_objc.zig` (`ObjcLowering`, a `*Lowering` facade). Reached via
// `self.objc()`. Emission-heavy IMP builders live in lower/objc_class.zig;
// the `lowerObjc*Call` lowering paths are below.

/// Resolve a runtime-class member type, substituting `Self` (and `*Self`)
/// with the runtime class's own struct type. Without this substitution
/// chained calls like `Cls.alloc().init()` see the inner result as a
/// fictitious `Self` struct and the next dispatch lookup fails.
pub fn resolveRuntimeClassMemberType(
    self: *Lowering,
    fcd: *const ast.RuntimeClassDecl,
    type_node: *const ast.Node,
) TypeId {
    if (type_node.data == .type_expr and std.mem.eql(u8, type_node.data.type_expr.name, "Self")) {
        return self.runtimeClassStructType(fcd);
    }
    if (type_node.data == .pointer_type_expr) {
        const pt = type_node.data.pointer_type_expr;
        if (pt.pointee_type.data == .type_expr and std.mem.eql(u8, pt.pointee_type.data.type_expr.name, "Self")) {
            return self.module.types.ptrTo(self.runtimeClassStructType(fcd));
        }
    }
    return self.resolveType(type_node);
}

pub fn resolveRuntimeMethodReturnType(
    self: *Lowering,
    fcd: *const ast.RuntimeClassDecl,
    method: ast.RuntimeMethodDecl,
) TypeId {
    const rt = method.return_type orelse return .void;
    return self.resolveRuntimeClassMemberType(fcd, rt);
}

pub fn runtimeClassStructType(self: *Lowering, fcd: *const ast.RuntimeClassDecl) TypeId {
    const name_id = self.module.types.internString(fcd.name);
    if (self.module.types.findByName(name_id)) |existing| return existing;
    return self.module.types.intern(.{ .@"struct" = .{ .name = name_id, .fields = &.{} } });
}

/// Lower `inst.method(args)` on an `#objc_class` / `#objc_protocol`
/// receiver. The selector is derived by `deriveObjcSelector`; arity
/// is validated against the keyword count produced by the mangling
/// (excluding self). Dispatch then runs through `objc_msg_send`,
/// sharing the cached-SEL slot path with explicit `#objc_call`.
pub fn lowerObjcMethodCall(
    self: *Lowering,
    fcd: *const ast.RuntimeClassDecl,
    method: ast.RuntimeMethodDecl,
    target: Ref,
    method_args: []const Ref,
    span: ast.Span,
) Ref {
    const arity = method_args.len;
    const derived = self.objc().deriveObjcSelector(method, arity);

    // Arity validation: the keyword count (number of `:` in the
    // selector) must equal the number of args passed at the call
    // site. For methods using the default mangling rule, a mismatch
    // is an error because the user can fix the sx-side name. For
    // `#selector("...")` overrides, the user has deliberately
    // chosen the selector — downgrade to a warning so the build
    // proceeds, but still surface the typo case (Obj-C's runtime
    // doesn't validate colon-vs-arg, so this is the last defense).
    if (arity > 0 and derived.keyword_count != arity) {
        if (self.diagnostics) |d| {
            if (derived.is_override) {
                d.addFmt(
                    .warn,
                    span,
                    "Obj-C selector \"{s}\" (override for '{s}.{s}') has {} keyword(s) but the call passes {} argument(s); the runtime will dispatch but the colon count is inconsistent with the arity — double-check the selector string",
                    .{ derived.sel, fcd.name, method.name, derived.keyword_count, arity },
                );
            } else {
                d.addFmt(
                    .err,
                    span,
                    "Obj-C selector for '{s}.{s}' has {} keyword(s) but the call passes {} argument(s); split the sx method name on '_' so it produces exactly {} keyword(s), or override with `#selector(\"...\")`",
                    .{ fcd.name, method.name, derived.keyword_count, arity, arity },
                );
                return Ref.none;
            }
        }
    }

    const ret_ty = self.resolveRuntimeMethodReturnType(fcd, method);

    // Cache the SEL slot per (selector-string, module) like
    // `#objc_call` does. The mangling produces the literal selector
    // string; we don't need a runtime sel_registerName call at the
    // dispatch site because the global initializer already does it.
    const vptr_ty = self.module.types.ptrTo(.void);
    const slot_gid = self.internObjcSelector(derived.sel);
    const slot_ptr = self.builder.emit(.{ .global_addr = slot_gid }, self.module.types.ptrTo(vptr_ty));
    const sel = self.builder.emit(.{ .load = .{ .operand = slot_ptr } }, vptr_ty);

    const args_owned = self.alloc.dupe(Ref, method_args) catch unreachable;
    return self.builder.emit(.{ .objc_msg_send = .{
        .recv = target,
        .sel = sel,
        .args = args_owned,
    } }, ret_ty);
}

/// Lower `Cls.static_method(args)` on an `#objc_class` /
/// `#objc_protocol` alias. Loads the class object through the
/// module-scoped cached slot (populated by `objc_getClass` at
/// module-init) and dispatches `objc_msg_send` with the same
/// selector mangling as instance methods (Phase 3.0).
pub fn lowerObjcStaticCall(
    self: *Lowering,
    fcd: *const ast.RuntimeClassDecl,
    method: ast.RuntimeMethodDecl,
    method_args: []const Ref,
    span: ast.Span,
) Ref {
    const arity = method_args.len;
    const derived = self.objc().deriveObjcSelector(method, arity);

    if (arity > 0 and derived.keyword_count != arity) {
        if (self.diagnostics) |d| {
            if (derived.is_override) {
                d.addFmt(
                    .warn,
                    span,
                    "Obj-C selector \"{s}\" (override for static call '{s}.{s}') has {} keyword(s) but the call passes {} argument(s); the runtime will dispatch but the colon count is inconsistent with the arity — double-check the selector string",
                    .{ derived.sel, fcd.name, method.name, derived.keyword_count, arity },
                );
            } else {
                d.addFmt(
                    .err,
                    span,
                    "Obj-C selector for static call '{s}.{s}' has {} keyword(s) but the call passes {} argument(s); split the sx method name on '_' so it produces exactly {} keyword(s), or override with `#selector(\"...\")`",
                    .{ fcd.name, method.name, derived.keyword_count, arity, arity },
                );
                return Ref.none;
            }
        }
    }

    const ret_ty = self.resolveRuntimeMethodReturnType(fcd, method);

    const vptr_ty = self.module.types.ptrTo(.void);

    // Load the class object from its module-scoped cached slot.
    // `objc_getClass(<name>)` runs once at module-init via the
    // constructor emit_llvm synthesizes (see `emitObjcClassInit`).
    const class_slot_gid = self.internObjcClassObject(fcd.runtime_path);
    const class_slot_ptr = self.builder.emit(.{ .global_addr = class_slot_gid }, self.module.types.ptrTo(vptr_ty));
    const class_obj = self.builder.emit(.{ .load = .{ .operand = class_slot_ptr } }, vptr_ty);

    // M4.0b: intercept `Cls.alloc()` for sx-defined classes — emit the
    // inline alloc-and-init sequence using the caller's `context.allocator`
    // instead of going through `objc_msgSend` (which would land in the
    // +alloc IMP and use `__sx_default_context.allocator`). This honors
    // a surrounding `push Context.{ allocator = ... }`.
    if (!fcd.is_extern and
        fcd.runtime == .objc_class and
        method_args.len == 0 and
        std.mem.eql(u8, method.name, "alloc"))
    {
        const ctx_addr = if (self.current_ctx_ref != Ref.none)
            self.current_ctx_ref
        else blk: {
            // Fallback: no current ctx (e.g. compiler-internal callers).
            // Use the default context — same as the IMP would.
            const default_ctx_gi = self.program_index.global_names.get("__sx_default_context") orelse {
                if (self.diagnostics) |d| {
                    d.addFmt(.err, span, "Cls.alloc() on sx-defined class '{s}': no current context and __sx_default_context missing", .{fcd.name});
                }
                return Ref.none;
            };
            break :blk self.builder.emit(.{ .global_addr = default_ctx_gi.id }, vptr_ty);
        };
        const instance = self.emitObjcDefinedAllocAndInit(fcd, class_obj, ctx_addr) orelse return Ref.none;
        // class_createInstance returns *void; bitcast to the method's
        // declared return type (typically `*<Cls>` or `?*<Cls>`) so
        // downstream `let f := Cls.alloc();` binds f at the right type
        // (lowerVarDecl reads the Ref's IR type when no annotation is
        // present). coerceToType is a no-op for ptr→ptr; we need an
        // explicit bitcast IR op to retype the Ref.
        if (ret_ty == vptr_ty) return instance;
        // Optional-wrapped returns (e.g. `-> ?*Cls`): emit optional_wrap.
        if (!ret_ty.isBuiltin()) {
            const ret_info = self.module.types.get(ret_ty);
            if (ret_info == .optional) {
                const inner = ret_info.optional.child;
                const cast = if (inner == vptr_ty)
                    instance
                else
                    self.builder.emit(.{ .bitcast = .{ .operand = instance, .from = vptr_ty, .to = inner } }, inner);
                return self.builder.optionalWrap(cast, ret_ty);
            }
        }
        return self.builder.emit(.{ .bitcast = .{ .operand = instance, .from = vptr_ty, .to = ret_ty } }, ret_ty);
    }

    // Load the SEL from its slot.
    const sel_slot_gid = self.internObjcSelector(derived.sel);
    const sel_slot_ptr = self.builder.emit(.{ .global_addr = sel_slot_gid }, self.module.types.ptrTo(vptr_ty));
    const sel = self.builder.emit(.{ .load = .{ .operand = sel_slot_ptr } }, vptr_ty);

    const args_owned = self.alloc.dupe(Ref, method_args) catch unreachable;
    return self.builder.emit(.{ .objc_msg_send = .{
        .recv = class_obj,
        .sel = sel,
        .args = args_owned,
    } }, ret_ty);
}

/// Lower `Alias.new(args)` where `Alias` is a runtime-class identifier
/// with `static new :: (...) -> *Self;` — JNI constructor dispatch:
/// `FindClass + GetMethodID("<init>", "(args)V") + NewObject(env,
/// clazz, mid, args...)`. Returns the new jobject.
///
/// Non-`new` static methods aren't supported via this path yet — the
/// user can use `#jni_static_call(T)(class, "name", sig, args...)`
/// for those. Constructor is the common case for #jni_main bodies
/// that need to instantiate Android classes (SurfaceView, etc.).
pub fn lowerRuntimeStaticCall(
    self: *Lowering,
    fcd: *const ast.RuntimeClassDecl,
    method: ast.RuntimeMethodDecl,
    method_args: []const Ref,
    span: ast.Span,
) Ref {
    // Obj-C static dispatch (Phase 3 step 3.1). `Cls.static_method(args)`
    // on an `#objc_class` alias loads the class object through a
    // module-scoped cached slot (populated once per module via
    // `objc_getClass`) and dispatches with the derived selector.
    if (fcd.runtime == .objc_class or fcd.runtime == .objc_protocol) {
        return self.lowerObjcStaticCall(fcd, method, method_args, span);
    }
    if (fcd.runtime != .jni_class and fcd.runtime != .jni_interface) {
        if (self.diagnostics) |d| d.addFmt(.err, span, "static calls on '{s}' runtime not yet supported (Phase 3/4)", .{@tagName(fcd.runtime)});
        return Ref.none;
    }
    if (!std.mem.eql(u8, method.name, "new")) {
        if (self.diagnostics) |d| d.addFmt(.err, span, "static runtime-class call '{s}.{s}' not yet supported via `Alias.method()` syntax \u{2014} only `new` is wired today; use `#jni_static_call` directly for other static methods", .{ fcd.name, method.name });
        return Ref.none;
    }

    if (self.jni_env_stack.items.len <= self.jni_env_stack_base) {
        if (self.diagnostics) |d| d.addFmt(.err, span, "constructor `{s}.new(...)` requires an enclosing `#jni_env` scope (or `#jni_main` body)", .{fcd.name});
        return Ref.none;
    }
    const env_ref = self.jni_env_stack.items[self.jni_env_stack.items.len - 1];

    // Build class registry snapshot for `*Foo` cross-class refs.
    var registry = jni_descriptor.ClassRegistry.init(self.alloc);
    defer registry.deinit();
    var it = self.program_index.runtime_class_map.iterator();
    while (it.next()) |entry| {
        registry.put(entry.key_ptr.*, entry.value_ptr.*.runtime_path) catch {};
    }

    // For `new`, the JNI descriptor's return position is `V` (the
    // constructor returns void; the new jobject comes back from
    // `NewObject` itself). Patch the AST by overriding return_type
    // to null during derivation.
    const m_for_desc: ast.RuntimeMethodDecl = .{
        .name = method.name,
        .params = method.params,
        .param_names = method.param_names,
        .return_type = null,
        .is_static = method.is_static,
        .jni_descriptor_override = method.jni_descriptor_override,
        .body = method.body,
    };

    const descriptor = jni_descriptor.deriveMethod(self.alloc, .{
        .enclosing_path = fcd.runtime_path,
        .classes = &registry,
    }, m_for_desc) catch |err| {
        if (self.diagnostics) |d| d.addFmt(.err, span, "JNI descriptor derivation failed for '{s}.new': {s}", .{ fcd.name, @errorName(err) });
        return Ref.none;
    };

    // sx-side return type is `*Self` — resolve to a pointer to the
    // runtime-class struct type so method dispatch on the new
    // jobject works (`view := SurfaceView.new(ctx); view.getHolder()`).
    // At LLVM level still ptr; the sx type table is what method
    // resolution consults.
    const self_struct_name = self.module.types.internString(fcd.name);
    const self_struct_id = if (self.module.types.findByName(self_struct_name)) |existing|
        existing
    else blk: {
        const info: types.TypeInfo = .{ .@"struct" = .{ .name = self_struct_name, .fields = &.{} } };
        break :blk self.module.types.intern(info);
    };
    const ret_ty = self.module.types.ptrTo(self_struct_id);

    const name_sid = self.module.types.internString("<init>");
    const name_ref = self.builder.constString(name_sid);
    const sig_sid = self.module.types.internString(descriptor);
    const sig_ref = self.builder.constString(sig_sid);

    const args_owned = self.alloc.dupe(Ref, method_args) catch unreachable;
    return self.builder.emit(.{ .jni_msg_send = .{
        .env = env_ref,
        .target = Ref.none, // unused for ctor — class is resolved via parent_class_path
        .name = name_ref,
        .sig = sig_ref,
        .args = args_owned,
        .is_static = false,
        .is_constructor = true,
        .parent_class_path = self.alloc.dupe(u8, fcd.runtime_path) catch fcd.runtime_path,
        .cache_key = null,
    } }, ret_ty);
}

/// Lower `super.method(args)` inside a `#jni_main` / sx-defined
/// `#jni_class` bodied method. Resolves the parent class from the
/// enclosing fcd's `#extends` clause (default `android.app.Activity`)
/// and emits a `JniMsgSend` with `is_nonvirtual=true`, which
/// emit_llvm expands into a `FindClass(parent) + GetMethodID +
/// CallNonvirtual<T>Method` chain.
///
/// Signature derivation: when `method_name` matches the enclosing
/// method's name (the common case — `super.onCreate(b)` from inside
/// `onCreate :: (self, b)` override), the enclosing method's
/// signature is reused. Other method names require the parent class
/// to be declared via `#jni_class(…) extern` so the signature can be
/// looked up.
pub fn lowerSuperCall(
    self: *Lowering,
    method_name: []const u8,
    method_args: []const Ref,
    span: ast.Span,
) Ref {
    const fcd = self.current_runtime_class orelse {
        if (self.diagnostics) |d| d.addFmt(.err, span, "'super' is only valid inside a `#jni_class` method body", .{});
        return Ref.none;
    };

    // Resolve parent runtime_path from the fcd's `#extends`. Default to
    // android.app.Activity to match the jni_java_emit default.
    var parent_path: []const u8 = "android/app/Activity";
    for (fcd.members) |m| switch (m) {
        .extends => |alias| {
            if (self.program_index.runtime_class_map.get(alias)) |parent_fcd| {
                parent_path = parent_fcd.runtime_path;
            } else {
                parent_path = alias;
            }
            break;
        },
        else => {},
    };

    // Resolve method signature. Same-name fast path reuses the
    // enclosing method's descriptor; cross-method super calls require
    // the parent class to be declared via `#jni_class(…) extern`.
    var descriptor: []const u8 = "";
    var resolved_method: ?ast.RuntimeMethodDecl = null;
    if (self.current_runtime_method) |em| {
        if (std.mem.eql(u8, em.name, method_name)) {
            resolved_method = em;
        }
    }
    if (resolved_method == null) {
        const parent_fcd = blk: for (fcd.members) |m| switch (m) {
            .extends => |alias| if (self.program_index.runtime_class_map.get(alias)) |pf| break :blk pf else continue,
            else => {},
        } else null;
        if (parent_fcd) |pf| {
            for (pf.members) |pm| switch (pm) {
                .method => |pmd| if (std.mem.eql(u8, pmd.name, method_name)) {
                    resolved_method = pmd;
                    break;
                },
                else => {},
            };
        }
    }
    const method = resolved_method orelse {
        if (self.diagnostics) |d| d.addFmt(.err, span, "no method '{s}' found for `super.{s}(...)` — declare the parent class via `#jni_class(…) extern` to make cross-method super calls available", .{ method_name, method_name });
        return Ref.none;
    };

    // Derive descriptor against the parent path (used as enclosing_path
    // for `*Self` resolution).
    var registry = jni_descriptor.ClassRegistry.init(self.alloc);
    defer registry.deinit();
    var it = self.program_index.runtime_class_map.iterator();
    while (it.next()) |entry| {
        registry.put(entry.key_ptr.*, entry.value_ptr.*.runtime_path) catch {};
    }
    descriptor = jni_descriptor.deriveMethod(self.alloc, .{
        .enclosing_path = parent_path,
        .classes = &registry,
    }, method) catch |err| {
        if (self.diagnostics) |d| d.addFmt(.err, span, "super-call descriptor derivation failed for '{s}.{s}': {s}", .{ parent_path, method_name, @errorName(err) });
        return Ref.none;
    };

    // env from the lexical stack (pushed by synthesizeJniMainStub).
    if (self.jni_env_stack.items.len <= self.jni_env_stack_base) {
        if (self.diagnostics) |d| d.addFmt(.err, span, "`super.{s}(...)` requires an enclosing `#jni_main` method scope (env is unavailable)", .{method_name});
        return Ref.none;
    }
    const env_ref = self.jni_env_stack.items[self.jni_env_stack.items.len - 1];

    // `self` is the first param of the synthesized `Java_*` fn. Bound
    // in scope as `self` by synthesizeJniMainStub.
    const self_binding = if (self.scope) |s| s.lookup("self") else null;
    const self_ref = if (self_binding) |b| (if (b.is_alloca) self.builder.load(b.ref, b.ty) else b.ref) else Ref.none;

    const name_sid = self.module.types.internString(method_name);
    const name_ref = self.builder.constString(name_sid);
    const sig_sid = self.module.types.internString(descriptor);
    const sig_ref = self.builder.constString(sig_sid);

    const ret_ty = if (method.return_type) |rt| self.resolveType(rt) else .void;

    const args_owned = self.alloc.dupe(Ref, method_args) catch unreachable;
    return self.builder.emit(.{ .jni_msg_send = .{
        .env = env_ref,
        .target = self_ref,
        .name = name_ref,
        .sig = sig_ref,
        .args = args_owned,
        .is_static = false,
        .is_nonvirtual = true,
        .parent_class_path = self.alloc.dupe(u8, parent_path) catch parent_path,
        .cache_key = null, // per-call FindClass + GetMethodID; caching is a follow-up
    } }, ret_ty);
}

// ── Runtime-class registration ──────────────────────────────────

/// Register a runtime-class declaration. The alias goes into
/// `runtime_class_map` for method-dispatch lookup. The underlying
/// type (e.g. `*Activity`) is resolved via the existing struct
/// fallback in `type_bridge.resolveTypeName` (which interns unknown
/// named types as 0-field structs).
///
/// sx-defined Obj-C classes (no `extern`, runtime == .objc_class)
/// also land in `module.objc_defined_class_cache` in declaration
/// order AND have their bodied methods registered into `fn_ast_map`
/// under qualified names `<ClassName>.<methodName>`. Lazy lowering
/// then handles the body via the standard path; `*Self` is
/// substituted to `*<ClassName>State` during body lowering (M1.2 A.2b).
pub fn registerRuntimeClassDecl(self: *Lowering, fcd: *const ast.RuntimeClassDecl) void {
    upsertRuntimeClass(self, fcd.name, fcd);
    if (!fcd.is_extern and fcd.runtime == .objc_class) {
        if (self.module.lookupObjcDefinedClass(fcd.name) == null) {
            self.module.appendObjcDefinedClass(fcd.name, fcd);
            // M2.3 — resolve the `#extends` alias to the actual
            // Obj-C runtime class name. `#extends NSObjectBase`
            // where NSObjectBase is aliased to "NSObject" must
            // pass "NSObject" to objc_allocateClassPair, otherwise
            // the runtime's class-hierarchy link is broken and
            // inherited-method dispatch fails.
            self.module.setObjcDefinedClassParent(fcd.name, self.resolveObjcParentName(fcd));
            // M1.2 A.4b.i: per-class ivar handle global. The class-pair
            // init constructor (emit_llvm) populates it via
            // class_getInstanceVariable after the class is registered;
            // IMP trampolines read it to find the __sx_state ivar.
            self.declareObjcDefinedStateIvarGlobal(fcd.name);
            // M1.2 A.6: per-class class-object global. -dealloc reads
            // it to build an `objc_super` struct for `[super dealloc]`
            // dispatch via `objc_msgSendSuper2`.
            self.declareObjcDefinedClassGlobal(fcd.name);
        }
        self.registerObjcDefinedClassMethods(fcd);
    }
}

/// Issue 0348: the runtime-class registry is name-keyed program-wide, so
/// two modules declaring the same sx name used to race the slot silently
/// (last-wins) — the loser's member calls resolved against the winner's
/// surface. Extern declarations are C-header-like per-module VIEWS of one
/// runtime class, so same-name externs binding the SAME runtime class now
/// MERGE into a union surface (every consumer sees the union through the
/// map). Genuine conflicts diagnose: different runtime bindings, any
/// sx-defined (export) duplicate, or same-name methods with different
/// static-ness/arity/selector.
fn upsertRuntimeClass(self: *Lowering, key: []const u8, fcd: *const ast.RuntimeClassDecl) void {
    const existing = self.program_index.runtime_class_map.get(key) orelse {
        self.program_index.runtime_class_map.put(key, fcd) catch {};
        return;
    };
    if (existing == fcd) return;
    const src_a = existing.source_file orelse "<unknown>";
    const src_b = fcd.source_file orelse (self.current_source_file orelse "<unknown>");
    if (!existing.is_extern or !fcd.is_extern) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, null, "duplicate runtime-class declaration '{s}': an sx-defined (export) class allows exactly one declaration — declared in {s} and {s}", .{ key, src_a, src_b });
        }
        return;
    }
    if (existing.runtime != fcd.runtime or !std.mem.eql(u8, existing.runtime_path, fcd.runtime_path)) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, null, "extern runtime-class name '{s}' binds different runtime classes: \"{s}\" (in {s}) vs \"{s}\" (in {s}) — one sx name, one runtime class", .{ key, existing.runtime_path, src_a, fcd.runtime_path, src_b });
        }
        return;
    }

    var members = std.ArrayList(ast.RuntimeClassMember).empty;
    members.appendSlice(self.alloc, existing.members) catch return;
    for (fcd.members) |m| {
        switch (m) {
            .method => |md| {
                var conflict = false;
                var present = false;
                for (existing.members) |em| {
                    if (em != .method) continue;
                    const emd = em.method;
                    if (!std.mem.eql(u8, emd.name, md.name)) continue;
                    const same_sel = (emd.selector_override == null and md.selector_override == null) or
                        (emd.selector_override != null and md.selector_override != null and
                            std.mem.eql(u8, emd.selector_override.?, md.selector_override.?));
                    // Arity + selector identify the dispatch; static-ness is
                    // NOT compared — it derives from the `*Self` spelling, so
                    // `self: *Self` vs `self: *NSObject` (both instance) would
                    // false-conflict, while a true static/instance pair
                    // already differs in params.len (statics carry no self).
                    if (emd.params.len == md.params.len and same_sel) {
                        present = true;
                    } else {
                        conflict = true;
                    }
                    break;
                }
                if (conflict) {
                    if (self.diagnostics) |d| {
                        d.addFmt(.err, null, "extern runtime-class '{s}': method '{s}' declared with conflicting shapes in {s} and {s} (static-ness, arity, or #selector differ)", .{ key, md.name, src_a, src_b });
                    }
                    return;
                }
                if (!present) members.append(self.alloc, m) catch return;
            },
            .field => |fd| {
                var dup = false;
                for (existing.members) |em| {
                    if (em == .field and std.mem.eql(u8, em.field.name, fd.name)) { dup = true; break; }
                }
                if (dup) {
                    if (self.diagnostics) |d| {
                        d.addFmt(.err, null, "extern runtime-class '{s}': field '{s}' declared in both {s} and {s} — declare it in one view", .{ key, fd.name, src_a, src_b });
                    }
                    return;
                }
                members.append(self.alloc, m) catch return;
            },
            .extends => |parent| {
                var existing_parent: ?[]const u8 = null;
                for (existing.members) |em| {
                    if (em == .extends) { existing_parent = em.extends; break; }
                }
                if (existing_parent) |ep| {
                    if (!std.mem.eql(u8, ep, parent)) {
                        if (self.diagnostics) |d| {
                            d.addFmt(.err, null, "extern runtime-class '{s}': #extends disagrees — '{s}' (in {s}) vs '{s}' (in {s})", .{ key, ep, src_a, parent, src_b });
                        }
                        return;
                    }
                } else {
                    members.append(self.alloc, m) catch return;
                }
            },
            .implements => |proto| {
                var dup = false;
                for (existing.members) |em| {
                    if (em == .implements and std.mem.eql(u8, em.implements, proto)) { dup = true; break; }
                }
                if (!dup) members.append(self.alloc, m) catch return;
            },
        }
    }

    // Nothing new (a re-scan of an already-merged pair) — keep the
    // existing entry, no fresh allocation.
    if (members.items.len == existing.members.len) return;

    const merged = self.alloc.create(ast.RuntimeClassDecl) catch return;
    merged.* = existing.*;
    merged.members = self.alloc.dupe(ast.RuntimeClassMember, members.items) catch return;
    self.program_index.runtime_class_map.put(key, merged) catch {};
}

/// Resolve the `#extends ParentAlias` declaration on a sx-defined
/// `#objc_class` to the actual Obj-C runtime class name. Falls
/// back to "NSObject" when no `#extends` is declared.
/// Aliases that resolve to runtime Obj-C classes use the
/// runtime_path; aliases for OTHER sx-defined classes use the
/// alias name directly (which equals the Obj-C class name for
/// sx-defined classes).
pub fn resolveObjcParentName(self: *Lowering, fcd: *const ast.RuntimeClassDecl) []const u8 {
    for (fcd.members) |m| switch (m) {
        .extends => |alias| {
            if (self.program_index.runtime_class_map.get(alias)) |parent_fcd| {
                if (parent_fcd.is_extern) return parent_fcd.runtime_path;
                // Sx-defined parent — its alias IS its Obj-C name.
                return parent_fcd.name;
            }
            // Unknown alias — pass through as-is and let the
            // runtime diagnose if it's genuinely wrong.
            return alias;
        },
        else => {},
    };
    return "NSObject";
}

/// Declare a per-class global `__<ClassName>_state_ivar : *void = null`.
/// emit_llvm's `emitObjcDefinedClassInit` constructor fills it in via
/// `class_getInstanceVariable(cls, "__sx_state")` once per module load.
pub fn declareObjcDefinedStateIvarGlobal(self: *Lowering, class_name: []const u8) void {
    const gname = std.fmt.allocPrint(self.alloc, "__{s}_state_ivar", .{class_name}) catch return;
    const name_id = self.module.types.internString(gname);
    _ = self.module.addGlobal(.{
        .name = name_id,
        .ty = self.module.types.ptrTo(.void),
        .init_val = .null_val,
        .is_extern = false,
        .is_const = false,
    });
}

/// Declare a per-class global `__<ClassName>_class : *void = null`.
/// emit_llvm's `emitObjcDefinedClassInit` constructor stores the
/// freshly-allocated Class pointer into it after objc_registerClassPair.
/// The synthesized `-dealloc` IMP reads it to construct an `objc_super`
/// for `[super dealloc]` dispatch.
pub fn declareObjcDefinedClassGlobal(self: *Lowering, class_name: []const u8) void {
    const gname = std.fmt.allocPrint(self.alloc, "__{s}_class", .{class_name}) catch return;
    const name_id = self.module.types.internString(gname);
    _ = self.module.addGlobal(.{
        .name = name_id,
        .ty = self.module.types.ptrTo(.void),
        .init_val = .null_val,
        .is_extern = false,
        .is_const = false,
    });
}

/// For each bodied instance method on an sx-defined `#objc_class`,
/// synthesize an `FnDecl` from the `RuntimeMethodDecl`, register it
/// in `fn_ast_map` under `<ClassName>.<methodName>`, declare the IR
/// function, AND collect per-method registration data (selector
/// mangling + type encoding + IMP symbol name) into the class's
/// cache entry so emit_llvm can wire up `class_addMethod` calls
/// (M1.2 A.4b.iii). Bodyless declarations are skipped — they
/// reference inherited / external methods, not sx-side bodies.
pub fn registerObjcDefinedClassMethods(self: *Lowering, fcd: *const ast.RuntimeClassDecl) void {
    // Set current_runtime_class so `*Self` substitutions in
    // declareFunction's type resolution find the state struct.
    const saved = self.current_runtime_class;
    self.current_runtime_class = fcd;
    defer self.current_runtime_class = saved;

    var method_infos = std.ArrayList(Module.ObjcDefinedMethodEntry).empty;

    for (fcd.members) |m| {
        const method = switch (m) {
            .method => |md| md,
            else => continue,
        };
        const body = method.body orelse continue;
        const fd = self.synthesizeFnDeclFromObjcMethod(method, body) orelse continue;
        const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ fcd.name, method.name }) catch continue;
        self.program_index.fn_ast_map.put(qualified, fd) catch {};
        self.declareFunction(fd, qualified);

        // Selector mangling — A.1's deriveObjcSelector handles
        // `#selector("...")` override + the default rule. Static
        // methods use the same mangling rule (their first param
        // ISN'T *Self, so no offset).
        //
        // ABI for the IMP signature (both instance + class methods):
        //   `(recv: id|Class, _cmd: SEL, ...user_args) -> ret`
        // For instance methods the user-declared self is at param[0]
        // (skipped); class methods have no self in the AST.
        const user_param_start: usize = if (method.is_static) 0 else 1;
        const user_arg_count = if (method.params.len > user_param_start) method.params.len - user_param_start else 0;
        const sel_info = self.objc().deriveObjcSelector(method, user_arg_count);

        const ret_ty: TypeId = if (method.return_type) |rt| self.resolveType(rt) else .void;
        var arg_tys = std.ArrayList(TypeId).empty;
        defer arg_tys.deinit(self.alloc);
        if (method.params.len > user_param_start) {
            for (method.params[user_param_start..]) |p_node| {
                arg_tys.append(self.alloc, self.resolveType(p_node)) catch unreachable;
            }
        }
        const encoding = self.objc().objcTypeEncodingFromSignature(ret_ty, arg_tys.items, null) catch continue;

        const imp_name = std.fmt.allocPrint(self.alloc, "__{s}_{s}_imp", .{ fcd.name, method.name }) catch continue;

        method_infos.append(self.alloc, .{
            .sel = sel_info.sel,
            .encoding = encoding,
            .imp_name = imp_name,
            .is_class = method.is_static,
        }) catch unreachable;
    }

    if (method_infos.items.len > 0) {
        const methods_slice = method_infos.toOwnedSlice(self.alloc) catch return;
        self.module.setObjcDefinedClassMethods(fcd.name, methods_slice);
    }
}

/// Build an `FnDecl` whose params are zipped from the
/// `RuntimeMethodDecl.params` (type nodes) and `param_names`. Used
/// to feed sx-defined class methods through the standard
/// fn-lowering pipeline. Allocator-owned; lives for the duration
/// of the Lowering pass.
pub fn synthesizeFnDeclFromObjcMethod(self: *Lowering, method: ast.RuntimeMethodDecl, body: *ast.Node) ?*ast.FnDecl {
    if (method.params.len != method.param_names.len) return null;
    var params = std.ArrayList(ast.Param).empty;
    for (method.params, method.param_names) |type_node, p_name| {
        params.append(self.alloc, .{
            .name = p_name,
            .name_span = .{ .start = 0, .end = 0 },
            .type_expr = type_node,
        }) catch unreachable;
    }
    const fd = self.alloc.create(ast.FnDecl) catch return null;
    fd.* = .{
        .name = method.name,
        .params = params.toOwnedSlice(self.alloc) catch unreachable,
        .return_type = method.return_type,
        .body = body,
    };
    return fd;
}

/// If `name` matches an sx-defined `#objc_class`'s qualified-method
/// pattern (`<ClassName>.<methodName>`), return the class's
/// RuntimeClassDecl. Used by `lowerFunction` to set
/// `current_runtime_class` so `*Self` resolves to the state struct
/// during body lowering.
pub fn lookupObjcDefinedClassForMethod(self: *Lowering, name: []const u8) ?*const ast.RuntimeClassDecl {
    const dot = std.mem.indexOf(u8, name, ".") orelse return null;
    return self.module.lookupObjcDefinedClass(name[0..dot]);
}

/// Lazily declare the `sx_jni_env_tl_get` / `sx_jni_env_tl_set`
/// runtime externs (step 2.16c). The storage lives in
/// `library/vendors/sx_jni_runtime/sx_jni_env_tl.c` as a
/// `_Thread_local` slot — keeping it OUT of the user's IR module
/// is what lets the LLVM ORC JIT load the module cleanly without
/// orc_rt platform support. AOT targets get the same .c file
/// linked in via `needs_jni_env_tl_runtime`, which Compilation
/// reads to append a synthetic c_import alongside the user's.
pub fn getJniEnvTlFids(self: *Lowering) struct { get: FuncId, set: FuncId } {
    self.needs_jni_env_tl_runtime = true;
    const ptr_ty = self.module.types.ptrTo(.void);
    if (self.jni_env_tl_get_fid == null) {
        const name = self.module.types.internString("sx_jni_env_tl_get");
        const fid = self.builder.declareExtern(name, &.{}, ptr_ty);
        const func = self.module.getFunctionMut(fid);
        func.call_conv = .c;
        self.jni_env_tl_get_fid = fid;
    }
    if (self.jni_env_tl_set_fid == null) {
        const name = self.module.types.internString("sx_jni_env_tl_set");
        const env_param = self.module.types.internString("env");
        var params = std.ArrayList(inst_mod.Function.Param).empty;
        params.append(self.alloc, .{ .name = env_param, .ty = ptr_ty }) catch unreachable;
        const fid = self.builder.declareExtern(name, params.toOwnedSlice(self.alloc) catch unreachable, .void);
        const func = self.module.getFunctionMut(fid);
        func.call_conv = .c;
        self.jni_env_tl_set_fid = fid;
    }
    return .{ .get = self.jni_env_tl_get_fid.?, .set = self.jni_env_tl_set_fid.? };
}

/// When a namespaced import (`Ns :: #import "..."`) contains runtime-class
/// declarations, ALSO register them under their qualified name `Ns.Class`
/// so receiver types like `*Ns.Class` can find the fcd. The recursive
/// scan/lower already handles bare-name registration; this only adds the
/// qualified-name entry, so cross-class refs in method signatures
/// (`*View` → bare lookup) still work.
pub fn registerNamespacedRuntimeClasses(self: *Lowering, ns: ast.NamespaceDecl) void {
    for (ns.decls) |inner| {
        if (inner.data == .runtime_class_decl) {
            const fcd = &inner.data.runtime_class_decl;
            const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ ns.name, fcd.name }) catch fcd.name;
            upsertRuntimeClass(self, qualified, fcd);
        } else if (inner.data == .namespace_decl) {
            // Nested namespaces — qualify with both prefixes.
            self.registerNamespacedRuntimeClasses(inner.data.namespace_decl);
        }
    }
}


// ── JNI main stubs ─────────────────────────────────────────────

pub fn synthesizeJniMainStubs(self: *Lowering) void {
    var seen = std.StringHashMap(void).init(self.alloc);
    defer seen.deinit();

    var it = self.program_index.runtime_class_map.iterator();
    while (it.next()) |entry| {
        const fcd = entry.value_ptr.*;
        if (!fcd.is_main) continue;
        if (fcd.is_extern) continue;
        if (fcd.runtime != .jni_class) continue;
        if (seen.contains(fcd.runtime_path)) continue;
        seen.put(fcd.runtime_path, {}) catch continue;

        for (fcd.members) |m| switch (m) {
            .method => |md| {
                if (md.body == null) continue;
                if (md.is_static) continue; // future: emit static native ABI without `self`
                self.synthesizeJniMainStub(fcd, md);
            },
            else => {},
        };
    }
}

pub fn synthesizeJniMainStub(self: *Lowering, fcd: *const ast.RuntimeClassDecl, md: ast.RuntimeMethodDecl) void {
    // Flow narrowing (issue 0179) is per-function: each native-method stub body
    // gets its own `Ref` space (reset by `beginFunction` below) that OVERLAPS
    // both the enclosing pass and a sibling method's stub. Without isolation the
    // previous method's `narrowed_refs` indices falsely match this body's `Ref`s
    // and permit an unsound unwrap of a non-present optional. Clear on entry,
    // restore on exit — same contract as the closure / monomorphization paths.
    var narrow_guard = Lowering.NarrowGuard.enter(self);
    defer narrow_guard.restore();

    const mangled = jni_descriptor.jniMangleNativeName(self.alloc, fcd.runtime_path, md.name) catch return;
    const name_id = self.module.types.internString(mangled);

    const ptr_void = self.module.types.ptrTo(.void);
    var params = std.ArrayList(inst_mod.Function.Param).empty;
    params.append(self.alloc, .{
        .name = self.module.types.internString("env"),
        .ty = ptr_void,
    }) catch return;
    params.append(self.alloc, .{
        .name = self.module.types.internString("self"),
        .ty = ptr_void,
    }) catch return;

    // User's declared params (skip the implicit `*Self` at index 0 for
    // instance methods — we synthesized `self` above as the jobject).
    const param_start: usize = 1;
    for (md.params[param_start..], 0..) |p_node, i| {
        const pty = jniMapParamType(self, p_node);
        params.append(self.alloc, .{
            .name = self.module.types.internString(md.param_names[param_start + i]),
            .ty = pty,
        }) catch return;
    }

    const ret_ty = if (md.return_type) |rt| jniMapParamType(self, rt) else .void;
    const params_slice = params.toOwnedSlice(self.alloc) catch return;

    _ = self.builder.beginFunction(name_id, params_slice, ret_ty);
    self.builder.currentFunc().linkage = .external;
    self.builder.currentFunc().call_conv = .c;

    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);

    var scope = Scope.init(self.alloc, self.scope);
    defer scope.deinit();
    const saved_scope = self.scope;
    self.scope = &scope;
    defer self.scope = saved_scope;

    for (params_slice, 0..) |p, i| {
        const slot = self.builder.alloca(p.ty);
        const param_ref = Ref.fromIndex(@intCast(i));
        self.builder.store(slot, param_ref);
        scope.put(self.module.types.getString(p.name), .{ .ref = slot, .ty = p.ty, .is_alloca = true });
    }

    // Push the JNIEnv* arg onto the lexical `#jni_env` stack so the
    // method body's `#jni_call(...)` / `super.method(...)` sites pick
    // it up without an explicit `#jni_env(env) { ... }` wrapper. The
    // JNI runtime guarantees the env passed to a native method is
    // valid for the calling thread.
    const env_slot = scope.lookup("env").?.ref;
    const env_loaded = self.builder.load(env_slot, ptr_void);
    const env_stack_base = self.jni_env_stack_base;
    self.jni_env_stack_base = self.jni_env_stack.items.len;
    self.jni_env_stack.append(self.alloc, env_loaded) catch {};
    defer {
        _ = self.jni_env_stack.pop();
        self.jni_env_stack_base = env_stack_base;
    }

    // Record method context so `super.method(args)` inside the body
    // can find the parent class (via `#extends`) and the method's
    // signature.
    const saved_fcd = self.current_runtime_class;
    const saved_method = self.current_runtime_method;
    self.current_runtime_class = fcd;
    self.current_runtime_method = md;
    defer {
        self.current_runtime_class = saved_fcd;
        self.current_runtime_method = saved_method;
    }

    // JNI native methods are C-callable entry points — install the
    // static default Context so `context.X` reads in the method body
    // resolve through `current_ctx_ref`. Mirror the same binding
    // `lowerFunction` does for abi(.c) / isExportedEntryName.
    const saved_ctx_ref_jni = self.current_ctx_ref;
    defer self.current_ctx_ref = saved_ctx_ref_jni;
    if (self.implicit_ctx_enabled) {
        if (self.program_index.global_names.get("__sx_default_context")) |dctx_gi| {
            self.current_ctx_ref = self.builder.emit(.{ .global_addr = dctx_gi.id }, ptr_void);
        }
    }

    const saved_target = self.target_type;
    self.target_type = if (ret_ty != .void) ret_ty else null;
    if (ret_ty != .void) {
        const body_val = self.lowerBlockValue(md.body.?);
        if (!self.currentBlockHasTerminator()) {
            if (body_val) |val| {
                const val_ty = self.builder.getRefType(val);
                if (val_ty == .void) {
                    self.ensureTerminator(ret_ty);
                } else {
                    const coerced = self.coerceToType(val, val_ty, ret_ty);
                    self.builder.ret(coerced, ret_ty);
                }
            } else {
                self.ensureTerminator(ret_ty);
            }
        }
    } else {
        self.lowerBlock(md.body.?);
        self.ensureTerminator(ret_ty);
    }
    self.target_type = saved_target;

    self.builder.finalize();
}

/// JNI param/return type resolution: user-declared types pass through
/// `resolveType` so the method body can dispatch on richer runtime-class
/// types (`holder.getSurface()` etc.). At LLVM level both `*SurfaceHolder`
/// and `*void` lower to the same `ptr`, so the C ABI shape Java sees is
/// unchanged — only sx-side method resolution benefits.
fn jniMapParamType(self: *Lowering, type_node: *ast.Node) TypeId {
    return self.resolveType(type_node);
}
