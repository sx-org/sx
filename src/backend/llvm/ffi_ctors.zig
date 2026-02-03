const std = @import("std");
const llvm = @import("../../llvm_api.zig");
const c = llvm.c;
const emit = @import("../../ir/emit_llvm.zig");

const LLVMEmitter = emit.LLVMEmitter;
const JniSlotPair = LLVMEmitter.JniSlotPair;

/// Obj-C / JNI runtime-constructor emission (architecture phase A7.3), extracted
/// from `LLVMEmitter`. A backend `*LLVMEmitter` facade (field `e`): it builds the
/// module-init constructors that populate the cached selector / class slots and
/// register sx-defined `#objc_class` class pairs (IMP tables, ivars, +alloc /
/// -dealloc / property IMPs, `#implements` protocol conformances). Reads the
/// emit-time caches (`ir_mod.objc_*_cache`, `global_map`) + cached LLVM handles
/// via `self.e.*`; the shared infra it calls back into
/// (`lazyDeclareCRuntime`/`emitPrivateCString`/`injectCtorIntoMain`) stays on
/// `LLVMEmitter`. `LLVMEmitter.emit` drives pass order via `self.ffiCtors()`.
pub const FfiCtors = struct {
    e: *LLVMEmitter,

    pub fn emitObjcSelectorInit(self: FfiCtors) void {
        if (self.e.ir_mod.objc_selector_cache.items.len == 0) return;

        // Lazy-declare sel_registerName for the constructor body —
        // lower.zig only declares it when a non-literal selector
        // appears, which the constructor doesn't depend on.
        const sel_reg_name = "sel_registerName";
        const sel_reg_z = self.e.alloc.dupeZ(u8, sel_reg_name) catch unreachable;
        defer self.e.alloc.free(sel_reg_z);
        var sel_reg_fn = c.LLVMGetNamedFunction(self.e.llvm_module, sel_reg_z.ptr);
        var sel_reg_ty: c.LLVMTypeRef = undefined;
        if (sel_reg_fn == null) {
            var params: [1]c.LLVMTypeRef = .{self.e.cached_ptr};
            sel_reg_ty = c.LLVMFunctionType(self.e.cached_ptr, &params, 1, 0);
            sel_reg_fn = c.LLVMAddFunction(self.e.llvm_module, sel_reg_z.ptr, sel_reg_ty);
            c.LLVMSetLinkage(sel_reg_fn, c.LLVMExternalLinkage);
        } else {
            sel_reg_ty = c.LLVMGlobalGetValueType(sel_reg_fn);
        }

        // Constructor: void __sx_objc_selector_init().
        var no_params: [0]c.LLVMTypeRef = .{};
        const ctor_ty = c.LLVMFunctionType(self.e.cached_void, &no_params, 0, 0);
        const ctor = c.LLVMAddFunction(self.e.llvm_module, "__sx_objc_selector_init", ctor_ty);
        c.LLVMSetLinkage(ctor, c.LLVMInternalLinkage);
        const entry = c.LLVMAppendBasicBlockInContext(self.e.context, ctor, "entry");
        c.LLVMPositionBuilderAtEnd(self.e.builder, entry);

        for (self.e.ir_mod.objc_selector_cache.items) |entry_kv| {
            const sel_str = entry_kv.sel;
            const slot_gid = entry_kv.slot;
            const slot_global = self.e.global_map.get(@intCast(slot_gid.index())) orelse continue;

            // Method-name C-string — names match clang's convention
            // so debuggers / nm / dyld see the same symbols, even
            // though the surrounding section tagging isn't load-
            // bearing in our JIT path.
            const meth_str_z = self.e.alloc.allocSentinel(u8, sel_str.len, 0) catch continue;
            defer self.e.alloc.free(meth_str_z);
            @memcpy(meth_str_z[0..sel_str.len], sel_str);
            const str_const = c.LLVMConstStringInContext(self.e.context, meth_str_z.ptr, @intCast(sel_str.len), 0);
            const str_global = c.LLVMAddGlobal(self.e.llvm_module, c.LLVMTypeOf(str_const), "OBJC_METH_VAR_NAME_");
            c.LLVMSetInitializer(str_global, str_const);
            c.LLVMSetLinkage(str_global, c.LLVMPrivateLinkage);
            c.LLVMSetGlobalConstant(str_global, 1);
            c.LLVMSetUnnamedAddress(str_global, c.LLVMGlobalUnnamedAddr);

            var sel_args: [1]c.LLVMValueRef = .{str_global};
            const sel_val = c.LLVMBuildCall2(self.e.builder, sel_reg_ty, sel_reg_fn, &sel_args, 1, "sel");
            _ = c.LLVMBuildStore(self.e.builder, sel_val, slot_global);
        }
        _ = c.LLVMBuildRetVoid(self.e.builder);

        // Register the constructor in @llvm.global_ctors. dyld picks
        // this up for a fully-linked binary at load time.
        const i32_ty = self.e.cached_i32;
        const ptr_ty = self.e.cached_ptr;
        var ctor_field_types: [3]c.LLVMTypeRef = .{ i32_ty, ptr_ty, ptr_ty };
        const ctor_struct_ty = c.LLVMStructTypeInContext(self.e.context, &ctor_field_types, 3, 0);
        var ctor_fields: [3]c.LLVMValueRef = .{
            c.LLVMConstInt(i32_ty, 65535, 0),
            ctor,
            c.LLVMConstNull(ptr_ty),
        };
        const ctor_entry = c.LLVMConstNamedStruct(ctor_struct_ty, &ctor_fields, 3);
        const ctors_arr_ty = c.LLVMArrayType2(ctor_struct_ty, 1);
        var ctor_entries: [1]c.LLVMValueRef = .{ctor_entry};
        const ctors_init = c.LLVMConstArray2(ctor_struct_ty, &ctor_entries, 1);
        const ctors_global = c.LLVMAddGlobal(self.e.llvm_module, ctors_arr_ty, "llvm.global_ctors");
        c.LLVMSetInitializer(ctors_global, ctors_init);
        c.LLVMSetLinkage(ctors_global, c.LLVMAppendingLinkage);

        // BUT — LLVM's ORC JIT (the engine for `sx run`) doesn't
        // automatically run `@llvm.global_ctors`. Inject a direct
        // call from `main`'s entry block as well; idempotent under
        // dyld (sel_registerName returns the same SEL on second call).
        const main_z = "main";
        const main_fn = c.LLVMGetNamedFunction(self.e.llvm_module, main_z);
        if (main_fn != null) {
            const entry_bb = c.LLVMGetEntryBasicBlock(main_fn);
            const first_inst = c.LLVMGetFirstInstruction(entry_bb);
            if (first_inst != null) {
                c.LLVMPositionBuilderBefore(self.e.builder, first_inst);
            } else {
                c.LLVMPositionBuilderAtEnd(self.e.builder, entry_bb);
            }
            var no_args: [0]c.LLVMValueRef = .{};
            _ = c.LLVMBuildCall2(self.e.builder, ctor_ty, ctor, &no_args, 0, "");
        }
    }

    /// Phase 3.1 companion to `emitObjcSelectorInit`. Walks
    /// `module.objc_class_cache` and synthesizes a constructor that
    /// populates each cached `Class*` slot via `objc_getClass(name)`
    /// exactly once at module-init. Registered in `@llvm.global_ctors`
    /// AND injected at the top of `main()` for the ORC JIT path.
    pub fn emitObjcClassInit(self: FfiCtors) void {
        if (self.e.ir_mod.objc_class_cache.items.len == 0) return;

        // Lazy-declare objc_getClass(name: *u8) -> *void.
        const get_class_name = "objc_getClass";
        const get_class_z = self.e.alloc.dupeZ(u8, get_class_name) catch unreachable;
        defer self.e.alloc.free(get_class_z);
        var get_class_fn = c.LLVMGetNamedFunction(self.e.llvm_module, get_class_z.ptr);
        var get_class_ty: c.LLVMTypeRef = undefined;
        if (get_class_fn == null) {
            var params: [1]c.LLVMTypeRef = .{self.e.cached_ptr};
            get_class_ty = c.LLVMFunctionType(self.e.cached_ptr, &params, 1, 0);
            get_class_fn = c.LLVMAddFunction(self.e.llvm_module, get_class_z.ptr, get_class_ty);
            c.LLVMSetLinkage(get_class_fn, c.LLVMExternalLinkage);
        } else {
            get_class_ty = c.LLVMGlobalGetValueType(get_class_fn);
        }

        // Constructor: void __sx_objc_class_init().
        var no_params: [0]c.LLVMTypeRef = .{};
        const ctor_ty = c.LLVMFunctionType(self.e.cached_void, &no_params, 0, 0);
        const ctor = c.LLVMAddFunction(self.e.llvm_module, "__sx_objc_class_init", ctor_ty);
        c.LLVMSetLinkage(ctor, c.LLVMInternalLinkage);
        const entry = c.LLVMAppendBasicBlockInContext(self.e.context, ctor, "entry");
        c.LLVMPositionBuilderAtEnd(self.e.builder, entry);

        for (self.e.ir_mod.objc_class_cache.items) |entry_kv| {
            const class_name = entry_kv.name;
            const slot_gid = entry_kv.slot;
            const slot_global = self.e.global_map.get(@intCast(slot_gid.index())) orelse continue;

            // Class-name C-string.
            const name_z = self.e.alloc.allocSentinel(u8, class_name.len, 0) catch continue;
            defer self.e.alloc.free(name_z);
            @memcpy(name_z[0..class_name.len], class_name);
            const str_const = c.LLVMConstStringInContext(self.e.context, name_z.ptr, @intCast(class_name.len), 0);
            const str_global = c.LLVMAddGlobal(self.e.llvm_module, c.LLVMTypeOf(str_const), "OBJC_CLASS_NAME_");
            c.LLVMSetInitializer(str_global, str_const);
            c.LLVMSetLinkage(str_global, c.LLVMPrivateLinkage);
            c.LLVMSetGlobalConstant(str_global, 1);
            c.LLVMSetUnnamedAddress(str_global, c.LLVMGlobalUnnamedAddr);

            var call_args: [1]c.LLVMValueRef = .{str_global};
            const class_val = c.LLVMBuildCall2(self.e.builder, get_class_ty, get_class_fn, &call_args, 1, "cls");
            _ = c.LLVMBuildStore(self.e.builder, class_val, slot_global);
        }
        _ = c.LLVMBuildRetVoid(self.e.builder);

        // Register in @llvm.global_ctors for AOT + inject into main for ORC JIT.
        const i32_ty = self.e.cached_i32;
        const ptr_ty = self.e.cached_ptr;
        var ctor_field_types: [3]c.LLVMTypeRef = .{ i32_ty, ptr_ty, ptr_ty };
        const ctor_struct_ty = c.LLVMStructTypeInContext(self.e.context, &ctor_field_types, 3, 0);
        var ctor_fields: [3]c.LLVMValueRef = .{
            c.LLVMConstInt(i32_ty, 65535, 0),
            ctor,
            c.LLVMConstNull(ptr_ty),
        };
        const ctor_entry = c.LLVMConstNamedStruct(ctor_struct_ty, &ctor_fields, 3);

        // Append-vs-replace the existing global_ctors. Selector init may
        // have created `@llvm.global_ctors` already — extend its array
        // rather than overwriting.
        const existing_z = "llvm.global_ctors";
        const existing = c.LLVMGetNamedGlobal(self.e.llvm_module, existing_z);
        if (existing != null) {
            const existing_init = c.LLVMGetInitializer(existing);
            const existing_arr_ty = c.LLVMGlobalGetValueType(existing);
            const old_count = c.LLVMGetArrayLength(existing_arr_ty);
            const new_count: c_uint = old_count + 1;
            var new_entries = std.ArrayList(c.LLVMValueRef).empty;
            defer new_entries.deinit(self.e.alloc);
            var i: c_uint = 0;
            while (i < old_count) : (i += 1) {
                new_entries.append(self.e.alloc, c.LLVMGetAggregateElement(existing_init, i)) catch unreachable;
            }
            new_entries.append(self.e.alloc, ctor_entry) catch unreachable;
            const new_arr_ty = c.LLVMArrayType2(ctor_struct_ty, new_count);
            const new_init = c.LLVMConstArray2(ctor_struct_ty, new_entries.items.ptr, new_count);
            const new_global = c.LLVMAddGlobal(self.e.llvm_module, new_arr_ty, "llvm.global_ctors.new");
            c.LLVMSetInitializer(new_global, new_init);
            c.LLVMSetLinkage(new_global, c.LLVMAppendingLinkage);
            c.LLVMSetValueName2(existing, "llvm.global_ctors.old", "llvm.global_ctors.old".len);
            c.LLVMSetValueName2(new_global, "llvm.global_ctors", "llvm.global_ctors".len);
            c.LLVMDeleteGlobal(existing);
        } else {
            const ctors_arr_ty = c.LLVMArrayType2(ctor_struct_ty, 1);
            var ctor_entries: [1]c.LLVMValueRef = .{ctor_entry};
            const ctors_init = c.LLVMConstArray2(ctor_struct_ty, &ctor_entries, 1);
            const ctors_global = c.LLVMAddGlobal(self.e.llvm_module, ctors_arr_ty, "llvm.global_ctors");
            c.LLVMSetInitializer(ctors_global, ctors_init);
            c.LLVMSetLinkage(ctors_global, c.LLVMAppendingLinkage);
        }

        // ORC JIT injection: same trick as emitObjcSelectorInit. Inject a
        // direct call from main's entry so the JIT path populates the
        // slots too. Must run AFTER the selector init's main injection
        // (selectors are needed independently of class objects), so we
        // place this call AFTER the first instruction (which is the
        // selector-init call, if present) rather than at the very top.
        const main_z = "main";
        const main_fn = c.LLVMGetNamedFunction(self.e.llvm_module, main_z);
        if (main_fn != null) {
            const entry_bb = c.LLVMGetEntryBasicBlock(main_fn);
            // Walk past any existing init calls (selector init etc.) so
            // class init runs after them. The order within main's prelude
            // doesn't matter functionally (the two caches are independent),
            // but stable ordering keeps IR snapshots deterministic.
            var insert_before = c.LLVMGetFirstInstruction(entry_bb);
            while (insert_before != null) : (insert_before = c.LLVMGetNextInstruction(insert_before)) {
                if (c.LLVMGetInstructionOpcode(insert_before) != c.LLVMCall) break;
            }
            if (insert_before != null) {
                c.LLVMPositionBuilderBefore(self.e.builder, insert_before);
            } else {
                c.LLVMPositionBuilderAtEnd(self.e.builder, entry_bb);
            }
            var no_args: [0]c.LLVMValueRef = .{};
            _ = c.LLVMBuildCall2(self.e.builder, ctor_ty, ctor, &no_args, 0, "");
        }
    }

    /// M1.2 A.4 — emit class-pair registration constructor for every
    /// sx-defined `#objc_class` declaration. Same shape as the Phase
    /// 3.1 `emitObjcClassInit` companion: a `@llvm.global_ctors`-
    /// registered constructor that runs at module load AND gets
    /// injected at the top of `main` for the ORC JIT path (which
    /// doesn't honor `@llvm.global_ctors`).
    ///
    /// For each entry in `objc_defined_class_cache`:
    ///   super_cls = objc_getClass("<ParentName>")  // default NSObject
    ///   cls       = objc_allocateClassPair(super_cls, "<ClassName>", 0)
    ///   class_addIvar(cls, "__sx_state", 8, 3, "^v")     // M1.2 A.4b.i
    ///   objc_registerClassPair(cls)
    ///   g_<ClassName>_state_ivar = class_getInstanceVariable(cls, "__sx_state")
    ///
    /// Method IMPs (`class_addMethod`) and the `+alloc` / `-dealloc`
    /// overrides come in A.4b.ii / A.5 / A.6.
    pub fn emitObjcDefinedClassInit(self: FfiCtors) void {
        if (self.e.ir_mod.objc_defined_class_cache.items.len == 0) return;

        const ptr_ty = self.e.cached_ptr;
        const i32_ty = self.e.cached_i32;
        const i64_ty = self.e.cached_i64;
        const i8_ty = c.LLVMInt8TypeInContext(self.e.context);

        // Lazy-declare the Obj-C runtime APIs the constructor calls.
        // objc_getClass(name: *u8) -> *void.
        const get_class_fn, const get_class_ty = self.e.lazyDeclareCRuntime("objc_getClass", &[_]c.LLVMTypeRef{ptr_ty}, ptr_ty, 0);
        // objc_allocateClassPair(super: *void, name: *u8, extra: usize) -> *void.
        const alloc_pair_fn, const alloc_pair_ty = self.e.lazyDeclareCRuntime("objc_allocateClassPair", &[_]c.LLVMTypeRef{ ptr_ty, ptr_ty, i64_ty }, ptr_ty, 0);
        // class_addIvar(cls: *void, name: *u8, size: u64, log2align: u8, type: *u8) -> bool.
        const add_ivar_fn, const add_ivar_ty = self.e.lazyDeclareCRuntime("class_addIvar", &[_]c.LLVMTypeRef{ ptr_ty, ptr_ty, i64_ty, i8_ty, ptr_ty }, i8_ty, 0);
        // sel_registerName(name: *u8) -> *void.
        const sel_reg_fn, const sel_reg_ty = self.e.lazyDeclareCRuntime("sel_registerName", &[_]c.LLVMTypeRef{ptr_ty}, ptr_ty, 0);
        // class_addMethod(cls: *void, sel: *void, imp: *void, types: *u8) -> bool.
        const add_method_fn, const add_method_ty = self.e.lazyDeclareCRuntime("class_addMethod", &[_]c.LLVMTypeRef{ ptr_ty, ptr_ty, ptr_ty, ptr_ty }, i8_ty, 0);
        // objc_registerClassPair(cls: *void) -> void.
        const register_fn, const register_ty = self.e.lazyDeclareCRuntime("objc_registerClassPair", &[_]c.LLVMTypeRef{ptr_ty}, self.e.cached_void, 0);
        // class_getInstanceVariable(cls: *void, name: *u8) -> *Ivar.
        const get_iv_fn, const get_iv_ty = self.e.lazyDeclareCRuntime("class_getInstanceVariable", &[_]c.LLVMTypeRef{ ptr_ty, ptr_ty }, ptr_ty, 0);

        // Constructor: void __sx_objc_defined_class_init().
        var no_params: [0]c.LLVMTypeRef = .{};
        const ctor_ty = c.LLVMFunctionType(self.e.cached_void, &no_params, 0, 0);
        const ctor = c.LLVMAddFunction(self.e.llvm_module, "__sx_objc_defined_class_init", ctor_ty);
        c.LLVMSetLinkage(ctor, c.LLVMInternalLinkage);
        const entry = c.LLVMAppendBasicBlockInContext(self.e.context, ctor, "entry");
        c.LLVMPositionBuilderAtEnd(self.e.builder, entry);

        // Reusable C-string globals for ivar metadata (same across classes).
        const sx_state_name_global = self.e.emitPrivateCString("__sx_state", "OBJC_IVAR_NAME_");
        const sx_state_enc_global = self.e.emitPrivateCString("^v", "OBJC_IVAR_TYPE_");

        for (self.e.ir_mod.objc_defined_class_cache.items) |entry_kv| {
            const fcd = entry_kv.decl;
            const class_name = fcd.name;

            // Parent class — pre-resolved Obj-C runtime name from
            // lower.zig (M2.3 resolveObjcParentName). Stored on the
            // cache entry so emit_llvm doesn't re-walk
            // runtime_class_map here.
            const parent_name = entry_kv.parent_objc_name;

            const parent_str_global = self.e.emitPrivateCString(parent_name, "OBJC_CLASS_NAME_");
            const class_str_global = self.e.emitPrivateCString(class_name, "OBJC_CLASS_NAME_");

            // super_cls = objc_getClass("ParentName")
            var get_args: [1]c.LLVMValueRef = .{parent_str_global};
            const super_val = c.LLVMBuildCall2(self.e.builder, get_class_ty, get_class_fn, &get_args, 1, "super_cls");

            // cls = objc_allocateClassPair(super_cls, "ClassName", 0)
            var alloc_args: [3]c.LLVMValueRef = .{ super_val, class_str_global, c.LLVMConstInt(i64_ty, 0, 0) };
            const cls_val = c.LLVMBuildCall2(self.e.builder, alloc_pair_ty, alloc_pair_fn, &alloc_args, 3, "cls");

            // class_addIvar(cls, "__sx_state", 8, 3, "^v")
            //   size = 8 (pointer)        — sizeof(*void) on 64-bit
            //   log2align = 3             — alignof(*void) = 8 = 2^3
            //   type = "^v" (encoded *void)
            var ivar_args: [5]c.LLVMValueRef = .{
                cls_val,
                sx_state_name_global,
                c.LLVMConstInt(i64_ty, 8, 0),
                c.LLVMConstInt(i8_ty, 3, 0),
                sx_state_enc_global,
            };
            _ = c.LLVMBuildCall2(self.e.builder, add_ivar_ty, add_ivar_fn, &ivar_args, 5, "");

            // Class-method registration (M2.1(b)) and the +alloc IMP
            // (M1.2 A.5) both target the metaclass. Compute it once
            // up-front so all metaclass-bound class_addMethod calls
            // can reference the same LLVM value.
            //
            // metaclass = object_getClass(cls).  (object_getClass on a
            // Class returns the metaclass — a Class IS an instance of
            // its metaclass. Distinct from objc_getClass(name).)
            const obj_get_class_fn, const obj_get_class_ty = self.e.lazyDeclareCRuntime("object_getClass", &[_]c.LLVMTypeRef{ptr_ty}, ptr_ty, 0);
            var ogc_args: [1]c.LLVMValueRef = .{cls_val};
            const metaclass_val = c.LLVMBuildCall2(self.e.builder, obj_get_class_ty, obj_get_class_fn, &ogc_args, 1, "metacls");

            // class_addMethod(target, sel_registerName(sel), imp, encoding)
            // — register each method's IMP trampoline (M1.2 A.4b.iii
            // + M2.1(b)). Instance methods register on `cls`; class
            // methods (`is_class`) on the metaclass. Must run BEFORE
            // objc_registerClassPair; the runtime locks the method
            // list at registration time on some SDK versions.
            for (entry_kv.methods) |method| {
                const sel_str_global = self.e.emitPrivateCString(method.sel, "OBJC_METH_VAR_NAME_");
                const enc_str_global = self.e.emitPrivateCString(method.encoding, "OBJC_METH_VAR_TYPE_");

                var sel_args: [1]c.LLVMValueRef = .{sel_str_global};
                const sel_val = c.LLVMBuildCall2(self.e.builder, sel_reg_ty, sel_reg_fn, &sel_args, 1, "sel");

                const imp_z = self.e.alloc.dupeZ(u8, method.imp_name) catch continue;
                defer self.e.alloc.free(imp_z);
                const imp_fn = c.LLVMGetNamedFunction(self.e.llvm_module, imp_z.ptr);
                if (imp_fn == null) continue;

                const target_cls = if (method.is_class) metaclass_val else cls_val;
                var add_args: [4]c.LLVMValueRef = .{ target_cls, sel_val, imp_fn, enc_str_global };
                _ = c.LLVMBuildCall2(self.e.builder, add_method_ty, add_method_fn, &add_args, 4, "");
            }

            // M2.3 / M3.2 — register `#implements` protocol conformances
            // BEFORE objc_registerClassPair. iOS checks
            // `class_conformsToProtocol` when instantiating scene
            // delegates and other protocol-typed callbacks; without
            // these the runtime silently rejects the class.
            //
            // The protocol may not be present on every SDK / runtime
            // (dead-strip pruning, version skew), so `objc_getProtocol`
            // returning null is non-fatal — skip the addProtocol call.
            const get_proto_fn, const get_proto_ty = self.e.lazyDeclareCRuntime("objc_getProtocol", &[_]c.LLVMTypeRef{ptr_ty}, ptr_ty, 0);
            const add_proto_fn, const add_proto_ty = self.e.lazyDeclareCRuntime("class_addProtocol", &[_]c.LLVMTypeRef{ ptr_ty, ptr_ty }, i8_ty, 0);
            for (fcd.members) |m| switch (m) {
                .implements => |proto_alias| {
                    const proto_str_global = self.e.emitPrivateCString(proto_alias, "OBJC_PROTOCOL_NAME_");
                    var gp_args: [1]c.LLVMValueRef = .{proto_str_global};
                    const proto_val = c.LLVMBuildCall2(self.e.builder, get_proto_ty, get_proto_fn, &gp_args, 1, "proto");
                    var ap_args: [2]c.LLVMValueRef = .{ cls_val, proto_val };
                    _ = c.LLVMBuildCall2(self.e.builder, add_proto_ty, add_proto_fn, &ap_args, 2, "");
                },
                else => {},
            };

            // objc_registerClassPair(cls)
            var reg_args: [1]c.LLVMValueRef = .{cls_val};
            _ = c.LLVMBuildCall2(self.e.builder, register_ty, register_fn, &reg_args, 1, "");

            // Cache the class pointer in `__<Cls>_class` global so the
            // synthesized -dealloc trampoline (M1.2 A.6) can use it for
            // [super dealloc] dispatch via objc_msgSendSuper2.
            const class_global_name = std.fmt.allocPrint(self.e.alloc, "__{s}_class", .{class_name}) catch continue;
            defer self.e.alloc.free(class_global_name);
            const class_global_z = self.e.alloc.dupeZ(u8, class_global_name) catch continue;
            defer self.e.alloc.free(class_global_z);
            const class_global = c.LLVMGetNamedGlobal(self.e.llvm_module, class_global_z.ptr);
            if (class_global != null) {
                _ = c.LLVMBuildStore(self.e.builder, cls_val, class_global);
            }

            // M1.2 A.6 — register the synthesized `-dealloc` IMP on the
            // class itself (instance method). The runtime fires it at
            // refcount-zero; the IMP frees __sx_state and chains to
            // [super dealloc].
            const dealloc_imp_name = std.fmt.allocPrint(self.e.alloc, "__{s}_dealloc_imp", .{class_name}) catch continue;
            defer self.e.alloc.free(dealloc_imp_name);
            const dealloc_imp_z = self.e.alloc.dupeZ(u8, dealloc_imp_name) catch continue;
            defer self.e.alloc.free(dealloc_imp_z);
            const dealloc_imp_fn = c.LLVMGetNamedFunction(self.e.llvm_module, dealloc_imp_z.ptr);
            if (dealloc_imp_fn != null) {
                const dealloc_sel_global = self.e.emitPrivateCString("dealloc", "OBJC_METH_VAR_NAME_");
                const dealloc_enc_global = self.e.emitPrivateCString("v@:", "OBJC_METH_VAR_TYPE_");

                var sel_args: [1]c.LLVMValueRef = .{dealloc_sel_global};
                const sel_val = c.LLVMBuildCall2(self.e.builder, sel_reg_ty, sel_reg_fn, &sel_args, 1, "sel_dealloc");

                var add_args: [4]c.LLVMValueRef = .{ cls_val, sel_val, dealloc_imp_fn, dealloc_enc_global };
                _ = c.LLVMBuildCall2(self.e.builder, add_method_ty, add_method_fn, &add_args, 4, "");
            }

            // M1.2 A.5 — register the synthesized `+alloc` IMP on the
            // metaclass. Class methods live on the metaclass (every
            // Class object's `isa` points to the metaclass), so we
            // resolve it via `object_getClass(cls)` and `class_addMethod`
            // the IMP there. Encoding `@@:` = returns id, takes Class,
            // then SEL — Apple's standard `+alloc` shape. This override
            // wins over NSObject's default +alloc; runtime instantiations
            // (UIKit, Info.plist, NSCoder) go through our IMP and get the
            // __sx_state ivar bound.
            const alloc_imp_name = std.fmt.allocPrint(self.e.alloc, "__{s}_alloc_imp", .{class_name}) catch continue;
            defer self.e.alloc.free(alloc_imp_name);
            const alloc_imp_z = self.e.alloc.dupeZ(u8, alloc_imp_name) catch continue;
            defer self.e.alloc.free(alloc_imp_z);
            const alloc_imp_fn = c.LLVMGetNamedFunction(self.e.llvm_module, alloc_imp_z.ptr);
            if (alloc_imp_fn != null) {
                // metaclass_val was computed up-front above (shared
                // with class-method registration). +alloc is a class
                // method registered on the metaclass.
                const alloc_sel_global = self.e.emitPrivateCString("alloc", "OBJC_METH_VAR_NAME_");
                const alloc_enc_global = self.e.emitPrivateCString("@@:", "OBJC_METH_VAR_TYPE_");

                var sel_args: [1]c.LLVMValueRef = .{alloc_sel_global};
                const sel_val = c.LLVMBuildCall2(self.e.builder, sel_reg_ty, sel_reg_fn, &sel_args, 1, "sel_alloc");

                var add_args: [4]c.LLVMValueRef = .{ metaclass_val, sel_val, alloc_imp_fn, alloc_enc_global };
                _ = c.LLVMBuildCall2(self.e.builder, add_method_ty, add_method_fn, &add_args, 4, "");
            }

            // Cache the ivar handle in the per-class global so trampolines
            // can read the __sx_state ivar without re-looking-it-up. The
            // global is declared by lower.zig (M1.2 A.4b.i) and starts as
            // null; the constructor fills it in here.
            const ivar_global_name = std.fmt.allocPrint(self.e.alloc, "__{s}_state_ivar", .{class_name}) catch continue;
            defer self.e.alloc.free(ivar_global_name);
            const ivar_global_z = self.e.alloc.dupeZ(u8, ivar_global_name) catch continue;
            defer self.e.alloc.free(ivar_global_z);
            const ivar_global = c.LLVMGetNamedGlobal(self.e.llvm_module, ivar_global_z.ptr);
            if (ivar_global != null) {
                var iv_args: [2]c.LLVMValueRef = .{ cls_val, sx_state_name_global };
                const iv_val = c.LLVMBuildCall2(self.e.builder, get_iv_ty, get_iv_fn, &iv_args, 2, "iv");
                _ = c.LLVMBuildStore(self.e.builder, iv_val, ivar_global);
            }
        }
        _ = c.LLVMBuildRetVoid(self.e.builder);

        // Inject the call into main's entry block ONLY — skip
        // @llvm.global_ctors. Apple's frameworks (UIKit on iOS,
        // AppKit on macOS) register their Obj-C classes during
        // dyld's image-init phase, which overlaps global_ctors. If
        // we ran there too, `objc_getClass("UIResponder")` would
        // return null and `objc_allocateClassPair(null, ...)` would
        // crash inside objc_registerClassPair. main's entry runs
        // AFTER dyld's framework init is complete but BEFORE user
        // code (UIApplicationMain), so the runtime sees the parent
        // class properly.
        self.e.injectCtorIntoMain(ctor, ctor_ty);

        _ = i32_ty;
    }

    /// Return `{cls_slot, mid_slot}` global pair for the
    /// `(name, sig)` literal — created on first lookup, shared across
    /// later `#jni_call` sites with the same literal pair. Both
    /// slots are zero-initialized `ptr`; the call-site lowering does
    /// lazy population on first dispatch. The cache (`jni_slots`) +
    /// `mangleJniKey` stay on `LLVMEmitter`.
    pub fn getOrCreateJniSlots(self: FfiCtors, name: []const u8, sig: []const u8) JniSlotPair {
        // Compose the key from name + a separator + sig. The separator
        // is a byte that can't appear in a JNI method name or signature
        // (NUL), so the same key never collides across distinct pairs.
        const key = std.fmt.allocPrint(self.e.alloc, "{s}\x00{s}", .{ name, sig }) catch unreachable;
        if (self.e.jni_slots.get(key)) |existing| {
            self.e.alloc.free(key);
            return existing;
        }
        const mangled = self.e.mangleJniKey(name, sig);
        defer self.e.alloc.free(mangled);
        const cls_name = std.fmt.allocPrintSentinel(self.e.alloc, "SX_JNI_CLS_{s}", .{mangled}, 0) catch unreachable;
        defer self.e.alloc.free(cls_name);
        const mid_name = std.fmt.allocPrintSentinel(self.e.alloc, "SX_JNI_MID_{s}", .{mangled}, 0) catch unreachable;
        defer self.e.alloc.free(mid_name);
        const cls_slot = c.LLVMAddGlobal(self.e.llvm_module, self.e.cached_ptr, cls_name.ptr);
        c.LLVMSetLinkage(cls_slot, c.LLVMInternalLinkage);
        c.LLVMSetInitializer(cls_slot, c.LLVMConstNull(self.e.cached_ptr));
        const mid_slot = c.LLVMAddGlobal(self.e.llvm_module, self.e.cached_ptr, mid_name.ptr);
        c.LLVMSetLinkage(mid_slot, c.LLVMInternalLinkage);
        c.LLVMSetInitializer(mid_slot, c.LLVMConstNull(self.e.cached_ptr));
        const pair = JniSlotPair{ .cls_slot = cls_slot, .mid_slot = mid_slot };
        self.e.jni_slots.put(key, pair) catch unreachable;
        return pair;
    }
};
