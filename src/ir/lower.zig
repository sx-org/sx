const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast.zig");
const Node = ast.Node;
const types = @import("types.zig");
const inst_mod = @import("inst.zig");
const mod_mod = @import("module.zig");
const type_bridge = @import("type_bridge.zig");
const unescape = @import("../unescape.zig");
const parser_mod = @import("../parser.zig");
const errors = @import("../errors.zig");
const jni_descriptor = @import("jni_descriptor.zig");
const program_index_mod = @import("program_index.zig");
const resolver_mod = @import("resolver.zig");
const imports_mod = @import("../imports.zig");
const ProgramIndex = program_index_mod.ProgramIndex;
const GlobalInfo = program_index_mod.GlobalInfo;
const StructTemplate = program_index_mod.StructTemplate;
const TemplateParam = program_index_mod.TemplateParam;
const ProtocolDeclInfo = program_index_mod.ProtocolDeclInfo;
const ProtocolMethodInfo = program_index_mod.ProtocolMethodInfo;
const ModuleConstInfo = program_index_mod.ModuleConstInfo;
const TypeResolver = @import("type_resolver.zig").TypeResolver;
const ResolveEnv = @import("type_resolver.zig").ResolveEnv;
const PackResolver = @import("packs.zig").PackResolver;
const ExprTyper = @import("expr_typer.zig").ExprTyper;
const CallResolver = @import("calls.zig").CallResolver;
const GenericResolver = @import("generics.zig").GenericResolver;
const ProtocolResolver = @import("protocols.zig").ProtocolResolver;
const CoercionResolver = @import("conversions.zig").CoercionResolver;
const ErrorAnalysis = @import("error_analysis.zig").ErrorAnalysis;
const ErrorFlow = @import("error_flow.zig").ErrorFlow;
const ObjcLowering = @import("ffi_objc.zig").ObjcLowering;
const semantic_diagnostics = @import("semantic_diagnostics.zig");
const lower_error = @import("lower/error.zig");
const lower_comptime = @import("lower/comptime.zig");
const lower_stmt = @import("lower/stmt.zig");
const lower_control_flow = @import("lower/control_flow.zig");
const lower_decl = @import("lower/decl.zig");
const lower_context_ext = @import("lower/context_ext.zig");
const lower_nominal = @import("lower/nominal.zig");
const lower_protocol = @import("lower/protocol.zig");
const lower_coerce = @import("lower/coerce.zig");
const lower_ffi = @import("lower/ffi.zig");
const lower_objc_class = @import("lower/objc_class.zig");
const lower_call = @import("lower/call.zig");
const lower_pack = @import("lower/pack.zig");
const lower_generic = @import("lower/generic.zig");
const lower_expr = @import("lower/expr.zig");
const lower_closure = @import("lower/closure.zig");

const TypeId = types.TypeId;
const StringId = types.StringId;
const Ref = inst_mod.Ref;
const BlockId = inst_mod.BlockId;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;
const Module = mod_mod.Module;
const Builder = mod_mod.Builder;

/// One frame in the chain of module-const names currently being folded by the
/// SOURCE-AWARE const evaluator (`Lowering.foldSourceConstInt` and its float
/// twins). Stack-allocated per recursive frame, so cycle detection needs no
/// allocation — the source-aware analogue of `program_index.ModuleConstFrame`,
/// which guards the GLOBAL-map fold (`moduleConstInt`). The frame keys on the
/// const's (name, author-source) pair, NOT name alone: same-name nested consts
/// across modules (`a.M` ≠ `b.M`) must NOT trip a false cycle (F3). A pair
/// already on the chain is a cyclic definition (`N :: N`; `N :: M + 1; M :: N`)
/// with no compile-time value → folds to null.
pub const ConstFoldFrame = struct {
    name: []const u8,
    source: ?[]const u8,
    parent: ?*const ConstFoldFrame,
};

pub fn constFoldFrameContains(frame: ?*const ConstFoldFrame, name: []const u8, source: ?[]const u8) bool {
    var cur = frame;
    while (cur) |c| : (cur = c.parent) {
        if (std.mem.eql(u8, c.name, name) and sourcesEql(c.source, source)) return true;
    }
    return false;
}

fn sourcesEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Folding context for a SOURCE-AWARE module-const EXPRESSION RHS (E2/F2/R1).
/// The leaf-resolution twin of `program_index.ModuleConstCtx`, but every leaf
/// name resolves through the querying source's OWN const author
/// (`selectModuleConst`, own-wins / ambiguous) instead of the GLOBAL last-wins
/// `module_const_map`. This is what makes a same-name shadow's RHS chain
/// (`K :: M + 1`, with `M` a same-name shadow too) fold `M` to the SELECTED
/// author's `M` — coherently for a const used as a value AND as an array
/// dimension / count. `frame` is the cyclic-definition guard.
pub const SourceConstCtx = struct {
    lowering: *Lowering,
    frame: ?*const ConstFoldFrame,
    pub fn lookupDimName(self: SourceConstCtx, name: []const u8) ?i64 {
        return self.lowering.foldSourceConstInt(name, self.frame);
    }
    pub fn lookupPackLen(self: SourceConstCtx, name: []const u8) ?i64 {
        return self.lowering.lookupPackLen(name);
    }
    pub fn lookupFloatName(self: SourceConstCtx, name: []const u8) ?f64 {
        return self.lowering.foldSourceConstFloat(name, self.frame);
    }
    pub fn nameIsFloatTyped(self: SourceConstCtx, name: []const u8) bool {
        return self.lowering.sourceConstIsFloatTyped(name, self.frame);
    }
    pub fn lookupConstAggLen(self: SourceConstCtx, name: []const u8) ?i64 {
        return self.lowering.foldConstAggLen(name);
    }
    pub fn lookupConstArrayElem(self: SourceConstCtx, name: []const u8, idx: i64, span: ?ast.Span) ?i64 {
        return self.lowering.foldConstArrayElem(name, idx, span, self.frame);
    }
    pub fn lookupConstStructField(self: SourceConstCtx, name: []const u8, field: []const u8) ?i64 {
        return self.lowering.foldConstStructField(name, field, self.frame);
    }
    // Type-query builtin folds (`field_count`/`size_of`/`align_of`) — delegate to
    // the wrapped Lowering, which can resolve the type-expr arg.
    pub fn evalConstCallInt(self: SourceConstCtx, node: *const Node) ?i64 {
        return self.lowering.evalConstCallInt(node);
    }
    pub fn lookupQualifiedConst(self: SourceConstCtx, ns: []const u8, field: []const u8) ?i64 {
        return self.lowering.foldQualifiedConstInt(ns, field, self.frame);
    }
    pub fn lookupQualifiedConstFloat(self: SourceConstCtx, ns: []const u8, field: []const u8) ?f64 {
        return self.lowering.foldQualifiedConstFloat(ns, field, self.frame);
    }
    pub fn qualifiedNameIsFloatTyped(self: SourceConstCtx, ns: []const u8, field: []const u8) bool {
        return self.lowering.qualifiedConstIsFloatTyped(ns, field, self.frame);
    }
};

// ── Scope ───────────────────────────────────────────────────────────────

pub const Binding = struct {
    /// Where a NON-ALLOCA binding came from. Drives the shape-specific
    /// "cannot assign" diagnostic (issue 0219 + review folds): a for-loop
    /// element can point at the `(*x)` by-ref spelling, while a range index /
    /// match payload / catch binding has no container storage to write back
    /// into and gets copy-into-a-`:=`-local advice only; a function-local
    /// `::` const gets the constant-family message. `.other` covers synthetic
    /// receivers / temp bindings that never legitimately reach an assignment
    /// target.
    pub const Origin = enum {
        other,
        /// Function-local `x :: 5` (lowerConstDecl) — immutable constant.
        local_const,
        /// `for xs (x)` by-value element — container-backed; `(*x)` exists.
        for_element,
        /// `for 0..N (i)` / paired range cursor (runtime or inline-for) —
        /// the position has no storage (`*` on a range capture is an error).
        range_index,
        /// Match-arm payload / optional-match binding.
        match_payload,
        /// `catch (e)` / `onfail e` error binding.
        catch_err,
        /// `inline for xs (x)` pack-element alias (`pack_elem` is also set).
        pack_elem_alias,
    };

    ref: Ref,
    ty: TypeId,
    is_alloca: bool, // true if ref is a pointer that needs load
    is_ref_capture: bool = false, // `for xs: (*x)` — `ref` is `*elem`; auto-deref in value positions
    /// `inline for xs (x)` element capture: `x` is an AST ALIAS for the
    /// synthesized `xs[<i>]` of the current unroll iteration (`ref` is
    /// `.none`). Identifier consumers substitute this node, so the capture
    /// inherits the full pack-element semantics — concrete-arg substitution,
    /// typing, and the interface-only constraint check.
    pack_elem: ?*ast.Node = null,
    origin: Origin = .other,
};

// `init` / `deinit` / `put` are pub so collaborator unit tests (e.g.
// calls.test.zig) can stand up a lexical scope and exercise the
// scope-dependent call forms (closure / fn-pointer callees) without
// driving a full function lowering.
pub const Scope = struct {
    map: std.StringHashMap(Binding),
    fn_names: std.StringHashMap([]const u8), // bare name → mangled name for local functions
    parent: ?*Scope,
    /// True on the ROOT scope of a NESTED `::` static function's body (a
    /// `f :: () {…}` declared inside another function). Such a scope keeps its
    /// `parent` chain so SIBLING nested fns (`fn_names`) and comptime constants
    /// still resolve, but a plain VALUE binding reached by crossing this
    /// boundary is an enclosing local/param/const — which a static nested fn has
    /// no env to reach — and must be diagnosed, not silently read as a dead Ref
    /// (issue 0250). Closures capture explicitly and do NOT set this.
    is_fn_boundary: bool = false,

    pub fn init(alloc: Allocator, parent: ?*Scope) Scope {
        return .{
            .map = std.StringHashMap(Binding).init(alloc),
            .fn_names = std.StringHashMap([]const u8).init(alloc),
            .parent = parent,
        };
    }

    pub fn deinit(self: *Scope) void {
        self.map.deinit();
        self.fn_names.deinit();
    }

    pub fn put(self: *Scope, name: []const u8, binding: Binding) void {
        self.map.put(name, binding) catch unreachable;
    }

    pub fn lookup(self: *const Scope, name: []const u8) ?Binding {
        if (self.map.get(name)) |b| return b;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }

    /// A value-binding lookup that also reports whether the binding was reached
    /// only by crossing a nested-fn boundary (`is_fn_boundary`). A static nested
    /// `::` fn has no environment, so such a binding is an enclosing
    /// local/param/const it cannot legitimately read — the identifier site turns
    /// `crossed_fn_boundary = true` into the tailored "use a closure to capture"
    /// diagnostic instead of silently emitting the dead Ref (issue 0250).
    /// `binding` is null when the name is absent entirely (the ordinary
    /// unresolved path); non-null with `crossed_fn_boundary = false` is a normal
    /// in-scope hit.
    pub const ScopedBinding = struct { binding: ?Binding, crossed_fn_boundary: bool };
    pub fn lookupBoundary(self: *const Scope, name: []const u8) ScopedBinding {
        var s: ?*const Scope = self;
        var crossed = false;
        while (s) |sc| : (s = sc.parent) {
            if (sc.map.get(name)) |b| return .{ .binding = b, .crossed_fn_boundary = crossed };
            if (sc.is_fn_boundary) crossed = true;
        }
        return .{ .binding = null, .crossed_fn_boundary = false };
    }

    pub fn lookupFn(self: *const Scope, name: []const u8) ?[]const u8 {
        if (self.fn_names.get(name)) |mangled| return mangled;
        if (self.parent) |p| return p.lookupFn(name);
        return null;
    }

    /// What `name` resolves to at the NEAREST scope level that declares it
    /// in EITHER local namespace: the value-binding map or the local-fn
    /// table (nested `name :: (…) {…}` decls). Shadowing is by DEPTH
    /// (specs §Variable Shadowing — innermost wins), never by namespace:
    /// an inner nested fn shadows an outer callable var and vice versa,
    /// which the independent full-chain walks of `lookup` / `lookupFn`
    /// cannot express (issue 0217 review F1). Within a single level the
    /// value binding wins; both coexisting at one level is a same-scope
    /// redeclaration shape, not a shadowing one.
    pub const NearestName = union(enum) {
        binding: Binding,
        /// Mangled name of the nested local fn — dispatch resolves it
        /// through the top-level fn tables exactly as `lookupFn` callers do.
        local_fn: []const u8,
    };

    pub fn lookupNearest(self: *const Scope, name: []const u8) ?NearestName {
        var s: ?*const Scope = self;
        while (s) |sc| : (s = sc.parent) {
            if (sc.map.get(name)) |b| return .{ .binding = b };
            if (sc.fn_names.get(name)) |m| return .{ .local_fn = m };
        }
        return null;
    }

    /// `lookupNearest` + the fn-boundary report (issue 0250 fold): call-site
    /// dispatch needs BOTH the nearest-declaration verdict and whether that
    /// declaration lives across a nested-fn boundary. A `.local_fn` found
    /// across the boundary is a SIBLING nested fn — static, legally callable.
    /// A `.binding` found across it is an enclosing local (closure value, fn
    /// pointer, anything) the static nested fn cannot reach — the call site
    /// diagnoses instead of dispatching through the dead Ref (Bus error).
    pub const NearestBoundary = struct { near: NearestName, crossed_fn_boundary: bool };
    pub fn lookupNearestBoundary(self: *const Scope, name: []const u8) ?NearestBoundary {
        var s: ?*const Scope = self;
        var crossed = false;
        while (s) |sc| : (s = sc.parent) {
            if (sc.map.get(name)) |b| return .{ .near = .{ .binding = b }, .crossed_fn_boundary = crossed };
            if (sc.fn_names.get(name)) |m| return .{ .near = .{ .local_fn = m }, .crossed_fn_boundary = crossed };
            if (sc.is_fn_boundary) crossed = true;
        }
        return null;
    }
};

/// A pending block-scoped cleanup: `defer` (runs on every block exit) or
/// `onfail` (runs only when an error leaves the block, binding the in-flight
/// tag). Both share one declaration-ordered stack so error-exit cleanup runs
/// them interleaved in reverse order (ERR E1.7).
const CleanupEntry = struct {
    body: *const Node,
    is_onfail: bool,
    binding: ?[]const u8 = null,
};

/// Pure non-transitive visibility walk: `name` is visible from `source` when
/// it's in `source`'s own scope or in any module reachable over one `graph`
/// edge. The core of the lowering visibility predicate, exposed so a unit test
/// can exercise the edge-walk without standing up a whole `Lowering`. Falls open
/// (true) when `scopes`/`graph` are null (scoping infra unwired).
pub fn nameVisibleOverEdges(
    scopes: ?*std.StringHashMap(std.StringHashMap(void)),
    graph: ?*std.StringHashMap(std.StringHashMap(void)),
    source: []const u8,
    name: []const u8,
) bool {
    const sc = scopes orelse return true;
    const own_scope = sc.get(source) orelse return true;
    if (own_scope.contains(name)) return true;
    const g = graph orelse return true;
    const direct = g.get(source) orelse return true;
    var it = direct.iterator();
    while (it.next()) |kv| {
        const dep = sc.get(kv.key_ptr.*) orelse continue;
        if (dep.contains(name)) return true;
    }
    return false;
}

// ── Lowering ────────────────────────────────────────────────────────────

pub const Lowering = struct {
    module: *Module,
    builder: Builder,
    alloc: Allocator,
    scope: ?*Scope = null,
    break_target: ?BlockId = null,
    continue_target: ?BlockId = null,
    loop_defer_base: usize = 0, // defer-stack height at the innermost loop's body start (break/continue drain to here)
    suppress_int_fit_check: bool = false, // inside an explicit `xx` cast operand: truncation is requested, skip the literal fits-check
    int_lit_extra_fit_ty: ?TypeId = null, // inside a `cast(T)` operand (T is the ambient type here): an ADDITIONAL range the literal may fit — set to i64 so a value fitting i64 but not T still truncates rather than erroring (issue 0275)
    block_counter: u32 = 0,
    comptime_counter: u32 = 0,
    /// Transient: the user-facing const name of the body-local `#run` currently
    /// being lowered (`L :: #run f()`), so `lowerInlineComptime` can stamp the
    /// `__ct` wrapper's `comptime_display_name` for a friendly comptime-init
    /// failure diagnostic (issue 0182). Set/cleared around the const's value
    /// lowering; null for a bare inline `#run`.
    comptime_const_name: ?[]const u8 = null,
    main_file: ?[]const u8 = null, // path of the main file; imported functions are declared extern
    resolved_root: ?*const Node = null, // full AST root (for building comptime modules)
    comptime_param_nodes: ?std.StringHashMap(*const Node) = null, // active comptime substitutions
    target_type: ?TypeId = null, // target type for struct/enum literals without explicit names
    // Count of diagnostics emitted by the annotated-store assignability guard
    // (`checkAssignable` / the named-return-default guard, issue 0197). Lets the
    // guard skip when ANY OTHER error already exists (`errorCount() > this`) —
    // suppressing cascades onto a pre-lowering error (an unknown annotation
    // type) or a failed initializer, while still reporting multiple INDEPENDENT
    // mismatches (each of those is one of the guard's OWN errors, not external).
    assignability_error_count: usize = 0,
    lowered_functions: std.StringHashMap(void), // tracks which functions have been fully lowered
    /// Identity map: authoring `*const ast.FnDecl` → the FuncId `declareFunction`
    /// created for it. The name-keyed function table (`resolveFuncByName`) returns
    /// the FIRST author of a name, so two same-name authors collide there; this
    /// map addresses each author's OWN slot by decl identity, letting
    /// a SHADOWED author lower its body into a distinct FuncId.
    fn_decl_fids: std.AutoHashMap(*const ast.FnDecl, FuncId),
    /// FuncId-keyed lowered tracking — the identity twin of `lowered_functions`
    /// (which keys by name). A shadowed same-name author shares the winner's name
    /// but not its FuncId, so name-keyed tracking can't tell them apart; this
    /// records which specific FuncIds have had a real body lowered.
    lowered_fids: std.AutoHashMap(FuncId, void),
    local_fn_counter: u32 = 0, // unique counter for mangling local function names
    /// Per-declaration nominal identity bookkeeping (E2). The FIRST source to
    /// register a given top-level type NAME keeps `nominal_id = 0` (structural —
    /// byte-identical to pre-E2 single-author registration); a later registration
    /// of the same name from a DIFFERENT source is a same-name SHADOW and gets a
    /// fresh id from `next_nominal_id`, so the two authors intern to DISTINCT
    /// TypeIds (closing the last-wins collapse). `nominal_name_authors`
    /// records each name's first author source to make that decision.
    nominal_name_authors: std.AutoHashMap(types.StringId, []const u8),
    next_nominal_id: u32 = 0,
    /// Declaration-name / import / visibility facts (architecture phase A1,
    /// `ProgramIndex`). Owns `import_flags`; borrows `module_scopes` /
    /// `import_graph` from the compilation driver. Reached via
    /// `self.program_index.<field>`; populated by scan/registration code.
    program_index: ProgramIndex,
    current_source_file: ?[]const u8 = null, // source file of function currently being lowered
    // Implicit Context parameter machinery. When the program imports
    // `std.sx` (and therefore declares `Context :: struct {...}`), every
    // default-conv sx function gains a synthetic `__sx_ctx: *void` param
    // at slot 0, and `current_ctx_ref` is bound to that param on each
    // function-body entry. `lowerCall` / `call_indirect` prepend this ref
    // to the args of every sx-to-sx call. push Context.{...} rebinds it
    // to a stack-allocated Context for the lexical body. See
    // `~/.claude/plans/lets-see-options-for-merry-dijkstra.md`.
    implicit_ctx_enabled: bool = false,
    current_ctx_ref: Ref = Ref.none,
    sel_register_name_fid: ?FuncId = null, // lazily-declared `sel_registerName` extern (non-literal selector fallback)
    jni_env_stack: std.ArrayList(Ref) = std.ArrayList(Ref).empty, // lexical `#jni_env(env)` Ref stack — top is current scope's env for omitted-env `#jni_call`
    jni_env_stack_base: usize = 0, // index above which the currently-lowering fn's `#jni_env` scopes live; outer-fn Refs aren't valid in this fn's instruction stream
    jni_env_tl_get_fid: ?FuncId = null, // extern `sx_jni_env_tl_get` (from library/vendors/sx_jni_runtime/sx_jni_env_tl.c)
    jni_env_tl_set_fid: ?FuncId = null, // extern `sx_jni_env_tl_set`
    needs_jni_env_tl_runtime: bool = false, // set when lowering touches the JNI env TL; signals Compilation to auto-link the runtime .c
    trace_push_fid: ?FuncId = null, // extern `sx_trace_push` (ERR E3.1, from library/vendors/sx_trace_runtime/sx_trace.c)
    trace_clear_fid: ?FuncId = null, // extern `sx_trace_clear`
    needs_trace_runtime: bool = false, // set when lowering emits a trace push/clear; signals Compilation to auto-link sx_trace.c
    chain_fail_target: ?ChainFailTarget = null, // ERR E2.4: when set, a failable `or` chain routes its TOTAL failure here (an absorbing consumer like `catch`) instead of propagating to the function
    current_runtime_class: ?*const ast.RuntimeClassDecl = null, // set while lowering a `#jni_main` (or any sx-defined `#jni_class`) bodied method — `super.method(args)` dispatch resolves the parent class against this fcd's `#extends`
    current_runtime_method: ?ast.RuntimeMethodDecl = null, // the specific method whose body is being lowered; `super.<same_name>(...)` reuses its signature
    type_bindings: ?std.StringHashMap(TypeId) = null, // generic type param bindings ($T → concrete TypeId)
    current_match_tags: ?[]const u64 = null, // type tags for current match arm (for runtime dispatch)
    /// Flow-sensitive narrowing (issue 0179). The set of local variable names
    /// currently PROVEN present (`?T` known to carry a value) by a `!= null`
    /// guard / branch. Region-scoped: `lowerBlock` snapshots+restores it, the
    /// if-then branch narrows on `!= null`, a divergent `== null` guard narrows
    /// the rest of the enclosing block, and an assignment kills the name's
    /// narrowing. Consulted at the implicit `?T → concrete` unwrap (`coerceMode`):
    /// a non-narrowed unwrap is REJECTED instead of silently yielding the zero
    /// payload of a null optional.
    narrowed: std.StringHashMap(void) = undefined,
    /// Dedupe for the issue-0250 "nested fn references enclosing local"
    /// diagnostic, keyed `"<fn-index>:<name>"`. The boundary guard fires at
    /// EVERY resolution layer (identifier read, getExprAlloca fast path,
    /// lvalue helper, call dispatch); a single bad reference would otherwise
    /// report the same error two or three times as the speculative fast path
    /// diagnoses and its null-fallback re-lowers through the guarded
    /// identifier machinery. First site wins; later sites stay silent-but-
    /// poisoned (they still return placeholders, and hasErrors() aborts).
    diag_enclosing_seen: std.StringHashMap(void) = undefined,
    /// The SSA `Ref`s produced by lowering a narrowed identifier — the bridge
    /// from name-keyed narrowing to the Ref-keyed `coerceMode` unwrap gate.
    /// Cleared per function body (the `Ref` space is per-function).
    narrowed_refs: std.AutoHashMap(Ref, void) = undefined,
    /// The SSA `Ref`s an EXPLICIT cast (`xx` / postfix `.(T)`) passed through
    /// UNCHANGED — no modeled conversion and no user `Into` applied, i.e. the
    /// user's deliberate opt-in to a bit-reinterpretation. Consulted by the
    /// implicit unmodeled-coercion guard (`coerceMode`'s `.none` arm and
    /// `checkReturnable`) so the explicit escape hatch stays open when the
    /// passthrough value later flows through an implicit coercion site.
    /// Per-function (the `Ref` space is per-function), cleared alongside
    /// `narrowed_refs`.
    xx_passthrough_refs: std.AutoHashMap(Ref, void) = undefined,
    force_block_value: bool = false, // set by lowerBlockValue to extract if-else values
    // Set while lowering a NAMED multi-return function body (`-> (x: A, y: B)`):
    // the slot names (1:1 with the return tuple's fields; a trailing "!" marks
    // the failable error slot). The slots are bound as in-scope assignable locals;
    // at end-of-body with no explicit `return`, `lowerValueBody` synthesizes the
    // implicit return from them (must-set rule: an unset, undefaulted slot errors).
    named_return_names: ?[]const []const u8 = null,
    // Per-slot default exprs (1:1 with the return tuple's fields; null where the
    // slot has none). A defaulted named-return slot is seeded with its default
    // and exempt from the must-set rule.
    named_return_defaults: ?[]const ?*const ast.Node = null,
    block_terminated: bool = false, // set when constant-folded if emits a return/br into current block
    in_lambda_body: bool = false, // true while lowering a closure-literal body; sharpens the `raise`-not-failable diagnostic (ERR E5.1: tell the user to annotate `-> (T, !)`)
    defer_stack: std.ArrayList(CleanupEntry) = std.ArrayList(CleanupEntry).empty, // block-scoped defer + onfail cleanup stack
    func_defer_base: usize = 0, // defer stack base for current function (lowerReturn drains to this)
    deferred_type_fns: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty, // functions deferred until all types registered
    processing_deferred: bool = false, // true when processing deferred functions (prevents re-deferral)
    /// True while emitting the compiler-synthesized default-Context global
    /// (`emitDefaultContextGlobal`). The built-in allocator infrastructure
    /// (`CAllocator`/`Allocator`/`Context`) is resolved as compiler internals,
    /// independent of the user program's import STYLE (a `std :: #import` puts
    /// `CAllocator` behind a namespace edge from `main`, so the user-visibility
    /// gate would reject it) — so the bare TYPE leaf falls open here (F1).
    emitting_default_context: bool = false,
    /// Set once `assembleContext` has extended the registered Context struct
    /// (possibly EARLY, from a scan-time type-fn eval; the assembly is
    /// reconciling, so this only gates default-context emission).
    context_assembled: bool = false,
    /// Set when a Context STRUCTURAL error was diagnosed (L4 collision, L5
    /// missing default, unresolvable field type). Such an error poisons
    /// every downstream `context.field` access — `lowerRoot` halts after
    /// assembly so the primary diagnostics stand alone instead of cascading
    /// a field-not-found per use site.
    context_structural_error: bool = false,
    /// Names declared as a BLOCK-LOCAL type (a `Foo :: struct/enum/union/error_set`
    /// or bare type-decl statement inside a fn / init body), keyed by the DECLARING
    /// source. A local type registers into the global type table and CLOBBERS a
    /// same-name top-level entry (`registerStructDecl`'s `findByName … orelse intern`
    /// + `updatePreservingKey`), so after it lowers the name IS the local type
    /// program-wide (single-author, pre-E2). The source-aware bare-TYPE gate consults
    /// this so a legitimately block-local type resolves in ITS OWN source (never
    /// mistaken for a namespaced-only leak, even when a namespaced-only import authors
    /// a same-name top-level type — R2). It is keyed by source because a local is
    /// visible ONLY within the source that declares it: an imported template's field
    /// resolution (run in the template's source context, E3 attempt-4) must NOT bind a
    /// name the CALLER declared block-local (E3 attempt-5).
    local_type_names: std.StringHashMap(std.StringHashMap(void)),
    struct_defaults_map: std.StringHashMap([]const ?*const Node), // struct name → field defaults
    struct_instance_bindings: std.StringHashMap(std.StringHashMap(TypeId)), // mangled struct name → type param bindings
    struct_instance_template: std.StringHashMap([]const u8), // mangled struct name → template name
    struct_instance_author: std.StringHashMap(*const ast.StructDecl), // mangled struct name → authoring StructDecl (CP-2: body-author ≡ layout-author)
    comptime_value_bindings: ?std.StringHashMap(i64) = null, // comptime value bindings ($N → integer value: int / enum-tag / tagged-union-tag)
    /// Comptime value params bound to a NON-scalar materialized value (a
    /// tagged-union literal, a struct/array aggregate). Keyed by param name →
    /// the IR `Ref` of the materialized value (an `enum_init(tag, payload)` for
    /// a tagged union, an aggregate const for a struct/array). The companion to
    /// `comptime_value_bindings`: the i64 map carries the comptime-readable
    /// scalar (the variant TAG for a tagged union, so `comptimeIntNamed` keeps
    /// returning it); this map carries the full value Ref so a lowering-time
    /// consumer can read the whole bound value (`comptimeValueRefNamed`).
    comptime_value_ref_bindings: ?std.StringHashMap(Ref) = null,
    protocol_thunk_map: std.StringHashMap([]const FuncId), // "Proto\x00Type" → thunk FuncIds
    protocol_vtable_type_map: std.StringHashMap(TypeId), // protocol name → vtable struct TypeId
    protocol_vtable_global_map: std.StringHashMap(inst_mod.GlobalId), // "Proto\x00Type" → vtable GlobalId
    param_impl_map: std.StringHashMap(std.ArrayList(ParamImplEntry)), // "Proto\x00<arg_mangled>\x00<src_mangled>" → impl entries (parameterised protocols only; list lets Phase 4/5 detect cross-module overlap)
    /// Pack-variadic impl entries — separate map keyed by `"Proto\x00<arg_mangled>"`
    /// (NO source suffix) so a single impl `Closure(..$args) -> $R` can be
    /// matched against many concrete source shapes. Concrete impls in
    /// `param_impl_map` win when both match (specificity rule).
    param_impl_pack_map: std.StringHashMap(std.ArrayList(PackParamImplEntry)),
    /// Active pack bindings during monomorphisation. Mirrors `type_bindings`
    /// but for variadic pack names: `args → [T1, T2, ...]`. Read by
    /// `resolveTypeWithBindings` on closure_type_expr to substitute
    /// `Closure(..$args) -> $R` into a concrete closure type.
    pack_bindings: ?std.StringHashMap([]const TypeId) = null,
    /// Active when lowering an inlined comptime-call body. `return X;`
    /// inside the body must NOT emit a `ret` into the caller's LLVM
    /// function — instead it stores X into `.slot` (typed `.ret_ty`)
    /// and sets `block_terminated` so the inliner can load the slot
    /// once the body finishes. Without this, a body like
    /// `{ return 42; }` truncates the caller's basic block mid-flight
    /// and trips LLVM's "Terminator found in the middle of a basic
    /// block" verifier.
    inline_return_target: ?InlineReturnInfo = null,
    /// Active pack-arg-node bindings during a comptime call's body lowering.
    /// Maps the pack-param name (e.g. `args`) to the slice of call-site
    /// argument AST nodes. `lowerIndexExpr` (and `inferExprType`) check
    /// this map when the index expression's base is an identifier matching
    /// a pack name AND the index is a comptime int literal — substitutes
    /// with the i-th call arg's lowered value so the static type tracks
    /// the call arg's real type instead of `Any`. The `[]Any` slice path
    /// remains the runtime-indexed fallback for non-literal indices.
    pack_arg_nodes: ?std.StringHashMap([]const *const Node) = null,
    /// Active pack-arity bindings during a pack-fn mono's body lowering.
    /// Maps the pack-param name (e.g. `args`) to N. `lowerFieldAccess`
    /// uses this to resolve `args.len` to a compile-time constant Ref
    /// when no `args` slice is in scope (the mono path doesn't
    /// materialise the slice).
    pack_param_count: ?std.StringHashMap(u32) = null,
    /// Type-only pack binding consulted by `inferExprType` for
    /// `args[<lit>]` (parallel to `pack_arg_nodes` which carries the
    /// AST substitution used at lowering time). Holds the concrete
    /// call-site arg types in declaration order — same data the
    /// mono's pack-param signature uses. Lets generic-`$R` return
    /// inference resolve `args[i]` to the correct concrete type even
    /// before the mono's scope is set up.
    pack_arg_types: ?std.StringHashMap([]const TypeId) = null,
    /// Active during a protocol-pack mono's body lowering: pack-param name →
    /// constraint protocol name (`..xs: Box` ⇒ `xs` → `"Box"`). Lets
    /// `lowerFieldAccess` enforce the interface-only rule — a member access
    /// `xs[i].<m>` is rejected unless `<m>` is one of the protocol's methods.
    /// Null / absent for the comptime `..$args` pack (no constraint).
    pack_constraint: ?std.StringHashMap([]const u8) = null,
    struct_const_map: std.StringHashMap(StructConstInfo), // "Struct.CONST" → value info
    extern_name_map: std.StringHashMap([]const u8), // sx name → C name for #extern renames
    target_config: ?@import("../target.zig").TargetConfig = null, // compilation target (for inline if)
    comptime_constants: std.StringHashMap(ComptimeValue), // compile-time known constants (e.g. OS, ARCH)
    diagnostics: ?*errors.DiagnosticList = null, // error reporting with source locations
    xx_reentrancy: std.AutoHashMap(u64, void), // (src_ty, dst_ty) pairs currently being resolved through user-space Into; prevents infinite monomorphisation when a convert body re-enters the same xx
    /// Whole-program-converged inferred error sets (ERR E1.4b): top-level
    /// bare-`!` function name → its sorted escape-tag ids (literal raises +
    /// pure-failable `try` edges, fix-pointed across the call graph). The
    /// shared `!` placeholder TypeId stays empty; this side map holds the real
    /// per-function sets (sidesteps the name-only error-set interning). Read by
    /// `lowerTry`'s named-caller widening and the empty-inferred warning.
    inferred_error_sets: std.StringHashMap([]const u32),
    /// Whole-program-converged inferred error sets keyed by closure/function
    /// VALUE-signature shape (ERR E5.1 sub-feature 2): every occurrence of
    /// `Closure(<sig>) -> (T, !)` with a structurally identical value-signature
    /// shares one node; each bare-`!` closure literal of that shape unions its
    /// escape tags in. Read by `checkEscapeWidening` when a `try` operand is a
    /// closure/fn-type SLOT call (no static fn name). Key = `closureShapeKey`.
    shape_inferred_sets: std.StringHashMap([]const u32),
    /// Qualified names (`Type.method`) of every explicitly-written protocol
    /// impl method. A protocol method may be declared `!` (the error channel
    /// is part of the contract — e.g. `Io.suspend_raw`); a conforming impl
    /// MUST keep the `!` even when its concrete body never raises, so the
    /// "declared `!` but never errors — drop the `!`" warning (a free-fn
    /// linting hint) is a false positive for these. The empty-inferred-set
    /// warning in `error_analysis.zig` skips names in this set.
    impl_method_names: std.StringHashMap(void),

    pub const ComptimeValue = union(enum) {
        int_val: i64,
        enum_tag: struct { ty: TypeId, tag: u32 },
    };

    pub const StructConstInfo = struct {
        value: *const Node,
        ty: ?TypeId, // null if no type annotation (inferred)
    };

    /// One impl block for a parameterised protocol (e.g. `impl Into(Block) for Closure() -> void`).
    /// Stored in `param_impl_map` keyed by (protocol_name, target_args_mangled, source_mangled).
    /// `defining_module` enables import-scoped visibility + cross-module duplicate diagnostics.
    pub const ParamImplEntry = struct {
        methods: []const *const ast.FnDecl,
        source_ty: TypeId,
        target_args: []const TypeId,
        defining_module: []const u8,
        span: ast.Span,
    };

    const InlineReturnInfo = struct { slot: Ref, ret_ty: TypeId, done_bb: BlockId };

    /// ERR E2.4 — where a failable `or` chain's TOTAL failure routes when the
    /// chain is the operand of an absorbing consumer (`catch`). `bb` is a block
    /// with a single parameter typed `set` (the error tag); the chain branches
    /// there with its final error instead of propagating to the function.
    const ChainFailTarget = struct { bb: BlockId, set: TypeId };

    /// Pack-variadic impl entry — `impl Proto(Args...) for Closure(Prefix..., ..$pack) -> $ret`.
    /// Matches any concrete closure source whose first `prefix_len` param types
    /// equal `source_pack_ty`'s fixed prefix; the tail binds to `pack_var_name`
    /// (e.g. "args") and the source's return type binds to `ret_var_name`
    /// (e.g. "R") when the impl's return is generic. `ret_var_name == null`
    /// means the return type is concrete and must match exactly.
    pub const PackParamImplEntry = struct {
        methods: []const *const ast.FnDecl,
        source_pack_ty: TypeId,
        target_args: []const TypeId,
        defining_module: []const u8,
        span: ast.Span,
        pack_var_name: []const u8,
        ret_var_name: ?[]const u8,
    };

    /// Caller-state protection for lowering a function body re-entrantly — a
    /// lazily lowered callee, a qualified `ns.fn` alias, or an out-of-line
    /// same-name author. `enter` snapshots the in-progress builder / scope /
    /// flag / pack / jni state and installs a fresh set for the nested body;
    /// `restore` puts the caller's state back. Lowering a callee must be
    /// transparent to the caller's own lowering — notably `block_terminated`,
    /// which leaking back would mark the caller's trailing statements
    /// dead-after-terminator.
    pub const FnBodyReentry = struct {
        l: *Lowering,
        func: ?FuncId,
        block: ?BlockId,
        counter: u32,
        scope: ?*Scope,
        defer_base: usize,
        block_terminated: bool,
        force_block_value: bool,
        source_file: ?[]const u8,
        jni_env_base: usize,
        pack_arg_nodes: ?std.StringHashMap([]const *const Node),
        pack_param_count: ?std.StringHashMap(u32),
        pack_arg_types: ?std.StringHashMap([]const TypeId),
        inline_return_target: ?InlineReturnInfo,
        narrowed: std.StringHashMap(void),
        narrowed_refs: std.AutoHashMap(Ref, void),
        xx_passthrough_refs: std.AutoHashMap(Ref, void),

        pub fn enter(l: *Lowering) FnBodyReentry {
            const g = FnBodyReentry{
                .l = l,
                .func = l.builder.func,
                .block = l.builder.current_block,
                .counter = l.builder.inst_counter,
                .scope = l.scope,
                .defer_base = l.func_defer_base,
                .block_terminated = l.block_terminated,
                .force_block_value = l.force_block_value,
                .source_file = l.current_source_file,
                .jni_env_base = l.jni_env_stack_base,
                .pack_arg_nodes = l.pack_arg_nodes,
                .pack_param_count = l.pack_param_count,
                .pack_arg_types = l.pack_arg_types,
                .inline_return_target = l.inline_return_target,
                // Flow narrowing is lexical to one function body — a nested
                // (closure / local-fn) lowering starts with a fresh, empty
                // narrowing state and the outer state is restored after.
                .narrowed = l.narrowed,
                .narrowed_refs = l.narrowed_refs,
                .xx_passthrough_refs = l.xx_passthrough_refs,
            };
            l.narrowed = std.StringHashMap(void).init(l.alloc);
            l.narrowed_refs = std.AutoHashMap(Ref, void).init(l.alloc);
            l.xx_passthrough_refs = std.AutoHashMap(Ref, void).init(l.alloc);
            // The `#jni_env` Ref stack is lexical to ONE function's instruction
            // stream; move the visible base to the current top. Pack-fn mono
            // state is likewise lexical to the pack-fn body — null it so a
            // callee sharing a param NAME with the active pack doesn't fold the
            // outer mono's arity into its own `<name>.len`.
            l.jni_env_stack_base = l.jni_env_stack.items.len;
            l.pack_arg_nodes = null;
            l.pack_param_count = null;
            l.pack_arg_types = null;
            l.inline_return_target = null;
            l.func_defer_base = l.defer_stack.items.len;
            l.block_terminated = false;
            l.force_block_value = false;
            return g;
        }

        pub fn restore(g: FnBodyReentry) void {
            const l = g.l;
            l.setCurrentSourceFile(g.source_file);
            l.scope = g.scope;
            l.func_defer_base = g.defer_base;
            l.block_terminated = g.block_terminated;
            l.force_block_value = g.force_block_value;
            l.builder.func = g.func;
            l.builder.current_block = g.block;
            l.builder.inst_counter = g.counter;
            l.jni_env_stack_base = g.jni_env_base;
            l.pack_arg_nodes = g.pack_arg_nodes;
            l.pack_param_count = g.pack_param_count;
            l.pack_arg_types = g.pack_arg_types;
            l.inline_return_target = g.inline_return_target;
            l.narrowed.deinit();
            l.narrowed = g.narrowed;
            l.narrowed_refs.deinit();
            l.narrowed_refs = g.narrowed_refs;
            l.xx_passthrough_refs.deinit();
            l.xx_passthrough_refs = g.xx_passthrough_refs;
        }
    };

    /// Save + clear + restore JUST the flow-narrowing state (issue 0179) around
    /// a nested body lowering that does NOT go through `FnBodyReentry` —
    /// closure literals, generic/pack/comptime monomorphization. Each lowers a
    /// SEPARATE function whose `Ref` space (reset by `beginFunction`) OVERLAPS
    /// the outer function's, so the outer `narrowed_refs` indices would falsely
    /// match the nested body's `Ref`s and permit an UNSOUND unwrap of a
    /// non-present optional. Clearing on entry isolates the nested body (it
    /// builds its own narrowing from scratch); restore re-arms the outer.
    pub const NarrowGuard = struct {
        l: *Lowering,
        narrowed: std.StringHashMap(void),
        narrowed_refs: std.AutoHashMap(Ref, void),
        xx_passthrough_refs: std.AutoHashMap(Ref, void),

        pub fn enter(l: *Lowering) NarrowGuard {
            const g = NarrowGuard{ .l = l, .narrowed = l.narrowed, .narrowed_refs = l.narrowed_refs, .xx_passthrough_refs = l.xx_passthrough_refs };
            l.narrowed = std.StringHashMap(void).init(l.alloc);
            l.narrowed_refs = std.AutoHashMap(Ref, void).init(l.alloc);
            l.xx_passthrough_refs = std.AutoHashMap(Ref, void).init(l.alloc);
            return g;
        }

        pub fn restore(g: NarrowGuard) void {
            g.l.narrowed.deinit();
            g.l.narrowed = g.narrowed;
            g.l.narrowed_refs.deinit();
            g.l.narrowed_refs = g.narrowed_refs;
            g.l.xx_passthrough_refs.deinit();
            g.l.xx_passthrough_refs = g.xx_passthrough_refs;
        }
    };

    pub fn init(module: *Module) Lowering {
        return .{
            .module = module,
            .builder = Builder.init(module),
            .alloc = module.alloc,
            .lowered_functions = std.StringHashMap(void).init(module.alloc),
            .fn_decl_fids = std.AutoHashMap(*const ast.FnDecl, FuncId).init(module.alloc),
            .lowered_fids = std.AutoHashMap(FuncId, void).init(module.alloc),
            .nominal_name_authors = std.AutoHashMap(types.StringId, []const u8).init(module.alloc),
            .local_type_names = std.StringHashMap(std.StringHashMap(void)).init(module.alloc),
            .struct_defaults_map = std.StringHashMap([]const ?*const Node).init(module.alloc),
            .struct_instance_bindings = std.StringHashMap(std.StringHashMap(TypeId)).init(module.alloc),
            .struct_instance_template = std.StringHashMap([]const u8).init(module.alloc),
            .struct_instance_author = std.StringHashMap(*const ast.StructDecl).init(module.alloc),
            .protocol_thunk_map = std.StringHashMap([]const FuncId).init(module.alloc),
            .protocol_vtable_type_map = std.StringHashMap(TypeId).init(module.alloc),
            .protocol_vtable_global_map = std.StringHashMap(inst_mod.GlobalId).init(module.alloc),
            .param_impl_map = std.StringHashMap(std.ArrayList(ParamImplEntry)).init(module.alloc),
            .param_impl_pack_map = std.StringHashMap(std.ArrayList(PackParamImplEntry)).init(module.alloc),
            .struct_const_map = std.StringHashMap(StructConstInfo).init(module.alloc),
            .extern_name_map = std.StringHashMap([]const u8).init(module.alloc),
            .comptime_constants = std.StringHashMap(ComptimeValue).init(module.alloc),
            .narrowed = std.StringHashMap(void).init(module.alloc),
            .diag_enclosing_seen = std.StringHashMap(void).init(module.alloc),
            .narrowed_refs = std.AutoHashMap(Ref, void).init(module.alloc),
            .xx_passthrough_refs = std.AutoHashMap(Ref, void).init(module.alloc),
            .xx_reentrancy = std.AutoHashMap(u64, void).init(module.alloc),
            .inferred_error_sets = std.StringHashMap([]const u32).init(module.alloc),
            .impl_method_names = std.StringHashMap(void).init(module.alloc),
            .shape_inferred_sets = std.StringHashMap([]const u32).init(module.alloc),
            .program_index = ProgramIndex.init(module.alloc),
        };
    }

    // ── Layout delegators ───────────────────────────────────────────

    /// Byte size of an IR type matching LLVM's type layout.
    pub fn typeSizeBytes(self: *Lowering, ty: TypeId) usize {
        return self.module.types.typeSizeBytes(ty);
    }

    pub fn typeAlignBytes(self: *Lowering, ty: TypeId) usize {
        return self.module.types.typeAlignBytes(ty);
    }

    fn resolveReturnType2(self: *Lowering, rt: ?*const Node) TypeId {
        if (rt) |r| return type_bridge.resolveAstType(r, &self.module.types, &self.program_index.type_alias_map, &self.program_index.module_const_map);
        return .void;
    }

    // ── Type-resolution delegators ──────────────────────────────────

    pub fn resolveReturnType(self: *Lowering, fd: *const ast.FnDecl) TypeId {
        if (fd.return_type) |rt| {
            // A bare-paren multi-return signature `(A, B)` is valid HERE (return
            // position); it resolves to its reused tuple TypeId. Misuse as a VALUE
            // type (a param / field / var annotation) is rejected at those sites
            // (`resolveParamType` et al.), not in the common resolver — return
            // types are re-resolved in many places (call-result typing, protocol
            // impls) that a central reject would wrongly trip.
            return self.resolveTypeWithBindings(rt);
        }
        // No explicit annotation — the type is inferred from the body, which
        // references the function's own parameters (`(x: i32) => x * 2`). Those
        // params aren't pushed into `self.scope` until body lowering, so bind
        // them into a temporary scope here; otherwise `inferExprType` can't
        // resolve `x`, the inference yields `.unresolved`, and that reaches LLVM
        // emission as `func.ret`. Whether it slipped through used to
        // depend on a same-named binding lingering from earlier lowering.
        var tmp_scope = Scope.init(self.alloc, self.scope);
        defer tmp_scope.deinit();
        const saved_scope = self.scope;
        self.scope = &tmp_scope;
        defer self.scope = saved_scope;
        for (fd.params, 0..) |p, i| {
            // Bind only plain annotated value params — that's all the body's
            // return type can depend on by name. Skip variadic / pack / comptime
            // params (their concrete types come from per-call substitution) and
            // unannotated ones (no context here). Resolve the type directly via
            // resolveTypeWithBindings rather than resolveParamType: the latter
            // does variadic/pack bookkeeping that must run exactly once, at body
            // lowering — calling it here too corrupts that state.
            if (p.is_variadic or p.is_pack or p.is_comptime) continue;
            if (p.type_expr.data == .inferred_type) continue;
            const pty = self.resolveTypeWithBindings(p.type_expr);
            tmp_scope.put(p.name, .{ .ref = Ref.fromIndex(@intCast(i)), .ty = pty, .is_alloca = false });
        }
        // Arrow functions without explicit return type: infer from body expression.
        if (fd.is_arrow) {
            return self.inferExprType(fd.body);
        }
        // Not arrow: an explicit `return <value>` statement wins. Otherwise
        // default to void — the body's tail expression is a side-effect
        // statement, not an implicit return.
        if (self.findReturnValueType(fd.body)) |ty| return ty;
        return .void;
    }

    /// Walk a function body and return the type of the first `return <value>;`
    /// statement encountered. Does not descend into nested function or lambda
    /// declarations (those have their own return types).
    pub fn findReturnValueType(self: *Lowering, node: *const Node) ?TypeId {
        return switch (node.data) {
            .return_stmt => |rs| if (rs.value) |v| self.inferExprType(v) else null,
            .block => |blk| blk: {
                for (blk.stmts) |s| {
                    if (self.findReturnValueType(s)) |t| break :blk t;
                }
                break :blk null;
            },
            .if_expr => |ie| blk: {
                if (self.findReturnValueType(ie.then_branch)) |t| break :blk t;
                if (ie.else_branch) |eb| {
                    if (self.findReturnValueType(eb)) |t| break :blk t;
                }
                break :blk null;
            },
            .while_expr => |we| self.findReturnValueType(we.body),
            .for_expr => |fe| self.findReturnValueType(fe.body),
            .match_expr => |me| blk: {
                for (me.arms) |arm| {
                    if (self.findReturnValueType(arm.body)) |t| break :blk t;
                }
                break :blk null;
            },
            else => null,
        };
    }

    /// A bare-paren `(A, B)` multi-return SIGNATURE is valid only as a
    /// function/closure return type — never as a VALUE type (a parameter /
    /// variable / field annotation), where a tuple value uses `Tuple(…)`. Emits a
    /// diagnostic and returns true when `node` is a `ReturnTypeExpr`. (`what` names
    /// the offending position, e.g. "parameter" / "variable" / "field".)
    pub fn rejectMultiReturnValueType(self: *Lowering, node: *const ast.Node, what: []const u8) bool {
        if (node.data != .return_type_expr) return false;
        if (self.diagnostics) |d| {
            d.addFmt(.err, node.span, "a bare-paren `(A, B)` is a multi-return signature, valid only as a return type; a tuple-valued {s} uses `Tuple(…)`", .{what});
        }
        return true;
    }

    pub fn resolveParamType(self: *Lowering, p: *const ast.Param) TypeId {
        // A plain value param with no annotation can only be typed from
        // context (a lambda's target closure signature). When `resolveParamType`
        // is reached for one, there is no such context — so it's a genuine
        // "missing annotation" error, not an 8-byte-int guess. (Comptime/
        // variadic pack params also carry `inferred_type` but get their types
        // from per-call substitution, so they're exempt here.)
        if (p.type_expr.data == .inferred_type and !p.is_comptime and !p.is_variadic and !p.is_pack) {
            if (self.diagnostics) |d| {
                d.addFmt(.err, p.type_expr.span, "parameter '{s}' has no type annotation", .{p.name});
            }
            return .unresolved;
        }
        // A bare-paren `(A, B)` is a MULTI-RETURN signature, valid only as a
        // return type — not a parameter value type (use `Tuple(…)`).
        if (self.rejectMultiReturnValueType(p.type_expr, "parameter")) return .unresolved;
        const declared_ty = self.resolveTypeWithBindings(p.type_expr);
        if (p.is_variadic) {
            // Two surface forms:
            //   - legacy `name: ..T` — declared_ty is the element type;
            //     wrap to receive a `[]T` slice.
            //   - new     `..name: []T` — declared_ty is already the slice
            //     type; use it as-is. Wrapping here would double up to
            //     `[][]T` and downstream LLVM emission crashes when the
            //     caller's argument-marshal pack produces a `[]T` that
            //     doesn't match the callee's stored param shape.
            if (!declared_ty.isBuiltin()) {
                const info = self.module.types.get(declared_ty);
                if (info == .slice) return declared_ty;
            }
            return self.module.types.sliceOf(declared_ty);
        }
        return declared_ty;
    }

    pub fn resolveType(self: *Lowering, type_ann: *const Node) TypeId {
        return self.resolveTypeWithBindings(type_ann);
    }

    /// Resolve a type node with the visibility context pinned to `src`, the
    /// DEFINING module of a namespaced callee, restoring the caller's context
    /// after. A namespaced callee's declared return type may name a type that is
    /// bare-visible only inside the callee's own module — namespaced-only from the
    /// call site's view. Post-E1 the bare leaf is source-aware, so resolving that
    /// return type in the CALL SITE's context would wrongly reject it (the type
    /// analog of the namespaced-fn-body source pin that lowers a namespaced fn body in
    /// its own module's context). `src == null` falls back to the call site's
    /// context unchanged.
    pub fn resolveTypeInSource(self: *Lowering, src: ?[]const u8, type_ann: *const Node) TypeId {
        const pinned = src orelse return self.resolveType(type_ann);
        const saved = self.current_source_file;
        defer self.setCurrentSourceFile(saved);
        self.setCurrentSourceFile(pinned);
        return self.resolveType(type_ann);
    }

    /// `resolveParamType` with the visibility context pinned to `src`, the
    /// DEFINING module of the param's function. An imported method's
    /// default-param type (`alloc: Allocator`) is bare-visible only inside its
    /// own module, so typing a cross-module call's args against it must resolve
    /// in that module's context, not the call site's (E4 — the param analog of
    /// `resolveTypeInSource`). `src == null` falls back unchanged.
    pub fn resolveParamTypeInSource(self: *Lowering, src: ?[]const u8, p: *const ast.Param) TypeId {
        const pinned = src orelse return self.resolveParamType(p);
        const saved = self.current_source_file;
        defer self.setCurrentSourceFile(saved);
        self.setCurrentSourceFile(pinned);
        return self.resolveParamType(p);
    }

    /// Construct a `TypeResolver` view over the current lowering state (borrows
    /// only; cheap by-value, reflects current `diagnostics` / `program_index`).
    pub fn typeResolver(self: *Lowering) TypeResolver {
        return .{
            .alloc = self.alloc,
            .types = &self.module.types,
            .diagnostics = self.diagnostics,
            .index = &self.program_index,
        };
    }

    /// Snapshot the active resolution context (Principle 2) for `TypeResolver`.
    /// A2.2 wires the type bindings + literal target; the pack/comptime fields
    /// are populated as A2.3 moves the cases that consume them.
    fn resolveEnv(self: *Lowering) ResolveEnv {
        return .{
            .type_bindings = if (self.type_bindings) |*tb| tb else null,
            .target_type = self.target_type,
        };
    }

    /// Inner-type recursion hook for `TypeResolver.resolveCompound`: resolves a
    /// child type node through the full stateful resolver, so generic structs /
    /// bindings / aliases in element position keep their resolution.
    pub fn resolveInner(self: *Lowering, node: *const Node) TypeId {
        return self.resolveTypeWithBindings(node);
    }

    /// Bare TYPE-NAME twin of `resolveInner` for callers holding a name rather
    /// than an AST node (e.g. an error-set reference `!Named`) — routed through
    /// the visibility-aware `resolveNominalLeaf`, so a same-name-shadowed set
    /// resolves to the querying module's own author (issue 0132's class).
    pub fn resolveName(self: *Lowering, name: []const u8) TypeId {
        return self.resolveNominalLeaf(name, false, null);
    }

    /// Fixed-array dimension hook for `TypeResolver.resolveCompound`. A literal
    /// `[16]T` and a named-const `N :: 16; [N]T` must resolve to the SAME length:
    /// the dimension folds to a compile-time integer (looked up in the comptime /
    /// value / module-const tables the stateful lowering owns) and is narrowed to
    /// `u32` through the single range-checked `program_index.foldDimU32` — never a
    /// bare `@intCast`, so an oversized-but-valid `i64` dim (`[5_000_000_000]`)
    /// diagnoses instead of panicking the compiler. A dimension that
    /// isn't a compile-time integer (or doesn't fit a `u32`) is a hard error:
    /// emit a diagnostic so the driver aborts (`hasErrors()`), then return a
    /// harmless `0` so body lowering finishes without touching the `.unresolved`
    /// sentinel (which would `@panic` in `sizeOf` mid-lowering, before the
    /// diagnostic surfaces). The diagnostic — not the returned length — is what
    /// guarantees no garbage ships.
    pub fn resolveArrayLen(self: *Lowering, len_node: *const Node) ?u32 {
        const result = program_index_mod.foldDimU32(len_node, self, 0);
        if (result == .ok) return result.ok;
        // A non-const / oversized / negative dim is a hard error. Emit the
        // shared diagnostic (single wording source — `program_index.reportDimError`,
        // also used by the stateless alias path so the two cannot diverge) and
        // return null so `resolveCompound` yields the `.unresolved` sentinel — NO
        // fabricated length (a `0` here gives a 0-byte alloca and OOB
        // element access). Lowering the binding never computes the failed type's
        // size: `alloca` records the type but defers `sizeOf` to LLVM emission,
        // which the emitted diagnostic pre-empts via `hasErrors()`, and a
        // downstream use of the `.unresolved`-typed value is poison-suppressed (a
        // field access stays silent — `emitFieldError`). So the failure surfaces
        // as ONE clean diagnostic and never reaches the `sizeOf` panic.
        if (self.diagnostics) |d| program_index_mod.reportDimError(d, len_node.span, result);
        return null;
    }

    /// Leaf-name lookup for the shared dimension evaluator: a name bound to a
    /// compile-time integer across the three const tables.
    pub fn lookupDimName(self: *Lowering, name: []const u8) ?i64 {
        return self.comptimeIntNamed(name);
    }

    /// Fold a pure int-returning type-query builtin CALL to its compile-time
    /// constant: `field_count(T)` / `size_of(T)` / `align_of(T)`. This is what
    /// lets a reflection-derived count drive an `inline for` bound / array dim
    /// exactly like a plain `K :: 3` const — e.g. a `($T) -> Type` builder that
    /// loops `inline for 0..field_count(T)` to assemble a variant list (the
    /// `race` result synthesis). (Reaches the self-ctx fold paths — array dim,
    /// inline-for bound; a Vector LANE in a plain type annotation resolves through
    /// the stateless type-bridge ctx, which stubs this to null.) Resolves the type
    /// arg through the same `resolveTypeArg` + accessors the value path uses, so
    /// the folded constant always matches the call's runtime value. Returns null
    /// for any non-type-query call, a wrong arg count, or an unresolved type arg
    /// → the shared folder then treats it as not-a-compile-time-integer.
    pub fn evalConstCallInt(self: *Lowering, node: *const Node) ?i64 {
        const c = switch (node.data) {
            .call => |call| call,
            else => return null,
        };
        const name = switch (c.callee.data) {
            .identifier => |id| id.name,
            else => return null,
        };
        if (c.args.len != 1) return null;
        const is_fc = std.mem.eql(u8, name, "struct_field_count") or std.mem.eql(u8, name, "variant_count");
        const is_sz = std.mem.eql(u8, name, "size_of");
        const is_al = std.mem.eql(u8, name, "align_of");
        if (!is_fc and !is_sz and !is_al) return null;
        // A runtime Type arg is not a compile-time integer — and resolveTypeArg
        // would emit a spurious "unresolved type" diagnostic from this
        // SPECULATIVE fold context. Bail to the normal (dynamic) lowering.
        if (!self.isStaticTypeArg(c.args[0])) return null;
        const ty = self.resolveTypeArg(c.args[0]);
        if (ty == .unresolved) return null;
        // `field_count` of a resolved non-aggregate is 0 (matches the value path
        // in lower/call.zig), NOT a fold failure.
        if (is_fc) return self.module.types.memberCount(ty) orelse 0;
        if (is_sz) return @intCast(self.typeSizeBytes(ty));
        return @intCast(self.typeAlignBytes(ty));
    }

    /// Pack-length leaf for the shared integer-expression evaluator: a pack
    /// name's monomorphised arity (e.g. an `inline for 0..xs.len` bound).
    /// Resolves through `pack_param_count`, which is populated when a comptime
    /// call binds a pack name. A name with no active pack binding is not a
    /// compile-time integer leaf here → null.
    pub fn lookupPackLen(self: *Lowering, name: []const u8) ?i64 {
        if (self.pack_param_count) |ppc| {
            if (ppc.get(name)) |n| return @intCast(n);
        }
        return null;
    }

    /// Float-valued leaf for the shared float-expression evaluator: a name bound
    /// to a NUMERIC module const whose compile-time value is a (non-integral)
    /// float — the FLOAT counterpart of `lookupDimName`, routed through the SAME
    /// `module_const_map` so the unified narrowing rule resolves a float-const
    /// leaf (`F : f64 : 2.5`) exactly as it resolves an int-const leaf. Integer /
    /// integral-float leaves and comptime int bindings are already resolved by the
    /// `evalConstIntExpr` delegation inside `evalConstFloatExpr`; this surfaces the
    /// non-integral float const so the rule can reject it.
    pub fn lookupFloatName(self: *Lowering, name: []const u8) ?f64 {
        return self.foldSourceConstFloat(name, null);
    }

    /// True iff `name` is a FLOAT-valued module const (`F : f64 : 2.5`,
    /// `K : f64 : 4.0`, untyped `M :: 4.0`, untyped-EXPR `ME :: 4.0 + 1.0`). The
    /// int folder's division arm consults this so a `/` with a float-const operand
    /// is recognised as float division. Comptime / generic
    /// value bindings are always integer-valued, so only the module-const table
    /// can name a float.
    pub fn nameIsFloatTyped(self: *Lowering, name: []const u8) bool {
        return self.sourceConstIsFloatTyped(name, null);
    }

    pub fn lookupConstAggLen(self: *Lowering, name: []const u8) ?i64 {
        return self.foldConstAggLen(name);
    }
    pub fn lookupConstArrayElem(self: *Lowering, name: []const u8, idx: i64, span: ?ast.Span) ?i64 {
        return self.foldConstArrayElem(name, idx, span, null);
    }
    pub fn lookupConstStructField(self: *Lowering, name: []const u8, field: []const u8) ?i64 {
        return self.foldConstStructField(name, field, null);
    }
    /// Qualified-import-member const leaf (`m.CAP`, issue 0192) for the shared
    /// dimension evaluator — resolves the namespace alias `ns` to its target
    /// module and folds its `field` const there.
    pub fn lookupQualifiedConst(self: *Lowering, ns: []const u8, field: []const u8) ?i64 {
        return self.foldQualifiedConstInt(ns, field, null);
    }
    pub fn lookupQualifiedConstFloat(self: *Lowering, ns: []const u8, field: []const u8) ?f64 {
        return self.foldQualifiedConstFloat(ns, field, null);
    }
    pub fn qualifiedNameIsFloatTyped(self: *Lowering, ns: []const u8, field: []const u8) bool {
        return self.qualifiedConstIsFloatTyped(ns, field, null);
    }

    /// Resolve a type node, checking type_bindings first for generic type params.
    pub fn resolveTypeWithBindings(self: *Lowering, node: *const Node) TypeId {
        // Pack-index in a type position: `$<pack>[<lit>]` resolves to the
        // i-th element type of the active pack binding (step 3 of the
        // variadic heterogeneous type packs feature). Unblocks parametric
        // trampoline bodies (`(*void, $args[0]) -> $args[1]`) in stdlib's
        // generic Into(Block) impl. OOB indices / a missing binding emit a
        // diagnostic and return the `.unresolved` sentinel — never a plausible
        // `.i64`, which would silently fabricate an 8-byte int.
        if (node.data == .pack_index_type_expr) {
            const pi = node.data.pack_index_type_expr;
            if (self.pack_arg_types) |pat| {
                if (pat.get(pi.pack_name)) |arg_tys| {
                    if (pi.index < arg_tys.len) return arg_tys[pi.index];
                    if (self.diagnostics) |diags| {
                        diags.addFmt(.err, node.span, "pack-index type ${s}[{}] out of bounds: '{s}' has {} element{s}", .{
                            pi.pack_name,                                                        pi.index, pi.pack_name, arg_tys.len,
                            if (arg_tys.len == 1) @as([]const u8, "") else @as([]const u8, "s"),
                        });
                    }
                    return .unresolved;
                }
            }
            if (self.diagnostics) |diags| {
                diags.addFmt(.err, node.span, "pack-index type ${s}[{}] used outside an active pack binding", .{
                    pi.pack_name, pi.index,
                });
            }
            return .unresolved;
        }
        // Bare `$<name>` in a type position. The parser tags EVERY `$name`
        // expression as `comptime_pack_ref` — including a single-type generic
        // binding (`$R: Type` in `Closure(..$args) -> $R`), which is NOT a
        // value pack. Such a binding lives in `type_bindings`; resolve it the
        // same way `resolveTypeArg` does (so `Box($R)` / `size_of(Box($R))` /
        // a bare `-> $R` return inside a pack-fn mono resolve `$R` to its bound
        // TypeId). Without this arm the node fell through to the catch-all
        // `else` → `type_bridge` → `.unresolved` → an LLVM-emission panic
        // (issue 0156). A name that is genuinely a value PACK (no single-type
        // binding) used where one type is required is a real error — diagnose
        // it, never silently fabricate a default type.
        if (node.data == .comptime_pack_ref) {
            const cpr = node.data.comptime_pack_ref;
            if (self.type_bindings) |tb| {
                if (tb.get(cpr.pack_name)) |ty| return ty;
            }
            if (self.diagnostics) |diags| {
                diags.addFmt(.err, node.span, "pack '{s}' used where a single type is required", .{cpr.pack_name});
            }
            return .unresolved;
        }
        // `*Self` substitution inside runtime-class member declarations
        // — both runtime and sx-defined — resolves to the class's own
        // 0-field stub struct (i.e. the opaque Obj-C pointer type).
        // This matches the Obj-C idiom where `self` IS the object.
        // `self.field` access on sx-defined classes is rewritten by
        // lowerFieldAccess to go through the `__sx_state` ivar
        // (object_getIvar + struct_gep) when needed — see M1.2 A.3.
        if (node.data == .type_expr and std.mem.eql(u8, node.data.type_expr.name, "Self")) {
            if (self.current_runtime_class) |fcd| {
                if (fcd.runtime == .objc_class or fcd.runtime == .objc_protocol) {
                    return self.runtimeClassStructType(fcd);
                }
            }
        }
        // A qualified type reference reaching type position as an EXPRESSION
        // `field_access` node — e.g. `m.Cfg` written as a struct-literal prefix
        // (`m.Cfg.{...}`, issue 0204). Resolve it the SAME way a dotted
        // `type_expr` annotation (`x : m.Cfg`) does (see the `.type_expr` arm
        // below): the prefix is a namespace alias — pin the source to its target
        // module and resolve the leaf there. NOT `resolveNominalLeaf("m.Cfg")`,
        // which treats the whole dotted string as a bare leaf, fails, and
        // fabricates an empty `{}` stub literally named "m.Cfg".
        if (node.data == .field_access) {
            if (self.qualifiedTypeName(node)) |qname| {
                defer self.alloc.free(qname);
                if (std.mem.lastIndexOfScalar(u8, qname, '.')) |dot| {
                    if (self.namespaceAliasTarget(qname[0..dot], node.span)) |target| {
                        const saved = self.current_source_file;
                        self.setCurrentSourceFile(target.target_module_path);
                        const ty = self.resolveNominalLeaf(qname[dot + 1 ..], false, node.span);
                        self.setCurrentSourceFile(saved);
                        return ty;
                    }
                }
            }
        }
        // A `Tuple(...)` element must denote a TYPE; a VALUE-literal element —
        // e.g. the `1` in `Tuple(i32, 1)` — is a user error. Diagnose it loudly
        // here (the same message the `.( ... )`-in-type path emits) BEFORE
        // `resolveCompound` would intern a tuple carrying an `.unresolved`
        // field. Only the unambiguous value literals are rejected: an
        // `error_type_expr` element (`-> Tuple(A, B) !` desugaring), names,
        // and the structural type shapes are all legitimate tuple elements.
        if (node.data == .tuple_type_expr) {
            for (node.data.tuple_type_expr.field_types) |ft| {
                // A signed numeric literal (`Tuple(i32, -1)`) arrives as a
                // `negate` unary over an int/float literal — reject it as the
                // literal it wraps, not as a generic non-type.
                const probe = if (ft.data == .unary_op and ft.data.unary_op.op == .negate)
                    ft.data.unary_op.operand
                else
                    ft;
                switch (probe.data) {
                    .int_literal,
                    .float_literal,
                    .string_literal,
                    .bool_literal,
                    .char_literal,
                    .null_literal,
                    => {
                        if (self.diagnostics) |diags| {
                            diags.addFmt(.err, ft.span, "tuple type element is not a type (found `{s}`); a tuple used as a type must list only types, e.g. `Tuple(i32, i32)`", .{@tagName(probe.data)});
                        }
                        return .unresolved;
                    },
                    else => {},
                }
            }
        }
        // Structural type shapes — `*T`, `[*]T`, `[]T`, `?T`, `[N]T`, functions,
        // PLAIN closures, and PLAIN tuples — are owned by
        // `TypeResolver.resolveCompound` (A2.3b). Element types recurse through
        // the full stateful resolver (`resolveInner` → here) so generic structs
        // / bindings keep their resolution. resolveCompound returns null only
        // for the pack-shaped forms (`Closure(..p)`, spread tuples) below.
        if (TypeResolver.resolveCompound(&self.module.types, node, self)) |t| return t;
        // Generic type-param binding (`$T`, or a bare return-type `T` without
        // the `$` prefix) — owned by TypeResolver via the explicit ResolveEnv.
        // The parameterized / call / closure / function arms that used to live
        // here were redundant with the unconditional handling just below (both
        // read the active bindings through the same resolvers), so they're gone.
        if (TypeResolver.resolveBinding(node, self.resolveEnv())) |t| return t;
        // Even without active type_bindings, handle parameterized types with struct templates
        if (node.data == .parameterized_type_expr) {
            return self.resolveParameterizedWithBindings(&node.data.parameterized_type_expr, node.span);
        }
        if (node.data == .call) {
            return self.resolveTypeCallWithBindings(&node.data.call);
        }
        // Plain structural shapes were handled by resolveCompound above. What
        // reaches here is the PACK-shaped subset, owned by `PackResolver`
        // (packs.zig): pack-shaped `Closure(..p)` and spread tuples. (Functions
        // are never pack-shaped at the type level — resolveCompound owns them
        // all, so there is no function arm here.)
        switch (node.data) {
            .closure_type_expr => |ct| {
                return self.packResolver().resolveClosureTypeWithBindings(&ct);
            },
            .tuple_type_expr => |tt| {
                return self.packResolver().resolveTupleTypeWithBindings(&tt);
            },
            // `(..$Ts)` in a type position (e.g. a struct field) parses as a
            // tuple LITERAL whose elements include a pack spread; PackResolver
            // expands it (returns null when no spread, so we fall through).
            .tuple_literal => |tl| {
                if (self.packResolver().resolveTupleLiteralType(&tl)) |t| return t;
            },
            else => {},
        }
        // An unbound generic type param (`$R` with no active binding) must not
        // fabricate an empty-struct stub — that surfaces as `R{}` downstream.
        // Return `.unresolved` so callers (e.g. lambda return-type inference,
        // call-site `$R` inference) treat it as not-yet-known.
        if (node.data == .type_expr and node.data.type_expr.is_generic) {
            // A VALUE param (`$N: u32`) named in a TYPE position (`x: N`) is bound
            // to a compile-time integer, not a type, so `resolveBinding` above
            // found no TYPE binding and it lands here. In the MAIN file the
            // `UnknownTypeChecker` owns this diagnostic (and halts before codegen);
            // an imported template's fields are resolved in the template's source
            // context (see `instantiateGenericStruct`) and are checker-trusted, so
            // this leaf is the sole guard — emit the tailored hint, mirroring the
            // imported `.undeclared` leaf. A genuinely-unbound type param (`$R`,
            // no value binding) stays a silent `.unresolved`.
            const nm = node.data.type_expr.name;
            const bound_value = if (self.comptime_value_bindings) |cvb| cvb.contains(nm) else false;
            if (bound_value) {
                const is_main = if (self.main_file) |mf|
                    (if (self.current_source_file) |csf| std.mem.eql(u8, csf, mf) else true)
                else
                    true;
                if (!is_main) {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, node.span, "'{s}' is a value parameter, not a type; introduce a generic type parameter with `${s}: Type`", .{ nm, nm });
                }
            }
            return .unresolved;
        }
        // Bare type names resolve through the source-aware `selectNominalLeaf`
        // (E1): the nominal author is selected over the ONE graph-walk collector
        // and resolved against the source-keyed caches, not the global
        // `findByName` first-match / global alias map. Other node kinds (inline
        // type decls, error types) still route through type_bridge, which reads
        // the global compat maps (cut over in a later phase).
        switch (node.data) {
            .type_expr => |te| {
                // Qualified `alias.Type` (incl. a carried alias): resolve the
                // base name pinned to the alias's target module.
                if (std.mem.lastIndexOfScalar(u8, te.name, '.')) |dot| {
                    if (self.namespaceAliasTarget(te.name[0..dot], node.span)) |target| {
                        const saved = self.current_source_file;
                        self.setCurrentSourceFile(target.target_module_path);
                        const ty = self.resolveNominalLeaf(te.name[dot + 1 ..], te.is_raw, node.span);
                        self.setCurrentSourceFile(saved);
                        return ty;
                    }
                    // A dotted `type_expr` whose prefix is NOT a namespace alias
                    // is the only remaining qualified form — and sx has no
                    // `Type.NestedType` access, so this is a VALUE field access
                    // (`g.a` where `g` is a value) sitting in a type position.
                    // Without this guard `resolveNominalLeaf("g.a")` would
                    // fabricate a zero-field empty-struct stub (`{}`) and ship it
                    // to codegen as a real type (issue 0189) — a silent-default
                    // miscompile. Reject loudly and poison with `.unresolved`.
                    // A genuinely registered dotted type (none today, but a
                    // forward-declared stub could exist) is still honored before
                    // we reject, so we never reject a name that resolves to a
                    // real type.
                    if (!self.aliasDeclaredAnywhere(te.name[0..dot])) {
                        const sid = self.module.types.internString(te.name);
                        if (self.module.types.findByName(sid)) |tid| {
                            const info = self.module.types.get(tid);
                            const is_empty_stub = info == .@"struct" and info.@"struct".fields.len == 0;
                            if (!is_empty_stub) return tid;
                        }
                        if (self.diagnostics) |d|
                            d.addFmt(.err, node.span, "expected a type, found a value '{s}' in type position", .{te.name});
                        return .unresolved;
                    }
                }
                return self.resolveNominalLeaf(te.name, te.is_raw, node.span);
            },
            .identifier => |id| return self.resolveNominalLeaf(id.name, id.is_raw, node.span),
            // A non-spread tuple literal in a type position is a tuple-type
            // literal (`(i32, i32)`); validate its elements are types and reject
            // non-type elements loudly.
            .tuple_literal => return self.resolveTupleLiteralTypeArg(node),
            // Inline type declarations used as a field type (`x: enum { ... }`,
            // `x: struct { ... }`, `x: union { ... }`): build their bodies with
            // THIS lowering as the `inner` recursion hook, so a payload / field
            // type NAME resolves in the enclosing module's visibility context —
            // the SAME own-wins-over-namespaced rule the top-level registration
            // uses (issue 0132's class). Delegating to the flat `else` below
            // dropped `self`, leaving inline-decl payloads on the global
            // `findByName` first-match.
            .enum_decl => return type_bridge.resolveInlineEnum(&node.data.enum_decl, &self.module.types, self),
            .struct_decl => return type_bridge.resolveInlineStruct(&node.data.struct_decl, &self.module.types, self),
            .union_decl => return type_bridge.resolveInlineUnion(&node.data.union_decl, &self.module.types, self),
            // A NAMED error-set reference (`!Named`) resolves its name through
            // `self` (visibility-aware) too; the bare `!` inferred set has no name
            // to shadow. NOTE: this reference-side resolution is currently DORMANT
            // for same-name error-set collisions — error-set DECLARATIONS don't
            // yet get per-decl nominal identity (E6a covers struct/enum/union
            // only), so a same-name set collapses to one TypeId at registration
            // and there is nothing distinct for the reference to select. See issue
            // 0134; once decls get nominal identity this activates with no change
            // here. `error_set_decl` is NOT in this switch: it interns only tag
            // names, resolving no type names, so it stays on the flat `else`.
            .error_type_expr => return type_bridge.resolveErrorType(&node.data.error_type_expr, &self.module.types, self),
            else => return type_bridge.resolveAstType(node, &self.module.types, &self.program_index.type_alias_map, &self.program_index.module_const_map),
        }
    }

    /// Bind a `PackResolver` to this Lowering for pack-aware TYPE-position
    /// resolution (`Closure(..p)` / `(Params...) -> R` / `(..xs)` tuples and
    /// their `..xs.T` projections). A2.3 moved that logic into `packs.zig`.
    pub fn packResolver(self: *Lowering) PackResolver {
        return .{ .l = self };
    }

    /// Resolve a `Vector(N, T)` lane count to a positive compile-time integer
    /// through the shared `program_index.foldDimU32` folder (min 1) — so a literal
    /// (`Vector(4, f32)`), a module/generic const (`Vector(N, f32)`), and a const
    /// expression (`Vector(M + 1, f32)`) all resolve identically, and the i64→u32
    /// narrowing is range-checked (an oversized lane diagnoses instead of
    /// panicking). A non-const lane (`Vector(get(), f32)`) or a
    /// non-positive one emits a clean diagnostic and returns null; the caller
    /// yields `.unresolved` rather than fabricating a `<0 x float>` lane count
    /// that crashes LLVM verification.
    pub fn resolveVectorLane(self: *Lowering, lane_node: *const Node) ?u32 {
        switch (program_index_mod.foldDimU32(lane_node, self, 1)) {
            .ok => |n| return n,
            .too_large => |v| {
                if (self.diagnostics) |d|
                    d.addFmt(.err, lane_node.span, "Vector lane count {} does not fit in u32", .{v});
                return null;
            },
            .non_integral_float => |v| {
                if (self.diagnostics) |d|
                    d.addFmt(.err, lane_node.span, "Vector lane count must be an integer, but '{d}' is a non-integral float", .{v});
                return null;
            },
            .not_const, .below_min => {
                if (self.diagnostics) |d|
                    d.addFmt(.err, lane_node.span, "Vector lane count must be a positive compile-time integer constant", .{});
                return null;
            },
        }
    }

    /// Infer the type of an expression from its AST node (used for untyped var decls).
    pub fn inferExprType(self: *Lowering, node: *const Node) TypeId {
        return switch (node.data) {
            .call => |*c| self.callResolver().resultType(c),
            else => self.exprTyper().inferType(node),
        };
    }

    fn exprTyper(self: *Lowering) ExprTyper {
        return .{ .l = self };
    }

    pub fn callResolver(self: *Lowering) CallResolver {
        return .{ .l = self };
    }

    /// A `Resolver` facade over the borrowed Phase A import facts (Phase B). Cheap
    /// by-value; `collectVisibleAuthors`'s `AuthorSet.flat` slice is backed by
    /// `self.alloc` and owned by the caller (`selectPlainCallableAuthor` frees it).
    pub fn resolver(self: *Lowering) resolver_mod.Resolver {
        return resolver_mod.Resolver.init(&self.program_index, self.alloc);
    }

    pub fn genericResolver(self: *Lowering) GenericResolver {
        return .{ .l = self };
    }

    pub fn protocolResolver(self: *Lowering) ProtocolResolver {
        return .{ .l = self };
    }

    pub fn coercionResolver(self: *Lowering) CoercionResolver {
        return .{ .l = self };
    }

    pub fn errorAnalysis(self: *Lowering) ErrorAnalysis {
        return .{ .l = self };
    }

    pub fn errorFlow(self: *Lowering) ErrorFlow {
        return .{ .l = self };
    }

    pub fn objc(self: *Lowering) ObjcLowering {
        return .{ .l = self };
    }

    /// Check if a name refers to a known type (primitive or registered struct/enum/union).
    /// Used to distinguish type-as-value (silent placeholder) from genuinely unresolved names.
    pub fn isKnownTypeName(self: *Lowering, name: []const u8) bool {
        if (type_bridge.resolveTypePrimitive(name) != null) return true;
        if (self.type_bindings) |bindings| {
            if (bindings.get(name) != null) return true;
        }
        if (self.program_index.type_alias_map.get(name) != null) return true;
        const name_id = self.module.types.internString(name);
        return self.module.types.findByName(name_id) != null;
    }

    /// Update `self.current_source_file` and mirror it onto `diags.current_source_file`,
    /// so any diagnostic emitted from inside a function lowered from another module is
    /// attributed to that module — not whichever file the diagnostics list was init'd with.
    pub fn setCurrentSourceFile(self: *Lowering, source_file: ?[]const u8) void {
        self.current_source_file = source_file;
        if (self.diagnostics) |d| d.current_source_file = source_file;
    }

    /// Stamp a caller-provided comptime `$`-arg node with the caller's source
    /// file. When the node is later substituted into the (defining-module-pinned)
    /// metaprogram body and lowered, lowerExpr's per-node source switch resolves
    /// its bare names in the CALLER's visibility context — not the callee's — so
    /// a caller-owned helper passed to an imported metaprogram stays visible.
    /// Only stamps a node with no source yet, and only when the caller context
    /// is known; an unknown caller source leaves the node's fall-open intact.
    pub fn stampCallerSource(self: *Lowering, node: *Node) void {
        if (node.source_file != null) return;
        if (self.current_source_file) |src| node.source_file = src;
    }

    pub fn emitError(self: *Lowering, name: []const u8, span: ?ast.Span) Ref {
        if (self.diagnostics) |diags| {
            // The literal message carries the lowering's `current_source_file`
            // and enclosing function name. The diagnostic renderer's
            // `source_file` -> `file:line:col` prefix can drift when a span is
            // offset into one source but the diagnostic falls back to another
            // (e.g. synthetic AST nodes inserted from `#insert` take their
            // span from the call site, not from the string being inserted).
            // Embedding the file + function in the message means a
            // misattributed span can never hide WHERE the lookup actually
            // failed. Setting SX_TRACE_UNRESOLVED=1 also dumps a Zig stack
            // trace at the emit site to surface the calling lowering path.
            const sf = self.current_source_file orelse "<unknown>";
            const fn_name: []const u8 = if (self.builder.func) |fid|
                self.module.types.getString(self.module.functions.items[@intFromEnum(fid)].name)
            else
                "<top-level>";
            if (std.c.getenv("SX_TRACE_UNRESOLVED") != null) {
                std.debug.print("\n== unresolved '{s}' (in {s} fn {s}) ==\n", .{ name, sf, fn_name });
                std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
            }
            diags.addFmt(.err, span, "unresolved '{s}' (in {s} fn {s})", .{ name, sf, fn_name });
        }
        return self.emitPlaceholder(name);
    }

    /// A static nested `::` function referenced an ENCLOSING function's local /
    /// param / local-const `name`. It has no environment to reach it — the only
    /// spelling that captures is a closure. Diagnose loudly (was a silent dead
    /// Ref → `undef` read, issue 0250) and emit a placeholder; `hasErrors()`
    /// aborts before codegen so the placeholder never runs. Deduped per
    /// (function, name): the guard sits at every resolution layer and a
    /// speculative fast path's diagnostic would otherwise repeat when its
    /// null-fallback re-lowers the same identifier through another guard.
    pub fn diagEnclosingLocalRef(self: *Lowering, name: []const u8, span: ?ast.Span) Ref {
        if (self.diagnostics) |diags| {
            const fn_idx: u32 = if (self.builder.func) |fid| @intFromEnum(fid) else std.math.maxInt(u32);
            const key = std.fmt.allocPrint(self.alloc, "{d}:{s}", .{ fn_idx, name }) catch name;
            const gop = self.diag_enclosing_seen.getOrPut(key) catch null;
            const first = if (gop) |g| !g.found_existing else true;
            if (first) {
                diags.addFmt(.err, span, "a nested function cannot reference the enclosing local '{s}' — use a closure ('{s} := () => ...') to capture it", .{ name, name });
            }
        }
        return self.emitPlaceholder(name);
    }

    pub fn emitFieldError(self: *Lowering, obj_ty: TypeId, field: []const u8, span: ast.Span) Ref {
        // A field access on an already-`.unresolved` object is a cascade from an
        // upstream type-resolution failure that was ALREADY diagnosed (e.g. an
        // unresolvable / oversized array dimension). The
        // `.unresolved` sentinel never exists without an accompanying error, so
        // piling a second "field not found on unresolved" onto the real one is
        // pure noise; stay silent and return a placeholder so lowering finishes
        // and `hasErrors()` aborts the build on the genuine diagnostic.
        if (obj_ty != .unresolved) {
            if (self.diagnostics) |diags| {
                const ty_name = self.formatTypeName(obj_ty);
                const id = diags.addFmtId(.err, span, "field '{s}' not found on type '{s}'", .{ field, ty_name });
                // An unknown field on the CONTEXT enumerates the program's
                // registered `#context_extend` fields (shared O3 helper) —
                // covers both `context.typo` reads and `push .{ typo = … }`.
                if (self.module.types.findByName(self.module.types.internString("Context"))) |ctx_ty| {
                    if (obj_ty == ctx_ty) self.noteRegisteredContextFields(id);
                }
            }
        }
        return self.emitPlaceholder(field);
    }

    /// Get the alloca Ref for an expression, if it's a simple variable reference.
    /// Returns null for complex expressions (field access, function calls, etc.)
    /// An alloca reached only ACROSS a nested-fn boundary is an enclosing
    /// function's storage — dead in this function's SSA context (issue 0250
    /// fold: the indexed-read fast path / lvalue helpers segfaulted through
    /// it). Diagnose and return null; every caller's null path lowers the
    /// expression through the identifier machinery, which is boundary-guarded
    /// (the duplicate diagnostic is suppressed via `diag_enclosing_seen`).
    pub fn getExprAlloca(self: *Lowering, node: *const Node) ?Ref {
        const name = switch (node.data) {
            .identifier => |id| id.name,
            .type_expr => |te| te.name,
            else => return null,
        };
        if (self.scope) |scope| {
            const sb = scope.lookupBoundary(name);
            if (sb.crossed_fn_boundary) {
                _ = self.diagEnclosingLocalRef(name, node.span);
                return null;
            }
            if (sb.binding) |binding| {
                if (binding.is_alloca) return binding.ref;
            }
        }
        return null;
    }

    /// True when `node` is an lvalue chain rooted in real storage — a local
    /// alloca or a module global — reached through field accesses, indexing,
    /// and pointer derefs. Exactly the shapes `lowerExprAsPtr` resolves to a
    /// genuine address: a by-value SSA binding at the root (loop/match/catch
    /// capture, `::` const) or an rvalue root (call result, literal) would
    /// make its value fallback fire, handing back a VALUE where the caller
    /// expects a pointer — those return false. A comptime pack index is
    /// excluded too: a pack element has no runtime storage (issue 0135).
    pub fn exprHasAddressableStorage(self: *Lowering, node: *const Node) bool {
        switch (node.data) {
            .identifier => |id| {
                if (self.scope) |scope| {
                    const sb = scope.lookupBoundary(id.name);
                    if (sb.crossed_fn_boundary) return false;
                    if (sb.binding) |binding| return binding.is_alloca;
                }
                // Global check mirrors `resolveGlobalRef` minus its
                // diagnostics — the ambiguous/not-visible outcomes fall to
                // the value path, which diagnoses them exactly once.
                if (self.program_index.global_names.get(id.name) == null) return false;
                return switch (self.selectGlobalAuthor(id.name)) {
                    .resolved, .untracked => true,
                    .not_a_global, .ambiguous, .not_visible => false,
                };
            },
            .deref_expr => return true,
            .field_access => |fa| return self.exprHasAddressableStorage(fa.object),
            .index_expr => |ie| return self.packArgNodeAt(&ie) == null and self.exprHasAddressableStorage(ie.object),
            else => return false,
        }
    }

    /// Get the element type for a slice/array/string type. A non-collection
    /// type has no element type — return `.unresolved` (asking for it is a bug)
    /// rather than a plausible `.i64`.
    pub fn getElementType(self: *Lowering, ty: TypeId) TypeId {
        if (ty == .string) return .u8;
        if (ty.isBuiltin()) return .unresolved;
        const info = self.module.types.get(ty);
        return switch (info) {
            .slice => |s| s.element,
            .array => |a| a.element,
            .vector => |v| v.element,
            .many_pointer => |p| p.element,
            else => .unresolved,
        };
    }

    /// The element type when `ty` is a POINTER TO AN ARRAY (`*[N]T` → T),
    /// else null. Indexing auto-derefs this shape (GEP the pointee array
    /// through the pointer value); kept OUT of `getElementType` so the
    /// slice/subslice paths don't half-accept a raw pointer base.
    pub fn ptrToArrayElem(self: *Lowering, ty: TypeId) ?TypeId {
        if (ty.isBuiltin()) return null;
        const info = self.module.types.get(ty);
        if (info != .pointer) return null;
        const pointee = info.pointer.pointee;
        if (pointee.isBuiltin()) return null;
        const pi = self.module.types.get(pointee);
        return if (pi == .array) pi.array.element else null;
    }

    /// The element type when `ty` is a pointer to a slice (`*[]T`).  This
    /// shape auto-dereferences for indexing and `.len` per specs.md.
    pub fn ptrToSliceElem(self: *Lowering, ty: TypeId) ?TypeId {
        if (ty.isBuiltin()) return null;
        const info = self.module.types.get(ty);
        if (info != .pointer) return null;
        const pointee = info.pointer.pointee;
        if (pointee.isBuiltin()) return null;
        const pi = self.module.types.get(pointee);
        return if (pi == .slice) pi.slice.element else null;
    }

    /// Load the slice value behind a `*[]T` index base. Other indexable bases
    /// are already values in the representation expected by index_get/GEP.
    pub fn derefPtrToSliceIndexBase(self: *Lowering, base: Ref, ty: TypeId) Ref {
        if (self.ptrToSliceElem(ty) == null) return base;
        return self.builder.load(base, self.module.types.get(ty).pointer.pointee);
    }

    pub fn isFloat(ty: TypeId) bool {
        return ty == .f32 or ty == .f64;
    }

    /// Result type of an arithmetic / bitwise / shift binary op over two
    /// scalar operand types. This is the single promotion rule shared by the
    /// value path (`lowerBinaryOp`) and AST-level inference
    /// (`ExprTyper.inferType`'s binary-op arm), so static typing reports
    /// exactly the type the lowered value carries. An integer LHS with a
    /// floating-point RHS promotes to the float (`i64 + f64` → `f64`); every
    /// other pairing — including vectors / structs, whose `isInt` is false —
    /// takes the LHS type. Comparison / logical ops never reach here (they
    /// are `.bool` at both sites).
    pub fn arithResultType(lhs_ty: TypeId, rhs_ty: TypeId) TypeId {
        if (isInt(lhs_ty) and isFloat(rhs_ty)) return rhs_ty;
        return lhs_ty;
    }

    fn isInt(ty: TypeId) bool {
        return switch (ty) {
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .usize, .isize => true,
            else => false,
        };
    }

    /// Carry-rule resolution outcome for a namespace alias, diagnostic-free.
    pub const AliasVerdict = union(enum) {
        /// No edge anywhere visible from the current file binds this alias.
        none,
        /// ≥2 DIRECT flat imports carry the alias to DISTINCT targets.
        ambiguous,
        /// The alias resolves — own edge, or carried over one flat hop.
        target: imports_mod.NamespaceTarget,
    };

    /// Resolve a namespace alias visible from the current source file under
    /// the carry rule: the file's OWN `ns :: #import` edge wins; otherwise an
    /// alias declared by a DIRECT flat import is carried (one level — flat
    /// edges of flat edges do not chain). Two distinct carried targets for
    /// the same alias are ambiguous.
    pub fn namespaceAliasVerdict(self: *Lowering, alias: []const u8) AliasVerdict {
        const from = self.current_source_file orelse return .none;
        return self.namespaceAliasVerdictFrom(alias, from);
    }

    /// `namespaceAliasVerdict` with an explicit querying source — for callers
    /// resolving an alias on behalf of ANOTHER module (e.g. following a const
    /// alias decl whose RHS is `ns.X`: `ns` binds in the alias author's file,
    /// not the use site's).
    pub fn namespaceAliasVerdictFrom(self: *Lowering, alias: []const u8, from: []const u8) AliasVerdict {
        const edges = self.program_index.namespace_edges orelse return .none;
        if (edges.getPtr(from)) |own| {
            if (own.get(alias)) |t| return .{ .target = t };
        }
        const flat = self.program_index.flat_import_graph orelse return .none;
        const direct = flat.get(from) orelse return .none;
        var found: ?imports_mod.NamespaceTarget = null;
        var it = direct.keyIterator();
        while (it.next()) |dep| {
            const dep_edges = edges.getPtr(dep.*) orelse continue;
            const t = dep_edges.get(alias) orelse continue;
            if (found) |f| {
                if (!std.mem.eql(u8, f.target_module_path, t.target_module_path)) return .ambiguous;
            } else found = t;
        }
        return if (found) |f| .{ .target = f } else .none;
    }

    /// `namespaceAliasVerdict` with the ambiguity diagnosed in place; callers
    /// that don't distinguish ambiguous-from-missing use this form.
    pub fn namespaceAliasTarget(self: *Lowering, alias: []const u8, span: ?ast.Span) ?imports_mod.NamespaceTarget {
        switch (self.namespaceAliasVerdict(alias)) {
            .target => |t| return t,
            .ambiguous => {
                if (self.diagnostics) |d| {
                    d.addFmt(.err, span, "namespace '{s}' is ambiguous: aliases from multiple flat-imported modules point at different targets; declare the alias locally", .{alias});
                }
                return null;
            },
            .none => return null,
        }
    }

    /// True when ANY module in the program declares `alias` as a namespace
    /// edge — distinguishes a not-visible alias (gate error) from a name that
    /// was never an alias at all (fall through to other resolution).
    pub fn aliasDeclaredAnywhere(self: *Lowering, alias: []const u8) bool {
        const edges = self.program_index.namespace_edges orelse return false;
        var it = edges.valueIterator();
        while (it.next()) |per_file| {
            if (per_file.contains(alias)) return true;
        }
        return false;
    }

    /// The target module's own fn member named `name` — a top-level fn decl
    /// or a const-wrapped fn (the same surface `registerNamespaceQualifiedFns`
    /// registers). Null when the member is absent or not a function.
    pub fn namespaceFnMember(self: *Lowering, target: *const imports_mod.NamespaceTarget, name: []const u8) ?*const ast.FnDecl {
        for (target.own_decls) |decl| {
            switch (decl.data) {
                .fn_decl => |*fd| if (std.mem.eql(u8, fd.name, name)) return fd,
                .const_decl => |*cd| if (std.mem.eql(u8, cd.name, name)) {
                    if (cd.value.data == .fn_decl) return &cd.value.data.fn_decl;
                    // A namespace function re-export (`write :: c.write`) is
                    // still a member of THIS namespace. Follow the alias from
                    // the declaration's own source so calls through the outer
                    // namespace inherit the terminal function's signature and
                    // dispatch, instead of falling through to an unrelated
                    // same-named global winner (issue 0282).
                    const from = decl.source_file orelse target.target_module_path;
                    if (self.aliasedFnDecl(cd, from)) |fd| return fd;
                },
                else => {},
            }
        }
        return null;
    }

    /// Reconstruct a dotted name from a pure identifier/field_access chain
    /// (`a.b.C` → "a.b.C"); null if any segment isn't a plain name. The caller
    /// owns and frees the returned slice. Used to resolve a qualified type
    /// prefix written in expression position (`m.Cfg.{...}` — issue 0204).
    pub fn qualifiedTypeName(self: *Lowering, node: *const Node) ?[]const u8 {
        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(self.alloc);
        var cur = node;
        while (true) {
            switch (cur.data) {
                .field_access => |fa| {
                    parts.append(self.alloc, fa.field) catch return null;
                    cur = fa.object;
                },
                .identifier => |id| {
                    parts.append(self.alloc, id.name) catch return null;
                    break;
                },
                else => return null,
            }
        }
        // `parts` is leaf-first (`[C, b, a]`); join reversed with '.'.
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.alloc);
        var i: usize = parts.items.len;
        while (i > 0) {
            i -= 1;
            buf.appendSlice(self.alloc, parts.items[i]) catch return null;
            if (i > 0) buf.append(self.alloc, '.') catch return null;
        }
        return buf.toOwnedSlice(self.alloc) catch return null;
    }

    /// The inner member name when `node` is a namespace-rooted prefix
    /// (`alias.Member`) — the shape a qualified type/static head takes after
    /// stripping the alias. Null when `node` isn't that shape.
    pub fn namespaceRootedMember(self: *Lowering, node: *const Node) ?[]const u8 {
        if (node.data != .field_access) return null;
        const fa = node.data.field_access;
        const root = switch (fa.object.data) {
            .identifier => |id| id.name,
            else => return null,
        };
        // A value binding shadows a same-named namespace alias.
        if (self.scope) |s| {
            if (s.lookup(root) != null) return null;
        }
        if (self.program_index.global_names.contains(root)) return null;
        if (self.namespaceAliasTarget(root, node.span) == null) return null;
        return fa.field;
    }

    pub fn isIntEx(self: *Lowering, ty: TypeId) bool {
        if (isInt(ty)) return true;
        if (!ty.isBuiltin()) {
            const info = self.module.types.get(ty);
            return switch (info) {
                .signed, .unsigned => true,
                else => false,
            };
        }
        return false;
    }

    /// Value range of an integer type, for literal fits-checks. Null for
    /// 64-bit types — every i64 literal bit pattern is legal there (a 64-bit
    /// hex literal wraps negative through the lexer's i64 value, so a
    /// min/max check would false-positive) — and for non-integers.
    pub fn intLiteralRange(self: *Lowering, ty: TypeId) ?struct { min: i64, max: i64 } {
        var width: u8 = 0;
        var is_signed = false;
        switch (ty) {
            .i8 => {
                width = 8;
                is_signed = true;
            },
            .i16 => {
                width = 16;
                is_signed = true;
            },
            .i32 => {
                width = 32;
                is_signed = true;
            },
            .u8 => width = 8,
            .u16 => width = 16,
            .u32 => width = 32,
            else => {
                if (ty.isBuiltin()) return null; // i64/u64/isize/usize/non-int
                switch (self.module.types.get(ty)) {
                    .signed => |w| {
                        width = w;
                        is_signed = true;
                    },
                    .unsigned => |w| width = w,
                    else => return null,
                }
                if (width >= 64) return null;
            },
        }
        if (is_signed) {
            const max = (@as(i64, 1) << @intCast(width - 1)) - 1;
            return .{ .min = -max - 1, .max = max };
        }
        const max = (@as(i64, 1) << @intCast(width)) - 1;
        return .{ .min = 0, .max = max };
    }

    /// Max NON-NEGATIVE magnitude a bare integer literal may hold in `ty`. A
    /// bare `int_literal` is always non-negative (negation is a separate fold),
    /// so its true value is the unsigned magnitude — checked against this cap.
    /// Uses `u64` so the 64-bit widths are EXACT (`i64` → i64.max, `u64` →
    /// u64.max), unlike `intLiteralRange` which returns null there because a
    /// >i64.max value can't be an i64 range bound. Null for non-integers.
    pub fn intLiteralMaxMagnitude(self: *Lowering, ty: TypeId) ?u64 {
        var width: u8 = 0;
        var is_signed = false;
        switch (ty) {
            .i8 => {
                width = 8;
                is_signed = true;
            },
            .i16 => {
                width = 16;
                is_signed = true;
            },
            .i32 => {
                width = 32;
                is_signed = true;
            },
            .i64, .isize => {
                width = 64;
                is_signed = true;
            },
            .u8 => width = 8,
            .u16 => width = 16,
            .u32 => width = 32,
            .u64, .usize => width = 64,
            else => {
                if (ty.isBuiltin()) return null;
                switch (self.module.types.get(ty)) {
                    .signed => |w| {
                        width = w;
                        is_signed = true;
                    },
                    .unsigned => |w| width = w,
                    else => return null,
                }
            },
        }
        if (is_signed) {
            // 2^(width-1) - 1 (width 64 → i64.max; no overflow: 1<<63 fits u64)
            return (@as(u64, 1) << @intCast(width - 1)) - 1;
        }
        // 2^width - 1 (width 64 → u64.max; 1<<64 would overflow, special-case)
        if (width >= 64) return std.math.maxInt(u64);
        return (@as(u64, 1) << @intCast(width)) - 1;
    }

    /// Fits-check for a BARE integer literal, magnitude-based (see
    /// `intLiteralMaxMagnitude`). Correctly admits a `u64` literal up to
    /// u64.max while still rejecting a >i64.max literal at an `i64` destination.
    /// The constant is still emitted by the caller so lowering continues.
    pub fn checkIntLiteralMagnitudeFits(self: *Lowering, value: i64, ty: TypeId, span: ast.Span) void {
        if (self.suppress_int_fit_check) return;
        const cap = self.intLiteralMaxMagnitude(ty) orelse return;
        const mag: u64 = @bitCast(value);
        if (mag <= cap) return;
        // Cast operand (issue 0275): a `cast(T) <lit>` folds against T (the
        // ambient `ty` here) but still TRUNCATES, so a literal that fits i64
        // yet overflows a narrower T (`cast(i8) 300`) must be accepted, not
        // rejected. `int_lit_extra_fit_ty` (set to i64 for the cast operand)
        // is that additional allowed range: accept when the value fits it,
        // erroring only when it fits NEITHER T NOR i64.
        if (self.int_lit_extra_fit_ty) |extra| {
            if (self.intLiteralMaxMagnitude(extra)) |ecap| {
                if (mag <= ecap) return;
            }
        }
        const d = self.diagnostics orelse return;
        var name_buf: [8]u8 = undefined;
        const tn = blk: {
            if (ty.isBuiltin()) break :blk self.module.types.typeName(ty);
            break :blk switch (self.module.types.get(ty)) {
                .signed => |w| std.fmt.bufPrint(&name_buf, "i{d}", .{w}) catch "integer",
                .unsigned => |w| std.fmt.bufPrint(&name_buf, "u{d}", .{w}) catch "integer",
                else => self.module.types.typeName(ty),
            };
        };
        // Sub-64-bit types have an i64-expressible range — keep the exact
        // "(range min..max)" wording. The 64-bit types (i64/u64) can't (their
        // bound overflows i64), so report the max magnitude instead.
        if (self.intLiteralRange(ty)) |r| {
            d.addFmt(.err, span, "integer literal {} does not fit in {s} (range {}..{}) — use an explicit `xx` / `.(T)` to truncate", .{ mag, tn, r.min, r.max });
        } else {
            d.addFmt(.err, span, "integer literal {} does not fit in {s} (max {}) — use an explicit `xx` / `.(T)` to truncate", .{ mag, tn, cap });
        }
    }

    /// Diagnose an integer literal that cannot be represented in `ty`
    /// (REJECTED PATTERNS: no silent wrap). The constant is still emitted by
    /// the caller so lowering continues and surfaces further errors.
    pub fn checkIntLiteralFits(self: *Lowering, value: i64, ty: TypeId, span: ast.Span) void {
        if (self.suppress_int_fit_check) return;
        const r = self.intLiteralRange(ty) orelse return;
        if (value < r.min or value > r.max) {
            if (self.diagnostics) |d| {
                // Custom-width ints are structural (unnamed in the type
                // table) — render them as s{N}/u{N}.
                var name_buf: [8]u8 = undefined;
                const tn = blk: {
                    if (ty.isBuiltin()) break :blk self.module.types.typeName(ty);
                    break :blk switch (self.module.types.get(ty)) {
                        .signed => |w| std.fmt.bufPrint(&name_buf, "i{d}", .{w}) catch "integer",
                        .unsigned => |w| std.fmt.bufPrint(&name_buf, "u{d}", .{w}) catch "integer",
                        else => self.module.types.typeName(ty),
                    };
                };
                d.addFmt(.err, span, "integer literal {} does not fit in {s} (range {}..{}) — use an explicit `xx` / `.(T)` to truncate", .{ value, tn, r.min, r.max });
            }
        }
    }

    /// Diagnose a char literal whose code point cannot be represented in `ty`.
    /// Same range logic as `checkIntLiteralFits`, but a char-specific message:
    /// the value is a code point the user wants to KEEP, so the fix is a wider
    /// storage type (u32 holds any Unicode scalar), not truncation. The source
    /// `'raw'` is included so the user sees which literal overflowed. The
    /// constant is still emitted by the caller so lowering continues.
    pub fn checkCharLiteralFits(self: *Lowering, cl: ast.CharLiteral, ty: TypeId, span: ast.Span) void {
        if (self.suppress_int_fit_check) return;
        const r = self.intLiteralRange(ty) orelse return;
        if (cl.value < r.min or cl.value > r.max) {
            if (self.diagnostics) |d| {
                var name_buf: [8]u8 = undefined;
                const tn = blk: {
                    if (ty.isBuiltin()) break :blk self.module.types.typeName(ty);
                    break :blk switch (self.module.types.get(ty)) {
                        .signed => |w| std.fmt.bufPrint(&name_buf, "i{d}", .{w}) catch "integer",
                        .unsigned => |w| std.fmt.bufPrint(&name_buf, "u{d}", .{w}) catch "integer",
                        else => self.module.types.typeName(ty),
                    };
                };
                d.addFmt(.err, span, "char literal '{s}' (value {}) does not fit in {s} (range {}..{}) — use a wider type such as u32 to hold this code point", .{ cl.raw, cl.value, tn, r.min, r.max });
            }
        }
    }

    /// Operands valid for a scalar numeric op (`+ - * / %`): ints (incl.
    /// custom widths), floats, SIMD vectors, and pointers (pointer
    /// arithmetic). `.unresolved` returns true so a type we couldn't infer
    /// is never diagnosed — the check only fires on a concretely
    /// incompatible operand (e.g. `string`, a struct, an enum).
    pub fn isArithOperand(self: *Lowering, ty: TypeId) bool {
        if (ty == .unresolved) return true;
        if (isInt(ty) or isFloat(ty)) return true;
        if (ty.isBuiltin()) return false;
        return switch (self.module.types.get(ty)) {
            .signed, .unsigned, .vector, .pointer, .many_pointer => true,
            else => false,
        };
    }

    /// Operands valid for ordering comparisons (`< <= > >=`): numbers
    /// (incl. custom int widths), enums (ordinal), pointers (address
    /// order), bool, and SIMD vectors. NOT strings (no lexicographic `<`
    /// lowering exists) or any other aggregate. `.unresolved` passes so an
    /// un-inferable operand is never falsely diagnosed.
    pub fn isOrderingOperand(self: *Lowering, ty: TypeId) bool {
        if (ty == .unresolved) return true;
        if (isInt(ty) or isFloat(ty) or ty == .bool) return true;
        if (ty.isBuiltin()) return false;
        return switch (self.module.types.get(ty)) {
            .signed, .unsigned, .@"enum", .pointer, .many_pointer, .vector => true,
            else => false,
        };
    }

    /// Operands valid for bitwise/shift ops (`& | ^ << >>`): integers
    /// (incl. custom widths), enums (flags are int-backed), bool, and SIMD
    /// vectors. NOT floats, strings, pointers, or aggregates. `.unresolved`
    /// passes (see `isOrderingOperand`).
    pub fn isBitwiseOperand(self: *Lowering, ty: TypeId) bool {
        if (ty == .unresolved) return true;
        if (isInt(ty) or ty == .bool) return true;
        if (ty.isBuiltin()) return false;
        return switch (self.module.types.get(ty)) {
            .signed, .unsigned, .@"enum", .vector => true,
            else => false,
        };
    }

    /// Human-readable description of a typed module-const initializer, used in
    /// the typed-const type-mismatch diagnostic. A literal names its kind; a
    /// const-expression is described by its inferred type category, so the
    /// message is accurate for `N : string : M + 2` ("an integer expression")
    /// as well as for `N : string : 4` ("an integer literal").
    pub fn initializerDescription(self: *Lowering, node: *const Node) []const u8 {
        return switch (node.data) {
            .int_literal => "an integer literal",
            .float_literal => "a float literal",
            .bool_literal => "a boolean literal",
            .string_literal => "a string literal",
            .char_literal => "a char literal",
            .null_literal => "null",
            .undef_literal => "'---'",
            else => self.constExprDescription(self.inferExprType(node)),
        };
    }

    fn constExprDescription(self: *Lowering, init_ty: TypeId) []const u8 {
        if (self.isIntEx(init_ty)) return "an integer expression";
        if (isFloat(init_ty)) return "a floating-point expression";
        if (init_ty == .bool) return "a boolean expression";
        if (init_ty == .string) return "a string expression";
        return "an expression of an incompatible type";
    }

    pub fn binOpSymbol(op: ast.BinaryOp.Op) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .eq => "==",
            .neq => "!=",
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
            .and_op => "and",
            .or_op => "or",
            .bit_and => "&",
            .bit_or => "|",
            .bit_xor => "^",
            .shl => "<<",
            .shr => ">>",
            .in_op => "in",
        };
    }

    fn typeBits(ty: TypeId) u32 {
        return switch (ty) {
            .bool => 1,
            .i8, .u8 => 8,
            .i16, .u16 => 16,
            .i32, .u32 => 32,
            .i64, .u64 => 64,
            .usize, .isize => 0, // target-dependent — use typeBitsEx
            .f32 => 32,
            .f64 => 64,
            else => 0,
        };
    }

    pub fn typeBitsEx(self: *Lowering, ty: TypeId) u32 {
        if (ty == .usize or ty == .isize) return @as(u32, self.module.types.pointer_size) * 8;
        const b = typeBits(ty);
        if (b > 0) return b;
        if (!ty.isBuiltin()) {
            const info = self.module.types.get(ty);
            return switch (info) {
                .signed => |w| @as(u32, w),
                .unsigned => |w| @as(u32, w),
                else => 0,
            };
        }
        return 0;
    }

    // --- moved to lower/error.zig (lower_error) ---
    pub const getTraceFids = lower_error.getTraceFids;
    pub const tracesEnabled = lower_error.tracesEnabled;
    pub const emitTracePush = lower_error.emitTracePush;
    pub const emitTraceClear = lower_error.emitTraceClear;
    pub const placeholderTraceFrame = lower_error.placeholderTraceFrame;
    pub const errorSetTypeOf = lower_error.errorSetTypeOf;
    pub const isErrorTagLiteralNode = lower_error.isErrorTagLiteralNode;
    pub const tryLowerErrorSetEquality = lower_error.tryLowerErrorSetEquality;
    pub const effectiveReturnType = lower_error.effectiveReturnType;
    pub const errorChannelOf = lower_error.errorChannelOf;
    pub const isInferredErrorSet = lower_error.isInferredErrorSet;
    pub const checkErrorSetSubset = lower_error.checkErrorSetSubset;
    pub const diagTagsNotInSet = lower_error.diagTagsNotInSet;
    pub const lowerRaise = lower_error.lowerRaise;
    pub const lowerFailableSuccessReturn = lower_error.lowerFailableSuccessReturn;
    pub const coercePureFailableReturn = lower_error.coercePureFailableReturn;
    pub const buildFailableTuple = lower_error.buildFailableTuple;
    pub const failableSuccessType = lower_error.failableSuccessType;
    pub const failableReturnTarget = lower_error.failableReturnTarget;
    pub const extractSuccessValue = lower_error.extractSuccessValue;
    pub const extractErrorSlot = lower_error.extractErrorSlot;
    pub const emitTupleRet = lower_error.emitTupleRet;
    pub const diagRaiseNotFailable = lower_error.diagRaiseNotFailable;
    pub const exprIsFailable = lower_error.exprIsFailable;
    pub const lowerCallerLocation = lower_error.lowerCallerLocation;
    pub const sourceForFile = lower_error.sourceForFile;
    pub const currentFunctionName = lower_error.currentFunctionName;
    pub const lowerTry = lower_error.lowerTry;
    pub const emitErrorReturn = lower_error.emitErrorReturn;
    pub const diagTryNotFailable = lower_error.diagTryNotFailable;
    pub const lowerCatch = lower_error.lowerCatch;
    pub const lowerCatchOverChain = lower_error.lowerCatchOverChain;
    pub const finishCatchHandler = lower_error.finishCatchHandler;
    pub const runCatchBody = lower_error.runCatchBody;
    pub const checkEscapeWidening = lower_error.checkEscapeWidening;
    pub const orIsFailableChain = lower_error.orIsFailableChain;
    pub const operandIsFailableLike = lower_error.operandIsFailableLike;
    pub const isErasedAssertNode = lower_error.isErasedAssertNode;
    pub const desugarErasedAssert = lower_error.desugarErasedAssert;
    pub const orChainSuccessType = lower_error.orChainSuccessType;
    pub const unwrapTryNode = lower_error.unwrapTryNode;
    pub const flattenOrChain = lower_error.flattenOrChain;
    pub const lowerFailableOr = lower_error.lowerFailableOr;
    pub const callTargetName = lower_error.callTargetName;
    pub const astIsPureBareInferred = lower_error.astIsPureBareInferred;
    pub const astPureNamedSet = lower_error.astPureNamedSet;
    pub const namedSetTags = lower_error.namedSetTags;
    pub const convergeInferredErrorSets = lower_error.convergeInferredErrorSets;
    pub const containsTag = lower_error.containsTag;
    pub const convergeClosureShapeSets = lower_error.convergeClosureShapeSets;
    pub const recordClosureShape = lower_error.recordClosureShape;
    pub const calleeEscapeTags = lower_error.calleeEscapeTags;
    pub const unionShapeTags = lower_error.unionShapeTags;
    pub const closureShapeKey = lower_error.closureShapeKey;
    pub const returnValuePart = lower_error.returnValuePart;
    pub const shapeKeyOfCallee = lower_error.shapeKeyOfCallee;

    // --- moved to lower/comptime.zig (lower_comptime) ---
    pub const SelectedConst = lower_comptime.SelectedConst;
    pub const evalComptimeCondition = lower_comptime.evalComptimeCondition;
    pub const evalComptimeMatch = lower_comptime.evalComptimeMatch;
    pub const evalStaticTypeMatch = lower_comptime.evalStaticTypeMatch;
    pub const staticTypeMatchesCategory = lower_comptime.staticTypeMatchesCategory;
    pub const evalComptimeInt = lower_comptime.evalComptimeInt;
    pub const evalComptimeString = lower_comptime.evalComptimeString;
    pub const evalComptimeType = lower_comptime.evalComptimeType;
    pub const evalComptimeTypeBody = lower_comptime.evalComptimeTypeBody;
    pub const runComptimeTypeFunc = lower_comptime.runComptimeTypeFunc;
    pub const renameNominalType = lower_comptime.renameNominalType;
    pub const lowerComptimeGlobal = lower_comptime.lowerComptimeGlobal;
    pub const lowerComptimeSideEffect = lower_comptime.lowerComptimeSideEffect;
    pub const lowerComptimeCall = lower_comptime.lowerComptimeCall;
    pub const lowerComptimeCallArgs = lower_comptime.lowerComptimeCallArgs;
    pub const lowerComptimeCallArgsSkip = lower_comptime.lowerComptimeCallArgsSkip;
    pub const bindComptimeValueParams = lower_comptime.bindComptimeValueParams;
    pub const recordComptimeTag = lower_comptime.recordComptimeTag;
    pub const recordComptimeValueRef = lower_comptime.recordComptimeValueRef;
    pub const bindEnumValueParam = lower_comptime.bindEnumValueParam;
    pub const bindTaggedUnionValueParam = lower_comptime.bindTaggedUnionValueParam;
    pub const enumHasVariant = lower_comptime.enumHasVariant;
    pub const comptimeValueRefNamed = lower_comptime.comptimeValueRefNamed;
    pub const lowerInlineComptime = lower_comptime.lowerInlineComptime;
    pub const lowerInsertExpr = lower_comptime.lowerInsertExpr;
    pub const lowerInsertExprValue = lower_comptime.lowerInsertExprValue;
    pub const lowerComptimeDeps = lower_comptime.lowerComptimeDeps;
    pub const substituteComptimeNodes = lower_comptime.substituteComptimeNodes;
    pub const fnBodyHasReturn = lower_comptime.fnBodyHasReturn;
    pub const createComptimeFunction = lower_comptime.createComptimeFunction;
    pub const createComptimeFunctionWithPrelude = lower_comptime.createComptimeFunctionWithPrelude;
    pub const constExprValue = lower_comptime.constExprValue;
    pub const constArrayLiteral = lower_comptime.constArrayLiteral;
    pub const constStructLiteral = lower_comptime.constStructLiteral;
    pub const constEnumLiteral = lower_comptime.constEnumLiteral;
    pub const foldSourceConstInt = lower_comptime.foldSourceConstInt;
    pub const foldSourceConstFloat = lower_comptime.foldSourceConstFloat;
    pub const sourceConstIsFloatTyped = lower_comptime.sourceConstIsFloatTyped;
    pub const selectQualifiedConst = lower_comptime.selectQualifiedConst;
    pub const foldQualifiedConstInt = lower_comptime.foldQualifiedConstInt;
    pub const foldQualifiedConstFloat = lower_comptime.foldQualifiedConstFloat;
    pub const qualifiedConstIsFloatTyped = lower_comptime.qualifiedConstIsFloatTyped;
    pub const comptimeIntNamed = lower_comptime.comptimeIntNamed;
    pub const selectModuleConst = lower_comptime.selectModuleConst;
    pub const GlobalAuthor = lower_comptime.GlobalAuthor;
    pub const selectGlobalAuthor = lower_comptime.selectGlobalAuthor;
    pub const foldConstAggLen = lower_comptime.foldConstAggLen;
    pub const foldConstArrayElem = lower_comptime.foldConstArrayElem;
    pub const foldConstStructField = lower_comptime.foldConstStructField;
    pub const resolveGlobalRef = lower_comptime.resolveGlobalRef;
    pub const sourceModuleConst = lower_comptime.sourceModuleConst;
    pub const pinConstAuthorSource = lower_comptime.pinConstAuthorSource;
    pub const foldComptimeFloatInit = lower_comptime.foldComptimeFloatInit;

    // --- moved to lower/stmt.zig (lower_stmt) ---
    pub const lowerBlock = lower_stmt.lowerBlock;
    pub const lowerInlineBranch = lower_stmt.lowerInlineBranch;
    pub const lowerBlockValue = lower_stmt.lowerBlockValue;
    pub const lowerValueBody = lower_stmt.lowerValueBody;
    pub const bindNamedReturnSlots = lower_stmt.bindNamedReturnSlots;
    pub const synthesizeNamedReturn = lower_stmt.synthesizeNamedReturn;
    pub const validateMultiReturn = lower_stmt.validateMultiReturn;
    pub const tryLowerAsExpr = lower_stmt.tryLowerAsExpr;
    pub const lowerStmt = lower_stmt.lowerStmt;
    pub const lowerVarDecl = lower_stmt.lowerVarDecl;
    pub const lowerLocalFnDecl = lower_stmt.lowerLocalFnDecl;
    pub const lowerConstDecl = lower_stmt.lowerConstDecl;
    pub const lowerReturn = lower_stmt.lowerReturn;
    pub const lowerAssignment = lower_stmt.lowerAssignment;
    pub const fieldLvalueResolve = lower_stmt.fieldLvalueResolve;
    pub const fieldLvaluePtr = lower_stmt.fieldLvaluePtr;
    pub const lowerUnionLiteral = lower_stmt.lowerUnionLiteral;
    pub const diagTaggedUnionVariantWrite = lower_stmt.diagTaggedUnionVariantWrite;
    pub const lowerExprAsPtr = lower_stmt.lowerExprAsPtr;
    pub const rootIsConstant = lower_stmt.rootIsConstant;
    pub const storeOrCompound = lower_stmt.storeOrCompound;
    pub const emitCompoundOp = lower_stmt.emitCompoundOp;
    pub const lowerMultiAssign = lower_stmt.lowerMultiAssign;
    pub const lowerDestructureDecl = lower_stmt.lowerDestructureDecl;
    pub const lowerPush = lower_stmt.lowerPush;
    pub const lowerDefer = lower_stmt.lowerDefer;
    pub const lowerOnFail = lower_stmt.lowerOnFail;
    pub const diagOnFailNotFailable = lower_stmt.diagOnFailNotFailable;
    pub const emitBlockDefers = lower_stmt.emitBlockDefers;
    pub const emitLoopExitDefers = lower_stmt.emitLoopExitDefers;
    pub const lowerCleanupBody = lower_stmt.lowerCleanupBody;
    pub const emitErrorCleanup = lower_stmt.emitErrorCleanup;

    // --- moved to lower/control_flow.zig (lower_control_flow) ---
    pub const lowerIfExpr = lower_control_flow.lowerIfExpr;
    pub const armStaticallyDiverges = lower_control_flow.armStaticallyDiverges;
    pub const armYieldsVoid = lower_control_flow.armYieldsVoid;
    pub const armContributesNull = lower_control_flow.armContributesNull;
    pub const matchContributesNull = lower_control_flow.matchContributesNull;
    pub const setMergeParamType = lower_control_flow.setMergeParamType;
    pub const narrowableLocal = lower_control_flow.narrowableLocal;
    pub const nullCmpName = lower_control_flow.nullCmpName;
    pub const collectPresentIfTrue = lower_control_flow.collectPresentIfTrue;
    pub const collectPresentIfFalse = lower_control_flow.collectPresentIfFalse;
    pub const narrowSnapshot = lower_control_flow.narrowSnapshot;
    pub const narrowRestore = lower_control_flow.narrowRestore;
    pub const applyNarrowing = lower_control_flow.applyNarrowing;
    pub const tryConstBoolCondition = lower_control_flow.tryConstBoolCondition;
    pub const lowerWhile = lower_control_flow.lowerWhile;
    pub const listView = lower_control_flow.listView;
    pub const lowerFor = lower_control_flow.lowerFor;
    pub const lowerInlineRangeFor = lower_control_flow.lowerInlineRangeFor;
    pub const lowerMatch = lower_control_flow.lowerMatch;
    pub const lowerBreak = lower_control_flow.lowerBreak;
    pub const lowerContinue = lower_control_flow.lowerContinue;
    pub const freshBlock = lower_control_flow.freshBlock;
    pub const freshBlockWithParams = lower_control_flow.freshBlockWithParams;
    pub const currentBlockHasTerminator = lower_control_flow.currentBlockHasTerminator;
    pub const ensureTerminator = lower_control_flow.ensureTerminator;

    // --- moved to lower/decl.zig (lower_decl) ---
    pub const checkInfiniteSize = lower_decl.checkInfiniteSize;
    pub const dfsByValueCycle = lower_decl.dfsByValueCycle;
    pub const poisonAggregateField = lower_decl.poisonAggregateField;
    pub const diagInfiniteSize = lower_decl.diagInfiniteSize;
    pub const SelectedFunc = lower_decl.SelectedFunc;
    pub const BareCallee = lower_decl.BareCallee;
    pub const VisibleStructAuthor = lower_decl.VisibleStructAuthor;
    pub const lowerRoot = lower_decl.lowerRoot;
    pub const validateMainSignature = lower_decl.validateMainSignature;
    pub const checkRequiredEntryPoints = lower_decl.checkRequiredEntryPoints;
    pub const injectComptimeConstants = lower_decl.injectComptimeConstants;
    pub const findVariantIndex = lower_decl.findVariantIndex;
    pub const lowerDeferredTypeFns = lower_decl.lowerDeferredTypeFns;
    pub const lowerDecls = lower_decl.lowerDecls;
    pub const detectContextDecl = lower_decl.detectContextDecl;
    pub const collectContextExtensions = lower_context_ext.collectContextExtensions;
    pub const assembleContext = lower_context_ext.assembleContext;
    pub const assembleContextEarly = lower_context_ext.assembleContextEarly;
    pub const contextExtensionDefault = lower_context_ext.contextExtensionDefault;
    pub const hasContextExtension = lower_context_ext.hasContextExtension;
    pub const contextFieldByName = lower_context_ext.contextFieldByName;
    pub const noteRegisteredContextFields = lower_context_ext.noteRegisteredContextFields;
    pub const funcWantsImplicitCtx = lower_decl.funcWantsImplicitCtx;
    pub const fnPtrTypeWantsCtx = lower_decl.fnPtrTypeWantsCtx;
    pub const scanDecls = lower_decl.scanDecls;
    pub const registerTypedModuleConst = lower_decl.registerTypedModuleConst;
    pub const registerConstArrayGlobal = lower_decl.registerConstArrayGlobal;
    pub const maybeRegisterConstStructGlobal = lower_decl.maybeRegisterConstStructGlobal;
    pub const inferConstArrayType = lower_decl.inferConstArrayType;
    pub const typedConstInitFits = lower_decl.typedConstInitFits;
    pub const constExprInitFits = lower_decl.constExprInitFits;
    pub const registerTopLevelGlobal = lower_decl.registerTopLevelGlobal;
    pub const globalInitValue = lower_decl.globalInitValue;
    pub const globalInitValuePayload = lower_decl.globalInitValuePayload;
    pub const diagnoseNonConstGlobal = lower_decl.diagnoseNonConstGlobal;
    pub const resolveForwardIdentifierAliases = lower_decl.resolveForwardIdentifierAliases;
    pub const aliasResolvedInSource = lower_decl.aliasResolvedInSource;
    pub const declareFunction = lower_decl.declareFunction;
    pub const registerNamespaceQualifiedFns = lower_decl.registerNamespaceQualifiedFns;
    pub const registerQualifiedFn = lower_decl.registerQualifiedFn;
    pub const isVisible = lower_decl.isVisible;
    pub const visibleOverEdges = lower_decl.visibleOverEdges;
    pub const isCImportVisible = lower_decl.isCImportVisible;
    pub const isNameVisible = lower_decl.isNameVisible;
    pub const lazyLowerFunction = lower_decl.lazyLowerFunction;
    pub const lowerFunctionBodyInto = lower_decl.lowerFunctionBodyInto;
    pub const lowerFunction = lower_decl.lowerFunction;
    pub const lowerMainAndComptime = lower_decl.lowerMainAndComptime;
    pub const lowerRetainedSameNameAuthors = lower_decl.lowerRetainedSameNameAuthors;
    pub const selectPlainCallableAuthor = lower_decl.selectPlainCallableAuthor;
    pub const selectNominalLeaf = lower_decl.selectNominalLeaf;
    pub const isNamedTypeKind = lower_decl.isNamedTypeKind;
    pub const namedRefTid = lower_decl.namedRefTid;
    pub const nameAuthoredAsTypeAnywhere = lower_decl.nameAuthoredAsTypeAnywhere;
    pub const recordLocalTypeName = lower_decl.recordLocalTypeName;
    pub const localTypeInSource = lower_decl.localTypeInSource;
    pub const localTypeInAnySource = lower_decl.localTypeInAnySource;
    pub const resolveNominalLeaf = lower_decl.resolveNominalLeaf;
    pub const fnDeclOfRaw = lower_decl.fnDeclOfRaw;
    pub const structDeclOfRaw = lower_decl.structDeclOfRaw;
    pub const structMethodFn = lower_decl.structMethodFn;
    pub const accessorEffName = lower_decl.accessorEffName;
    pub const accessorNameMatches = lower_decl.accessorNameMatches;
    pub const setter_eff_suffix = lower_decl.setter_eff_suffix;
    pub const typeFnAuthor = lower_decl.typeFnAuthor;
    pub const selectedFuncId = lower_decl.selectedFuncId;
    pub const bareAuthorFuncId = lower_decl.bareAuthorFuncId;
    pub const putTypeAlias = lower_decl.putTypeAlias;
    pub const putModuleConst = lower_decl.putModuleConst;
    pub const putGlobal = lower_decl.putGlobal;
    pub const dropModuleConst = lower_decl.dropModuleConst;
    pub const emitModuleConst = lower_decl.emitModuleConst;
    pub const emitPlaceholder = lower_decl.emitPlaceholder;

    // --- moved to lower/nominal.zig (lower_nominal) ---
    pub const registerErrorSetDecl = lower_nominal.registerErrorSetDecl;
    pub const registerStructDecl = lower_nominal.registerStructDecl;
    pub const registerEnumDecl = lower_nominal.registerEnumDecl;
    pub const registerUnionDecl = lower_nominal.registerUnionDecl;
    pub const qualifyAnonType = lower_nominal.qualifyAnonType;
    pub const nominalIdOf = lower_nominal.nominalIdOf;
    pub const stampNominalId = lower_nominal.stampNominalId;
    pub const reserveShadowStructSlot = lower_nominal.reserveShadowStructSlot;
    pub const reserveShadowEnumSlot = lower_nominal.reserveShadowEnumSlot;
    pub const reserveShadowUnionSlot = lower_nominal.reserveShadowUnionSlot;
    pub const reserveShadowErrorSetSlot = lower_nominal.reserveShadowErrorSetSlot;
    pub const topLevelTypeDecl = lower_nominal.topLevelTypeDecl;
    pub const reserveShadowSlot = lower_nominal.reserveShadowSlot;
    pub const internNamedTypeDecl = lower_nominal.internNamedTypeDecl;
    pub const adoptsForwardStructStub = lower_nominal.adoptsForwardStructStub;
    pub const shadowNominalId = lower_nominal.shadowNominalId;
    pub const nameHasMultipleTypeAuthors = lower_nominal.nameHasMultipleTypeAuthors;
    pub const rawNamedTypePtr = lower_nominal.rawNamedTypePtr;
    pub const buildGenericStructTemplate = lower_nominal.buildGenericStructTemplate;
    pub const qualifiedStructTemplate = lower_nominal.qualifiedStructTemplate;
    pub const aliasedStructTemplate = lower_nominal.aliasedStructTemplate;
    pub const aliasedFnDecl = lower_nominal.aliasedFnDecl;
    pub const qualifiedMemberMissing = lower_nominal.qualifiedMemberMissing;
    pub const bareVisibleStructDecl = lower_nominal.bareVisibleStructDecl;
    pub const bareVisibleStructTemplate = lower_nominal.bareVisibleStructTemplate;
    pub const registerGenericStructAlias = lower_nominal.registerGenericStructAlias;

    // --- moved to lower/protocol.zig (lower_protocol) ---
    pub const ProjectionPosition = lower_pack.ProjectionPosition;
    pub const PackProjection = lower_pack.PackProjection;
    pub const registerProtocolDecl = lower_protocol.registerProtocolDecl;
    pub const instantiateParamProtocol = lower_protocol.instantiateParamProtocol;
    pub const lookupProtocolArg = lower_protocol.lookupProtocolArg;
    pub const lookupProtocolField = lower_protocol.lookupProtocolField;
    pub const isProtocolType = lower_protocol.isProtocolType;
    pub const getProtocolInfo = lower_protocol.getProtocolInfo;
    pub const getOrCreateThunks = lower_protocol.getOrCreateThunks;
    pub const emitDefaultContextGlobal = lower_protocol.emitDefaultContextGlobal;
    pub const emitDefaultContextGlobalEarly = lower_protocol.emitDefaultContextGlobalEarly;
    pub const protocolErasureConst = lower_protocol.protocolErasureConst;
    pub const createProtocolThunk = lower_protocol.createProtocolThunk;
    pub const buildProtocolValue = lower_protocol.buildProtocolValue;
    pub const emitProtocolDispatch = lower_protocol.emitProtocolDispatch;
    pub const refuseProtocolAssertTargetOnAny = lower_protocol.refuseProtocolAssertTargetOnAny;
    pub const lowerOwningErasure = lower_protocol.lowerOwningErasure;
    pub const allocViaAllocatorValue = lower_protocol.allocViaAllocatorValue;
    pub const resolveConcreteTypeName = lower_protocol.resolveConcreteTypeName;
    pub const computeHasImpl = lower_protocol.computeHasImpl;

    // --- moved to lower/coerce.zig (lower_coerce) ---
    pub const lowerXX = lower_coerce.lowerXX;
    pub const refuseIdentityRvalueErasure = lower_coerce.refuseIdentityRvalueErasure;
    pub const protocolIsIdentity = lower_coerce.protocolIsIdentity;
    pub const demandOwnedErasure = lower_coerce.demandOwnedErasure;
    pub const isClosureToBlockCast = lower_coerce.isClosureToBlockCast;
    pub const tryPackImplMatch = lower_coerce.tryPackImplMatch;
    pub const tryUserConversion = lower_coerce.tryUserConversion;
    pub const isLvalueExpr = lower_coerce.isLvalueExpr;
    pub const refStorageAddress = lower_coerce.refStorageAddress;
    pub const arrayToSliceView = lower_coerce.arrayToSliceView;
    pub const isByValueBindingIdent = lower_coerce.isByValueBindingIdent;
    pub const coerceOrErase = lower_coerce.coerceOrErase;
    pub const buildProtocolErasure = lower_coerce.buildProtocolErasure;
    pub const viewOfConcreteAddr = lower_coerce.viewOfConcreteAddr;
    pub const inferConcreteTypeName = lower_coerce.inferConcreteTypeName;
    pub const lowerAnyToF64Dispatch = lower_coerce.lowerAnyToF64Dispatch;
    pub const lowerAnyToIntDispatch = lower_coerce.lowerAnyToIntDispatch;
    pub const boxAnyOf = lower_coerce.boxAnyOf;
    pub const buildDefaultValue = lower_coerce.buildDefaultValue;
    pub const optionalOfFlattened = lower_coerce.optionalOfFlattened;
    pub const zeroValue = lower_coerce.zeroValue;
    pub const lowerCoercedDefault = lower_coerce.lowerCoercedDefault;
    pub const lowerDefaultWithBindings = lower_coerce.lowerDefaultWithBindings;
    pub const coerceToType = lower_coerce.coerceToType;
    pub const coerceExplicit = lower_coerce.coerceExplicit;
    pub const checkAssignable = lower_coerce.checkAssignable;
    pub const checkReturnable = lower_coerce.checkReturnable;
    pub const noneReinterpretIsUnsafe = lower_coerce.noneReinterpretIsUnsafe;
    pub const externalErrorsExist = lower_coerce.externalErrorsExist;
    pub const coerceMode = lower_coerce.coerceMode;
    pub const diagNonIntegralNarrow = lower_coerce.diagNonIntegralNarrow;
    pub const promoteCVariadicArgs = lower_coerce.promoteCVariadicArgs;
    pub const coerceCallArgs = lower_coerce.coerceCallArgs;

    // --- moved to lower/ffi.zig (lower_ffi) ---
    pub const internObjcSelector = lower_ffi.internObjcSelector;
    pub const internObjcClassObject = lower_ffi.internObjcClassObject;
    pub const getSelRegisterNameFid = lower_ffi.getSelRegisterNameFid;
    pub const lowerFfiIntrinsicCall = lower_ffi.lowerFfiIntrinsicCall;
    pub const lowerJniCall = lower_ffi.lowerJniCall;
    pub const lowerRuntimeMethodCall = lower_ffi.lowerRuntimeMethodCall;
    pub const resolveRuntimeClassMemberType = lower_ffi.resolveRuntimeClassMemberType;
    pub const resolveRuntimeMethodReturnType = lower_ffi.resolveRuntimeMethodReturnType;
    pub const runtimeClassStructType = lower_ffi.runtimeClassStructType;
    pub const lowerObjcMethodCall = lower_ffi.lowerObjcMethodCall;
    pub const lowerObjcStaticCall = lower_ffi.lowerObjcStaticCall;
    pub const lowerRuntimeStaticCall = lower_ffi.lowerRuntimeStaticCall;
    pub const lowerSuperCall = lower_ffi.lowerSuperCall;
    pub const registerRuntimeClassDecl = lower_ffi.registerRuntimeClassDecl;
    pub const resolveObjcParentName = lower_ffi.resolveObjcParentName;
    pub const declareObjcDefinedStateIvarGlobal = lower_ffi.declareObjcDefinedStateIvarGlobal;
    pub const declareObjcDefinedClassGlobal = lower_ffi.declareObjcDefinedClassGlobal;
    pub const registerObjcDefinedClassMethods = lower_ffi.registerObjcDefinedClassMethods;
    pub const synthesizeFnDeclFromObjcMethod = lower_ffi.synthesizeFnDeclFromObjcMethod;
    pub const lookupObjcDefinedClassForMethod = lower_ffi.lookupObjcDefinedClassForMethod;
    pub const getJniEnvTlFids = lower_ffi.getJniEnvTlFids;
    pub const registerNamespacedRuntimeClasses = lower_ffi.registerNamespacedRuntimeClasses;
    pub const synthesizeJniMainStubs = lower_ffi.synthesizeJniMainStubs;
    pub const synthesizeJniMainStub = lower_ffi.synthesizeJniMainStub;

    // --- moved to lower/objc_class.zig (lower_objc_class) ---
    pub const lowerObjcDefinedClassMethods = lower_objc_class.lowerObjcDefinedClassMethods;
    pub const lookupObjcPropertyOnPointer = lower_objc_class.lookupObjcPropertyOnPointer;
    pub const findRuntimeMethodInChain = lower_objc_class.findRuntimeMethodInChain;
    pub const findRuntimePropertyInChain = lower_objc_class.findRuntimePropertyInChain;
    pub const lookupObjcDefinedStateFieldOnPointer = lower_objc_class.lookupObjcDefinedStateFieldOnPointer;
    pub const lowerObjcDefinedStateFieldRead = lower_objc_class.lowerObjcDefinedStateFieldRead;
    pub const lowerObjcDefinedStateForObj = lower_objc_class.lowerObjcDefinedStateForObj;
    pub const lowerObjcPropertyGetter = lower_objc_class.lowerObjcPropertyGetter;
    pub const lowerObjcPropertySetter = lower_objc_class.lowerObjcPropertySetter;
    pub const ensureCRuntimeDecl = lower_objc_class.ensureCRuntimeDecl;
    pub const ensureArcRuntimeDecls = lower_objc_class.ensureArcRuntimeDecls;
    pub const emitObjcDefinedClassImps = lower_objc_class.emitObjcDefinedClassImps;
    pub const emitObjcDefinedClassPropertyImps = lower_objc_class.emitObjcDefinedClassPropertyImps;
    pub const emitObjcDefinedPropertyGetter = lower_objc_class.emitObjcDefinedPropertyGetter;
    pub const emitObjcDefinedPropertySetter = lower_objc_class.emitObjcDefinedPropertySetter;
    pub const registerObjcDefinedPropertyMethodEntries = lower_objc_class.registerObjcDefinedPropertyMethodEntries;
    pub const emitObjcDefinedClassImp = lower_objc_class.emitObjcDefinedClassImp;
    pub const emitObjcDefinedClassAllocImp = lower_objc_class.emitObjcDefinedClassAllocImp;
    pub const emitObjcDefinedAllocAndInit = lower_objc_class.emitObjcDefinedAllocAndInit;
    pub const emitObjcDefinedClassStaticImp = lower_objc_class.emitObjcDefinedClassStaticImp;
    pub const emitObjcDefinedClassDeallocImp = lower_objc_class.emitObjcDefinedClassDeallocImp;
    pub const internStringConstantGlobal = lower_objc_class.internStringConstantGlobal;
    pub const lookupGlobalIdByName = lower_objc_class.lookupGlobalIdByName;

    // --- moved to lower/call.zig (lower_call) ---
    pub const CaptureInfo = lower_closure.CaptureInfo;
    pub const lowerCall = lower_call.lowerCall;
    pub const ufcsGenericBindsAll = lower_call.ufcsGenericBindsAll;
    pub const selectUfcsGenericByReceiver = lower_call.selectUfcsGenericByReceiver;
    pub const diagnoseMissingContext = lower_call.diagnoseMissingContext;
    pub const allocViaContext = lower_call.allocViaContext;
    pub const callExtern = lower_call.callExtern;
    pub const prependCtxIfNeeded = lower_call.prependCtxIfNeeded;
    pub const resolveFuncByName = lower_call.resolveFuncByName;
    pub const resolveBuiltin = lower_call.resolveBuiltin;
    pub const lowerGenericCall = lower_call.lowerGenericCall;
    pub const tryLowerReflectionCall = lower_call.tryLowerReflectionCall;
    pub const tryLowerAtomicIntrinsic = lower_call.tryLowerAtomicIntrinsic;
    pub const reflectionArgIsType = lower_call.reflectionArgIsType;
    pub const reflectionTypeArgGuard = lower_call.reflectionTypeArgGuard;
    pub const reflectionErrorSentinel = lower_call.reflectionErrorSentinel;
    pub const appendDefaultArgs = lower_call.appendDefaultArgs;
    pub const checkCallArity = lower_call.checkCallArity;
    pub const expandCallDefaults = lower_call.expandCallDefaults;
    pub const userParamTypes = lower_call.userParamTypes;
    pub const resolveCallParamTypes = lower_call.resolveCallParamTypes;

    // --- moved to lower/pack.zig (lower_pack) ---
    pub const lowerPackElems = lower_pack.lowerPackElems;
    pub const lowerPackValueProjection = lower_pack.lowerPackValueProjection;
    pub const packSpreadRefs = lower_pack.packSpreadRefs;
    pub const valueSpreadRefs = lower_pack.valueSpreadRefs;
    pub const materializePackTuple = lower_pack.materializePackTuple;
    pub const expandSpreadArgNodes = lower_pack.expandSpreadArgNodes;
    pub const diagPackIndexOOB = lower_pack.diagPackIndexOOB;
    pub const packArgNodeAt = lower_pack.packArgNodeAt;
    pub const comptimeIndexOf = lower_pack.comptimeIndexOf;
    pub const diagPackAsValue = lower_pack.diagPackAsValue;
    pub const isPackName = lower_pack.isPackName;
    pub const lowerPackToSlice = lower_pack.lowerPackToSlice;
    pub const lowerVariadicArgs = lower_pack.lowerVariadicArgs;
    pub const packVariadicCallArgs = lower_pack.packVariadicCallArgs;
    pub const buildPackSliceValue = lower_pack.buildPackSliceValue;
    pub const materialisePackSlice = lower_pack.materialisePackSlice;
    pub const inferPackBodyReturnType = lower_pack.inferPackBodyReturnType;
    pub const lowerPackFnCall = lower_pack.lowerPackFnCall;
    pub const monomorphizePackFn = lower_pack.monomorphizePackFn;
    pub const resolvePackProjection = lower_pack.resolvePackProjection;
    pub const isPackFn = lower_pack.isPackFn;
    pub const isPackParam = lower_pack.isPackParam;

    // --- moved to lower/generic.zig (lower_generic) ---
    pub const monomorphizeFunction = lower_generic.monomorphizeFunction;
    pub const instantiateGenericStruct = lower_generic.instantiateGenericStruct;
    pub const instantiateTypeFunction = lower_generic.instantiateTypeFunction;
    pub const instantiateTypeUnion = lower_generic.instantiateTypeUnion;
    pub const findStructInBody = lower_generic.findStructInBody;
    pub const findUnionInBody = lower_generic.findUnionInBody;
    pub const findReturnTypeExpr = lower_generic.findReturnTypeExpr;
    pub const returnExprMintsType = lower_generic.returnExprMintsType;
    pub const genericInstanceMethod = lower_generic.genericInstanceMethod;
    pub const ensureGenericInstanceMethodLowered = lower_generic.ensureGenericInstanceMethodLowered;
    pub const lowerComptimeGenericInstanceMethod = lower_generic.lowerComptimeGenericInstanceMethod;
    pub const assertInstanceMapsCoincide = lower_generic.assertInstanceMapsCoincide;
    pub const isStaticTypeArg = lower_generic.isStaticTypeArg;
    pub const isTypeReturningCallNode = lower_generic.isTypeReturningCallNode;
    pub const isStaticTypeRef = lower_generic.isStaticTypeRef;
    pub const resolveTupleLiteralTypeArg = lower_generic.resolveTupleLiteralTypeArg;
    pub const resolveTypeArg = lower_generic.resolveTypeArg;
    pub const formatTypeName = lower_generic.formatTypeName;
    pub const formatFnTypeString = lower_generic.formatFnTypeString;
    pub const matchTypeParam = lower_generic.matchTypeParam;
    pub const matchTypeParamStatic = lower_generic.matchTypeParamStatic;
    pub const extractTypeParam = lower_generic.extractTypeParam;
    pub const mangleTypeName = lower_generic.mangleTypeName;
    pub const resolveTypeCategoryTags = lower_generic.resolveTypeCategoryTags;
    pub const inferMatchResultType = lower_generic.inferMatchResultType;
    pub const unifyValueArmTypes = lower_generic.unifyValueArmTypes;
    pub const isTypeCategoryMatch = lower_generic.isTypeCategoryMatch;
    pub const isRuntimeCategoryName = lower_generic.isRuntimeCategoryName;
    pub const isTypeParamDecl = lower_generic.isTypeParamDecl;
    pub const hasComptimeParams = lower_generic.hasComptimeParams;
    pub const isPlainFreeFn = lower_generic.isPlainFreeFn;
    pub const selectGenericStructHead = lower_generic.selectGenericStructHead;
    pub const headTypeLeak = lower_generic.headTypeLeak;
    pub const headNameOfCallee = lower_generic.headNameOfCallee;
    pub const headTypeGate = lower_generic.headTypeGate;
    pub const headFnLeak = lower_generic.headFnLeak;
    pub const flatFnAuthorAmbiguous = lower_generic.flatFnAuthorAmbiguous;
    pub const flatFnAuthorVisible = lower_generic.flatFnAuthorVisible;
    pub const resolveTypeCallWithBindings = lower_generic.resolveTypeCallWithBindings;
    pub const fieldTypeOf = lower_generic.fieldTypeOf;
    pub const resolveParameterizedWithBindings = lower_generic.resolveParameterizedWithBindings;
    pub const resolveValueParamArg = lower_generic.resolveValueParamArg;
    pub const canonicalIntConstraintName = lower_generic.canonicalIntConstraintName;
    pub const diagValueParamNotConst = lower_generic.diagValueParamNotConst;
    pub const diagValueParamRange = lower_generic.diagValueParamRange;

    // --- moved to lower/expr.zig (lower_expr) ---
    pub const lowerStructLiteral = lower_expr.lowerStructLiteral;
    pub const synthesizeAnonStruct = lower_expr.synthesizeAnonStruct;
    pub const lowerInitBlock = lower_expr.lowerInitBlock;
    pub const getStructFields = lower_expr.getStructFields;
    pub const getAccessorFor = lower_expr.getAccessorFor;
    pub const getSetterFor = lower_expr.getSetterFor;
    pub const getterReturnTypeOnDeref = lower_expr.getterReturnTypeOnDeref;
    pub const fixupMethodReceiver = lower_expr.fixupMethodReceiver;
    pub const getStructTypeName = lower_expr.getStructTypeName;
    pub const builtinTypeName = lower_expr.builtinTypeName;
    pub const resolveFieldType = lower_expr.resolveFieldType;
    pub const lowerFieldAccess = lower_expr.lowerFieldAccess;
    pub const identifierBindsValue = lower_expr.identifierBindsValue;
    pub const lowerNumericLimit = lower_expr.lowerNumericLimit;
    pub const lowerStructConstant = lower_expr.lowerStructConstant;
    pub const lowerOptionalChain = lower_expr.lowerOptionalChain;
    pub const lowerOptionalChainIndex = lower_expr.lowerOptionalChainIndex;
    pub const vectorLaneIndex = lower_expr.vectorLaneIndex;
    pub const lowerFieldAccessOnType = lower_expr.lowerFieldAccessOnType;
    pub const lowerEnumLiteral = lower_expr.lowerEnumLiteral;
    pub const lowerErrorTagLiteral = lower_expr.lowerErrorTagLiteral;
    pub const lowerTaggedEnumLiteral = lower_expr.lowerTaggedEnumLiteral;
    pub const findTaggedVariant = lower_expr.findTaggedVariant;
    pub const emitBadVariant = lower_expr.emitBadVariant;
    pub const emitBadEnumVariant = lower_expr.emitBadEnumVariant;
    pub const isPayloadlessVariant = lower_expr.isPayloadlessVariant;
    pub const dedupeExternSymbol = lower_decl.dedupeExternSymbol;
    pub const resolveVariantValue = lower_expr.resolveVariantValue;
    pub const resolveVariantIndex = lower_expr.resolveVariantIndex;
    pub const hasVariant = lower_expr.hasVariant;
    pub const lowerArrayLiteral = lower_expr.lowerArrayLiteral;
    pub const resolveArrayLiteralType = lower_expr.resolveArrayLiteralType;
    pub const lowerIndexExpr = lower_expr.lowerIndexExpr;
    pub const lowerIndexOperand = lower_expr.lowerIndexOperand;
    pub const diagNonIndexable = lower_expr.diagNonIndexable;
    pub const lowerSliceExpr = lower_expr.lowerSliceExpr;
    pub const lowerTupleLiteral = lower_expr.lowerTupleLiteral;
    pub const lowerDerefExpr = lower_expr.lowerDerefExpr;
    pub const lowerForceUnwrap = lower_expr.lowerForceUnwrap;
    pub const diagOptionalOperand = lower_expr.diagOptionalOperand;
    pub const lowerNullCoalesce = lower_expr.lowerNullCoalesce;
    pub const resolveOptionalInner = lower_expr.resolveOptionalInner;
    pub const lowerExpr = lower_expr.lowerExpr;
    pub const lowerAsmExpr = lower_expr.lowerAsmExpr;
    pub const asmResultType = lower_expr.asmResultType;
    pub const refCapturePointee = lower_expr.refCapturePointee;
    pub const lowerBinaryOp = lower_expr.lowerBinaryOp;
    pub const lowerBoolCondition = lower_expr.lowerBoolCondition;
    pub const checkConditionType = lower_expr.checkConditionType;
    pub const lowerTupleOp = lower_expr.lowerTupleOp;
    pub const lowerTupleLexCompare = lower_expr.lowerTupleLexCompare;
    pub const lowerTupleMembership = lower_expr.lowerTupleMembership;
    pub const lowerStructEquality = lower_expr.lowerStructEquality;
    pub const lowerFieldEquality = lower_expr.lowerFieldEquality;
    pub const lowerChainedComparison = lower_expr.lowerChainedComparison;
    pub const emitCmp = lower_expr.emitCmp;

    // --- moved to lower/closure.zig (lower_closure) ---
    pub const lowerLambda = lower_closure.lowerLambda;
    pub const createBareFnTrampoline = lower_closure.createBareFnTrampoline;
    pub const createClosureToBareFnAdapter = lower_closure.createClosureToBareFnAdapter;
    pub const collectCaptures = lower_closure.collectCaptures;
    pub const computeEnvSize = lower_closure.computeEnvSize;
};
