const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const mod_mod = @import("../module.zig");
const type_bridge = @import("../type_bridge.zig");
const unescape = @import("../../unescape.zig");
const errors = @import("../../errors.zig");
const program_index_mod = @import("../program_index.zig");
const resolver_mod = @import("../resolver.zig");
const intrinsics = @import("../intrinsics.zig");
const ProgramIndex = program_index_mod.ProgramIndex;
const GlobalInfo = program_index_mod.GlobalInfo;
const ModuleConstInfo = program_index_mod.ModuleConstInfo;
const TypeResolver = @import("../type_resolver.zig").TypeResolver;
const CallResolver = @import("../calls.zig").CallResolver;
const ProtocolResolver = @import("../protocols.zig").ProtocolResolver;
const ErrorFlow = @import("../error_flow.zig").ErrorFlow;
const semantic_diagnostics = @import("../semantic_diagnostics.zig");

const TypeId = types.TypeId;
const StringId = types.StringId;
const Ref = inst_mod.Ref;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;
const Module = mod_mod.Module;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const Scope = lower.Scope;
const nameVisibleOverEdges = lower.nameVisibleOverEdges;
const SelectedConst = Lowering.SelectedConst;
const FnBodyReentry = Lowering.FnBodyReentry;
const hasComptimeParams = Lowering.hasComptimeParams;
const isPlainFreeFn = Lowering.isPlainFreeFn;
const topLevelTypeDecl = Lowering.topLevelTypeDecl;
const isFloat = Lowering.isFloat;
const isPackFn = Lowering.isPackFn;

/// Reject infinitely-sized types: a nominal aggregate (struct / enum-with-payload
/// / union) that contains ITSELF — or a mutual peer — BY VALUE has no finite
/// layout, and would otherwise infinite-recurse `typeSizeBytes` into a stack
/// overflow. Walk the by-VALUE containment graph (a pointer / slice / optional
/// payload is finite-size and breaks the cycle, so `*Self` recursion is fine);
/// on a back-edge, emit a loud diagnostic and POISON the offending field to
/// `.unresolved`, breaking the cycle so later sizing can't crash before the
/// build halts on the error. Covers both source decls and comptime-constructed
/// (`declare`/`define`) types.
pub fn checkInfiniteSize(self: *Lowering) void {
    const n = self.module.types.infos.items.len;
    if (n == 0) return;
    const color = self.alloc.alloc(u8, n) catch return; // 0=white 1=gray 2=black
    defer self.alloc.free(color);
    @memset(color, 0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (color[i] == 0) self.dfsByValueCycle(TypeId.fromIndex(@intCast(i)), color);
    }
}

pub fn dfsByValueCycle(self: *Lowering, tid: TypeId, color: []u8) void {
    const idx = tid.index();
    if (idx >= color.len) return;
    color[idx] = 1; // gray (on the current containment path)
    if (byValueAggregateFields(&self.module.types, tid)) |fields| {
        for (fields, 0..) |f, k| {
            if (!isByValueAggregate(&self.module.types, f.ty)) continue; // pointer/slice/etc. break the cycle
            const fidx = f.ty.index();
            if (fidx >= color.len) continue;
            if (color[fidx] == 1) {
                // Back-edge: `f.ty` is on the current path → infinitely sized.
                self.diagInfiniteSize(f.ty);
                self.poisonAggregateField(tid, k);
            } else if (color[fidx] == 0) {
                self.dfsByValueCycle(f.ty, color);
            }
        }
    }
    color[idx] = 2; // black (fully explored)
}

/// The by-value fields of a nominal aggregate, or null for any other type.
fn byValueAggregateFields(table: *const types.TypeTable, tid: TypeId) ?[]const types.TypeInfo.StructInfo.Field {
    if (tid.isBuiltin()) return null;
    return switch (table.get(tid)) {
        .@"struct" => |s| s.fields,
        .tagged_union => |u| u.fields,
        .@"union" => |u| u.fields,
        else => null,
    };
}

/// True iff a field of type `ty` contributes its FULL size by value (a nominal
/// aggregate), so a cycle through it is infinite. Pointers / slices / optionals /
/// functions are finite-size and break the cycle.
fn isByValueAggregate(table: *const types.TypeTable, ty: TypeId) bool {
    if (ty.isBuiltin()) return false;
    return switch (table.get(ty)) {
        .@"struct", .tagged_union, .@"union" => true,
        else => false,
    };
}

/// Break a by-value cycle: replace field `k` of nominal `tid` with `.unresolved`.
/// The name + nominal id are untouched, so the intern key is stable
/// (`updatePreservingKey`). The diagnostic is the user-facing signal; this just
/// stops `typeSizeBytes` recursing before the build halts on the error.
pub fn poisonAggregateField(self: *Lowering, tid: TypeId, k: usize) void {
    const table = &self.module.types;
    const info = table.get(tid);
    var new_info = info;
    const src_fields = switch (info) {
        .@"struct" => |s| s.fields,
        .tagged_union => |u| u.fields,
        .@"union" => |u| u.fields,
        else => return,
    };
    const nf = self.alloc.dupe(types.TypeInfo.StructInfo.Field, src_fields) catch return;
    if (k >= nf.len) return;
    nf[k].ty = .unresolved;
    switch (new_info) {
        .@"struct" => |*s| s.fields = nf,
        .tagged_union => |*u| u.fields = nf,
        .@"union" => |*u| u.fields = nf,
        else => return,
    }
    table.updatePreservingKey(tid, new_info);
}

pub fn diagInfiniteSize(self: *Lowering, ty: TypeId) void {
    if (self.diagnostics) |d| {
        const nm = self.module.types.typeName(ty);
        d.addFmt(.err, null, "type '{s}' is infinitely sized (it contains itself by value); use a pointer ('*{s}') to break the cycle", .{ nm, nm });
    }
}

/// Names that must keep external LLVM linkage because the OS loader (not
/// sx code) is the caller. Without this they'd default to internal and
/// either DCE away or stay hidden from the dynamic symbol table.
/// Anything starting with `Java_` is a JNI native method that Android's
/// runtime resolves by name mangling — same rule.
/// True when `fd` declares a `-> Type` return — the signal that a non-generic
/// call to it (`E :: f(...)`) should be comptime-evaluated to mint a type.
/// Matches a bare `Type` type-expr return only.
fn fnReturnsTypeValue(fd: *const ast.FnDecl) bool {
    const rt = fd.return_type orelse return false;
    return rt.data == .type_expr and std.mem.eql(u8, rt.data.type_expr.name, "Type");
}

/// True when `tid` transitively carries the `.unresolved` sentinel through any
/// COMPOSITE shape — tuple fields, array/slice/vector/many-pointer elements,
/// optional child, pointer pointee, function/closure params + return. A tuple
/// ALIAS must never register such a type: the sentinel would reach LLVM
/// emission and panic the tripwire (issue 0196 review MED-3 —
/// `Tuple(a: [2][zz]i64)` hid the sentinel one composite deep and a
/// tuple-only recursion waved it through). Nominal aggregates
/// (struct/union/enum) are terminal: their fields are validated at their own
/// registration, and not recursing through them keeps self-referential shapes
/// (`next: *Node` cycles) from looping this walk.
fn typeCarriesUnresolved(table: *const types.TypeTable, tid: TypeId) bool {
    if (tid == .unresolved) return true;
    if (tid.isBuiltin()) return false;
    return switch (table.get(tid)) {
        .tuple => |t| blk: {
            for (t.fields) |f| if (typeCarriesUnresolved(table, f)) break :blk true;
            break :blk false;
        },
        .array => |a| typeCarriesUnresolved(table, a.element),
        .slice => |s| typeCarriesUnresolved(table, s.element),
        .vector => |v| typeCarriesUnresolved(table, v.element),
        .many_pointer => |m| typeCarriesUnresolved(table, m.element),
        .pointer => |p| typeCarriesUnresolved(table, p.pointee),
        .optional => |o| typeCarriesUnresolved(table, o.child),
        .function => |f| blk: {
            for (f.params) |p| if (typeCarriesUnresolved(table, p)) break :blk true;
            break :blk typeCarriesUnresolved(table, f.ret);
        },
        .closure => |c| blk: {
            for (c.params) |p| if (typeCarriesUnresolved(table, p)) break :blk true;
            break :blk typeCarriesUnresolved(table, c.ret);
        },
        else => false,
    };
}

fn isExportedEntryName(name: []const u8) bool {
    return std.mem.eql(u8, name, "main") or
        std.mem.eql(u8, name, "JNI_OnLoad") or
        std.mem.startsWith(u8, name, "Java_");
}

/// The well-known stdlib build driver (`library/modules/build.sx`). It is invoked
/// by the compiler post-codegen when no `#run on_build(...)` override exists, but
/// is never CALLED from sx — so it must be force-lowered like an OS entry point,
/// else lazy lowering leaves it a bodiless `declare` stub the VM can't run.
fn isDefaultBuildPipeline(name: []const u8) bool {
    return std.mem.eql(u8, name, "default_pipeline");
}

/// Lower all top-level declarations from a root node.
/// Pass 1: Scan all declarations (register ASTs, types, extern stubs).
/// Pass 2: Lower only `main` (everything else is lowered lazily on demand).
pub fn lowerRoot(self: *Lowering, root: *const Node) void {
    const decls = switch (root.data) {
        .root => |r| r.decls,
        else => return,
    };
    // Pass 0: pre-scan for `Context :: struct {...}`. If the program
    // imports `std.sx` it has Context, and every default-conv sx
    // function gets the implicit `__sx_ctx` param. Otherwise the
    // implicit-ctx machinery stays fully disabled — programs that
    // call only libc directly keep their bare C ABI.
    self.implicit_ctx_enabled = detectContextDecl(decls);
    self.module.has_implicit_ctx = self.implicit_ctx_enabled;
    // Pass 0a: collect every `#context_extend` declaration program-wide into
    // ProgramIndex (L6 order, L4/L5 validation). Runs UNCONDITIONALLY — in a
    // no-context build the declarations are inert (O3) but the collected list
    // still powers the registered-field diagnostic.
    self.collectContextExtensions(decls);
    // Pass 1: scan — register all function ASTs, struct types, extern stubs
    self.scanDecls(decls);
    // Pass 1a': assemble the program Context — append the collected
    // `#context_extend` fields to the registered Context struct. Must run
    // after `scanDecls` (every named type an extension can reference is
    // registered) and before `emitDefaultContextGlobal` / any body lowering
    // (both consume the assembled layout via findByName("Context")).
    self.assembleContext();
    // A Context STRUCTURAL error (L4 collision / L5 missing default /
    // unresolvable field type) poisons every downstream `context.field`
    // access — halt here so the primary diagnostics stand alone instead of
    // cascading a field-not-found per use site. `core.zig` gates on
    // `hasErrors()` right after `lowerRoot` either way.
    if (self.context_structural_error) return;
    // Pass 1b: inject compile-time constants (OS, ARCH, POINTER_SIZE) from target config
    self.injectComptimeConstants();
    // Pass 1c: emit the process-wide default Context global, statically
    // initialised to a CAllocator-backed Allocator value. Used by FFI
    // wrappers in Step 4 and by the interp's `callWithDefaultContext`
    // entry. Only fires when the program imports `std.sx` (so Context +
    // Allocator + CAllocator are all registered).
    self.emitDefaultContextGlobal();
    // Pass 1d: converge inferred (`bare !`) error sets across the whole
    // program (ERR E1.4b). Runs before body lowering so `lowerTry`'s
    // named-caller widening sees each bare-`!` callee's converged set; also
    // emits the empty-inferred warning.
    self.convergeInferredErrorSets();
    // Pass 1d': converge inferred (`bare !`) error sets per closure/fn-type
    // SHAPE (ERR E5.1 sub-feature 2). Runs after the name-keyed pass so a
    // closure's `try named_fn()` edge resolves against the converged
    // top-level sets; before body lowering so `try slot(x)` widening sees
    // the full per-shape union.
    self.convergeClosureShapeSets();
    // Pass 1e: error-flow checks (ERR E1.8 value-slot liveness + E1.7
    // cleanup-body absorption) over the main file's functions. Runs after
    // the error-set convergence passes (so failable callees resolve) and
    // before body lowering — purely a diagnostic pass; `core.zig` halts on
    // any error before codegen.
    self.errorFlow().checkErrorFlow(decls);
    // Pass 1f: reject identifiers used in a type position that name no
    // declared type / primitive / in-scope generic param.
    // Runs after scanning (so every real type name is registered) and
    // before body lowering, so the diagnostic halts via `core.zig`
    // `hasErrors()` before the empty-struct stub can reach codegen. Owned by
    // `semantic_diagnostics.UnknownTypeChecker` (A2.4); built only when
    // diagnostics are active, querying ProgramIndex + TypeResolver.
    if (self.diagnostics) |diags| {
        const checker = semantic_diagnostics.UnknownTypeChecker{
            .alloc = self.alloc,
            .diagnostics = diags,
            .types = &self.module.types,
            .index = &self.program_index,
            .main_file = self.main_file,
            .lowering = self,
        };
        checker.run(decls);
    }
    // Pass 1g: reject infinitely-sized types — a nominal aggregate that contains
    // ITSELF (or a mutual peer) BY VALUE has no finite layout and would otherwise
    // infinite-loop `typeSizeBytes` into a stack overflow during body lowering.
    // Runs after every type is registered (source AND comptime-constructed) and
    // before body lowering, which is the first consumer of type sizes.
    self.checkInfiniteSize();
    // Pass 2: lower main (and comptime side-effects)
    self.lowerMainAndComptime(decls);
    // Pass 2b: force-lower the stdlib build driver `default_pipeline` (in the
    // flat-imported `modules/build.sx`, so NOT in the main `decls` above). The
    // compiler auto-invokes it post-codegen when no `#run on_build(...)` override
    // exists, but nothing CALLS it from sx — so without this it stays a bodiless
    // stub the build VM can't run. No-ops when build.sx isn't imported.
    self.lazyLowerFunction("default_pipeline");
    // Pass 3: lower deferred functions (any_to_string etc.) now that all types are registered
    self.lowerDeferredTypeFns();
    // Pass 4: target-specific entry-point sanity checks
    self.checkRequiredEntryPoints();
    // Pass 4a: validate main's signature (ERR E4.2 entry-point gate).
    self.validateMainSignature();
    // Pass 4b: eagerly lower bodied methods on sx-defined `#objc_class`
    // declarations. The Obj-C runtime calls these via IMP pointers
    // registered in M1.2 A.4 — no sx-side call path drives lazy
    // lowering, so we trigger it here. Mirrors the JNI eager-lower
    // pattern in Pass 5.
    self.lowerObjcDefinedClassMethods();
    // Pass 5: synthesize JNI-mangled exports for `#jni_main` bodied methods.
    // Android's JNI runtime resolves `private native sx_<m>(...)` declared in
    // the bundled classes.dex by looking up the symbol
    // `Java_<pkg-mangled>_<Class>_sx_1<m-mangled>` in the loaded .so. Each
    // bodied method on a `#jni_main #jni_class` decl becomes an exported
    // C-ABI fn with that name; the JNIEnv* / jobject params are prepended,
    // then the user-declared params (with type-erased pointers since JNI
    // doesn't carry sx-side types across the binding).
    self.synthesizeJniMainStubs();
    // CP coverage lock: every generic instance carries both a template and an
    // author stamp (body-author ≡ layout-author by construction).
    self.assertInstanceMapsCoincide();
}

/// ERR E4.2: the entry-point signature gate. `main` must take no parameters
/// and have a SINGLE-slot return: void (`()` / `-> ()` / `-> void`), an
/// integer (POSIX exit code, truncated to u8), or `-> !` / `-> !Named` (the
/// error tag rides the single return register). The multi-slot
/// `-> (T, !)` tuple return is NOT yet supported — the JIT calls main as
/// `() -> i32`, so a 2-slot `{value, error}` return ABI-mismatches and
/// segfaults; that shape lands with the E4.2 entry-point wrapper. Any other
/// shape (`-> string`, `-> f64`, a non-failable tuple, …) is a clean
/// diagnostic rather than a silent miscompile.
pub fn validateMainSignature(self: *Lowering) void {
    const fd = self.program_index.fn_ast_map.get("main") orelse return;

    if (fd.params.len != 0) {
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, fd.params[0].name_span, "main: parameters must be empty; return type must be void, an integer, or `!`", .{});
        }
        return;
    }

    const rt = self.resolveReturnType(fd);
    // Single-slot returns the JIT's `() -> i32` ABI handles directly:
    //   void / integer, and a pure failable `-> !` (a bare u32 error tag).
    if (rt == .void or self.isIntEx(rt)) return;
    if (self.errorChannelOf(rt)) |chan| {
        if (rt == chan) {
            // pure `-> !` / `-> !Named`. The emitted entry-point wrapper
            // (emit_llvm `emitFailableMainRet`) calls `sx_trace_report_unhandled`
            // on an escaping error, so the AOT path must auto-link the trace
            // runtime even when the body emits no other push/clear.
            self.needs_trace_runtime = true;
            return;
        }
        // `-> (T, !)` — value-carrying failable. Accepted only for a single
        // **integer** value slot (`{int, error_set}`): the wrapper extracts
        // the value + tag from the returned tuple, exits `value as u8` on
        // success / reports + exits 1 on error. Multi-value `-> (T1, T2, !)`
        // or a non-integer value slot stays rejected — there's no single
        // integer exit code to map it to.
        const ti = self.module.types.get(rt);
        if (ti == .tuple and ti.tuple.fields.len == 2 and self.isIntEx(ti.tuple.fields[0])) {
            self.needs_trace_runtime = true;
            return;
        }
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, if (fd.return_type) |rtn| rtn.span else null, "a value-carrying failable `main` must be `-> (int, !)` (one integer value slot); got '{s}'. Use `-> !` (no value), `-> (int, !)`, or a non-failable integer return", .{self.formatTypeName(rt)});
        }
        return;
    }

    if (self.diagnostics) |diags| {
        diags.addFmt(.err, if (fd.return_type) |rtn| rtn.span else null, "main: return type must be void, an integer, or `!`; got '{s}'", .{self.formatTypeName(rt)});
    }
}

// ERR E1.7 / E1.8 — path-sensitive error-flow diagnostics (Pass 1e) live in
// `error_flow.zig` (`ErrorFlow`, a `*Lowering` facade). `lowerRoot` calls
// `self.errorFlow().checkErrorFlow(decls)`.

/// On Android, the OS loads the .so via a Java-side Activity declared
/// with `#jni_main #jni_class("...")`. The Java class drives the
/// lifecycle (onCreate / onPause / etc.) and sx provides the native
/// delegates bound via JNI name mangling. Without a `#jni_main` decl
/// there's no entry point — the .so would load but Android has nothing
/// to call into.
pub fn checkRequiredEntryPoints(self: *Lowering) void {
    const tc = self.target_config orelse return;
    if (!tc.isAndroid()) return;

    var it = self.program_index.runtime_class_map.iterator();
    while (it.next()) |entry| {
        const fcd = entry.value_ptr.*;
        if (fcd.is_main and !fcd.is_extern and fcd.runtime == .jni_class) return;
    }

    if (self.diagnostics) |diags| {
        diags.addFmt(.err, null, "target is Android but no `#jni_main` Activity declared. " ++
            "The OS launches a Java-side Activity that delegates lifecycle " ++
            "callbacks into sx — declare one like:\n\n" ++
            "    Bundle :: #jni_class(\"android/os/Bundle\") extern {{ }}\n\n" ++
            "    MyApp :: #jni_main #jni_class(\"co/example/MyApp\") {{\n" ++
            "        onCreate :: (self: *Self, b: *Bundle) {{ /* ... */ }}\n" ++
            "    }}", .{});
    }
}

/// Inject compile-time constants from target_config into comptime_constants.
/// Called after scanDecls so that enum types (OperatingSystem, Architecture) are registered.
pub fn injectComptimeConstants(self: *Lowering) void {
    const tc = self.target_config orelse return;

    // OS: OperatingSystem enum { macos; linux; windows; wasm; unknown; }
    const os_name_id = self.module.types.internString("OperatingSystem");
    if (self.module.types.findByName(os_name_id)) |os_ty| {
        const os_info = self.module.types.get(os_ty);
        if (os_info == .@"enum") {
            const tag: u32 = if (tc.isWasm())
                self.findVariantIndex(os_info.@"enum".variants, "wasm")
            else if (tc.isWindows())
                self.findVariantIndex(os_info.@"enum".variants, "windows")
            else if (tc.isAndroid())
                self.findVariantIndex(os_info.@"enum".variants, "android")
            else if (tc.isLinux())
                self.findVariantIndex(os_info.@"enum".variants, "linux")
            else if (tc.isIOS())
                self.findVariantIndex(os_info.@"enum".variants, "ios")
            else if (tc.isMacOS())
                self.findVariantIndex(os_info.@"enum".variants, "macos")
            else
                self.findVariantIndex(os_info.@"enum".variants, "unknown");
            self.comptime_constants.put("OS", .{ .enum_tag = .{ .ty = os_ty, .tag = tag } }) catch {};
        }
    }

    // ARCH: Architecture enum { aarch64; x86_64; wasm32; wasm64; unknown; }
    const arch_name_id = self.module.types.internString("Architecture");
    if (self.module.types.findByName(arch_name_id)) |arch_ty| {
        const arch_info = self.module.types.get(arch_ty);
        if (arch_info == .@"enum") {
            const tag: u32 = if (tc.isWasm32())
                self.findVariantIndex(arch_info.@"enum".variants, "wasm32")
            else if (tc.isWasm64())
                self.findVariantIndex(arch_info.@"enum".variants, "wasm64")
            else if (tc.isAarch64())
                self.findVariantIndex(arch_info.@"enum".variants, "aarch64")
            else if (tc.isX86_64())
                self.findVariantIndex(arch_info.@"enum".variants, "x86_64")
            else
                self.findVariantIndex(arch_info.@"enum".variants, "unknown");
            self.comptime_constants.put("ARCH", .{ .enum_tag = .{ .ty = arch_ty, .tag = tag } }) catch {};
        }
    }

    // POINTER_SIZE: i64 (4 for wasm32, 8 for wasm64 and other 64-bit targets)
    const ptr_size: i64 = if (tc.isWasm32()) 4 else 8;
    self.comptime_constants.put("POINTER_SIZE", .{ .int_val = ptr_size }) catch {};
}

pub fn findVariantIndex(self: *Lowering, variants: []const types.StringId, name: []const u8) u32 {
    const name_id = self.module.types.internString(name);
    for (variants, 0..) |v, i| {
        if (v == name_id) return @intCast(i);
    }
    return 0; // fallback to first variant
}

/// Lower functions that were deferred because they use type-category matching.
/// At this point, main is fully lowered and all types are in the TypeTable.
pub fn lowerDeferredTypeFns(self: *Lowering) void {
    if (self.deferred_type_fns.items.len == 0) return;
    self.processing_deferred = true;
    for (self.deferred_type_fns.items) |name| {
        self.lazyLowerFunction(name);
    }
    self.processing_deferred = false;
}

/// Lower a list of top-level declarations (used by irComptimeEval — non-lazy path).
/// This preserves the old behavior for comptime evaluation contexts.
pub fn lowerDecls(self: *Lowering, decls: []const *const Node) void {
    for (decls) |decl| {
        self.setCurrentSourceFile(decl.source_file);
        const is_imported = if (self.main_file) |mf|
            (if (decl.source_file) |sf| !std.mem.eql(u8, sf, mf) else false)
        else
            false;
        switch (decl.data) {
            .fn_decl => |fd| {
                self.program_index.fn_ast_map.put(fd.name, &decl.data.fn_decl) catch {};
                self.lowerFunction(&fd, fd.name, is_imported);
            },
            .const_decl => |cd| {
                if (cd.value.data == .fn_decl) {
                    self.program_index.fn_ast_map.put(cd.name, &cd.value.data.fn_decl) catch {};
                    self.lowerFunction(&cd.value.data.fn_decl, cd.name, is_imported);
                } else if (cd.value.data == .struct_decl) {
                    self.registerStructDecl(&cd.value.data.struct_decl, decl.source_file);
                } else if (cd.value.data == .enum_decl) {
                    self.registerEnumDecl(&cd.value.data.enum_decl);
                } else if (cd.value.data == .union_decl) {
                    self.registerUnionDecl(&cd.value.data.union_decl);
                } else if (cd.value.data == .comptime_expr) {
                    self.lowerComptimeGlobal(cd.name, cd.value.data.comptime_expr.expr, cd.type_annotation);
                }
            },
            .comptime_expr => |ct| {
                self.lowerComptimeSideEffect(ct.expr);
            },
            .struct_decl => {
                self.registerStructDecl(&decl.data.struct_decl, decl.source_file);
            },
            .enum_decl => {
                self.registerEnumDecl(&decl.data.enum_decl);
            },
            .union_decl => {
                self.registerUnionDecl(&decl.data.union_decl);
            },
            .error_set_decl => {
                self.registerErrorSetDecl(decl);
            },
            .protocol_decl => {
                self.registerProtocolDecl(&decl.data.protocol_decl);
            },
            .impl_block => {
                self.protocolResolver().registerImplBlock(&decl.data.impl_block, is_imported, decl);
            },
            .runtime_class_decl => {
                self.registerRuntimeClassDecl(&decl.data.runtime_class_decl);
            },
            .namespace_decl => |ns| {
                self.registerNamespacedRuntimeClasses(ns);
                if (self.main_file != null) {
                    self.registerNamespaceQualifiedFns(ns.name, ns.own_decls);
                    self.lowerDecls(ns.decls);
                }
            },
            else => {},
        }
    }
}

/// Detect whether `Context :: struct {...}` is declared anywhere in the
/// program. Used to gate the implicit `__sx_ctx` param machinery: when
/// `std.sx` is in the dep graph, `Context` is declared and every sx
/// function gets the implicit param. Otherwise the program runs with a
/// bare C ABI (no global Context, no implicit param, no FFI wrappers).
pub fn detectContextDecl(decls: []const *const Node) bool {
    for (decls) |decl| {
        const found = switch (decl.data) {
            .struct_decl => |sd| std.mem.eql(u8, sd.name, "Context"),
            .const_decl => |cd| std.mem.eql(u8, cd.name, "Context") and cd.value.data == .struct_decl,
            .namespace_decl => |ns| detectContextDecl(ns.decls),
            else => false,
        };
        if (found) return true;
    }
    return false;
}

/// Returns true if a sx function declaration should receive the
/// implicit `__sx_ctx` parameter. False for extern-libc bindings,
/// intrinsic / #compiler bodies, and C-conv functions (which keep
/// their literal C ABI). Also false for OS-called entry points
/// (`isExportedEntryName`): main and JNI hooks are invoked by the
/// dyld / JVM with no `__sx_ctx` arg, so the visible signature must
/// not include one. Their bodies are still sx code — they
/// synthesise `&__sx_default_context` at entry and use it as their
/// own `current_ctx_ref`. Full FFI-wrapper split (a separate
/// `__sx_<name>_impl` with the ctx param) lands in Step 4 proper.
pub fn funcWantsImplicitCtx(self: *const Lowering, fd: *const ast.FnDecl) bool {
    if (!self.implicit_ctx_enabled) return false;
    if (fd.abi == .c) return false;
    // An `abi(.naked)` function has no frame and no synthetic params — its body
    // is a single asm block reading args from ABI registers. No implicit
    // `__sx_ctx` (it would occupy a register slot the asm doesn't expect).
    // See Function.is_naked.
    if (fd.abi == .naked) return false;
    // An `evaluate` intrinsic is dispatched to a VM handler with exactly the
    // declared args; an implicit `__sx_ctx` prepend would shift every one of them
    // and break the handler's arity check. No sx context, like an extern import.
    // (A build callback is an ordinary sx function the VM runs — it gets the
    // normal implicit-ctx treatment.)
    // `extern` imports and `export` defines are external C symbols —
    // C ABI, no sx context (Phase 2, gap iv).
    if (fd.extern_export != .none) return false;
    return switch (fd.body.data) {
        .intrinsic_expr => false,
        else => !isExportedEntryName(fd.name),
    };
}

/// Returns true if a fn-pointer of the given type carries an implicit
/// `__sx_ctx` at LLVM slot 0. Default-conv sx fn-pointers do; C-conv
/// (and any non-function type) does not.
pub fn fnPtrTypeWantsCtx(self: *const Lowering, ty: TypeId) bool {
    if (!self.implicit_ctx_enabled) return false;
    if (ty.isBuiltin()) return false;
    const ti = self.module.types.get(ty);
    if (ti != .function) return false;
    return ti.function.call_conv != .c;
}

// ── Unified declaration-fact writers (R5 §#4) ──
// The SOLE writers of the three semantic maps — global
// `type_alias_map` / `module_const_map` / `global_names` AND their
// source-partitioned analogues (`*_by_source`). Invariant: the global and
// by-source write for a name are inseparable — a write-site that mirrors
// one without the other lets a ns-only author miss `*_by_source` and leak
// past the source-aware bare-TYPE gate. No raw `.put`/`.remove` to the
// three maps exists outside these helpers (grep-checkable — mirrors the
// no-raw-`TypeTable.update` discipline). The global map stays the only
// READER for now; the per-source cache feeds the gate. A null source
// (unreachable for a scanned top-level decl post-import-resolution) falls
// back to the main file; if even that is absent only the by-source write is
// skipped — the global map is always written.
pub fn putTypeAlias(self: *Lowering, source: ?[]const u8, name: []const u8, tid: TypeId) void {
    self.program_index.type_alias_map.put(name, tid) catch {};
    if (source orelse self.main_file) |src| self.program_index.putTypeAliasBySource(src, name, tid);
}
pub fn putModuleConst(self: *Lowering, source: ?[]const u8, name: []const u8, info: program_index_mod.ModuleConstInfo) void {
    self.program_index.module_const_map.put(name, info) catch {};
    if (source orelse self.main_file) |src| self.program_index.putModuleConstBySource(src, name, info);
}
pub fn putGlobal(self: *Lowering, source: ?[]const u8, name: []const u8, info: program_index_mod.GlobalInfo) void {
    self.program_index.global_names.put(name, info) catch {};
    if (source orelse self.main_file) |src| self.program_index.putGlobalBySource(src, name, info);
}
pub fn dropModuleConst(self: *Lowering, source: ?[]const u8, name: []const u8) void {
    _ = self.program_index.module_const_map.remove(name);
    if (source orelse self.main_file) |src| self.program_index.removeModuleConstBySource(src, name);
}

/// Pass 1: Scan declarations — register ASTs and extern stubs, but don't lower bodies.
pub fn scanDecls(self: *Lowering, decls: []const *const Node) void {
    // Pass 0: register every numeric-literal module const (`N :: 16` and the
    // typed `N : i64 : 16`, plus float-valued `N :: 4.0` / `N : f64 : 4.0`)
    // BEFORE any type alias is resolved below. A type alias whose dimension is
    // a named const (`Arr :: [N]T`) resolves its dimension eagerly here, on
    // the stateless registration path; that path can only read
    // `module_const_map`. Untyped consts would otherwise be registered only in
    // declaration order (pass 1) and typed ones only after the alias fixpoint
    // (pass 2) — so an alias declared before its const, or any alias over a
    // typed const, saw an empty table and miscompiled the dimension to length
    // 0. A float-valued const resolves to a dimension only when
    // its value is integral (`floatToIntExact`); pre-registering it keeps the
    // forward-alias float path identical to the int path. The dimension only
    // needs the value, so a placeholder type is fine; pass 2 overwrites typed
    // consts with the resolved annotation type.
    for (decls) |decl| {
        if (decl.data != .const_decl) continue;
        const cd = decl.data.const_decl;
        switch (cd.value.data) {
            .int_literal => {
                const info = program_index_mod.ModuleConstInfo{ .value = cd.value, .ty = .i64 };
                self.putModuleConst(decl.source_file, cd.name, info);
            },
            .char_literal => {
                const info = program_index_mod.ModuleConstInfo{ .value = cd.value, .ty = .i64 };
                self.putModuleConst(decl.source_file, cd.name, info);
            },
            .float_literal => {
                const info = program_index_mod.ModuleConstInfo{ .value = cd.value, .ty = .f64 };
                self.putModuleConst(decl.source_file, cd.name, info);
            },
            // A const whose RHS is an integer EXPRESSION over other consts
            // (`M :: 2; N :: M + 1`) is itself a usable count: register it so
            // `moduleConstInt` can fold the RHS through `evalConstIntExpr`
            //. Placeholder `.i64` type — the count consumers read
            // only the value; if the expression doesn't fold (references a
            // non-const), `moduleConstInt` yields null and the use diagnoses.
            .binary_op, .unary_op => {
                const info = program_index_mod.ModuleConstInfo{ .value = cd.value, .ty = .i64 };
                self.putModuleConst(decl.source_file, cd.name, info);
            },
            // Bool/string literal consts carry their real type — registering
            // them here (not just in declaration-ordered pass 1) lets a
            // const ALIAS chain below resolve through them regardless of
            // declaration order (issue 0296).
            .bool_literal => {
                const info = program_index_mod.ModuleConstInfo{ .value = cd.value, .ty = .bool };
                self.putModuleConst(decl.source_file, cd.name, info);
            },
            .string_literal => {
                const info = program_index_mod.ModuleConstInfo{ .value = cd.value, .ty = .string };
                self.putModuleConst(decl.source_file, cd.name, info);
            },
            else => {},
        }
    }
    // Pass 0a': const ALIASES of consts (`B :: A`, chains of any depth /
    // declaration order). A bare-identifier RHS was never registered, so
    // `B` failed as "unresolved" at every value use — while the expression
    // spelling `B :: A + 0` worked (issue 0296). Register the alias with its
    // TARGET's type (the typer reads `ty`, so a placeholder would break
    // `if B` on a bool chain); the value node stays the identifier —
    // `emitModuleConst`'s expression arm lowers it through the target.
    // Only a target that IS a registered module const qualifies; an
    // identifier naming a type / function / global keeps its existing
    // behavior. Fixpoint over the decl list so chain order doesn't matter;
    // an unresolvable or cyclic alias simply never registers and the use
    // site diagnoses as before.
    {
        var changed = true;
        var iters: u32 = 0;
        while (changed and iters < 16) : (iters += 1) {
            changed = false;
            for (decls) |decl| {
                if (decl.data != .const_decl) continue;
                const cd = decl.data.const_decl;
                if (cd.value.data != .identifier and cd.value.data != .field_access) continue;
                if (self.program_index.module_const_map.contains(cd.name)) continue;
                const target: program_index_mod.ModuleConstInfo = switch (cd.value.data) {
                    .identifier => |id| self.program_index.module_const_map.get(id.name) orelse continue,
                    .field_access => blk: {
                        const from = decl.source_file orelse self.main_file orelse continue;
                        const path = self.qualifiedTypeName(cd.value) orelse continue;
                        defer self.alloc.free(path);
                        const sel = switch (self.qualifiedMemberVerdictFrom(path, from)) {
                            .selected => |s| s,
                            .not_qualified, .missing, .ambiguous => continue,
                        };
                        break :blk self.sourceModuleConst(sel.target.target_module_path, sel.member) orelse continue;
                    },
                    else => unreachable,
                };
                self.putModuleConst(decl.source_file, cd.name, .{ .value = cd.value, .ty = target.ty });
                changed = true;
            }
        }
    }
    // Pass 0b: reserve every GENUINE same-name NAMED-TYPE shadow's DISTINCT
    // nominal slot BEFORE the registration loop resolves any fields (E2/F1, and
    // enum/union from E6a). A field / variant type referencing a shadow name —
    // self (`next: *Box`), or a forward / mutual ref to a shadow declared LATER
    // in the same module (`peer: *Node`) — then binds to its OWN nominal TypeId
    // via `type_decl_tids`, never the global findByName first-author fallback

    //
    // "Genuine" = ≥2 DISTINCT decls in THIS scan author the name (so it needs
    // ≥2 distinct nominal TypeIds). Grouping is by NAME ONLY: same-KIND authors
    // (two `struct Foo`s) and CROSS-KIND authors (an imported `E :: struct {}`
    // plus a local `E :: error { ... }`) form one shadow group alike — a
    // forward reference from a fn signature must bind its OWN file's author
    // whatever its kind, and without the up-front reservation the signature's
    // `findByName` fallback binds whichever author interned first (issue 0212:
    // the imported struct won, so the signature and the body — resolved
    // source-aware AFTER registration — disagreed about the same param). Each
    // decl still reserves through its own kind's reserver, so the reserved
    // slot's kind always matches its later registration (the
    // `updatePreservingKey` key-stability requirement). Gating on the scanned
    // decls — NOT `nameHasMultipleTypeAuthors` (the raw import facts, which
    // over-count one file reached via two un-normalized import spellings, e.g.
    // `math/matrix44` pulled in twice) — keeps a single-real-decl name on the
    // legacy id-0 path, byte-identical. ALL authors of a genuine shadow
    // reserve, in declaration order: the FIRST at id 0, the rest at fresh
    // nonzero ids, matching the per-decl registration order so the
    // first-author-keeps-0 assignment holds.
    var shadow_first = std.AutoHashMap(types.StringId, *const anyopaque).init(self.alloc);
    defer shadow_first.deinit();
    var genuine_shadows = std.AutoHashMap(types.StringId, void).init(self.alloc);
    defer genuine_shadows.deinit();
    for (decls) |decl| {
        const td = topLevelTypeDecl(decl) orelse continue;
        if (td.isGeneric()) continue;
        const sk = self.module.types.internString(td.name());
        const gop = shadow_first.getOrPut(sk) catch continue;
        if (gop.found_existing) {
            if (gop.value_ptr.* != td.key()) genuine_shadows.put(sk, {}) catch {};
        } else gop.value_ptr.* = td.key();
    }
    for (decls) |decl| {
        const td = topLevelTypeDecl(decl) orelse continue;
        if (td.isGeneric()) continue;
        const sk = self.module.types.internString(td.name());
        if (!genuine_shadows.contains(sk)) continue;
        self.setCurrentSourceFile(decl.source_file);
        self.reserveShadowSlot(td);
    }
    for (decls) |decl| {
        self.setCurrentSourceFile(decl.source_file);
        const is_imported = if (self.main_file) |mf|
            (if (decl.source_file) |sf| !std.mem.eql(u8, sf, mf) else false)
        else
            false;
        switch (decl.data) {
            .fn_decl => |fd| {
                // First-wins on a bare-name collision, matching `mergeFlat`
                // and `resolveFuncByName`. A later namespace recursion that
                // re-introduces a same-named function (e.g. a second module
                // also exporting `parse`) must NOT clobber the AST while the
                // function table keeps the first — that split lowers one
                // signature against the other's body. The
                // shadowed function stays reachable via its qualified name.
                if (!self.program_index.fn_ast_map.contains(fd.name)) {
                    self.program_index.fn_ast_map.put(fd.name, &decl.data.fn_decl) catch {};
                    self.program_index.import_flags.put(fd.name, is_imported) catch {};
                }
                // Declare extern stub for all functions (bodies lowered
                // lazily). Key the identity map (`fn_decl_fids`, inside
                // `declareFunction`) by the STABLE AST field pointer — the
                // same `&decl.data.fn_decl` stored in `fn_ast_map` and the
                // `module_decls` raw facts — not the switch-capture copy `fd`,
                // whose address is a per-iteration stack temporary that no
                // later decl-identity lookup can reproduce.
                self.declareFunction(&decl.data.fn_decl, fd.name);
            },
            .const_decl => |cd| {
                if (cd.value.data == .fn_decl) {
                    if (!self.program_index.fn_ast_map.contains(cd.name)) {
                        self.program_index.fn_ast_map.put(cd.name, &cd.value.data.fn_decl) catch {};
                        self.program_index.import_flags.put(cd.name, is_imported) catch {};
                    }
                    self.declareFunction(&cd.value.data.fn_decl, cd.name);
                } else if (cd.value.data == .struct_decl) {
                    self.registerStructDecl(&cd.value.data.struct_decl, decl.source_file);
                } else if (cd.value.data == .enum_decl) {
                    // Per-decl nominal identity for enum/tagged-union types (E6a)
                    self.registerEnumDecl(&cd.value.data.enum_decl);
                } else if (cd.value.data == .union_decl) {
                    // Per-decl nominal identity for plain union types (E6a)
                    self.registerUnionDecl(&cd.value.data.union_decl);
                } else if (isCompositeAliasRhs(cd.value.data)) {
                    // COMPOSITE type alias — tuple / array / slice / optional /
                    // pointer / many-pointer / function / closure RHS
                    // (`NT :: Tuple(a: i64, b: bool)`, `Bad :: [3]T`,
                    // `S :: []T`, `O :: ?T`, `P :: *T`, `F :: (T) -> U`,
                    // `CB :: Closure(T) -> U`). Register EAGERLY only when every
                    // element/pointee/param/return leaf ALREADY resolves (normal
                    // declaration order) so later-in-file fn signatures see the
                    // alias. Resolving an element that references a LATER decl
                    // would mint a permanent empty-struct stub under the
                    // element's name — never adopted for aliases, a silently
                    // size-0 wrong layout forever (issue 0196 HIGH-1, extended
                    // to every composite kind in 0230) — so those DEFER to the
                    // `resolveCompositeAliases` fixpoint after the forward-alias
                    // fixpoint below, where the element is ADOPTED once its
                    // decl has been seen (`A :: [2]B; B :: i64` now works).
                    if (typeNodeLeavesReady(self, cd.value, decl.source_file)) {
                        registerCompositeAlias(self, &decl.data.const_decl, decl.source_file);
                    }
                } else if (cd.value.data == .type_expr) {
                    // Bare-name type alias: MyFloat :: f64;  A :: B.
                    // A `.type_expr` RHS is a single name leaf — resolved
                    // statelessly here, then re-tried by the source-aware
                    // `resolveForwardIdentifierAliases` fixpoint if it names a
                    // forward decl. (Composite RHS shapes take the deferred,
                    // stub-hardened branch above — issue 0230.)
                    const target_ty = type_bridge.resolveAstType(cd.value, &self.module.types, &self.program_index.type_alias_map, &self.program_index.module_const_map);
                    self.putTypeAlias(self.current_source_file, cd.name, target_ty);
                } else if (cd.value.data == .identifier or cd.value.data == .field_access) {
                    // FN alias (issue 0121): `print2 :: print;` /
                    // `my_print :: s.print;`. When the alias chain terminates
                    // at a fn decl, register the ALIAS name in `fn_ast_map`
                    // pointing at the target's decl — every dispatch path
                    // (early pack/comptime/generic, plain lazy-lower,
                    // plan-side return typing) reads that map, so the alias
                    // dispatches exactly like the target. Absent-only: a real
                    // same-name fn keeps its slot (same-name re-exports are
                    // a no-op — the target already owns the name).
                    if (self.current_source_file orelse self.main_file) |from| {
                        if (self.aliasedFnDecl(&decl.data.const_decl, from)) |target_fd| {
                            if (!self.program_index.fn_ast_map.contains(cd.name)) {
                                self.program_index.fn_ast_map.put(cd.name, target_fd) catch {};
                            }
                        }
                    }
                    if (cd.value.data == .identifier) {
                        // Identifier-RHS alias: MyAlias :: MyInt;  WideAlias :: Wide.
                        // SOURCE-AWARE (E1.5). Resolve the RHS `B` AS SEEN FROM this
                        // alias's OWN source via `selectNominalLeaf` (E1's source-
                        // keyed nominal leaf), NEVER the global `type_alias_map` /
                        // global `findByName` (last-wins across modules). Only the
                        // `.resolved` outcome is written; `.pending` (B is itself a
                        // forward alias not resolved yet), `.undeclared`, and
                        // `.not_visible` (a same-name B authored only by a namespaced
                        // import) leave A UNWRITTEN so the source-aware
                        // `resolveForwardIdentifierAliases` fixpoint re-tries A once
                        // the local B registers. A GLOBAL selection here would bind A
                        // to a namespaced same-name B, and the per-source fixpoint
                        // guard (`aliasResolvedInSource`) would then SKIP A — leaving
                        // the wrong global TypeId and re-opening 0105 one layer down
                        // (R1, E1.5). Same unified `putTypeAlias` writer (no-drift).
                        const rhs = cd.value.data.identifier;
                        if (self.current_source_file orelse self.main_file) |from| {
                            switch (self.selectNominalLeaf(rhs.name, from, rhs.is_raw)) {
                                .resolved => |tid| self.putTypeAlias(self.current_source_file, cd.name, tid),
                                // `.ambiguous` (same-name RHS authored by ≥2 flat
                                // imports) leaves A unwritten like `.not_visible`;
                                // the loud diagnostic fires where A is USED.
                                .pending, .forward, .undeclared, .not_visible, .ambiguous => {},
                            }
                        }
                    } else if (cd.value.data == .field_access) {
                        // Qualified type alias: `Alias :: foreign.P`, including
                        // a nested namespace prefix. Resolve every edge from the
                        // alias AUTHOR's source and retain the exact terminal
                        // target. A forward target remains unwritten and is
                        // retried by the post-scan fixpoint.
                        if (self.current_source_file orelse self.main_file) |from| {
                            const path = self.qualifiedTypeName(cd.value) orelse continue;
                            defer self.alloc.free(path);
                            switch (self.qualifiedMemberVerdictFrom(path, from)) {
                                .selected => |sel| {
                                    // A field-access RHS can alias a VALUE const
                                    // just as readily as a nominal type
                                    // (`N :: facade.engine.COUNT`). Register the
                                    // exact selected source's const before trying
                                    // the type domain; otherwise the type probe
                                    // correctly says `.undeclared` and the alias
                                    // is silently lost at runtime. The stored RHS
                                    // remains the qualified node, so emission and
                                    // nested const folding re-prove the same path.
                                    if (self.sourceModuleConst(sel.target.target_module_path, sel.member)) |target| {
                                        self.putModuleConst(self.current_source_file, cd.name, .{ .value = cd.value, .ty = target.ty });
                                    } else switch (self.selectNominalLeaf(sel.member, sel.target.target_module_path, false)) {
                                        .resolved => |tid| self.putTypeAlias(self.current_source_file, cd.name, tid),
                                        .pending, .forward, .undeclared, .not_visible, .ambiguous => {},
                                    }
                                },
                                .missing => |m| if (self.diagnostics) |d|
                                    d.addFmt(.err, cd.value.span, "namespace '{s}' has no member '{s}'", .{ m.namespace, m.member }),
                                .ambiguous => |alias| if (self.diagnostics) |d|
                                    d.addFmt(.err, cd.value.span, "namespace '{s}' is ambiguous: aliases from multiple flat-imported modules point at different targets; declare the alias locally", .{alias}),
                                .not_qualified => {},
                            }
                        }
                    }
                }
                // Handle generic struct instantiation: Vec3 :: Vec(3, f32)
                // Parser produces a .call node for these (not parameterized_type_expr)
                if (cd.value.data == .call) {
                    const call_data = &cd.value.data.call;
                    const head_qualified = call_data.callee.data == .field_access;
                    const callee_name = switch (call_data.callee.data) {
                        .identifier => |id| id.name,
                        .field_access => |fa| fa.field,
                        else => "",
                    };
                    const qualified_path: ?[]const u8 = if (head_qualified)
                        self.qualifiedTypeName(call_data.callee)
                    else
                        null;
                    defer if (qualified_path) |path| self.alloc.free(path);
                    const selected_fd: ?*const ast.FnDecl = if (qualified_path) |path|
                        self.qualifiedFnMember(path)
                    else
                        self.program_index.fn_ast_map.get(callee_name);
                    // `E :: f(...)` where `f` is a NON-generic fn returning
                    // `Type` (a comptime type constructor): comptime-evaluate the
                    // call — `declare`/`define` reached inside it mint the type —
                    // and bind `E` as an alias to the result. No hardcoded
                    // constructor names: any Type-returning value-fn flows here.
                    // Generic type-fns (`$T`) are minted by
                    // `instantiateTypeFunction` below. Poison on failure so
                    // `E.x` gets a clean follow-on, never a silent default.
                    if (selected_fd) |fd| {
                        if (fd.type_params.len == 0 and fnReturnsTypeValue(fd)) {
                            // The minted type's NAME comes from its `TypeInfo`
                            // (via `define`), not the binding LHS — no rename.
                            const tid = self.evalComptimeType(cd.value) orelse TypeId.unresolved;
                            self.putTypeAlias(self.current_source_file, cd.name, tid);
                            continue;
                        }
                    }
                    // A namespaced callee is an explicit qualified reach,
                    // exempt from the bare-head visibility gate (E4). The
                    // complete path is retained by selectGenericStructCallee,
                    // including nested namespace aliases.
                    if (callee_name.len > 0) {
                        // Generic-struct alias head (`ABox :: Box(i64)` /
                        // `a.Box(i64)`): route layout selection through the single
                        // choke-point (CP-1); the Vector / type-fn branches stay
                        // as the non-generic fall-through.
                        switch (self.selectGenericStructCallee(call_data.callee, call_data.callee.span)) {
                            .template => |t| self.registerGenericStructAlias(cd.name, &t, call_data.args),
                            .poisoned => self.putTypeAlias(self.current_source_file, cd.name, .unresolved),
                            .not_generic => {
                                if (std.mem.eql(u8, callee_name, "Vector")) {
                                    // Builtin type constructor — checked BEFORE
                                    // the generic `fn_ast_map` branch because
                                    // `Vector` IS in `fn_ast_map` (declared as a
                                    // `intrinsic` fn) but `instantiateTypeFunction`
                                    // can't resolve it (no body). Use
                                    // `resolveTypeCallWithBindings` which
                                    // hard-codes the vector layout.
                                    const result_ty = self.resolveTypeCallWithBindings(call_data);
                                    if (result_ty != .void) {
                                        self.putTypeAlias(self.current_source_file, cd.name, result_ty);
                                    }
                                } else if (selected_fd) |fd| {
                                    // Type-returning function: Foo :: Complex(u32)
                                    if (fd.type_params.len > 0) {
                                        if (!head_qualified and self.headFnLeak(callee_name, call_data.callee.span)) {
                                            self.putTypeAlias(self.current_source_file, cd.name, .unresolved);
                                        } else if (self.instantiateTypeFunction(cd.name, callee_name, fd, call_data.args)) |result_ty| {
                                            self.putTypeAlias(self.current_source_file, cd.name, result_ty);
                                        }
                                    }
                                }
                            },
                        }
                    }
                } else if (cd.value.data == .parameterized_type_expr) {
                    // Type alias for generic struct (from type_bridge path)
                    const pt = &cd.value.data.parameterized_type_expr;
                    const base_name = if (std.mem.lastIndexOfScalar(u8, pt.name, '.')) |dot| pt.name[dot + 1 ..] else pt.name;
                    const pt_qualified = std.mem.indexOfScalar(u8, pt.name, '.') != null;
                    // A qualified base `ABox :: a.Box(i64)` selects a's OWN
                    // template via the namespace edge (mirrors the annotation
                    // head site `resolveParameterizedWithBindings`), not the
                    // bare last-wins `struct_template_map`.
                    // Generic-struct alias base: route layout selection through the
                    // single choke-point (CP-1); the builtin parameterised-type
                    // path (Vector etc.) stays as the non-generic fall-through.
                    switch (self.selectGenericStructHead(base_name, if (pt_qualified) pt.name else null, pt_qualified, cd.value.span)) {
                        .template => |t| self.registerGenericStructAlias(cd.name, &t, pt.args),
                        .poisoned => self.putTypeAlias(self.current_source_file, cd.name, .unresolved),
                        .not_generic => {
                            // Builtin parameterised type (Vector(N, T) etc) —
                            // resolve via type_bridge and register the result
                            // under the alias name so `Vec4` in expression
                            // position can `const_type(<vector tid>)`.
                            const result_ty = self.resolveParameterizedWithBindings(pt, cd.value.span);
                            if (result_ty != .void and result_ty != .unresolved) {
                                self.putTypeAlias(self.current_source_file, cd.name, result_ty);
                            }
                        },
                    }
                }
                // comptime_expr handled in Pass 2

                // Typed value constants (`AF_INET :i32: 2`) are registered in
                // pass 2 below — after the forward-alias fixpoint — so a
                // forward identifier alias in the annotation resolves to its
                // target instead of a fabricated stub. Untyped
                // literal constants carry no annotation to resolve, so they
                // stay here (their type comes from the literal / inference).
                if (cd.type_annotation == null) {
                    // Untyped literal constants (e.g. UI_VERT_SRC :: #string GLSL...GLSL;)
                    const lit_ty: ?TypeId = switch (cd.value.data) {
                        .string_literal => .string,
                        .int_literal => .i64,
                        .float_literal => .f64,
                        .bool_literal => .bool,
                        .char_literal => .i64,
                        // Complex constant expressions (e.g. COLOR_WHITE :: Color.{ r = 255, ... })
                        .struct_literal => self.inferExprType(cd.value),
                        else => null,
                    };
                    if (lit_ty) |ty| {
                        const info = program_index_mod.ModuleConstInfo{ .value = cd.value, .ty = ty };
                        self.putModuleConst(self.current_source_file, cd.name, info);
                    }
                }
            },
            .struct_decl => {
                self.registerStructDecl(&decl.data.struct_decl, decl.source_file);
            },
            .enum_decl => {
                // Per-decl nominal identity for enum/tagged-union types (E6a)
                self.registerEnumDecl(&decl.data.enum_decl);
            },
            .union_decl => {
                // Per-decl nominal identity for plain union types (E6a)
                self.registerUnionDecl(&decl.data.union_decl);
            },
            .error_set_decl => {
                self.registerErrorSetDecl(decl);
            },
            .protocol_decl => {
                self.registerProtocolDecl(&decl.data.protocol_decl);
            },
            .impl_block => {
                self.protocolResolver().registerImplBlock(&decl.data.impl_block, is_imported, decl);
            },
            .runtime_class_decl => {
                self.registerRuntimeClassDecl(&decl.data.runtime_class_decl);
            },
            .namespace_decl => |ns| {
                self.registerNamespacedRuntimeClasses(ns);
                if (self.main_file != null) {
                    self.scanDecls(ns.decls);
                    self.registerNamespaceQualifiedFns(ns.name, ns.own_decls);
                }
            },
            .ufcs_alias => |ua| {
                self.program_index.ufcs_alias_map.put(ua.name, ua.target) catch {};
            },
            // Top-level globals are registered in a second pass (below),
            // after the forward-alias fixpoint, so a forward identifier
            // alias used as a global's type annotation resolves.
            .var_decl => {},
            else => {},
        }
    }
    self.resolveForwardIdentifierAliases(decls);
    resolveCompositeAliases(self, decls);
    // Retry only impls that could not be registered in declaration order
    // (notably a protocol/alias declared later). Successful registrations are
    // identity-marked and remain byte-for-byte in their original order.
    for (decls) |decl| {
        if (decl.data != .impl_block) continue;
        if (self.registered_protocol_impls.contains(&decl.data.impl_block)) continue;
        self.setCurrentSourceFile(decl.source_file);
        const is_imported = if (self.main_file) |mf|
            (if (decl.source_file) |sf| !std.mem.eql(u8, sf, mf) else false)
        else
            false;
        self.protocolResolver().registerImplBlock(&decl.data.impl_block, is_imported, decl);
    }
    // Pass 2: registrations that resolve a top-level type annotation run
    // after the alias fixpoint, so a forward identifier alias used as the
    // annotation resolves to its target.
    for (decls) |decl| {
        self.setCurrentSourceFile(decl.source_file);
        switch (decl.data) {
            .var_decl => self.registerTopLevelGlobal(&decl.data.var_decl),
            .const_decl => |cd| if (cd.value.data == .array_literal)
                self.registerConstArrayGlobal(&cd)
            else {
                self.registerTypedModuleConst(&cd);
                self.maybeRegisterConstStructGlobal(&cd);
            },
            else => {},
        }
    }
    // Every mutable-global symbol now exists, so relocatable initializers can
    // refer forward as well as backward (`p : *T = @later`). Fill payloads in
    // a separate pass without changing declaration/global ordering.
    for (decls) |decl| {
        if (decl.data != .var_decl) continue;
        self.setCurrentSourceFile(decl.source_file);
        initializeTopLevelGlobal(self, &decl.data.var_decl);
    }
    // Pass 2b: untyped consts whose RHS is a CONST-AGGREGATE leaf
    // (`L :: K.len`, `E :: K[1]`, `R :: LIT.r`) register with the count
    // placeholder so the folders reach them. Runs AFTER pass 2 so the
    // aggregate (array const / struct const) is registered regardless of
    // declaration order; gated on the receiver naming a const aggregate so
    // a namespaced member (`F :: m.PI_ISH`) is never mis-typed.
    for (decls) |decl| {
        if (decl.data != .const_decl) continue;
        const cd = decl.data.const_decl;
        if (cd.type_annotation != null) continue;
        self.setCurrentSourceFile(decl.source_file);
        const obj: *const Node = switch (cd.value.data) {
            .field_access => |fa| fa.object,
            .index_expr => |ie| ie.object,
            else => continue,
        };
        if (obj.data != .identifier) continue;
        const recv_is_agg = switch (self.selectModuleConst(obj.data.identifier.name)) {
            .resolved => |sel| sel.info.value.data == .array_literal or sel.info.value.data == .struct_literal,
            .own_opaque, .ambiguous, .none => false,
        };
        if (!recv_is_agg) continue;
        self.putModuleConst(decl.source_file, cd.name, .{ .value = cd.value, .ty = .i64 });
    }
}

/// Register a typed module-level value constant (`AF_INET :i32: 2`). Run in
/// scanDecls pass 2 (after `resolveForwardIdentifierAliases`) so a forward
/// identifier alias in the annotation (`A :: B; B :: i32; K : A : 42;`)
/// resolves to its target rather than a fabricated empty-struct stub, which
/// would otherwise mistype the constant.
pub fn registerTypedModuleConst(self: *Lowering, cd: *const ast.ConstDecl) void {
    const ta = cd.type_annotation orelse return;
    // Only initializer shapes that pass 0 (binary_op / unary_op → placeholder
    // `.i64`) or the literal path register as a USABLE module const need
    // reconciling against the annotation. Every other shape (call,
    // struct/array literal, bare identifier) is never registered as a
    // foldable / emittable const, so it cannot manifest a
    // wrong-type fold/emit; a use-site diagnostic covers it.
    switch (cd.value.data) {
        .int_literal, .float_literal, .bool_literal, .string_literal, .char_literal, .undef_literal, .null_literal, .binary_op, .unary_op, .struct_literal => {},
        else => return,
    }
    const ty = self.resolveType(ta);
    // An unresolvable annotation is already diagnosed by the type resolver;
    // don't pile a bogus type-mismatch on top, and don't leave the pass-0
    // placeholder behind as a usable const.
    if (ty == .unresolved) {
        self.dropModuleConst(self.current_source_file, cd.name);
        return;
    }
    // Validate the initializer against the explicit annotation BY TYPE, so a
    // const-EXPRESSION initializer (`N : string : M + 2`) is checked exactly
    // like a literal rather than skipped. A mismatch is a type error, not a
    // silently-accepted const — registering it would let `emitModuleConst`
    // stamp the value with the wrong IR type (an int emitted as a `string`
    // const → a bogus pointer that segfaults at the use site) and let the
    // count path fold it (`[N]i64` → 4). Issue 0088.
    if (!self.typedConstInitFits(cd.value, ty)) {
        // A non-integral compile-time float into an integer const is the
        // same implicit-narrowing failure as a typed local/field/param —
        // report it with the unified wording (integral floats now FOLD here,
        // so the old generic "initializer is a float literal/expression"
        // message is stale). Every other mismatch keeps the generic wording.
        if (self.isIntEx(ty) and isFloat(self.inferExprType(cd.value))) {
            if (program_index_mod.evalConstFloatExpr(cd.value, self)) |fv| {
                self.diagNonIntegralNarrow(cd.value.span, fv, ty);
                self.dropModuleConst(self.current_source_file, cd.name);
                return;
            }
        }
        if (self.diagnostics) |d| {
            d.addFmt(.err, cd.value.span, "type mismatch: constant '{s}' is declared '{s}' but its initializer is {s}", .{
                cd.name, self.formatTypeName(ty), self.initializerDescription(cd.value),
            });
        }
        // Evict the pass-0 placeholder (`N : string : 4` and
        // `N : string : M + 2` are both pre-registered as `.i64` in scanDecls
        // pass 0); leaving it would let a count use still fold `N`.
        self.dropModuleConst(self.current_source_file, cd.name);
        return;
    }
    // Reconcile the registration with the resolved annotation (pass 0 stored
    // a literal/expression placeholder type), so the const folds and emits at
    // its declared type — the same `put` the literal path always did.
    const info = program_index_mod.ModuleConstInfo{ .value = cd.value, .ty = ty };
    self.putModuleConst(self.current_source_file, cd.name, info);
}

/// True iff a literal initializer of `value`'s kind is faithfully
/// representable at the declared `dst_ty` — the precondition
/// `emitModuleConst` relies on when it materialises the constant. The arms
/// match `emitModuleConst`'s arms exactly, using the same type-kind
/// predicates (`isIntEx` / `isFloat` / the `module.types.get` tag) the rest
/// of lowering uses.
///
/// Deliberately NOT routed through `coercionResolver().classify`
/// (conversions.zig): that planner judges RUNTIME value coercions and is
/// unsound as a compile-time literal-representability oracle here — a `null`
/// literal's natural type is `.void`, so `classify(.void, *T)` yields `.none`
/// and would reject the valid `P : *void : null`; `bool` is 1 bit wide, so
/// `classify(.bool, i64)` yields `.widen` and would accept the bogus
/// `B : i64 : true`.
pub fn typedConstInitFits(self: *Lowering, value: *const Node, dst_ty: TypeId) bool {
    // An INTEGER-annotated constant accepts a compile-time INTEGRAL float —
    // a literal (`K : i64 : 4.0`), an int-leaf expression (`K : i64 : M + 2.0`
    // → 4), or a float-const-leaf expression whose SUM is integral
    // (`F : f64 : 2.5; K : i64 : F + 1.5` → 4). Integrality is judged on the
    // FLOAT fold (`evalConstFloatExpr` + `floatToIntExact`) — the SAME facility
    // the typed-local path (`foldComptimeFloatInit`) uses — not the int-only
    // folder, which folds leaf-by-leaf in `i64` and so misses an integral SUM
    // built from a non-integral float leaf. A non-integral fold (`1.5`,
    // `M + 0.5`, `F + 0.25`) yields null here and falls through to the
    // rejecting checks below, where `registerTypedModuleConst` emits the
    // unified narrowing diagnostic.
    if (self.isIntEx(dst_ty)) {
        switch (value.data) {
            .float_literal, .binary_op, .unary_op => {
                if (program_index_mod.evalConstFloatExpr(value, self)) |fv| {
                    if (program_index_mod.floatToIntExact(fv) != null) return true;
                }
            },
            else => {},
        }
    }
    return switch (value.data) {
        // `---` zero-inits at any type.
        .undef_literal => true,
        // Integer literal → any integer (incl. custom widths) or float
        // (`WIDTH : f32 : 800`).
        .int_literal => self.isIntEx(dst_ty) or isFloat(dst_ty),
        // Char literal → same as int literal (it's an integer code point).
        .char_literal => self.isIntEx(dst_ty) or isFloat(dst_ty),
        // Float literal → a float type only (the float arm emits `constFloat`).
        .float_literal => isFloat(dst_ty),
        .bool_literal => dst_ty == .bool,
        .string_literal => dst_ty == .string,
        // `null` → a pointer or optional.
        .null_literal => !dst_ty.isBuiltin() and switch (self.module.types.get(dst_ty)) {
            .pointer, .many_pointer, .optional => true,
            else => false,
        },
        // Const-EXPRESSION initializer (binary_op / unary_op — the only
        // non-literal kinds the caller admits): validate by the initializer's
        // INFERRED type so coverage is type-based, not a per-node-kind
        // allowlist where an unenumerated kind silently escapes. The integer/float fit mirrors the literal arms above.
        else => self.constExprInitFits(self.inferExprType(value), dst_ty),
    };
}

/// True iff a const-expression initializer of inferred type `init_ty` is
/// faithfully representable at the declared `dst_ty`. Type-based so it covers
/// every const-expression shape (binary_op, unary_op, …) through one check
/// rather than per-node-kind arms. The integer/float arms mirror the
/// int/float literal arms of `typedConstInitFits` (an integer expression fits
/// an integer or float annotation; a float expression fits a float).
pub fn constExprInitFits(self: *Lowering, init_ty: TypeId, dst_ty: TypeId) bool {
    // An initializer whose type we couldn't infer is left for the use-site /
    // emission diagnostic rather than rejected here (no over-rejection).
    if (init_ty == .unresolved) return true;
    if (self.isIntEx(init_ty)) return self.isIntEx(dst_ty) or isFloat(dst_ty);
    if (isFloat(init_ty)) return isFloat(dst_ty);
    if (init_ty == .bool) return dst_ty == .bool;
    if (init_ty == .string) return dst_ty == .string;
    // Any other concrete initializer type must match the annotation exactly.
    return init_ty == dst_ty;
}

/// Register an array-typed `::` constant (`K : [4]i64 : .[...]`, or the
/// untyped `A :: .[1, 2, 3]`) as an IMMUTABLE module global: one storage,
/// reads GEP it, the emitter marks it LLVMSetGlobalConstant, dead-global
/// elimination drops it when unused. Source-aware reads come for free via
/// `selectGlobalAuthor` (the per-source partition is written here).
pub fn registerConstArrayGlobal(self: *Lowering, cd: *const ast.ConstDecl) void {
    const al = &cd.value.data.array_literal;
    const arr_ty: TypeId = blk: {
        if (cd.type_annotation) |ta| {
            const t = self.resolveType(ta);
            if (t == .unresolved) return; // annotation already diagnosed
            if (t.isBuiltin() or self.module.types.get(t) != .array) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, cd.value.span, "constant '{s}' has an array-literal initializer but its annotation is not an array type", .{cd.name});
                return;
            }
            const dim = self.module.types.get(t).array.length;
            if (dim != al.elements.len) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, cd.value.span, "constant '{s}' declares [{d}] elements but its initializer has {d}", .{ cd.name, dim, al.elements.len });
                return;
            }
            break :blk t;
        }
        break :blk self.inferConstArrayType(cd.name, al.elements, cd.value.span) orelse return;
    };
    const init_val = self.constArrayLiteral(al.elements, arr_ty) orelse {
        if (self.diagnostics) |d|
            d.addFmt(.err, cd.value.span, "constant '{s}' must be initialized by compile-time constant elements", .{cd.name});
        return;
    };
    const name_id = self.module.types.internString(cd.name);
    const gid = self.module.addGlobal(.{
        .name = name_id,
        .ty = arr_ty,
        .init_val = init_val,
        .is_const = true,
    });
    self.putGlobal(self.current_source_file, cd.name, .{ .id = gid, .ty = arr_ty });
    // ALSO register as a module const so the comptime folders see the
    // elements (`K.len` / `K[<const idx>]` in dims and const exprs).
    // Bare value reads still hit the GLOBAL arm first (identifier arm
    // order), so this never double-emits.
    self.putModuleConst(self.current_source_file, cd.name, .{ .value = cd.value, .ty = arr_ty });
}

/// Infer `[N]T` for an untyped array-literal constant. Element types unify:
/// all ints → i64; ANY float promotes the element type to f64 (ints convert
/// exactly — the int+float promotion rule for consts, element-wise); bool /
/// string homogeneous only. A non-numeric mix or a non-inferable element
/// shape (nested aggregate, enum literal, named const) asks for an
/// annotation rather than guessing.
pub fn inferConstArrayType(self: *Lowering, name: []const u8, elements: []const *const Node, span: ast.Span) ?TypeId {
    if (elements.len == 0) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "constant '{s}' is an empty array literal — annotate the type (e.g. `{s} : [0]i64 : .[]`)", .{ name, name });
        return null;
    }
    var elem_ty: ?TypeId = null;
    for (elements) |e| {
        const leaf: ?TypeId = switch (e.data) {
            .int_literal => .i64,
            .float_literal => .f64,
            .bool_literal => .bool,
            .string_literal => .string,
            .char_literal => .i64,
            .unary_op => |uo| if (uo.op == .negate) switch (uo.operand.data) {
                .int_literal => .i64,
                .float_literal => .f64,
                .char_literal => .i64,
                else => null,
            } else null,
            else => null,
        };
        const lt = leaf orelse {
            if (self.diagnostics) |d|
                d.addFmt(.err, e.span, "cannot infer the element type of constant '{s}' from this element — annotate the array type", .{name});
            return null;
        };
        if (elem_ty) |prev| {
            if (prev == lt) continue;
            // Numeric mix promotes to the float element type.
            const numeric_pair = (prev == .i64 and lt == .f64) or (prev == .f64 and lt == .i64);
            if (numeric_pair) {
                elem_ty = .f64;
                continue;
            }
            if (self.diagnostics) |d|
                d.addFmt(.err, e.span, "constant '{s}' mixes incompatible element types — annotate the array type", .{name});
            return null;
        }
        elem_ty = lt;
    }
    return self.module.types.arrayOf(elem_ty.?, @intCast(elements.len));
}

/// Migrate a struct-literal constant to an IMMUTABLE GLOBAL when every
/// field serializes (literals, enum tags, nested aggregates, and — via the
/// fold helpers — const expressions over named consts / const-aggregate
/// leaves). One storage, reads GEP it, `@W` becomes addressable. A const
/// with a NON-serializable field (a call, a runtime read) keeps the inline
/// re-lowering path — per-use evaluation is that class's documented
/// contract. The module-const registration stays either way (folds +
/// fallback share it); bare reads hit the GLOBAL arm first when migrated.
pub fn maybeRegisterConstStructGlobal(self: *Lowering, cd: *const ast.ConstDecl) void {
    if (cd.value.data != .struct_literal) return;
    const src = self.current_source_file orelse self.main_file orelse return;
    const ci = self.sourceModuleConst(src, cd.name) orelse return;
    if (ci.ty.isBuiltin() or self.module.types.get(ci.ty) != .@"struct") return;
    const init_val = self.constStructLiteral(&cd.value.data.struct_literal, ci.ty) orelse return;
    const name_id = self.module.types.internString(cd.name);
    const gid = self.module.addGlobal(.{
        .name = name_id,
        .ty = ci.ty,
        .init_val = init_val,
        .is_const = true,
    });
    self.putGlobal(self.current_source_file, cd.name, .{ .id = gid, .ty = ci.ty });
}

/// Register a top-level mutable global (e.g., `context : Context = ---;`).
/// Run AFTER `resolveForwardIdentifierAliases` so a forward identifier alias
/// in the type annotation (`A :: B; B :: i32; g : A = 7;`) resolves to its
/// target instead of a fabricated empty-struct stub, which would otherwise
/// give the global a type that mismatches its initializer at LLVM
/// verification. Globals can't be named in a type position, so
/// deferring them past type/alias registration introduces no ordering hazard.
pub fn registerTopLevelGlobal(self: *Lowering, vd: *const ast.VarDecl) void {
    // Use self.resolveType so type aliases like `Handle :: u32;` resolve
    // to their target type (not a synthetic empty struct). When the
    // user omitted the annotation, infer from the initializer
    // expression; extern globals with no annotation are diagnosed
    // because their type can't be inferred without an initializer.
    const var_ty: TypeId = if (vd.type_annotation) |ta|
        self.resolveType(ta)
    else if (vd.value) |val|
        self.inferExprType(val)
    else blk: {
        if (self.diagnostics) |d|
            d.addFmt(.err, null, "top-level var '{s}' has no type annotation and no initializer to infer from", .{vd.name});
        break :blk .void;
    };
    // Extern globals reference a symbol defined in libSystem etc.
    // (`_NSConcreteStackBlock : *void extern;` or `… : *void extern;`). The C
    // symbol name is the optional override (`extern_name`) or the sx name itself.
    const sym_name = vd.extern_name orelse vd.name;
    const name_id = self.module.types.internString(sym_name);
    const gid = self.module.addGlobal(.{
        .name = name_id,
        .ty = var_ty,
        .init_val = null,
        .is_const = false,
        .is_extern = vd.is_extern,
    });
    const info = program_index_mod.GlobalInfo{ .id = gid, .ty = var_ty };
    self.global_decl_infos.put(vd, info) catch @panic("out of memory while indexing global declaration identity");
    self.putGlobal(self.current_source_file, vd.name, info);
}

fn initializeTopLevelGlobal(self: *Lowering, vd: *const ast.VarDecl) void {
    const gi = switch (self.selectGlobalAuthor(vd.name)) {
        .resolved => |g| g,
        .untracked => self.program_index.global_names.get(vd.name) orelse return,
        else => return,
    };
    if (gi.id.index() >= self.module.globals.items.len) return;
    self.module.globals.items[gi.id.index()].init_val = self.globalInitValue(vd, gi.ty);
}

/// Serialize a top-level global's initializer into a static `ConstantValue`.
/// Extern globals (external symbol) and value-less declarations carry no
/// payload — they default to zero/extern at link, which is correct. An
/// identifier initializer that names a module constant is materialized from
/// the recorded constant (`K : A : 42; g : A = K;` → 42); a
/// global initialized from an identifier that resolves to no usable constant
/// is rejected with a diagnostic rather than silently zero-initialized — a
/// global has no run site for a dynamic initializer.
pub fn globalInitValue(self: *Lowering, vd: *const ast.VarDecl, var_ty: TypeId) ?inst_mod.ConstantValue {
    if (vd.is_extern) return null;
    const v = vd.value orelse return null;

    // An optional-typed global (`g : ?T = <present>;`) must carry the
    // 2-field `{ payload, has_value }` aggregate the optional's LLVM
    // layout expects — NOT the raw payload constant (issue 0234). The
    // absent forms (`= null` / `= ---`) already zero the whole `{T,i1}`
    // struct via `.null_val` / `.zeroinit` at the emit top level, which is
    // exactly `{ zeroinit, false }`, so they flow through unwrapped. Any
    // other (present) initializer is serialized against the CHILD type and
    // wrapped here into `{ <payload>, true }`. Recursing on the child type
    // also handles nested optionals (`?(?i64)`) and optional aggregates
    // (`?S = S.{...}`), whose payloads are themselves structs/optionals.
    if (!var_ty.isBuiltin() and self.module.types.get(var_ty) == .optional) {
        switch (v.data) {
            .null_literal => return .null_val,
            .undef_literal => return .zeroinit,
            else => {},
        }
        const child = self.module.types.get(var_ty).optional.child;
        const payload = self.globalInitValuePayload(vd, v, child) orelse return null;
        // Sentinel-shaped optionals (`?*T`, `?fn`, `?Closure`, `?Protocol`)
        // reuse the payload's null representation and therefore have no
        // `{payload, has_value}` wrapper in LLVM. A present global address is
        // already the complete initializer for `?*T` (issue 0248).
        const child_info = self.module.types.get(child);
        const sentinel_optional = child_info == .pointer or child_info == .many_pointer or
            child_info == .function or child_info == .cstring or child_info == .closure or
            (child_info == .@"struct" and child_info.@"struct".is_protocol);
        if (sentinel_optional) return payload;
        const fields = self.alloc.alloc(inst_mod.ConstantValue, 2) catch return null;
        fields[0] = payload;
        fields[1] = .{ .boolean = true };
        return .{ .aggregate = fields };
    }

    return self.globalInitValuePayload(vd, v, var_ty);
}

/// Serialize a global initializer expression against `var_ty` into a static
/// `ConstantValue`, WITHOUT any optional wrapping (see `globalInitValue`,
/// which handles the optional `{payload, has_value}` layout before calling
/// here). This is the raw payload serializer.
pub fn globalInitValuePayload(self: *Lowering, vd: *const ast.VarDecl, v: *const Node, var_ty: TypeId) ?inst_mod.ConstantValue {
    return switch (v.data) {
        .undef_literal => .zeroinit,
        .null_literal => .null_val,
        .int_literal => |il| blk: {
            self.checkIntLiteralMagnitudeFits(il.value, var_ty, v.span);
            break :blk .{ .int = il.value };
        },
        // Char literal — same as int, but a char-aware fit check so the
        // diagnostic names it as a char literal and suggests wider storage.
        .char_literal => |cl| blk: {
            self.checkCharLiteralFits(cl, var_ty, v.span);
            break :blk .{ .int = cl.value };
        },
        // A negated literal (`g : i64 = -1;`) folds through the shared
        // const-expr serializer. The folded value follows the same rules as
        // the direct literal arms: int fits-check; a float at an integer
        // global narrows only when integral.
        .unary_op => blk: {
            const u = v.data.unary_op;
            // `xx <global>` at an #inline-protocol-typed global folds to the
            // inline protocol constant (identity erasure of the global's
            // stable storage — L8 rider a). Non-protocol `xx` falls through
            // to the ordinary const-expr fold below.
            if (u.op == .xx) {
                if (self.protocolErasureConst(u.operand, var_ty)) |cv| break :blk cv;
            }
            if (u.op == .address_of and u.operand.data == .identifier) {
                const target_name = u.operand.data.identifier.name;
                switch (self.selectGlobalAuthor(target_name)) {
                    .resolved => |g| break :blk inst_mod.ConstantValue{ .global_ref = g.id },
                    .untracked => if (self.program_index.global_names.get(target_name)) |g|
                        break :blk inst_mod.ConstantValue{ .global_ref = g.id },
                    else => {},
                }
            }
            if (self.constExprValue(v, var_ty)) |cv| {
                switch (cv) {
                    .int => |iv| self.checkIntLiteralFits(iv, var_ty, v.span),
                    .float => |fv| if (self.isIntEx(var_ty)) {
                        if (program_index_mod.floatToIntExact(fv)) |iv| break :blk inst_mod.ConstantValue{ .int = iv };
                        self.diagNonIntegralNarrow(v.span, fv, var_ty);
                        break :blk null;
                    },
                    else => {},
                }
                break :blk cv;
            }
            break :blk self.diagnoseNonConstGlobal(vd, v);
        },
        .bool_literal => |bl| .{ .boolean = bl.value },
        // A float initializer at an integer-typed global follows the
        // implicit narrowing rule (integral folds, non-integral errors).
        .float_literal => |fl| blk: {
            if (self.isIntEx(var_ty)) {
                if (program_index_mod.floatToIntExact(fl.value)) |iv| break :blk inst_mod.ConstantValue{ .int = iv };
                self.diagNonIntegralNarrow(v.span, fl.value, var_ty);
                break :blk null;
            }
            break :blk inst_mod.ConstantValue{ .float = fl.value };
        },
        .string_literal => |sl| .{ .string = self.module.types.internString(sl.raw) },
        .array_literal => |al| self.constArrayLiteral(al.elements, var_ty) orelse self.diagnoseNonConstGlobal(vd, v),
        .struct_literal => |sl| self.constStructLiteral(&sl, var_ty) orelse self.diagnoseNonConstGlobal(vd, v),
        .identifier => |id| blk: {
            // A bare identifier at an #inline-PROTOCOL-typed global is an
            // identity erasure of the named global — the declared type states
            // the conversion, no `xx` needed. Same fold as the explicit
            // `xx <global>` in the unary arm.
            if (self.protocolErasureConst(v, var_ty)) |cv| break :blk cv;
            // A global initialized from a module constant copies the
            // constant's recorded value (typed module consts land in
            // `module_const_map` via `registerTypedModuleConst`, run in the
            // same pass-2 before this). F1/F2: copy the SOURCE-AWARE author's
            // value (own-wins), folding its RHS in the author's context, and
            // reject a ≥2-flat ambiguity loudly.
            if (self.program_index.module_const_map.get(id.name)) |ci_global| {
                const sel: SelectedConst = switch (self.selectModuleConst(id.name)) {
                    .resolved => |s| s,
                    .none => .{ .info = ci_global, .source = null },
                    .own_opaque => {
                        if (self.diagnostics) |d|
                            d.addFmt(.err, v.span, "global '{s}' must be initialized by a compile-time constant; '{s}' is not a usable constant here", .{ vd.name, id.name });
                        break :blk null;
                    },
                    .ambiguous => {
                        if (self.diagnostics) |d|
                            d.addFmt(.err, v.span, "'{s}' is ambiguous: it is declared in multiple flat-imported modules; qualify the reference or remove the duplicate import", .{id.name});
                        break :blk null;
                    },
                };
                const author_pin = self.pinConstAuthorSource(sel.source);
                defer author_pin.unpin();
                if (self.constExprValue(sel.info.value, var_ty)) |cv| break :blk cv;
            }
            if (self.diagnostics) |d|
                d.addFmt(.err, v.span, "global '{s}' must be initialized by a compile-time constant; '{s}' is not a usable constant here", .{ vd.name, id.name });
            break :blk null;
        },
        // An enum-literal global (`chosen : Color = .green;`) serializes to
        // the variant's tag value against the destination enum type (issue
        // 0082). The compiler-injected `OS`/`ARCH` globals flow through here
        // too; their runtime reads resolve via `comptime_constants`, so the
        // serialized tag only affects the static initializer.
        .enum_literal => |el| self.constEnumLiteral(&el, var_ty, v.span),
        // Any other initializer shape (`.field_access` on a const, a call, an
        // arithmetic expression, …) is not a static constant the compiler can
        // evaluate here. Diagnose loudly rather than emit a null payload that
        // silently zero-initializes the global.
        else => blk: {
            if (self.diagnostics) |d|
                d.addFmt(.err, v.span, "global '{s}' must be initialized by a compile-time constant", .{vd.name});
            break :blk null;
        },
    };
}

/// A global aggregate initializer (array/struct literal) that does not fully
/// reduce to a compile-time constant is rejected loudly. Without this the
/// `null` payload would fall through to a zero-initialized global, silently
/// dropping the declared fields.
pub fn diagnoseNonConstGlobal(self: *Lowering, vd: *const ast.VarDecl, v: *const Node) ?inst_mod.ConstantValue {
    if (self.diagnostics) |d|
        d.addFmt(.err, v.span, "global '{s}' must be initialized by a compile-time constant", .{vd.name});
    return null;
}

/// Resolve identifier-RHS type aliases whose target is declared LATER in the
/// file. The forward scan above only registers an alias (`A :: B`) when `B`
/// is already resolved as a type author; a forward target isn't yet present,
/// so `A` is left unregistered and its uses get falsely flagged as an unknown
/// type. Re-resolve to a fixpoint now that every top-level name
/// has been seen, so `A :: B; B :: i32;` converges the same as the ordered
/// `B :: i32; A :: B;`. A value const is never an `.identifier` node
/// (`NotAType :: 123` is an int literal), and an alias whose target is a value
/// const stays unresolved, so neither this pass nor the unknown-type suppression can register a
/// non-type name.
///
/// SOURCE-AWARE (R5 §4, E1.5). The target `B` is resolved AS SEEN FROM `A`'s
/// OWN source via the source-aware nominal leaf (`selectNominalLeaf` over
/// `type_aliases_by_source` / `moduleTypeAuthor` — E1), NEVER the global
/// `type_alias_map` / global `findByName`. The "already resolved" guard is
/// likewise per-source. When a same-name `B` is authored by a *different*
/// source (e.g. a namespaced import polluting the global alias map last-wins),
/// a global fixpoint would bind `A` to the wrong `B` and re-open 0105 one
/// layer down once E2 registers shadows; resolving against `A`'s source binds
/// the local `B`. The `.pending` outcome (B is itself a not-yet-resolved
/// forward alias) routes BACK into this fixpoint — `A` is skipped this round
/// and converges on a later iteration. `.undeclared` (no type author) and
/// `.not_visible` (a namespaced-only type, not bare-aliasable) leave `A`
/// unwritten; its uses surface the stub / diagnostic, never a silent global
/// leak. The write stays on the unified `putTypeAlias` helper (E1 no-drift
/// invariant — only the helper touches the maps).
pub fn resolveForwardIdentifierAliases(self: *Lowering, decls: []const *const Node) void {
    var progressed = true;
    while (progressed) {
        progressed = false;
        for (decls) |decl| {
            const cd = switch (decl.data) {
                .const_decl => |c| c,
                else => continue,
            };
            const src = decl.source_file orelse self.main_file orelse continue;
            if (self.aliasResolvedInSource(src, cd.name)) continue;
            // The (leaf-name, from-source, raw) triple to resolve the alias RHS:
            //  • `A :: B`        — a bare identifier; resolve `B` from `src`.
            //  • `A :: ns.Leaf`  — a qualified RHS (`Color :: inner.Color`); the
            //    namespace `ns` binds in the ALIAS author's file (`src`), so pin
            //    `ns` to its target module and resolve `Leaf` THERE. Without this
            //    a re-exported ENUM/union/error alias stays `.pending` and adopts
            //    the empty-struct `{}` stub — which silently name-reconciles for a
            //    struct target but corrupts a non-struct target (issue 0206).
            var qualified_path: ?[]const u8 = null;
            defer if (qualified_path) |path| self.alloc.free(path);
            const target_src, const leaf, const leaf_raw = switch (cd.value.data) {
                .identifier => |rhs| .{ src, rhs.name, rhs.is_raw },
                .field_access => blk: {
                    const path = self.qualifiedTypeName(cd.value) orelse continue;
                    // `sel.member` is a slice into `path`; retain that owned
                    // spelling through the `selectNominalLeaf` call below.
                    // Freeing it inside this switch arm leaves `leaf`
                    // dangling and Zig's debug allocator catches the aliased
                    // memcpy while interning the poisoned slice.
                    qualified_path = path;
                    const sel = switch (self.qualifiedMemberVerdictFrom(path, src)) {
                        .selected => |s| s,
                        .not_qualified, .missing, .ambiguous => continue,
                    };
                    break :blk .{ sel.target.target_module_path, sel.member, false };
                },
                else => continue,
            };
            switch (self.selectNominalLeaf(leaf, target_src, leaf_raw)) {
                .resolved => |tid| {
                    self.putTypeAlias(decl.source_file, cd.name, tid);
                    progressed = true;
                },
                // B not yet a resolved type author from this source: a forward
                // alias still pending (re-tried next round), a forward / not-
                // yet-registered named author, an undeclared name, a
                // namespaced-only type that is not bare-aliasable, or an
                // ambiguous same-name shadow (≥2 flat authors). Leave A
                // unwritten — no global last-wins leak; the ambiguity surfaces
                // where A is used.
                .pending, .forward, .undeclared, .not_visible, .ambiguous => {},
            }
        }
    }
}

/// TRUE when a const-decl RHS is a COMPOSITE type-expression alias whose
/// element/pointee/param/return positions carry name leaves that must defer
/// past the forward-alias fixpoint (issue 0230 — generalizes the 0196 tuple
/// case to array / slice / optional / pointer / many-pointer / function /
/// closure RHS). Bare-name aliases (`.type_expr` / `.identifier`, e.g.
/// `MyFloat :: f64`, `B :: A`) are DELIBERATELY excluded — those resolve
/// through the source-aware `resolveForwardIdentifierAliases` fixpoint.
fn isCompositeAliasRhs(kind: std.meta.Tag(ast.Node.Data)) bool {
    return switch (kind) {
        .tuple_type_expr,
        .array_type_expr,
        .slice_type_expr,
        .optional_type_expr,
        .pointer_type_expr,
        .many_pointer_type_expr,
        .function_type_expr,
        .closure_type_expr,
        => true,
        else => false,
    };
}

/// The `const_decl` behind a composite-type-alias declaration
/// (`NT :: Tuple(...)`, `Bad :: [3]T`, `S :: []T`, `O :: ?T`, `P :: *T`,
/// `F :: (T) -> U`, `CB :: Closure(T) -> U`), or null for any other decl
/// shape (issue 0230, generalized from the 0196 tuple-only probe).
fn compositeAliasConstDecl(decl: *const Node) ?*const ast.ConstDecl {
    if (decl.data != .const_decl) return null;
    const cd = &decl.data.const_decl;
    if (!isCompositeAliasRhs(cd.value.data)) return null;
    return cd;
}

/// Registration-time READINESS probe for a tuple-alias RHS (issue 0196): TRUE
/// when every bare type-name leaf in `node` already resolves from `source` —
/// probed via the NON-MINTING `selectNominalLeaf`, so a not-yet-registered
/// element name never gets a permanent empty-struct stub interned under it
/// (the stub is adopted only by NOMINAL decls, never by a later alias — the
/// 0196-review HIGH-1 silent-layout corruption). FALSE defers the alias to
/// the `resolveCompositeAliases` fixpoint (element declared later) or its final
/// rounds (spread / undeclared / builtin-constructor heads — resolved or
/// diagnosed there). Conservative by construction: node kinds without bare
/// name leaves are treated as ready and validated by the post-resolution
/// `typeCarriesUnresolved` check instead.
pub fn typeNodeLeavesReady(self: *Lowering, node: *const Node, source: ?[]const u8) bool {
    const src = source orelse self.main_file orelse return true;
    switch (node.data) {
        // A `..pack` spread can never resolve at a top-level alias (no pack
        // binding exists) — never ready; `registerCompositeAlias` emits the
        // precise message in the final round.
        .spread_expr => return false,
        .type_expr => |te| return bareTypeLeafReady(self, te.name, src, te.is_raw),
        .identifier => |id| return bareTypeLeafReady(self, id.name, src, id.is_raw),
        // A pointer / many-pointer POINTEE tolerates a forward NOMINAL leaf:
        // `*RouteCtx` behind a function alias declared above `RouteCtx :: struct`
        // is a well-formed pointer regardless of pointee completeness, and the
        // minted forward stub is ADOPTED when the nominal registers (key-stable
        // update) — exactly the working `next: *Node` forward-field pattern the
        // stdlib relies on (issue 0230). So the pointee is probed in
        // `behind_ptr` mode: a bare `.forward` (forward nominal) leaf counts as
        // ready there, while `.pending` (a forward IDENTIFIER ALIAS — never
        // adopted) still defers.
        .pointer_type_expr => |p| return typeNodeLeavesReadyBehindPtr(self, p.pointee_type, source),
        .many_pointer_type_expr => |m| return typeNodeLeavesReadyBehindPtr(self, m.element_type, source),
        .slice_type_expr => |s| return typeNodeLeavesReady(self, s.element_type, source),
        .optional_type_expr => |o| return typeNodeLeavesReady(self, o.inner_type, source),
        // Dimension consts are pre-registered (scan pass 0); only the element
        // carries name leaves. An unresolvable dimension is caught by the
        // post-resolution validation.
        .array_type_expr => |a| return typeNodeLeavesReady(self, a.element_type, source),
        .tuple_type_expr => |tt| {
            for (tt.field_types) |ft| if (!typeNodeLeavesReady(self, ft, source)) return false;
            return true;
        },
        .return_type_expr => |rt| {
            for (rt.field_types) |ft| if (!typeNodeLeavesReady(self, ft, source)) return false;
            return true;
        },
        .closure_type_expr => |ct| {
            // Pack-shaped `Closure(..p)`: no pack binding at an alias — the
            // final round diagnoses it via the resolver's own guards.
            if (ct.pack_name != null) return false;
            for (ct.param_types) |pt| if (!typeNodeLeavesReady(self, pt, source)) return false;
            if (ct.return_type) |r| return typeNodeLeavesReady(self, r, source);
            return true;
        },
        .function_type_expr => |ft| {
            for (ft.param_types) |pt| if (!typeNodeLeavesReady(self, pt, source)) return false;
            if (ft.return_type) |r| return typeNodeLeavesReady(self, r, source);
            return true;
        },
        // Generic instantiation element (`List(i64)`): the head's template
        // must be registered; a qualified head resolves through the stateful
        // resolver's namespace guards, and the builtin `Vector` constructor
        // head has no template — both land in the last-chance round. A
        // VALUE-const arg (`Vector(N, f32)`) is a name that never enters the
        // alias table, so it probes not-ready and likewise settles in the
        // last-chance round.
        .parameterized_type_expr => |pt| {
            const qualified = std.mem.indexOfScalar(u8, pt.name, '.') != null;
            const base = if (std.mem.lastIndexOfScalar(u8, pt.name, '.')) |dot| pt.name[dot + 1 ..] else pt.name;
            const head_ready = qualified or self.program_index.struct_template_map.contains(base);
            if (!head_ready) return false;
            for (pt.args) |arg| if (!typeNodeLeavesReady(self, arg, source)) return false;
            return true;
        },
        // Literals (array dims / Vector lanes), inline type decls, error
        // types, … — no bare name leaf to probe; owned by the stateful
        // resolver + post-validation.
        else => return true,
    }
}

/// Readiness probe for a POINTER/MANY-POINTER pointee (issue 0230). Same as
/// `typeNodeLeavesReady` except a bare NOMINAL leaf that is declared-but-not-
/// yet-registered (`.forward`) counts as READY: a pointer to a forward nominal
/// is a well-formed pointer TypeId, and the minted forward stub is adopted
/// (key-stable) when the nominal registers. A nested pointer keeps `behind_ptr`
/// mode; any non-pointer composite inside reverts to the strict value-position
/// probe (`typeNodeLeavesReady`), since an array element / tuple field / slice
/// element behind the pointer is a real value position that must not stub.
fn typeNodeLeavesReadyBehindPtr(self: *Lowering, node: *const Node, source: ?[]const u8) bool {
    const src = source orelse self.main_file orelse return true;
    return switch (node.data) {
        .type_expr => |te| bareTypeLeafReadyBehindPtr(self, te.name, src, te.is_raw),
        .identifier => |id| bareTypeLeafReadyBehindPtr(self, id.name, src, id.is_raw),
        .pointer_type_expr => |p| typeNodeLeavesReadyBehindPtr(self, p.pointee_type, source),
        .many_pointer_type_expr => |m| typeNodeLeavesReadyBehindPtr(self, m.element_type, source),
        // An optional pointee (`*?T`) is a real value payload — strict probe.
        // Every other shape (array/slice/tuple/function/closure/generic) is a
        // value position or owns its own readiness rule; defer to the strict
        // probe so nothing that must not stub slips through behind the pointer.
        else => typeNodeLeavesReady(self, node, source),
    };
}

/// `bareTypeLeafReady`, but a `.forward` (forward NOMINAL) leaf counts as ready
/// — used only behind a pointer, where a forward nominal is a legal pointee
/// (the stub is adopted on registration). `.pending` (forward IDENTIFIER ALIAS,
/// never adopted) still defers.
fn bareTypeLeafReadyBehindPtr(self: *Lowering, name: []const u8, src: []const u8, raw: bool) bool {
    if (std.mem.indexOfScalar(u8, name, '.') != null) return true;
    return switch (self.selectNominalLeaf(name, src, raw)) {
        .resolved, .forward => true,
        .pending, .undeclared, .not_visible, .ambiguous => false,
    };
}

/// TRUE when the bare type name `name` resolves from `src` RIGHT NOW —
/// builtin, registered named type, or already-registered alias — via the
/// non-minting `selectNominalLeaf`. `.pending` / `.forward` (declared but not
/// yet registered) and the terminal failures (undeclared / not-visible /
/// ambiguous) are all "not ready": the fixpoint re-probes the former; the
/// last-chance round surfaces the latter through the stateful resolver's own
/// diagnostics.
fn bareTypeLeafReady(self: *Lowering, name: []const u8, src: []const u8, raw: bool) bool {
    // Qualified names (`ns.T`) resolve through the namespace-edge machinery
    // with its own guards — trust the stateful resolver.
    if (std.mem.indexOfScalar(u8, name, '.') != null) return true;
    return switch (self.selectNominalLeaf(name, src, raw)) {
        .resolved => true,
        .pending, .forward, .undeclared, .not_visible, .ambiguous => false,
    };
}

/// TRUE when any bare type-name leaf in a composite-alias RHS names a
/// still-unregistered composite alias (`pending`) — the reference-cycle probe
/// for `resolveCompositeAliases`' last-chance round. Resolving such an RHS
/// would mint an empty-struct stub for the pending peer that
/// `typeCarriesUnresolved` cannot tell from a real empty struct, silently
/// registering a lying layout (issue 0230, generalized from 0196's tuple probe).
fn compositeRhsReferencesPending(node: *const Node, pending: *const std.StringHashMap(void)) bool {
    switch (node.data) {
        .type_expr => |te| return pending.contains(te.name),
        .identifier => |id| return pending.contains(id.name),
        .pointer_type_expr => |p| return compositeRhsReferencesPending(p.pointee_type, pending),
        .many_pointer_type_expr => |m| return compositeRhsReferencesPending(m.element_type, pending),
        .slice_type_expr => |s| return compositeRhsReferencesPending(s.element_type, pending),
        .optional_type_expr => |o| return compositeRhsReferencesPending(o.inner_type, pending),
        .array_type_expr => |a| return compositeRhsReferencesPending(a.element_type, pending),
        .tuple_type_expr => |tt| {
            for (tt.field_types) |ft| if (compositeRhsReferencesPending(ft, pending)) return true;
            return false;
        },
        .return_type_expr => |rt| {
            for (rt.field_types) |ft| if (compositeRhsReferencesPending(ft, pending)) return true;
            return false;
        },
        .closure_type_expr => |ct| {
            for (ct.param_types) |pt| if (compositeRhsReferencesPending(pt, pending)) return true;
            if (ct.return_type) |r| return compositeRhsReferencesPending(r, pending);
            return false;
        },
        .function_type_expr => |ft| {
            for (ft.param_types) |pt| if (compositeRhsReferencesPending(pt, pending)) return true;
            if (ft.return_type) |r| return compositeRhsReferencesPending(r, pending);
            return false;
        },
        .parameterized_type_expr => |pt| {
            for (pt.args) |arg| if (compositeRhsReferencesPending(arg, pending)) return true;
            return false;
        },
        else => return false,
    }
}

/// Report the precise per-element diagnostic for a composite-alias RHS that
/// resolved (transitively) to `.unresolved` (issue 0230, generalized from the
/// 0196 tuple loop). Walks the RHS shape to the FIRST offending leaf and emits
/// at that leaf's own span — a `..pack` spread (no pack binding at a top-level
/// alias), an unresolvable array dimension (precise too-large/negative message
/// via `reportDimError` where the fold pins it down), or an element/pointee/
/// param/return that does not name a type. Returns after the first report so a
/// single alias emits one located error, not a cascade.
fn reportCompositeAliasElement(self: *Lowering, cd: *const ast.ConstDecl, node: *const Node) void {
    const d = self.diagnostics orelse return;
    switch (node.data) {
        .spread_expr => d.addFmt(.err, node.span, "type alias '{s}' could not be resolved: a `..pack` spread element needs a pack binding, which a top-level alias never has", .{cd.name}),
        .tuple_type_expr => |tt| {
            for (tt.field_types) |ft| {
                if (typeCarriesUnresolved(&self.module.types, self.resolveTypeWithBindings(ft)))
                    return reportCompositeAliasElement(self, cd, ft);
            }
            d.addFmt(.err, node.span, "type alias '{s}' could not be resolved: a tuple element is not a resolvable type", .{cd.name});
        },
        .array_type_expr => |at| {
            // Precise dimension message where the fold pins it down: an
            // oversized / negative / non-integral constant gets the same
            // located `reportDimError` the direct form (`a : [N]T`) does
            // (the stateful resolver poisons those to `.unresolved` WITHOUT
            // a message of its own). A genuinely NON-CONST dim (`[get()]`),
            // by contrast, was ALREADY reported by the stateful resolve in
            // `registerCompositeAlias` ("array dimension must be a compile-
            // time integer constant", matching the direct form) — so recurse
            // only into the ELEMENT here, never re-emitting a dim message,
            // which would duplicate the resolver's (issue 0230).
            const dim = type_bridge.foldArrayDim(at.length, &self.module.types, &self.program_index.type_alias_map, &self.program_index.module_const_map);
            switch (dim) {
                .too_large, .below_min, .non_integral_float => return program_index_mod.reportDimError(d, at.length.span, dim),
                else => {},
            }
            if (typeCarriesUnresolved(&self.module.types, self.resolveTypeWithBindings(at.element_type)))
                return reportCompositeAliasElement(self, cd, at.element_type);
            // Dim already diagnosed by the resolver; nothing to add.
        },
        .slice_type_expr => |st| reportCompositeAliasElement(self, cd, st.element_type),
        .optional_type_expr => |ot| reportCompositeAliasElement(self, cd, ot.inner_type),
        .pointer_type_expr => |pt| reportCompositeAliasElement(self, cd, pt.pointee_type),
        .many_pointer_type_expr => |mp| reportCompositeAliasElement(self, cd, mp.element_type),
        .function_type_expr => |ft| {
            for (ft.param_types) |pt| {
                if (typeCarriesUnresolved(&self.module.types, self.resolveTypeWithBindings(pt)))
                    return reportCompositeAliasElement(self, cd, pt);
            }
            if (ft.return_type) |rt| {
                if (typeCarriesUnresolved(&self.module.types, self.resolveTypeWithBindings(rt)))
                    return reportCompositeAliasElement(self, cd, rt);
            }
            d.addFmt(.err, node.span, "type alias '{s}' could not be resolved: a function-type element is not a resolvable type", .{cd.name});
        },
        .closure_type_expr => |ct| {
            for (ct.param_types) |pt| {
                if (typeCarriesUnresolved(&self.module.types, self.resolveTypeWithBindings(pt)))
                    return reportCompositeAliasElement(self, cd, pt);
            }
            if (ct.return_type) |rt| {
                if (typeCarriesUnresolved(&self.module.types, self.resolveTypeWithBindings(rt)))
                    return reportCompositeAliasElement(self, cd, rt);
            }
            d.addFmt(.err, node.span, "type alias '{s}' could not be resolved: a closure-type element is not a resolvable type", .{cd.name});
        },
        // A bare name leaf that failed to resolve — the unknown-type checker
        // owns the "unknown type 'X'" diagnostic; here we surface the generic
        // alias failure at the leaf so the poison never ships silently.
        else => d.addFmt(.err, node.span, "type alias '{s}' could not be resolved: '{s}' does not name a type", .{ cd.name, nodeTypeLeafName(node) orelse "<element>" }),
    }
}

/// The bare type-name spelled at a leaf node, for the fallback element
/// diagnostic; null for non-name nodes.
fn nodeTypeLeafName(node: *const Node) ?[]const u8 {
    return switch (node.data) {
        .type_expr => |te| te.name,
        .identifier => |id| id.name,
        else => null,
    };
}

/// Resolve a COMPOSITE-alias RHS STATEFULLY and register it (issue 0230,
/// generalized from the 0196 tuple case to array / slice / optional /
/// pointer / many-pointer / function / closure — and tuple). The stateful
/// `resolveTypeWithBindings` is the same resolver the inline annotation form
/// (`x : [2]List(i64)`, `x : Tuple(a: List(i64), b: string)`) uses, so
/// generic-instantiation elements instantiate for real instead of stubbing
/// into an empty nominal with a lying `size_of`, and a LATER-declared element
/// (`A :: [2]B; B :: i64`) is ADOPTED once the fixpoint reaches it — the
/// deferred-fixpoint POSITIVE fix, never a permanent size-0 stub.
/// A dirty RHS (transitively carrying `.unresolved` — bad dims, unbound
/// generics, undeclared names, `..pack` spreads) poisons the alias with
/// `.unresolved` (clean follow-ons at every use) via
/// `reportCompositeAliasElement`, never a lying layout. Registration also
/// rejects the alias NAME having been stub-bound ABOVE its declaration (an
/// earlier fn signature / struct field resolved the name before this decl
/// registered; the stub is adopted only by nominal decls, so that earlier
/// binder would keep a permanently-wrong empty layout — 0196 review MED-4,
/// surfaced as a located diagnostic instead of an LLVM verifier dump).
fn registerCompositeAlias(self: *Lowering, cd: *const ast.ConstDecl, source: ?[]const u8) void {
    const ty = self.resolveTypeWithBindings(cd.value);
    if (!typeCarriesUnresolved(&self.module.types, ty)) {
        // MED-4 (TUPLE aliases only): a pre-existing EMPTY-STRUCT entry under
        // the alias's own name means an earlier reference (fn signature /
        // struct field) resolved the name before this registration and bound
        // a never-adopted stub. For a STRUCTURAL TUPLE alias that stub keeps a
        // permanently-wrong empty layout (0196 review MED-4), so reject loudly.
        // The other composite RHS kinds (function / closure / pointer / slice
        // / optional / array) do NOT hit this: a struct field / signature that
        // names such an alias above its decl (e.g. `body_read_fn: BodyReadFn`
        // above `BodyReadFn :: (...) -> i64`) is patched by the struct/field
        // re-resolution machinery — a working forward-reference pattern the
        // stdlib http module relies on — so scoping MED-4 to tuple keeps the
        // over-eager rejection from firing on it. A genuine same-name type
        // authored by another module is a legal shadow, not a stub — excluded
        // via the raw import facts.
        if (cd.value.data == .tuple_type_expr) {
            const name_id = self.module.types.internString(cd.name);
            if (self.module.types.findByName(name_id)) |pre| {
                const pre_info = self.module.types.get(pre);
                if (pre_info == .@"struct" and pre_info.@"struct".fields.len == 0 and
                    !self.nameAuthoredAsTypeAnywhere(cd.name))
                {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, cd.value.span, "tuple alias '{s}' is referenced above its declaration (an earlier signature or field bound an unresolvable placeholder); declare the tuple alias before its first use", .{cd.name});
                }
            }
        }
        self.putTypeAlias(source, cd.name, ty);
        return;
    }
    reportCompositeAliasElement(self, cd, cd.value);
    self.putTypeAlias(source, cd.name, .unresolved);
}

/// Fixpoint registration for COMPOSITE-type aliases whose elements reference
/// decls registered LATER in the scan (issue 0196 review HIGH-1, extended to
/// every composite kind in 0230): `A :: [2]B; B :: i64;` /
/// `A :: Tuple(a: B, c: bool); B :: i64;` — A's in-loop registration was
/// deferred (resolving `B` then would mint a permanent stub); now that every
/// top-level name has been seen, re-probe readiness to a fixpoint.
/// Interleaved with `resolveForwardIdentifierAliases` so identifier aliases
/// OF composite aliases (`NT2 :: NT` above `NT`) and composite aliases OVER
/// identifier aliases converge in either declaration order. The LAST-CHANCE
/// round resolves through the stateful resolver even when the readiness
/// probe never turned true — covering its deliberate false-negatives
/// (builtin `Vector` heads, value-const args) — gated on not referencing a
/// still-pending composite alias so a cycle member never resolves against a
/// minted stub of its peer. True leftovers are reference cycles: diagnosed
/// and poisoned, never registered with a stubbed member.
fn resolveCompositeAliases(self: *Lowering, decls: []const *const Node) void {
    // Round 1: readiness-gated fixpoint (no stub minting anywhere).
    var progressed = true;
    while (progressed) {
        progressed = false;
        for (decls) |decl| {
            const cd = compositeAliasConstDecl(decl) orelse continue;
            const src = decl.source_file orelse self.main_file orelse continue;
            if (self.aliasResolvedInSource(src, cd.name)) continue;
            if (!typeNodeLeavesReady(self, cd.value, decl.source_file)) continue;
            self.setCurrentSourceFile(decl.source_file);
            registerCompositeAlias(self, cd, decl.source_file);
            progressed = true;
        }
        if (progressed) self.resolveForwardIdentifierAliases(decls);
    }
    // Round 2: last-chance fixpoint through the stateful resolver.
    progressed = true;
    while (progressed) {
        progressed = false;
        var still_pending = std.StringHashMap(void).init(self.alloc);
        defer still_pending.deinit();
        for (decls) |decl| {
            const cd = compositeAliasConstDecl(decl) orelse continue;
            const src = decl.source_file orelse self.main_file orelse continue;
            if (!self.aliasResolvedInSource(src, cd.name)) still_pending.put(cd.name, {}) catch {};
        }
        for (decls) |decl| {
            const cd = compositeAliasConstDecl(decl) orelse continue;
            const src = decl.source_file orelse self.main_file orelse continue;
            if (self.aliasResolvedInSource(src, cd.name)) continue;
            if (compositeRhsReferencesPending(cd.value, &still_pending)) continue;
            self.setCurrentSourceFile(decl.source_file);
            registerCompositeAlias(self, cd, decl.source_file);
            _ = still_pending.remove(cd.name);
            progressed = true;
        }
        if (progressed) self.resolveForwardIdentifierAliases(decls);
    }
    // Leftovers: every remaining composite alias references a still-pending peer
    // (or itself) — a reference cycle. Diagnose + poison.
    for (decls) |decl| {
        const cd = compositeAliasConstDecl(decl) orelse continue;
        const src = decl.source_file orelse self.main_file orelse continue;
        if (self.aliasResolvedInSource(src, cd.name)) continue;
        self.setCurrentSourceFile(decl.source_file);
        if (self.diagnostics) |d|
            d.addFmt(.err, cd.value.span, "type alias '{s}' could not be resolved: it participates in a composite-alias reference cycle (self-referential structural aliases are not supported; use a named struct for recursive shapes)", .{cd.name});
        self.putTypeAlias(decl.source_file, cd.name, .unresolved);
    }
}

/// TRUE iff `name` is already recorded as a type alias FROM `src` — the
/// per-source analogue of `type_alias_map.contains`, so the forward-alias
/// fixpoint resolves a same-name alias in each source independently (E1.5).
pub fn aliasResolvedInSource(self: *Lowering, src: []const u8, name: []const u8) bool {
    if (self.program_index.type_aliases_by_source.get(src)) |inner| return inner.contains(name);
    return false;
}

/// Pass 2: Lower main function body and comptime side-effects.
pub fn lowerMainAndComptime(self: *Lowering, decls: []const *const Node) void {
    for (decls) |decl| {
        // A `#run` body lowers in its OWN module's source context: `NAME :: #run f()` written in an imported module must
        // resolve a bare `f` from that module's flat imports, not the main
        // file's. Without this, `selectPlainCallableAuthor` runs with the main
        // file's perspective and reports a genuine per-source author as
        // ambiguous. Mirrors `scanDecls` / `lowerDecls`, which already set
        // the source file per decl.
        self.setCurrentSourceFile(decl.source_file);
        switch (decl.data) {
            .const_decl => |cd| {
                if (cd.value.data == .fn_decl) {
                    // `export` defines are roots: their purpose is external
                    // consumption (often never called from sx), so force-lower
                    // them like OS-called entry points — else lazy lowering
                    // leaves them as bodiless `declare` stubs (Phase 2).
                    if (isExportedEntryName(cd.name) or cd.value.data.fn_decl.extern_export == .export_ or isDefaultBuildPipeline(cd.name)) {
                        self.lazyLowerFunction(cd.name);
                    }
                } else if (cd.value.data == .comptime_expr) {
                    self.lowerComptimeGlobal(cd.name, cd.value.data.comptime_expr.expr, cd.type_annotation);
                }
            },
            .fn_decl => |fd| {
                if (isExportedEntryName(fd.name) or fd.extern_export == .export_) {
                    self.lazyLowerFunction(fd.name);
                }
            },
            .comptime_expr => |ct| {
                self.lowerComptimeSideEffect(ct.expr);
            },
            .namespace_decl => |ns| {
                if (self.main_file != null) {
                    self.lowerMainAndComptime(ns.decls);
                }
            },
            // Top-level global asm (Phase F): capture the verbatim template; it
            // is appended to the LLVM module at emit time (source order). The
            // template must be a comptime-known string (parser guarantees a
            // string node here).
            .asm_global => |ag| {
                if (ag.template.data == .string_literal) {
                    self.module.global_asm.append(self.alloc, ag.template.data.string_literal.raw) catch unreachable;
                } else if (self.diagnostics) |diags| {
                    diags.addFmt(.err, decl.span, "global asm template must be a compile-time-known string", .{});
                }
            },
            else => {},
        }
    }
}

/// Lower every SHADOWED same-name function author into its OWN FuncId with a
/// real (non-extern) body — the identity-addressable lowering PATH this step
/// adds. It does NOT run during a default compile: the name path
/// stays the sole resolver, so the suite is byte-for-byte unchanged. The bare-call
/// disambiguation invokes it as part of routing bare flat calls to the right author; until
/// then it is exercised by the lower-test regression that asserts two distinct
/// non-extern bodies for a same-name collision.
///
/// The first-wins flat/directory merge keeps exactly one author per name in
/// the merged decl list; `scanDecls` declares that WINNER (lowered on demand
/// through the name-keyed `lazyLowerFunction`). The merge retains every
/// dropped same-name author in the `module_decls` raw facts (path → name →
/// `RawDeclRef`) without touching resolution; this walks that index, filters
/// each author to its `*FnDecl` (`fnDeclOfRaw`), and gives each shadowed
/// author its own slot: `declareFunction` (identity-mapped to a fresh
/// same-name FuncId) + `lowerFunctionBodyInto` (its body, in its own module's
/// visibility context). Two same-name authors then carry distinct FuncIds and
/// distinct bodies, while `resolveFuncByName` still returns the first (winner)
/// author so existing calls bind first-wins.
///
/// Scoped to DIRECT flat imports of the main file: a `module_decls` entry
/// whose path is the main file or one of its bare `#import` edges. A
/// namespaced (`ns :: #import`) author has no bare-name winner and is excluded
/// both by that flat-edge gate and by the `fn_ast_map` winner lookup below.
pub fn lowerRetainedSameNameAuthors(self: *Lowering) void {
    const module_decls = self.program_index.module_decls orelse return;
    const main_file = self.main_file orelse return;
    const flat_graph = self.program_index.flat_import_graph orelse return;
    const main_flat_edges = flat_graph.get(main_file);

    var path_it = module_decls.iterator();
    while (path_it.next()) |path_entry| {
        const path = path_entry.key_ptr.*;
        const is_eligible = std.mem.eql(u8, path, main_file) or
            (main_flat_edges != null and main_flat_edges.?.contains(path));
        if (!is_eligible) continue;

        var fn_it = path_entry.value_ptr.names.iterator();
        while (fn_it.next()) |fn_entry| {
            const name = fn_entry.key_ptr.*;
            const fd = fnDeclOfRaw(fn_entry.value_ptr.*) orelse continue;

            // A name with no bare winner is namespaced-only (`ns.fn`) — it
            // never participated in the flat merge, so it has no shadow to
            // lower. The author already owning the name-keyed slot (the
            // first-wins winner) lowers through the normal lazy path.
            const winner = self.program_index.fn_ast_map.get(name) orelse continue;
            if (winner == fd) continue;

            // Only plain free functions get an out-of-line slot; generic /
            // extern / builtin / #compiler authors keep their existing
            // dispatch (mirrors lazyLowerFunction / declareFunction guards).
            if (!isPlainFreeFn(fd)) continue;

            _ = self.bareAuthorFuncId(fd, name, path);
        }
    }
}

/// Result of bare-call disambiguation (now over the Phase B
/// author collector).
pub const BareCallee = union(enum) {
    /// Bind the call to this specific author, carried as the shared
    /// `SelectedFunc` (R5 §#3): its `*FnDecl` + authoring source, FuncId
    /// materialized on demand. Every callee-signature decision in the call
    /// path (variadic packing, param typing, default expansion) reads the
    /// RESOLVED author from this one object — never a first-wins re-lookup
    /// by name.
    func: SelectedFunc,
    /// ≥2 distinct flat authors are reachable from the caller and none is
    /// the caller's own — the bare call can't pick one; require a qualifier.
    ambiguous,
    /// 0 or 1 reachable author, or the resolved author IS the existing
    /// bare-name winner — defer to the existing path, byte-for-byte.
    none,
};

/// The single bare-call author object (R5 §#3): the `*FnDecl` that defines
/// the call and the SOURCE file that authors it, kept together so the call
/// path has ONE source of truth for the callee. `materialized` holds the
/// author's FuncId once a site needs it; it is filled on demand by
/// `selectedFuncId` (→ `bareAuthorFuncId`), NOT during selection — so a
/// selection that only needs the decl (default-arg expansion), or a shadow
/// taken purely as a value, never lowers the first-wins winner (0102d).
pub const SelectedFunc = struct {
    decl: *const ast.FnDecl,
    source: []const u8,
    materialized: ?FuncId = null,
};

/// Outcome of the source-aware bare TYPE leaf (`selectNominalLeaf`, R5 §E).
/// The type-position analogue of `BareCallee`: the nominal author is selected
/// over the ONE graph-walk collector and resolved against the source-keyed
/// caches, never the global `findByName` first-match / global alias map.
pub const TypeHeadResolution = union(enum) {
    /// A builtin primitive, a registered named type, or a resolved alias.
    resolved: TypeId,
    /// A const author is visible but its alias target is not resolved yet —
    /// a forward identifier alias. Routes back into the existing
    /// `resolveForwardIdentifierAliases` fixpoint (source-aware in E1.5).
    /// `resolveNominalLeaf` keeps the empty-struct stub (the alias resolves on
    /// a later fixpoint round).
    pending,
    /// A flat-visible author DOES declare `name` as a type, but its TypeId
    /// slot is not registered yet — a forward / self / mutual reference
    /// resolved mid-registration (`next: *ArenaChunk`), or an extern /
    /// lazily-registered author with no `findByName` slot. `resolveNominalLeaf`
    /// keeps the empty-struct stub, which `internNamedTypeDecl` ADOPTS (key-
    /// stable `updatePreservingKey`) when the type registers — so the forward
    /// reference binds to the eventually-filled type. NOT an error: the author
    /// exists, it is simply not interned yet.
    forward,
    /// NO author anywhere declares `name` as a type, an alias, or a const —
    /// a genuinely-undeclared name (a typo, or a value parameter used as a
    /// type). `resolveNominalLeaf` poisons it with the `.unresolved` sentinel
    /// + an "unknown type" diagnostic, never a silently-fabricated 0-field
    /// struct (which would mis-size every downstream load / store). In the
    /// MAIN file the `UnknownTypeChecker` is the diagnostic authority (it owns
    /// scope context + value-param hints, and a valid unbound generic leaf
    /// like `-> T` on a template legitimately lands here), so the leaf keeps
    /// the legacy stub there and defers the diagnostic to the checker.
    undeclared,
    /// `name` IS a registered named type, but it is reachable from the
    /// querying module ONLY through a namespaced import (or over more than one
    /// flat hop) — not bare-visible over the single-hop direct flat-import set
    /// (the type analog of Phase B's bare-call tightening, F1). The user must
    /// qualify it (`ns.Type`) or `#import` the declaring module directly.
    /// `resolveNominalLeaf` surfaces the "not visible" diagnostic and returns
    /// the `.unresolved` poison sentinel — NEVER the global `findByName` match
    /// (which would leak the type) and NEVER a silent empty-struct stub (which
    /// would mis-size it).
    not_visible,
    /// ≥2 DISTINCT same-name type authors are flat-visible from the querying
    /// source and none is its own (E2). The selection is genuinely
    /// ambiguous: `resolveNominalLeaf` emits a loud diagnostic and returns the
    /// `.unresolved` poison sentinel — never a silent first-/last-wins pick.
    ambiguous,
};

/// THE plain bare-name call selector. `resolveBareCallee`'s
/// body verbatim, now over the Phase B author collector
/// (`resolver.collectVisibleAuthors` — the ONE graph-walk) instead of a direct
/// `module_decls` + `flat_import_graph` traversal. Routes a bare identifier
/// call `name` from `caller_file` to the right same-name author when flat
/// imports introduce a genuine collision. Every single-author / local /
/// parameter / std / qualified name resolves through the EXISTING path
/// unchanged: the selector returns `.none` whenever the outcome would match
/// first-wins, so nothing on the common path is perturbed.
///
/// The collector returns RAW authors across ALL decl domains; this selector
/// reproduces a fn-only author view by filtering each author through
/// `fnDeclOfRaw` (a `const`-wrapped fn unwraps to its inner fn; every other
/// domain drops out), preserving resolveBareCallee's negative space
/// byte-for-byte.
///
/// - **own-author wins**: if `caller_file` authors `name` as a fn and the
///   bare-name first-wins winner is a DIFFERENT author, select the caller's
///   own author. (When the winner already IS the caller's own — the
///   single-author and first-importer cases — `.none` lets the existing path
///   bind it.)
/// - else select among the authors reachable via `caller_file`'s FLAT import
///   edges (bare `#import` of a file or directory, never a namespaced
///   `ns :: #import`), deduped by author identity (a diamond import of the
///   same module is one author): `≥2 distinct` → `.ambiguous`; exactly one
///   that DIFFERS from the winner → select it; otherwise `.none`.
///
/// Generic / comptime / extern / builtin authors are never rerouted — the
/// existing dispatch owns those shapes; `isPlainFreeFn` filters them out
/// BEFORE the count gate (so a same-name collision of non-plain authors is
/// NOT ambiguous), and the selector returns `.none`. No eager
/// materialization: the returned `SelectedFunc` carries decl + source and
/// `materialized = null`; a consumer fills the FuncId via `selectedFuncId`
/// only when it truly needs it (0102d).
pub fn selectPlainCallableAuthor(self: *Lowering, name: []const u8, caller_file: []const u8) BareCallee {
    const winner = self.program_index.fn_ast_map.get(name);
    var res = self.resolver();
    const set = res.collectVisibleAuthors(name, caller_file, .user_bare_flat);
    defer if (set.flat.len > 0) self.alloc.free(set.flat);

    // own-author wins. The collector's `own` spans all domains; a non-fn
    // (or a const not bound to a function) means `caller_file` has no fn
    // `name` — fall through to the flat authors, exactly as a fn-only walk
    // would.
    if (set.own) |own_author| {
        if (fnDeclOfRaw(own_author.raw)) |own| {
            if (winner != null and winner.? == own) return .none;
            if (!isPlainFreeFn(own)) return .none;
            return .{ .func = .{ .decl = own, .source = own_author.source } };
        }
    }

    // Caller does not author `name` as a fn → its flat-reachable authors.
    // Filter to plain free functions BEFORE counting: a same-name collision
    // of non-plain authors (e.g. two flat-imported modules each `extern`ing
    // the same symbol) is NOT counted as ambiguous — it falls through to
    // `.none` and the existing first-wins path.
    var the_one: ?*const ast.FnDecl = null;
    var the_source: []const u8 = &.{};
    var count: usize = 0;
    for (set.flat) |fa| {
        const fd = fnDeclOfRaw(fa.raw) orelse continue;
        if (!isPlainFreeFn(fd)) continue;
        count += 1;
        if (count >= 2) return .ambiguous;
        the_one = fd;
        the_source = fa.source;
    }
    if (count == 0) return .none;
    if (winner != null and winner.? == the_one.?) return .none;
    return .{ .func = .{ .decl = the_one.?, .source = the_source } };
}

/// Resolve an as-yet-unregistered alias author directly to a terminal named
/// type when raw import/declaration facts already prove the whole chain. This
/// is principally the declaration-ABI path for `Alias :: foreign.P`: function
/// signatures and aggregate fields may precede either alias declaration in
/// source, while the imported protocol's canonical aggregate layout must be
/// known before their IR types are interned. Materializing a terminal protocol
/// is safe and exactly-once through `registered_protocol_decls`; other named
/// kinds are used only when their ordinary scan already registered a slot.
fn resolvePendingAliasType(self: *Lowering, author: resolver_mod.RawAuthor, alias_name: []const u8) ?TypeId {
    const terminal = self.followAliasChain(author, 16) orelse return null;

    if (terminal.raw == .protocol_decl) {
        const pd = terminal.raw.protocol_decl;
        // Parameterized protocols are compile-time templates, not runtime ABI
        // types, so they cannot satisfy a plain alias annotation here.
        if (pd.type_params.len > 0) return null;
        const saved_source = self.current_source_file;
        self.setCurrentSourceFile(terminal.source);
        self.protocolResolver().registerProtocolDecl(pd);
        self.setCurrentSourceFile(saved_source);
    }

    const terminal_name: []const u8 = switch (terminal.raw) {
        .struct_decl => |d| d.name,
        .enum_decl => |d| d.name,
        .union_decl => |d| d.name,
        .error_set_decl => |d| d.name,
        .protocol_decl => |d| d.name,
        .runtime_class_decl => |d| d.name,
        .const_decl => |d| d.name,
        .fn_decl, .var_decl, .namespace_decl => return null,
    };
    const tid: TypeId = switch (terminal.raw) {
        .const_decl => blk: {
            // `Name :: struct/enum/union/error { ... }` is a named type
            // definition wrapped by the surface `::`, not a type alias. Its
            // exact declaration slot is authoritative and must not be looked
            // up through the alias compatibility map.
            if (self.namedRefTid(terminal.raw, terminal_name)) |named| break :blk named;
            const aliases = self.program_index.type_aliases_by_source.get(terminal.source) orelse return null;
            break :blk aliases.get(terminal_name) orelse return null;
        },
        else => self.namedRefTid(terminal.raw, terminal_name) orelse return null,
    };
    self.putTypeAlias(author.source, alias_name, tid);
    return tid;
}

/// THE source-aware bare TYPE leaf (R5 §E, E1). The type-position analogue
/// of `selectPlainCallableAuthor`: resolve a bare type name `name` referenced
/// from `from` by selecting its nominal author over the ONE graph-walk
/// collector (`resolver.collectVisibleAuthors`) and reading the alias from the
/// source-keyed cache (`type_aliases_by_source`, E0's write side) keyed by the
/// selected author's OWN source — never the global `findByName` first-match
/// nor the global `type_alias_map`.
///
/// `raw` is the backtick raw-identifier escape: a raw reference
/// bypasses the builtin classifier and resolves only through the nominal
/// author / alias path.
///
/// E1 is single-author: `collectVisibleAuthors` returns ≤1 author, so the
/// selection is unambiguous and resolution is byte-identical to the legacy
/// leaf. Same-name shadows (≥2 authors) and the `.ambiguous` outcome (0105)
/// land in E2; the per-author `nominal_id` TypeId that makes a shadow
/// representable also lands then (today a registered named type resolves to
/// its unique `findByName` match, which IS the single author's TypeId).
/// Generic / parameterized-protocol / Vector / type-function heads never
/// reach this leaf — `resolveTypeWithBindings` owns those above the leaf
/// switch, so they stay legacy.
pub fn selectNominalLeaf(self: *Lowering, name: []const u8, from: []const u8, raw: bool) TypeHeadResolution {
    const table = &self.module.types;
    // Builtin primitive keyword / arbitrary-width int — unless a raw escape
    // routes the literal name straight to nominal resolution.
    if (!raw) {
        if (TypeResolver.resolveBuiltinName(name, table)) |id| return .{ .resolved = id };
    }
    // Structural string-forms that reach the leaf as a literal type-expr
    // name (`[:0]u8` → string, `[*]T`, `*T`, `?T`) carry NO nominal author —
    // they are wrappers, not declarations, so source-keying does not apply.
    // Resolve them through the stateless namer exactly as the legacy leaf
    // did; only the bare nominal name below cuts over to the collector.
    if (name.len > 0 and (name[0] == '[' or name[0] == '*' or name[0] == '?')) {
        return .{ .resolved = self.typeResolver().resolveName(name, raw) };
    }
    // Bare nominal name. A bare TYPE name is visible iff a flat-import-
    // reachable module authors it AS A TYPE — and a TYPE author is EITHER a
    // named type (struct/enum/union/error-set/protocol/runtime class) OR a
    // type ALIAS (`Name :: <type>`, a `const_decl` whose value resolved to a
    // type, recorded in E0's `type_aliases_by_source`). Both kinds are gated
    // identically: `moduleTypeAuthor` is the SINGLE source of truth, so a
    // namespaced-only alias leaks no more than a namespaced-only named type,
    // and a flat-visible alias is never poisoned by an invisible same-name
    // named type (and vice-versa) — R4. A same-name flat VALUE/FUNCTION is
    // NOT a type author (R1); a value-const (`N :: 7`) lives in
    // `module_consts_by_source`, never in `type_aliases_by_source`, so it is
    // correctly excluded too.
    //
    // The TYPE reachability here is SINGLE-HOP — `from`'s own author plus its
    // DIRECT flat-import edges (`flatTypeAuthorCount`), the same non-transitive
    // set the bare VALUE / FUNCTION / CONST leaves use (E4, consistent with
    // 0706). A library template's INTERNAL type refs (`List.append`'s
    // `alloc: Allocator`) still resolve because every instantiation kind
    // (generic struct / fn / pack fn / param protocol / type fn) is
    // source-pinned to the template's defining module, so the query
    // originates THERE — where the type is a direct flat import — not at the
    // cross-module call site.
    const name_id = table.internString(name);
    const registered = table.findByName(name_id);

    // Compiler-synthesized default-Context emission resolves the built-in
    // allocator types as infrastructure — fall open (the gate is for USER bare
    // references, not compiler internals).
    if (self.emitting_default_context) {
        if (registered) |existing| return .{ .resolved = existing };
    }
    // Import facts unwired (registration / comptime host with no module_decls
    // or flat graph): there is no querying context to gate against — preserve
    // the legacy resolution (registered → existing; else forward-alias /
    // undeclared).
    if (self.program_index.module_decls == null or self.program_index.flat_import_graph == null) {
        if (registered) |existing| return .{ .resolved = existing };
        // Direct per-source lookup for resolved alias, then pending check.
        if (self.program_index.type_aliases_by_source.get(from)) |inner| {
            if (inner.get(name)) |tid| return .{ .resolved = tid };
        }
        if (self.program_index.module_decls) |decls| {
            if (decls.get(from)) |m| if (m.names.get(name)) |ref| if (ref == .const_decl) return .pending;
        }
        return .undeclared;
    }

    // Single graph-walk over flat imports: one `collectVisibleAuthors` call
    // replaces `moduleTypeAuthor` + `ownConstDeclIsPendingAlias` +
    // `flatTypeAuthorCount` + `forwardAliasOrUndeclared`.
    var res_walk = self.resolver();
    const author_set = res_walk.collectVisibleAuthors(name, from, .user_bare_flat);
    defer if (author_set.flat.len > 0) self.alloc.free(author_set.flat);

    // 1a. Own type author wins outright (own-wins).
    if (author_set.own) |own| switch (own.raw) {
        .const_decl => {
            // Surface named definitions (`Name :: struct/enum/union/error`)
            // are raw const declarations, but semantically they are nominal
            // authors. Resolve the inner declaration identity before the
            // true-alias path; treating it as a pending alias fabricates an
            // unstamped nominal-0 stub and collapses same-name module types.
            if (constWrappedNamedTypeRef(own.raw.const_decl) != null) {
                if (self.namedRefTid(own.raw, name)) |tid| return .{ .resolved = tid };
                return .forward;
            }
            // Type alias: present in type_aliases_by_source → resolved.
            if (self.program_index.type_aliases_by_source.get(own.source)) |inner| {
                if (inner.get(name)) |tid| return .{ .resolved = tid };
            }
            // Forward/qualified alias chains may be queried by an ABI consumer
            // before declaration-order scanning reaches the alias. Resolve the
            // raw chain now so params, returns, fields and wrappers all intern
            // the same canonical protocol TypeId (issue 0323).
            if (resolvePendingAliasType(self, own, name)) |tid| return .{ .resolved = tid };
            // Own const_decl not yet resolved: pending (own takes priority
            // over any flat author — prevents flat-preemption).
            return .pending;
        },
        else => if (isNamedTypeKind(own.raw)) {
            if (self.namedRefTid(own.raw, name)) |tid| return .{ .resolved = tid };
            return .forward; // named type exists but slot not yet interned
        },
        // fn_decl / namespace_decl: not a type author, fall to flat walk
    };

    // 1b. Flat type authors (named types and resolved aliases only; pending
    //     flat aliases handled below).
    var found_tid: ?TypeId = null;
    var flat_type_count: usize = 0;
    var flat_has_unregistered = false;
    for (author_set.flat) |fa| {
        const is_type = switch (fa.raw) {
            .const_decl => blk: {
                if (constWrappedNamedTypeRef(fa.raw.const_decl) != null) break :blk true;
                if (self.program_index.type_aliases_by_source.get(fa.source)) |inner|
                    break :blk inner.contains(name);
                break :blk false;
            },
            else => isNamedTypeKind(fa.raw),
        };
        if (!is_type) continue;
        flat_type_count += 1;
        const fa_tid: ?TypeId = switch (fa.raw) {
            .const_decl => blk: {
                if (constWrappedNamedTypeRef(fa.raw.const_decl) != null)
                    break :blk self.namedRefTid(fa.raw, name);
                if (self.program_index.type_aliases_by_source.get(fa.source)) |inner|
                    break :blk inner.get(name);
                break :blk null;
            },
            else => self.namedRefTid(fa.raw, name),
        };
        if (fa_tid) |t| {
            if (found_tid) |f| {
                if (t != f) return .ambiguous;
            } else found_tid = t;
        } else {
            flat_has_unregistered = true;
        }
    }
    if (flat_type_count > 0) {
        if (found_tid) |t| return .{ .resolved = t };
        return .forward; // flat author exists but TypeId not yet registered
    }

    // 1c. Pending flat aliases (const_decl in a flat-imported module but not
    //     yet resolved in type_aliases_by_source — the forward-alias fixpoint
    //     will settle these).
    for (author_set.flat) |fa| {
        if (fa.raw == .const_decl) {
            if (self.program_index.type_aliases_by_source.get(fa.source)) |inner| {
                if (inner.get(name)) |tid| return .{ .resolved = tid };
            }
            return .pending;
        }
    }

    // 2. A block-local type (declared inside a fn / init body) clobbers the
    //    global entry for its name, so `existing` IS that local type. A local is
    //    visible ONLY in its OWN source. Resolve it ungated when the query
    //    originates in the local's source: a legitimately-scoped local must
    //    not be rejected just because a namespaced-only import also authors a
    //    top-level type of the same name. When the same name is a block-local of a
    //    DIFFERENT source — e.g. an imported template's field naming a type the
    //    CALLER declared block-local — the local is NOT visible here.
    if (self.localTypeInSource(from, name)) {
        if (registered) |existing| return .{ .resolved = existing };
    } else if (self.localTypeInAnySource(name)) {
        return .undeclared; // local in another source; no pending alias possible here
    }

    // 3. Authored as a TYPE (named OR alias) in some module, but NOT flat-
    //    import-reachable from `from` → reachable only over a namespace edge.
    if (self.nameAuthoredAsTypeAnywhere(name)) return .not_visible;

    // 4. Not a cross-module type author. A registered generic type-param bound
    //    or fabricated empty-struct stub resolves ungated.
    if (registered) |existing| return .{ .resolved = existing };
    return .undeclared;
}

/// TRUE iff `raw` declares a NAMED TYPE — struct / enum / union / error-set /
/// protocol / runtime class. A `fn_decl`, a value-or-alias `const_decl`, and a
/// `namespace_decl` are NOT named types. A type ALIAS is a `const_decl`;
/// it is recognised via `type_aliases_by_source` separately from named types.
pub fn isNamedTypeKind(raw: resolver_mod.RawDeclRef) bool {
    return switch (raw) {
        .struct_decl, .enum_decl, .union_decl, .error_set_decl, .protocol_decl, .runtime_class_decl => true,
        .const_decl => |cd| constWrappedNamedTypeRef(cd) != null,
        .fn_decl, .var_decl, .namespace_decl => false,
    };
}

/// A surface named type definition written with `::` is represented in raw
/// import facts as a const declaration whose value is the actual nominal AST
/// declaration. Recover that declaration so source-aware type selection can
/// use `type_decl_tids`, exactly like a bare nominal declaration.
fn constWrappedNamedTypeRef(cd: *const ast.ConstDecl) ?resolver_mod.RawDeclRef {
    return switch (cd.value.data) {
        .struct_decl => .{ .struct_decl = &cd.value.data.struct_decl },
        .enum_decl => .{ .enum_decl = &cd.value.data.enum_decl },
        .union_decl => .{ .union_decl = &cd.value.data.union_decl },
        .error_set_decl => .{ .error_set_decl = &cd.value.data.error_set_decl },
        else => null,
    };
}

/// The per-decl nominal TypeId of a NAMED-type `RawDeclRef` author, or null
/// when its slot is not registered yet (a forward / self reference resolved
/// mid-registration → the caller yields the legacy empty-struct stub). A
/// STRUCT resolves first through its `type_decl_tids` nominal identity (E2)
/// keyed by the raw-facts decl pointer, so two same-name struct authors in
/// different sources resolve to their OWN distinct TypeIds. A
/// `type_decl_tids` MISS falls back to the global `findByName` — correct for a
/// SINGLE-author struct registered via a non-`internNamedTypeDecl` path (a
/// `struct #compiler`, a protocol-backed struct, a generic instance) or before
/// it registers; a genuine same-name SHADOW always registers through
/// `internNamedTypeDecl` and so is in `type_decl_tids`, never reaching the
/// fallback. ENUM and UNION resolve the same per-decl way (E6a): registered
/// through `internNamedTypeDecl` (`registerEnumDecl` / `registerUnionDecl`),
/// keyed by the raw-facts decl pointer, with the `findByName` fallback for a
/// single author registered before its slot lands. Error-set and nullary
/// protocol declarations likewise prefer their per-decl slots; runtime
/// classes retain the legacy name lookup.
pub fn namedRefTid(self: *Lowering, ref: resolver_mod.RawDeclRef, name: []const u8) ?TypeId {
    const table = &self.module.types;
    return switch (ref) {
        .struct_decl => |d| (table.type_decl_tids.get(@ptrCast(d)) orelse table.findByName(table.internString(name))),
        .enum_decl => |d| (table.type_decl_tids.get(@ptrCast(d)) orelse table.findByName(table.internString(name))),
        .union_decl => |d| (table.type_decl_tids.get(@ptrCast(d)) orelse table.findByName(table.internString(name))),
        // Error sets now carry per-decl nominal identity (issue 0134), so prefer
        // the own author's reserved TypeId over the name-keyed first-author
        // `findByName` — mirroring the struct/enum/union arms above. A set that
        // was not decl-registered (no `type_decl_tids` entry) falls back to the
        // name lookup, byte-identical to pre-0134.
        .error_set_decl => |d| (table.type_decl_tids.get(@ptrCast(d)) orelse table.findByName(table.internString(name))),
        .protocol_decl => |d| (table.type_decl_tids.get(@ptrCast(d)) orelse table.findByName(table.internString(name))),
        .runtime_class_decl => table.findByName(table.internString(name)),
        .const_decl => |d| if (constWrappedNamedTypeRef(d)) |inner| self.namedRefTid(inner, name) else null,
        .fn_decl, .var_decl, .namespace_decl => null,
    };
}

/// TRUE iff `name` is authored as a TYPE — a NAMED type OR a type ALIAS — in
/// ANY module's raw facts. The leak detector: a name that is a type author
/// somewhere but not flat-visible from the querying module is reachable only
/// over a namespace edge. Both kinds are checked (R4): named types via
/// `module_decls`, aliases via E0's `type_aliases_by_source`. Distinguishes a
/// real cross-module TYPE author from a LOCAL type / generic-param /
/// fabricated empty-struct stub (findByName-registered but authored in no
/// module) and from a same-name VALUE/FUNCTION author (not a type). Unwired
/// facts → false (nothing to gate; resolve ungated).
pub fn nameAuthoredAsTypeAnywhere(self: *Lowering, name: []const u8) bool {
    if (self.program_index.module_decls) |decls| {
        var it = decls.valueIterator();
        while (it.next()) |m| {
            if (m.names.get(name)) |ref| if (isNamedTypeKind(ref)) return true;
        }
    }
    var ait = self.program_index.type_aliases_by_source.valueIterator();
    while (ait.next()) |inner| {
        if (inner.contains(name)) return true;
    }
    return false;
}

/// Record a name declared as a BLOCK-LOCAL type so the bare-TYPE gate never
/// mistakes it for a namespaced-only leak (see `local_type_names`). Keyed by the
/// declaring source (the function being lowered) so the local is visible only
/// within that source.
pub fn recordLocalTypeName(self: *Lowering, name: []const u8) void {
    const src = self.current_source_file orelse self.main_file orelse return;
    const gop = self.local_type_names.getOrPut(src) catch return;
    if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(std.heap.page_allocator);
    gop.value_ptr.put(name, {}) catch {};
}

/// TRUE iff `name` is a block-local type declared in `source`.
pub fn localTypeInSource(self: *Lowering, source: []const u8, name: []const u8) bool {
    if (self.local_type_names.get(source)) |inner| return inner.contains(name);
    return false;
}

/// TRUE iff `name` is a block-local type declared in ANY source. A name that is a
/// local SOMEWHERE but not in the querying source is a cross-source local — not
/// visible from the querying source.
pub fn localTypeInAnySource(self: *Lowering, name: []const u8) bool {
    var it = self.local_type_names.valueIterator();
    while (it.next()) |inner| if (inner.contains(name)) return true;
    return false;
}

/// Resolve the bare TYPE leaf to a `TypeId` for `resolveTypeWithBindings`.
/// Routes through the source-aware `selectNominalLeaf`. `.pending` (forward
/// alias) and `.forward` (a real author not interned yet — self / forward /
/// extern reference) keep the empty-struct stub, which the type ADOPTS on
/// registration (`internNamedTypeDecl`). `.undeclared` (NO author anywhere)
/// is genuinely-undeclared: in a NON-main module — which the
/// `UnknownTypeChecker` trusts and never walks — the leaf is the only guard,
/// so it emits "unknown type" and poisons with `.unresolved` (never a silent
/// 0-field struct). In the MAIN file the checker owns the diagnostic (and a
/// valid unbound generic leaf legitimately reaches here), so the leaf keeps
/// the legacy stub. `.not_visible` / `.ambiguous` surface their own loud
/// diagnostic + `.unresolved`. When the source context is unwired
/// (`current_source_file` null — comptime / registration callers), there is no
/// querying module to collect from, so fall open to the legacy namer.
pub fn resolveNominalLeaf(self: *Lowering, name: []const u8, raw: bool, span: ?ast.Span) TypeId {
    const from = self.current_source_file orelse
        return self.typeResolver().resolveName(name, raw);
    return switch (self.selectNominalLeaf(name, from, raw)) {
        .resolved => |t| t,
        // A forward alias (`.pending`) or a forward / not-yet-interned named
        // author (`.forward`) — keep the empty-struct stub the type adopts
        // when it registers. A raw or non-raw bare name both land the same
        // stub here.
        .pending, .forward => self.module.types.intern(.{ .@"struct" = .{
            .name = self.module.types.internString(name),
            .fields = &.{},
        } }),
        // Genuinely undeclared: no type / alias / const author anywhere.
        .undeclared => {
            // The MAIN file is the `UnknownTypeChecker`'s domain — it emits
            // the canonical "unknown type" (with scope context + value-param
            // hints) and `hasErrors` halts before the stub reaches codegen,
            // and a valid unbound generic leaf (`-> T` on a template) also
            // lands here — so keep the legacy stub and do NOT double-report.
            // A NON-main (imported / library) module is checker-trusted, so
            // this leaf is the sole guard: emit + poison with `.unresolved`.
            const is_main = if (self.main_file) |mf| std.mem.eql(u8, from, mf) else true;
            if (is_main) return self.module.types.intern(.{ .@"struct" = .{
                .name = self.module.types.internString(name),
                .fields = &.{},
            } });
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "unknown type '{s}'", .{name});
            return .unresolved;
        },
        // Registered, but reachable only through a namespaced import: emit the
        // diagnostic at the reference and poison the result so no downstream
        // check (field access, size) trusts a leaked / mis-sized type.
        // `.unresolved` is poison-suppressed, so there is no secondary
        // "field not found" cascade.
        .not_visible => {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "type '{s}' is not visible; #import the module that declares it", .{name});
            return .unresolved;
        },
        // ≥2 distinct same-name type authors flat-visible, none own (issue
        // 0105 case 4): a genuine collision the source can't disambiguate.
        // Emit a loud diagnostic and poison — never a silent first-/last-wins.
        .ambiguous => {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "type '{s}' is ambiguous: it is declared in multiple flat-imported modules; qualify the reference or remove the duplicate import", .{name});
            return .unresolved;
        },
    };
}

/// The `*FnDecl` a raw author wraps, or null when the author is not a
/// function — unwraps a `RawDeclRef` so the collector's all-domain authors
/// yield a fn-only view (a `const`-wrapped fn unwraps to its inner fn; every
/// other domain → null). The single place function authors are read out of
/// the `module_decls` raw facts.
pub fn fnDeclOfRaw(ref: resolver_mod.RawDeclRef) ?*const ast.FnDecl {
    return switch (ref) {
        .fn_decl => |fd| fd,
        .const_decl => |cd| if (cd.value.data == .fn_decl) &cd.value.data.fn_decl else null,
        else => null,
    };
}

/// The `*StructDecl` a raw author wraps, or null when the author is not a
/// struct — a top-level `Box :: struct(...)` is recorded either as a bare
/// `struct_decl` RawDeclRef or a `const_decl` whose value is one, so both
/// unwrap to the same decl (mirrors `qualifiedStructTemplate`'s own-decl walk).
pub fn structDeclOfRaw(ref: resolver_mod.RawDeclRef) ?*const ast.StructDecl {
    return switch (ref) {
        .struct_decl => |sd| sd,
        .const_decl => |cd| if (cd.value.data == .struct_decl) &cd.value.data.struct_decl else null,
        else => null,
    };
}

/// The single bare-VISIBLE generic-struct author selected by
/// `bareVisibleStructDecl`: the `StructDecl` plus the source that DECLARED it.
pub const VisibleStructAuthor = struct {
    sd: *const ast.StructDecl,
    source: []const u8,
};

/// The `fn_decl` of struct `sd`'s method named `method`, or null when `sd`
/// declares no such method. Used to source-pin a static-method head's body to
/// the bare-visible author's own method (`b.Box.make`), bypassing the name-keyed
/// last-wins `fn_ast_map` ("Box.make") that a 2-flat-hop same-name template's
/// method would otherwise win (E4 #1, static-method site).
/// The suffix that distinguishes a `#set` accessor's EFFECTIVE method name from
/// the read name it shares with a same-name `#get`. `$` can never appear in an
/// sx identifier (it is the comptime-param sigil), so `len$set` is an
/// unmistakable, symbol-safe key that cannot collide with any user method name
/// — yet it keeps the getter under the plain `len`, so registration / mangling /
/// dispatch keep BOTH accessors of a get+set pair distinct. See
/// `accessorEffName` / `accessorNameMatches`.
pub const setter_eff_suffix = "$set";

/// The name a method is REGISTERED / MANGLED / DISPATCHED under: a `#set`
/// accessor is keyed as `name$set` so it never clobbers the same-name `#get`
/// (which keeps its plain `name`); every other method keeps its own name.
pub fn accessorEffName(self: *Lowering, fd: *const ast.FnDecl) []const u8 {
    if (!fd.is_set) return fd.name;
    return std.fmt.allocPrint(self.alloc, "{s}" ++ setter_eff_suffix, .{fd.name}) catch fd.name;
}

/// True when method `fd` is the one a name-keyed lookup for `query` should
/// resolve to. A `name$set` query resolves ONLY the `#set` accessor named
/// `name`; a plain `name` query resolves any NON-setter (a `#get` accessor or an
/// ordinary method), never a setter. This makes get/set coexistence
/// declaration-order-independent (the read query picks the getter, the
/// `…$set` write query picks the setter) without an overload table.
pub fn accessorNameMatches(fd: *const ast.FnDecl, query: []const u8) bool {
    if (std.mem.endsWith(u8, query, setter_eff_suffix)) {
        if (!fd.is_set) return false;
        return std.mem.eql(u8, fd.name, query[0 .. query.len - setter_eff_suffix.len]);
    }
    if (fd.is_set) return false;
    return std.mem.eql(u8, fd.name, query);
}

pub fn structMethodFn(sd: *const ast.StructDecl, method: []const u8) ?*const ast.FnDecl {
    for (sd.methods) |mn| {
        if (mn.data == .fn_decl and accessorNameMatches(&mn.data.fn_decl, method))
            return &mn.data.fn_decl;
    }
    return null;
}

/// TRUE iff `ref` is a TYPE-FUNCTION head author — a `fn_decl` (or const-
/// wrapped fn) declaring at least one `$`-parameter, i.e. instantiable as a
/// bare type head (`Make(i64)` where `Make :: ($T) -> Type`). Mirrors the
/// `fd.type_params.len > 0` gate every instantiation site uses to recognize a
/// type-fn head, so an ORDINARY same-name function (`Make :: () -> i32`, zero
/// type params) is NOT a type-fn author and does NOT vouch for a hidden 2-flat-
/// hop type-fn head (E4 attempt-8: a `fn_decl != null` author view let any
/// visible function — type-fn or not — authorize a type head).
pub fn typeFnAuthor(ref: resolver_mod.RawDeclRef) bool {
    const fd = fnDeclOfRaw(ref) orelse return false;
    return fd.type_params.len > 0;
}

/// Materialize (lower-on-demand) the FuncId for a selected bare-call author,
/// caching into `sf.materialized`. Shadow-only: the winner owns the
/// name-keyed slot and lowers through the lazy path, so
/// `selectPlainCallableAuthor` returns `.none` for it and this is never asked
/// to lower the winner (0102d). `name` is the call name (== the author's
/// registered name); `sf.source` pins the author's own visibility context.
pub fn selectedFuncId(self: *Lowering, sf: *SelectedFunc, name: []const u8) FuncId {
    if (sf.materialized) |fid| return fid;
    const fid = self.bareAuthorFuncId(sf.decl, name, sf.source);
    sf.materialized = fid;
    return fid;
}

/// The FuncId for a resolved bare-call author, ensuring its body is lowered.
/// Only ever called for a SHADOW (an author that is not the name-keyed
/// winner): the winner owns the name-keyed slot and lowers through the
/// normal lazy path, so `selectPlainCallableAuthor` returns `.none` for it. A shadow
/// is declared a fresh same-name FuncId in its OWN module's visibility
/// context and its body lowered into that slot via the identity-
/// addressable `lowerFunctionBodyInto`. Idempotent: `lowered_fids` tracks
/// which slots already carry a body.
pub fn bareAuthorFuncId(self: *Lowering, fd: *const ast.FnDecl, name: []const u8, path: []const u8) FuncId {
    if (self.fn_decl_fids.get(fd)) |fid| {
        if (!self.lowered_fids.contains(fid)) {
            self.lowered_fids.put(fid, {}) catch {};
            self.lowerFunctionBodyInto(fd, fid, name);
        }
        return fid;
    }
    const saved_src = self.current_source_file;
    self.setCurrentSourceFile(path);
    self.declareFunction(fd, name);
    self.setCurrentSourceFile(saved_src);
    const fid = self.fn_decl_fids.get(fd).?;
    self.lowered_fids.put(fid, {}) catch {};
    self.lowerFunctionBodyInto(fd, fid, name);
    return fid;
}

/// Walk a return-type expression for a `$T` generic leaf, returning the
/// first generic name found. The parser builds `fd.type_params` from
/// PARAMS only (`collectTypeParams`), so a `$`-generic that appears ONLY
/// in the return type makes the fn look non-generic while its return can
/// never be bound — `declareFunction` rejects that shape loudly.
fn returnGenericLeaf(node: *const Node) ?[]const u8 {
    return switch (node.data) {
        .type_expr => |te| if (te.is_generic) te.name else null,
        .pointer_type_expr => |pte| returnGenericLeaf(pte.pointee_type),
        .many_pointer_type_expr => |mpte| returnGenericLeaf(mpte.element_type),
        .slice_type_expr => |ste| returnGenericLeaf(ste.element_type),
        .array_type_expr => |ate| returnGenericLeaf(ate.element_type),
        .optional_type_expr => |ote| returnGenericLeaf(ote.inner_type),
        .parameterized_type_expr => |pte| {
            for (pte.args) |arg| if (returnGenericLeaf(arg)) |n| return n;
            return null;
        },
        .tuple_type_expr => |tte| {
            for (tte.field_types) |ft| if (returnGenericLeaf(ft)) |n| return n;
            return null;
        },
        .closure_type_expr => |cte| {
            for (cte.param_types) |pt| if (returnGenericLeaf(pt)) |n| return n;
            if (cte.return_type) |rt| return returnGenericLeaf(rt);
            return null;
        },
        .function_type_expr => |fte| {
            for (fte.param_types) |pt| if (returnGenericLeaf(pt)) |n| return n;
            if (fte.return_type) |rt| return returnGenericLeaf(rt);
            return null;
        },
        else => null,
    };
}

/// Declare a function as an extern stub (signature only, no body).
/// The same C SYMBOL declared more than once (two modules binding the same
/// libc function, or a rename colliding with an existing binding): an EQUAL
/// signature shares the first registration; a CONFLICTING one is diagnosed —
/// silently letting the first registration win mis-types every call through
/// the later declaration (a `-> string` view of a symbol registered `-> *u8`
/// reads the wrong shape; issue 0128). True = handled (shared or diagnosed),
/// caller must not declare again.
pub fn dedupeExternSymbol(self: *Lowering, fd: *const ast.FnDecl, sym_name: StringId, params: []const Function.Param, ret_ty: TypeId) bool {
    for (self.module.functions.items, 0..) |*func, i| {
        if (func.name != sym_name or !func.is_extern) continue;
        var same = func.ret == ret_ty and func.params.len == params.len;
        if (same) {
            for (func.params, params) |a, b| {
                if (a.ty != b.ty) {
                    same = false;
                    break;
                }
            }
        }
        if (same) {
            self.fn_decl_fids.put(fd, FuncId.fromIndex(@intCast(i))) catch {};
            return true;
        }
        if (self.diagnostics) |d| {
            d.addFmt(.err, fd.body.span, "extern symbol '{s}' is already bound with a different signature; two views of one C symbol must declare identical types", .{self.module.types.getString(sym_name)});
        }
        return true;
    }
    return false;
}

pub fn declareFunction(self: *Lowering, fd: *const ast.FnDecl, name: []const u8) void {
    // An `intrinsic` body binds to the registry (`ir/intrinsics.zig`) by
    // (module, name). Validate here — above the generic-template guard, since
    // most intrinsics are `$T`-generic and would otherwise skip the check —
    // so an unregistered or wrong-arity declaration is a diagnostic at its own
    // span rather than a call-site failure in some later pass.
    if (fd.body.data == .intrinsic_expr) validateIntrinsicDecl(self, fd, name);

    // Skip generic templates — they're monomorphized on demand, not declared as extern
    if (fd.type_params.len > 0) return;

    const ret_ty = self.resolveReturnType(fd);

    // A `$T`-generic return with NO parameter mentioning `$T`: the fn isn't
    // a template (the guard above runs on param-derived `type_params`) yet
    // its return can never be bound by any call site. Declaring it would
    // carry the `.unresolved` sentinel into LLVM emission and panic the
    // tripwire — diagnose at the declaration instead. Named unknown types
    // (`-> Bogus`) are covered by the semantic pass's "unknown type".
    if (ret_ty == .unresolved) {
        if (fd.return_type) |rtn| {
            if (returnGenericLeaf(rtn)) |gen_name| {
                if (self.diagnostics) |d| {
                    d.addFmt(.err, rtn.span, "generic return type '${s}' cannot be bound — '{s}' has no parameter mentioning '${s}', so no call site can infer it", .{ gen_name, name, gen_name });
                }
                return;
            }
        }
    }

    // Extern declarations with a trailing variadic param map to the C
    // calling convention's `...` tail. Drop the variadic param from the
    // IR signature (it has no C-level slot) and set is_variadic.
    // Bare `extern` import: an external C symbol declared via the `extern`
    // linkage keyword (empty-block placeholder body). C-ABI promotion +
    // declareExtern routing below; the optional `extern LIB "csym"` lib/rename
    // axis is extern_lib/extern_name. (`export` defines take the beginFunction
    // path, not here.) The `#import c` auto-synthesis also produces this shape.
    // An `evaluate`-mode intrinsic is declared-not-defined for the same reason an
    // `extern` import is: the implementation lives outside the sx body — here, in
    // the VM handler the registry names.
    const is_extern_decl = fd.extern_export == .extern_ or
        isEvaluateIntrinsic(self, fd, name);
    var is_variadic = false;
    var effective_params = fd.params;
    // A lib-less C-import with a C-variadic `...` tail: drop the trailing slice
    // param and set is_variadic (mirrored at the call site by
    // `packVariadicCallArgs`).
    if (is_extern_decl and fd.params.len > 0 and fd.params[fd.params.len - 1].is_variadic) {
        is_variadic = true;
        effective_params = fd.params[0 .. fd.params.len - 1];
    }

    const wants_ctx = self.funcWantsImplicitCtx(fd);
    var params = std.ArrayList(Function.Param).empty;
    if (wants_ctx) {
        params.append(self.alloc, .{
            .name = self.module.types.internString("__sx_ctx"),
            .ty = self.module.types.ptrTo(.void),
        }) catch unreachable;
    }
    for (effective_params, 0..) |p, i| {
        // A synthesized protocol-default method carries an exact concrete
        // receiver registered before declaration. Its body/signature otherwise
        // belongs to the protocol module, where text-resolving `*Target` can
        // be invisible or select a different same-display-name declaration.
        const pty = if (i == 0)
            self.protocol_impl_receiver_types.get(fd) orelse self.resolveParamType(&p)
        else
            self.resolveParamType(&p);
        params.append(self.alloc, .{
            .name = self.module.types.internString(p.name),
            .ty = pty,
        }) catch unreachable;
    }

    // `extern` declarations are external C symbols by definition — promote
    // them to abi(.c) when the user didn't write it explicitly. This keeps
    // fn-ptr coercion type-safe: anything typed by name as `(args) -> ret` of an
    // `extern` decl can be assigned to / passed as a `abi(.c)` fn-pointer
    // without a call-convention mismatch.
    const cc: Function.CallingConvention = if (fd.abi == .c or is_extern_decl or fd.extern_export == .export_) .c else .default;

    // Symbol-name override: `extern … "csym"` / `export … "csym"` (fd.extern_name).
    // Declare under the C name and map the sx name → C name so call sites resolve
    // to the real symbol. For `export` the stub is later promoted to a real
    // definition (the body lowers into this C-named function via lazyLowerFunction).
    const is_export_decl = fd.extern_export == .export_;
    const rename_c_name: ?[]const u8 = if (is_extern_decl or is_export_decl)
        fd.extern_name
    else
        null;
    if (rename_c_name) |c_name| {
        const c_name_id = self.module.types.internString(c_name);
        if (self.dedupeExternSymbol(fd, c_name_id, params.items, ret_ty)) {
            self.extern_name_map.put(name, c_name) catch {};
            return;
        }
        const fid = self.builder.declareExtern(c_name_id, params.items, ret_ty);
        const func = self.module.getFunctionMut(fid);
        func.call_conv = cc;
        func.source_file = self.current_source_file;
        func.is_variadic = is_variadic;
        func.has_implicit_ctx = wants_ctx;
        func.is_naked = (fd.abi == .naked);
        func.is_get = fd.is_get;
        func.is_set = fd.is_set;
        self.extern_name_map.put(name, c_name) catch {};
        self.fn_decl_fids.put(fd, fid) catch {};
        return;
    }

    const name_id = self.module.types.internString(name);
    if (is_extern_decl and self.dedupeExternSymbol(fd, name_id, params.items, ret_ty)) return;
    const fid = self.builder.declareExtern(name_id, params.items, ret_ty);
    const func = self.module.getFunctionMut(fid);
    func.call_conv = cc;
    func.source_file = self.current_source_file;
    func.is_variadic = is_variadic;
    func.has_implicit_ctx = wants_ctx;
    func.is_naked = (fd.abi == .naked);
    func.is_get = fd.is_get;
    func.is_set = fd.is_set;
    // An intrinsic has no symbol at all — the backend must not declare it.
    if (fd.body.data == .intrinsic_expr) func.is_intrinsic = true;

    // A non-generic `-> Type` builder is a comptime type constructor — only ever
    // evaluated at lowering time (`runComptimeTypeFunc`) to mint a type, never
    // called at runtime. Flag it `is_comptime` so its emitted body is dead: the
    // comptime-only `compiler`-library gate then permits welded calls inside it
    // (`register_type`/`declare_type`/`pointer_to`), exactly as in a #run/`::`
    // wrapper. Without this, a builder that calls a welded fn would be rejected
    // as "comptime-only fn called at runtime" even though it never runs at runtime.
    if (fnReturnsTypeValue(fd)) func.comptime_role = .type_builder;
    self.fn_decl_fids.put(fd, fid) catch {};
}

/// Validate an `intrinsic` declaration against the registry. The registry IS the
/// allow-list: a name it does not carry has no handler anywhere, so accepting the
/// declaration would defer the failure to a call site (or, worse, to a recognizer
/// that silently does the wrong thing). Diagnose at the declaration span instead.
///
/// The binding key is (module, name) — `size_of` is an intrinsic because
/// std/core.sx declares it, not because the name is magic. A same-named
/// declaration in another module is a different function and is rejected here.
fn validateIntrinsicDecl(self: *Lowering, fd: *const ast.FnDecl, name: []const u8) void {
    const span = if (fd.name_span.end != 0) fd.name_span else fd.body.span;
    const entry = intrinsics.find(name, self.current_source_file) orelse {
        // Registered under a DIFFERENT module? Then the name is real but this
        // declaration is in the wrong place — say so, rather than "unknown".
        if (intrinsics.find(name, null)) |other| {
            if (self.diagnostics) |d| d.addFmt(.err, span, "intrinsic '{s}' is declared by {s}, not by this module", .{ name, other.module });
        } else if (self.diagnostics) |d| {
            d.addFmt(.err, span, "unknown intrinsic '{s}'", .{name});
        }
        return;
    };
    if (fd.params.len != entry.arity) {
        if (self.diagnostics) |d| d.addFmt(.err, span, "intrinsic '{s}' expects {d} parameter{s}, declared with {d}", .{
            name, entry.arity, if (entry.arity == 1) @as([]const u8, "") else "s", fd.params.len,
        });
    }
}

/// An `evaluate`-mode intrinsic: a declaration the comptime evaluator services
/// itself (`Vm.callCompilerFn`) rather than one lowering folds or lowers to ops.
/// Declared-not-defined, like an `extern` import — the VM handler IS the body.
///
/// The registry is the allow-list; `validateIntrinsicDecl` has already diagnosed
/// an unregistered or misplaced name against its own span, so this only asks
/// "which kind is it?" and never reports.
pub fn isEvaluateIntrinsic(self: *Lowering, fd: *const ast.FnDecl, name: []const u8) bool {
    if (fd.body.data != .intrinsic_expr) return false;
    const e = intrinsics.find(name, self.current_source_file) orelse return false;
    return e.mode == .evaluate;
}

/// Register a namespaced import's OWN functions under their module-qualified
/// name (`ns.fn`), giving each a UNIQUE FuncId in the function table. Two
/// modules each exporting a top-level `parse` otherwise collide in the
/// bare-name `fn_ast_map` / function table (last-wins) while `resolveFuncByName`
/// picks the first declared, so `lazyLowerFunction` lowers one signature
/// against the other's body and trips its param-count assert.
/// The bare recursion in `scanDecls` still registers intra-module bare calls;
/// this adds the qualified identity the `pkg.fn(...)` resolution paths in
/// `CallResolver.plan` / `lowerCall` already prefer.
pub fn registerNamespaceQualifiedFns(self: *Lowering, ns_name: []const u8, own_decls: []const *Node) void {
    const saved_source = self.current_source_file;
    defer self.setCurrentSourceFile(saved_source);
    for (own_decls) |decl| {
        self.setCurrentSourceFile(decl.source_file);
        switch (decl.data) {
            .fn_decl => self.registerQualifiedFn(ns_name, &decl.data.fn_decl, decl.data.fn_decl.name),
            .const_decl => |cd| {
                if (cd.value.data == .fn_decl) {
                    self.registerQualifiedFn(ns_name, &cd.value.data.fn_decl, cd.name);
                }
            },
            else => {},
        }
    }
}

pub fn registerQualifiedFn(self: *Lowering, ns_name: []const u8, fd: *const ast.FnDecl, short: []const u8) void {
    // Only PLAIN free functions need a qualified identity. Generic /
    // comptime / pack functions (`Vector`, `print`, `any_to_string`) are
    // dispatched by monomorphization off their BARE template name, not the
    // plain `resolveFuncByName` / `lazyLowerFunction` path that trips the
    // collision assert; registering a qualified alias for them
    // would divert that machinery and strand a per-call type binding.
    if (fd.type_params.len > 0 or hasComptimeParams(fd) or isPackFn(fd)) return;
    // Extern / builtin bodies keep their literal name; a qualified alias has
    // no distinct symbol to resolve to.
    switch (fd.body.data) {
        .intrinsic_expr => return,
        else => {},
    }
    const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ ns_name, short }) catch return;
    if (self.program_index.fn_ast_map.contains(qualified)) return;
    self.program_index.fn_ast_map.put(qualified, fd) catch {};
    self.program_index.import_flags.put(qualified, true) catch {};
    // Carry the alias's OWN declaring source file (the caller in
    // `registerNamespaceQualifiedFns` pins `current_source_file` to the
    // decl's source before each call). `lazyLowerFunction`'s null-FuncId
    // path restores this so `ns.fn`'s body lowers in its own module's
    // visibility context, not the call site's.
    if (self.current_source_file) |src| {
        self.program_index.qualified_fn_source.put(qualified, src) catch {};
    }
    // No eager `declareFunction` here: the extern stub's param/return types
    // would be resolved now, before the forward-alias fixpoint, caching an
    // `.unresolved` for any type declared later in the module. The qualified
    // function is declared + lowered on demand by `lazyLowerFunction`'s
    // null-FuncId path (`lowerFunction`), which runs after all types resolve.
}

/// The unified non-transitive `#import` visibility predicate, parameterized
/// by `VisibilityMode`. `isNameVisible` / `isCImportVisible` are thin
/// adapters over it.
///
/// This is the lowering-side GATE: it walks `module_scopes` (the per-file
/// name set) joined over the edge set the mode selects. It is distinct from
/// `resolver.collectVisibleAuthors`, which collects raw AUTHORS over
/// `module_decls` — the single graph-walk that lives in `resolver.zig`. The
/// two read different facts (name set vs author refs) for different jobs, so
/// the gate's own iterator stays here, not in the resolver.
///
/// `module_scopes[F]` holds ONLY the names authored in F (plus its namespace
/// aliases); cross-module visibility is joined here at query time. Doing the
/// join at lookup (instead of pre-merging in `resolveImports`) lets cyclic
/// imports like std.sx ↔ allocators.sx still resolve, since the cycle's
/// skipped edge is still recorded in the graph and the partner's scope is
/// filled in by the time lowering queries it.
pub fn isVisible(self: *Lowering, name: []const u8, vis: resolver_mod.VisibilityMode) bool {
    switch (vis) {
        // Registration / lazy lowering paths don't police user visibility.
        .lowering_internal => return true,
        // Transitive visibility is ProtocolResolver.findVisibleImpls' job;
        // this predicate is single-hop only.
        .impl_transitive => @panic("isVisible: transitive visibility is owned by findVisibleImpls"),
        .c_import_bare => {
            // Extern-C gate: only a lib-less C-import fn_decl is policed; a
            // library-bound `extern LIB` decl (resolves via the named library,
            // not a module edge) or a non-extern body is unconditionally
            // visible. A lib-less `extern` decl routes to `visibleOverEdges` so
            // a transitive reference gets the "C function not visible"
            // diagnostic, not the generic top-level-name wording (example 1228).
            const fd = self.program_index.fn_ast_map.get(name) orelse return true;
            if (fd.extern_export != .extern_) return true;
            if (fd.extern_lib != null) return true;
            return self.visibleOverEdges(name);
        },
        .user_bare_flat => return self.visibleOverEdges(name),
    }
}

/// Run the per-file visibility walk over the flat-import edge set. Falls
/// open (visible) when the scoping infrastructure isn't wired (comptime
/// callers, directory imports without main_file, etc.). The caller is
/// responsible for restricting the check to names that ARE known top-level
/// decls; otherwise every local variable would be policed.
pub fn visibleOverEdges(self: *Lowering, name: []const u8) bool {
    const source = self.current_source_file orelse return true;
    return nameVisibleOverEdges(self.program_index.module_scopes, self.program_index.flat_import_graph, source, name);
}

/// Check if a C-imported function is visible from the current source file.
/// Returns true for non-C functions (always visible) or if no scoping info
/// available. Byte-identical adapter over `isVisible`.
pub fn isCImportVisible(self: *Lowering, fn_name: []const u8) bool {
    return self.isVisible(fn_name, .c_import_bare);
}

/// Non-transitive `#import` visibility check for top-level decls.
/// Byte-identical adapter over `isVisible`.
pub fn isNameVisible(self: *Lowering, name: []const u8) bool {
    // The `__sx_` prefix is the compiler-reserved namespace: those calls are
    // compiler REWRITES (assertion desugars → fmt.sx's __sx_cast_* runtime),
    // synthesized at any lowering site — including inside std part-files that
    // do not import the declaring module. A compiler indirection is exempt
    // from the user-facing visibility gate, like UFCS rewrites.
    if (std.mem.startsWith(u8, name, "__sx_")) return true;
    return self.isVisible(name, .user_bare_flat);
}

/// Lazily lower a function body on demand. Called when lowerCall can't find
/// the function and it exists in fn_ast_map.
pub fn lazyLowerFunction(self: *Lowering, name: []const u8) void {
    // Already lowered?
    if (self.lowered_functions.contains(name)) return;

    // For sx-defined `#objc_class` methods, pin current_runtime_class
    // so `*Self` substitutions in resolveTypeWithBindings find the
    // state-struct type (M1.2 A.2b). The inline body-lowering path
    // below re-resolves param types, so the context must be set
    // BEFORE any resolveReturnType / resolveParamType call.
    const saved_fc_lazy = self.current_runtime_class;
    defer self.current_runtime_class = saved_fc_lazy;
    if (self.lookupObjcDefinedClassForMethod(name)) |fcd| {
        self.current_runtime_class = fcd;
    }
    // No AST? (builtins, extern functions, or imported functions not in this file)
    const fd = self.program_index.fn_ast_map.get(name) orelse return;
    // Extern declarations stay as extern stubs but need to be REGISTERED
    // in the current module so callers get a real FuncId. Without this,
    // a comptime-lowered function (e.g. `concat` from std.sx pulled into
    // a fresh ct_module via `evalComptimeString`) emits `.call` against a
    // FuncId that doesn't exist locally; the interp can't find the
    // extern target and silently no-ops instead of dispatching to libc.
    if (fd.extern_export == .extern_) {
        if (self.resolveFuncByName(name) == null) {
            self.declareFunction(fd, name);
            self.lowered_functions.put(name, {}) catch {};
        }
        return;
    }
    // Builtin bodies stay as compiler-handled — no extern stub needed.
    if (fd.body.data == .intrinsic_expr) return;
    if (fd.type_params.len > 0) return; // generics handled by monomorphization (Step 3.13)

    // Defer functions with type-category matches until all types are registered.
    // any_to_string uses `if type == { case slice: ... }` which compiles a switch
    // with type tags from resolveTypeCategoryTags. This must happen AFTER main is
    // fully lowered so all types ([]i32, List__i32, etc.) are in the TypeTable.
    if (!self.processing_deferred and std.mem.eql(u8, name, "any_to_string")) {
        self.deferred_type_fns.append(self.alloc, name) catch {};
        return;
    }

    // Mark as lowered before lowering (prevents infinite recursion)
    self.lowered_functions.put(name, {}) catch {};

    // Find the existing extern stub (from scanDecls), keyed by NAME — the
    // FIRST author of a name owns this slot. A shadowed same-name author is
    // not here (it has no name-keyed slot); it is lowered out-of-line into
    // its OWN FuncId by `lowerRetainedSameNameAuthors`.
    // A renamed `export … "csym"` fn was declared under its C symbol name
    // (declareFunction's rename path), so search for the stub under that name
    // and promote the body into it. `extern_name_map` only carries an entry
    // when a rename was registered; a bare export / normal define keeps its sx
    // name (Phase 2.2).
    const search_name = self.extern_name_map.get(name) orelse name;
    const name_id = self.module.types.internString(search_name);
    var func_id: ?FuncId = null;
    for (self.module.functions.items, 0..) |func, i| {
        if (func.name == name_id) {
            func_id = FuncId.fromIndex(@intCast(i));
            break;
        }
    }

    if (func_id) |fid| {
        self.lowerFunctionBodyInto(fd, fid, name);
        return;
    }

    // Function not yet declared — create it fresh via lowerFunction. A
    // module-qualified alias (`ns.fn`) is registered in
    // `fn_ast_map` without an eager `declareFunction`, so there's no
    // `Function.source_file` to switch to. Restore the alias's OWN declaring
    // source before lowering its body, otherwise it lowers in the caller's
    // visibility context and an own-import callee (`foo` calling `helper`
    // from `foo`'s module's flat import) is reported "not visible" (0100 F1).
    // The reentry guard keeps the nested lowering transparent to the caller.
    var reentry = FnBodyReentry.enter(self);
    defer reentry.restore();
    if (self.program_index.qualified_fn_source.get(name)) |src| {
        self.setCurrentSourceFile(src);
    }
    self.lowerFunction(fd, name, false);
}

/// Lower `fd`'s body into the SPECIFIC `fid`, promoting its extern stub to a
/// real function. Identity-addressable: the caller passes the exact FuncId,
/// so a SHADOWED same-name author lowers into its OWN slot instead of
/// colliding on the name-keyed `resolveFuncByName` (which returns the first
/// author, the very split that trips the param-count assert). Self-
/// contained — the `FnBodyReentry` guard makes the nested lowering
/// transparent to any in-progress caller body — so it serves
/// both `lazyLowerFunction`'s name-keyed found path and the out-of-line
/// `lowerRetainedSameNameAuthors` pass.
pub fn lowerFunctionBodyInto(self: *Lowering, fd: *const ast.FnDecl, fid: FuncId, name: []const u8) void {
    // Synthesized protocol defaults execute in their declaring impl's method
    // domain: `self.required()` must call that exact protocol requirement even
    // when the concrete type has a same-named inherent method. Recompute the
    // domain at EVERY function-body entry. This both activates it for a default
    // reached through any lowering path and clears an outer default's domain
    // while lazily lowering a nested ordinary/explicit method body.
    const saved_protocol_default_dispatch = self.protocol_default_dispatch;
    self.protocol_default_dispatch = self.protocolDefaultDispatchDomain(fd);
    defer self.protocol_default_dispatch = saved_protocol_default_dispatch;

    // objc-defined-class method context for `*Self` substitution (M1.2 A.2b);
    // the resolveReturnType / resolveParamType calls below consult it.
    const saved_fc = self.current_runtime_class;
    defer self.current_runtime_class = saved_fc;
    if (self.lookupObjcDefinedClassForMethod(name)) |fcd| {
        self.current_runtime_class = fcd;
    }

    var reentry = FnBodyReentry.enter(self);
    defer reentry.restore();

    // Re-use the existing function slot — switch builder to it. Pin the
    // function's OWN source BEFORE resolving the return type, so a same-name
    // shadowed type in the signature resolves against THIS
    // function's module rather than the caller's (which, importing two
    // same-name authors, would be ambiguous). Param types below already
    // resolve after this point.
    self.builder.func = fid;
    const func = &self.module.functions.items[@intFromEnum(fid)];
    self.setCurrentSourceFile(func.source_file);

    // `extern` imports are pure declarations — never promote the stub to a real
    // function or lower the (empty placeholder) body. Mirrors the declare-only
    // handling in lowerFunction / lazyLowerFunction. An `evaluate` intrinsic is
    // declare-only too — the VM handler is the impl.
    if (fd.extern_export == .extern_ or isEvaluateIntrinsic(self, fd, name)) return;

    const ret_ty = self.resolveReturnType(fd);

    if (!func.is_extern) {
        // Already promoted (e.g., via lowerComptimeDeps) — skip.
        return;
    }
    func.is_extern = false; // promote from extern stub to real function
    // `export` defines force external linkage + C ABI (Phase 2, gaps i+ii).
    func.linkage = if (isExportedEntryName(name) or fd.extern_export == .export_) .external else .internal;
    if (fd.abi == .c or fd.extern_export == .export_) func.call_conv = .c;
    // Set inst_counter to param count (params occupy refs 0..N-1). IR params
    // = AST params + 1 if the function carries `__sx_ctx` at slot 0.
    const ctx_slots: usize = if (func.has_implicit_ctx) 1 else 0;
    std.debug.assert(func.params.len == fd.params.len + ctx_slots);
    self.builder.inst_counter = @intCast(func.params.len);

    // Create entry block
    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);

    // Create scope and bind params
    var scope = Scope.init(self.alloc, null);
    defer scope.deinit();
    self.scope = &scope;

    // The implicit `__sx_ctx` param (when present) lives at slot 0; user
    // params shift by one. `current_ctx_ref` is bound to slot 0 so call-site
    // lowering can prepend it to every sx-to-sx call. For OS-called entry
    // points (main / JNI hooks) there's no ctx param — synthesise
    // `&__sx_default_context` and bind `current_ctx_ref` to its address.
    const wants_ctx = self.funcWantsImplicitCtx(fd);
    const saved_ctx_ref = self.current_ctx_ref;
    defer self.current_ctx_ref = saved_ctx_ref;
    const user_param_base: u32 = if (wants_ctx) 1 else 0;
    if (wants_ctx) self.current_ctx_ref = Ref.fromIndex(0);

    // An `abi(.naked)` (naked) function has no frame: its params arrive in ABI
    // registers and are read directly by the asm body (e.g. `swap_context`'s
    // `from`/`to`). Spilling them to allocas would (a) need a frame and (b) emit
    // `store i64 %0, …` — "cannot use argument of naked function" (LLVM verifier).
    // Leave the LLVM args declared-but-unused (the verifier allows that); the asm
    // references the registers.
    if (fd.abi != .naked) for (fd.params, 0..) |p, i| {
        // Protocol impl declarations already resolved their receiver in the
        // concrete target's authoring domain. In particular, a synthesized
        // default body belongs to the protocol module, so resolving its
        // synthetic `self: *Target` again here could cross-bind a same-name
        // target from another module. Reuse that exact declared receiver type.
        const pty = if (i == 0)
            self.protocol_impl_receiver_types.get(fd) orelse self.resolveParamType(&p)
        else
            self.resolveParamType(&p);
        const slot = self.builder.alloca(pty);
        const param_ref = Ref.fromIndex(@intCast(i + user_param_base));
        self.builder.store(slot, param_ref);
        scope.put(p.name, .{ .ref = slot, .ty = pty, .is_alloca = true });
    };

    // Named multi-return (`-> (x: A, y: B)`): bind the slots as in-scope locals
    // for the body to assign; `lowerValueBody` synthesizes the implicit return.
    const saved_nrn = self.named_return_names;
    const saved_nrd = self.named_return_defaults;
    self.named_return_names = null;
    self.named_return_defaults = null;
    defer {
        self.named_return_names = saved_nrn;
        self.named_return_defaults = saved_nrd;
    }
    if (fd.abi != .naked) self.bindNamedReturnSlots(fd, ret_ty, &scope);

    // Inbound entry points + abi(.c) sx functions: bind current_ctx_ref
    // to the static default before any user code runs.
    if (!wants_ctx and self.implicit_ctx_enabled) {
        if (self.program_index.global_names.get("__sx_default_context")) |dctx_gi| {
            self.current_ctx_ref = self.builder.emit(.{ .global_addr = dctx_gi.id }, self.module.types.ptrTo(.void));
        }
    }

    // Lower the function body (set target_type to return type for implicit returns)
    const saved_target = self.target_type;
    self.target_type = if (ret_ty != .void and ret_ty != .noreturn) ret_ty else null;
    if (self.builder.currentFunc().is_naked) {
        // `abi(.naked)`: the body is a single asm block that emits its own `ret`.
        // There is no sx-level value return — lower the statements and cap the
        // block with `unreachable` (control never falls back into sx). This
        // bypasses the implicit-return machinery, which would otherwise reject
        // the missing return. LLVM emission lands in B1.0b.
        self.lowerBlock(fd.body);
        if (!self.currentBlockHasTerminator()) self.builder.emitUnreachable();
    } else if (ret_ty != .void and ret_ty != .noreturn) {
        self.lowerValueBody(fd.body, ret_ty);
    } else {
        // void / noreturn: no value to return — lower as statements and let
        // `ensureTerminator` close the block (ret void / unreachable).
        self.lowerBlock(fd.body);
        self.ensureTerminator(ret_ty);
    }
    self.target_type = saved_target;

    self.builder.finalize();
}

/// Lower a single function declaration.
pub fn lowerFunction(self: *Lowering, fd: *const ast.FnDecl, name: []const u8, is_imported: bool) void {
    // For sx-defined `#objc_class` methods (qualified `<Class>.<method>`),
    // set `current_runtime_class` so `*Self` substitutions through
    // `resolveTypeWithBindings` find the state-struct type (M1.2 A.2b).
    // Save+restore — function lowering can re-enter.
    const saved_fc = self.current_runtime_class;
    defer self.current_runtime_class = saved_fc;
    if (self.lookupObjcDefinedClassForMethod(name)) |fcd| {
        self.current_runtime_class = fcd;
    }

    const name_id = self.module.types.internString(name);
    const ret_ty = self.resolveReturnType(fd);

    const wants_ctx = self.funcWantsImplicitCtx(fd);

    // Build param list. `Function.init` borrows the slice (it does not
    // dupe), so this storage must outlive the local — build it in the
    // module's slice arena (freed at module deinit) rather than via
    // `self.alloc`, which would leak (Function.deinit never frees params).
    const param_alloc = self.module.slice_arena.allocator();
    var params = std.ArrayList(Function.Param).empty;
    if (wants_ctx) {
        params.append(param_alloc, .{
            .name = self.module.types.internString("__sx_ctx"),
            .ty = self.module.types.ptrTo(.void),
        }) catch unreachable;
    }
    for (fd.params) |p| {
        const pty = self.resolveParamType(&p);
        params.append(param_alloc, .{
            .name = self.module.types.internString(p.name),
            .ty = pty,
        }) catch unreachable;
    }

    // An `intrinsic` body needs no lowering — the compiler is the implementation.
    // `extern` imports are declare-only too (empty placeholder body).
    if (fd.body.data == .intrinsic_expr or
        fd.extern_export == .extern_)
    {
        // Already declared by scanDecls/declareFunction (which handles #extern renames)
        return;
    }

    // Skip generic functions (they have type parameters and are templates, not concrete)
    if (fd.type_params.len > 0) {
        const fid = self.builder.declareExtern(name_id, params.items, ret_ty);
        self.module.getFunctionMut(fid).has_implicit_ctx = wants_ctx;
        return;
    }

    // Imported functions: declare as extern (don't lower bodies from other files)
    if (is_imported) {
        const fid = self.builder.declareExtern(name_id, params.items, ret_ty);
        self.module.getFunctionMut(fid).has_implicit_ctx = wants_ctx;
        return;
    }

    const func_id = self.builder.beginFunction(
        name_id,
        params.items,
        ret_ty,
    );
    _ = func_id;
    self.builder.currentFunc().has_implicit_ctx = wants_ctx;
    // Record the declaring source so the function carries its own module
    // for diagnostics/emit and for any later `lazyLowerFunction` re-entry
    // that switches to `func.source_file`. The caller sets
    // `current_source_file` to the decl's source before lowering.
    self.builder.currentFunc().source_file = self.current_source_file;

    // Set linkage. Default for fn defs is `internal` (LLVM DCE-friendly,
    // matches C `static`). isExportedEntryName lists the names the OS
    // loader calls — `main`, Android NativeActivity hooks — which must
    // stay externally visible.
    // `export` defines force external linkage (Phase 2, gap i) alongside
    // the OS-called entry points.
    if (isExportedEntryName(name) or fd.extern_export == .export_) {
        self.builder.currentFunc().linkage = .external;
    }

    // Set calling convention. `export` defines promote to C ABI (gap ii).
    if (fd.abi == .c or fd.extern_export == .export_) {
        self.builder.currentFunc().call_conv = .c;
    }

    // Create entry block
    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);

    // Create scope and bind params. A NESTED `::` static fn (lowered while an
    // enclosing body's scope is still current) keeps its parent chain so
    // sibling nested fns + comptime consts resolve, but is flagged a fn
    // boundary: a plain value binding read across it is an enclosing
    // local/param/const the static fn has no env to reach, and the identifier
    // site diagnoses it (issue 0250) instead of emitting a dead Ref.
    var scope = Scope.init(self.alloc, self.scope);
    scope.is_fn_boundary = self.scope != null;
    defer scope.deinit();
    self.scope = &scope;
    defer self.scope = scope.parent;

    // Implicit `__sx_ctx` at slot 0 when funcWantsImplicitCtx is true;
    // user params shift by one. Bind `current_ctx_ref` for call-site
    // forwarding inside the body.
    const wants_ctx_lf = self.funcWantsImplicitCtx(fd);
    const saved_ctx_ref_lf = self.current_ctx_ref;
    defer self.current_ctx_ref = saved_ctx_ref_lf;
    const user_param_base_lf: u32 = if (wants_ctx_lf) 1 else 0;
    if (wants_ctx_lf) self.current_ctx_ref = Ref.fromIndex(0);

    // `abi(.naked)` (naked): params arrive in registers, read directly by the asm
    // body — no frame, no alloca/store (which the LLVM verifier rejects on a
    // naked function). See the sibling guard in the other body-lowering path.
    if (fd.abi != .naked) for (fd.params, 0..) |p, i| {
        const pty = self.resolveParamType(&p);
        // Allocate stack slot for param, store initial value.
        // Refs 0..N-1 are reserved for function parameters by beginFunction.
        const slot = self.builder.alloca(pty);
        const param_ref = Ref.fromIndex(@intCast(i + user_param_base_lf));
        self.builder.store(slot, param_ref);
        scope.put(p.name, .{ .ref = slot, .ty = pty, .is_alloca = true });
    };

    // Named multi-return slots as in-scope locals (see the sibling body path).
    const saved_nrn_lf = self.named_return_names;
    const saved_nrd_lf = self.named_return_defaults;
    self.named_return_names = null;
    self.named_return_defaults = null;
    defer {
        self.named_return_names = saved_nrn_lf;
        self.named_return_defaults = saved_nrd_lf;
    }
    if (fd.abi != .naked) self.bindNamedReturnSlots(fd, ret_ty, &scope);

    // Inbound entry points + abi(.c) sx functions: bind
    // current_ctx_ref to &__sx_default_context. See companion comment
    // in `lowerFunction` for the same case.
    if (!wants_ctx_lf and self.implicit_ctx_enabled) {
        if (self.program_index.global_names.get("__sx_default_context")) |dctx_gi| {
            self.current_ctx_ref = self.builder.emit(.{ .global_addr = dctx_gi.id }, self.module.types.ptrTo(.void));
        }
    }

    // Lower the function body, capturing the last expression's value for implicit return
    const saved_target = self.target_type;
    self.target_type = if (ret_ty != .void and ret_ty != .noreturn) ret_ty else null;
    if (self.builder.currentFunc().is_naked) {
        // `abi(.naked)`: asm-only body that rets itself — see the sibling path
        // above. Lower statements, cap with `unreachable`; emission is B1.0b.
        self.lowerBlock(fd.body);
        if (!self.currentBlockHasTerminator()) self.builder.emitUnreachable();
    } else if (ret_ty != .void and ret_ty != .noreturn) {
        self.lowerValueBody(fd.body, ret_ty);
    } else {
        // void / noreturn: no value to return — lower as statements and
        // let `ensureTerminator` close the block (ret void / unreachable).
        self.lowerBlock(fd.body);
        self.ensureTerminator(ret_ty);
    }
    self.target_type = saved_target;

    self.builder.finalize();
}

// ── Module-const emission ───────────────────────────────────────

pub fn emitModuleConst(self: *Lowering, ci: ModuleConstInfo, author_source: ?[]const u8) Ref {
    // F1: a const read from another module folds/lowers its RHS in the
    // AUTHOR's visibility context, so a same-name leaf (`K :: M + 1` selected
    // from `a.sx`) resolves `M` against `a.sx` — not against the reading
    // module, which may flat-import a different same-name `M`. Single-author /
    // own-read consts pin to the source they were already in → byte-identical.
    const author_pin = self.pinConstAuthorSource(author_source);
    defer author_pin.unpin();
    // An integer-typed const whose initializer is a compile-time integer —
    // an int literal/expression, OR an INTEGRAL float that `typedConstInitFits`
    // accepted under the unified narrowing rule — materializes as its folded
    // int through the SAME `program_index.foldCountI64` the count / array-dim
    // path uses, so the const's emitted VALUE and its use as a COUNT come from
    // one fold (`K : i64 : 4.0` → 4; `K : i64 : M + 2.0` → 4; and a float-const-
    // leaf `KF : i64 : F + 1.5` → 4, which the int-only folder could not reach).
    // A non-integral float never arrives (it was rejected at registration); any
    // other non-foldable shape falls through to the per-kind emitters below.
    if (self.isIntEx(ci.ty)) {
        switch (program_index_mod.foldCountI64(ci.value, self)) {
            .int => |iv| {
                // Range-check the folded value against the declared width — a
                // typed module const (`C : u8 : '🦀'` / `C : u8 : 129408`) must
                // report an out-of-range initializer here, not silently
                // truncate. A char-literal initializer gets the char-specific
                // "use a wider type" message; everything else the int message.
                switch (ci.value.data) {
                    .char_literal => |cl| self.checkCharLiteralFits(cl, ci.ty, ci.value.span),
                    else => self.checkIntLiteralFits(iv, ci.ty, ci.value.span),
                }
                return self.builder.constInt(iv, ci.ty);
            },
            .non_integral, .not_const => {},
        }
    }
    switch (ci.value.data) {
        .int_literal => |lit| {
            // If declared type is float, convert integer value to float constant
            if (ci.ty == .f32 or ci.ty == .f64) {
                return self.builder.constFloat(@floatFromInt(lit.value), ci.ty);
            }
            return self.builder.constInt(lit.value, ci.ty);
        },
        .char_literal => |lit| {
            if (ci.ty == .f32 or ci.ty == .f64) {
                return self.builder.constFloat(@floatFromInt(lit.value), ci.ty);
            }
            return self.builder.constInt(lit.value, ci.ty);
        },
        .float_literal => |lit| return self.builder.constFloat(lit.value, ci.ty),
        .bool_literal => |lit| return self.builder.emit(.{ .const_bool = lit.value }, .bool),
        .string_literal => |lit| {
            const str = if (lit.is_raw) lit.raw else unescape.unescapeString(self.alloc, lit.raw) catch lit.raw;
            const sid = self.module.types.internString(str);
            return self.builder.constString(sid);
        },
        .undef_literal => return self.builder.constUndef(ci.ty),
        .null_literal => return self.builder.constNull(ci.ty),
        else => {
            // Complex expressions (struct_literal, call, etc.) — lower on demand
            const saved_target = self.target_type;
            self.target_type = ci.ty;
            const result = self.lowerExpr(ci.value);
            self.target_type = saved_target;
            return result;
        },
    }
}

pub fn emitPlaceholder(self: *Lowering, name: []const u8) Ref {
    const sid = self.module.types.internString(name);
    return self.builder.emit(.{ .placeholder = sid }, .i64);
}
