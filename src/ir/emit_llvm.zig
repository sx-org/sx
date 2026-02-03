const std = @import("std");
const Allocator = std.mem.Allocator;
const llvm = @import("../llvm_api.zig");
const c = llvm.c;
const target_mod = @import("../target.zig");
const TargetConfig = target_mod.TargetConfig;
const ir_types = @import("types.zig");
const TypeId = ir_types.TypeId;
const TypeInfo = ir_types.TypeInfo;
const TypeTable = ir_types.TypeTable;
const StringId = ir_types.StringId;
const errors = @import("../errors.zig");
const llvm_types = @import("../backend/llvm/types.zig");
const llvm_abi = @import("../backend/llvm/abi.zig");
const llvm_debug = @import("../backend/llvm/debug.zig");
const llvm_reflection = @import("../backend/llvm/reflection.zig");
const llvm_ffi_ctors = @import("../backend/llvm/ffi_ctors.zig");
const llvm_ops = @import("../backend/llvm/ops.zig");
const ir_inst = @import("inst.zig");
const Ref = ir_inst.Ref;
const Span = ir_inst.Span;
const BlockId = ir_inst.BlockId;
const FuncId = ir_inst.FuncId;
const GlobalId = ir_inst.GlobalId;
const Inst = ir_inst.Inst;
const Op = ir_inst.Op;
const Block = ir_inst.Block;
const Function = ir_inst.Function;
const Global = ir_inst.Global;
const ir_module = @import("module.zig");
const Module = ir_module.Module;
const compiler_hooks = @import("compiler_hooks.zig");
const Value = @import("comptime_value.zig").Value;
const comptime_vm = @import("comptime_vm.zig");
const build_opts = @import("build_opts");

// The vendored error-trace ring buffer (library/vendors/sx_trace_runtime/sx_trace.c)
// is linked into the compiler. Comptime `#run` evaluation pushes frames to it via
// extern `sx_trace_push` calls; after a `#run` we read it here to render the
// return trace for an escaping comptime error (E5.2).
extern fn sx_trace_len() u32;
extern fn sx_trace_frame_at(i: u32) u64;
extern fn sx_trace_clear() void;

fn isIdentByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}

/// JNI vtable slot offsets — indices into the `JNINativeInterface`
/// function-pointer array reachable via `*env`. Stable per the JNI
/// spec across versions; locked to the documented order in
/// `<jni.h>`. Slot numbers here MUST match the order of fields in
/// the C `JNINativeInterface_` struct.
pub const Jni = struct {
    pub const FindClass: u32 = 6;
    pub const NewGlobalRef: u32 = 21;
    pub const NewObject: u32 = 28;
    pub const GetObjectClass: u32 = 31;
    pub const GetMethodID: u32 = 33;
    // Call<Type>Method (instance, varargs variant). Each numeric type
    // has its own slot — distinct ABI per return type, so the JNI
    // runtime dispatches the right arg-shuffle for each.
    pub const CallObjectMethod: u32 = 34;
    pub const CallBooleanMethod: u32 = 37;
    pub const CallIntMethod: u32 = 49;
    pub const CallLongMethod: u32 = 52;
    pub const CallFloatMethod: u32 = 55;
    pub const CallDoubleMethod: u32 = 58;
    pub const CallVoidMethod: u32 = 61;
    // CallNonvirtual<T>Method (instance, super-dispatch variant). Used by
    // `super.method(args)` from inside a `#jni_main` Activity method body:
    // dispatch is bound to a specific class rather than going through the
    // vtable, so subclass overrides don't intercept the call. Signature:
    // `(JNIEnv*, jobject obj, jclass clazz, jmethodID, args...)`.
    pub const CallNonvirtualObjectMethod: u32 = 64;
    pub const CallNonvirtualBooleanMethod: u32 = 67;
    pub const CallNonvirtualIntMethod: u32 = 79;
    pub const CallNonvirtualLongMethod: u32 = 82;
    pub const CallNonvirtualFloatMethod: u32 = 85;
    pub const CallNonvirtualDoubleMethod: u32 = 88;
    pub const CallNonvirtualVoidMethod: u32 = 91;
    // Static-dispatch siblings — `target` IS already a `jclass`, so
    // no `GetObjectClass` step. `GetStaticMethodID` returns a
    // method-ID that's bound to a class+method+sig like the instance
    // variant; `CallStatic<Type>Method` dispatches without a `this`.
    pub const GetStaticMethodID: u32 = 113;
    pub const CallStaticObjectMethod: u32 = 114;
    pub const CallStaticBooleanMethod: u32 = 117;
    pub const CallStaticIntMethod: u32 = 129;
    pub const CallStaticLongMethod: u32 = 132;
    pub const CallStaticFloatMethod: u32 = 135;
    pub const CallStaticDoubleMethod: u32 = 138;
    pub const CallStaticVoidMethod: u32 = 141;
};

// ── LLVMEmitter ─────────────────────────────────────────────────────────
// Emits LLVM IR from an IR Module. This is the Phase 3 replacement for
// the AST-based codegen.

pub const LLVMEmitter = struct {
    // LLVM handles
    context: c.LLVMContextRef,
    llvm_module: c.LLVMModuleRef,
    builder: c.LLVMBuilderRef,
    target_machine: ?c.LLVMTargetMachineRef,

    // IR Module being emitted
    ir_mod: *const Module,

    // Set when a comptime `#run` raised an unhandled error (E5.2), or when a
    // global initializer could not be serialized to a valid static constant.
    // The driver (core.generateCode) aborts with a non-zero exit after emit()
    // when set, so an invalid/placeholder initializer never reaches the object
    // file or the JIT — the emit-time diagnostic is the surfaced error.
    comptime_failed: bool = false,
    // Set when LLVM emission encounters an IR invariant violation that has
    // already produced a specific diagnostic. The driver aborts before
    // verification/optimization/object emission, so malformed placeholder IR
    // is never allowed to continue through the backend.
    emission_failed: bool = false,
    // Production diagnostics are always on. IR unit tests that deliberately
    // construct malformed instructions disable printing while still asserting
    // the same emission-failure gate, keeping `zig build test` silent on success.
    print_emission_diagnostics: bool = true,
    /// Runtime-reachable set + the parent edges that found each function.
    /// Computed once at the top of `emit`; used to report the CALL PATH when a
    /// compile-time-only function turns out to be reachable from the binary.
    reach: ?@import("reachability.zig").Reachability = null,

    // When set (env `SX_COMPTIME_FLAT`, → a `-Dcomptime-flat` build flag later),
    // comptime const-init folds try the comptime VM (`comptime_vm.tryEval`)
    // first and fall back to the legacy tagged interpreter on null. Default OFF so
    // the corpus is unaffected until the VM reaches parity (Phase 1.final step d).
    comptime_flat: bool = false,

    // When set (env `SX_COMPTIME_FLAT_TRACE`, only meaningful with `comptime_flat`),
    // each comptime const-init reports to stderr whether the VM handled it or fell
    // back to the legacy interpreter (with the bail reason) — the coverage signal
    // for porting the next ops. Default OFF.
    comptime_flat_trace: bool = false,

    // When set (`-Dcomptime-flat-strict` / env `SX_COMPTIME_FLAT_STRICT`), a VM bail
    // does NOT fall back to the legacy interpreter — it becomes a build-gating error.
    // The enumeration gate for retiring `interp.zig`. Implies `comptime_flat`.
    comptime_flat_strict: bool = false,

    // Allocator for temporary bookkeeping
    alloc: Allocator,

    // Maps IR Ref → LLVM Value for the current function
    ref_map: std.AutoHashMap(u32, c.LLVMValueRef),

    // Maps IR FuncId → LLVM function value
    func_map: std.AutoHashMap(u32, c.LLVMValueRef),

    // Maps IR GlobalId → LLVM global value
    global_map: std.AutoHashMap(u32, c.LLVMValueRef),

    // Maps (func_idx, block_idx) → LLVM BasicBlock
    block_map: std.AutoHashMap(u64, c.LLVMBasicBlockRef),
    // For each IR block, the LLVM block its terminator was actually emitted
    // into. Usually equals `block_map[block]`, but an instruction can expand
    // into its own sub-CFG (string `==`'s memcmp blocks, a value `match`'s
    // arm blocks) and leave the builder in a later block, so the terminator —
    // and therefore the PHI predecessor edge — lands there instead. Keyed the
    // same way as `block_map`.
    term_block_map: std.AutoHashMap(u64, c.LLVMBasicBlockRef),

    // Cached LLVM types
    cached_i1: c.LLVMTypeRef,
    cached_i8: c.LLVMTypeRef,
    cached_i16: c.LLVMTypeRef,
    cached_i32: c.LLVMTypeRef,
    cached_i64: c.LLVMTypeRef,
    cached_f32: c.LLVMTypeRef,
    cached_f64: c.LLVMTypeRef,
    cached_ptr: c.LLVMTypeRef,
    cached_void: c.LLVMTypeRef,

    // Current ref counter — tracks which Ref index we're emitting within a function
    ref_counter: u32 = 0,

    // Pending PHI nodes to fixup after all blocks in a function are emitted
    pending_phis: std.ArrayList(PendingPhi),

    // Whether the current function being emitted is "main" (needs i32 return for JIT)
    current_func_is_main: bool = false,
    current_func_idx: u32 = 0,

    // Cached composite types
    string_struct_type: ?c.LLVMTypeRef,
    any_struct_type: ?c.LLVMTypeRef,
    closure_struct_type: ?c.LLVMTypeRef,
    // The shared `@objc_msgSend` function value. Lazily declared on
    // first `objc_msg_send` instruction; all `#objc_call` sites
    // dispatch through it with their own LLVMBuildCall2 function type
    // (opaque pointers — the function value is just a `ptr`).
    objc_msg_send_value: ?c.LLVMValueRef,
    // `(name, sig)` → `{cls_slot, mid_slot}` cache for `#jni_call`
    // interning (step 1.17). Two call sites with the same literal
    // name + signature share one pair of static slots, populated
    // lazily on the first call.
    jni_slots: std.StringHashMap(JniSlotPair),

    // Cached field name arrays for reflection (TypeId → LLVM global)
    field_name_arrays: std.AutoHashMap(u32, c.LLVMValueRef),
    // The always-linked tag-name table (global tag id → name); built once.
    tag_name_array: ?c.LLVMValueRef = null,

    // Lazy global `[N x string]` indexed by TypeId.index(), holding
    // each type's display name. Built on the first dynamic
    // `type_name(t)` call site; reused thereafter.
    type_name_array: ?c.LLVMValueRef = null,
    type_name_array_len: u32 = 0,

    // Lazy global `[N x i1]` indexed by TypeId.index(): true where the
    // type is an unsigned integer. Built on the first dynamic
    // `type_is_unsigned(t)` call site (the `{}` formatter's int branch).
    type_is_unsigned_array: ?c.LLVMValueRef = null,
    type_is_unsigned_array_len: u32 = 0,
    // 1a-S2 runtime-reflection scalar tables (lazy, tag-indexed [N x i64] /
    // [N x i1]); built on the first dynamic call site of their builtin.
    type_size_array: ?c.LLVMValueRef = null,
    type_size_array_len: u32 = 0,
    type_align_array: ?c.LLVMValueRef = null,
    type_align_array_len: u32 = 0,
    sf_count_array: ?c.LLVMValueRef = null,
    sf_count_array_len: u32 = 0,
    variant_count_array: ?c.LLVMValueRef = null,
    variant_count_array_len: u32 = 0,
    is_flags_array: ?c.LLVMValueRef = null,
    is_flags_array_len: u32 = 0,
    vector_lanes_array: ?c.LLVMValueRef = null,
    vector_lanes_array_len: u32 = 0,
    variant_tag_width_array: ?c.LLVMValueRef = null,
    variant_tag_width_array_len: u32 = 0,
    // 1a-S3b field-family master-index tables: [N x ptr] → per-type arrays.
    member_name_ptrs: ?c.LLVMValueRef = null,
    member_name_ptrs_len: u32 = 0,
    member_type_ptrs: ?c.LLVMValueRef = null,
    member_type_ptrs_len: u32 = 0,
    field_offset_ptrs: ?c.LLVMValueRef = null,
    field_offset_ptrs_len: u32 = 0,
    member_value_ptrs: ?c.LLVMValueRef = null,
    member_value_ptrs_len: u32 = 0,
    // 1a-S3b-3: runtime type_info records — [N x ptr] master to per-type
    // TypeInfo constants (each its own global; bytes match the sx layout).
    type_info_records: ?c.LLVMValueRef = null,
    type_info_records_len: u32 = 0,

    // Target configuration (stored for ABI decisions during emission)
    target_config: TargetConfig,

    // Build configuration accumulated from #run blocks
    build_config: compiler_hooks.BuildConfig,

    // ── DWARF debug info (ERR E3.0) ──────────────────────────────────
    // Emitted only when the build keeps error traces (opt_level
    // none/less, matching lower.zig's `tracesEnabled`) AND a source map
    // is wired in via `setDebugContext`. One `DICompileUnit` (on the
    // main file) + a `DIFile` per source file + a `DISubprogram` per
    // emitted function + a `DILocation` per instruction (resolved from
    // `Inst.span`). Lets a captured return-address PC resolve to
    // file:line:col for E3.3's runtime trace formatting, and makes sx
    // binaries debuggable in lldb/gdb as a bonus.
    di_builder: c.LLVMDIBuilderRef = null,
    di_cu: c.LLVMMetadataRef = null,
    di_files: std.StringHashMap(c.LLVMMetadataRef),
    // The current function's DISubprogram — the scope for its
    // DILocations. Null between functions (and in functions we don't
    // describe, e.g. the synthetic Obj-C init constructors).
    di_scope: c.LLVMMetadataRef = null,
    // Source file of the function currently being emitted (span → line).
    current_func_file: []const u8 = "",
    // File path → source text (the diagnostics' `import_sources` map).
    // Null in unit tests, so no debug info is emitted there.
    import_sources: ?*const std.StringHashMap([:0]const u8) = null,
    // Main file path — the compile unit's file and the span-resolution
    // fallback for functions with no recorded source file.
    main_file: []const u8 = "",

    // ── Error-trace `Frame` (ERR E3.0 slice 3a) ──────────────────────
    // The compiled return-trace frame type: `{ string file, i32 line,
    // i32 col, string func }`. Hand-built here (not looked up from a sx
    // `TypeId`) so traces work even when the program doesn't import the
    // module that declares `Frame`. The layout MUST stay in lockstep with
    // `Frame` in `library/modules/trace.sx` (sx-side reader) and `SxFrame`
    // in `sx_trace.c` (the failable-main reporter).
    frame_struct_type: ?c.LLVMTypeRef = null,
    // Interns the `{ptr,i64}` string constants the `Frame` globals embed,
    // keyed by content, so a file/func name shared by N push sites is
    // emitted once. Keys are owned.
    frame_str_cache: std.StringHashMap(c.LLVMValueRef),

    const PendingPhi = struct {
        phi: c.LLVMValueRef,
        block_id: BlockId, // the block this phi belongs to
        param_index: u32,
    };

    pub const JniSlotPair = struct {
        cls_slot: c.LLVMValueRef, // @SX_JNI_CLS_<key>: ptr (GlobalRef to jclass)
        mid_slot: c.LLVMValueRef, // @SX_JNI_MID_<key>: ptr (jmethodID)
    };

    pub fn init(alloc: Allocator, ir_mod: *const Module, module_name: [*:0]const u8, target_config: TargetConfig) LLVMEmitter {
        // Initialize LLVM targets
        if (target_config.triple == null) {
            llvm.initNativeTarget();
        } else {
            llvm.initAllTargets();
        }

        const ctx = c.LLVMContextCreate();
        const llvm_module = c.LLVMModuleCreateWithNameInContext(module_name, ctx);
        const builder = c.LLVMCreateBuilderInContext(ctx);

        // Set target triple. Normalize first: zig-scheme, vendor-less triples
        // (e.g. "x86_64-windows-gnu") would otherwise have "windows" land in
        // LLVM's vendor slot under its positional parser, leaving OS=unknown
        // and the object format silently falling back to ELF. Normalization is
        // LLVM's own reordering — not a hand-maintained translation table.
        const raw_owned = target_config.triple == null;
        const raw_triple = target_config.triple orelse c.LLVMGetDefaultTargetTriple();
        defer if (raw_owned) c.LLVMDisposeMessage(@constCast(raw_triple));
        const triple = c.LLVMNormalizeTargetTriple(raw_triple);
        defer c.LLVMDisposeMessage(triple);

        c.LLVMSetTarget(llvm_module, triple);

        // Create target machine and set data layout
        var target: c.LLVMTargetRef = null;
        var err_msg: [*c]u8 = null;
        var tm: c.LLVMTargetMachineRef = null;
        if (c.LLVMGetTargetFromTriple(triple, &target, &err_msg) == 0) {
            tm = c.LLVMCreateTargetMachine(
                target,
                triple,
                target_config.getCpu(),
                target_config.getFeatures(),
                target_config.opt_level.toLLVM(),
                c.LLVMRelocPIC,
                c.LLVMCodeModelDefault,
            );
            const dl = c.LLVMCreateTargetDataLayout(tm);
            c.LLVMSetModuleDataLayout(llvm_module, dl);
            c.LLVMDisposeTargetData(dl);
        } else {
            if (err_msg != null) c.LLVMDisposeMessage(err_msg);
        }

        return .{
            .context = ctx,
            .llvm_module = llvm_module,
            .builder = builder,
            .target_machine = tm,
            .ir_mod = ir_mod,
            .alloc = alloc,
            .ref_map = std.AutoHashMap(u32, c.LLVMValueRef).init(alloc),
            .func_map = std.AutoHashMap(u32, c.LLVMValueRef).init(alloc),
            .global_map = std.AutoHashMap(u32, c.LLVMValueRef).init(alloc),
            .block_map = std.AutoHashMap(u64, c.LLVMBasicBlockRef).init(alloc),
            .term_block_map = std.AutoHashMap(u64, c.LLVMBasicBlockRef).init(alloc),
            .pending_phis = std.ArrayList(PendingPhi).empty,
            .cached_i1 = c.LLVMInt1TypeInContext(ctx),
            .cached_i8 = c.LLVMInt8TypeInContext(ctx),
            .cached_i16 = c.LLVMInt16TypeInContext(ctx),
            .cached_i32 = c.LLVMInt32TypeInContext(ctx),
            .cached_i64 = c.LLVMInt64TypeInContext(ctx),
            .cached_f32 = c.LLVMFloatTypeInContext(ctx),
            .cached_f64 = c.LLVMDoubleTypeInContext(ctx),
            .cached_ptr = c.LLVMPointerTypeInContext(ctx, 0),
            .cached_void = c.LLVMVoidTypeInContext(ctx),
            .string_struct_type = null,
            .any_struct_type = null,
            .closure_struct_type = null,
            .objc_msg_send_value = null,
            .jni_slots = std.StringHashMap(JniSlotPair).init(alloc),
            .field_name_arrays = std.AutoHashMap(u32, c.LLVMValueRef).init(alloc),
            .target_config = target_config,
            .build_config = .{},
            .di_files = std.StringHashMap(c.LLVMMetadataRef).init(alloc),
            .frame_str_cache = std.StringHashMap(c.LLVMValueRef).init(alloc),
            // Enabled by the `-Dcomptime-flat` build flag OR the `SX_COMPTIME_FLAT`
            // env var (either turns it on); default OFF (legacy interpreter).
            .comptime_flat = build_opts.comptime_flat or std.c.getenv("SX_COMPTIME_FLAT") != null or
                build_opts.comptime_flat_strict or std.c.getenv("SX_COMPTIME_FLAT_STRICT") != null,
            .comptime_flat_trace = std.c.getenv("SX_COMPTIME_FLAT_TRACE") != null,
            .comptime_flat_strict = build_opts.comptime_flat_strict or std.c.getenv("SX_COMPTIME_FLAT_STRICT") != null,
        };
    }

    pub fn deinit(self: *LLVMEmitter) void {
        if (self.reach) |*r| r.deinit();
        self.build_config.deinit(self.alloc);
        self.ref_map.deinit();
        self.func_map.deinit();
        self.field_name_arrays.deinit();
        var jni_it = self.jni_slots.keyIterator();
        while (jni_it.next()) |k| self.alloc.free(k.*);
        self.jni_slots.deinit();
        self.global_map.deinit();
        self.block_map.deinit();
        self.term_block_map.deinit();
        self.di_files.deinit();
        var fsc_it = self.frame_str_cache.keyIterator();
        while (fsc_it.next()) |k| self.alloc.free(k.*);
        self.frame_str_cache.deinit();
        if (self.di_builder != null) c.LLVMDisposeDIBuilder(self.di_builder);
        if (self.target_machine) |tm| c.LLVMDisposeTargetMachine(tm);
        c.LLVMDisposeBuilder(self.builder);
        c.LLVMDisposeModule(self.llvm_module);
        c.LLVMContextDispose(self.context);
    }

    // ── Top-level emit ──────────────────────────────────────────────

    pub fn emit(self: *LLVMEmitter) void {
        // Which functions can the binary actually reach, and via what path? A
        // compile-time-only callee found in that set is a staging error, and the
        // path is what makes it actionable — the immediate caller alone rarely
        // says why a `#run`-only helper ended up in the runtime graph.
        if (@import("reachability.zig").compute(self.alloc, self.ir_mod)) |r| {
            self.reach = r;
        } else |_| {
            // OOM computing reachability: leave `reach` null. The gates below
            // still fire, they just report without a path.
            self.reach = null;
        }

        // Pass -1: Set up DWARF debug info (compile unit + module flags).
        // Must precede any DISubprogram (created per function below).
        self.debugInfo().initDebugInfo();

        // Top-level global asm (ASM stream Phase F): append each block verbatim
        // to the module. Multiple blocks concatenate in source order; LLVM emits
        // them as module-level `module asm`. Symbols they define are reached via
        // lib-less `extern` declarations.
        for (self.ir_mod.global_asm.items) |asm_text| {
            c.LLVMAppendModuleInlineAsm(self.llvm_module, asm_text.ptr, asm_text.len);
        }

        // Pass 0: Declare and initialize globals
        self.emitGlobals();

        // Pass 0.5: Run comptime side-effect functions (#run expr; at top level)
        self.runComptimeSideEffects();

        // A comptime/global init failure (e.g. an unbridgeable `#run` result)
        // sets `comptime_failed` AND leaves the failed const's type as the
        // `.unresolved` sentinel. The driver converts `comptime_failed` into a
        // clean exit-1 *after* emit() returns — but the remaining passes
        // (declare/emit function bodies that reference the now-unresolved const)
        // would `@panic("unresolved type reached LLVM emission")` first. Abort
        // emission here so the failure surfaces as the printed diagnostic +
        // clean exit, never the panic.
        if (self.comptime_failed) return;

        // Pass 1: Declare all functions (so calls can reference them)
        for (self.ir_mod.functions.items, 0..) |func, i| {
            self.declareFunction(&func, @intCast(i));
        }

        // Pass 1.5: Initialize vtable globals (needs function declarations from Pass 1)
        self.initVtableGlobals();

        // Pass 2: Emit function bodies
        for (self.ir_mod.functions.items, 0..) |func, i| {
            if (func.is_extern or func.blocks.items.len == 0) continue;
            // Emit only what the runtime can reach. Anything else — a `#run`
            // wrapper, a build callback, a helper only they call, an unused
            // stdlib function — is dead code for the binary and is neither
            // declared (below) nor defined here.
            if (self.reach) |r| {
                if (!r.emits(ir_inst.FuncId.fromIndex(@intCast(i)))) continue;
            }
            // `abi(.naked)` functions emit normally — the `naked` attribute (set
            // in the declaration pass) makes the backend emit the body (inline
            // asm + its own `ret`) with no prologue/epilogue. See Function.is_naked.
            self.emitFunction(&func, @intCast(i));
            if (self.emission_failed) return;
        }

        // Pass 2.5: Emit Obj-C selector init constructor (Phase 1.5).
        self.ffiCtors().emitObjcSelectorInit();

        // Pass 2.5b: Emit Obj-C class-pair registration constructor for
        // sx-defined classes (M1.2 A.4+). Runs BEFORE the runtime
        // class-cache populator (2.5c) so a sx-defined class is already
        // registered with the Obj-C runtime by the time
        // `objc_getClass(\"SxFoo\")` runs to populate the Phase 3.1
        // class-object cache — otherwise the cache slot would store
        // null and `SxFoo.method()` dispatches against null.
        self.ffiCtors().emitObjcDefinedClassInit();

        // Pass 2.5c: Emit Obj-C class-object init constructor (Phase 3.1).
        // Same shape as the selector init — populates the per-module
        // cached `Class*` slots via `objc_getClass` at module-init time.
        self.ffiCtors().emitObjcClassInit();

        // Pass 2.6: On macOS, chdir to the .app bundle's Resources dir at
        // startup so relative asset paths work when Finder/`open`
        // launches the binary with CWD=/. Non-bundled binaries no-op.
        self.emitMacosBundleChdir();

        // Pass 3: Verify typeSizeBytes matches LLVM's ABI sizes
        self.verifySizes();

        // Pass 4: Resolve DWARF temporary metadata. Must come after all
        // DISubprograms / DILocations are created and before the module
        // is verified or emitted.
        self.debugInfo().finalizeDebugInfo();
    }

    // ── DWARF debug info (ERR E3.0) ──────────────────────────────────

    /// Wire the source map + main file so spans can resolve to
    /// file:line:col. Called by the driver after `init`; absent in unit
    /// tests, which keeps debug-info emission off there.
    pub fn setDebugContext(self: *LLVMEmitter, import_sources: *const std.StringHashMap([:0]const u8), main_file: []const u8) void {
        self.import_sources = import_sources;
        self.main_file = main_file;
    }

    /// Source text for `file` via the diagnostics' file→source map (the
    /// same map `#caller_location` uses). Empty when unavailable —
    /// line:col then degrades to 1:1 rather than crash.
    pub fn sourceForFile(self: *LLVMEmitter, file: []const u8) []const u8 {
        const is = self.import_sources orelse return "";
        if (is.get(file)) |s| return s;
        if (self.main_file.len > 0) {
            if (is.get(self.main_file)) |s| return s;
        }
        return "";
    }

    /// Lazy-declare an extern C runtime function. Returns (fn-value, fn-type).
    pub fn lazyDeclareCRuntime(self: *LLVMEmitter, name: []const u8, params: []const c.LLVMTypeRef, ret_ty: c.LLVMTypeRef, is_var_arg: c_int) struct { c.LLVMValueRef, c.LLVMTypeRef } {
        const name_z = self.alloc.dupeZ(u8, name) catch unreachable;
        defer self.alloc.free(name_z);
        var fn_value = c.LLVMGetNamedFunction(self.llvm_module, name_z.ptr);
        var fn_ty: c.LLVMTypeRef = undefined;
        if (fn_value == null) {
            fn_ty = c.LLVMFunctionType(ret_ty, @constCast(params.ptr), @intCast(params.len), is_var_arg);
            fn_value = c.LLVMAddFunction(self.llvm_module, name_z.ptr, fn_ty);
            c.LLVMSetLinkage(fn_value, c.LLVMExternalLinkage);
        } else {
            fn_ty = c.LLVMGlobalGetValueType(fn_value);
        }
        return .{ fn_value, fn_ty };
    }

    /// Emit a private constant C string global. Used for class names,
    /// selector names, etc. consumed by the Obj-C runtime.
    pub fn emitPrivateCString(self: *LLVMEmitter, s: []const u8, name_hint: []const u8) c.LLVMValueRef {
        const s_z = self.alloc.allocSentinel(u8, s.len, 0) catch unreachable;
        defer self.alloc.free(s_z);
        @memcpy(s_z[0..s.len], s);
        const str_const = c.LLVMConstStringInContext(self.context, s_z.ptr, @intCast(s.len), 0);
        const name_z = self.alloc.dupeZ(u8, name_hint) catch unreachable;
        defer self.alloc.free(name_z);
        const str_global = c.LLVMAddGlobal(self.llvm_module, c.LLVMTypeOf(str_const), name_z.ptr);
        c.LLVMSetInitializer(str_global, str_const);
        c.LLVMSetLinkage(str_global, c.LLVMPrivateLinkage);
        c.LLVMSetGlobalConstant(str_global, 1);
        c.LLVMSetUnnamedAddress(str_global, c.LLVMGlobalUnnamedAddr);
        return str_global;
    }

    /// Append a constructor entry to `@llvm.global_ctors` (creating the
    /// global if not present, extending the array if so) AND inject a
    /// direct call from `main`'s entry block so the ORC JIT path runs
    /// the constructor too.
    /// Inject a call to `ctor()` at the start of `main`'s entry block
    /// (past any existing init calls). Used by class-pair init etc.
    /// that need to run BEFORE user code but AFTER dyld's framework
    /// load — global_ctors is too early because Apple frameworks
    /// (UIKit etc.) register their Obj-C classes during their own
    /// init phase that overlaps ours.
    pub fn injectCtorIntoMain(self: *LLVMEmitter, ctor: c.LLVMValueRef, ctor_ty: c.LLVMTypeRef) void {
        const main_z = "main";
        const main_fn = c.LLVMGetNamedFunction(self.llvm_module, main_z);
        if (main_fn == null) return;
        const entry_bb = c.LLVMGetEntryBasicBlock(main_fn);
        var insert_before = c.LLVMGetFirstInstruction(entry_bb);
        while (insert_before != null) : (insert_before = c.LLVMGetNextInstruction(insert_before)) {
            if (c.LLVMGetInstructionOpcode(insert_before) != c.LLVMCall) break;
        }
        if (insert_before != null) {
            c.LLVMPositionBuilderBefore(self.builder, insert_before);
        } else {
            c.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
        }
        var no_args: [0]c.LLVMValueRef = .{};
        _ = c.LLVMBuildCall2(self.builder, ctor_ty, ctor, &no_args, 0, "");
    }

    fn appendModuleCtor(self: *LLVMEmitter, ctor: c.LLVMValueRef, ctor_ty: c.LLVMTypeRef) void {
        const i32_ty = self.cached_i32;
        const ptr_ty = self.cached_ptr;
        var ctor_field_types: [3]c.LLVMTypeRef = .{ i32_ty, ptr_ty, ptr_ty };
        const ctor_struct_ty = c.LLVMStructTypeInContext(self.context, &ctor_field_types, 3, 0);
        var ctor_fields: [3]c.LLVMValueRef = .{
            c.LLVMConstInt(i32_ty, 65535, 0),
            ctor,
            c.LLVMConstNull(ptr_ty),
        };
        const ctor_entry = c.LLVMConstNamedStruct(ctor_struct_ty, &ctor_fields, 3);

        const existing_z = "llvm.global_ctors";
        const existing = c.LLVMGetNamedGlobal(self.llvm_module, existing_z);
        if (existing != null) {
            const existing_init = c.LLVMGetInitializer(existing);
            const existing_arr_ty = c.LLVMGlobalGetValueType(existing);
            const old_count = c.LLVMGetArrayLength(existing_arr_ty);
            const new_count: c_uint = old_count + 1;
            var new_entries = std.ArrayList(c.LLVMValueRef).empty;
            defer new_entries.deinit(self.alloc);
            var i: c_uint = 0;
            while (i < old_count) : (i += 1) {
                new_entries.append(self.alloc, c.LLVMGetAggregateElement(existing_init, i)) catch unreachable;
            }
            new_entries.append(self.alloc, ctor_entry) catch unreachable;
            const new_arr_ty = c.LLVMArrayType2(ctor_struct_ty, new_count);
            const new_init = c.LLVMConstArray2(ctor_struct_ty, new_entries.items.ptr, new_count);
            const new_global = c.LLVMAddGlobal(self.llvm_module, new_arr_ty, "llvm.global_ctors.new");
            c.LLVMSetInitializer(new_global, new_init);
            c.LLVMSetLinkage(new_global, c.LLVMAppendingLinkage);
            c.LLVMSetValueName2(existing, "llvm.global_ctors.old", "llvm.global_ctors.old".len);
            c.LLVMSetValueName2(new_global, "llvm.global_ctors", "llvm.global_ctors".len);
            c.LLVMDeleteGlobal(existing);
        } else {
            const ctors_arr_ty = c.LLVMArrayType2(ctor_struct_ty, 1);
            var ctor_entries: [1]c.LLVMValueRef = .{ctor_entry};
            const ctors_init = c.LLVMConstArray2(ctor_struct_ty, &ctor_entries, 1);
            const ctors_global = c.LLVMAddGlobal(self.llvm_module, ctors_arr_ty, "llvm.global_ctors");
            c.LLVMSetInitializer(ctors_global, ctors_init);
            c.LLVMSetLinkage(ctors_global, c.LLVMAppendingLinkage);
        }

        // ORC JIT: inject a direct call at the end of main's prelude
        // (past any existing init calls).
        const main_z = "main";
        const main_fn = c.LLVMGetNamedFunction(self.llvm_module, main_z);
        if (main_fn != null) {
            const entry_bb = c.LLVMGetEntryBasicBlock(main_fn);
            var insert_before = c.LLVMGetFirstInstruction(entry_bb);
            while (insert_before != null) : (insert_before = c.LLVMGetNextInstruction(insert_before)) {
                if (c.LLVMGetInstructionOpcode(insert_before) != c.LLVMCall) break;
            }
            if (insert_before != null) {
                c.LLVMPositionBuilderBefore(self.builder, insert_before);
            } else {
                c.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
            }
            var no_args: [0]c.LLVMValueRef = .{};
            _ = c.LLVMBuildCall2(self.builder, ctor_ty, ctor, &no_args, 0, "");
        }
    }

    /// On macOS, emit a startup helper that chdir's to the .app bundle's
    /// `Contents/Resources` directory when the executable lives inside a
    /// `.app/Contents/MacOS/` path. Lets relative asset paths like
    /// `assets/foo.png` resolve correctly when Finder/`open` launches the
    /// binary with CWD=/.
    ///
    /// Bundled binary: strstr finds the marker, chdir succeeds.
    /// CLI binary / `sx run`: strstr returns null, the function no-ops.
    ///
    /// The call is injected at the very start of `main()` (matching the
    /// pattern used for the Obj-C selector init) rather than registered
    /// via `@llvm.global_ctors`, so the ORC JIT path runs it too without
    /// special handling.
    fn emitMacosBundleChdir(self: *LLVMEmitter) void {
        if (!self.target_config.is_aot) return;
        if (!self.target_config.isMacOS()) return;

        const ptr_ty = self.cached_ptr;
        const i32_ty = self.cached_i32;
        const i8_ty = self.cached_i8;
        const void_ty = self.cached_void;

        // Declare libc externs (re-use if already declared).
        var ns_params: [2]c.LLVMTypeRef = .{ ptr_ty, ptr_ty };
        const ns_ty = c.LLVMFunctionType(i32_ty, &ns_params, 2, 0);
        var ns_fn = c.LLVMGetNamedFunction(self.llvm_module, "_NSGetExecutablePath");
        if (ns_fn == null) ns_fn = c.LLVMAddFunction(self.llvm_module, "_NSGetExecutablePath", ns_ty);

        var chdir_params: [1]c.LLVMTypeRef = .{ptr_ty};
        const chdir_ty = c.LLVMFunctionType(i32_ty, &chdir_params, 1, 0);
        var chdir_fn = c.LLVMGetNamedFunction(self.llvm_module, "chdir");
        if (chdir_fn == null) chdir_fn = c.LLVMAddFunction(self.llvm_module, "chdir", chdir_ty);

        var ss_params: [2]c.LLVMTypeRef = .{ ptr_ty, ptr_ty };
        const ss_ty = c.LLVMFunctionType(ptr_ty, &ss_params, 2, 0);
        var ss_fn = c.LLVMGetNamedFunction(self.llvm_module, "strstr");
        if (ss_fn == null) ss_fn = c.LLVMAddFunction(self.llvm_module, "strstr", ss_ty);

        var sc_params: [2]c.LLVMTypeRef = .{ ptr_ty, ptr_ty };
        const sc_ty = c.LLVMFunctionType(ptr_ty, &sc_params, 2, 0);
        var sc_fn = c.LLVMGetNamedFunction(self.llvm_module, "strcpy");
        if (sc_fn == null) sc_fn = c.LLVMAddFunction(self.llvm_module, "strcpy", sc_ty);

        var no_params: [0]c.LLVMTypeRef = .{};
        const ctor_ty = c.LLVMFunctionType(void_ty, &no_params, 0, 0);
        const ctor = c.LLVMAddFunction(self.llvm_module, "__sx_macos_bundle_chdir", ctor_ty);
        c.LLVMSetLinkage(ctor, c.LLVMInternalLinkage);

        const entry_bb = c.LLVMAppendBasicBlockInContext(self.context, ctor, "entry");
        const found_bb = c.LLVMAppendBasicBlockInContext(self.context, ctor, "found");
        const done_bb = c.LLVMAppendBasicBlockInContext(self.context, ctor, "done");

        c.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

        const buf_ty = c.LLVMArrayType2(i8_ty, 1024);
        const buf = c.LLVMBuildAlloca(self.builder, buf_ty, "buf");
        const bufsize = c.LLVMBuildAlloca(self.builder, i32_ty, "bufsize");
        _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(i32_ty, 1024, 0), bufsize);

        var ns_args: [2]c.LLVMValueRef = .{ buf, bufsize };
        _ = c.LLVMBuildCall2(self.builder, ns_ty, ns_fn, &ns_args, 2, "");

        const needle = self.emitCStringGlobal("/Contents/MacOS/", "__sx_macos_chdir_needle");
        const replacement = self.emitCStringGlobal("/Contents/Resources", "__sx_macos_chdir_replacement");

        var ss_args: [2]c.LLVMValueRef = .{ buf, needle };
        const p = c.LLVMBuildCall2(self.builder, ss_ty, ss_fn, &ss_args, 2, "p");

        const is_null = c.LLVMBuildIsNull(self.builder, p, "is_null");
        _ = c.LLVMBuildCondBr(self.builder, is_null, done_bb, found_bb);

        c.LLVMPositionBuilderAtEnd(self.builder, found_bb);
        var sc_args: [2]c.LLVMValueRef = .{ p, replacement };
        _ = c.LLVMBuildCall2(self.builder, sc_ty, sc_fn, &sc_args, 2, "");
        var chdir_args: [1]c.LLVMValueRef = .{buf};
        _ = c.LLVMBuildCall2(self.builder, chdir_ty, chdir_fn, &chdir_args, 1, "");
        _ = c.LLVMBuildBr(self.builder, done_bb);

        c.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        _ = c.LLVMBuildRetVoid(self.builder);

        // Inject a call at the very start of main(). Matches the
        // emitObjcSelectorInit pattern so the ORC JIT path picks it up
        // without needing `@llvm.global_ctors` plumbing.
        const main_fn = c.LLVMGetNamedFunction(self.llvm_module, "main");
        if (main_fn != null) {
            const main_entry = c.LLVMGetEntryBasicBlock(main_fn);
            const first_inst = c.LLVMGetFirstInstruction(main_entry);
            if (first_inst != null) {
                c.LLVMPositionBuilderBefore(self.builder, first_inst);
            } else {
                c.LLVMPositionBuilderAtEnd(self.builder, main_entry);
            }
            var no_args: [0]c.LLVMValueRef = .{};
            _ = c.LLVMBuildCall2(self.builder, ctor_ty, ctor, &no_args, 0, "");
        }
    }

    /// Build an LLVM-friendly identifier suffix from a JNI
    /// `(method_name, signature)` pair. Non-identifier characters are
    /// rewritten to `_`; the resulting string is unique per pair (the
    /// caller guarantees uniqueness on `(name, sig)`, which we
    /// preserve through the separator between mangled name and sig).
    pub fn mangleJniKey(self: *LLVMEmitter, name: []const u8, sig: []const u8) []u8 {
        var buf = std.ArrayList(u8).empty;
        for (name) |b| buf.append(self.alloc, if (isIdentByte(b)) b else '_') catch unreachable;
        buf.appendSlice(self.alloc, "__") catch unreachable;
        for (sig) |b| buf.append(self.alloc, if (isIdentByte(b)) b else '_') catch unreachable;
        return buf.toOwnedSlice(self.alloc) catch unreachable;
    }

    /// If `val` is a `{ptr, i64}` slice struct, extract field 0
    /// (the ptr); otherwise return it unchanged. Used by JNI dispatch
    /// to feed string-literal method names + signatures to
    /// `GetMethodID`, which expects raw C strings.
    pub fn extractSlicePtr(self: *LLVMEmitter, val: c.LLVMValueRef) c.LLVMValueRef {
        const val_ty = c.LLVMTypeOf(val);
        if (c.LLVMGetTypeKind(val_ty) != c.LLVMStructTypeKind) return val;
        if (c.LLVMCountStructElementTypes(val_ty) != 2) return val;
        const f0 = c.LLVMStructGetTypeAtIndex(val_ty, 0);
        if (c.LLVMGetTypeKind(f0) != c.LLVMPointerTypeKind) return val;
        return c.LLVMBuildExtractValue(self.builder, val, 0, "jni.str.ptr");
    }

    /// Load a JNI vtable function pointer at the given offset. `ifs`
    /// is the `JNINativeInterface*` loaded from `JNIEnv*`. Treats the
    /// vtable as an array of opaque `ptr`s and indexes into it.
    pub fn loadJniFn(self: *LLVMEmitter, ifs: c.LLVMValueRef, offset: u32, name: [*:0]const u8) c.LLVMValueRef {
        const offset_val = c.LLVMConstInt(self.cached_i32, offset, 0);
        var idx = [_]c.LLVMValueRef{offset_val};
        const slot = c.LLVMBuildInBoundsGEP2(self.builder, self.cached_ptr, ifs, &idx, 1, "");
        return c.LLVMBuildLoad2(self.builder, self.cached_ptr, slot, name);
    }

    /// Lazily look up / declare the shared `@objc_msgSend` function.
    /// Cached on the emitter; all `objc_msg_send` instructions hand
    /// LLVMBuildCall2 their own per-call-site function type — the
    /// underlying function value is just an opaque `ptr` symbol.
    pub fn getObjcMsgSendValue(self: *LLVMEmitter) c.LLVMValueRef {
        if (self.objc_msg_send_value) |v| return v;
        const name_z = "objc_msgSend";
        if (c.LLVMGetNamedFunction(self.llvm_module, name_z)) |existing| {
            self.objc_msg_send_value = existing;
            return existing;
        }
        // Seed with a `(ptr, ptr) -> ptr` shape; opaque pointers mean
        // each call site can override.
        var params: [2]c.LLVMTypeRef = .{ self.cached_ptr, self.cached_ptr };
        const fn_ty = c.LLVMFunctionType(self.cached_ptr, &params, 2, 0);
        const fn_val = c.LLVMAddFunction(self.llvm_module, name_z, fn_ty);
        c.LLVMSetLinkage(fn_val, c.LLVMExternalLinkage);
        self.objc_msg_send_value = fn_val;
        return fn_val;
    }

    /// Compare IR typeSizeBytes against LLVMABISizeOfType for all user-defined types.
    fn verifySizes(self: *LLVMEmitter) void {
        // Skip for wasm32: 4-byte pointers vs IR's assumed 8-byte,
        // so struct sizes will differ. LLVM handles emission correctly.
        if (self.target_config.isWasm32()) return;
        const dl = c.LLVMGetModuleDataLayout(self.llvm_module);
        if (dl == null) return;
        const type_count = self.ir_mod.types.infos.items.len;
        for (TypeId.first_user..type_count) |idx| {
            const ty = TypeId.fromIndex(@intCast(idx));
            const info = self.ir_mod.types.get(ty);
            // Only verify aggregate types where sizing is non-trivial
            switch (info) {
                .@"struct", .@"union", .tagged_union, .tuple => {},
                else => continue,
            }
            const llvm_ty = self.toLLVMType(ty);
            const llvm_size = c.LLVMABISizeOfType(dl, llvm_ty);
            const ir_size = self.ir_mod.types.typeSizeBytes(ty);
            std.debug.assert(llvm_size == ir_size);
        }
    }

    /// The error-set channel of a (possibly failable) type: the set itself for
    /// a pure `-> !` result, or the last tuple slot for `-> (T..., !)`. null if
    /// the type carries no error channel. Mirror of lower.errorChannelOf.
    fn comptimeErrChannel(self: *LLVMEmitter, ty: TypeId) ?TypeId {
        if (ty.isBuiltin()) return null;
        switch (self.ir_mod.types.get(ty)) {
            .error_set => return ty,
            .tuple => |t| {
                if (t.fields.len == 0) return null;
                const last = t.fields[t.fields.len - 1];
                if (last.isBuiltin()) return null;
                return if (self.ir_mod.types.get(last) == .error_set) last else null;
            },
            else => return null,
        }
    }

    /// Inspect a failable `#run` result. On a non-zero error tag, print the
    /// comptime-error diagnostic + return trace, flag compilation failed, and
    /// return null. On success, return the value part (error channel stripped):
    /// `void_val` for a pure failable, the lone value for `(T, !)`, the
    /// value-tuple for multi-value. (E5.2)
    fn checkComptimeFailable(self: *LLVMEmitter, result: Value, fail_ty: TypeId, label: []const u8) ?Value {
        const channel = self.comptimeErrChannel(fail_ty) orelse return result;
        var tag: u32 = 0;
        var success: Value = .void_val;
        if (channel == fail_ty) {
            // pure failable — the result IS the error tag (u32)
            tag = switch (result) {
                .int => |v| @truncate(@as(u64, @bitCast(v))),
                else => 0,
            };
        } else {
            // value-carrying — the result is the `{values..., tag}` aggregate
            const fields = switch (result) {
                .aggregate => |f| f,
                else => return result,
            };
            if (fields.len == 0) return result;
            tag = switch (fields[fields.len - 1]) {
                .int => |v| @truncate(@as(u64, @bitCast(v))),
                else => 0,
            };
            success = if (fields.len == 2) fields[0] else .{ .aggregate = fields[0 .. fields.len - 1] };
        }
        if (tag == 0) {
            sx_trace_clear();
            return success;
        }
        self.reportComptimeEscape(label, tag);
        sx_trace_clear();
        self.comptime_failed = true;
        return null;
    }

    /// Print the locked comptime-escape diagnostic: the raised tag name, the
    /// resolved return trace from the thread-local buffer, and a help line.
    fn reportComptimeEscape(self: *LLVMEmitter, label: []const u8, tag: u32) void {
        const tname = self.ir_mod.types.tags.getName(tag);
        std.debug.print("error: comptime `#run` ({s}) raised an unhandled error: error.{s}\n", .{ label, tname });
        const n = sx_trace_len();
        if (n > 0) {
            std.debug.print("error return trace (most recent call last):\n", .{});
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const packed_frame = sx_trace_frame_at(i);
                const fid: u32 = @intCast(packed_frame >> 32);
                const offset: u32 = @truncate(packed_frame);
                if (fid >= self.ir_mod.functions.items.len) continue;
                const func = self.ir_mod.getFunction(FuncId.fromIndex(fid));
                const fname = self.ir_mod.types.getString(func.name);
                const file_full = func.source_file orelse "";
                const file = std.fs.path.basename(file_full);
                var line: usize = 1;
                var col: usize = 1;
                if (self.import_sources) |sm| {
                    if (sm.get(file_full)) |src| {
                        const loc = errors.SourceLoc.compute(src, offset);
                        line = loc.line;
                        col = loc.col;
                    }
                }
                std.debug.print("  {s} at {s}:{d}:{d}\n", .{ fname, file, line, col });
            }
        }
        std.debug.print("help: handle it at the `#run` site — `#run <expr> catch (e) {{ ... }}` or `#run <expr> or <default>`\n", .{});
    }

    /// Run comptime side-effect functions (e.g., `#run main();` at top level).
    /// These are functions marked `is_comptime = true` with void return that
    /// aren't associated with any global. They produce compile-time output.
    fn runComptimeSideEffects(self: *LLVMEmitter) void {
        for (self.ir_mod.functions.items, 0..) |func, i| {
            // `#run expr;` side-effects are the `__run_N` wrappers (global
            // initializers are named after their global and run by emitGlobals;
            // inline `__ct`/`__insert` wrappers run from their call sites). A
            // failable side-effect carries the error channel on `func.ret`.
            if (func.comptime_role != .run_wrapper) continue;
            const fname = self.ir_mod.types.getString(func.name);
            if (!std.mem.startsWith(u8, fname, "__run")) continue;

            const func_id = ir_inst.FuncId.fromIndex(@intCast(i));
            sx_trace_clear();
            // The comptime VM is the SOLE evaluator (P5.7) — no legacy fallback.
            // A VM-run `#run` side-effect writes its `print` output directly to
            // fd 1 via host-FFI (no buffered interp output to flush). A bail is a
            // build-gating error naming the reason.
            const result = comptime_vm.tryEval(self.alloc, self.ir_mod, func_id, &self.build_config, self.import_sources) orelse {
                std.debug.print("error: comptime `#run` ({s}) failed: {s}\n", .{ fname, comptime_vm.last_bail_reason orelse "<unknown>" });
                self.comptime_failed = true;
                continue;
            };
            // A bare failable `#run f();` whose error escapes → diagnostic + halt.
            if (self.comptimeErrChannel(func.ret) != null) {
                _ = self.checkComptimeFailable(result, func.ret, "top-level statement");
            }
        }
    }

    fn emitGlobals(self: *LLVMEmitter) void {
        // Dead-global elimination: a plain-data global no instruction
        // references is not emitted — without this, every module pulled in
        // via the std namespace tail lands its data (hash's K table, ...)
        // in every binary. Comptime-backed globals are kept: their #run
        // evaluation (and its failure diagnostics) is a semantic effect,
        // not just data.
        var used = std.AutoHashMap(u32, void).init(self.alloc);
        defer used.deinit();
        for (self.ir_mod.functions.items) |*func| {
            for (func.blocks.items) |*block| {
                for (block.insts.items) |*instruction| {
                    switch (instruction.op) {
                        .global_get, .global_addr => |gid| used.put(gid.index(), {}) catch {},
                        .global_set => |gs| used.put(gs.global.index(), {}) catch {},
                        else => {},
                    }
                }
            }
        }
        // A relocatable global initializer is a real use of its target even
        // when no function references that target directly (issue 0248).
        for (self.ir_mod.globals.items) |global| {
            if (global.init_val) |iv| markConstGlobalRefs(iv, &used);
        }
        for (self.ir_mod.globals.items, 0..) |global, i| {
            if (global.comptime_func == null and !used.contains(@intCast(i))) continue;
            const name = self.ir_mod.types.getString(global.name);
            const llvm_ty = self.toLLVMType(global.ty);
            const name_z = self.alloc.dupeZ(u8, name) catch continue;
            defer self.alloc.free(name_z);

            const llvm_global = c.LLVMAddGlobal(self.llvm_module, llvm_ty, name_z.ptr);

            // Extern globals (`<name> : <type> extern;`) resolve at link time
            // to a libSystem / framework symbol — no initializer, default linkage.
            if (global.is_extern) {
                c.LLVMSetLinkage(llvm_global, c.LLVMExternalLinkage);
                self.global_map.put(@intCast(i), llvm_global) catch {};
                continue;
            }

            c.LLVMSetLinkage(llvm_global, c.LLVMInternalLinkage);

            if (global.is_thread_local) {
                c.LLVMSetThreadLocal(llvm_global, 1);
            }

            // Evaluate comptime initializer if present
            if (global.comptime_func) |func_id| {
                // The comptime VM is the SOLE evaluator (P5.7) — no legacy
                // fallback. A bail is ALWAYS a build-gating error naming the
                // reason; its result Value is materialized by `valueToLLVMConst`.
                sx_trace_clear();
                const result = comptime_vm.tryEval(self.alloc, self.ir_mod, func_id, &self.build_config, self.import_sources) orelse {
                    // Surface the bail loudly instead of silently filling the
                    // const with zero. Leave the global undef; comptime_failed
                    // halts the build before it ships.
                    const gname = self.ir_mod.types.getString(global.name);
                    std.debug.print("error: comptime init of '{s}' failed: {s}\n", .{ gname, comptime_vm.last_bail_reason orelse "<unknown>" });
                    self.comptime_failed = true;
                    c.LLVMSetInitializer(llvm_global, c.LLVMGetUndef(llvm_ty));
                    self.global_map.put(@intCast(i), llvm_global) catch {};
                    continue;
                };
                // A bare failable `NAME :: #run f();`: the comptime function
                // returns the failable tuple; split it. Escaping error →
                // diagnostic + halt (leave the global undef); success → the
                // value part materializes into the global's success type (E5.2).
                const cf_ret = self.ir_mod.getFunction(func_id).ret;
                var init_value = result;
                if (self.comptimeErrChannel(cf_ret) != null) {
                    if (self.checkComptimeFailable(result, cf_ret, self.ir_mod.types.getString(global.name))) |succ| {
                        init_value = succ;
                    } else {
                        c.LLVMSetInitializer(llvm_global, c.LLVMGetUndef(llvm_ty));
                        self.global_map.put(@intCast(i), llvm_global) catch {};
                        continue;
                    }
                }
                const init_val = self.valueToLLVMConst(init_value, global.ty, self.ir_mod.types.getString(global.name));
                c.LLVMSetInitializer(llvm_global, init_val);
            } else if (global.init_val) |iv| {
                const init_val = switch (iv) {
                    .int => |v| c.LLVMConstInt(llvm_ty, @bitCast(v), 1),
                    .float => |v| c.LLVMConstReal(llvm_ty, v),
                    .boolean => |v| c.LLVMConstInt(llvm_ty, @intFromBool(v), 0),
                    .string => |sid| self.emitConstStringGlobal(self.ir_mod.types.getString(sid)),
                    .aggregate => |agg| self.emitConstAggregate(agg, llvm_ty, false),
                    .vtable => c.LLVMConstNull(llvm_ty), // placeholder — initialized in initVtableGlobals after function declarations
                    // A top-level null-pointer global (`p : *i64 = null;`) and a
                    // zero-initialized global both emit as the all-zero constant
                    // of the global's type.
                    .null_val, .zeroinit => c.LLVMConstNull(llvm_ty),
                    .undef => c.LLVMGetUndef(llvm_ty),
                    // func_map is empty in Pass 0 (functions are declared in
                    // Pass 1). Emit a placeholder and resolve in initVtableGlobals.
                    .func_ref => c.LLVMConstNull(llvm_ty),
                    .global_ref => c.LLVMConstNull(llvm_ty),
                };
                c.LLVMSetInitializer(llvm_global, init_val);
            } else {
                c.LLVMSetInitializer(llvm_global, c.LLVMConstNull(llvm_ty));
            }

            if (global.is_const) c.LLVMSetGlobalConstant(llvm_global, 1);

            self.global_map.put(@intCast(i), llvm_global) catch {};
        }
    }

    fn markConstGlobalRefs(cv: ir_inst.ConstantValue, used: *std.AutoHashMap(u32, void)) void {
        switch (cv) {
            .global_ref => |gid| used.put(gid.index(), {}) catch {},
            .aggregate => |fields| for (fields) |field| markConstGlobalRefs(field, used),
            else => {},
        }
    }

    /// Initialize vtable + aggregate-with-func_ref globals with function
    /// pointer constants. Must run after Pass 1 (function declarations) so
    /// func_map is populated — that's why these globals get a placeholder
    /// initializer in `emitGlobals` and we fix them up here.
    fn initVtableGlobals(self: *LLVMEmitter) void {
        for (self.ir_mod.globals.items, 0..) |global, i| {
            const iv = global.init_val orelse continue;
            const llvm_global = self.global_map.get(@intCast(i)) orelse continue;
            const llvm_ty = self.toLLVMType(global.ty);

            switch (iv) {
                .vtable => |func_ids| {
                    var field_vals = std.ArrayList(c.LLVMValueRef).empty;
                    defer field_vals.deinit(self.alloc);
                    for (func_ids) |fid| {
                        const llvm_func = self.func_map.get(fid.index()) orelse {
                            std.debug.print(
                                "error: vtable global '{s}' references function '{s}' which has no declaration\n",
                                .{ self.ir_mod.types.getString(global.name), self.ir_mod.types.getString(self.ir_mod.getFunction(fid).name) },
                            );
                            // Keep the struct shape so module construction can
                            // finish; comptime_failed halts before it ships.
                            field_vals.append(self.alloc, c.LLVMConstNull(self.cached_ptr)) catch unreachable;
                            self.comptime_failed = true;
                            continue;
                        };
                        field_vals.append(self.alloc, llvm_func) catch unreachable;
                    }
                    const init_val = c.LLVMConstNamedStruct(llvm_ty, field_vals.items.ptr, @intCast(field_vals.items.len));
                    c.LLVMSetInitializer(llvm_global, init_val);
                    c.LLVMSetGlobalConstant(llvm_global, 1);
                },
                .aggregate => |agg| {
                    // Re-emit. The first pass in `emitGlobals` already ran,
                    // but func_ref leaves resolved to null then (func_map
                    // wasn't populated yet). Now they must resolve — a still-
                    // unresolved func_ref here is a loud diagnostic, never a
                    // silent null.
                    const init_val = self.emitConstAggregate(agg, llvm_ty, true);
                    c.LLVMSetInitializer(llvm_global, init_val);
                },
                .func_ref => |fid| {
                    const llvm_func = self.func_map.get(fid.index()) orelse {
                        std.debug.print(
                            "error: global '{s}' references function '{s}' which has no declaration\n",
                            .{ self.ir_mod.types.getString(global.name), self.ir_mod.types.getString(self.ir_mod.getFunction(fid).name) },
                        );
                        self.comptime_failed = true;
                        continue;
                    };
                    c.LLVMSetInitializer(llvm_global, llvm_func);
                },
                .global_ref => |gid| {
                    const target = self.global_map.get(gid.index()) orelse {
                        std.debug.print("error: global '{s}' references an unavailable global initializer target\n", .{self.ir_mod.types.getString(global.name)});
                        self.comptime_failed = true;
                        continue;
                    };
                    c.LLVMSetInitializer(llvm_global, target);
                },
                else => continue,
            }
        }
    }

    /// Read `len` bytes from `addr` in the current process. Used to lift
    /// comptime-evaluated heap data into a static binary constant — the
    /// interp ran in this process, so any libc-malloc'd buffer it
    /// produced is still mapped and readable. Returns `null` on a
    /// null/zero address (callers handle empty-slice as a special case
    /// before calling this).
    fn readHostBytes(addr: usize, len: usize) ?[]const u8 {
        if (addr == 0) return null;
        const ptr: [*]const u8 = @ptrFromInt(addr);
        return ptr[0..len];
    }

    /// Record that a global initializer could not be serialized to a valid
    /// static constant: set the halt flag (the driver aborts with a non-zero
    /// exit after `emit()`) and return an `undef` placeholder so in-process
    /// LLVM module construction can finish without tripping over an invalid
    /// value before the halt is observed. The placeholder is never shipped —
    /// `comptime_failed` guarantees we stop before object emission / JIT.
    fn failGlobalInit(self: *LLVMEmitter, llvm_ty: c.LLVMTypeRef) c.LLVMValueRef {
        self.comptime_failed = true;
        return c.LLVMGetUndef(llvm_ty);
    }

    /// Serialize an interp `Value` to an LLVM constant for use as a static
    /// global initializer. `ty` is the IR-level type of the destination;
    /// the LLVM type is derived from it. `interp` gives access to the
    /// interpreter's heap so heap_ptr values can be walked. `global_name`
    /// is included in any diagnostic the path produces so the user can
    /// locate the offending `#run` site.
    ///
    /// On bail, prints the diagnostic and routes through `failGlobalInit`
    /// (sets `comptime_failed`, returns `undef`): the in-process module
    /// finishes constructing, but the driver halts with a non-zero exit
    /// before object emission / JIT, so the placeholder never ships.
    fn valueToLLVMConst(
        self: *LLVMEmitter,
        val: Value,
        ty: TypeId,
        global_name: []const u8,
    ) c.LLVMValueRef {
        const llvm_ty = self.toLLVMType(ty);
        return switch (val) {
            .int => |v| blk: {
                // Host-pointer-as-int trap: the interp marshals raw pointers
                // (libc-malloc'd buffers, etc.) into a .int that holds the
                // host address. When that address is meant for a `ptr` slot
                // in the destination type, emitting `LLVMConstInt` against
                // the ptr type silently produces a malformed `i0 0`. The
                // string/slice paths above handle this case by reading the
                // pointed-to bytes; anything else with an int landing in a
                // ptr slot is a Phase-1.4a heap-walk case we don't yet
                // know how to serialize.
                const kind = c.LLVMGetTypeKind(llvm_ty);
                if (kind == c.LLVMPointerTypeKind) {
                    std.debug.print(
                        "error: comptime init of '{s}' produced a raw integer for a pointer field — needs IR-typed heap-walk serialization (Phase 1.4a heap-walk follow-up)\n",
                        .{global_name},
                    );
                    break :blk self.failGlobalInit(llvm_ty);
                }
                break :blk c.LLVMConstInt(llvm_ty, @bitCast(v), 1);
            },
            .float => |v| c.LLVMConstReal(llvm_ty, v),
            .boolean => |v| c.LLVMConstInt(llvm_ty, @intFromBool(v), 0),
            .null_val => c.LLVMConstNull(llvm_ty),
            .void_val, .undef => c.LLVMGetUndef(llvm_ty),
            // Comptime globals are serialized here in Pass 0, before functions
            // are declared (Pass 1) and with no later re-emit. A func_ref can
            // therefore never resolve to a real function pointer at this point;
            // bail loudly rather than ship a silently-null function pointer.
            .func_ref => |fid| blk: {
                std.debug.print(
                    "error: comptime init of '{s}' produced a reference to function '{s}', which cannot be serialized as a static constant (function declarations are not available at global-init time)\n",
                    .{ global_name, self.ir_mod.types.getString(self.ir_mod.getFunction(fid).name) },
                );
                break :blk self.failGlobalInit(llvm_ty);
            },
            .string => |s| self.emitConstStringGlobal(s),
            .aggregate => |fields| self.serializeAggregateValue(fields, ty, global_name),
            // The remaining Value variants cannot become static binary
            // constants outside of a fat-pointer aggregate. Bail loudly.
            // (`heap_ptr` / `byte_ptr` / `int → ptr` are handled inside
            // `serializeAggregateValue` when they appear in a string or
            // slice fat-pointer's data field.)
            .heap_ptr, .byte_ptr, .slot_ptr, .closure, .type_tag => blk: {
                std.debug.print(
                    "error: comptime init of '{s}' produced a {s} value, which cannot be serialized as a static constant\n",
                    .{ global_name, @tagName(val) },
                );
                break :blk self.failGlobalInit(llvm_ty);
            },
        };
    }

    /// Helper for `valueToLLVMConst` — serialize an aggregate value
    /// against an IR TypeId. Splits on the type:
    ///
    ///   - `string` / `slice` — fat pointer `{ data, len }`. The data
    ///     field can be a heap_ptr (interp-managed memory), byte_ptr
    ///     (raw host address), int (same), or string literal. The len
    ///     field is consulted to know how many bytes to capture from
    ///     the data. Bytes are emitted as a private global byte array
    ///     and the aggregate constant points at it.
    ///   - `struct` — walk the IR field types in lockstep with the
    ///     value fields; recurse per field with its declared TypeId.
    ///   - `array` — walk elements with the array's element TypeId.
    fn serializeAggregateValue(
        self: *LLVMEmitter,
        fields: []const Value,
        ty: TypeId,
        global_name: []const u8,
    ) c.LLVMValueRef {
        const llvm_ty = self.toLLVMType(ty);

        // Fat-pointer types: extract len, then read bytes from the data
        // field's address (whatever flavour the interp produced for it).
        const is_string = (ty == .string);
        const is_slice = !ty.isBuiltin() and self.ir_mod.types.get(ty) == .slice;
        if ((is_string or is_slice) and fields.len == 2) {
            const data = fields[0];
            const len_i = fields[1].asInt() orelse {
                std.debug.print(
                    "error: comptime init of '{s}' produced a fat-pointer aggregate whose len field is not an integer\n",
                    .{global_name},
                );
                return self.failGlobalInit(llvm_ty);
            };
            const len: usize = @intCast(len_i);

            const bytes_opt: ?[]const u8 = switch (data) {
                .byte_ptr => |addr| readHostBytes(addr, len),
                .int => |v| blk: {
                    if (v == 0 and len == 0) break :blk &.{}; // empty slice
                    if (v == 0) break :blk null;
                    break :blk readHostBytes(@as(usize, @bitCast(v)), len);
                },
                .string => |s| if (len <= s.len) s[0..len] else null,
                else => null,
            };

            const bytes = bytes_opt orelse {
                std.debug.print(
                    "error: comptime init of '{s}' produced a fat-pointer aggregate whose data field ({s}) cannot be resolved to {} bytes — needs Phase 1.4a heap-walk for this shape\n",
                    .{ global_name, @tagName(data), len },
                );
                return self.failGlobalInit(llvm_ty);
            };

            return self.emitConstStringGlobal(bytes);
        }

        // Generic struct: walk IR fields by their declared TypeIds.
        if (!ty.isBuiltin()) {
            const info = self.ir_mod.types.get(ty);
            if (info == .@"struct") {
                const ir_fields = info.@"struct".fields;
                if (ir_fields.len != fields.len) {
                    std.debug.print(
                        "error: comptime init of '{s}' produced aggregate with {} fields but struct '{s}' expects {}\n",
                        .{ global_name, fields.len, self.ir_mod.types.getString(info.@"struct".name), ir_fields.len },
                    );
                    return self.failGlobalInit(llvm_ty);
                }
                var field_vals = std.ArrayList(c.LLVMValueRef).empty;
                defer field_vals.deinit(self.alloc);
                for (ir_fields, fields) |ir_field, fv| {
                    field_vals.append(self.alloc, self.valueToLLVMConst(fv, ir_field.ty, global_name)) catch unreachable;
                }
                return c.LLVMConstNamedStruct(llvm_ty, field_vals.items.ptr, @intCast(field_vals.items.len));
            }
            if (info == .array) {
                const elem_ty = info.array.element;
                const llvm_elem_ty = self.toLLVMType(elem_ty);
                var elem_vals = std.ArrayList(c.LLVMValueRef).empty;
                defer elem_vals.deinit(self.alloc);
                for (fields) |fv| {
                    elem_vals.append(self.alloc, self.valueToLLVMConst(fv, elem_ty, global_name)) catch unreachable;
                }
                return c.LLVMConstArray2(llvm_elem_ty, elem_vals.items.ptr, @intCast(elem_vals.items.len));
            }
            // Present optional `?T` → `{ <payload>, i1 1 }`, matching the
            // anonymous-struct layout `toLLVMType` builds for a non-pointer
            // optional (the absent case is a `.null_val`, serialized at the
            // `valueToLLVMConst` top level as `LLVMConstNull` of `{T,i1}`).
            // The VM's reg→value optional arm only produces this 2-field
            // `[payload, bool]` aggregate for present, non-pointer optionals.
            if (info == .optional) {
                if (fields.len != 2) {
                    std.debug.print(
                        "error: comptime init of '{s}' produced an optional aggregate with {} fields (expected 2: payload, has_value)\n",
                        .{ global_name, fields.len },
                    );
                    return self.failGlobalInit(llvm_ty);
                }
                const payload = self.valueToLLVMConst(fields[0], info.optional.child, global_name);
                const has = self.valueToLLVMConst(fields[1], .bool, global_name);
                var ofields = [_]c.LLVMValueRef{ payload, has };
                return c.LLVMConstStructInContext(self.context, &ofields, 2, 0);
            }
        }

        std.debug.print(
            "error: comptime init of '{s}' produced an aggregate but the destination type ({s}) is neither struct, array, string, nor slice\n",
            .{ global_name, self.ir_mod.types.typeName(ty) },
        );
        return self.failGlobalInit(llvm_ty);
    }

    // ── Function declaration ────────────────────────────────────────

    fn declareFunction(self: *LLVMEmitter, func: *const Function, func_idx: u32) void {
        const name = self.ir_mod.types.getString(func.name);

        // Not reachable from the binary: declaring it would leave a `declare`
        // with no `define`, which fails LLVM verification. Nothing the binary can
        // reach refers to it, so there is nothing to declare it for.
        if (self.reach) |r| {
            if (!r.emits(ir_inst.FuncId.fromIndex(func_idx))) return;
        }

        // An intrinsic has no symbol: it folded to a constant, lowered to ops, or
        // is serviced by the comptime VM. Declaring one emits a `declare` nothing
        // can ever call — and since std/core.sx is in every module's graph, that
        // dead declaration would land in every module. Emit nothing, and register
        // nothing in func_map: a call that reached here would be a lowering bug,
        // and an absent entry surfaces it instead of resolving to a dead symbol.
        if (func.is_intrinsic) return;

        // Skip builtins that are declared via getOrDeclare* with correct C-compatible types.
        // The IR lowering creates extern stubs with IR types (e.g. memset → void return),
        // but the C ABI may differ (memset returns ptr). Let getOrDeclare* handle these.
        if (func.is_extern and isBuiltinLibcName(name)) {
            // Still register in func_map so call resolution works
            const builtin_fn = self.getOrDeclareBuiltinByName(name);
            if (builtin_fn) |bf| {
                self.func_map.put(func_idx, bf) catch unreachable;
                return;
            }
        }

        const is_main = std.mem.eql(u8, name, "main");

        // main always returns i32 at the LLVM level (JIT expects it)
        const raw_ret_ty = self.toLLVMType(func.ret);
        const needs_c_abi = func.is_extern or func.call_conv == .c;
        // An extern `-> string` / `-> ?string` receives ONE `char *` from C;
        // the fat sx value is synthesized at the call site (emitCall's
        // cstrReturnToSx). Never sret — the C callee knows nothing about an
        // out-pointer.
        const cstr_ret = self.cstrRetKind(func);
        // sret return: C-ABI functions returning a >16 B non-HFA struct
        // use the indirect-return convention (caller allocates space,
        // passes its pointer as a hidden first arg with `sret(<T>)`,
        // function writes through and returns void). Distinct from
        // small-struct register coercion (i64 / [2 x i64]) and HFA.
        const uses_sret = needs_c_abi and !is_main and cstr_ret == .none and self.needsByval(func.ret, raw_ret_ty);
        const ret_ty = if (is_main) self.cached_i32 else if (cstr_ret != .none) self.cached_ptr else if (uses_sret) self.cached_void else if (needs_c_abi) self.abiCoerceParamTypeEx(func.ret, raw_ret_ty, func.is_extern) else raw_ret_ty;

        // Build parameter types.
        // C ABI (extern / abi(.c)): full size-bucket coercion (string→ptr, ≤8→i64, …).
        // Default sx ABI: still pack ≤8-byte non-HFA structs into i64 so AArch64
        // does not expand `{i8×4}` (e.g. Color) into four i8 args that mis-spill
        // when a second such param overflows the integer registers (issue 0286).
        // When uses_sret, prepend the sret pointer at index 0.
        const sret_offset: usize = if (uses_sret) 1 else 0;
        const param_count: c_uint = @intCast(func.params.len + sret_offset);
        const param_types = self.alloc.alloc(c.LLVMTypeRef, func.params.len + sret_offset) catch unreachable;
        defer self.alloc.free(param_types);
        if (uses_sret) param_types[0] = self.cached_ptr;
        for (func.params, 0..) |param, j| {
            const llvm_ty = self.toLLVMType(param.ty);
            param_types[j + sret_offset] = if (needs_c_abi)
                self.abiCoerceParamTypeEx(param.ty, llvm_ty, func.is_extern)
            else
                self.abiCoerceDefaultParamType(param.ty, llvm_ty);
        }

        const is_var_arg: c_int = if (func.is_variadic) 1 else 0;
        const fn_type = c.LLVMFunctionType(ret_ty, param_types.ptr, param_count, is_var_arg);
        const name_z = self.alloc.dupeZ(u8, name) catch unreachable;
        defer self.alloc.free(name_z);

        const llvm_func = c.LLVMAddFunction(self.llvm_module, name_z.ptr, fn_type);

        // sret(<RetType>) attribute on the prepended pointer param.
        // LLVMAttributeIndex 1 = first parameter (0 = return value).
        if (uses_sret) {
            const sret_kind = c.LLVMGetEnumAttributeKindForName("sret", 4);
            const sret_attr = c.LLVMCreateTypeAttribute(self.context, sret_kind, raw_ret_ty);
            const param1_idx: c.LLVMAttributeIndex = @bitCast(@as(i32, 1));
            c.LLVMAddAttributeAtIndex(llvm_func, param1_idx, sret_attr);
        }

        // Set linkage. Every function that reaches here is runtime-reachable (the
        // gate above returned for the rest), so each has a body to define.
        switch (func.linkage) {
            .external => c.LLVMSetLinkage(llvm_func, c.LLVMExternalLinkage),
            .internal => c.LLVMSetLinkage(llvm_func, c.LLVMInternalLinkage),
            .private => c.LLVMSetLinkage(llvm_func, c.LLVMPrivateLinkage),
        }

        // Set calling convention
        if (func.call_conv == .c) {
            c.LLVMSetFunctionCallConv(llvm_func, c.LLVMCCallConv);
        }

        // Add frame-pointer and nounwind attributes for correct ARM64 codegen
        {
            const func_idx_attr: c.LLVMAttributeIndex = @bitCast(@as(i32, -1));
            if (func.is_naked) {
                // `abi(.naked)`: emit via LLVM's `naked` attribute — the backend
                // emits the body verbatim (our inline asm + its own `ret`) with
                // NO prologue/epilogue/frame. Do NOT request `frame-pointer`
                // (incompatible with a frameless function). `noinline` keeps the
                // asm body out of a framed caller; `nounwind` — naked asm never
                // unwinds. See Function.is_naked / current/PLAN-FIBERS.md.
                const naked_id = c.LLVMGetEnumAttributeKindForName("naked", 5);
                c.LLVMAddAttributeAtIndex(llvm_func, func_idx_attr, c.LLVMCreateEnumAttribute(self.context, naked_id, 0));
                const noinline_id = c.LLVMGetEnumAttributeKindForName("noinline", 8);
                c.LLVMAddAttributeAtIndex(llvm_func, func_idx_attr, c.LLVMCreateEnumAttribute(self.context, noinline_id, 0));
                const nounwind_id = c.LLVMGetEnumAttributeKindForName("nounwind", 8);
                c.LLVMAddAttributeAtIndex(llvm_func, func_idx_attr, c.LLVMCreateEnumAttribute(self.context, nounwind_id, 0));
            } else {
                const fp_kind = "frame-pointer";
                const fp_val = "all";
                const fp_attr = c.LLVMCreateStringAttribute(
                    self.context,
                    fp_kind.ptr,
                    @intCast(fp_kind.len),
                    fp_val.ptr,
                    @intCast(fp_val.len),
                );
                c.LLVMAddAttributeAtIndex(llvm_func, func_idx_attr, fp_attr);

                // Add nounwind
                const nounwind_id = c.LLVMGetEnumAttributeKindForName("nounwind", 8);
                const nounwind_attr = c.LLVMCreateEnumAttribute(self.context, nounwind_id, 0);
                c.LLVMAddAttributeAtIndex(llvm_func, func_idx_attr, nounwind_attr);
            }
        }

        // Apple ARM64 ABI for >16B non-HFA composites: pass by reference
        // via a pointer in the next int register (NOT via LLVM's `byval`
        // attribute, which lowers the struct on the stack — incompatible
        // with what `clang` emits and what extern C callees expect).
        // abiCoerceParamType returned `ptr` for these slots, so the formal
        // param IS a plain pointer; the prologue loads the struct back.

        self.func_map.put(func_idx, llvm_func) catch unreachable;
    }

    // ── Function body emission ──────────────────────────────────────

    fn emitFunction(self: *LLVMEmitter, func: *const Function, func_idx: u32) void {
        const llvm_func = self.func_map.get(func_idx) orelse unreachable;
        const name = self.ir_mod.types.getString(func.name);
        self.current_func_is_main = std.mem.eql(u8, name, "main");
        self.current_func_idx = func_idx;
        // Source file for span resolution — needed by `.trace_frame` even when
        // DWARF is off (traces gate on opt level only, not on a source map).
        self.current_func_file = func.source_file orelse self.main_file;

        // DWARF: describe this function and make it the scope for the
        // per-instruction locations set in emitInst (no-op if off).
        self.debugInfo().beginFunctionDebug(func, llvm_func, name);

        // Clear ref_map and pre-map parameter refs
        self.ref_map.clearRetainingCapacity();
        self.ref_counter = 0;

        // Refs 0..N-1 are function parameters (matching the IR convention).
        // An sret function's LLVM signature carries the hidden out-pointer at
        // slot 0 (declareFunction's sret_offset), so IR param i is LLVM param
        // i+1 — mapping without the shift would hand the body the sret
        // pointer as its first argument. Must mirror declareFunction's
        // classification exactly.
        const needs_c_abi_sig = func.is_extern or func.call_conv == .c;
        const fn_uses_sret = needs_c_abi_sig and !self.current_func_is_main and
            self.cstrRetKind(func) == .none and
            self.needsByval(func.ret, self.toLLVMType(func.ret));
        const param_sret_offset: usize = if (fn_uses_sret) 1 else 0;
        for (0..func.params.len) |pi| {
            const param_val = c.LLVMGetParam(llvm_func, @intCast(pi + param_sret_offset));
            self.mapRef(param_val);
        }

        // Create all basic blocks first (so branches can reference them)
        for (func.blocks.items, 0..) |block, bi| {
            const block_name = self.ir_mod.types.getString(block.name);
            const block_name_z = self.alloc.dupeZ(u8, block_name) catch unreachable;
            defer self.alloc.free(block_name_z);
            const bb = c.LLVMAppendBasicBlockInContext(self.context, llvm_func, block_name_z.ptr);
            const block_key = makeBlockKey(func_idx, @intCast(bi));
            self.block_map.put(block_key, bb) catch unreachable;
        }

        // byval params arrive as `ptr` in LLVM but the IR body expects struct values.
        // At entry, load each byval param into a struct SSA value and re-map its ref.
        if (needs_c_abi_sig and func.blocks.items.len > 0) {
            const entry_key = makeBlockKey(func_idx, 0);
            const entry_bb = self.block_map.get(entry_key) orelse unreachable;
            c.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
            for (func.params, 0..) |param, pi| {
                const raw_llvm_ty = self.toLLVMType(param.ty);
                if (self.needsByval(param.ty, raw_llvm_ty)) {
                    const ptr_val = c.LLVMGetParam(llvm_func, @intCast(pi + param_sret_offset));
                    const loaded = c.LLVMBuildLoad2(self.builder, raw_llvm_ty, ptr_val, "byval.load");
                    self.ref_map.put(@intCast(pi), loaded) catch unreachable;
                }
            }
        }

        // Clear pending phis for this function
        self.pending_phis.clearRetainingCapacity();
        self.term_block_map.clearRetainingCapacity();

        // Emit instructions for each block — use first_ref to sync ref numbering
        for (func.blocks.items, 0..) |block, bi| {
            const block_key = makeBlockKey(func_idx, @intCast(bi));
            const bb = self.block_map.get(block_key) orelse unreachable;
            c.LLVMPositionBuilderAtEnd(self.builder, bb);

            // Reset ref_counter to this block's actual starting ref
            // (blocks may not be in emission order due to nested control flow)
            self.ref_counter = block.first_ref;

            for (block.insts.items, 0..) |instruction, inst_i| {
                _ = inst_i;
                self.emitInst(&instruction, func_idx);
                if (self.emission_failed) break;
            }

            if (self.emission_failed) break;

            // The terminator may have landed in a later LLVM block than `bb`
            // if an instruction in this IR block expanded into its own sub-CFG.
            // Record where the builder actually is so PHI predecessors point at
            // the block that holds the branch, not the block we started in.
            self.term_block_map.put(block_key, c.LLVMGetInsertBlock(self.builder)) catch unreachable;
        }

        // Fixup PHI nodes: scan all blocks for branches that pass args
        if (!self.emission_failed) self.fixupPhiNodes(func, func_idx);

        // DWARF: leave no stale location for the next function.
        self.debugInfo().endFunctionDebug();
    }

    /// Build an alloca in the current function's ENTRY block, not at the
    /// builder's position. An alloca executed inside a loop body allocates
    /// fresh stack on every iteration (LLVM only reclaims at `ret`), so any
    /// alloca reachable per-instruction must be hoisted here; only entry-block
    /// allocas are static frame slots (and mem2reg-promotable). Insertion goes
    /// after existing entry allocas; the builder position is restored.
    pub fn buildEntryAlloca(self: *LLVMEmitter, ty: c.LLVMTypeRef, name: [*:0]const u8) c.LLVMValueRef {
        const cur_bb = c.LLVMGetInsertBlock(self.builder);
        const func = c.LLVMGetBasicBlockParent(cur_bb);
        const entry_bb = c.LLVMGetEntryBasicBlock(func);
        if (entry_bb == cur_bb) {
            return c.LLVMBuildAlloca(self.builder, ty, name);
        }
        var insert_before = c.LLVMGetFirstInstruction(entry_bb);
        while (insert_before != null) : (insert_before = c.LLVMGetNextInstruction(insert_before)) {
            if (c.LLVMGetInstructionOpcode(insert_before) != c.LLVMAlloca) break;
        }
        if (insert_before != null) {
            c.LLVMPositionBuilderBefore(self.builder, insert_before);
        } else {
            c.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
        }
        const result = c.LLVMBuildAlloca(self.builder, ty, name);
        c.LLVMPositionBuilderAtEnd(self.builder, cur_bb);
        return result;
    }

    /// After emitting all blocks, fill in PHI incoming values from branch args.
    fn fixupPhiNodes(self: *LLVMEmitter, func: *const Function, func_idx: u32) void {
        if (self.pending_phis.items.len == 0) return;

        for (func.blocks.items, 0..) |block, bi| {
            const src_key = makeBlockKey(func_idx, @intCast(bi));
            // Predecessor is the block the terminator was emitted into, which
            // differs from `block_map[bi]` when an instruction expanded the
            // block into a sub-CFG (string `==`, value `match`, …).
            const src_bb = self.term_block_map.get(src_key) orelse continue;

            for (block.insts.items) |instruction| {
                switch (instruction.op) {
                    .br => |branch| {
                        self.addPhiIncoming(branch.target, branch.args, src_bb);
                    },
                    .cond_br => |cb| {
                        self.addPhiIncoming(cb.then_target, cb.then_args, src_bb);
                        self.addPhiIncoming(cb.else_target, cb.else_args, src_bb);
                    },
                    .switch_br => |sw| {
                        for (sw.cases) |case| {
                            self.addPhiIncoming(case.target, case.args, src_bb);
                        }
                        self.addPhiIncoming(sw.default, sw.default_args, src_bb);
                    },
                    else => {},
                }
            }
        }
    }

    fn addPhiIncoming(self: *LLVMEmitter, target: BlockId, args: []const Ref, src_bb: c.LLVMBasicBlockRef) void {
        for (args, 0..) |arg, pi| {
            const val = self.resolveRef(arg) orelse continue;
            // Find the matching pending phi
            for (self.pending_phis.items) |pp| {
                if (pp.block_id.index() == target.index() and pp.param_index == pi) {
                    var incoming_vals = [1]c.LLVMValueRef{val};
                    var incoming_bbs = [1]c.LLVMBasicBlockRef{src_bb};
                    c.LLVMAddIncoming(pp.phi, &incoming_vals, &incoming_bbs, 1);
                    break;
                }
            }
        }
    }

    // ── Instruction emission ────────────────────────────────────────

    fn emitInst(self: *LLVMEmitter, instruction: *const Inst, func_idx: u32) void {
        // DWARF: stamp every LLVM instruction this op emits with the sx
        // source location (no-op when debug info is off).
        self.debugInfo().setInstDebugLocation(instruction.span);
        switch (instruction.op) {
            // ── Constants ───────────────────────────────────────────
            .const_int => |val| self.ops().emitConstInt(instruction, val),
            .const_float => |val| self.ops().emitConstFloat(instruction, val),
            .const_bool => |val| self.ops().emitConstBool(val),
            .is_comptime => self.ops().emitIsComptime(),
            .interp_print_frames => self.ops().emitInterpPrintFrames(),
            .trace_frame => self.ops().emitTraceFrame(instruction),
            .trace_resolve => |u| self.ops().emitTraceResolve(u),
            .const_string => |str_id| self.ops().emitConstString(str_id),
            .const_null => self.ops().emitConstNull(instruction),
            .const_undef => self.ops().emitConstUndef(instruction),
            .const_type => |tid| self.ops().emitConstType(tid),

            // ── Arithmetic ─────────────────────────────────────────
            .add => |bin| self.ops().emitAdd(instruction, bin),
            .sub => |bin| self.ops().emitSub(instruction, bin),
            .mul => |bin| self.ops().emitMul(instruction, bin),
            .div => |bin| self.ops().emitDiv(instruction, bin),
            .mod => |bin| self.ops().emitMod(instruction, bin),
            .neg => |un| self.ops().emitNeg(instruction, un),

            // ── Bitwise ────────────────────────────────────────────
            .bit_and => |bin| self.ops().emitBitAnd(instruction, bin),
            .bit_or => |bin| self.ops().emitBitOr(instruction, bin),
            .bit_xor => |bin| self.ops().emitBitXor(instruction, bin),
            .bit_not => |un| self.ops().emitBitNot(un),
            .shl => |bin| self.ops().emitShl(instruction, bin),
            .shr => |bin| self.ops().emitShr(instruction, bin),

            // ── Comparisons ───────────────────────────────────────
            .cmp_eq => |bin| self.ops().emitCmpEq(instruction, bin),
            .cmp_ne => |bin| self.ops().emitCmpNe(instruction, bin),
            .cmp_lt => |bin| self.ops().emitCmpLt(instruction, bin),
            .cmp_le => |bin| self.ops().emitCmpLe(instruction, bin),
            .cmp_gt => |bin| self.ops().emitCmpGt(instruction, bin),
            .cmp_ge => |bin| self.ops().emitCmpGe(instruction, bin),
            .str_eq => |bin| self.ops().emitStrEq(bin),
            .str_ne => |bin| self.ops().emitStrNe(bin),

            // ── Logical ───────────────────────────────────────────
            .bool_and => |bin| self.ops().emitBoolAnd(bin),
            .bool_or => |bin| self.ops().emitBoolOr(bin),
            .bool_not => |un| self.ops().emitBoolNot(un),

            // ── Memory ────────────────────────────────────────────
            .alloca => |elem_ty| self.ops().emitAlloca(elem_ty),
            .load => |un| self.ops().emitLoad(instruction, un),
            .store => |st| self.ops().emitStore(st),
            .atomic_load => |a| self.ops().emitAtomicLoad(instruction, a),
            .atomic_store => |a| self.ops().emitAtomicStore(a),
            .atomic_rmw => |a| self.ops().emitAtomicRmw(instruction, a),
            .atomic_cmpxchg => |a| self.ops().emitAtomicCmpxchg(instruction, a),
            .atomic_fence => |a| self.ops().emitAtomicFence(a),
            // ── Globals ───────────────────────────────────────────
            .global_get => |gid| self.ops().emitGlobalGet(instruction, gid),
            .global_addr => |gid| self.ops().emitGlobalAddr(gid),
            .func_ref => |fid| self.ops().emitFuncRef(fid),
            .global_set => |gs| self.ops().emitGlobalSet(gs),

            // ── Conversions ───────────────────────────────────────
            .widen => |conv| self.ops().emitWiden(conv),
            .narrow => |conv| self.ops().emitNarrow(conv),
            .bitcast => |conv| self.ops().emitBitcast(conv),
            .int_to_float => |conv| self.ops().emitIntToFloat(conv),
            .float_to_int => |conv| self.ops().emitFloatToInt(conv),

            // ── Pointer ops ───────────────────────────────────────
            .addr_of => |un| self.ops().emitAddrOf(un),
            .deref => |un| self.ops().emitDeref(instruction, un),

            // ── Calls ─────────────────────────────────────────────
            .objc_msg_send => |msg| self.ops().emitObjcMsgSend(instruction, msg),
            .jni_msg_send => |msg| self.ops().emitJniMsgSend(instruction, msg),
            .inline_asm => |a| self.ops().emitInlineAsm(instruction, a),
            .call => |call_op| self.ops().emitCall(instruction, call_op),
            .call_indirect => |call_op| self.ops().emitCallIndirect(instruction, call_op),

            // ── Terminators ────────────────────────────────────────
            .ret => |un| self.ops().emitRet(un),
            .ret_void => self.ops().emitRetVoid(),
            .@"unreachable" => self.ops().emitUnreachable(),
            .br => |branch| self.ops().emitBr(branch, func_idx),
            .cond_br => |cbr| self.ops().emitCondBr(cbr, func_idx),

            // ── Struct ops ────────────────────────────────────────────
            .struct_init => |agg| self.ops().emitStructInit(instruction, agg),
            .struct_get => |fa| self.ops().emitStructGet(instruction, fa),
            .struct_gep => |fa| self.ops().emitStructGep(instruction, fa),

            // ── Enum ops ─────────────────────────────────────────────
            .enum_init => |ei| self.ops().emitEnumInit(instruction, ei),
            .enum_tag => |un| self.ops().emitEnumTag(instruction, un),
            .enum_payload => |fa| self.ops().emitEnumPayload(instruction, fa),

            // ── Union ops ────────────────────────────────────────────
            .union_get => |fa| self.ops().emitUnionGet(instruction, fa),
            .union_gep => |fa| self.ops().emitUnionGep(instruction, fa),

            // ── Array/Slice ops ───────────────────────────────────────
            .index_get => |bin| self.ops().emitIndexGet(instruction, bin),
            .index_gep => |bin| self.ops().emitIndexGep(instruction, bin),
            .length => |un| self.ops().emitLength(un),
            .data_ptr => |un| self.ops().emitDataPtr(un),
            .subslice => |ss| self.ops().emitSubslice(instruction, ss),
            .array_to_slice => |un| self.ops().emitArrayToSlice(instruction, un),

            // ── Call extensions ───────────────────────────────────────
            .call_builtin => |bi| self.ops().emitCallBuiltin(instruction, bi),
            .call_closure => |call_op| self.ops().emitCallClosure(instruction, call_op),

            // ── Tuple ops ────────────────────────────────────────────
            .tuple_init => |agg| self.ops().emitTupleInit(instruction, agg),
            .tuple_get => |fa| self.ops().emitTupleGet(fa),

            // ── Optional ops ─────────────────────────────────────────
            .optional_wrap => |un| self.ops().emitOptionalWrap(instruction, un),
            .optional_unwrap => |un| self.ops().emitOptionalUnwrap(un),
            .optional_has_value => |un| self.ops().emitOptionalHasValue(un),
            .optional_coalesce => |bin| self.ops().emitOptionalCoalesce(bin),

            // ── Box/Unbox Any ────────────────────────────────────────
            .box_any => |ba| self.ops().emitBoxAny(ba),
            .unbox_any => |un| self.ops().emitUnboxAny(instruction, un),
            .any_data => |un| self.ops().emitAnyData(instruction, un),
            .make_any => |ma| self.ops().emitMakeAny(ma),

            // ── Reflection ops ──────────────────────────────────────
            .field_name_get => |fr| self.ops().emitFieldNameGet(fr),
            .field_value_get => |fr| self.ops().emitFieldValueGet(fr, func_idx),
            .error_tag_name_get => |u| self.ops().emitErrorTagNameGet(u),

            // ── Switch branch ────────────────────────────────────────
            .switch_br => |sw| self.ops().emitSwitchBr(sw, func_idx),

            // ── Closure creation ─────────────────────────────────────
            .closure_create => |cc| self.ops().emitClosureCreate(cc),

            // ── Vector ops ───────────────────────────────────────────
            .vec_splat => |un| self.ops().emitVecSplat(instruction, un),
            .vec_extract => |bin| self.ops().emitVecExtract(bin),
            .vec_insert => |tri| self.ops().emitVecInsert(tri),

            // ── Block params ─────────────────────────────────────────
            .block_param => |bp| self.ops().emitBlockParam(instruction, bp),

            // ── Misc ─────────────────────────────────────────────────
            .placeholder => self.ops().emitPlaceholder(instruction),
        }
    }

    // ── Ref tracking ────────────────────────────────────────────────

    pub fn mapRef(self: *LLVMEmitter, val: c.LLVMValueRef) void {
        self.ref_map.put(self.ref_counter, val) catch unreachable;
        self.ref_counter += 1;
    }

    pub fn advanceRefCounter(self: *LLVMEmitter) void {
        self.ref_counter += 1;
    }

    pub fn resolveRef(self: *LLVMEmitter, ref: Ref) c.LLVMValueRef {
        if (ref.isNone()) {
            return c.LLVMGetUndef(self.cached_i64);
        }
        return self.ref_map.get(ref.index()) orelse c.LLVMGetUndef(self.cached_i64);
    }

    pub fn getBlock(self: *LLVMEmitter, func_idx: u32, block_id: BlockId) c.LLVMBasicBlockRef {
        const key = makeBlockKey(func_idx, block_id.index());
        return self.block_map.get(key) orelse {
            std.debug.print("getBlock: missing block func={d} block={d}\n", .{ func_idx, block_id.index() });
            unreachable;
        };
    }

    // ── Struct/union GEP helper ────────────────────────────────────────

    /// For struct_gep/union_gep: we need the LLVM type of the aggregate being pointed to.
    /// The instruction's type is the *result* (pointer to field), so we need to look at
    /// the IR instruction that produced the base pointer to find the aggregate type.
    /// As a fallback, we scan back through the ref_map to find the alloca type.
    fn getStructTypeForGep(self: *LLVMEmitter, instruction: *const Inst) ?c.LLVMTypeRef {
        // For GEP, the base ref points to an alloca or another pointer.
        // The instruction type is a pointer type (result of GEP), but we need the
        // aggregate type. We get it from the base pointer's allocated type.
        const fa = switch (instruction.op) {
            .struct_gep => |f| f,
            .union_gep => |f| f,
            else => unreachable,
        };
        const base_val = self.resolveRef(fa.base);
        // LLVMGetAllocatedType only works on alloca instructions
        if (c.LLVMIsAAllocaInst(base_val) != null) {
            const alloc_ty = c.LLVMGetAllocatedType(base_val);
            if (alloc_ty != null and isGepAggregateLLVMType(alloc_ty)) return alloc_ty;
        }
        // Fallback: trace LLVM value chain — if base came from a load,
        // check the load's source pointer for an alloca
        if (c.LLVMIsALoadInst(base_val) != null) {
            const load_ptr = c.LLVMGetOperand(base_val, 0);
            if (load_ptr != null and c.LLVMIsAAllocaInst(load_ptr) != null) {
                const inner_alloc = c.LLVMGetAllocatedType(load_ptr);
                if (inner_alloc != null and isGepAggregateLLVMType(inner_alloc)) return inner_alloc;
            }
        }
        // Fallback: look up the IR type of the base ref to find the pointee type
        const base_ir_ty = self.getRefIRType(fa.base);
        if (base_ir_ty) |ir_ty| {
            if (!ir_ty.isBuiltin()) {
                const info = self.ir_mod.types.get(ir_ty);
                switch (info) {
                    .pointer => |p| {
                        const llvm_ty = self.toLLVMType(p.pointee);
                        if (isGepAggregateLLVMType(llvm_ty)) return llvm_ty;
                    },
                    else => {
                        const llvm_ty = self.toLLVMType(ir_ty);
                        if (isGepAggregateLLVMType(llvm_ty)) return llvm_ty;
                    },
                }
            }
        }
        return null;
    }

    /// Only real aggregate representations are valid source element types for
    /// struct_gep/union_gep. A scalar type must never double as a failed-lookup
    /// sentinel (issue 0319).
    pub fn isGepAggregateLLVMType(llvm_ty: c.LLVMTypeRef) bool {
        if (llvm_ty == null) return false;
        return switch (c.LLVMGetTypeKind(llvm_ty)) {
            c.LLVMStructTypeKind,
            c.LLVMArrayTypeKind,
            c.LLVMVectorTypeKind,
            c.LLVMScalableVectorTypeKind,
            => true,
            else => false,
        };
    }

    /// Surface an unrecoverable GEP aggregate type as a backend diagnostic and
    /// gate the driver before LLVM verification/optimization/object emission.
    pub fn failGepTypeResolution(self: *LLVMEmitter, op_name: []const u8, base_ref: Ref) void {
        const func = &self.ir_mod.functions.items[self.current_func_idx];
        if (self.print_emission_diagnostics) {
            std.debug.print(
                "error: LLVM emission failed for {s} in '{s}': cannot resolve aggregate type for base ref %{d}; IR must provide base_type or recoverable aggregate pointer metadata\n",
                .{ op_name, self.ir_mod.types.getString(func.name), base_ref.index() },
            );
        }
        self.emission_failed = true;
    }

    /// Resolve the struct LLVM type for GEP operations.
    /// Uses LLVM alloca type when available, falls back to IR type system.
    pub fn resolveGepStructType(self: *LLVMEmitter, base_ref: Ref, instruction: *const Inst) ?c.LLVMTypeRef {
        const base_val = self.resolveRef(base_ref);

        // Strategy 1: base is an alloca — get allocated type directly
        if (c.LLVMIsAAllocaInst(base_val) != null) {
            const alloc_ty = c.LLVMGetAllocatedType(base_val);
            if (alloc_ty != null) {
                if (isGepAggregateLLVMType(alloc_ty)) return alloc_ty;
            }
        }

        // Strategy 2: Use IR type system — most accurate for chained GEPs (e.g. union_gep + struct_gep)
        const base_ir_ty = self.getRefIRType(base_ref);
        if (base_ir_ty) |ir_ty| {
            // Resolve through pointer types to find the pointee struct
            var resolved = ir_ty;
            if (!resolved.isBuiltin()) {
                const info = self.ir_mod.types.get(resolved);
                if (info == .pointer) {
                    resolved = info.pointer.pointee;
                }
            }
            if (!resolved.isBuiltin()) {
                const llvm_ty = self.toLLVMType(resolved);
                if (isGepAggregateLLVMType(llvm_ty)) return llvm_ty;
            }
        }

        // Strategy 3: base is a GEP result — get the source element type
        if (c.LLVMIsAGetElementPtrInst(base_val) != null) {
            const src_ty = c.LLVMGetGEPSourceElementType(base_val);
            if (src_ty != null) {
                if (isGepAggregateLLVMType(src_ty)) return src_ty;
            }
        }

        // Strategy 4: trace the producer/load chain. Failure remains null and
        // is diagnosed by the operation-specific caller.
        return self.getStructTypeForGep(instruction);
    }

    /// Resolve through pointer types to get the underlying aggregate type.
    pub fn resolveAggregate(self: *LLVMEmitter, ty: TypeId) TypeId {
        if (!ty.isBuiltin()) {
            const info = self.ir_mod.types.get(ty);
            if (info == .pointer) return info.pointer.pointee;
        }
        return ty;
    }

    // ── Comparison helpers ────────────────────────────────────────────

    pub fn emitCmp(self: *LLVMEmitter, bin: ir_inst.BinOp, _: TypeId, int_pred: c_uint, float_pred: c_uint) void {
        var lhs = self.resolveRef(bin.lhs);
        var rhs = self.resolveRef(bin.rhs);
        // Determine if float by inspecting operand LLVM type
        var lhs_ty = c.LLVMTypeOf(lhs);
        var kind = c.LLVMGetTypeKind(lhs_ty);
        var rhs_ty = c.LLVMTypeOf(rhs);
        var rhs_kind = c.LLVMGetTypeKind(rhs_ty);

        // Unwrap single-element struct (1-tuple) to scalar for comparison
        if (kind == c.LLVMStructTypeKind and rhs_kind != c.LLVMStructTypeKind) {
            if (c.LLVMCountStructElementTypes(lhs_ty) == 1) {
                lhs = c.LLVMBuildExtractValue(self.builder, lhs, 0, "tup.unwrap");
                lhs_ty = c.LLVMTypeOf(lhs);
                kind = c.LLVMGetTypeKind(lhs_ty);
            }
        } else if (rhs_kind == c.LLVMStructTypeKind and kind != c.LLVMStructTypeKind) {
            if (c.LLVMCountStructElementTypes(rhs_ty) == 1) {
                rhs = c.LLVMBuildExtractValue(self.builder, rhs, 0, "tup.unwrap");
                rhs_ty = c.LLVMTypeOf(rhs);
                rhs_kind = c.LLVMGetTypeKind(rhs_ty);
            }
        }

        // Struct types (strings, slices, tagged unions): compare fields individually
        if (kind == c.LLVMStructTypeKind and rhs_kind == c.LLVMStructTypeKind) {
            const n_fields = c.LLVMCountStructElementTypes(lhs_ty);
            if (n_fields >= 2) {
                const is_eq = (int_pred == c.LLVMIntEQ);
                const f0_l = c.LLVMBuildExtractValue(self.builder, lhs, 0, "sc.l0");
                const f0_r = c.LLVMBuildExtractValue(self.builder, rhs, 0, "sc.r0");
                const cmp0 = c.LLVMBuildICmp(self.builder, @intCast(int_pred), f0_l, f0_r, "sc.c0");

                // Check if field 1 is an array (tagged union payload) — skip comparison
                // For tagged unions {tag, [N x i8]}, the tag comparison alone is sufficient
                const f1_ty = c.LLVMStructGetTypeAtIndex(lhs_ty, 1);
                const f1_kind = c.LLVMGetTypeKind(f1_ty);
                if (f1_kind == c.LLVMArrayTypeKind) {
                    // Tagged union: compare tag only
                    self.mapRef(cmp0);
                    return;
                }

                const f1_l = c.LLVMBuildExtractValue(self.builder, lhs, 1, "sc.l1");
                const f1_r = c.LLVMBuildExtractValue(self.builder, rhs, 1, "sc.r1");
                const cmp1 = c.LLVMBuildICmp(self.builder, @intCast(int_pred), f1_l, f1_r, "sc.c1");
                const result = if (is_eq)
                    c.LLVMBuildAnd(self.builder, cmp0, cmp1, "sc.and")
                else
                    c.LLVMBuildOr(self.builder, cmp0, cmp1, "sc.or");
                self.mapRef(result);
                return;
            }
        }

        // Coerce operands to same type if needed
        if (kind == c.LLVMIntegerTypeKind and rhs_kind == c.LLVMIntegerTypeKind) {
            const lw = c.LLVMGetIntTypeWidth(lhs_ty);
            const rw = c.LLVMGetIntTypeWidth(rhs_ty);
            const is_unsigned = self.isRefUnsigned(bin.lhs) or self.isRefUnsigned(bin.rhs);
            if (is_unsigned) {
                if (lw < rw) lhs = c.LLVMBuildZExt(self.builder, lhs, rhs_ty, "cmp.ext") else if (rw < lw) rhs = c.LLVMBuildZExt(self.builder, rhs, lhs_ty, "cmp.ext");
            } else {
                if (lw < rw) lhs = c.LLVMBuildSExt(self.builder, lhs, rhs_ty, "cmp.ext") else if (rw < lw) rhs = c.LLVMBuildSExt(self.builder, rhs, lhs_ty, "cmp.ext");
            }
        }
        // Pointer vs integer: coerce int to null pointer
        if (kind == c.LLVMPointerTypeKind and rhs_kind == c.LLVMIntegerTypeKind) {
            rhs = c.LLVMConstNull(lhs_ty);
        } else if (kind == c.LLVMIntegerTypeKind and rhs_kind == c.LLVMPointerTypeKind) {
            lhs = c.LLVMConstNull(rhs_ty);
        }
        const result_kind = c.LLVMGetTypeKind(c.LLVMTypeOf(lhs));
        const result = if (result_kind == c.LLVMFloatTypeKind or result_kind == c.LLVMDoubleTypeKind)
            c.LLVMBuildFCmp(self.builder, @intCast(float_pred), lhs, rhs, "fcmp")
        else
            c.LLVMBuildICmp(self.builder, @intCast(int_pred), lhs, rhs, "icmp");
        self.mapRef(result);
    }

    pub fn emitCmpOrdered(self: *LLVMEmitter, bin: ir_inst.BinOp, _: TypeId, signed_pred: c_uint, unsigned_pred: c_uint, float_pred: c_uint) void {
        var lhs = self.resolveRef(bin.lhs);
        var rhs = self.resolveRef(bin.rhs);
        const lhs_ty = c.LLVMTypeOf(lhs);
        const kind = c.LLVMGetTypeKind(lhs_ty);
        // Determine signedness from IR operand type
        const is_unsigned = self.isRefUnsigned(bin.lhs) or self.isRefUnsigned(bin.rhs);
        // Coerce operands to same type if needed
        if (kind == c.LLVMIntegerTypeKind) {
            const rhs_ty = c.LLVMTypeOf(rhs);
            const rhs_kind = c.LLVMGetTypeKind(rhs_ty);
            if (rhs_kind == c.LLVMIntegerTypeKind) {
                const lw = c.LLVMGetIntTypeWidth(lhs_ty);
                const rw = c.LLVMGetIntTypeWidth(rhs_ty);
                if (is_unsigned) {
                    if (lw < rw) lhs = c.LLVMBuildZExt(self.builder, lhs, rhs_ty, "cmp.ext") else if (rw < lw) rhs = c.LLVMBuildZExt(self.builder, rhs, lhs_ty, "cmp.ext");
                } else {
                    if (lw < rw) lhs = c.LLVMBuildSExt(self.builder, lhs, rhs_ty, "cmp.ext") else if (rw < lw) rhs = c.LLVMBuildSExt(self.builder, rhs, lhs_ty, "cmp.ext");
                }
            }
        }
        const result = if (kind == c.LLVMFloatTypeKind or kind == c.LLVMDoubleTypeKind)
            c.LLVMBuildFCmp(self.builder, @intCast(float_pred), lhs, rhs, "fcmp")
        else if (is_unsigned)
            c.LLVMBuildICmp(self.builder, @intCast(unsigned_pred), lhs, rhs, "icmp")
        else
            c.LLVMBuildICmp(self.builder, @intCast(signed_pred), lhs, rhs, "icmp");
        self.mapRef(result);
    }

    /// String comparison via memcmp: compare length first, then content.
    pub fn emitStrCmp(self: *LLVMEmitter, bin: ir_inst.BinOp, is_eq: bool) void {
        const lhs = self.resolveRef(bin.lhs);
        const rhs = self.resolveRef(bin.rhs);
        const b = self.builder;
        const i32_ty = c.LLVMInt32TypeInContext(self.context);
        const i1_ty = c.LLVMInt1TypeInContext(self.context);
        const ptr_ty = c.LLVMPointerTypeInContext(self.context, 0);

        // Extract ptr and len from both fat pointers
        const lhs_ptr = c.LLVMBuildExtractValue(b, lhs, 0, "str.lp");
        const lhs_len = c.LLVMBuildExtractValue(b, lhs, 1, "str.ll");
        const rhs_ptr = c.LLVMBuildExtractValue(b, rhs, 0, "str.rp");
        const rhs_len = c.LLVMBuildExtractValue(b, rhs, 1, "str.rl");

        // Compare lengths first
        const len_eq = c.LLVMBuildICmp(b, c.LLVMIntEQ, lhs_len, rhs_len, "str.len_eq");

        // Set up basic blocks
        const cur_fn = c.LLVMGetBasicBlockParent(c.LLVMGetInsertBlock(b));
        const memcmp_bb = c.LLVMAppendBasicBlockInContext(self.context, cur_fn, "str.memcmp");
        const merge_bb = c.LLVMAppendBasicBlockInContext(self.context, cur_fn, "str.merge");

        const cur_bb = c.LLVMGetInsertBlock(b);
        _ = c.LLVMBuildCondBr(b, len_eq, memcmp_bb, merge_bb);

        // memcmp block
        c.LLVMPositionBuilderAtEnd(b, memcmp_bb);
        const size_ty = self.sizeType();
        const memcmp_fn = c.LLVMGetNamedFunction(self.llvm_module, "memcmp") orelse blk: {
            var params = [_]c.LLVMTypeRef{ ptr_ty, ptr_ty, size_ty };
            const fn_type = c.LLVMFunctionType(i32_ty, &params, 3, 0);
            break :blk c.LLVMAddFunction(self.llvm_module, "memcmp", fn_type);
        };
        const cmp_len = self.coerceArg(lhs_len, size_ty);
        var args = [_]c.LLVMValueRef{ lhs_ptr, rhs_ptr, cmp_len };
        const fn_ty = c.LLVMGlobalGetValueType(memcmp_fn);
        const cmp_result = c.LLVMBuildCall2(b, fn_ty, memcmp_fn, &args, 3, "memcmp");
        const content_eq = c.LLVMBuildICmp(b, c.LLVMIntEQ, cmp_result, c.LLVMConstInt(i32_ty, 0, 0), "str.ceq");
        _ = c.LLVMBuildBr(b, merge_bb);

        // Merge block: phi(len_mismatch=false, memcmp_result)
        c.LLVMPositionBuilderAtEnd(b, merge_bb);
        const phi = c.LLVMBuildPhi(b, i1_ty, "str.eq");
        const false_val = c.LLVMConstInt(i1_ty, 0, 0);
        var phi_vals = [_]c.LLVMValueRef{ false_val, content_eq };
        var phi_bbs = [_]c.LLVMBasicBlockRef{ cur_bb, memcmp_bb };
        c.LLVMAddIncoming(phi, &phi_vals, &phi_bbs, 2);

        const result = if (is_eq)
            phi
        else
            c.LLVMBuildNot(b, phi, "str.ne");
        self.mapRef(result);
    }

    // ── Conversion helpers ──────────────────────────────────────────

    pub fn emitConversion(self: *LLVMEmitter, operand: c.LLVMValueRef, from: TypeId, to: TypeId, to_ty: c.LLVMTypeRef) c.LLVMValueRef {
        const from_float = isFloatOrVecFloat(from, &self.ir_mod.types);
        const to_float = isFloatOrVecFloat(to, &self.ir_mod.types);

        if (from_float and to_float) {
            // float→float: FPExt or FPTrunc
            const from_bits = floatBits(from);
            const to_bits = floatBits(to);
            return if (to_bits > from_bits)
                c.LLVMBuildFPExt(self.builder, operand, to_ty, "fpext")
            else
                c.LLVMBuildFPTrunc(self.builder, operand, to_ty, "fptrunc");
        }

        if (from_float and !to_float) {
            return if (isSignedType(to))
                c.LLVMBuildFPToSI(self.builder, operand, to_ty, "fptosi")
            else
                c.LLVMBuildFPToUI(self.builder, operand, to_ty, "fptoui");
        }

        if (!from_float and to_float) {
            return if (self.isSignedTypeEx(from))
                c.LLVMBuildSIToFP(self.builder, operand, to_ty, "sitofp")
            else
                c.LLVMBuildUIToFP(self.builder, operand, to_ty, "uitofp");
        }

        // int→int: SExt, ZExt, or Trunc. Arbitrary-width int TypeIds carry
        // their width in the type table — `intBits` only knows builtins and
        // would misclassify e.g. a u1→u32 widen as a 64→32 truncation.
        const ptr_bits: u32 = @as(u32, self.ir_mod.types.pointer_size) * 8;
        const from_bits = intBitsEx(self, from) orelse ptr_bits;
        const to_bits = intBitsEx(self, to) orelse ptr_bits;
        if (to_bits > from_bits) {
            // Sign check must be table-aware: an arbitrary-width `.signed`
            // TypeId is not a builtin, and the builtin-only `isSignedType`
            // would zero-extend it (i1 -1 → 1).
            return if (self.isSignedTypeEx(from))
                c.LLVMBuildSExt(self.builder, operand, to_ty, "sext")
            else
                c.LLVMBuildZExt(self.builder, operand, to_ty, "zext");
        } else if (to_bits < from_bits) {
            return c.LLVMBuildTrunc(self.builder, operand, to_ty, "trunc");
        }
        // Same width — no-op (bitcast or just return)
        return operand;
    }

    // ── Malloc/Free declarations ────────────────────────────────────

    fn getOrDeclareMalloc(self: *LLVMEmitter) c.LLVMValueRef {
        if (c.LLVMGetNamedFunction(self.llvm_module, "malloc")) |f| return f;
        const fn_ty = self.getMallocType();
        return c.LLVMAddFunction(self.llvm_module, "malloc", fn_ty);
    }

    fn getOrDeclareFree(self: *LLVMEmitter) c.LLVMValueRef {
        if (c.LLVMGetNamedFunction(self.llvm_module, "free")) |f| return f;
        const fn_ty = self.getFreeType();
        return c.LLVMAddFunction(self.llvm_module, "free", fn_ty);
    }

    /// Returns the LLVM type for C `size_t`: i32 on wasm32, i64 on 64-bit targets (including wasm64).
    fn sizeType(self: *LLVMEmitter) c.LLVMTypeRef {
        return if (self.target_config.isWasm32()) self.cached_i32 else self.cached_i64;
    }

    fn getMallocType(self: *LLVMEmitter) c.LLVMTypeRef {
        // malloc(size_t) → ptr
        var param_types = [_]c.LLVMTypeRef{self.sizeType()};
        return c.LLVMFunctionType(self.cached_ptr, &param_types, 1, 0);
    }

    fn getFreeType(self: *LLVMEmitter) c.LLVMTypeRef {
        // free(ptr) → void
        var param_types = [_]c.LLVMTypeRef{self.cached_ptr};
        return c.LLVMFunctionType(self.cached_void, &param_types, 1, 0);
    }

    fn getOrDeclareMemcpy(self: *LLVMEmitter) c.LLVMValueRef {
        if (c.LLVMGetNamedFunction(self.llvm_module, "memcpy")) |f| return f;
        return c.LLVMAddFunction(self.llvm_module, "memcpy", self.getMemcpyType());
    }

    fn getMemcpyType(self: *LLVMEmitter) c.LLVMTypeRef {
        // memcpy(ptr, ptr, size_t) → ptr
        var param_types = [_]c.LLVMTypeRef{ self.cached_ptr, self.cached_ptr, self.sizeType() };
        return c.LLVMFunctionType(self.cached_ptr, &param_types, 3, 0);
    }

    fn getOrDeclareMemset(self: *LLVMEmitter) c.LLVMValueRef {
        if (c.LLVMGetNamedFunction(self.llvm_module, "memset")) |f| return f;
        return c.LLVMAddFunction(self.llvm_module, "memset", self.getMemsetType());
    }

    fn getMemsetType(self: *LLVMEmitter) c.LLVMTypeRef {
        // memset(ptr, i32, size_t) → ptr
        var param_types = [_]c.LLVMTypeRef{ self.cached_ptr, self.cached_i32, self.sizeType() };
        return c.LLVMFunctionType(self.cached_ptr, &param_types, 3, 0);
    }

    pub fn getOrDeclareMathF64(self: *LLVMEmitter, id: ir_inst.BuiltinId) c.LLVMValueRef {
        const name: [*:0]const u8 = switch (id) {
            .sqrt => "sqrt",
            .sin => "sin",
            .cos => "cos",
            .floor => "floor",
            else => unreachable,
        };
        if (c.LLVMGetNamedFunction(self.llvm_module, name)) |f| return f;
        return c.LLVMAddFunction(self.llvm_module, name, self.getMathF64Type());
    }

    pub fn getMathF64Type(self: *LLVMEmitter) c.LLVMTypeRef {
        var param_types = [_]c.LLVMTypeRef{self.cached_f64};
        return c.LLVMFunctionType(self.cached_f64, &param_types, 1, 0);
    }

    pub fn getOrDeclareMathF32(self: *LLVMEmitter, id: ir_inst.BuiltinId) c.LLVMValueRef {
        const name: [*:0]const u8 = switch (id) {
            .sqrt => "sqrtf",
            .sin => "sinf",
            .cos => "cosf",
            .floor => "floorf",
            else => unreachable,
        };
        if (c.LLVMGetNamedFunction(self.llvm_module, name)) |f| return f;
        return c.LLVMAddFunction(self.llvm_module, name, self.getMathF32Type());
    }

    pub fn getMathF32Type(self: *LLVMEmitter) c.LLVMTypeRef {
        var param_types = [_]c.LLVMTypeRef{self.cached_f32};
        return c.LLVMFunctionType(self.cached_f32, &param_types, 1, 0);
    }

    fn getOrDeclareMemcmp(self: *LLVMEmitter) c.LLVMValueRef {
        if (c.LLVMGetNamedFunction(self.llvm_module, "memcmp")) |f| return f;
        // memcmp(ptr, ptr, size_t) → i32
        var param_types = [_]c.LLVMTypeRef{ self.cached_ptr, self.cached_ptr, self.sizeType() };
        const fn_ty = c.LLVMFunctionType(self.cached_i32, &param_types, 3, 0);
        return c.LLVMAddFunction(self.llvm_module, "memcmp", fn_ty);
    }

    pub fn getOrDeclareWrite(self: *LLVMEmitter) c.LLVMValueRef {
        if (c.LLVMGetNamedFunction(self.llvm_module, "write")) |f| return f;
        return c.LLVMAddFunction(self.llvm_module, "write", self.getWriteType());
    }

    pub fn getWriteType(self: *LLVMEmitter) c.LLVMTypeRef {
        // write(fd: i32, buf: ptr, count: size_t) → ssize_t
        const st = self.sizeType();
        var param_types = [_]c.LLVMTypeRef{ self.cached_i32, self.cached_ptr, st };
        return c.LLVMFunctionType(st, &param_types, 3, 0);
    }

    fn getOrDeclareSnprintf(self: *LLVMEmitter) c.LLVMValueRef {
        if (c.LLVMGetNamedFunction(self.llvm_module, "snprintf")) |f| return f;
        return c.LLVMAddFunction(self.llvm_module, "snprintf", self.getSnprintfType());
    }

    fn getSnprintfType(self: *LLVMEmitter) c.LLVMTypeRef {
        // snprintf(buf: ptr, size: i32, fmt: ptr, ...) → i32  (variadic)
        var param_types = [_]c.LLVMTypeRef{ self.cached_ptr, self.cached_i32, self.cached_ptr };
        return c.LLVMFunctionType(self.cached_i32, &param_types, 3, 1); // 1 = variadic
    }

    /// Check if a function name is a known libc builtin that has a dedicated
    /// getOrDeclare* helper with correct C-compatible types.
    fn isBuiltinLibcName(name: []const u8) bool {
        const builtins = [_][]const u8{ "malloc", "free", "memcpy", "memset", "memcmp", "write", "snprintf" };
        for (builtins) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
    }

    /// Get or declare a builtin libc function by name, using the correct C-compatible type.
    fn getOrDeclareBuiltinByName(self: *LLVMEmitter, name: []const u8) ?c.LLVMValueRef {
        if (std.mem.eql(u8, name, "malloc")) return self.getOrDeclareMalloc();
        if (std.mem.eql(u8, name, "free")) return self.getOrDeclareFree();
        if (std.mem.eql(u8, name, "memcpy")) return self.getOrDeclareMemcpy();
        if (std.mem.eql(u8, name, "memset")) return self.getOrDeclareMemset();
        if (std.mem.eql(u8, name, "memcmp")) return self.getOrDeclareMemcmp();
        if (std.mem.eql(u8, name, "write")) return self.getOrDeclareWrite();
        if (std.mem.eql(u8, name, "snprintf")) return self.getOrDeclareSnprintf();
        return null;
    }

    /// Build a string fat pointer {ptr, len} from raw pointer and length.
    fn buildStringValue(self: *LLVMEmitter, ptr: c.LLVMValueRef, len: c.LLVMValueRef) c.LLVMValueRef {
        const str_ty = self.getStringStructType();
        const undef = c.LLVMGetUndef(str_ty);
        const with_ptr = c.LLVMBuildInsertValue(self.builder, undef, ptr, 0, "s.ptr");
        return c.LLVMBuildInsertValue(self.builder, with_ptr, len, 1, "s.len");
    }

    // ── Value coercion helpers ──────────────────────────────────────

    /// Check if a TypeId represents a signed integer type (including arbitrary-width).
    pub fn isSignedTypeEx(self: *LLVMEmitter, ty: TypeId) bool {
        if (isSignedType(ty)) return true;
        if (!ty.isBuiltin()) {
            const info = self.ir_mod.types.get(ty);
            return info == .signed;
        }
        return false;
    }

    /// Map a TypeId to its Any tag value.
    /// Uses TypeId.index() directly — this matches resolveTypeCategoryTags in lower.zig
    /// which also uses TypeId indices for type-switch comparisons.
    /// For arbitrary-width ints (user-defined signed/unsigned), map to the closest
    /// builtin TypeId so the "case int:" branch matches correctly.
    /// Map a TypeId to its Any tag value.
    /// Uses TypeId.index() directly — this matches resolveTypeCategoryTags in lower.zig
    /// which also uses TypeId indices for type-switch comparisons.
    /// For arbitrary-width ints (user-defined signed/unsigned), map to the closest
    /// builtin TypeId so the "case int:" branch matches correctly.
    pub fn anyTag(self: *LLVMEmitter, ty: TypeId) u64 {
        if (ty.isBuiltin()) return ty.index();
        // For user-defined types, check if they're arbitrary-width ints
        const info = self.ir_mod.types.get(ty);
        return switch (info) {
            .signed => |w| switch (w) {
                8 => TypeId.i8.index(),
                16 => TypeId.i16.index(),
                32 => TypeId.i32.index(),
                64 => TypeId.i64.index(),
                else => if (w <= 32) TypeId.i32.index() else TypeId.i64.index(),
            },
            .unsigned => |w| switch (w) {
                8 => TypeId.u8.index(),
                16 => TypeId.u16.index(),
                32 => TypeId.u32.index(),
                64 => TypeId.u64.index(),
                else => if (w <= 32) TypeId.u32.index() else TypeId.u64.index(),
            },
            else => ty.index(),
        };
    }

    /// Coerce a call argument to match the expected parameter type.
    /// Handles int width mismatches (trunc/ext), float width, and int↔float.
    /// How an EXTERN function's declared sx return maps onto a C `char *`:
    /// `-> string` (.plain) and `-> ?string` (.optional) both receive one
    /// pointer from C; everything else is `.none`. Keep `declareFunction`'s
    /// signature building and `emitCall`'s result synthesis keyed on the
    /// SAME classification or the ABI splits.
    pub const CstrRet = enum { none, plain, optional };

    pub fn cstrRetKind(self: *LLVMEmitter, func: *const Function) CstrRet {
        if (!func.is_extern) return .none;
        if (func.ret == .string) return .plain;
        if (!func.ret.isBuiltin()) {
            const info = self.ir_mod.types.get(func.ret);
            if (info == .optional and info.optional.child == .string) return .optional;
        }
        return .none;
    }

    /// Build the sx-level value for a extern call that returned a `char *`:
    /// `{ptr, strlen(ptr)}` for `string` (NULL → `{null, 0}`), wrapped in
    /// `{string, i1}` with `has = ptr != null` for `?string`. The strlen call
    /// is branch-guarded — `select` would evaluate `strlen(NULL)`.
    pub fn cstrReturnToSx(self: *LLVMEmitter, p: c.LLVMValueRef, optional: bool) c.LLVMValueRef {
        const strlen_fn = c.LLVMGetNamedFunction(self.llvm_module, "strlen") orelse blk: {
            var pt = [_]c.LLVMTypeRef{self.cached_ptr};
            const ft = c.LLVMFunctionType(self.cached_i64, &pt, 1, 0);
            break :blk c.LLVMAddFunction(self.llvm_module, "strlen", ft);
        };
        const strlen_ty = c.LLVMGlobalGetValueType(strlen_fn);

        const cur_fn = c.LLVMGetBasicBlockParent(c.LLVMGetInsertBlock(self.builder));
        const entry_bb = c.LLVMGetInsertBlock(self.builder);
        const len_bb = c.LLVMAppendBasicBlockInContext(self.context, cur_fn, "cstr.len");
        const join_bb = c.LLVMAppendBasicBlockInContext(self.context, cur_fn, "cstr.join");

        const is_null = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, p, c.LLVMConstNull(self.cached_ptr), "cstr.isnull");
        _ = c.LLVMBuildCondBr(self.builder, is_null, join_bb, len_bb);

        c.LLVMPositionBuilderAtEnd(self.builder, len_bb);
        var sargs = [_]c.LLVMValueRef{p};
        const n = c.LLVMBuildCall2(self.builder, strlen_ty, strlen_fn, &sargs, 1, "cstr.n");
        _ = c.LLVMBuildBr(self.builder, join_bb);

        c.LLVMPositionBuilderAtEnd(self.builder, join_bb);
        const len_phi = c.LLVMBuildPhi(self.builder, self.cached_i64, "cstr.lenphi");
        var ivals = [_]c.LLVMValueRef{ c.LLVMConstInt(self.cached_i64, 0, 0), n };
        var ibbs = [_]c.LLVMBasicBlockRef{ entry_bb, len_bb };
        c.LLVMAddIncoming(len_phi, &ivals, &ibbs, 2);

        const str_ty = self.getStringStructType();
        var s = c.LLVMGetUndef(str_ty);
        s = c.LLVMBuildInsertValue(self.builder, s, p, 0, "cstr.sp");
        s = c.LLVMBuildInsertValue(self.builder, s, len_phi, 1, "cstr.sv");
        if (!optional) return s;

        var ofields = [_]c.LLVMTypeRef{ str_ty, self.cached_i1 };
        const opt_ty = c.LLVMStructTypeInContext(self.context, &ofields, 2, 0);
        const has = c.LLVMBuildNot(self.builder, is_null, "cstr.has");
        var o = c.LLVMGetUndef(opt_ty);
        o = c.LLVMBuildInsertValue(self.builder, o, s, 0, "cstr.ov");
        o = c.LLVMBuildInsertValue(self.builder, o, has, 1, "cstr.opt");
        return o;
    }

    pub fn coerceArg(self: *LLVMEmitter, val: c.LLVMValueRef, param_ty: c.LLVMTypeRef) c.LLVMValueRef {
        const val_ty = c.LLVMTypeOf(val);
        if (val_ty == param_ty) return val;
        const val_kind = c.LLVMGetTypeKind(val_ty);
        const param_kind = c.LLVMGetTypeKind(param_ty);

        // Int → Int (width mismatch)
        if (val_kind == c.LLVMIntegerTypeKind and param_kind == c.LLVMIntegerTypeKind) {
            const val_w = c.LLVMGetIntTypeWidth(val_ty);
            const param_w = c.LLVMGetIntTypeWidth(param_ty);
            if (val_w > param_w) {
                return c.LLVMBuildTrunc(self.builder, val, param_ty, "ca.tr");
            } else {
                // Use ZExt by default — preserves bit pattern for unsigned types.
                // Signed widening is handled by explicit widen instructions from the IR.
                return c.LLVMBuildZExt(self.builder, val, param_ty, "ca.ext");
            }
        }
        // Float → Float (width mismatch)
        if ((val_kind == c.LLVMFloatTypeKind or val_kind == c.LLVMDoubleTypeKind) and
            (param_kind == c.LLVMFloatTypeKind or param_kind == c.LLVMDoubleTypeKind))
        {
            if (val_kind == c.LLVMFloatTypeKind and param_kind == c.LLVMDoubleTypeKind) {
                return c.LLVMBuildFPExt(self.builder, val, param_ty, "ca.fpext");
            } else {
                return c.LLVMBuildFPTrunc(self.builder, val, param_ty, "ca.fptrunc");
            }
        }
        // Int → Float (use SIToFP for i1/bool, UIToFP otherwise for safe default)
        if (val_kind == c.LLVMIntegerTypeKind and (param_kind == c.LLVMFloatTypeKind or param_kind == c.LLVMDoubleTypeKind)) {
            const val_w = c.LLVMGetIntTypeWidth(val_ty);
            if (val_w == 1) {
                return c.LLVMBuildUIToFP(self.builder, val, param_ty, "ca.uitofp");
            }
            // Default to SIToFP since most sx integers are signed (i64).
            // Explicit unsigned conversions go through the IR widen/narrow path.
            return c.LLVMBuildSIToFP(self.builder, val, param_ty, "ca.sitofp");
        }
        // Float → Int
        if ((val_kind == c.LLVMFloatTypeKind or val_kind == c.LLVMDoubleTypeKind) and param_kind == c.LLVMIntegerTypeKind) {
            return c.LLVMBuildFPToSI(self.builder, val, param_ty, "ca.fptosi");
        }
        // Ptr → Struct (closure auto-promotion: fn_ptr → {fn_ptr, null_env})
        if (val_kind == c.LLVMPointerTypeKind and param_kind == c.LLVMStructTypeKind) {
            const num_fields = c.LLVMCountStructElementTypes(param_ty);
            if (num_fields == 2) {
                const f0 = c.LLVMStructGetTypeAtIndex(param_ty, 0);
                const f1 = c.LLVMStructGetTypeAtIndex(param_ty, 1);
                if (c.LLVMGetTypeKind(f0) == c.LLVMPointerTypeKind and c.LLVMGetTypeKind(f1) == c.LLVMPointerTypeKind) {
                    var result = c.LLVMGetUndef(param_ty);
                    result = c.LLVMBuildInsertValue(self.builder, result, val, 0, "ca.cls.fn");
                    result = c.LLVMBuildInsertValue(self.builder, result, c.LLVMConstNull(f1), 1, "ca.cls.env");
                    return result;
                }
            }
        }
        // Scalar → Vector (splat: broadcast scalar to all lanes)
        if (param_kind == c.LLVMVectorTypeKind or param_kind == c.LLVMScalableVectorTypeKind) {
            const vec_elem_ty = c.LLVMGetElementType(param_ty);
            const vec_len = c.LLVMGetVectorSize(param_ty);
            // First coerce scalar to the vector element type
            const scalar = self.coerceArg(val, vec_elem_ty);
            // Then splat into a vector
            var result = c.LLVMGetUndef(param_ty);
            var lane: c_uint = 0;
            while (lane < vec_len) : (lane += 1) {
                const idx = c.LLVMConstInt(self.cached_i32, lane, 0);
                result = c.LLVMBuildInsertElement(self.builder, result, scalar, idx, "splat");
            }
            return result;
        }
        // Struct → Ptr (string/slice decay: extract field 0 = raw pointer)
        // Only for 2-field structs {ptr, i64} (fat pointers) — avoids breaking other struct→ptr cases
        if (val_kind == c.LLVMStructTypeKind and param_kind == c.LLVMPointerTypeKind) {
            const num_fields = c.LLVMCountStructElementTypes(val_ty);
            if (num_fields == 2) {
                const field0_ty = c.LLVMStructGetTypeAtIndex(val_ty, 0);
                if (c.LLVMGetTypeKind(field0_ty) == c.LLVMPointerTypeKind) {
                    return c.LLVMBuildExtractValue(self.builder, val, 0, "ca.decay");
                }
            }
        }
        // Struct → Integer (C ABI coercion: store struct to memory, load as integer)
        if (val_kind == c.LLVMStructTypeKind and param_kind == c.LLVMIntegerTypeKind) {
            const tmp = self.buildEntryAlloca(param_ty, "abi.tmp");
            _ = c.LLVMBuildStore(self.builder, c.LLVMConstNull(param_ty), tmp);
            _ = c.LLVMBuildStore(self.builder, val, tmp);
            return c.LLVMBuildLoad2(self.builder, param_ty, tmp, "abi.coerce");
        }
        // Integer → Struct (C ABI return coercion: store integer to memory, load as struct)
        if (val_kind == c.LLVMIntegerTypeKind and param_kind == c.LLVMStructTypeKind) {
            const tmp = self.buildEntryAlloca(val_ty, "abi.ret.tmp");
            _ = c.LLVMBuildStore(self.builder, val, tmp);
            return c.LLVMBuildLoad2(self.builder, param_ty, tmp, "abi.ret.coerce");
        }
        // Struct → Array (C ABI coercion for 9..16-byte structs — paired with
        // abiCoerceParamType's `[2 x i64]` slot for that size class). Same
        // memory-bitcast pattern as the integer case; the array type carries
        // 16 bytes of storage so we alloca with param_ty to guarantee size.
        if (val_kind == c.LLVMStructTypeKind and param_kind == c.LLVMArrayTypeKind) {
            const tmp = self.buildEntryAlloca(param_ty, "abi.struct2arr");
            _ = c.LLVMBuildStore(self.builder, val, tmp);
            return c.LLVMBuildLoad2(self.builder, param_ty, tmp, "abi.coerce.arr");
        }
        // Array → Struct (return-side counterpart for 9..16-byte structs)
        if (val_kind == c.LLVMArrayTypeKind and param_kind == c.LLVMStructTypeKind) {
            const tmp = self.buildEntryAlloca(val_ty, "abi.arr2struct");
            _ = c.LLVMBuildStore(self.builder, val, tmp);
            return c.LLVMBuildLoad2(self.builder, param_ty, tmp, "abi.ret.coerce.arr");
        }
        // Array → Ptr (array decay: alloca + GEP to first element)
        if (val_kind == c.LLVMArrayTypeKind and param_kind == c.LLVMPointerTypeKind) {
            const tmp = self.buildEntryAlloca(val_ty, "ca.arr");
            _ = c.LLVMBuildStore(self.builder, val, tmp);
            const zero = c.LLVMConstInt(self.cached_i64, 0, 0);
            var indices = [_]c.LLVMValueRef{ zero, zero };
            return c.LLVMBuildGEP2(self.builder, val_ty, tmp, &indices, 2, "ca.decay");
        }
        // Int → Ptr (null literal: inttoptr)
        if (val_kind == c.LLVMIntegerTypeKind and param_kind == c.LLVMPointerTypeKind) {
            return c.LLVMBuildIntToPtr(self.builder, val, param_ty, "ca.itp");
        }
        return val;
    }

    /// Look up the IR type of a Ref in the current function (for store coercion).
    pub fn getRefIRType(self: *LLVMEmitter, ref: Ref) ?TypeId {
        const func = &self.ir_mod.functions.items[self.current_func_idx];
        const idx = ref.index();
        // Check if it's a function param (refs 0..N-1)
        if (idx < func.params.len) return func.params[idx].ty;
        for (func.blocks.items) |blk| {
            if (idx >= blk.first_ref and idx < blk.first_ref + blk.insts.items.len) {
                return blk.insts.items[idx - blk.first_ref].ty;
            }
        }
        return null;
    }

    /// Resolve the IR type of a extern-call argument ref. Every FFI arg ref is
    /// a real function param or block instruction result, so a `null` here is a
    /// codegen invariant violation, not a recoverable case: return the dedicated
    /// `.unresolved` sentinel — never `.void`/`.i64` — so the failure cannot be
    /// mistaken for a real type and trips `toLLVMType`'s hard tripwire at the call
    /// site instead of silently emitting a void-typed extern argument.
    pub fn argIRTypeOrFail(self: *LLVMEmitter, arg_ref: Ref) TypeId {
        return self.getRefIRType(arg_ref) orelse .unresolved;
    }

    /// How a reflection builtin (`type_name` / `type_eq`) must read its `Type`
    /// argument: boxed inside an `Any` aggregate (extract the value field) vs a
    /// bare i64 `TypeId` index. The IR-type lookup is must-succeed, so it routes
    /// through `argIRTypeOrFail`; a failed lookup surfaces as `.unresolved` —
    /// never a silent `.i64` that would mis-classify a boxed arg as bare and read
    /// the wrong value. The caller turns `.unresolved` into a hard tripwire.
    pub const ReflectArgRepr = enum { boxed, bare, unresolved };

    pub fn reflectArgRepr(self: *LLVMEmitter, arg_ref: Ref) ReflectArgRepr {
        return switch (self.argIRTypeOrFail(arg_ref)) {
            .unresolved => .unresolved,
            .any => .boxed,
            else => .bare,
        };
    }

    /// Coerce both binary operands to match the instruction's result type.
    /// E.g. if result is i64 but one operand is i32, sext it.
    pub fn matchBinOpTypes(self: *LLVMEmitter, lhs: *c.LLVMValueRef, rhs: *c.LLVMValueRef, result_ty: TypeId) void {
        const target = self.toLLVMType(result_ty);
        lhs.* = self.coerceArg(lhs.*, target);
        rhs.* = self.coerceArg(rhs.*, target);
    }

    // ── Type conversion ─────────────────────────────────────────────

    fn typeLowering(self: *LLVMEmitter) llvm_types.TypeLowering {
        return .{ .e = self };
    }

    fn abiLowering(self: *LLVMEmitter) llvm_abi.AbiLowering {
        return .{ .e = self };
    }

    fn debugInfo(self: *LLVMEmitter) llvm_debug.DebugInfo {
        return .{ .e = self };
    }

    pub fn reflection(self: *LLVMEmitter) llvm_reflection.Reflection {
        return .{ .e = self };
    }

    pub fn ffiCtors(self: *LLVMEmitter) llvm_ffi_ctors.FfiCtors {
        return .{ .e = self };
    }

    fn ops(self: *LLVMEmitter) llvm_ops.Ops {
        return .{ .e = self };
    }

    /// IR-type → LLVM-type lowering lives in `backend/llvm/types.zig`
    /// (`TypeLowering`). This stays the facade entry point (~97 callers).
    pub fn toLLVMType(self: *LLVMEmitter, ty: TypeId) c.LLVMTypeRef {
        return self.typeLowering().toLLVMType(ty);
    }

    // ── C ABI coercion for extern functions ──────────────────────────
    // The coercion logic lives in `backend/llvm/abi.zig` (`AbiLowering`);
    // these stay the facade entry points (callers in signature/call emission +
    // the block-trampoline path use abiCoerceParamTypeEx directly).

    pub fn abiCoerceParamType(self: *LLVMEmitter, ir_ty: TypeId, llvm_ty: c.LLVMTypeRef) c.LLVMTypeRef {
        return self.abiLowering().abiCoerceParamType(ir_ty, llvm_ty);
    }

    pub fn abiCoerceParamTypeEx(self: *LLVMEmitter, ir_ty: TypeId, llvm_ty: c.LLVMTypeRef, is_extern_c_api: bool) c.LLVMTypeRef {
        return self.abiLowering().abiCoerceParamTypeEx(ir_ty, llvm_ty, is_extern_c_api);
    }

    pub fn abiCoerceDefaultParamType(self: *LLVMEmitter, ir_ty: TypeId, llvm_ty: c.LLVMTypeRef) c.LLVMTypeRef {
        return self.abiLowering().abiCoerceDefaultParamType(ir_ty, llvm_ty);
    }

    pub fn needsByval(self: *LLVMEmitter, ir_ty: TypeId, raw_llvm_ty: c.LLVMTypeRef) bool {
        return self.abiLowering().needsByval(ir_ty, raw_llvm_ty);
    }

    pub fn materializeByvalArg(self: *LLVMEmitter, val: c.LLVMValueRef, struct_ty: c.LLVMTypeRef) c.LLVMValueRef {
        return self.abiLowering().materializeByvalArg(val, struct_ty);
    }

    // ── Cached composite types ──────────────────────────────────────

    pub fn getStringStructType(self: *LLVMEmitter) c.LLVMTypeRef {
        if (self.string_struct_type) |t| return t;
        var field_types = [_]c.LLVMTypeRef{
            self.cached_ptr, // ptr
            self.cached_i64, // len
        };
        self.string_struct_type = c.LLVMStructTypeInContext(self.context, &field_types, 2, 0);
        return self.string_struct_type.?;
    }

    /// The compiled error-trace `Frame` type: `{ string, i32, i32, string }`.
    /// Layout must match `Frame` in `trace.sx` and `SxFrame` in `sx_trace.c`.
    pub fn getFrameStructType(self: *LLVMEmitter) c.LLVMTypeRef {
        if (self.frame_struct_type) |t| return t;
        const str_ty = self.getStringStructType();
        var field_types = [_]c.LLVMTypeRef{
            str_ty, // file
            self.cached_i32, // line
            self.cached_i32, // col
            str_ty, // func
            str_ty, // line_text (the source line, for the snippet)
        };
        self.frame_struct_type = c.LLVMStructTypeInContext(self.context, &field_types, 5, 0);
        return self.frame_struct_type.?;
    }

    pub fn getAnyStructType(self: *LLVMEmitter) c.LLVMTypeRef {
        if (self.any_struct_type) |t| return t;
        var field_types = [_]c.LLVMTypeRef{
            self.cached_i64, // type tag
            self.cached_i64, // value
        };
        self.any_struct_type = c.LLVMStructTypeInContext(self.context, &field_types, 2, 0);
        return self.any_struct_type.?;
    }

    pub fn getClosureStructType(self: *LLVMEmitter) c.LLVMTypeRef {
        if (self.closure_struct_type) |t| return t;
        var field_types = [_]c.LLVMTypeRef{
            self.cached_ptr, // fn_ptr
            self.cached_ptr, // env
        };
        self.closure_struct_type = c.LLVMStructTypeInContext(self.context, &field_types, 2, 0);
        return self.closure_struct_type.?;
    }

    // ── String constant emission ────────────────────────────────────

    /// Build a constant string { ptr, i64 } value without using the builder
    /// (safe to call during global initialization, before any function body is emitted).
    fn emitConstStringGlobal(self: *LLVMEmitter, str: []const u8) c.LLVMValueRef {
        const str_z = self.alloc.dupeZ(u8, str) catch unreachable;
        defer self.alloc.free(str_z);
        const len: c_uint = @intCast(str.len + 1); // include null terminator
        const str_const = c.LLVMConstStringInContext(self.context, str_z.ptr, len - 1, 0);
        const arr_ty = c.LLVMArrayType2(self.cached_i8, len);
        const str_global_val = c.LLVMAddGlobal(self.llvm_module, arr_ty, "str.data");
        c.LLVMSetInitializer(str_global_val, str_const);
        c.LLVMSetGlobalConstant(str_global_val, 1);
        c.LLVMSetLinkage(str_global_val, c.LLVMPrivateLinkage);
        c.LLVMSetUnnamedAddress(str_global_val, c.LLVMGlobalUnnamedAddr);
        // Build constant { ptr, i64 } aggregate
        const len_val = c.LLVMConstInt(self.cached_i64, str.len, 0);
        var fields = [_]c.LLVMValueRef{ str_global_val, len_val };
        return c.LLVMConstStructInContext(self.context, &fields, 2, 0);
    }

    /// Serialize a constant aggregate to an LLVM constant. `require_resolved`
    /// governs the func_ref leaves: in Pass 0 (`emitGlobals`) func_map is empty,
    /// so func_refs are left as a transient null placeholder (`false`) and the
    /// whole aggregate is re-emitted by `initVtableGlobals` after Pass 1 with
    /// `true`, where any still-unresolved func_ref is a loud diagnostic — never
    /// a silently-null function pointer.
    fn emitConstAggregate(self: *LLVMEmitter, agg: []const ir_inst.ConstantValue, llvm_ty: c.LLVMTypeRef, require_resolved: bool) c.LLVMValueRef {
        const kind = c.LLVMGetTypeKind(llvm_ty);
        const is_struct = kind == c.LLVMStructTypeKind;
        const n: c_uint = @intCast(agg.len);
        const vals = self.alloc.alloc(c.LLVMValueRef, agg.len) catch return c.LLVMConstNull(llvm_ty);
        defer self.alloc.free(vals);
        for (agg, 0..) |cv, i| {
            const elem_ty = if (is_struct)
                c.LLVMStructGetTypeAtIndex(llvm_ty, @intCast(i))
            else
                c.LLVMGetElementType(llvm_ty);
            vals[i] = switch (cv) {
                .int => |v| c.LLVMConstInt(elem_ty, @bitCast(v), 1),
                .float => |v| c.LLVMConstReal(elem_ty, v),
                .boolean => |v| c.LLVMConstInt(elem_ty, @intFromBool(v), 0),
                .string => |sid| self.emitConstStringGlobal(self.ir_mod.types.getString(sid)),
                .aggregate => |inner| self.emitConstAggregate(inner, elem_ty, require_resolved),
                .func_ref => |fid| self.func_map.get(fid.index()) orelse blk: {
                    if (require_resolved) {
                        std.debug.print(
                            "error: static initializer references function '{s}' which has no declaration\n",
                            .{self.ir_mod.types.getString(self.ir_mod.getFunction(fid).name)},
                        );
                        break :blk self.failGlobalInit(elem_ty);
                    }
                    // Pass 0 placeholder: func_map is empty until Pass 1, so the
                    // whole aggregate is re-emitted with require_resolved=true.
                    break :blk c.LLVMConstNull(elem_ty);
                },
                .global_ref => |gid| self.global_map.get(gid.index()) orelse c.LLVMConstNull(elem_ty),
                // A null pointer field and a zero-initialized field both emit as
                // the all-zero constant of the leaf type.
                .null_val, .zeroinit => c.LLVMConstNull(elem_ty),
                .undef => c.LLVMGetUndef(elem_ty),
                // Vtable constants are only ever produced for top-level protocol
                // vtable globals (lower.zig), never as a nested aggregate leaf.
                .vtable => @panic("nested vtable constant in aggregate is unsupported — vtables are top-level globals only"),
            };
        }
        if (is_struct) {
            return c.LLVMConstNamedStruct(llvm_ty, vals.ptr, n);
        }
        const elem_ty = c.LLVMGetElementType(llvm_ty);
        return c.LLVMConstArray(elem_ty, vals.ptr, n);
    }

    pub fn emitStringConstant(self: *LLVMEmitter, str: []const u8) c.LLVMValueRef {
        // LLVMBuildGlobalStringPtr needs a null-terminated C string
        const str_z = self.alloc.dupeZ(u8, str) catch unreachable;
        defer self.alloc.free(str_z);

        // Create a global constant string and return a fat pointer { ptr, len }
        const str_global = c.LLVMBuildGlobalStringPtr(self.builder, str_z.ptr, "str");
        const len_val = c.LLVMConstInt(self.cached_i64, str.len, 0);
        const str_ty = self.getStringStructType();
        const undef = c.LLVMGetUndef(str_ty);
        const with_ptr = c.LLVMBuildInsertValue(self.builder, undef, str_global, 0, "str.ptr");
        return c.LLVMBuildInsertValue(self.builder, with_ptr, len_val, 1, "str.len");
    }

    /// Emit a NUL-terminated C string as a private LLVM global and return
    /// the pointer to its first byte. Used for FindClass(env, "<path>") etc.
    /// where the runtime expects raw `const char *`, not the sx slice shape.
    pub fn emitCStringGlobal(self: *LLVMEmitter, str: []const u8, name: [*:0]const u8) c.LLVMValueRef {
        const z = self.alloc.dupeZ(u8, str) catch unreachable;
        defer self.alloc.free(z);
        return c.LLVMBuildGlobalStringPtr(self.builder, z.ptr, name);
    }

    /// Expand a JNI constructor dispatch (`Foo.new(args)` in sx). Chain:
    /// `FindClass(env, parent_class_path)` → `GetMethodID(env, clazz,
    /// "<init>", sig)` → `NewObject(env, clazz, mid, args...)`. Returns
    /// the new jobject. Per-call lookups — no caching yet.
    pub fn emitJniConstructor(self: *LLVMEmitter, msg: ir_inst.JniMsgSend, ret_ty_id: TypeId) void {
        const env = self.resolveRef(msg.env);
        const sig_ptr = self.extractSlicePtr(self.resolveRef(msg.sig));
        const name_ptr = self.extractSlicePtr(self.resolveRef(msg.name));

        const ifs = c.LLVMBuildLoad2(self.builder, self.cached_ptr, env, "jni.ifs");

        const path = msg.parent_class_path orelse "";
        const path_global = self.emitCStringGlobal(path, "jni.ctor.path");
        const find_class = self.loadJniFn(ifs, Jni.FindClass, "jni.FindClass");
        var fc_params = [_]c.LLVMTypeRef{ self.cached_ptr, self.cached_ptr };
        const fc_ty = c.LLVMFunctionType(self.cached_ptr, &fc_params, 2, 0);
        var fc_args = [_]c.LLVMValueRef{ env, path_global };
        const cls = c.LLVMBuildCall2(self.builder, fc_ty, find_class, &fc_args, 2, "jni.ctor.cls");

        const get_mid = self.loadJniFn(ifs, Jni.GetMethodID, "jni.GetMethodID");
        var gmid_params = [_]c.LLVMTypeRef{ self.cached_ptr, self.cached_ptr, self.cached_ptr, self.cached_ptr };
        const gmid_ty = c.LLVMFunctionType(self.cached_ptr, &gmid_params, 4, 0);
        var gmid_args = [_]c.LLVMValueRef{ env, cls, name_ptr, sig_ptr };
        const mid = c.LLVMBuildCall2(self.builder, gmid_ty, get_mid, &gmid_args, 4, "jni.ctor.mid");

        const new_object = self.loadJniFn(ifs, Jni.NewObject, "jni.NewObject");
        const raw_ret = self.toLLVMType(ret_ty_id);
        const total_call_params: usize = 3 + msg.args.len;
        const call_param_types = self.alloc.alloc(c.LLVMTypeRef, total_call_params) catch unreachable;
        defer self.alloc.free(call_param_types);
        const call_args = self.alloc.alloc(c.LLVMValueRef, total_call_params) catch unreachable;
        defer self.alloc.free(call_args);
        call_param_types[0] = self.cached_ptr;
        call_param_types[1] = self.cached_ptr;
        call_param_types[2] = self.cached_ptr;
        call_args[0] = env;
        call_args[1] = cls;
        call_args[2] = mid;
        for (msg.args, 0..) |arg_ref, i| {
            const raw_ty = self.argIRTypeOrFail(arg_ref);
            const raw_llvm = self.toLLVMType(raw_ty);
            const coerced_ty = self.abiCoerceParamType(raw_ty, raw_llvm);
            call_param_types[i + 3] = coerced_ty;
            call_args[i + 3] = self.coerceArg(self.resolveRef(arg_ref), coerced_ty);
        }
        const call_fn_ty = c.LLVMFunctionType(raw_ret, call_param_types.ptr, @intCast(total_call_params), 0);
        const result = c.LLVMBuildCall2(self.builder, call_fn_ty, new_object, call_args.ptr, @intCast(total_call_params), "jni.new.obj");
        self.mapRef(result);
    }

    /// Failable main entry-point wrapper (ERR E4.2). At the LLVM level main
    /// returns i32. `tag_val` is the u32 error tag (0 = "no error"); `value` is
    /// the integer value slot for a value-carrying `-> (int, !)` main, or null
    /// for a pure `-> !` main. Emit the branch: tag == 0 → `ret i32 <value-or-0>`
    /// (success — exit code truncated to u8 downstream); else resolve the tag
    /// name from the always-linked tag-name table, hand it + the tag to
    /// `sx_trace_report_unhandled` (prints the header + return trace to stderr),
    /// and `ret i32 1`.
    pub fn emitFailableMainRet(self: *LLVMEmitter, value: ?c.LLVMValueRef, tag_val: c.LLVMValueRef) void {
        const llvm_func = c.LLVMGetBasicBlockParent(c.LLVMGetInsertBlock(self.builder));
        const tag_i32 = self.coerceArg(tag_val, self.cached_i32);

        const is_err = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, tag_i32, c.LLVMConstInt(self.cached_i32, 0, 0), "main.iserr");
        const ok_bb = c.LLVMAppendBasicBlockInContext(self.context, llvm_func, "main.ok");
        const err_bb = c.LLVMAppendBasicBlockInContext(self.context, llvm_func, "main.err");
        _ = c.LLVMBuildCondBr(self.builder, is_err, err_bb, ok_bb);

        // Success: exit the value (truncated to u8 by the JIT/OS) or 0.
        c.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
        const ok_ret = if (value) |v| self.coerceArg(v, self.cached_i32) else c.LLVMConstInt(self.cached_i32, 0, 0);
        _ = c.LLVMBuildRet(self.builder, ok_ret);

        // Error: resolve the tag name, report to stderr, exit 1.
        c.LLVMPositionBuilderAtEnd(self.builder, err_bb);
        const global = self.reflection().getOrBuildTagNameArray();
        const idx = c.LLVMBuildZExt(self.builder, tag_i32, self.cached_i64, "main.tagidx");
        const string_ty = self.getStringStructType();
        const n: u32 = @intCast(self.ir_mod.types.tags.names.items.len);
        const array_ty = c.LLVMArrayType(string_ty, n);
        const zero = c.LLVMConstInt(self.cached_i64, 0, 0);
        var indices = [2]c.LLVMValueRef{ zero, idx };
        const gep = c.LLVMBuildInBoundsGEP2(self.builder, array_ty, global, &indices, 2, "main.tag.gep");
        const name_struct = c.LLVMBuildLoad2(self.builder, string_ty, gep, "main.tag.name");
        const name_ptr = c.LLVMBuildExtractValue(self.builder, name_struct, 0, "main.tag.ptr");
        const name_len = c.LLVMBuildExtractValue(self.builder, name_struct, 1, "main.tag.len");

        const reporter, const reporter_ty = self.lazyDeclareCRuntime(
            "sx_trace_report_unhandled",
            &[_]c.LLVMTypeRef{ self.cached_i32, self.cached_ptr, self.cached_i64 },
            self.cached_void,
            0,
        );
        var args = [3]c.LLVMValueRef{ tag_i32, name_ptr, name_len };
        _ = c.LLVMBuildCall2(self.builder, reporter_ty, reporter, &args, 3, "");
        _ = c.LLVMBuildRet(self.builder, c.LLVMConstInt(self.cached_i32, 1, 0));
    }

    /// Emit field_value_get: switch on the runtime index; each case yields an
    /// `any` VIEW `{field type tag, interior pointer}` into the receiver's
    /// storage — no copy of the field. The base operand is the receiver's
    /// ADDRESS (lowering borrows an lvalue receiver or spills an rvalue), so
    /// a view into borrowed storage aliases the source: mutations of the
    /// struct stay visible through a live view.
    pub fn emitFieldValueGet(self: *LLVMEmitter, fr: ir_inst.FieldReflect, func_idx: u32) void {
        const base_addr = self.resolveRef(fr.base);
        const idx_val = self.resolveRef(fr.index);

        const info = self.ir_mod.types.get(fr.struct_type);
        const fields = switch (info) {
            .@"struct" => |s| s.fields,
            .@"union" => |u| u.fields,
            .tagged_union => |u| u.fields,
            else => &[_]TypeInfo.StructInfo.Field{},
        };

        const any_ty = self.getAnyStructType();
        if (fields.len == 0) {
            // No fields (e.g., plain enum) — return a void-tagged any with a
            // null view (nothing to point at).
            const void_tag = c.LLVMConstInt(self.cached_i64, TypeId.void.index(), 0);
            var void_any = c.LLVMGetUndef(any_ty);
            void_any = c.LLVMBuildInsertValue(self.builder, void_any, c.LLVMConstInt(self.cached_i64, 0, 0), 0, "fv.vval");
            void_any = c.LLVMBuildInsertValue(self.builder, void_any, void_tag, 1, "fv.vtag");
            self.mapRef(void_any);
            return;
        }

        const current_func = self.func_map.get(func_idx) orelse {
            self.mapRef(c.LLVMGetUndef(any_ty));
            return;
        };
        if (c.LLVMGetTypeKind(c.LLVMTypeOf(base_addr)) != c.LLVMPointerTypeKind) {
            @panic("emitFieldValueGet: base is not an address — field_value_get takes the receiver's ADDRESS (route the site through the borrow-or-spill lowering)");
        }

        const merge_bb = c.LLVMAppendBasicBlockInContext(self.context, current_func, "fv.merge");
        const default_bb = c.LLVMAppendBasicBlockInContext(self.context, current_func, "fv.default");
        const switch_inst = c.LLVMBuildSwitch(self.builder, idx_val, default_bb, @intCast(fields.len));

        var case_blocks = std.ArrayList(c.LLVMBasicBlockRef).empty;
        defer case_blocks.deinit(self.alloc);
        var case_values = std.ArrayList(c.LLVMValueRef).empty;
        defer case_values.deinit(self.alloc);

        const base_llvm_ty = self.toLLVMType(fr.struct_type);
        const is_tagged = info == .tagged_union;
        const is_union = info == .@"union" or is_tagged;
        for (fields, 0..) |field, i| {
            const case_bb = c.LLVMAppendBasicBlockInContext(self.context, current_func, "fv.case");
            c.LLVMAddCase(switch_inst, c.LLVMConstInt(self.cached_i64, @intCast(i), 0), case_bb);

            c.LLVMPositionBuilderAtEnd(self.builder, case_bb);
            const tag_val = self.anyTag(field.ty);
            var any_val = c.LLVMGetUndef(any_ty);
            if (field.ty == .void) {
                // Void variant/field has no storage — {void, null}.
                any_val = c.LLVMBuildInsertValue(self.builder, any_val, c.LLVMConstInt(self.cached_i64, 0, 0), 0, "fv.val");
                any_val = c.LLVMBuildInsertValue(self.builder, any_val, c.LLVMConstInt(self.cached_i64, TypeId.void.index(), 0), 1, "fv.tag");
            } else {
                var field_ptr: c.LLVMValueRef = undefined;
                if (is_union) {
                    // Tagged union: the payload area is struct field 1 of
                    // `{tag, [N x i8]}`. Untagged union (`[N x i8]` blob):
                    // every arm overlays at offset 0 — the base IS the view.
                    field_ptr = if (is_tagged)
                        c.LLVMBuildStructGEP2(self.builder, base_llvm_ty, base_addr, 1, "fv.pp")
                    else
                        base_addr;
                } else {
                    field_ptr = c.LLVMBuildStructGEP2(self.builder, base_llvm_ty, base_addr, @intCast(i), "fv.fp");
                }
                if (tag_val != field.ty.index()) {
                    // Arbitrary-width int field: the tag normalizes to the
                    // nearest builtin width, so a direct view would overread.
                    // Copy-extend into a temp of the tag's width and view that
                    // instead (aliasing is lost for these fields only —
                    // `data` must always cover size_of(tag) valid bytes).
                    const field_llvm_ty = self.toLLVMType(field.ty);
                    const norm_ty = TypeId.fromIndex(@intCast(tag_val));
                    const norm_llvm_ty = self.toLLVMType(norm_ty);
                    const loaded = c.LLVMBuildLoad2(self.builder, field_llvm_ty, field_ptr, "fv.narrow");
                    const extended = if (self.isSignedTypeEx(field.ty))
                        c.LLVMBuildSExt(self.builder, loaded, norm_llvm_ty, "fv.sext")
                    else
                        c.LLVMBuildZExt(self.builder, loaded, norm_llvm_ty, "fv.zext");
                    const tmp = self.buildEntryAlloca(norm_llvm_ty, "fv.tmp");
                    _ = c.LLVMBuildStore(self.builder, extended, tmp);
                    field_ptr = tmp;
                }
                const tag = c.LLVMConstInt(self.cached_i64, tag_val, 0);
                const data = c.LLVMBuildPtrToInt(self.builder, field_ptr, self.cached_i64, "fv.data");
                any_val = c.LLVMBuildInsertValue(self.builder, any_val, data, 0, "fv.val");
                any_val = c.LLVMBuildInsertValue(self.builder, any_val, tag, 1, "fv.tag");
            }
            _ = c.LLVMBuildBr(self.builder, merge_bb);

            case_blocks.append(self.alloc, case_bb) catch unreachable;
            case_values.append(self.alloc, any_val) catch unreachable;
        }

        // Default block: return undef Any
        c.LLVMPositionBuilderAtEnd(self.builder, default_bb);
        _ = c.LLVMBuildBr(self.builder, merge_bb);

        // Merge block: PHI
        c.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        const phi = c.LLVMBuildPhi(self.builder, any_ty, "fv.phi");
        for (case_blocks.items, case_values.items) |bb, val| {
            c.LLVMAddIncoming(phi, @constCast(&val), @constCast(&bb), 1);
        }
        const undef_any = c.LLVMGetUndef(any_ty);
        c.LLVMAddIncoming(phi, @constCast(&undef_any), @constCast(&default_bb), 1);

        self.mapRef(phi);
    }

    // ── Helpers ─────────────────────────────────────────────────────

    fn makeBlockKey(func_idx: u32, block_idx: u32) u64 {
        return (@as(u64, func_idx) << 32) | @as(u64, block_idx);
    }

    /// Dump the LLVM module to a string (for testing).
    pub fn dumpToString(self: *LLVMEmitter) []const u8 {
        const raw = c.LLVMPrintModuleToString(self.llvm_module);
        return std.mem.span(raw);
    }

    /// Verify the LLVM module. Returns true if valid.
    pub fn verify(self: *LLVMEmitter) bool {
        return c.LLVMVerifyModule(self.llvm_module, c.LLVMReturnStatusAction, null) == 0;
    }

    /// Verify the LLVM module, returning an error message on failure.
    pub fn verifyWithMessage(self: *LLVMEmitter) !void {
        var err_msg: [*c]u8 = null;
        if (c.LLVMVerifyModule(self.llvm_module, c.LLVMReturnStatusAction, &err_msg) != 0) {
            if (err_msg != null) {
                const msg = std.mem.span(err_msg);
                // Dump IR to /tmp for debugging
                _ = c.LLVMPrintModuleToFile(self.llvm_module, "/tmp/sx_debug.ll", null);
                std.debug.print("LLVM verification failed: {s}\n", .{msg});
                c.LLVMDisposeMessage(err_msg);
            }
            return error.VerificationFailed;
        }
    }

    /// Run LLVM's standard middle-end pipeline for the requested optimization
    /// level. O0 deliberately skips PassBuilder so debug builds retain the IR
    /// shape emitted by sx; target-machine codegen still receives its matching
    /// LLVMCodeGenOptLevel in `init` for every level.
    pub fn optimize(self: *LLVMEmitter) !void {
        const pipeline = self.target_config.opt_level.toLLVMPassPipeline() orelse return;
        const tm = self.target_machine orelse return error.NoTargetMachine;
        const options = c.LLVMCreatePassBuilderOptions();
        defer c.LLVMDisposePassBuilderOptions(options);

        const err = c.LLVMRunPasses(self.llvm_module, pipeline.ptr, tm, options);
        if (err != null) {
            const msg = c.LLVMGetErrorMessage(err);
            defer c.LLVMDisposeErrorMessage(msg);
            std.debug.print("LLVM optimization failed for {s}: {s}\n", .{ pipeline, std.mem.span(msg) });
            return error.OptimizationFailed;
        }
    }

    /// Print the LLVM IR to stderr.
    pub fn printIR(self: *LLVMEmitter) void {
        const ir_str = c.LLVMPrintModuleToString(self.llvm_module);
        defer c.LLVMDisposeMessage(ir_str);
        const len = std.mem.len(ir_str);
        // Write to fd 1 (stdout), not std.debug.print (stderr): `sx ir` is a
        // data-emitting command meant to be piped/redirected, so the IR text
        // belongs on stdout. Mirrors core.flushInterpOutput's raw-write route.
        _ = std.c.write(1, ir_str, len);
        _ = std.c.write(1, "\n", 1);
    }

    /// Emit the module as an object file to disk.
    pub fn emitObject(self: *LLVMEmitter, output_path: [*:0]const u8) !void {
        return self.emitToFile(output_path, c.LLVMObjectFile);
    }

    /// Emit the module as an assembly file to disk.
    pub fn emitAssembly(self: *LLVMEmitter, output_path: [*:0]const u8) !void {
        return self.emitToFile(output_path, c.LLVMAssemblyFile);
    }

    /// Emit the module as LLVM bitcode to disk (for emcc to recompile with a newer LLVM).
    pub fn emitBitcode(self: *LLVMEmitter, output_path: [*:0]const u8) !void {
        if (c.LLVMWriteBitcodeToFile(self.llvm_module, output_path) != 0) {
            return error.EmitFailed;
        }
    }

    /// Dump the LLVM IR to a file for debugging.
    pub fn dumpIRToFile(self: *LLVMEmitter, path: [*:0]const u8) void {
        _ = c.LLVMPrintModuleToFile(self.llvm_module, path, null);
    }

    /// Emit the module as an object file to a memory buffer (for JIT).
    pub fn emitObjectToMemory(self: *LLVMEmitter) !c.LLVMMemoryBufferRef {
        const tm = self.target_machine orelse return error.NoTargetMachine;
        var err_msg: [*c]u8 = null;
        var buf: c.LLVMMemoryBufferRef = null;
        if (c.LLVMTargetMachineEmitToMemoryBuffer(tm, self.llvm_module, c.LLVMObjectFile, &err_msg, &buf) != 0) {
            if (err_msg != null) {
                std.debug.print("failed to emit object to memory: {s}\n", .{std.mem.span(err_msg)});
                c.LLVMDisposeMessage(err_msg);
            }
            return error.EmitFailed;
        }
        return buf;
    }

    fn emitToFile(self: *LLVMEmitter, output_path: [*:0]const u8, file_type: c.LLVMCodeGenFileType) !void {
        const tm = self.target_machine orelse return error.NoTargetMachine;
        var err_msg: [*c]u8 = null;
        if (c.LLVMTargetMachineEmitToFile(tm, self.llvm_module, output_path, file_type, &err_msg) != 0) {
            if (err_msg != null) {
                std.debug.print("failed to emit file: {s}\n", .{std.mem.span(err_msg)});
                c.LLVMDisposeMessage(err_msg);
            }
            return error.EmitFailed;
        }
    }
    /// Check if an IR Ref's type is an unsigned integer (u8, u16, u32, u64).
    fn isRefUnsigned(self: *LLVMEmitter, ref: Ref) bool {
        if (ref.isNone()) return false;
        const func = &self.ir_mod.functions.items[self.current_func_idx];
        const ref_idx = ref.index();
        // Check function parameters first (refs 0..N-1)
        if (ref_idx < func.params.len) {
            const ty = func.params[ref_idx].ty;
            return ty == .u8 or ty == .u16 or ty == .u32 or ty == .u64;
        }
        for (func.blocks.items) |*block| {
            const first = block.first_ref;
            if (ref_idx >= first and ref_idx < first + @as(u32, @intCast(block.insts.items.len))) {
                const ty = block.insts.items[ref_idx - first].ty;
                return ty == .u8 or ty == .u16 or ty == .u32 or ty == .u64;
            }
        }
        return false;
    }
};

// ── Type classification helpers ─────────────────────────────────────

fn isFloatType(ty: TypeId) bool {
    return ty == .f32 or ty == .f64;
}

/// Check if a TypeId is a float type, including float vectors.
pub fn isFloatOrVecFloat(ty: TypeId, types: *const TypeTable) bool {
    if (ty == .f32 or ty == .f64) return true;
    if (!ty.isBuiltin()) {
        const info = types.get(ty);
        if (info == .vector) return info.vector.element == .f32 or info.vector.element == .f64;
    }
    return false;
}

pub fn isSignedType(ty: TypeId) bool {
    return switch (ty) {
        .i8, .i16, .i32, .i64, .isize => true,
        else => false,
    };
}

fn floatBits(ty: TypeId) u32 {
    return switch (ty) {
        .f32 => 32,
        .f64 => 64,
        else => 0,
    };
}

fn intBits(ty: TypeId) u32 {
    return switch (ty) {
        .i8, .u8 => 8,
        .i16, .u16 => 16,
        .i32, .u32 => 32,
        .i64, .u64 => 64,
        .bool => 1,
        .usize, .isize => 0, // target-dependent — caller must query pointer_size
        else => 64,
    };
}

/// Table-aware int width: arbitrary-width int TypeIds (`.signed`/`.unsigned`
/// infos) answer their declared width; builtins go through `intBits`. Null
/// means target-pointer width (usize/isize).
fn intBitsEx(self: *LLVMEmitter, ty: TypeId) ?u32 {
    if (!ty.isBuiltin()) {
        switch (self.ir_mod.types.get(ty)) {
            .signed, .unsigned => |w| return w,
            else => {},
        }
    }
    const b = intBits(ty);
    return if (b == 0) null else b;
}
