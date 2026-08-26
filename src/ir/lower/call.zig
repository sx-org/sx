const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const intrinsics = @import("../intrinsics.zig");
const type_bridge = @import("../type_bridge.zig");
const unescape = @import("../../unescape.zig");
const errors = @import("../../errors.zig");
const program_index_mod = @import("../program_index.zig");
const ProtocolMethodInfo = program_index_mod.ProtocolMethodInfo;
const GlobalInfo = program_index_mod.GlobalInfo;
const CallResolver = @import("../calls.zig").CallResolver;
const init_plan = @import("init_plan.zig");
const build_block = @import("build_block.zig");
const lower_generic = @import("generic.zig");
const lower_open_set = @import("open_set.zig");
const lower_closure = @import("closure.zig");
const lower_protocol = @import("protocol.zig");
const lower_bound = @import("bound.zig");
const generics_mod = @import("../generics.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const BlockId = inst_mod.BlockId;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const ParamDemand = Lowering.ParamDemand;
const SelectedFunc = Lowering.SelectedFunc;
const isTypeParamDecl = Lowering.isTypeParamDecl;
const isPackFn = Lowering.isPackFn;
const headNameOfCallee = Lowering.headNameOfCallee;
const hasComptimeParams = Lowering.hasComptimeParams;

/// Compiler-internal dispatch/monomorphization base for an exactly-selected
/// declaration.  Encode the complete source path and stable declaration
/// location/ordinal: hashes can collide, source+name alone does not distinguish
/// overload/local/synthesized declarations, and pointer text is nondeterministic.
/// A synthesized zero-span declaration must have a DeclId; otherwise there is
/// no stable identity to emit and compilation fails loudly.
fn selectedDispatchName(self: *Lowering, sf: *const SelectedFunc) []const u8 {
    const decl_id = if (self.program_index.decl_table) |dt|
        dt.declIdForRef(.{ .fn_decl = sf.decl })
    else
        null;
    if (sf.decl.name_span.start == 0 and sf.decl.name_span.end == 0 and decl_id == null)
        @panic("selected synthesized function has no stable declaration identity");

    var out = std.ArrayList(u8).empty;
    out.appendSlice(self.alloc, sf.decl.name) catch @panic("out of memory while mangling selected function");
    out.appendSlice(self.alloc, "$src$") catch @panic("out of memory while mangling selected function");
    const hex = "0123456789abcdef";
    for (sf.source) |byte| {
        out.append(self.alloc, hex[byte >> 4]) catch @panic("out of memory while mangling selected function");
        out.append(self.alloc, hex[byte & 0xf]) catch @panic("out of memory while mangling selected function");
    }
    var numeric: [96]u8 = undefined;
    const span_fragment = std.fmt.bufPrint(&numeric, "$span${d}_{d}", .{ sf.decl.name_span.start, sf.decl.name_span.end }) catch unreachable;
    out.appendSlice(self.alloc, span_fragment) catch @panic("out of memory while mangling selected function");
    if (decl_id) |id| {
        const ordinal_fragment = std.fmt.bufPrint(&numeric, "$decl${d}", .{@intFromEnum(id)}) catch unreachable;
        out.appendSlice(self.alloc, ordinal_fragment) catch @panic("out of memory while mangling selected function");
    }
    return out.toOwnedSlice(self.alloc) catch @panic("out of memory while mangling selected function");
}

/// The ufcs function a dot-call resolves to when ANY of its parameters is
/// destination-first (`$I/@Init(T)`), or null when the dot-call is anything else.
/// Answers the same questions the ufcs dispatch arm asks, in the same order — the
/// receiver's own type answers first, an alias names its target, and a generic
/// family is selected by the receiver — so a call only re-spells itself where that
/// arm would have taken it anyway.
const DestinationFirstUfcs = struct {
    fd: *const ast.FnDecl,
    name: []const u8,
};

fn destinationFirstUfcs(self: *Lowering, fa: *const ast.FieldAccess, call_args: []const *Node) ?DestinationFirstUfcs {
    const alias_target = self.ufcsAliasTarget(fa.field);
    const eff_field = alias_target orelse fa.field;
    const fd0 = self.program_index.fn_ast_map.get(eff_field) orelse return null;
    if (alias_target == null and !fd0.is_ufcs) return null;

    // A method the receiver's own type provides wins over a free function.
    if (receiverProvidesMethod(self, self.inferExprType(fa.object), fa.field)) return null;

    var fd = fd0;
    if (fd0.type_params.len > 0) {
        var eff_args = std.ArrayList(*const Node).empty;
        defer eff_args.deinit(self.alloc);
        eff_args.append(self.alloc, fa.object) catch return null;
        for (call_args) |a| eff_args.append(self.alloc, a) catch return null;
        var amb = false;
        if (self.selectUfcsGenericByReceiver(eff_field, eff_args.items, &amb, fd0)) |sel| {
            fd = sel;
        } else if (amb) {
            // A tie between receivers is a fact only the dot-call has: the ordinary
            // spelling would pick one silently, so the dispatch arm keeps this one
            // and reports it with the receiver in hand.
            return null;
        }
        // A family that cannot bind from this call is diagnosed better by the
        // ordinary spelling — the same message, naming the parameter it could not
        // infer — so the call is re-spelled and says it there.
        // The receiver chose an author the NAME does not: an ordinary call resolves
        // by name, so re-spelling this one would call the other declaration. The
        // dispatch arm keeps it — and cannot form the receiver there, so a case that
        // REACHES this line is a hole. Two destination-first declarations present
        // the same first-parameter shape, so the ranking above cannot separate them
        // and lands on `amb` first; that is what makes this unreachable.
        if (fd != fd0) return null;
    }
    if (fd.params.len == 0) return null;
    if (init_plan.boundTargetNode(fd.params[0].type_expr) != null)
        return .{ .fd = fd, .name = eff_field };
    // A destination-first parameter PAST the receiver re-spells only when the
    // receiver is what that first parameter takes. The name alone does not
    // settle it: the map's winner may be an unrelated declaration that happens
    // to share the name, and re-spelling for it would hand the receiver to a
    // parameter it does not fit.
    for (fd.params[1..]) |p| {
        if (init_plan.boundTargetNode(p.type_expr) == null) continue;
        if (!receiverFitsFirstParam(self, fd, self.inferExprType(fa.object))) return null;
        return .{ .fd = fd, .name = eff_field };
    }
    return null;
}

/// Would `recv_ty` be accepted at `fd`'s first parameter? A parameter whose
/// type is not resolvable here is left to the ordinary call to judge.
fn receiverFitsFirstParam(self: *Lowering, fd: *const ast.FnDecl, recv_ty: TypeId) bool {
    if (recv_ty == .unresolved) return false;
    const want = self.resolveTypeArg(fd.params[0].type_expr);
    if (want == .unresolved) return true;
    if (want == recv_ty) return true;
    const pi = self.getProtocolInfo(want) orelse return false;
    if (!pi.isErased()) return false;
    const cname = self.resolveConcreteTypeName(recv_ty) orelse return false;
    return self.firstUnimplementedMethod(want, cname, recv_ty) == null;
}


/// A destination-first target cannot be dispatched from the fall-through arm: the
/// receiver was lowered on the way down, and that parameter takes the expression
/// rather than its value (§5.2). The dot-call spelling is re-read as an ordinary
/// call BEFORE anything is lowered, so reaching a dispatch means it was not — the
/// call is refused rather than handed a receiver it cannot accept. It sits after
/// every more specific refusal this arm makes, so it shadows none of them.
fn refuseDestinationFirstDispatch(self: *Lowering, fd: *const ast.FnDecl, spelled: []const u8, recv_ty: TypeId, span: ast.Span) bool {
    if (fd.params.len == 0) return false;
    if (init_plan.boundTargetNode(fd.params[0].type_expr) == null) return false;
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, span, "'{s}' takes its first argument unevaluated, so it cannot be dispatched on a '{s}' value", .{ spelled, self.formatSourceTypeName(recv_ty) });
        d.addHelpFmt(id, span, null, "spell it as a call ('{s}(receiver, …)') — the receiver IS that argument", .{spelled});
    }
    return true;
}

/// Does a value of `ty` answer `name` ITSELF — as a member of any kind the
/// method-call path can resolve? The gate re-spells a dot-call as a free call only
/// when this is false, so every kind the path handles has to be asked about here.
///
/// There is no single query that answers it: the path resolves members from five
/// separate registries, in arms spread across this function. The census below
/// mirrors those arms one for one, with the line each answers for — a member kind
/// added to the path without a line here is a dot-call the gate would steal.
///
///   - a CALLABLE field of that name — a closure or a function pointer — which the
///     path calls instead of dispatching a method (`o.flush()` on a `Closure()`
///     field). A field of any OTHER type is not a member call at all: the path has
///     no arm for it, so it is left to the free function exactly as a plain ufcs
///     leaves it;
///   - a method the type's own declaration carries (`plainStructMethod`);
///   - a method of a GENERIC instance, which carries a separate author stamp and
///     is intentionally absent from `plainStructMethod` (`genericInstanceMethod`);
///   - a method an `impl` contributed, keyed `<Type>.<name>` in the function map;
///   - a runtime-class member (`@JniClass` and its parallels);
///   - a protocol's method, on an erased value;
///   - a set's required method, on a set value;
///   - and any of these through a POINTER or an OPTIONAL, which the path reaches
///     by loading or narrowing first.
fn receiverProvidesMethod(self: *Lowering, ty: TypeId, name: []const u8) bool {
    if (ty == .unresolved) return false;

    // A CALLABLE field of that name: the path calls the field. A field of another
    // type has no arm at all, so declining to it would leave the call to the very
    // dispatch this gate exists to avoid.
    switch (self.lookupField(ty, name)) {
        .hit, .private => |h| if (self.callableSigOf(h.ty) != null) return true,
        .missing => {},
    }

    if (self.plainStructMethod(ty, name) != null) return true;
    if (self.getStructTypeName(ty)) |sname| {
        if (self.genericInstanceMethod(sname, name) != null) return true;
        const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ sname, name }) catch return true;
        if (self.program_index.fn_ast_map.get(qualified) != null) return true;
        if (self.program_index.runtime_class_map.get(sname) != null) return true;
    }
    if (self.getProtocolInfo(ty)) |pi| {
        if (protocolHasMethod(pi, name)) return true;
    }
    if (self.openSetOf(ty)) |set| {
        if (lower_open_set.requiredMethod(set, name) != null) return true;
    }
    if (!ty.isBuiltin()) {
        const info = self.module.types.get(ty);
        if (info == .pointer) return receiverProvidesMethod(self, info.pointer.pointee, name);
        if (info == .optional) return receiverProvidesMethod(self, info.optional.child, name);
    }
    return false;
}

/// True iff every type-parameter of generic ufcs/free-fn `fd` binds to a
/// concrete (present) type given `args_ast` (receiver prepended). A param the
/// argument shapes can't pin is simply absent from the bindings map (e.g. a
/// `*Future($R)` receiver param against a `*Box(i64)` argument never binds `R`).
pub fn ufcsGenericBindsAll(self: *Lowering, fd: *const ast.FnDecl, args_ast: []const *const Node) bool {
    var b = self.genericResolver().buildTypeBindings(fd, args_ast);
    defer b.deinit();
    for (fd.type_params) |tp| {
        if (b.contains(tp.name)) continue;
        // A callable binder is decided by what its argument LOWERS to, so it
        // discriminates no overload here.
        if (callableBinderOf(fd, tp.name) != null) continue;
        return false;
    }
    return true;
}

/// The parameter whose own function-type bound is written on `name`.
fn callableBinderOf(fd: *const ast.FnDecl, name: []const u8) ?*const ast.Param {
    for (fd.params) |*p| {
        if (Lowering.boundOnBinder(p.type_expr, name)) return p;
    }
    return null;
}

/// True if `fd`'s receiver param (`params[0]`) is a CONCRETE/structured type
/// (`*Task($R)`, `Box($R)`, `*Foo`, `[]T`, …) rather than a BARE type-parameter
/// receiver (`$T` / `T` / `*$T`) that matches ANY receiver. Used to prefer the
/// more receiver-specific overload when several same-named generic ufcs bind.
/// POINTER LAYERS ARE PEELED: a receiver's specificity is its core type, not
/// the `*` wrapper — `*Box($T)` (core `Box`, concrete) is strictly more specific
/// than `*$T` (core `$T`, bare), so the structurally-narrower overload wins
/// instead of tying.
fn ufcsReceiverConcrete(fd: *const ast.FnDecl) bool {
    if (fd.params.len == 0) return false;
    var te = fd.params[0].type_expr;
    while (te.data == .pointer_type_expr) te = te.data.pointer_type_expr.pointee_type;
    const bare: ?[]const u8 = switch (te.data) {
        .comptime_pack_ref => |c| c.pack_name,
        .identifier => |id| id.name,
        .type_expr => |t| t.name,
        else => null, // parameterized (Box($T)) / array / slice → concrete
    };
    if (bare) |nm| {
        for (fd.type_params) |tp| {
            if (std.mem.eql(u8, tp.name, nm)) return false; // bare `$T` receiver
        }
    }
    return true;
}

/// Rank one candidate `maybe_fd` into the running (best, best_concrete, tie)
/// selection state: skip non-(generic ufcs) and non-binding candidates; a
/// strictly more receiver-specific candidate wins outright; two distinct
/// equally-specific binders set `tie`; a less-specific one is ignored. Re-export
/// aliases (same `*FnDecl` reached twice) are deduped by identity.
fn rankUfcsCand(self: *Lowering, maybe_fd: ?*const ast.FnDecl, args_ast: []const *const Node, best: *?*const ast.FnDecl, best_concrete: *bool, tie: *bool) void {
    const fd = maybe_fd orelse return;
    if (!(fd.type_params.len > 0 and fd.is_ufcs)) return;
    if (!self.ufcsGenericBindsAll(fd, args_ast)) return;
    const concrete = ufcsReceiverConcrete(fd);
    if (best.*) |b| {
        if (b == fd) return; // same decl via a re-export — dedup
        if (concrete and !best_concrete.*) {
            best.* = fd;
            best_concrete.* = true;
            tie.* = false; // strictly more specific wins outright
        } else if (concrete == best_concrete.*) {
            tie.* = true; // two distinct equally-specific binders
        }
        // else: strictly less specific → ignore
    } else {
        best.* = fd;
        best_concrete.* = concrete;
    }
}

/// A bare-ufcs name resolves through a single
/// last-wins `fn_ast_map` winner (`fd0`), which may be a same-named generic ufcs
/// whose receiver does NOT match the call's receiver (e.g. user `cancel :: ufcs
/// (t: *Task($R))` shadowed by the stdlib `cancel :: ufcs (f: *Future($R))`).
/// Pick the most receiver-specific BINDING author, in two tiers so visibility is
/// respected (the non-transitive import model) without losing receiver-reachable
/// namespaced methods:
///
///   Tier 1 — DIRECTLY-VISIBLE authors (own + one-hop flat, via
///   `collectVisibleAuthors`). A genuine user-facing ambiguity (two distinct
///   equally-specific VISIBLE binders) sets `ambiguous.*` here.
///   Tier 2 (only if no visible author binds) — receiver-reachable methods that
///   aren't flat-visible (a `*Task($R)` method reached through a `sched ::
///   @import` namespace). Scan all module authors for the unique most-specific
///   binder; on a tie among non-visible binders DON'T cry ambiguous — defer to
///   `fd0` (the global last-wins) so a transitively-hidden collision never
///   surfaces as a false error.
///
/// MUST be called identically from call planning (`calls.zig`) and lowering so
/// the planned result type and the dispatched function never disagree (which
/// would misbox the result). Returns null when nothing binds (the caller falls
/// back to `fd0` if it binds, else diagnoses — never monomorphizes `.unresolved`).
pub fn selectUfcsGenericByReceiver(self: *Lowering, name: []const u8, args_ast: []const *const Node, ambiguous: *bool, fd0: ?*const ast.FnDecl) ?*const ast.FnDecl {
    ambiguous.* = false;
    // Tier 1: directly-visible authors. Ambiguity is a user-facing error only here.
    if (self.current_source_file) |caller_file| {
        var res = self.resolver();
        const set = res.collectVisibleAuthors(name, caller_file, .user_bare_flat);
        defer if (set.flat.len > 0) self.alloc.free(set.flat);
        var best: ?*const ast.FnDecl = null;
        var best_concrete = false;
        var tie = false;
        if (set.own) |own| rankUfcsCand(self, Lowering.fnDeclOfRaw(own.raw), args_ast, &best, &best_concrete, &tie);
        for (set.flat) |fa| rankUfcsCand(self, Lowering.fnDeclOfRaw(fa.raw), args_ast, &best, &best_concrete, &tie);
        if (best) |b| {
            if (tie) {
                ambiguous.* = true;
                return null;
            }
            return b;
        }
    }
    // Tier 2: receiver-reachable but not flat-visible (namespaced methods defined
    // alongside the receiver type). Pick the unique most-specific binder; on a
    // hidden tie defer to `fd0` rather than reporting a false ambiguity.
    const decls = self.program_index.module_decls orelse return null;
    var best: ?*const ast.FnDecl = null;
    var best_concrete = false;
    var tie = false;
    var it = decls.iterator();
    while (it.next()) |entry| {
        const ref = entry.value_ptr.names.get(name) orelse continue;
        // A private method is receiver-reachable only from its own file.
        if (entry.value_ptr.private_names.contains(name)) {
            const requester = self.current_source_file orelse self.main_file orelse entry.value_ptr.source;
            if (!std.mem.eql(u8, requester, entry.value_ptr.source)) continue;
        }
        rankUfcsCand(self, Lowering.fnDeclOfRaw(ref), args_ast, &best, &best_concrete, &tie);
    }
    if (best == null) return null;
    if (tie) {
        if (fd0) |w| {
            if (self.ufcsGenericBindsAll(w, args_ast)) return w;
        }
        return null;
    }
    return best;
}

/// True when every module authoring `name` declares it `private` (and at
/// least one does). Steers the visibility-gate diagnostic: "@import the
/// module that declares it" is useless advice for a private name.
fn nameAuthoredOnlyPrivately(self: *Lowering, name: []const u8) bool {
    const decls = self.program_index.module_decls orelse return false;
    var any = false;
    var it = decls.valueIterator();
    while (it.next()) |m| {
        if (!m.names.contains(name)) continue;
        if (!m.private_names.contains(name)) return false;
        any = true;
    }
    return any;
}

/// True when `name` is bound in the current lexical scope to a CALLABLE
/// value — a fn-pointer or closure local. Such a binding shadows any
/// same-named top-level fn in call position: the call must
/// dispatch indirectly through the LOCAL, so every program-fn path — the
/// non-transitive-visibility gate, the early pack/comptime/generic
/// dispatch, and direct name dispatch — is skipped for it. Without this,
/// an importer's unrelated module-scope `h` hijacks (or the visibility
/// gate rejects) an imported module's own `h := ...; h(...)` sites.
/// A pack-element alias is excluded (the substitution path owns it), as
/// is a non-callable binding: it falls through to the program-fn paths and
/// the trailing any-binding indirect-call fallback.
/// Nearest-scope resolution: a nested local fn decl at a
/// NEARER level owns the name — `lookupNearest` walks the chain once,
/// consulting BOTH per-level namespaces, so an outer callable var never
/// beats an inner nested fn (and vice versa).
pub fn callableLocalShadow(self: *Lowering, name: []const u8) bool {
    const scope = self.scope orelse return false;
    const near = scope.lookupNearest(name) orelse return false;
    const binding = switch (near) {
        // Nested local fn is nearest: the mangled-name direct-dispatch
        // path owns the call (innermost wins) — no value shadow.
        .local_fn => return false,
        .binding => |b| b,
    };
    if (binding.pack_elem != null) return false;
    return self.callableSigOf(binding.ty) != null;
}

/// Call the function a unique lambda's env `env_addr` belongs to. The value IS
/// the env, so the address stands in for the fat pointer a `Closure` carries.
fn callUniqueLambda(self: *Lowering, u: lower_closure.UniqueLambda, env_addr: Ref, args: []Ref) Ref {
    coerceClosureCallArgs(self, args, u.params);
    var call_args = std.ArrayList(Ref).empty;
    defer call_args.deinit(self.alloc);
    if (self.module.functions.items[u.func.index()].has_implicit_ctx) {
        call_args.append(self.alloc, self.current_ctx_ref) catch unreachable;
    }
    call_args.append(self.alloc, env_addr) catch unreachable;
    call_args.appendSlice(self.alloc, args) catch unreachable;
    const owned = self.alloc.dupe(Ref, call_args.items) catch unreachable;
    return self.builder.emit(.{ .call = .{ .callee = u.func, .args = owned } }, u.ret);
}

/// Call the `call` that `impl (sig) for T` declares. The callee expression IS
/// the receiver, so the receiver fixup a method call uses decides whether `call`
/// gets it by value or by address; `recv_addr` is the receiver's storage when
/// the cell already produced it, so an lvalue callee is evaluated once.
///
/// The dispatch key is the declaration itself: `cn.qualified` is a spelled
/// `Type.call` that two same-display-name conformers share.
fn callNominal(
    self: *Lowering,
    cn: lower_protocol.CallableNominal,
    recv_node: *const Node,
    recv: Ref,
    recv_addr: ?Ref,
    recv_ty: TypeId,
    args: []const Ref,
    c: *const ast.Call,
    span: ast.Span,
) Ref {
    if (self.checkCallArity(cn.fd, cn.qualified, args.len + 1, true, span)) return Ref.none;
    const fid = self.fn_decl_fids.get(cn.fd) orelse return Ref.none;
    if (!self.lowered_fids.contains(fid)) {
        self.lowered_fids.put(fid, {}) catch @panic("out of memory");
        self.lowerFunctionBodyInto(cn.fd, fid, cn.qualified);
    }
    var call_args = std.ArrayList(Ref).empty;
    defer call_args.deinit(self.alloc);
    call_args.append(self.alloc, recv) catch unreachable;
    call_args.appendSlice(self.alloc, args) catch unreachable;
    self.appendDefaultArgs(cn.fd, &call_args, c.callee);
    const func = &self.module.functions.items[@intFromEnum(fid)];
    const ret_ty = func.ret;
    const params = func.params;
    self.fixupMethodReceiver(&call_args, func, recv_node, recv_ty, recv_addr);
    // `coerceCallArgs` can add a function to the module and invalidate `func`,
    // so its fields are read above.
    const final_args = self.prependCtxIfNeeded(func, call_args.items);
    self.coerceCallArgs(final_args, params);
    return self.builder.call(fid, final_args, ret_ty);
}

/// The callee VALUE a call dispatches through: the value itself, the address of
/// the storage holding it when the cell produced one, and where it came from —
/// which selects the arity checker that shape's diagnostics come from.
const CalleeValue = struct {
    ty: TypeId,
    /// `Ref.none` when only `addr` is known; the shape loads it on demand.
    ref: Ref,
    addr: ?Ref = null,
    node: *const Node,
    name: ?[]const u8 = null,
    origin: Origin,

    /// Which arity checker and argument coercion the value's shape uses.
    const Origin = union(enum) {
        /// A local binding: a fn pointer dispatches through its own checker.
        local: lower.Binding,
        /// A module global read by bare name, whose `*T` params take the
        /// address of a `T` argument.
        bare_global,
        /// A selected namespace member, a field, or any other expression.
        value,
    };
};

fn calleeValueRef(self: *Lowering, cv: CalleeValue) Ref {
    return if (cv.ref.isNone()) self.builder.load(cv.addr.?, cv.ty) else cv.ref;
}

/// Call a callable VALUE through the one classification `callableShapeOf`
/// makes. Null when the value is not callable at all, so a cell can fall
/// through to its remaining dispatch.
fn callValue(self: *Lowering, cv: CalleeValue, c: *const ast.Call, args: []Ref, span: ast.Span) ?Ref {
    switch (self.callableShapeOf(cv.ty) orelse return null) {
        .unique => |u| {
            if (checkCallableValueArgs(self, "closure", cv.name, args, .{ .fixed = u.params.len, .pack_start = null }, c, span)) return Ref.none;
            const env_addr = if (cv.addr) |a|
                uniqueEnvAddress(self, cv.ty, a, true).?
            else
                uniqueEnvAddress(self, cv.ty, cv.ref, false).?;
            return callUniqueLambda(self, u, env_addr, args);
        },
        .nominal => |cn| return callNominal(self, cn, cv.node, calleeValueRef(self, cv), cv.addr, cv.ty, args, c, span),
        .closure => |ci| {
            if (checkCallableValueArgs(self, "closure", cv.name, args, .{ .fixed = ci.params.len, .pack_start = ci.pack_start }, c, span)) return Ref.none;
            const callee_ref = calleeValueRef(self, cv);
            coerceClosureCallArgs(self, args, ci.params);
            // Closure trampolines carry `__sx_ctx` at slot 0; emit_llvm builds
            // the call as [ctx, env, user_args].
            const owned = if (self.implicit_ctx_enabled) blk: {
                const arr = self.alloc.alloc(Ref, args.len + 1) catch unreachable;
                arr[0] = self.current_ctx_ref;
                @memcpy(arr[1..], args);
                break :blk arr;
            } else self.alloc.dupe(Ref, args) catch unreachable;
            return self.builder.emit(.{ .call_closure = .{ .callee = callee_ref, .args = owned } }, ci.ret);
        },
        .fn_ptr => |fi| {
            if (cv.origin == .local) {
                if (rejectLeftoverSpreadPlaceholder(self, "a function pointer", args, c, span)) return Ref.none;
                return indirectCallThroughLocal(self, cv.name orelse "", cv.origin.local, args, span);
            }
            if (checkCallableValueArgs(self, "function pointer", cv.name, args, fnPointerShape(fi), c, span)) return Ref.none;
            const callee_ref = calleeValueRef(self, cv);
            if (cv.origin == .bare_global) {
                coerceGlobalFnPointerArgs(self, args, fi, c);
            } else {
                coerceFnPointerCallArgs(self, args, fi);
            }
            var final_args = std.ArrayList(Ref).empty;
            defer final_args.deinit(self.alloc);
            if (self.fnPtrTypeWantsCtx(cv.ty)) final_args.append(self.alloc, self.current_ctx_ref) catch unreachable;
            final_args.appendSlice(self.alloc, args) catch unreachable;
            const owned = self.alloc.dupe(Ref, final_args.items) catch unreachable;
            return self.builder.emit(.{ .call_indirect = .{ .callee = callee_ref, .args = owned } }, fi.ret);
        },
    }
}

/// The callee a module global names, or null when the global is not callable.
/// A MUTABLE global carries its live storage, so a `call` taking `self: *T`
/// writes through the global itself; a `::` const lives in `.rodata` and is
/// called through a copy.
fn globalCallee(self: *Lowering, gi: GlobalInfo, name: []const u8, node: *const Node, origin: CalleeValue.Origin) ?CalleeValue {
    const addressed = switch (self.callableShapeOf(gi.ty) orelse return null) {
        .unique, .nominal => !self.module.globals.items[gi.id.index()].is_const,
        .closure, .fn_ptr => false,
    };
    return .{
        .ty = gi.ty,
        .ref = if (addressed) Ref.none else self.builder.emit(.{ .global_get = gi.id }, gi.ty),
        .addr = if (addressed) self.builder.emit(.{ .global_addr = gi.id }, self.module.types.ptrTo(gi.ty)) else null,
        .node = node,
        .name = name,
        .origin = origin,
    };
}

/// Argument coercion for a call through a module-global function pointer. A
/// `*T` param takes the ADDRESS of a `T` argument: an identifier naming an
/// alloca passes that storage, every other expression a copy.
fn coerceGlobalFnPointerArgs(self: *Lowering, args: []Ref, info: types.TypeInfo.FunctionInfo, c: *const ast.Call) void {
    // A tuple/pack spread expands one AST arg to N lowered args, so `c.args[ai]`
    // only aligns while `ai` is in range — a spliced element falls back to its
    // lowered ref's type.
    for (args, 0..) |*arg, ai| {
        if (ai >= info.params.len) break;
        const dst_ty = info.params[ai];
        const src_ty = if (ai < c.args.len) self.inferExprType(c.args[ai]) else self.builder.getRefType(arg.*);
        if (!dst_ty.isBuiltin()) {
            const dti = self.module.types.get(dst_ty);
            if (dti == .pointer and dti.pointer.pointee == src_ty and src_ty != .void) {
                if (ai < c.args.len and c.args[ai].data == .identifier) {
                    if (self.scope) |scope| {
                        if (scope.lookup(c.args[ai].data.identifier.name)) |binding| {
                            if (binding.is_alloca) {
                                arg.* = self.builder.emit(.{ .addr_of = .{ .operand = binding.ref } }, dst_ty);
                                continue;
                            }
                        }
                    }
                }
                const slot = self.builder.alloca(src_ty);
                self.builder.store(slot, arg.*);
                arg.* = slot;
                continue;
            }
        }
        arg.* = self.coerceToType(arg.*, src_ty, dst_ty);
    }
    if (info.is_c_variadic) self.promoteCVariadicArgs(args, info.params.len);
}

/// The env address behind a value of unique type `ty`: a `*$F` names one
/// directly, a binding names its own storage.
fn uniqueEnvAddress(self: *Lowering, ty: TypeId, ref: Ref, is_alloca: bool) ?Ref {
    if (self.uniqueLambdaOf(ty) != null) {
        if (is_alloca) return ref;
        const slot = self.builder.alloca(ty);
        self.builder.store(slot, ref);
        return slot;
    }
    if (ty.isBuiltin()) return null;
    const info = self.module.types.get(ty);
    if (info != .pointer or self.uniqueLambdaOf(info.pointer.pointee) == null) return null;
    return if (is_alloca) self.builder.load(ref, ty) else ref;
}

/// Indirect call through a local VALUE binding (fn-pointer local, or the
/// trailing any-binding fallback). Checks arity against the fn-pointer's
/// signature (arg coercion min()-truncates, so a wrong-arity call would
/// otherwise silently drop args), coerces args to the param
/// types, and prepends the implicit ctx when the pointee signature wants it.
fn indirectCallThroughLocal(self: *Lowering, name: []const u8, binding: lower.Binding, args: []Ref, span: ast.Span) Ref {
    // Arity: the fn TYPE's params are user-visible (no __sx_ctx slot —
    // `fnPtrTypeWantsCtx` prepends it from the calling convention) and a
    // pack-variadic signature (`pack_start != null`) binds per call shape,
    // so it is exempt. A C-variadic tail takes whatever follows the fixed
    // prefix; every other signature is exact.
    if (!binding.ty.isBuiltin()) {
        const bti = self.module.types.get(binding.ty);
        if (bti == .function and bti.function.pack_start == null) {
            const want = bti.function.params.len;
            const exact = !bti.function.is_c_variadic;
            if (args.len < want or (exact and args.len > want)) {
                if (self.diagnostics) |d| {
                    const s: []const u8 = if (want == 1) "" else "s";
                    const verb: []const u8 = if (args.len == 1) "was" else "were";
                    const at_least: []const u8 = if (exact) "" else "at least ";
                    d.addFmt(.err, span, "'{s}' expects {s}{d} argument{s}, but {d} {s} given", .{ name, at_least, want, s, args.len, verb });
                }
                return Ref.none;
            }
        }
    }
    const callee_ref = if (binding.is_alloca) self.builder.load(binding.ref, binding.ty) else binding.ref;
    const ret_ty = if (!binding.ty.isBuiltin()) blk: {
        const bti = self.module.types.get(binding.ty);
        break :blk if (bti == .function) bti.function.ret else .i64;
    } else .i64;
    // Coerce user args to the fn-pointer's param types — same as
    // the closure-value and global-fn-pointer
    // paths. The arg loop already applied implicit address-of
    // for `*T` params (resolveCallParamTypes now surfaces the
    // `.function` param types), so this completes value
    // coercions like a `?T` wrap. Without it a concrete arg to a
    // `?T` fn-ptr param reaches `call_indirect` unconverted.
    if (!binding.ty.isBuiltin()) {
        const bti = self.module.types.get(binding.ty);
        if (bti == .function) coerceFnPointerCallArgs(self, args, bti.function);
    }
    var final_args = std.ArrayList(Ref).empty;
    defer final_args.deinit(self.alloc);
    if (self.fnPtrTypeWantsCtx(binding.ty)) {
        final_args.append(self.alloc, self.current_ctx_ref) catch unreachable;
    }
    final_args.appendSlice(self.alloc, args) catch unreachable;
    const owned = self.alloc.dupe(Ref, final_args.items) catch unreachable;
    return self.builder.emit(.{ .call_indirect = .{ .callee = callee_ref, .args = owned } }, ret_ty);
}

/// Call an exactly-selected namespace global without round-tripping through
/// the process-wide name map. Every callable shape keeps the same ABI, arity
/// and coercion behavior as its bare callable-value form.
fn callThroughSelectedGlobal(
    self: *Lowering,
    selected: CallResolver.CallableValue,
    args: []Ref,
    c: *const ast.Call,
    span: ast.Span,
) Ref {
    const cv = globalCallee(self, selected.global, selected.member, c.callee, .value) orelse
        return self.emitError(selected.member, span);
    return callValue(self, cv, c, args, span) orelse self.emitError(selected.member, span);
}

/// Whether the callee MAY declare a slice-variadic param (`..xs: []T`).
/// Consulted by the value-spread expansion in the arg loop: an ARRAY spread
/// into a slice variadic must stay whole (the packVariadicCallArgs fast path
/// takes the array AS the slice), so expansion is skipped when this returns
/// true. Conservative: an unresolvable callee (field-access method we can't
/// name here, unknown identifier) reports true — the placeholder path then
/// keeps existing behavior (slice-variadic pass-through or an arity
/// diagnostic), never a desynced expansion.
fn calleeMayHaveVariadicParam(self: *Lowering, c: *const ast.Call, sel_author: ?*SelectedFunc, qualified_callable: ?GlobalInfo) bool {
    if (qualified_callable != null) return false;
    const fd: ?*const ast.FnDecl = blk: {
        if (sel_author) |sf| break :blk sf.decl;
        switch (c.callee.data) {
            .identifier => |id| {
                const eff = if (self.scope) |scope| scope.lookupFn(id.name) orelse id.name else id.name;
                if (self.program_index.fn_ast_map.get(eff)) |fd| break :blk fd;
                // A local closure / fn-pointer binding has a fixed signature —
                // it can never be slice-variadic.
                if (self.scope) |scope| {
                    if (scope.lookup(id.name) != null) break :blk null;
                }
                return true; // unknown callee — stay conservative
            },
            .field_access => |fa| {
                if (self.callResolver().objectIsValue(fa.object)) {
                    const recv_ty = self.inferExprType(fa.object);
                    if (self.plainStructMethod(recv_ty, fa.field)) |method| break :blk method.fd;
                    if (self.hasPlainStructAuthor(recv_ty)) return true;
                } else switch (self.staticStructHead(fa.object)) {
                    .resolved => |owner_ty| {
                        if (self.plainStructMethod(owner_ty, fa.field)) |method| break :blk method.fd;
                        if (self.hasPlainStructAuthor(owner_ty)) return true;
                    },
                    .ambiguous, .not_visible => return true,
                    .none => {},
                }
                // Namespaced / UFCS free fn by bare member name; anything we
                // can't resolve stays conservative.
                const eff = self.ufcsAliasTarget(fa.field) orelse fa.field;
                if (self.program_index.fn_ast_map.get(eff)) |fd| break :blk fd;
                return true;
            },
            else => return true,
        }
    };
    const f = fd orelse return false;
    for (f.params) |p| {
        if (p.is_variadic) return true;
    }
    return false;
}

/// Whether a generic declaration parameter denotes a TYPE which must be bound
/// before the comptime body can resolve its signature/body. Comptime value
/// params (`$o: Ord`, `$n: i64`) use the value-binding machinery instead.
fn comptimeTypeParamNeedsBinding(self: *Lowering, tp: ast.StructTypeParam, source: ?[]const u8) bool {
    if (tp.is_variadic or tp.constraint.data != .type_expr) return false;
    const constraint = tp.constraint.data.type_expr.name;
    return std.mem.eql(u8, constraint, "Type") or
        self.isProtocolConstraint(constraint, source);
}

fn comptimeMethodBindingsComplete(
    self: *Lowering,
    fd: *const ast.FnDecl,
    bindings: *const std.StringHashMap(TypeId),
    span: ast.Span,
) bool {
    for (fd.type_params) |tp| {
        if (!comptimeTypeParamNeedsBinding(self, tp, fd.body.source_file) or bindings.contains(tp.name)) continue;
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "cannot infer generic type parameter '{s}' for comptime method '{s}' from this call's arguments", .{ tp.name, fd.name });
        return false;
    }
    return true;
}

/// Inline a selected plain-struct comptime method through one effective AST
/// argument list. Instance calls prepend their receiver; static and
/// target-typed shorthand calls do not. The shared comptime helper stages the
/// whole list before installing any formal, so all call forms get identical
/// target typing, pointer adaptation, single evaluation, and body hygiene.
fn lowerComptimePlainStructMethod(
    self: *Lowering,
    method: Lowering.PlainStructMethod,
    recv_node: ?*const Node,
    call_args: []const *Node,
    call_span: ast.Span,
) Ref {
    const fd = method.fd;
    var effective_args = std.ArrayList(*Node).empty;
    defer effective_args.deinit(self.alloc);
    if (recv_node) |receiver| effective_args.append(self.alloc, @constCast(receiver)) catch unreachable;
    effective_args.appendSlice(self.alloc, call_args) catch unreachable;

    var method_bindings: ?std.StringHashMap(TypeId) = null;
    var binding_scope: ?generics_mod.TypeBindingScope = null;
    defer {
        if (binding_scope) |*bs| bs.exit();
        if (method_bindings) |*bindings| bindings.deinit();
    }
    if (fd.type_params.len > 0) {
        method_bindings = self.genericResolver().buildTypeBindings(fd, effective_args.items);
        if (!comptimeMethodBindingsComplete(self, fd, &method_bindings.?, call_span)) return Ref.none;
        binding_scope = generics_mod.installTypeBindings(self, method_bindings.?);
    }

    return self.lowerComptimeMethodCallArgs(fd, effective_args.items, recv_node != null, call_span);
}

pub fn lowerCall(self: *Lowering, c_in: *const ast.Call) Ref {
    var c = c_in;
    // A bare reserved-type-name spelling in call position parses as a
    // `.type_expr` (e.g. `i8(4)`), but if a function of that name is in
    // scope — a backtick-declared sx fn or a `@import c` extern fn whose C
    // name collides with a reserved type spelling — it is a CALL to that
    // function. `TypeName(val)` is not a cast (casts are `cast(T, val)`), so
    // there is no ambiguity. Rewrite the callee to an identifier so the
    // normal call machinery resolves it, symmetric to the bare-value
    // reference that already resolves via scope/globals.
    //
    // Scoped to RAW provenance: only a backtick (`is_raw`) or `@import c`
    // extern fn declaration may legally carry a reserved-name spelling
    // (the decl check rejects every bare reserved-name sx fn). Refusing the
    // rewrite for a non-raw match keeps a genuine reserved type spelling a
    // type — belt-and-suspenders should any future path ever reintroduce a
    // non-raw reserved-name callee.
    if (c.callee.data == .type_expr) {
        const tname = c.callee.data.type_expr.name;
        const eff = if (self.scope) |scope| scope.lookupFn(tname) orelse tname else tname;
        const fd: ?*const ast.FnDecl = self.program_index.fn_ast_map.get(eff) orelse
            self.program_index.fn_ast_map.get(tname);
        if (fd) |decl| if (decl.is_raw) {
            const id_node = self.alloc.create(Node) catch unreachable;
            id_node.* = .{ .span = c.callee.span, .data = .{ .identifier = .{ .name = tname, .is_raw = true } } };
            const rewritten = self.alloc.create(ast.Call) catch unreachable;
            rewritten.* = .{ .callee = id_node, .args = c.args };
            c = rewritten;
        };
    }
    // Select an identity-bearing call author ONCE before any signature
    // consumer. Bare same-name collisions use the flat-author selector;
    // namespace calls use the arbitrary-depth qualified-member selector. The
    // two forms are mutually exclusive. Defaults, contextual argument typing,
    // specialized/generic lowering and final dispatch all consume this exact
    // `FnDecl` + source pair rather than re-looking up a collapsed global name.
    var qualified_call_verdict = self.callResolver().classifyQualifiedCall(c);
    var bare_author_verdict: Lowering.BareCallee = switch (qualified_call_verdict) {
        .never_qualified, .value_receiver => self.callResolver().selectedFreeAuthor(c),
        .type_prefix, .func, .callable_value, .non_callable, .missing, .not_visible, .ambiguous => .none,
    };
    const bare_author: ?*SelectedFunc = switch (bare_author_verdict) {
        .func => |*sf| sf,
        else => null,
    };
    const qualified_author: ?*SelectedFunc = switch (qualified_call_verdict) {
        .func => |*sf| sf,
        else => null,
    };
    const qualified_callable: ?CallResolver.CallableValue = switch (qualified_call_verdict) {
        .callable_value => |cv| cv,
        else => null,
    };
    const sel_author: ?*SelectedFunc = bare_author orelse qualified_author;
    const author_ambiguous = bare_author_verdict == .ambiguous;
    // The bare name's visible author is a VALUE: this spelling denotes that
    // declaration here, so no name-keyed function lookup may answer for it.
    const author_not_callable = bare_author_verdict == .not_callable;
    // Either verdict forbids reading a signature off the name-keyed winner
    // (`sel_author` / `fn_ast_map`).
    const author_declines = author_ambiguous or author_not_callable;

    // A proved namespace path that fails at one edge/member is terminal. Emit
    // the selector's exact failure now and do not evaluate argument side effects
    // before reporting a call which cannot exist.
    switch (qualified_call_verdict) {
        .missing => |m| {
            if (self.diagnostics) |d|
                d.addFmt(.err, m.span, "namespace '{s}' has no member '{s}'", .{ m.namespace, m.member });
            return Ref.none;
        },
        .not_visible => |hidden| {
            if (self.diagnostics) |d|
                d.addFmt(.err, hidden.span, "namespace '{s}' is not visible; @import the module that declares it", .{hidden.alias});
            return Ref.none;
        },
        .ambiguous => |amb| {
            if (self.diagnostics) |d|
                d.addFmt(.err, amb.span, "namespace '{s}' is ambiguous: aliases from multiple flat-imported modules point at different targets; declare the alias locally", .{amb.alias});
            return Ref.none;
        },
        .non_callable => |nc| {
            if (self.diagnostics) |d|
                d.addFmt(.err, nc.span, "cannot call '{s}' — this namespace member is not callable", .{nc.member});
            return Ref.none;
        },
        .never_qualified, .value_receiver, .type_prefix, .func, .callable_value => {},
    }
    // Named-argument mapping (specs: Named Arguments) — rewrite
    // `f(a, name = v)` into declaration order with defaults filled, BEFORE
    // positional default expansion (a named call never reaches it: mapping
    // fills every default itself, middle holes included).
    if (mapNamedArgs(self, c, sel_author, qualified_author != null, if (qualified_callable) |cv| cv.global else null, author_declines)) |mapped| c = mapped;
    // Expand default parameter values for bare identifier callees:
    // when the caller omits trailing positional args, fill them in
    // from the callee's `param: T = expr` declarations.
    if (self.expandCallDefaults(c, sel_author, qualified_author != null, author_declines)) |expanded| c = expanded;
    // Check reflection builtins first (before lowering args — some args are type names, not values)
    if (c.callee.data == .identifier) {
        if (self.tryLowerReflectionCall(c.callee.data.identifier.name, c)) |ref| return ref;
        // Atomic intrinsics (atomic_load/atomic_store): a type arg + value args,
        // so lower them here (before generic arg lowering) like reflection calls.
        if (self.tryLowerAtomicIntrinsic(c.callee.data.identifier.name, c)) |ref| return ref;
        if (self.tryLowerVolatileIntrinsic(c.callee.data.identifier.name, c)) |ref| return ref;
        if (self.tryLowerPrintfIntrinsic(c.callee.data.identifier.name, c)) |ref| return ref;
        if (self.tryLowerCursorIntrinsic(c.callee.data.identifier.name, c)) |ref| return ref;
    }
    // Qualified intrinsic spelling is legal too. Only dispatch a compiler
    // recognizer after the full namespace path selected the exact declaration
    // and proved that its body is intrinsic; the terminal name alone is not
    // authority (intrinsic identity is module + name).
    if (qualified_author) |sf| {
        if (sf.decl.body.data == .intrinsic_expr) {
            if (self.tryLowerReflectionCall(sf.decl.name, c)) |ref| return ref;
            if (self.tryLowerAtomicIntrinsic(sf.decl.name, c)) |ref| return ref;
            if (self.tryLowerVolatileIntrinsic(sf.decl.name, c)) |ref| return ref;
            if (self.tryLowerPrintfIntrinsic(sf.decl.name, c)) |ref| return ref;
            if (self.tryLowerCursorIntrinsic(sf.decl.name, c)) |ref| return ref;
        }
    }

    if (c.callee.data == .identifier) {
        const id_name = c.callee.data.identifier.name;
        const eff_name = blk: {
            const scoped = if (self.scope) |scope| scope.lookupFn(id_name) orelse id_name else id_name;
            if (self.ufcsAliasTarget(id_name)) |target| {
                break :blk if (self.scope) |scope| scope.lookupFn(target) orelse target else target;
            }
            break :blk scoped;
        };
        // C-import visibility: deny calls to C fn_decls not in the caller's module scope
        if (!self.isCImportVisible(eff_name)) {
            if (self.diagnostics) |d|
                d.addFmt(.err, c.callee.span, "C function '{s}' not visible; add @import for the module that declares it", .{eff_name});
            return Ref.none;
        }
        // Non-transitive `@import` visibility check. Apply only when the
        // user-typed name resolved as-is to a top-level fn — local-scope
        // mangling (eff_name != id_name) and UFCS alias rewriting are
        // compiler indirections and stay exempt. A callable LOCAL binding
        // shadows the top-level fn entirely: the call targets
        // the local, so the program-fn visibility gate must not fire.
        // An intrinsic is a compiler feature, not a library export, so import
        // visibility does not gate it — the same reason `size_of` / `sqrt` /
        // `atomic_load` resolve with no import (their folds run before this
        // check). The evaluate-mode intrinsics DO reach here, because the VM
        // services them as ordinary declared calls; exempting them keeps every
        // intrinsic reachable on the same terms.
        if (std.mem.eql(u8, eff_name, id_name) and
            self.ufcsAliasTarget(id_name) == null and
            !self.respelled_ufcs_callees.contains(c.callee) and
            self.program_index.fn_ast_map.contains(eff_name) and
            !callableLocalShadow(self, id_name) and
            intrinsics.findByName(eff_name) == null and
            !self.isNameVisible(eff_name))
        {
            if (self.diagnostics) |d| {
                if (nameAuthoredOnlyPrivately(self, eff_name))
                    d.addFmt(.err, c.callee.span, "'{s}' is private to its declaring module", .{eff_name})
                else
                    d.addFmt(.err, c.callee.span, "'{s}' is not visible; @import the module that declares it", .{eff_name});
            }
            return Ref.none;
        }
    }


    // Early detection of comptime-expanded calls (e.g. print) — skip arg evaluation
    // since lowerComptimeCall re-evaluates args from AST (avoiding double evaluation)
    if (c.callee.data == .identifier) {
        const early_name = blk: {
            const id_name = c.callee.data.identifier.name;
            const scoped = if (self.scope) |scope| scope.lookupFn(id_name) orelse id_name else id_name;
            if (self.ufcsAliasTarget(id_name)) |target| {
                break :blk if (self.scope) |scope| scope.lookupFn(target) orelse target else target;
            }
            break :blk scoped;
        };
        // The early pack/comptime/generic dispatch reads
        // the SAME author the call resolver SELECTED — not the first-wins
        // winner. A bare call selects every sx-bodied shape, so a selected
        // pack / comptime / generic author monomorphizes HERE, from the
        // caller's own author; a selected plain author falls through to the
        // main dispatch, which CONSUMES `sel_author` and binds it. Without
        // this the early path would dispatch the first-wins winner and
        // disagree with the main dispatch — the selected author's bare call
        // would invoke another module's function. On the common path
        // (`sel_author == null`) this reads the winner exactly as before —
        // byte-identical, since the selector reroutes nothing there.
        // A callable LOCAL binding shadows the top-level fn:
        // the early pack/comptime/generic program-fn dispatch must not
        // consume the call — the main dispatch routes it indirect through
        // the local. (`sel_author` is already `.none` for any shadowed
        // name, so only the first-wins map lookup needs the gate.)
        const early_fd: ?*const ast.FnDecl = if (sel_author) |sf|
            sf.decl
        else if (author_not_callable or callableLocalShadow(self, c.callee.data.identifier.name))
            null
        else
            self.program_index.fn_ast_map.get(early_name);
        if (early_fd) |fd| {
            if (isPackFn(fd)) {
                // Protocol packs (`..xs: P`) and comptime type-packs
                // (`..$args`) both monomorphize per call shape.
                return self.lowerPackFnCall(fd, c);
            }
            if (hasComptimeParams(fd)) {
                return self.lowerComptimeCall(fd, c);
            }
            // Early detection of generic function calls — skip arg lowering for type params
            // because lowerGenericCall resolves type params from AST nodes, not lowered refs.
            // Only if the name is NOT shadowed by a local variable (closure, fn ptr, etc.).
            // A selected author is never generic (`isPlainFreeFn` excludes
            // `type_params > 0`), so this branch fires only on the winner.
            const shadowed = if (self.scope) |scope| scope.lookup(c.callee.data.identifier.name) != null else false;
            if (fd.type_params.len > 0 and !shadowed) {
                if (self.expandSpreadArgNodes(c.args)) |expanded| {
                    const syn_call = ast.Call{ .callee = c.callee, .args = expanded };
                    return self.lowerCall(&syn_call);
                }
                // Monomorphization binds args by parameter position and drops
                // the rest, so the count has to answer for itself here — the
                // arity check the main dispatch runs is downstream of this arm.
                if (self.checkCallArity(fd, c.callee.data.identifier.name, c.args.len, false, c.callee.span)) return Ref.none;
                const types_explicit = self.genericResolver().typesPassedExplicitly(fd, c.args);
                // Resolve the DECLARED param demands up front — in the callee's
                // source, with $T bindings inferred from the arg nodes — and
                // align them to the ARG positions (inference calls omit the
                // type-param slots). Each resolvable param supplies its arg's
                // target exactly like the direct-call path: without it, an
                // `xx local` arg to a protocol param lowers node-lessly and
                // the later value-wise coercion copies the local into a frame
                // temp and borrows THAT instead of the local. An
                // unresolvable param slot keeps a null target (the ambient
                // target must still not leak into the arg).
                const early_param_types = astCalleeParamTypes(self, fd, c.args);
                var arg_demands = std.ArrayList(ParamDemand).empty;
                defer arg_demands.deinit(self.alloc);
                for (fd.params, 0..) |*p, pi| {
                    if (!types_explicit and isTypeParamDecl(p, fd.type_params)) continue;
                    arg_demands.append(self.alloc, if (pi < early_param_types.len) early_param_types[pi] else .none) catch unreachable;
                }
                var lowered_args = std.ArrayList(Ref).empty;
                defer lowered_args.deinit(self.alloc);
                for (c.args, 0..) |arg, ai| {
                    // Skip type param args only when types are passed explicitly
                    if (types_explicit and ai < fd.params.len and isTypeParamDecl(&fd.params[ai], fd.type_params)) {
                        lowered_args.append(self.alloc, Ref.none) catch unreachable;
                    } else {
                        var dem = self.enterDemand(if (ai < arg_demands.items.len) arg_demands.items[ai] else .none);
                        defer dem.restore();
                        const tgt: ?TypeId = self.target_type;
                        const r = blk: {
                            // A `$I/@Init(T)` param forms its recipe instead of
                            // evaluating the argument (same arm as the direct
                            // path below).
                            if (tgt) |ptv| {
                                if (self.initTargetOf(ptv)) |target| break :blk self.formInitPlan(arg, target);
                                // A `$B/@BuildBlock(P)` param forms its block from
                                // the trailing body, or takes one already formed.
                                if (self.blockProtocolOf(ptv)) |protocol| break :blk self.formBuildBlock(arg, protocol);
                            }
                            // Protocol param targets erase node-aware
                            // (same arm as the direct path).
                            if (tgt) |ptv| {
                                if (protocolArgErasure(self, arg, ptv)) |ib| break :blk ib;
                            }
                            // A `@VaList` param is the C boundary: the argument
                            // names a live list and its PLACE crosses (same arm
                            // as the direct path) — a cursor has no value form
                            // for `lowerExpr` to read.
                            if (tgt) |ptv| {
                                if (self.boundaryCursorArg(arg, ptv)) |place| break :blk place;
                            }
                            break :blk self.lowerExpr(arg);
                        };
                        lowered_args.append(self.alloc, r) catch unreachable;
                    }
                }
                return self.lowerGenericCall(fd, early_name, c, lowered_args.items);
            }
        }
    }

    // Exactly-selected qualified pack/comptime functions own AST argument
    // evaluation and therefore dispatch before the ordinary arg loop. Generic
    // runtime functions still need the lowered values and dispatch afterward.
    // The identity-bearing name keeps same-spelled pack monos from two modules
    // distinct; comptime lowering consumes the exact declaration directly.
    if (qualified_author) |sf| {
        if (isPackFn(sf.decl))
            return self.lowerPackFnCallNamed(sf.decl, selectedDispatchName(self, sf), c, null);
        if (hasComptimeParams(sf.decl))
            return self.lowerComptimeCall(sf.decl, c);
    }

    // Selected static plain-struct pack/comptime methods must dispatch before
    // ordinary argument lowering: both specialized lowerers consume and lower
    // the AST arguments themselves. Reaching the later namespace/static arm
    // after the loop below would evaluate every argument twice. The same rule
    // applies to the target-typed `.method(...)` shorthand.
    const early_static_method: ?Lowering.PlainStructMethod = switch (c.callee.data) {
        .field_access => |fa| if (qualified_author == null and qualified_call_verdict == .type_prefix) blk: {
            break :blk switch (self.staticStructHead(fa.object)) {
                .resolved => |owner_ty| self.plainStructMethod(owner_ty, fa.field),
                .ambiguous, .not_visible, .none => null,
            };
        } else null,
        .enum_literal => |el| if (self.target_type) |tgt| self.plainStructMethod(tgt, el.name) else null,
        else => null,
    };
    if (early_static_method) |method| {
        if (isPackFn(method.fd)) return self.lowerPackFnCallNamed(method.fd, self.plainStructMethodName(method), c, null);
        if (hasComptimeParams(method.fd))
            return lowerComptimePlainStructMethod(self, method, null, c.args, c.callee.span);
    }

    // Instance pack/comptime methods also own AST argument evaluation. Select
    // the nominal author before the ordinary arg loop and splice the receiver
    // into pack calls so declaration positions line up with `self`.
    if (qualified_author == null and qualified_call_verdict == .value_receiver and c.callee.data == .field_access) {
        const fa = c.callee.data.field_access;
        {
            const recv_ty = self.inferExprType(fa.object);
            if (self.plainStructMethod(recv_ty, fa.field)) |method| {
                if (isPackFn(method.fd)) {
                    const eff_args = self.alloc.alloc(*Node, c.args.len + 1) catch return Ref.none;
                    eff_args[0] = @constCast(fa.object);
                    @memcpy(eff_args[1..], c.args);
                    const syn_call = ast.Call{ .callee = c.callee, .args = eff_args };
                    return self.lowerPackFnCallNamed(method.fd, self.plainStructMethodName(method), &syn_call, fa.object);
                }
                if (hasComptimeParams(method.fd))
                    return lowerComptimePlainStructMethod(self, method, fa.object, c.args, c.callee.span);
            }
            // Generic-struct instances carry a separate author stamp and are
            // intentionally absent from plainStructMethod. Select their
            // comptime methods here too, before the ordinary argument loop,
            // otherwise every runtime argument is evaluated once here and a
            // second time by the inline helper below.
            if (self.getStructTypeName(recv_ty)) |inst_name| {
                if (self.genericInstanceMethod(inst_name, fa.field)) |gm| {
                    if (hasComptimeParams(gm.fd))
                        return self.lowerComptimeGenericInstanceMethod(gm, fa.object, c.args, c.callee.span);
                }
            }
        }
    }

    // `value.write(dest)` on an `@Init(T)` owns its own argument, and must be
    // decided before any name-keyed path: `write` is a common free / UFCS
    // function name, and the recipe's own operation wins over all of them.
    if (c.callee.data == .field_access) {
        const fa = c.callee.data.field_access;
        if (std.mem.eql(u8, fa.field, init_plan.write_method)) {
            if (self.initTargetOf(self.inferExprType(fa.object))) |target|
                return self.lowerInitWrite(target, fa.object, c.args, c.callee.span);
        }
        // `value.site()` — the initializer's own provenance, baked per formation
        // site. Decided here for the same reason `write` is.
        if (std.mem.eql(u8, fa.field, init_plan.site_method)) {
            const recv_ty = self.inferExprType(fa.object);
            if (self.initTargetOf(recv_ty) != null)
                return self.lowerInitSite(recv_ty, c.args, c.callee.span);
        }
        // `content.run(*sink)` / `content.shape()` / `content.site()` — the
        // build-block operations, decided on the receiver's TYPE before any
        // name-keyed path, exactly as `write` is: the body they replay belongs to
        // the block's formation site, not to any declaration.
        {
            const recv_ty = self.inferExprType(fa.object);
            if (self.module.types.blockSite(recv_ty) != null) {
                if (std.mem.eql(u8, fa.field, build_block.run_method)) {
                    return self.lowerBuildBlockRun(fa.object, recv_ty, c.args, c.callee.span);
                }
                if (std.mem.eql(u8, fa.field, build_block.shape_method)) {
                    return self.lowerBuildBlockShape(recv_ty, c.args, c.callee.span);
                }
                if (std.mem.eql(u8, fa.field, build_block.site_method)) {
                    return self.lowerBuildBlockSite(recv_ty, c.args, c.callee.span);
                }
                if (self.diagnostics) |d| {
                    const id = d.addFmtId(.err, c.callee.span, "'{s}' has no '{s}' — a build block's operations are '.{s}(sink)', '.{s}()', and '.{s}()'", .{ self.formatTypeName(recv_ty), fa.field, build_block.run_method, build_block.shape_method, build_block.site_method });
                    d.addHelpFmt(id, c.callee.span, null, "the block's own body is what it carries; nothing else reads it", .{});
                }
                return Ref.none;
            }
        }

        // A ufcs function whose FIRST parameter is DESTINATION-FIRST — bounded by
        // `@Init(T)` — never takes an evaluated receiver: that parameter wants the
        // expression, not its value (§5.2). The receiver IS that first argument, so
        // the call is the ordinary spelling of itself and lowers as one. Decided
        // HERE, before the receiver or any argument is lowered, because evaluating
        // them at the boundary is precisely what the parameter forbids.
        // ...and only when the callee is a VALUE-receiver dot-call. A type prefix
        // (`Box.emit(3)`) or a namespace path (`lib.emit(6)`) is a qualified name
        // whose left side is not an argument at all — the qualified branch owns
        // those. `.never_qualified` is admitted with `.value_receiver`: a receiver
        // that is an expression rather than a name (`Label{ … }.emit()`) never had
        // a qualified reading to consider.
        const value_receiver_call = switch (qualified_call_verdict) {
            .never_qualified, .value_receiver => true,
            .type_prefix, .func, .callable_value, .non_callable, .missing, .not_visible, .ambiguous => false,
        };
        if (value_receiver_call and !author_declines) {
            if (destinationFirstUfcs(self, &fa, c.args)) |target| {
                const args = self.expandSpreadArgNodes(c.args) orelse c.args;
                if (self.checkCallArity(target.fd, fa.field, args.len + 1, true, c.callee.span)) return Ref.none;
                const syn_args = self.alloc.alloc(*Node, args.len + 1) catch unreachable;
                syn_args[0] = @constCast(fa.object);
                @memcpy(syn_args[1..], args);
                const callee = self.synthNode(.{ .identifier = .{ .name = target.name } }, c.callee.span, c.callee.source_file);
                self.respelled_ufcs_callees.put(self.alloc, callee, {}) catch {};
                const syn_call = ast.Call{ .callee = callee, .args = syn_args };
                return self.lowerCall(&syn_call);
            }
        }
    }

    // Lower args (with target type propagation for xx conversions)
    var args = std.ArrayList(Ref).empty;
    defer args.deinit(self.alloc);
    // Try to resolve param types for target_type context
    const param_types = self.resolveCallParamTypes(c, sel_author, qualified_author != null, if (qualified_callable) |cv| cv.global else null, author_declines);
    // For enum_literal callees (.Variant(payload)), resolve the payload target type
    // from the union field type so struct literal fields get proper coercion.
    // Resolve through optional layers — a `?E` destination constructs the E
    // and wraps at the coercion site.
    var enum_payload_ty: ?TypeId = null;
    if (c.callee.data == .enum_literal) {
        var target = self.target_type orelse .unresolved;
        while (!target.isBuiltin()) {
            const info = self.module.types.get(target);
            if (info == .tagged_union) {
                const tag = self.resolveVariantIndex(target, c.callee.data.enum_literal.name);
                if (tag < info.tagged_union.fields.len) {
                    enum_payload_ty = info.tagged_union.fields[tag].ty;
                }
                break;
            }
            if (info != .optional) break;
            target = info.optional.child;
        }
    }
    // Running PARAMETER index: a spread expands one
    // AST arg into N lowered args, so the AST loop index stops matching the
    // callee's parameter positions after any spread. `param_idx` advances by
    // the EXPANDED width, so every post-spread arg is target-typed / coerced
    // against its true parameter — indexing `param_types` by the raw AST
    // index typed `f(..pair, null)`'s `null` against the wrong param (a
    // present-zero optional instead of none).
    var param_idx: usize = 0;
    for (c.args) |arg| {
        if (arg.data == .spread_expr) {
            // Pack spread `..xs` / `..xs.method` → expand to N positional
            // args here. A runtime-slice spread (`..arr`) is left as a
            // placeholder for the slice-variadic path (packVariadicCallArgs).
            if (self.packSpreadRefs(arg.data.spread_expr.operand, arg.span)) |elems| {
                defer self.alloc.free(elems);
                for (elems) |e| args.append(self.alloc, e) catch unreachable;
                param_idx += elems.len;
                continue;
            }
            // Value spread (specs.md §"Tuple parallels"): `..t` on a concrete
            // TUPLE expands to its elements — this is how a materialized pack
            // `.(..xs)` is re-spread. A fixed ARRAY expands the same way, but
            // only when the callee provably has no slice-variadic param:
            // `sum(..arr)` into `..xs: []T` passes the WHOLE array as the
            // slice (the packVariadicCallArgs fast path), which stays as the
            // placeholder below.
            expand: {
                const op_ty = self.inferExprType(arg.data.spread_expr.operand);
                if (op_ty.isBuiltin()) break :expand;
                const op_info = self.module.types.get(op_ty);
                // A STRUCT value spreads field-wise like a tuple — the
                // materialized-pack carrier is an anonymous positional
                // struct (`stored := .{ ..xs };` → `f(..stored)`).
                if (op_info != .array and op_info != .@"struct") break :expand;
                if (op_info == .array and calleeMayHaveVariadicParam(self, c, sel_author, if (qualified_callable) |cv| cv.global else null)) break :expand;
                if (self.valueSpreadRefs(arg.data.spread_expr.operand, arg.span)) |elems| {
                    defer self.alloc.free(elems);
                    for (elems) |e| args.append(self.alloc, e) catch unreachable;
                    param_idx += elems.len;
                    continue;
                }
            }
            args.append(self.alloc, Ref.none) catch unreachable;
            param_idx += 1;
            continue;
        }
        // Every non-spread arg consumes exactly one parameter slot — on every
        // exit from this iteration (all the `continue`s below included).
        defer param_idx += 1;
        const ai = param_idx;
        // Beyond the declared parameters the ambient target stands — a
        // C-variadic tail types from it — and no signature rides with it.
        var dem = self.enterDemand(if (ai < param_types.len) param_types[ai] else null);
        defer dem.restore();
        const pt: ?TypeId = if (ai < param_types.len) param_types[ai].coerceType() else null;
        // `cast(T) X` — lower an integer-literal operand against the cast's
        // target type T: otherwise the literal folds against the
        // ambient default `i64` and a value above i64.max but within a wider
        // target (`cast(u64) 0xcbf...`) trips the i64 fits-check before the
        // cast ever applies — AND a same-width signed↔unsigned reinterpret
        // (`i64 → u64`) is classified `.none`, passing the operand through with
        // its SOURCE type so a `:=`-inferred result mis-formats as signed.
        // Emitting the literal directly as T fixes both (the value is masked to
        if (enum_payload_ty) |ept| {
            if (ai == 0) self.target_type = ept;
        }
        // A `$I/@Init(T)` parameter is destination-first (spec §5.2): the
        // argument is NOT evaluated at the call boundary. Form the recipe and
        // pass it; the callee decides when — and whether — the expression runs.
        // This precedes every value-shaped arm below, all of which would evaluate.
        if (pt) |ptv| {
            if (self.initTargetOf(ptv)) |target| {
                args.append(self.alloc, self.formInitPlan(arg, target)) catch unreachable;
                continue;
            }
            // A `$B/@BuildBlock(P)` parameter takes the trailing block's body
            // (§6.2 rule 1) or a block already formed (rule 2). Neither is an
            // ordinary value, so this precedes every value-shaped arm below.
            if (self.blockProtocolOf(ptv)) |protocol| {
                args.append(self.alloc, self.formBuildBlock(arg, protocol)) catch unreachable;
                continue;
            }
            // A `@VaList` parameter is the C boundary: the argument names a
            // live list and its PLACE crosses. Precedes every value-shaped arm
            // below — a cursor has no value form for them to read.
            if (self.boundaryCursorArg(arg, ptv)) |r| {
                args.append(self.alloc, r) catch unreachable;
                continue;
            }
        }
        // Implicit float→int narrowing of a compile-time float argument
        // (incl. an expanded `param: T = expr` default) follows the unified
        // rule: an integral comptime float folds, a non-integral one errors.
        // A runtime float / `xx` cast is unaffected and coerces as before.
        if (pt) |ptv| {
            if (self.foldComptimeFloatInit(arg, ptv)) |folded| {
                args.append(self.alloc, folded) catch unreachable;
                continue;
            }
        }
        // Implicit address-of: when param expects *T and arg is an identifier
        // with an alloca of type T, pass the alloca pointer directly (reference
        // semantics, so mutations through the pointer are visible to the caller).
        if (pt != null and arg.data == .identifier) {
            const ptv = pt.?;
            if (!ptv.isBuiltin()) {
                const pti = self.module.types.get(ptv);
                if (pti == .pointer) {
                    const nm = arg.data.identifier.name;
                    const local = if (self.scope) |scope| scope.lookup(nm) else null;
                    if (local) |binding| {
                        // Only apply when the binding type matches the pointee type
                        if (binding.is_alloca and binding.ty == pti.pointer.pointee) {
                            const ptr_ty = self.module.types.ptrTo(binding.ty);
                            args.append(self.alloc, self.builder.emit(.{ .addr_of = .{ .operand = binding.ref } }, ptr_ty)) catch unreachable;
                            continue;
                        }
                    } else if (self.resolveGlobalRef(nm, null)) |gi| {
                        // MUTABLE global arg to a `*T` param: pass the global's
                        // LIVE address (`global_addr` via lowerExprAsPtr), not a
                        // loaded copy the callee would mutate in vain — the
                        // explicit-call sibling of the UFCS-receiver rule.
                        // A `::` const global is excluded (no `*T` into `.rodata`
                        // — would SIGBUS / slip past the const-write guard); it
                        // falls through to the value copy below.
                        if (gi.ty == pti.pointer.pointee and !self.rootIsConstant(nm)) {
                            const ptr_ty = self.module.types.ptrTo(gi.ty);
                            const place = self.lowerExprAsPtr(arg);
                            const place_ty = self.builder.getRefType(place);
                            const r = if (place_ty == ptr_ty)
                                place
                            else
                                self.builder.emit(.{ .addr_of = .{ .operand = place } }, ptr_ty);
                            args.append(self.alloc, r) catch unreachable;
                            continue;
                        }
                    }
                }
            }
        }
        // Implicit address-of for compound lvalues (field access / index /
        // deref): when the param expects `*T` and the arg is an addressable
        // lvalue of type `T`, pass the lvalue's real address (GEP) — same
        // reference semantics as the identifier case above. Without this the
        // arg would be loaded into a temporary and the callee would mutate a
        // throwaway copy (silent data loss — e.g. `make_move(self.board, m)`).
        if (pt != null and (arg.data == .field_access or arg.data == .index_expr or arg.data == .deref_expr)) {
            const ptv = pt.?;
            if (!ptv.isBuiltin()) {
                const pti = self.module.types.get(ptv);
                if (pti == .pointer and self.inferExprType(arg) == pti.pointer.pointee) {
                    // `lowerExprAsPtr` yields the lvalue's address, typed
                    // either as `*T` already (index/deref) or as the pointee
                    // `T` (a field "place" ref); normalize to `*T` — exactly
                    // what `@field_access` does.
                    const place = self.lowerExprAsPtr(arg);
                    const place_ty = self.builder.getRefType(place);
                    const ref: ?Ref = if (place_ty == ptv)
                        place
                    else if (place_ty == pti.pointer.pointee)
                        self.builder.emit(.{ .addr_of = .{ .operand = place } }, ptv)
                    else
                        null;
                    if (ref) |r| {
                        args.append(self.alloc, r) catch unreachable;
                        continue;
                    }
                }
            }
        }
        // Concrete lvalue → interface param: erase NODE-AWARE so the lvalue
        // BORROWS (`free(t, gpa)` aliases gpa) — the node-less coerceCallArgs
        // layer would misread the lvalue as an rvalue and refuse.
        if (pt) |ptv| {
            if (protocolArgErasure(self, arg, ptv)) |r| {
                args.append(self.alloc, r) catch unreachable;
                continue;
            }
        }
        // Concrete lvalue → `*Protocol` param: the borrowed-VIEW coercion
        // (erasure model). Take the lvalue's REAL address,
        // build the borrow-mode protocol value around it (ctx = that address,
        // so mutations through the view reach the original), spill the value
        // to a frame slot and pass the slot's address. Mirrors the implicit
        // address-of arms above; rvalue args never reach here (no lvalue
        // shape) and are refused at the node-less layer (coerceCallArgs).
        if (pt != null and (arg.data == .identifier or arg.data == .field_access or
            arg.data == .index_expr or arg.data == .deref_expr))
        {
            const ptv = pt.?;
            if (!ptv.isBuiltin()) {
                const pti = self.module.types.get(ptv);
                if (pti == .pointer and self.getProtocolInfo(pti.pointer.pointee) != null) {
                    const cty = self.inferExprType(arg);
                    if (cty != .unresolved and !cty.isBuiltin() and cty != pti.pointer.pointee and
                        self.getProtocolInfo(cty) == null and self.module.types.get(cty) == .@"struct")
                    {
                        const place = self.lowerExprAsPtr(arg);
                        const place_ty = self.builder.getRefType(place);
                        const addr = if (place_ty == cty)
                            self.builder.emit(.{ .addr_of = .{ .operand = place } }, self.module.types.ptrTo(cty))
                        else
                            place;
                        if (self.viewOfConcreteAddr(addr, cty, ptv)) |v| {
                            args.append(self.alloc, v) catch unreachable;
                            continue;
                        }
                    }
                }
            }
        }
        // An argument is a VALUE position: a block-form `if C { A } else { B }`
        // / `match` used directly as an argument must yield its branch value,
        // not be lowered as a statement-if (which returns a bare `void 0` and
        // silently passes `0`, or overruns for a wider branch type → segfault).
        // The `then`-form and a `let`-bound local already work
        // because both reach `lowerIfExpr` with `force_block_value` set; a bare
        // call argument did not. Set it here so the arg materializes its value.
        const saved_fbv = self.force_block_value;
        self.force_block_value = true;
        const val = self.lowerExpr(arg);
        self.force_block_value = saved_fbv;
        // Passing a `*T` where a `T` value is expected — a by-reference loop
        // capture (`for *m in xs`), a `*T` parameter, or any pointer local —
        // otherwise slips through to LLVM as an opaque "call parameter type
        // does not match function signature" verifier error. Flag it at the
        // call site with a `.*` fix-it.
        if (pt) |ptv| {
            const vt = self.builder.getRefType(val);
            const vti = self.module.types.get(vt);
            if (vti == .pointer and vti.pointer.pointee == ptv) {
                if (self.diagnostics) |d| {
                    const tn = self.formatTypeName(ptv);
                    if (arg.data == .identifier) {
                        const nm = arg.data.identifier.name;
                        const lead: []const u8 = if (self.refCapturePointee(arg) != null) "by-reference loop capture" else "argument";
                        const fix = std.fmt.allocPrint(self.alloc, "{s}.*", .{nm}) catch nm;
                        const pid = d.addFmtId(.err, arg.span, "{s} '{s}' has type '*{s}', but '{s}' is expected here", .{ lead, nm, tn, tn });
                        d.addHelpFmt(pid, arg.span, fix, "dereference it to pass the value: `{s}`", .{fix});
                    } else {
                        const pid = d.addFmtId(.err, arg.span, "this argument has type '*{s}', but '{s}' is expected here", .{ tn, tn });
                        d.addHelpFmt(pid, arg.span, null, "dereference it with `.*` to pass the value", .{});
                    }
                }
            }
        }
        args.append(self.alloc, val) catch unreachable;
    }

    switch (c.callee.data) {
        .identifier => |id| {
            // Resolve local function name (bare → mangled) and UFCS aliases
            const func_name = blk: {
                // First try scope lookup for mangled local fn names
                const scoped = if (self.scope) |scope| scope.lookupFn(id.name) orelse id.name else id.name;
                // Then try UFCS alias on bare name
                if (self.ufcsAliasTarget(id.name)) |target| {
                    // Resolve the alias target through scope too (target may be mangled)
                    break :blk if (self.scope) |scope| scope.lookupFn(target) orelse target else target;
                }
                break :blk scoped;
            };

            // Check builtins first (these are handled natively by interpreter and emitter)
            if (resolveBuiltin(id.name)) |bid| {
                const ret_ty: TypeId = switch (bid) {
                    .size_of, .align_of => .i64,
                    .sqrt, .sin, .cos, .floor => blk: {
                        // Math builtins: return type matches argument type ($T -> T)
                        if (c.args.len > 0) {
                            const arg_ty = self.inferExprType(c.args[0]);
                            if (arg_ty == .f32) break :blk TypeId.f32;
                        }
                        break :blk TypeId.f64;
                    },
                    else => .void,
                };
                return self.builder.callBuiltin(bid, args.items, ret_ty);
            }
            // Check scope first: local variables (closures, fn ptrs) shadow
            // global functions. NEAREST-scope resolution across BOTH local
            // namespaces (value bindings AND nested local fn decls):
            // whichever is declared at the inner level wins — an outer
            // callable var must not hijack an inner nested fn, nor vice
            // versa (specs §Variable Shadowing).
            if (self.scope) |scope| {
                if (scope.lookupNearestBoundary(id.name)) |nb| switch (nb.near) {
                    // A nested local fn is nearest: the mangled `func_name`
                    // direct dispatch below owns the call. Legal even across a
                    // nested-fn boundary — siblings are static.
                    .local_fn => {},
                    .binding => |binding| {
                        if (!binding.ty.isBuiltin()) {
                            const ty_info = self.module.types.get(binding.ty);
                            // A callable binding (closure value / fn pointer)
                            // reached only ACROSS a nested-fn boundary is the
                            // enclosing function's local — dispatching through
                            // it reads a dead env/fn Ref (Bus error).
                            // Diagnose for BOTH closure and fn-pointer
                            // shapes — even a non-capturing closure that would
                            // happen to run must not silently legitimize the
                            // reference. A NON-callable crossed binding falls
                            // through unused: the enclosing local is invisible
                            // to a static nested fn, so the name correctly
                            // resolves to the module-scope callable below.
                            if (nb.crossed != .none and (ty_info == .closure or ty_info == .function or
                                self.uniqueLambdaThrough(binding.ty) != null or self.callableNominalThrough(binding.ty) != null))
                            {
                                _ = self.diagEnclosingLocalRef(id.name, c.callee.span, nb.crossed);
                                return Ref.none;
                            }
                            // A callable local shadows any same-named top-level
                            // fn: dispatch through the LOCAL before the author /
                            // name-based program-fn paths below, otherwise an
                            // importer's unrelated module-scope fn hijacks the
                            // call. A fn-pointer-typed pack-element alias is
                            // excluded — the substitution path owns it.
                            if (self.callableShapeOf(binding.ty)) |shape| {
                                if (shape != .fn_ptr or binding.pack_elem == null) {
                                    if (callValue(self, .{
                                        .ty = binding.ty,
                                        .ref = if (binding.is_alloca) Ref.none else binding.ref,
                                        .addr = if (binding.is_alloca) binding.ref else null,
                                        .node = c.callee,
                                        .name = id.name,
                                        .origin = .{ .local = binding },
                                    }, c, args.items, c.callee.span)) |r| return r;
                                }
                            }
                        }
                    },
                };
            }
            // A genuine flat same-name collision — bind the
            // author the call resolver selected (own-author-wins, or the single
            // flat-reachable author), or reject a bare call to a name ≥2
            // imported modules author. `selectedFreeAuthor` (computed once
            // above, and the exact verdict `plan` consumes for typing) is the
            // single producer; lowering CONSUMES it rather than re-resolving
            // the name, so typing and dispatch read the SAME author and can't
            // disagree. Reached only for an identifier callee, so
            // `sel_author` / `author_ambiguous` here are the bare verdict.
            if (author_ambiguous) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, c.callee.span, "'{s}' is ambiguous; declared by multiple imported modules — qualify the call", .{func_name});
                return Ref.none;
            }
            // `args.items` is the post-expansion count: trailing defaults
            // were filled by `expandCallDefaults`, comptime-pack spreads
            // expanded element-wise above.
            {
                const arity_fd: ?*const ast.FnDecl = if (sel_author) |sf|
                    sf.decl
                else if (author_not_callable)
                    null
                else
                    self.program_index.fn_ast_map.get(func_name);
                if (arity_fd) |fd| {
                    // A leftover slice/array-spread placeholder into a callee
                    // with NO variadic slot to consume it: diagnose the spread
                    // itself — an arity error alone counts the
                    // placeholder as one arg, and a count that happens to line
                    // up emits undef for the slot.
                    if (!fnDeclHasVariadicParam(fd)) {
                        var buf: [160]u8 = undefined;
                        const what = std.fmt.bufPrint(&buf, "'{s}'", .{id.name}) catch id.name;
                        if (rejectLeftoverSpreadPlaceholder(self, what, args.items, c, c.callee.span)) return Ref.none;
                    }
                    if (self.checkCallArity(fd, id.name, args.items.len, false, c.callee.span)) return Ref.none;
                }
            }
            if (sel_author) |sf| {
                const fid = self.selectedFuncId(sf);
                const func = &self.module.functions.items[@intFromEnum(fid)];
                const ret_ty = func.ret;
                const params = func.params;
                // The RESOLVED author's decl drives variadic packing — not a
                // first-wins re-lookup by name, whose variadic shape may
                // differ.
                self.packVariadicCallArgs(sf.decl, c, &args);
                const final_args = self.prependCtxIfNeeded(func, args.items);
                self.coerceCallArgs(final_args, params);
                if (func.is_c_variadic) self.promoteCVariadicArgs(final_args, params.len);
                return self.builder.call(fid, final_args, ret_ty);
            }
            // A value-authored name has no callable declaration here, so the
            // name-keyed map does not answer for it.
            const named_fd: ?*const ast.FnDecl = if (author_not_callable) null else self.program_index.fn_ast_map.get(func_name);
            // Check for comptime-expanded or generic functions
            if (named_fd) |fd| {
                if (hasComptimeParams(fd)) {
                    return self.lowerComptimeCall(fd, c);
                }
                if (fd.type_params.len > 0) {
                    // Runtime dispatch already handled above (before arg lowering)
                    return self.lowerGenericCall(fd, func_name, c, args.items);
                }
            }
            // Look up declared/extern function — try lazy lowering if not yet lowered
            if (!author_not_callable) {
                // First attempt: function may already be declared (from scanDecls)
                // but not yet lowered. Try lazy lowering if needed.
                if (self.program_index.fn_ast_map.contains(func_name) and !self.lowered_functions.contains(func_name)) {
                    self.lazyLowerFunction(func_name);
                }
                if (self.resolveFuncByName(func_name)) |fid| {
                    const func = &self.module.functions.items[@intFromEnum(fid)];
                    const ret_ty = func.ret;
                    const params = func.params;
                    // Pack variadic args into a slice if the function has a variadic param
                    if (self.program_index.fn_ast_map.get(func_name)) |fd| {
                        self.packVariadicCallArgs(fd, c, &args);
                    }
                    const final_args = self.prependCtxIfNeeded(func, args.items);
                    // Coerce arguments to match parameter types
                    self.coerceCallArgs(final_args, params);
                    if (func.is_c_variadic) self.promoteCVariadicArgs(final_args, params.len);
                    return self.builder.call(fid, final_args, ret_ty);
                }
            }
            // May be a variable holding a function pointer (non-closure).
            // Function-typed bindings dispatch through the program-fn paths
            // above; this trailing fallback covers every other
            // binding shape.
            if (self.scope) |scope| {
                // A binding reachable only across a nested-fn boundary is an
                // enclosing local — never a valid indirect-call target here
                // (mirrors the callable-binding gate above).
                const crossed = scope.lookupBoundary(id.name).crossed;
                if (crossed != .none) {
                    _ = self.diagEnclosingLocalRef(id.name, c.callee.span, crossed);
                    return Ref.none;
                }
                if (scope.lookup(id.name)) |binding| {
                    // No variadic slot on any binding-typed callee — a leftover
                    // slice/array spread placeholder must not reach the
                    // indirect call as undef.
                    if (rejectLeftoverSpreadPlaceholder(self, "a function pointer", args.items, c, c.callee.span)) return Ref.none;
                    return indirectCallThroughLocal(self, id.name, binding, args.items, c.callee.span);
                }
            }
            // May be a module global holding a callable value.
            if (self.resolveGlobalRef(id.name, c.callee.span)) |gi| {
                if (globalCallee(self, gi, id.name, c.callee, .bare_global)) |cv| {
                    if (callValue(self, cv, c, args.items, c.callee.span)) |r| return r;
                }
            }
            // A generic type-CONSTRUCTOR head (`List(i64)`, `ModBox(V)`)
            // parses as a call in the value grammar. Like every other type
            // literal in expression position it lowers to a first-class
            // `Type` value — which is what a `$T: Type` argument slot reads.
            if (self.isGenericTypeConstructorHead(id.name)) {
                const ty = self.resolveTypeCallWithBindings(c);
                if (ty != .unresolved) return self.builder.constType(ty);
            }
            // Unresolved function call
            return self.emitError(id.name, c.callee.span);
        },
        .field_access => |fa| {
            if (qualified_callable) |selected|
                return callThroughSelectedGlobal(self, selected, args.items, c, c.callee.span);

            // `super.method(args)` from inside a `main = true` (or any
            // sx-defined `@JniClass`) bodied method. Dispatch via
            // CallNonvirtual<T>Method against the parent class
            // resolved from the enclosing fcd's `extends =` clause.
            if (fa.object.data == .identifier and
                std.mem.eql(u8, fa.object.data.identifier.name, "super"))
            {
                return self.lowerSuperCall(fa.field, args.items, c.callee.span);
            }

            // `Alias.method(args)` where Alias is a runtime-class
            // identifier and `method` is a `static` member — JNI
            // dispatch via FindClass + GetStaticMethodID + CallStatic*,
            // OR (for `new`) via FindClass + GetMethodID("<init>") +
            // NewObject. Falls through to existing paths when no match.
            if (fa.object.data == .identifier) {
                const alias = fa.object.data.identifier.name;
                if (self.program_index.runtime_class_map.get(alias)) |fcd| {
                    for (fcd.members) |m| switch (m) {
                        .method => |md| if (md.is_static and std.mem.eql(u8, md.name, fa.field)) {
                            return self.lowerRuntimeStaticCall(fcd, md, args.items, c.callee.span);
                        },
                        else => {},
                    };
                }
            }

            // Type constructor call: Sx(f32).user(0.5) — obj is a call that returns a type
            if (fa.object.data == .call) {
                const inner_call = &fa.object.data.call;
                // Generic struct STATIC-METHOD head (`Box(i64).make(..)` or the
                // qualified `a.Box(i64).make(..)`): the layout author is chosen
                // by the single head choke-point (CP-1) and the method body by
                // the instance's STAMPED author (CP-4), so layout-author ≡
                // body-author for BOTH bare and qualified heads (#1 / #2).
                switch (self.selectGenericStructCallee(inner_call.callee, inner_call.callee.span)) {
                    .poisoned => return Ref.none,
                    .template => |t| {
                        const inst_ty = self.instantiateGenericStruct(&t, inner_call.args);
                        const inst_name = self.formatTypeName(inst_ty);
                        if (self.genericInstanceMethod(inst_name, fa.field)) |gm| {
                            if (self.ensureGenericInstanceMethodLowered(gm)) |fid| {
                                const func = &self.module.functions.items[@intFromEnum(fid)];
                                self.appendDefaultArgs(gm.fd, &args, c.callee);
                                const final_args = self.prependCtxIfNeeded(func, args.items);
                                self.coerceCallArgs(final_args, func.params);
                                return self.builder.call(fid, final_args, func.ret);
                            }
                        }
                    },
                    .not_generic => {},
                }

                if (inner_call.callee.data == .identifier) {
                    const inner_name = inner_call.callee.data.identifier.name;
                    const resolved = if (self.scope) |scope| (scope.lookupFn(inner_name) orelse inner_name) else inner_name;

                    if (self.program_index.fn_ast_map.get(resolved)) |fd| {
                        // Only a `-> Type` generic is a type constructor. A
                        // value-returning generic reaches here as an ordinary
                        // method receiver (`el(Leaf{…}).opacity(…)`), and
                        // instantiating it as a type would resolve its VALUE
                        // arguments in type position.
                        if (fd.type_params.len > 0 and self.isTypeReturningCallNode(fa.object)) {
                            if (self.headFnLeak(inner_name, inner_call.callee.span)) return Ref.none;
                            // Try instantiate as type function
                            if (self.instantiateTypeFunction(inner_name, inner_name, fd, inner_call.args)) |result_ty| {
                                const type_info = self.module.types.get(result_ty);
                                if (type_info == .tagged_union) {
                                    // Qualified enum construction: Type.variant(payload)
                                    if (!self.hasVariant(result_ty, fa.field)) {
                                        self.emitBadVariant(result_ty, type_info.tagged_union, fa.field, c.callee.span);
                                        return self.builder.enumInit(0, Ref.none, result_ty);
                                    }
                                    // ORDINAL indexes `fields[]` (payload-type
                                    // lookup); the EXPLICIT tag value is what's
                                    // stored at runtime so match/C-interop agree.
                                    const ord = self.resolveVariantIndex(result_ty, fa.field);
                                    const tag = self.resolveVariantValue(result_ty, fa.field);
                                    var payload = if (args.items.len > 0) args.items[0] else Ref.none;
                                    if (!payload.isNone()) {
                                        const fields = type_info.tagged_union.fields;
                                        if (ord < fields.len) {
                                            const field_ty = fields[ord].ty;
                                            if (field_ty != .void) {
                                                const payload_ty = self.inferExprType(c.args[0]);
                                                if (field_ty != payload_ty) {
                                                    payload = self.coerceToType(payload, payload_ty, field_ty);
                                                }
                                            }
                                        }
                                    }
                                    return self.builder.enumInit(tag, payload, result_ty);
                                }
                                if (type_info == .@"enum") {
                                    if (!self.hasVariant(result_ty, fa.field)) {
                                        self.emitBadEnumVariant(result_ty, type_info.@"enum", fa.field, c.callee.span);
                                        return self.builder.enumInit(0, Ref.none, result_ty);
                                    }
                                    const tag = self.resolveVariantIndex(result_ty, fa.field);
                                    return self.builder.enumInit(tag, Ref.none, result_ty);
                                }
                            }
                        }
                    }
                }
            }

            // Namespace-qualified call (e.g. `std.print`) vs method / UFCS
            // call on a value (`recv.method`). This boundary decides whether
            // the receiver is prepended, so it MUST agree with the call
            // plan's `free_fn_ufcs` (prepends) vs `namespace_fn` (does not)
            // classification — source it from the single definition in
            // `CallResolver` rather than re-deriving it here.
            const is_namespace = qualified_call_verdict != .value_receiver;

            if (is_namespace) {
                // Arbitrary-depth namespace function selected before defaults /
                // argument lowering. Every callable shape dispatches by this
                // declaration identity: generic monomorphs use an author-stable
                // key, sx bodies materialize the exact declaration, and
                // extern/intrinsic stubs use that declaration's registered fid.
                if (qualified_author) |sf| {
                    const fd = sf.decl;
                    if (fd.type_params.len > 0)
                        return self.lowerGenericCall(fd, selectedDispatchName(self, sf), c, args.items);
                    if (self.checkCallArity(fd, fd.name, args.items.len, false, c.callee.span)) return Ref.none;
                    const fid: FuncId = if (fd.extern_export == .extern_ or fd.body.data == .intrinsic_expr)
                        self.fn_decl_fids.get(fd) orelse declared: {
                            const saved_source = self.current_source_file;
                            self.setCurrentSourceFile(sf.source);
                            self.declareFunction(fd, fd.name);
                            self.setCurrentSourceFile(saved_source);
                            break :declared self.fn_decl_fids.get(fd) orelse return self.emitError(fd.name, c.callee.span);
                        }
                    else
                        self.selectedFuncId(sf);
                    const func = &self.module.functions.items[@intFromEnum(fid)];
                    self.packVariadicCallArgs(fd, c, &args);
                    const final_args = self.prependCtxIfNeeded(func, args.items);
                    self.coerceCallArgs(final_args, func.params);
                    if (func.is_c_variadic) self.promoteCVariadicArgs(final_args, func.params.len);
                    return self.builder.call(fid, final_args, func.ret);
                }

                // A static method on a plain struct is selected from the
                // nominal type head's author, not the global last-wins
                // `StructName.method` entry. This precedes
                // namespace-name stripping so `a.Thing.init()` retains a's
                // TypeId and body provenance end to end.
                switch (self.staticStructHead(fa.object)) {
                    .resolved => |owner_ty| {
                        if (self.plainStructMethod(owner_ty, fa.field)) |method| {
                            const fd = method.fd;
                            const dispatch_name = self.plainStructMethodName(method);
                            if (isPackFn(fd)) return self.lowerPackFnCallNamed(fd, dispatch_name, c, null);
                            if (hasComptimeParams(fd))
                                return lowerComptimePlainStructMethod(self, method, null, c.args, c.callee.span);
                            if (fd.type_params.len > 0) return self.lowerGenericCall(fd, dispatch_name, c, args.items);
                            if (self.checkCallArity(fd, dispatch_name, args.items.len, false, c.callee.span)) return Ref.none;
                            self.appendDefaultArgs(fd, &args, c.callee);
                            const fid = self.ensurePlainStructMethodLowered(method);
                            const func = &self.module.functions.items[@intFromEnum(fid)];
                            const ret_ty = func.ret;
                            const params = func.params;
                            const has_ctx = func.has_implicit_ctx;
                            const is_c_variadic = func.is_c_variadic;
                            self.packVariadicCallArgs(fd, c, &args);
                            const final_args = blk: {
                                if (!has_ctx) break :blk args.items;
                                const new_args = self.alloc.alloc(Ref, args.items.len + 1) catch break :blk args.items;
                                new_args[0] = self.current_ctx_ref;
                                @memcpy(new_args[1..], args.items);
                                break :blk new_args;
                            };
                            self.coerceCallArgs(final_args, params);
                            if (is_c_variadic) self.promoteCVariadicArgs(final_args, params.len);
                            return self.builder.call(fid, final_args, ret_ty);
                        }
                        if (self.hasPlainStructAuthor(owner_ty))
                            return self.emitError(fa.field, c.callee.span);
                    },
                    .ambiguous => {
                        if (self.diagnostics) |d| {
                            if (fa.object.data == .field_access and fa.object.data.field_access.object.data == .identifier) {
                                const alias = fa.object.data.field_access.object.data.identifier.name;
                                d.addFmt(.err, fa.object.span, "namespace '{s}' is ambiguous: aliases from multiple flat-imported modules point at different targets; declare the alias locally", .{alias});
                            } else {
                                const head = self.qualifiedTypeName(fa.object) orelse "<type>";
                                d.addFmt(.err, fa.object.span, "type '{s}' is ambiguous: it is declared in multiple flat-imported modules; qualify the reference or remove the duplicate import", .{head});
                            }
                        }
                        return Ref.none;
                    },
                    .not_visible => {
                        if (self.diagnostics) |d| {
                            const head = self.qualifiedTypeName(fa.object) orelse "<type>";
                            d.addFmt(.err, fa.object.span, "type '{s}' is not visible; @import the module that declares it", .{head});
                        }
                        return Ref.none;
                    },
                    .none => {},
                }

                // Namespace call: module.func(args) — don't prepend object
                const func_name = fa.field;
                // Also try qualified name: Namespace.method (for struct methods)
                const ns_name: ?[]const u8 = switch (fa.object.data) {
                    .identifier => |id| id.name,
                    .type_expr => |te| te.name,
                    // `alias.Type.method()` — strip the alias so the existing
                    // `Type.method` qualified machinery resolves the static.
                    .field_access => self.namespaceRootedMember(fa.object),
                    else => null,
                };
                const qualified_name = if (ns_name) |n|
                    std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ n, fa.field }) catch func_name
                else
                    func_name;
                // The carry gate: a plain-identifier root that is
                // a namespace ALIAS (not a type / fn global name — those are
                // the `Type.method` paths below) must be visible under the
                // carry rule, and its fn members dispatch pinned to the
                // alias's TARGET module — never the global first-wins
                // qualified registration, never the last-wins bare fallback.
                gate: {
                    // A qualified call which selected an exact author above has
                    // already returned and must never be re-selected through
                    // this one-segment gate.
                    if (qualified_author != null) break :gate;
                    if (fa.object.data != .identifier) break :gate;
                    const oname = fa.object.data.identifier.name;
                    if (self.identifierBindsVisibleValue(oname)) break :gate;
                    switch (self.namespaceAliasVerdict(oname)) {
                        .target => |target| {
                            const fd = self.namespaceFnMember(&target, fa.field) orelse {
                                if (self.diagnostics) |d|
                                    d.addFmt(.err, c.callee.span, "namespace '{s}' has no member '{s}'", .{ oname, fa.field });
                                return Ref.none;
                            };
                            // Extern / builtin / #compiler bodies keep their
                            // literal global symbol — the existing bare-name
                            // machinery below resolves them.
                            switch (fd.body.data) {
                                .intrinsic_expr => break :gate,
                                else => {},
                            }
                            if (hasComptimeParams(fd)) return self.lowerComptimeCall(fd, c);
                            if (fd.type_params.len > 0) return self.lowerGenericCall(fd, fa.field, c, args.items);
                            if (self.checkCallArity(fd, fa.field, args.items.len, false, c.callee.span)) return Ref.none;
                            var sf = SelectedFunc{ .decl = fd, .source = target.target_module_path };
                            const fid = self.selectedFuncId(&sf);
                            const func = &self.module.functions.items[@intFromEnum(fid)];
                            self.packVariadicCallArgs(fd, c, &args);
                            const final_args = self.prependCtxIfNeeded(func, args.items);
                            self.coerceCallArgs(final_args, func.params);
                            if (func.is_c_variadic) self.promoteCVariadicArgs(final_args, func.params.len);
                            return self.builder.call(fid, final_args, func.ret);
                        },
                        .ambiguous => {
                            if (self.diagnostics) |d|
                                d.addFmt(.err, fa.object.span, "namespace '{s}' is ambiguous: aliases from multiple flat-imported modules point at different targets; declare the alias locally", .{oname});
                            return Ref.none;
                        },
                        .none => {
                            if (self.aliasDeclaredAnywhere(oname)) {
                                if (self.diagnostics) |d|
                                    d.addFmt(.err, fa.object.span, "namespace '{s}' is not visible; @import the module that declares it", .{oname});
                                return Ref.none;
                            }
                        },
                    }
                }
                // Check for comptime-expanded or generic functions (try both names)
                const effective_name = if (self.program_index.fn_ast_map.get(qualified_name) != null) qualified_name else func_name;
                if (self.program_index.fn_ast_map.get(effective_name)) |fd| {
                    if (hasComptimeParams(fd)) {
                        return self.lowerComptimeCall(fd, c);
                    }
                    if (fd.type_params.len > 0) {
                        return self.lowerGenericCall(fd, effective_name, c, args.items);
                    }
                }
                if (self.program_index.fn_ast_map.contains(effective_name) and !self.lowered_functions.contains(effective_name)) {
                    self.lazyLowerFunction(effective_name);
                }
                if (self.resolveFuncByName(effective_name)) |fid| {
                    const func = &self.module.functions.items[@intFromEnum(fid)];
                    const ret_ty = func.ret;
                    const params = func.params;
                    if (self.program_index.fn_ast_map.get(effective_name)) |fd| {
                        if (self.checkCallArity(fd, effective_name, args.items.len, false, c.callee.span)) return Ref.none;
                        self.packVariadicCallArgs(fd, c, &args);
                    }
                    const final_args = self.prependCtxIfNeeded(func, args.items);
                    self.coerceCallArgs(final_args, params);
                    if (func.is_c_variadic) self.promoteCVariadicArgs(final_args, params.len);
                    return self.builder.call(fid, final_args, ret_ty);
                }
                // Check if this is Type.variant(payload) — qualified enum construction
                if (ns_name) |type_name| {
                    const type_name_id = self.module.types.internString(type_name);
                    if (self.module.types.findByName(type_name_id)) |union_ty| {
                        const type_info = self.module.types.get(union_ty);
                        if (type_info == .tagged_union) {
                            if (!self.hasVariant(union_ty, func_name)) {
                                self.emitBadVariant(union_ty, type_info.tagged_union, func_name, c.callee.span);
                                return self.builder.enumInit(0, Ref.none, union_ty);
                            }
                            // ORDINAL indexes `fields[]`; the EXPLICIT tag value
                            // is stored at runtime.
                            const ord = self.resolveVariantIndex(union_ty, func_name);
                            const tag = self.resolveVariantValue(union_ty, func_name);
                            var payload = if (args.items.len > 0) args.items[0] else Ref.none;
                            // Coerce payload to match field type
                            if (!payload.isNone()) {
                                const fields = type_info.tagged_union.fields;
                                if (ord < fields.len) {
                                    const field_ty = fields[ord].ty;
                                    const payload_ty = self.inferExprType(c.args[0]);
                                    if (field_ty != payload_ty) {
                                        payload = self.coerceToType(payload, payload_ty, field_ty);
                                    }
                                }
                            }
                            return self.builder.enumInit(tag, payload, union_ty);
                        }
                        if (type_info == .@"enum") {
                            if (!self.hasVariant(union_ty, func_name)) {
                                self.emitBadEnumVariant(union_ty, type_info.@"enum", func_name, c.callee.span);
                                return self.builder.enumInit(0, Ref.none, union_ty);
                            }
                            const tag = self.resolveVariantIndex(union_ty, func_name);
                            return self.builder.enumInit(tag, Ref.none, union_ty);
                        }
                    }
                }
                return self.emitError(func_name, c.callee.span);
            }

            // Method call: obj.method(args) → prepend obj (or &obj for *Self receivers)
            // For ptr.*.method(): pass the pointer directly instead of loading + re-addressing.
            // This ensures mutations through self: *T are visible after the call.
            var obj_ty: TypeId = undefined;
            var obj: Ref = undefined;
            var effective_obj_node: *const Node = fa.object;
            if (fa.object.data == .deref_expr) {
                effective_obj_node = fa.object.data.deref_expr.operand;
                obj_ty = self.inferExprType(effective_obj_node);
                obj = self.lowerExpr(effective_obj_node);
            } else {
                obj_ty = self.inferExprType(fa.object);
                obj = self.lowerExpr(fa.object);
            }

            // A guard-narrowed optional receiver dispatches through its
            // child implicitly — parity with field reads and the
            // coercion sites.
            if (!obj_ty.isBuiltin()) {
                const oinfo_nrw = self.module.types.get(obj_ty);
                if (oinfo_nrw == .optional and self.narrowed_refs.contains(obj)) {
                    obj_ty = oinfo_nrw.optional.child;
                    obj = self.builder.emit(.{ .optional_unwrap = .{ .operand = obj } }, obj_ty);
                }
            }

            // A CALLABLE field is called as a value, not dispatched as a method.
            switch (self.lookupField(obj_ty, fa.field)) {
                .hit, .private => |h| if (self.callableShapeOf(h.ty)) |shape| {
                    if (self.mentionField(obj_ty, fa.field, c.callee.span) == .private) return Ref.none;
                    var cv: CalleeValue = .{ .ty = h.ty, .ref = Ref.none, .node = c.callee, .name = fa.field, .origin = .value };
                    switch (shape) {
                        // The field IS the receiver storage: GEP its slot from a
                        // base lowered ONCE, so the call writes the field and a
                        // side-effecting receiver is evaluated a single time.
                        .unique, .nominal => cv.addr = blk: {
                            const slot_ty = self.module.types.ptrTo(h.ty);
                            if (!obj_ty.isBuiltin()) {
                                const oi = self.module.types.get(obj_ty);
                                if (oi == .pointer)
                                    break :blk self.builder.structGepTyped(obj, h.index, slot_ty, oi.pointer.pointee);
                            }
                            const base = if (self.isLvalueExpr(c.callee))
                                self.lowerExprAsPtr(effective_obj_node)
                            else b2: {
                                const b = self.builder.alloca(obj_ty);
                                self.builder.store(b, obj);
                                break :b2 b;
                            };
                            break :blk self.builder.structGepTyped(base, h.index, slot_ty, obj_ty);
                        },
                        // A `Closure` / fn-pointer field is a plain value read.
                        // `structGet` requires an aggregate, so a `*T` receiver
                        // loads through the pointer first.
                        .closure, .fn_ptr => {
                            var agg = obj;
                            if (!obj_ty.isBuiltin()) {
                                const oi = self.module.types.get(obj_ty);
                                if (oi == .pointer) agg = self.builder.load(obj, oi.pointer.pointee);
                            }
                            cv.ref = self.builder.structGet(agg, h.index, h.ty);
                        },
                    }
                    if (callValue(self, cv, c, args.items, c.callee.span)) |r| return r;
                },
                .missing => {},
            }

            // Receiver is an OPEN SET (or a pointer to one) and the field names a
            // method the set requires: dispatch on the tag word. The arm hands the
            // member its own storage INSIDE the slot, so a method that writes
            // through `self` writes into the receiver (spec: Open Sets — dispatch).
            if (openSetReceiver(self, obj_ty)) |set_ty| {
                if (self.openSetOf(set_ty)) |set| {
                    if (lower_open_set.requiredMethod(set, fa.field)) |method| {
                        const addr = openSetReceiverAddress(self, obj, obj_ty, set_ty, fa.object);
                        return self.emitOpenSetDispatch(addr, set, method, args.items, c.callee.span);
                    }
                }
            }

            // Check if receiver is a protocol type → dispatch through
            // vtable/fn_ptrs — but only for the protocol's OWN methods. A
            // non-member field falls through to the free-fn ufcs machinery
            // (`context.allocator.create(Session)` — a ufcs fn taking the
            // protocol value as its first param).
            if (self.getProtocolInfo(obj_ty)) |proto_info| {
                if (protocolHasMethod(proto_info, fa.field)) {
                    return self.emitProtocolDispatch(obj, proto_info, fa.field, args.items, c.callee.span);
                }
            }

            // Receiver is `*Protocol` (a borrowed VIEW, erasure model): load
            // the protocol value through the pointer and dispatch as usual —
            // ctx and vtable/fn-ptr words are in the pointee.
            if (!obj_ty.isBuiltin()) {
                const oi = self.module.types.get(obj_ty);
                if (oi == .pointer) {
                    if (self.getProtocolInfo(oi.pointer.pointee)) |proto_info| {
                        if (protocolHasMethod(proto_info, fa.field)) {
                            const pv = self.builder.load(obj, oi.pointer.pointee);
                            return self.emitProtocolDispatch(pv, proto_info, fa.field, args.items, c.callee.span);
                        }
                    }
                }
            }

            // Check if receiver is `?Protocol` — for sentinel-shaped
            // optionals (Protocol has ctx as first ptr field, and a
            // null ctx is the "none" state) the unwrap is a no-op
            // structurally. Treat the optional value as the protocol
            // value and dispatch. Calling a method on a null protocol
            // is undefined (same as derefing a null pointer); user
            // guards with `if x != null` first.
            if (!obj_ty.isBuiltin()) {
                const opt_info = self.module.types.get(obj_ty);
                if (opt_info == .optional) {
                    const pay_ty = opt_info.optional.child;
                    if (self.getProtocolInfo(pay_ty)) |proto_info| {
                        if (protocolHasMethod(proto_info, fa.field)) {
                            return self.emitProtocolDispatch(obj, proto_info, fa.field, args.items, c.callee.span);
                        }
                    }
                    // `?*P` (optional VIEW): the optional of a
                    // pointer is pointer-sentinel-shaped, so the optional
                    // value IS the `*P` word — load the pointee protocol
                    // value and dispatch, same as the plain `*P` arm.
                    // Calling on null is undefined, like `?P` above.
                    if (!pay_ty.isBuiltin()) {
                        const pay_info = self.module.types.get(pay_ty);
                        if (pay_info == .pointer) {
                            if (self.getProtocolInfo(pay_info.pointer.pointee)) |proto_info| {
                                if (protocolHasMethod(proto_info, fa.field)) {
                                    const pv = self.builder.load(obj, pay_info.pointer.pointee);
                                    return self.emitProtocolDispatch(pv, proto_info, fa.field, args.items, c.callee.span);
                                }
                            }
                        }
                    }
                }
            }

            var method_args = std.ArrayList(Ref).empty;
            defer method_args.deinit(self.alloc);
            method_args.append(self.alloc, obj) catch unreachable;
            for (args.items) |a| {
                method_args.append(self.alloc, a) catch unreachable;
            }

            // Runtime-class DSL: `inst.method(args)` where `inst`'s
            // type is an alias declared by `@JniClass("...") { ... }`
            // (or its parallel forms). Routes to the JNI dispatch
            // shape, descriptor derived from the sx signature.
            const struct_name = self.getStructTypeName(obj_ty);
            if (struct_name) |sname_for_runtime| {
                if (self.program_index.runtime_class_map.get(sname_for_runtime)) |fcd| {
                    return self.lowerRuntimeMethodCall(fcd, fa.field, obj, args.items, c.callee.span);
                }
            }

            // Try to resolve the method by struct type name
            if (struct_name) |sname| {
                // Try direct qualified name: StructName.method
                const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ sname, fa.field }) catch fa.field;
                const nominal_method = self.plainStructMethod(obj_ty, fa.field);
                const nominal_author = self.hasPlainStructAuthor(obj_ty);

                // Generic-struct instance method: select the body via the
                // instance's STAMPED author (CP-4), so the dispatched method is
                // the one authored alongside this instance's layout — never the
                // global last-wins `fn_ast_map["Template.method"]`.
                if (self.genericInstanceMethod(sname, fa.field)) |gm| {
                    // A comptime method (`pick :: (self: *Box(T), $o: Ord)`) must
                    // INLINE so its `$o` binds — a plain `call` to a monomorphized
                    // FuncId would leave `o` unresolved. The struct is already
                    // monomorphized for `T`; this composes that with the
                    // comptime-value-param binding (`bindComptimeValueParams`).
                    if (hasComptimeParams(gm.fd)) {
                        return self.lowerComptimeGenericInstanceMethod(gm, effective_obj_node, c.args, c.callee.span);
                    }
                    // Binders of the method's own: monomorphize over the
                    // instance's bindings PLUS what this call's arguments bind,
                    // so one instance can answer at several argument types.
                    if (instanceMethodNeedsArgBinding(gm)) {
                        const saved_seed = self.impl_binder_seed;
                        defer self.impl_binder_seed = saved_seed;
                        self.impl_binder_seed = gm.bindings;
                        var eff_args = std.ArrayList(*const Node).empty;
                        defer eff_args.deinit(self.alloc);
                        eff_args.append(self.alloc, effective_obj_node) catch unreachable;
                        for (c.args) |a| eff_args.append(self.alloc, a) catch unreachable;
                        var gbindings = callBindings(self, gm.fd, eff_args.items, method_args.items);
                        defer gbindings.deinit();
                        const base = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ gm.inst_name, self.accessorEffName(gm.fd) }) catch fa.field;
                        const gmangled = self.genericResolver().mangleGenericName(base, gm.fd, &gbindings);
                        if (!self.lowered_functions.contains(gmangled)) {
                            self.monomorphizeFunction(gm.fd, gmangled, &gbindings);
                        }
                        if (self.resolveFuncByName(gmangled)) |fid| {
                            const func = &self.module.functions.items[@intFromEnum(fid)];
                            self.fixupMethodReceiver(&method_args, func, effective_obj_node, obj_ty, null);
                            self.appendDefaultArgs(gm.fd, &method_args, c.callee);
                            const final_args = self.prependCtxIfNeeded(func, method_args.items);
                            self.coerceCallArgs(final_args, func.params);
                            return self.builder.call(fid, final_args, func.ret);
                        }
                    }
                    if (self.ensureGenericInstanceMethodLowered(gm)) |fid| {
                        const func = &self.module.functions.items[@intFromEnum(fid)];
                        const ret_ty = func.ret;
                        const params = func.params;
                        self.fixupMethodReceiver(&method_args, func, effective_obj_node, obj_ty, null);
                        self.appendDefaultArgs(gm.fd, &method_args, c.callee);
                        const final_args = self.prependCtxIfNeeded(func, method_args.items);
                        self.coerceCallArgs(final_args, params);
                        return self.builder.call(fid, final_args, ret_ty);
                    }
                }

                // Generic method on a non-template struct: `obj.method($T, ...)`
                // or inferred form `obj.method(val)` where val's type pins $T.
                const generic_method_fd: ?*const ast.FnDecl = if (nominal_method) |m|
                    m.fd
                else if (nominal_author)
                    null
                else
                    self.program_index.fn_ast_map.get(qualified);
                if (generic_method_fd) |gen_fd| {
                    if (gen_fd.type_params.len > 0) {
                        // Effective AST args: prepend receiver so positions
                        // line up with fd.params (which has self at index 0).
                        var eff_args = std.ArrayList(*const Node).empty;
                        defer eff_args.deinit(self.alloc);
                        eff_args.append(self.alloc, effective_obj_node) catch unreachable;
                        for (c.args) |a| eff_args.append(self.alloc, a) catch unreachable;

                        var gbindings = callBindings(self, gen_fd, eff_args.items, method_args.items);
                        defer gbindings.deinit();

                        const generic_base =if (nominal_method) |m| self.plainStructMethodName(m) else qualified;
                        const gmangled = self.genericResolver().mangleGenericName(generic_base, gen_fd, &gbindings);
                        if (!self.lowered_functions.contains(gmangled)) {
                            self.monomorphizeFunction(gen_fd, gmangled, &gbindings);
                        }
                        if (self.resolveFuncByName(gmangled)) |gfid| {
                            const gfunc = &self.module.functions.items[@intFromEnum(gfid)];
                            const gret_ty = gfunc.ret;
                            const gparams = gfunc.params;
                            // Strip type-decl slots from method_args. method_args[0] is the
                            // receiver (corresponds to fd.params[0] = self, never a type decl).
                            // Walk fd.params[1..], advance arg_idx through method_args[1..].
                            var gvalue_args = std.ArrayList(Ref).empty;
                            defer gvalue_args.deinit(self.alloc);
                            gvalue_args.append(self.alloc, method_args.items[0]) catch unreachable;
                            const types_explicit = method_args.items.len == gen_fd.params.len;
                            var arg_idx: usize = 1;
                            for (gen_fd.params[1..], 1..) |p, pi| {
                                if (isTypeParamDecl(&p, gen_fd.type_params)) {
                                    if (types_explicit) arg_idx += 1;
                                    continue;
                                }
                                if (arg_idx < method_args.items.len) {
                                    gvalue_args.append(self.alloc, method_args.items[arg_idx]) catch unreachable;
                                } else {
                                    const dv = self.lowerDefaultArg(gen_fd, pi, c.callee) orelse break;
                                    gvalue_args.append(self.alloc, dv) catch unreachable;
                                }
                                arg_idx += 1;
                            }
                            self.fixupMethodReceiver(&gvalue_args, gfunc, effective_obj_node, obj_ty, null);
                            const final_args = self.prependCtxIfNeeded(gfunc, gvalue_args.items);
                            self.coerceCallArgs(final_args, gparams);
                            return self.builder.call(gfid, final_args, gret_ty);
                        }
                    }
                }

                // Non-generic plain struct method: lower the declaration into
                // its own identity-addressed FuncId. This must precede the
                // compatibility name path below; that path cannot distinguish
                // same-display-name nominal structs.
                if (nominal_method) |method| {
                    const fd = method.fd;
                    const dispatch_name = self.plainStructMethodName(method);
                    if (self.checkCallArity(fd, dispatch_name, method_args.items.len, true, c.callee.span)) return Ref.none;
                    const fid = self.ensurePlainStructMethodLowered(method);
                    const func = &self.module.functions.items[@intFromEnum(fid)];
                    const ret_ty = func.ret;
                    const params = func.params;
                    const has_ctx = func.has_implicit_ctx;
                    self.fixupMethodReceiver(&method_args, func, effective_obj_node, obj_ty, null);
                    self.appendDefaultArgs(fd, &method_args, c.callee);
                    const final_args = blk: {
                        if (!has_ctx) break :blk method_args.items;
                        const new_args = self.alloc.alloc(Ref, method_args.items.len + 1) catch break :blk method_args.items;
                        new_args[0] = self.current_ctx_ref;
                        @memcpy(new_args[1..], method_args.items);
                        break :blk new_args;
                    };
                    self.coerceCallArgs(final_args, params);
                    return self.builder.call(fid, final_args, ret_ty);
                }

                // Try non-generic qualified method
                if (!nominal_author) {
                    const plain_method_fd = self.program_index.fn_ast_map.get(qualified);
                    if (plain_method_fd) |fd| {
                        if (self.checkCallArity(fd, qualified, method_args.items.len, true, c.callee.span)) return Ref.none;
                        if (!self.lowered_functions.contains(qualified)) {
                            self.lazyLowerFunction(qualified);
                        }
                    }
                    if (self.resolveFuncByName(qualified)) |fid| {
                        const func = &self.module.functions.items[@intFromEnum(fid)];
                        const ret_ty = func.ret;
                        const params = func.params;
                        const has_ctx = func.has_implicit_ctx;
                        self.fixupMethodReceiver(&method_args, func, effective_obj_node, obj_ty, null);
                        if (plain_method_fd) |fd| self.appendDefaultArgs(fd, &method_args, c.callee);
                        // coerceCallArgs can trigger protocol thunk creation
                        // (module.addFunction), invalidating func pointer.
                        // Use pre-extracted params/ret_ty (+ has_ctx) instead of
                        // func.* after this.
                        const final_args = blk: {
                            if (!has_ctx) break :blk method_args.items;
                            const new_args = self.alloc.alloc(Ref, method_args.items.len + 1) catch break :blk method_args.items;
                            new_args[0] = self.current_ctx_ref;
                            @memcpy(new_args[1..], method_args.items);
                            break :blk new_args;
                        };
                        self.coerceCallArgs(final_args, params);
                        return self.builder.call(fid, final_args, ret_ty);
                    }
                }
            }

            // Free-function dot-call (`recv.fn(args)` → `fn(recv, args)`)
            // is OPT-IN: only a fn declared `name :: ufcs (...) {...}` or a
            // `name :: ufcs target;` alias dispatches. A plain fn is
            // callable only by direct call — a dot-call on one gets a
            // tailored diagnostic rather than silently becoming a method.
            //
            // A free-function UFCS target with a
            // genuine flat same-name collision dispatches to the author the
            // call PLAN selected for the receiver's source — the SAME author
            // plan typed the call's result as, so dispatch and typing can't
            // disagree (without this, a string-typed winner over
            // an i64 shadow boxes a raw int as a string pointer → segfault).
            // The plan is the single producer; lowering consumes its verdict
            // (`sel_author` / `cplan.ambiguous_collision`, computed once above)
            // rather than re-resolving the field name. `.ambiguous` → loud
            // diagnostic; otherwise the existing first-wins lazy path.
            const alias_target = self.ufcsAliasTarget(fa.field);
            const eff_field = alias_target orelse fa.field;
            const ufcs_fd = self.program_index.fn_ast_map.get(eff_field);
            const ufcs_opted_in = alias_target != null or (ufcs_fd != null and ufcs_fd.?.is_ufcs);

            if (ufcs_opted_in) {
                if (author_ambiguous) {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, c.callee.span, "'{s}' is ambiguous; declared by multiple imported modules — qualify the call", .{fa.field});
                    return Ref.none;
                }
                // A pack ufcs target (`worker: Closure(..) -> $R, ..$args`):
                // route through the SAME pack-call path the direct call uses,
                // with the receiver spliced in as the first arg so the pack
                // boundary, the `$R` closure-return binding, and the pack
                // expansion all line up with `fd.params[0]`.
                // `lowerPackFnCall` reads only `call_node.args` (never the
                // callee), so a synthetic spliced-args call is sufficient.
                if (ufcs_fd) |fd| {
                    if (isPackFn(fd)) {
                        // `lowerPackFnCall` only READS these nodes; the const-cast
                        // back to `*Node` (Call.args' element type) is sound.
                        var syn_args = std.ArrayList(*Node).empty;
                        defer syn_args.deinit(self.alloc);
                        syn_args.append(self.alloc, @constCast(effective_obj_node)) catch unreachable;
                        for (c.args) |a| syn_args.append(self.alloc, a) catch unreachable;
                        const syn_call = ast.Call{ .callee = c.callee, .args = syn_args.items };
                        return self.lowerPackFnCall(fd, &syn_call);
                    }
                }
                // Generic ufcs target: monomorphize with the receiver's AST
                // node prepended so bindings align with fd.params[0].
                if (ufcs_fd) |fd0| {
                    if (fd0.type_params.len > 0) {
                        var eff_args = std.ArrayList(*const Node).empty;
                        defer eff_args.deinit(self.alloc);
                        eff_args.append(self.alloc, effective_obj_node) catch unreachable;
                        for (c.args) |arg| eff_args.append(self.alloc, arg) catch unreachable;
                        // The last-wins `fn_ast_map` winner may be a
                        // same-named generic ufcs from another module whose
                        // receiver doesn't match. Only when it fails to bind all
                        // its type-params for THIS receiver do we re-select the
                        // receiver-matching author — so a working call is never
                        // perturbed, and the mismatching path either finds the
                        // right candidate or emits a clean diagnostic (never an
                        // `.unresolved` reaching codegen).
                        // Always resolve the receiver-specific author (not just
                        // on bind-failure): a fully-generic `(x: $T)` last-wins
                        // winner BINDS for any receiver, so a failure-gated
                        // re-select would silently keep it over a more specific
                        // `*Task($R)` — order-dependent dispatch. `selectUfcsGenericByReceiver`
                        // picks the most specific binder (or flags a genuine
                        // tie). Fall back to `fd0` only when it isn't enumerable
                        // in `module_decls` but still binds; diagnose otherwise
                        // (never monomorphize an `.unresolved` into LLVM).
                        var fd = fd0;
                        var amb = false;
                        if (self.selectUfcsGenericByReceiver(eff_field, eff_args.items, &amb, fd0)) |sel| {
                            fd = sel;
                        } else if (amb) {
                            if (self.diagnostics) |d|
                                d.addFmt(.err, c.callee.span, "ambiguous ufcs call '{s}': multiple overloads' receivers match — qualify the call", .{eff_field});
                            return Ref.none;
                        } else if (!self.ufcsGenericBindsAll(fd0, eff_args.items)) {
                            if (self.diagnostics) |d|
                                d.addFmt(.err, c.callee.span, "cannot infer generic type parameter for ufcs call '{s}' (no visible overload's receiver matches)", .{eff_field});
                            return Ref.none;
                        }
                        // Nothing more specific applies now: a receiver already
                        // lowered cannot reach a destination-first parameter.
                        if (refuseDestinationFirstDispatch(self, fd, fa.field, obj_ty, c.callee.span)) return Ref.none;
                        var gbindings = callBindings(self, fd, eff_args.items, method_args.items);
                        defer gbindings.deinit();
                        const gmangled = self.genericResolver().mangleGenericName(eff_field, fd, &gbindings);
                        if (!self.lowered_functions.contains(gmangled)) {
                            self.monomorphizeFunction(fd, gmangled, &gbindings);
                        }
                        if (self.resolveFuncByName(gmangled)) |gfid| {
                            const gfunc = &self.module.functions.items[@intFromEnum(gfid)];
                            const gret_ty = gfunc.ret;
                            const gparams = gfunc.params;
                            // Strip type-decl slots. method_args[0] is the
                            // receiver (a VALUE — a type-expr receiver
                            // classifies as a namespace call, never here),
                            // so fd.params[0] is a value param.
                            var gvalue_args = std.ArrayList(Ref).empty;
                            defer gvalue_args.deinit(self.alloc);
                            gvalue_args.append(self.alloc, method_args.items[0]) catch unreachable;
                            const types_explicit = method_args.items.len == fd.params.len;
                            var arg_idx: usize = 1;
                            for (fd.params[1..], 1..) |p, pi| {
                                if (isTypeParamDecl(&p, fd.type_params)) {
                                    if (types_explicit) arg_idx += 1;
                                    continue;
                                }
                                if (arg_idx < method_args.items.len) {
                                    gvalue_args.append(self.alloc, method_args.items[arg_idx]) catch unreachable;
                                } else {
                                    const dv = self.lowerDefaultArg(fd, pi, c.callee) orelse break;
                                    gvalue_args.append(self.alloc, dv) catch unreachable;
                                }
                                arg_idx += 1;
                            }
                            self.fixupMethodReceiver(&gvalue_args, gfunc, effective_obj_node, obj_ty, null);
                            const final_args = self.prependCtxIfNeeded(gfunc, gvalue_args.items);
                            self.coerceCallArgs(final_args, gparams);
                            return self.builder.call(gfid, final_args, gret_ty);
                        }
                        return self.emitError(eff_field, c.callee.span);
                    }
                }
                const ufcs_arity_fd: ?*const ast.FnDecl = if (sel_author) |sf| sf.decl else ufcs_fd;
                if (ufcs_arity_fd) |fd_df| {
                    if (refuseDestinationFirstDispatch(self, fd_df, fa.field, obj_ty, c.callee.span)) return Ref.none;
                }
                if (ufcs_arity_fd) |fd| {
                    if (self.checkCallArity(fd, fa.field, method_args.items.len, true, c.callee.span)) return Ref.none;
                }
                const ufcs_fid: ?FuncId = blk_uf: {
                    if (sel_author) |sf| {
                        break :blk_uf self.selectedFuncId(sf);
                    }
                    if (ufcs_fd != null) {
                        if (!self.lowered_functions.contains(eff_field)) {
                            self.lazyLowerFunction(eff_field);
                        }
                    }
                    break :blk_uf self.resolveFuncByName(eff_field);
                };
                if (ufcs_fid) |fid| {
                    const func = &self.module.functions.items[@intFromEnum(fid)];
                    const ret_ty = func.ret;
                    const params = func.params;
                    // Same implicit address-of as a struct-defined method: if the
                    // free function's first param is `*T` and the receiver is a
                    // value `T`, pass its address instead of a by-value copy
                    self.fixupMethodReceiver(&method_args, func, effective_obj_node, obj_ty, null);
                    if (ufcs_arity_fd) |fd| self.appendDefaultArgs(fd, &method_args, c.callee);
                    const final_args = self.prependCtxIfNeeded(func, method_args.items);
                    self.coerceCallArgs(final_args, params);
                    return self.builder.call(fid, final_args, ret_ty);
                }
                return self.emitError(eff_field, c.callee.span);
            }

            // A fn by this name exists but is not dot-callable: tailored help.
            if (ufcs_fd != null or self.resolveFuncByName(fa.field) != null) {
                if (self.diagnostics) |d| {
                    const id = d.addFmtId(.err, c.callee.span, "'{s}' is not a ufcs function — a plain function does not dispatch via dot-call", .{fa.field});
                    d.addHelpFmt(id, c.callee.span, null, "call it directly (`{s}(receiver, ...)`) or declare it `{s} :: ufcs (...) {{ ... }}`", .{ fa.field, fa.field });
                }
                return Ref.none;
            }
            return self.emitError(fa.field, c.callee.span);
        },
        .enum_literal => |el| {
            const target_opt: ?TypeId = self.target_type;

            // Try struct-method dispatch first: .{...}.method() where target is a struct
            if (target_opt) |tgt| {
                if (!tgt.isBuiltin()) {
                    const target_info = self.module.types.get(tgt);
                    if (target_info == .@"struct") {
                        const struct_name = self.module.types.typeName(tgt);
                        const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ struct_name, el.name }) catch el.name;
                        if (self.plainStructMethod(tgt, el.name)) |method| {
                            const fd = method.fd;
                            const dispatch_name = self.plainStructMethodName(method);
                            if (fd.type_params.len > 0) return self.lowerGenericCall(fd, dispatch_name, c, args.items);
                            if (self.checkCallArity(fd, dispatch_name, args.items.len, false, c.callee.span)) return Ref.none;
                            self.appendDefaultArgs(fd, &args, c.callee);
                            const fid = self.ensurePlainStructMethodLowered(method);
                            const func = &self.module.functions.items[@intFromEnum(fid)];
                            const ret_ty = func.ret;
                            const params = func.params;
                            const final_args = self.prependCtxIfNeeded(func, args.items);
                            self.coerceCallArgs(final_args, params);
                            return self.builder.call(fid, final_args, ret_ty);
                        }
                        if (self.hasPlainStructAuthor(tgt))
                            return self.emitError(el.name, c.callee.span);
                        if (self.program_index.fn_ast_map.get(qualified)) |fd| {
                            if (fd.type_params.len > 0) {
                                return self.lowerGenericCall(fd, qualified, c, args.items);
                            }
                            if (!self.lowered_functions.contains(qualified)) {
                                self.lazyLowerFunction(qualified);
                            }
                        }
                        if (self.resolveFuncByName(qualified)) |fid| {
                            const func = &self.module.functions.items[@intFromEnum(fid)];
                            const ret_ty = func.ret;
                            const params = func.params;
                            const final_args = self.prependCtxIfNeeded(func, args.items);
                            self.coerceCallArgs(final_args, params);
                            return self.builder.call(fid, final_args, ret_ty);
                        }
                    }
                }
            }

            // .Variant(payload) — tagged enum construction. Requires target to be a tagged union.
            const target = blk: {
                if (target_opt) |tgt| {
                    // A `?E` destination constructs the E and wraps at the
                    // coercion site — resolve through optional layers, same
                    // as the bare-literal path.
                    var t = tgt;
                    while (!t.isBuiltin()) {
                        const info = self.module.types.get(t);
                        if (info == .tagged_union) break :blk t;
                        if (info != .optional) break;
                        t = info.optional.child;
                    }
                }
                if (self.diagnostics) |diags| {
                    diags.addFmt(.err, c.callee.span, "cannot infer enum type for '.{s}' \u{2014} use an explicit type or assign to a typed variable", .{el.name});
                }
                return self.emitPlaceholder(el.name);
            };
            // Validate the variant EXISTS before resolving its index —
            // `resolveVariantIndex` returns 0 for an unknown name, which would
            // silently build the zeroth variant (`.int_(7)` on a renamed enum
            // constructing `.null`). `target` is a tagged_union per the blk above.
            if (!self.hasVariant(target, el.name)) {
                self.emitBadVariant(target, self.module.types.get(target).tagged_union, el.name, c.callee.span);
                return self.builder.enumInit(0, Ref.none, target);
            }
            // ORDINAL indexes `fields[]`; the EXPLICIT tag value is stored at
            // runtime so a payloadful match/C-interop agree.
            const ord = self.resolveVariantIndex(target, el.name);
            const tag = self.resolveVariantValue(target, el.name);
            var payload = if (args.items.len > 0) args.items[0] else Ref.none;
            // Coerce payload to match the field type. Coerce from the value's
            // ACTUAL lowered type (`getRefType`), not a re-inference of the
            // arg node: an anonymous payload literal (`.key_up(.{ ... })`)
            // re-infers as the STEERING target (the union type itself, from a
            // return/binding context), and that phantom `union → payload`
            // mismatch trips the unmodeled-coercion guard. The
            // lowered ref's type is authoritative.
            if (!payload.isNone() and !target.isBuiltin()) {
                const info = self.module.types.get(target);
                if (info == .tagged_union) {
                    const fields = info.tagged_union.fields;
                    if (ord < fields.len) {
                        const field_ty = fields[ord].ty;
                        const payload_ty = self.builder.getRefType(payload);
                        if (field_ty != payload_ty) {
                            payload = self.coerceToType(payload, payload_ty, field_ty);
                        }
                    }
                }
            }
            return self.builder.enumInit(tag, payload, target);
        },
        else => {
            // Indirect call through an expression. Unique-typed storage
            // writes through its env address; a `_{ … }` IIFE infers as
            // Closure and lowers as the env, so uniqueness follows the
            // lowered ref. Closure values use `call_closure`; fn pointers
            // use `call_indirect`.
            const inferred = self.inferExprType(c.callee);
            if (self.callableShapeOf(inferred)) |shape| switch (shape) {
                // Unique-typed and nominal storage is written through its
                // address, so an lvalue callee is lowered as a place — ONCE.
                .unique, .nominal => {
                    const addr: ?Ref = if (self.isLvalueExpr(c.callee)) self.lowerExprAsPtr(c.callee) else null;
                    if (callValue(self, .{
                        .ty = inferred,
                        .ref = if (addr == null) self.lowerExpr(c.callee) else Ref.none,
                        .addr = addr,
                        .node = c.callee,
                        .origin = .value,
                    }, c, args.items, c.callee.span)) |r| return r;
                },
                // A `_{ … }` IIFE infers as Closure and lowers as its env, so a
                // Closure / fn-pointer callee is classified on the LOWERED ref.
                .closure, .fn_ptr => {},
            };
            const callee_ref = self.lowerExpr(c.callee);
            const callee_ty = self.builder.getRefType(callee_ref);
            if (callValue(self, .{
                .ty = callee_ty,
                .ref = callee_ref,
                .node = c.callee,
                .origin = .value,
            }, c, args.items, c.callee.span)) |r| return r;
            // An unknown callee still dispatches with the fn-pointer ABI: the
            // implicit ctx is prepended when the pointee's convention wants it.
            var final_args = std.ArrayList(Ref).empty;
            defer final_args.deinit(self.alloc);
            if (self.fnPtrTypeWantsCtx(callee_ty)) {
                final_args.append(self.alloc, self.current_ctx_ref) catch unreachable;
            }
            final_args.appendSlice(self.alloc, args.items) catch unreachable;
            const owned = self.alloc.dupe(Ref, final_args.items) catch unreachable;
            return self.builder.emit(.{ .call_indirect = .{ .callee = callee_ref, .args = owned } }, .i64);
        },
    }
}

/// Emit a diagnostic for code that needs `Context` (allocator
/// protocol, `push .{...}` / `push Context{...}`, the `context` identifier) when
/// the program hasn't registered the type — i.e. doesn't transitively
/// import `modules/std.sx`. Returns a placeholder Ref so the lowering
/// can keep going and surface any additional errors.
pub fn diagnoseMissingContext(self: *Lowering, what: []const u8) Ref {
    if (self.diagnostics) |d| {
        const span = ast.Span{ .start = 0, .end = 0 };
        const id = d.addFmtId(.err, span, "{s} requires the Context type — add `@import \"modules/std.sx\";` (or a module that imports it)", .{what});
        // A no-context build may still COMPILE `@context_extend`
        // declarations (they are inert without Context). Show what the
        // program's context would have been, so the demand is traceable.
        self.noteRegisteredContextFields(id);
    }
    return self.emitPlaceholder("missing-context");
}

/// The `Allocator` value currently installed as `context.allocator`.
pub fn ambientAllocator(self: *Lowering) ?Ref {
    if (!self.implicit_ctx_enabled or self.current_ctx_ref == Ref.none) return null;
    const ctx_ty = self.module.types.findByName(self.module.types.internString("Context")) orelse return null;
    const af = self.contextFieldByName("allocator") orelse return null;
    const ctx = self.builder.load(self.current_ctx_ref, ctx_ty);
    return self.builder.structGet(ctx, af.index, af.ty);
}

/// Prepend the caller's current `__sx_ctx` to `args` when the callee
/// has the implicit context param. Returns either the original `args`
/// (when no prepend is needed) or a newly-allocated slice with ctx at
/// slot 0. The returned slice is mutable so callers can pass it
/// straight into `coerceCallArgs`. Direct callers that built the args
/// themselves with __sx_ctx already prepended (protocol thunks, FFI
/// wrappers) should NOT call this — they already manage slot 0.
pub fn prependCtxIfNeeded(self: *Lowering, callee: *const Function, args: []Ref) []Ref {
    if (!callee.has_implicit_ctx) return args;
    const new_args = self.alloc.alloc(Ref, args.len + 1) catch return args;
    new_args[0] = self.current_ctx_ref;
    @memcpy(new_args[1..], args);
    return new_args;
}

/// Concrete arg at an INTERFACE param target: erase NODE-AWARE so
/// `buildProtocolErasure` classifies from the AST and BORROWS lvalues
/// (`free(t, gpa)` aliases `gpa`). A literal-with-init-block materializes
/// through a temp slot, which the node-LESS refStorageAddress heuristic
/// would misread as an lvalue. Returns null when the shape doesn't apply
/// (caller falls through to its normal path).
fn protocolArgErasure(self: *Lowering, arg: *const Node, pt: TypeId) ?Ref {
    if (self.getProtocolInfo(pt) == null) return null;
    const cty = self.inferExprType(arg);
    if (cty == .unresolved or cty == pt or cty == .any or cty.isBuiltin()) return null;
    if (self.getProtocolInfo(cty) != null) return null; // already erased
    const ci = self.module.types.get(cty);
    if (ci != .@"struct" and ci != .pointer) return null;
    const val = self.lowerExpr(arg);
    return self.buildProtocolErasure(val, arg, cty, pt);
}

fn protocolHasMethod(proto_info: anytype, name: []const u8) bool {
    for (proto_info.methods) |m| {
        if (std.mem.eql(u8, m.name, name)) return true;
    }
    return false;
}

pub fn resolveFuncByName(self: *Lowering, name: []const u8) ?FuncId {
    // Check extern name map first (e.g., "c_abs" → "abs")
    const effective_name = self.extern_name_map.get(name) orelse name;
    const name_id = self.module.types.internString(effective_name);
    for (self.module.functions.items, 0..) |func, i| {
        if (func.name == name_id) return FuncId.fromIndex(@intCast(i));
    }
    return null;
}

/// The `BuiltinId` (IR op tag) a call lowers to, or null when the name has no
/// `call_builtin` form. `BuiltinId` is an IR-level concern — which op the
/// instruction carries — and is deliberately NOT the same axis as the registry's
/// `Id`, which says which DECLARATION was called.
///
/// "print" is not here — it's a comptime-expanded function, not a builtin.
/// "out" is not either — it's a plain sx function over libc `write`.
pub fn resolveBuiltin(name: []const u8) ?inst_mod.BuiltinId {
    // Every name must be a registered intrinsic to get a builtin op at all.
    const id = intrinsics.findByName(name) orelse return null;
    return switch (id) {
        .@"@sqrt" => .sqrt,
        .@"@sin" => .sin,
        .@"@cos" => .cos,
        .@"@floor" => .floor,
        .size_of => .size_of,
        .align_of => .align_of,

        // No `call_builtin` form. The reflection intrinsics fold to a constant in
        // `tryLowerReflectionCall`; `type_name` / `type_is_unsigned` / `@typeInfo`
        // DO have builtin ops but are emitted directly by their folds (as the
        // non-static fallback), never routed through here; the atomics lower to
        // dedicated atomic ops. Listed exhaustively on purpose — a new intrinsic
        // must decide here rather than fall through a catch-all.
        .@"@typeOf",
        .@"@typeName",
        .struct_field_count,
        .variant_count,
        .struct_field_name,
        .variant_name,
        .struct_field_type,
        .variant_type,
        .struct_field_offset,
        .struct_field_value,
        .variant_payload,
        .variant_value,
        .variant_index,
        .pointee_type,
        .is_flags,
        .@"@errorName",
        .@"@tag",
        .@"@errorPayload",
        .@"@len",
        .@"@field",
        .@"@elementAt",
        .vector_lanes,
        .__sx_variant_tag_width,
        .__sx_slice_len_info,
        .any_element,
        .raw_any_data,
        .raw_make_any,
        .@"@typeInfo",
        .atomic_load,
        .atomic_store,
        .atomic_fetch_add,
        .atomic_fetch_sub,
        .atomic_fetch_and,
        .atomic_fetch_or,
        .atomic_fetch_xor,
        .atomic_fetch_min,
        .atomic_fetch_max,
        .atomic_swap,
        .atomic_fence,
        .atomic_cmpxchg,
        .atomic_cmpxchg_weak,
        .@"@volatile_load",
        .@"@volatile_store",
        .@"@printf",
        .@"@is_comptime",
        .@"@error",
        .@"@va_start",
        .@"@va_arg",
        .@"@va_copy",
        .@"@va_end",
        .@"@env_type",
        .@"@env_of",
        .@"@call_ptr",
        // evaluate-only: the VM services these; they never lower at all.
        .raw_declare_type,
        .raw_register_type,
        .c_object_paths,
        .link_libraries,
        .emit_object,
        .link,
        .build_output,
        .build_target,
        .build_frameworks,
        .build_flags,
        .build_options,
        .add_link_flag,
        .add_framework,
        .set_output_path,
        .set_wasm_shell,
        .add_asset_dir,
        .asset_dir_count,
        .asset_dir_src_at,
        .asset_dir_dest_at,
        .set_post_link_module,
        .binary_path,
        .set_bundle_path,
        .set_bundle_id,
        .set_codesign_identity,
        .set_provisioning_profile,
        .bundle_path,
        .bundle_id,
        .codesign_identity,
        .provisioning_profile,
        .target_triple,
        .is_macos,
        .is_ios,
        .is_ios_device,
        .is_ios_simulator,
        .is_android,
        .framework_count,
        .framework_at,
        .framework_path_count,
        .framework_path_at,
        .set_manifest_path,
        .set_keystore_path,
        .manifest_path,
        .keystore_path,
        .jni_main_count,
        .jni_main_runtime_path_at,
        .jni_main_java_source_at,
        .on_build,
        .raw_intern,
        .raw_text_of,
        .raw_find_type,
        .raw_type_kind,
        .raw_type_name,
        .raw_field_count,
        .raw_field_name,
        .raw_field_type,
        .raw_variant_value,
        .raw_pointer_to,
        => null,
    };
}

// ── Generic calls ─────────────────────────────────────────────

/// Build `tp.name -> TypeId` bindings for a generic call.
/// `args_ast` must be parallel to `fd.params`; for dot-calls the caller
/// prepends the receiver's AST node so positions align with `fd.params[0] = self`.
/// Caller owns the returned map and must call `.deinit()`.
/// Lower a call to a generic function by monomorphizing it with inferred type arguments.
pub fn lowerGenericCall(self: *Lowering, fd: *const ast.FnDecl, base_name: []const u8, call_node: *const ast.Call, lowered_args: []Ref) Ref {
    var bindings = callBindings(self, fd, call_node.args, lowered_args);
    defer bindings.deinit();

    // An uninferrable TYPE param must diagnose here: monomorphizing with
    // it unbound stamps `.unresolved` through the body and trips the
    // emitter's sentinel panic instead of surfacing a source error.
    // Comptime VALUE params (`$N: u32`) and `..$Ts` packs bind through
    // their own dispatch and are exempt.
    for (fd.type_params) |tp| {
        if (tp.is_variadic) continue;
        if (tp.constraint.data != .type_expr) continue;
        const cname = tp.constraint.data.type_expr.name;
        const is_type_param = std.mem.eql(u8, cname, "Type") or
            self.isProtocolConstraint(cname, fd.body.source_file);
        if (is_type_param and !bindings.contains(tp.name)) {
            if (self.diagnostics) |d|
                d.addFmt(.err, call_node.callee.span, "cannot infer generic type parameter '{s}' for '{s}' from this call's arguments", .{ tp.name, base_name });
            return Ref.none;
        }
    }

    const types_passed_explicitly = self.genericResolver().typesPassedExplicitly(fd, call_node.args);
    const mangled_name = self.genericResolver().mangleGenericName(base_name, fd, &bindings);

    if (!self.lowered_functions.contains(mangled_name)) {
        // Record this call as the instantiation site for the mono's body:
        // a surviving `@error` inside it anchors HERE (outermost frame of
        // the chain), not at the library-internal directive line.
        self.mono_sites.append(self.alloc, .{
            .source = call_node.callee.source_file orelse self.current_source_file,
            .span = call_node.callee.span,
            .caller_func = self.builder.func,
        }) catch {};
        defer self.mono_sites.items.len -= 1;
        self.monomorphizeFunction(fd, mangled_name, &bindings);
    }

    if (self.resolveFuncByName(mangled_name)) |fid| {
        const func = &self.module.functions.items[@intFromEnum(fid)];
        const ret_ty = func.ret;
        const params = func.params;
        // Build value-only args (skip type param declaration args)
        var value_args = std.ArrayList(Ref).empty;
        defer value_args.deinit(self.alloc);
        var arg_idx: usize = 0;
        for (fd.params) |p| {
            if (isTypeParamDecl(&p, fd.type_params)) {
                if (types_passed_explicitly) arg_idx += 1;
                continue;
            }
            if (arg_idx < lowered_args.len) {
                value_args.append(self.alloc, lowered_args[arg_idx]) catch unreachable;
            }
            arg_idx += 1;
        }
        // A C-variadic monomorph takes whatever follows its fixed parameters:
        // the tail arguments ride behind the value params and cross under the
        // shared promotion/admissibility rule.
        const fixed_count = value_args.items.len;
        if (func.is_c_variadic) {
            while (arg_idx < lowered_args.len) : (arg_idx += 1) {
                value_args.append(self.alloc, lowered_args[arg_idx]) catch unreachable;
            }
        }
        const final_args = self.prependCtxIfNeeded(func, value_args.items);
        self.coerceCallArgs(final_args, params);
        if (func.is_c_variadic) {
            const ctx_off: usize = final_args.len - value_args.items.len;
            self.promoteCVariadicArgs(final_args, ctx_off + fixed_count);
        }
        return self.builder.call(fid, final_args, ret_ty);
    }

    return self.emitError(base_name, call_node.callee.span);
}

/// The bindings a call mangles and monomorphizes on: what the argument NODES
/// say, then what the lowered callable arguments ARE. `args_ast` and `lowered`
/// are parallel to `fd.params`; a dot-call prepends its receiver to both.
fn callBindings(
    self: *Lowering,
    fd: *const ast.FnDecl,
    args_ast: []const *const Node,
    lowered: []Ref,
) std.StringHashMap(TypeId) {
    var bindings = self.genericResolver().buildTypeBindings(fd, args_ast);
    bindCallableBinders(self, fd, args_ast, lowered, &bindings);
    return bindings;
}

/// Rebind each type parameter a callable-binder argument speaks for from the
/// value that argument lowered to. A callable's type is its shape, not its
/// annotation: a `_{ … }` literal IS its env struct, and a lambda with no `-> R`
/// takes its return from its body — neither is known until the argument is
/// lowered. Binders the function-type bound introduces extract from that
/// signature. An argument that lowered to something uncallable keeps the
/// annotation's binding, so the bound diagnoses it.
fn bindCallableBinders(
    self: *Lowering,
    fd: *const ast.FnDecl,
    args_ast: []const *const Node,
    lowered_args: []Ref,
    bindings: *std.StringHashMap(TypeId),
) void {
    const types_explicit = self.genericResolver().typesPassedExplicitly(fd, args_ast);
    for (fd.type_params) |tp| {
        var arg_idx: usize = 0;
        for (fd.params) |param| {
            const is_type_decl = isTypeParamDecl(&param, fd.type_params);
            defer if (!is_type_decl) {
                arg_idx += 1;
            };
            if (is_type_decl) {
                if (types_explicit) arg_idx += 1;
                continue;
            }
            if (arg_idx >= lowered_args.len) continue;
            if (Lowering.callableBound(param.type_expr) == null) continue;
            if (!self.matchTypeParam(param.type_expr, tp.name)) continue;
            const arg_ref = lowered_args[arg_idx];
            const arg_ty = self.valueTypeOfRef(arg_ref, self.builder.getRefType(arg_ref));
            if (self.callableSigOf(arg_ty) == null) continue;
            if (self.extractTypeParam(param.type_expr, arg_ty, tp.name)) |ty| {
                bindings.put(tp.name, ty) catch {};
            }
        }
    }
}

/// The five `Ordering` variants by declaration-order tag. INVARIANT: the sx
/// `Ordering` enum (library/modules/std/atomic.sx) and the IR `AtomicOrdering`
/// enum (inst.zig) declare these variants in the SAME order, so a comptime-bound
/// ordering's tag indexes this list. Keep all three in sync.
fn atomicOrderingFromTag(tag: i64) ?inst_mod.AtomicOrdering {
    return switch (tag) {
        0 => .relaxed,
        1 => .acquire,
        2 => .release,
        3 => .acq_rel,
        4 => .seq_cst,
        else => null,
    };
}

/// Resolve an ordering argument to the IR `AtomicOrdering`. Accepts a bare enum
/// literal (`.seq_cst`) OR a comptime-bound identifier (a `$o: Ordering` param
/// forwarded into the intrinsic — read its bound variant tag via
/// `comptimeIntNamed`). Returns null for a non-constant ordering — the caller
/// turns that into a loud diagnostic (never a silent default).
fn atomicOrderingFromNode(self: *Lowering, node: *const Node) ?inst_mod.AtomicOrdering {
    if (node.data == .enum_literal) {
        const n = node.data.enum_literal.name;
        if (std.mem.eql(u8, n, "relaxed")) return .relaxed;
        if (std.mem.eql(u8, n, "acquire")) return .acquire;
        if (std.mem.eql(u8, n, "release")) return .release;
        if (std.mem.eql(u8, n, "acq_rel")) return .acq_rel;
        if (std.mem.eql(u8, n, "seq_cst")) return .seq_cst;
        return null;
    }
    if (node.data == .identifier) {
        if (self.comptimeIntNamed(node.data.identifier.name)) |tag| return atomicOrderingFromTag(tag);
    }
    return null;
}

/// Is `name` one of `std/atomic.sx`'s intrinsics? Asks the registry, then
/// narrows by id — exhaustively, so a new intrinsic must classify itself here
/// instead of defaulting to "not an atomic".
fn isAtomicIntrinsic(name: []const u8) bool {
    const id = intrinsics.findByName(name) orelse return false;
    return switch (id) {
        .atomic_load,
        .atomic_store,
        .atomic_fetch_add,
        .atomic_fetch_sub,
        .atomic_fetch_and,
        .atomic_fetch_or,
        .atomic_fetch_xor,
        .atomic_fetch_min,
        .atomic_fetch_max,
        .atomic_swap,
        .atomic_fence,
        .atomic_cmpxchg,
        .atomic_cmpxchg_weak,
        => true,

        .size_of,
        .align_of,
        .@"@typeOf",
        .@"@typeName",
        .struct_field_count,
        .variant_count,
        .struct_field_name,
        .variant_name,
        .struct_field_type,
        .variant_type,
        .struct_field_offset,
        .struct_field_value,
        .variant_payload,
        .variant_value,
        .variant_index,
        .pointee_type,
        .is_flags,
        .@"@errorName",
        .@"@tag",
        .@"@errorPayload",
        .@"@len",
        .@"@field",
        .@"@elementAt",
        .vector_lanes,
        .__sx_variant_tag_width,
        .__sx_slice_len_info,
        .any_element,
        .raw_any_data,
        .raw_make_any,
        .@"@typeInfo",
        .@"@sqrt",
        .@"@sin",
        .@"@cos",
        .@"@floor",
        .@"@volatile_load",
        .@"@volatile_store",
        .@"@printf",
        .@"@is_comptime",
        .@"@error",
        .@"@va_start",
        .@"@va_arg",
        .@"@va_copy",
        .@"@va_end",
        .@"@env_type",
        .@"@env_of",
        .@"@call_ptr",
        .raw_declare_type,
        .raw_register_type,
        .c_object_paths,
        .link_libraries,
        .emit_object,
        .link,
        .build_output,
        .build_target,
        .build_frameworks,
        .build_flags,
        .build_options,
        .add_link_flag,
        .add_framework,
        .set_output_path,
        .set_wasm_shell,
        .add_asset_dir,
        .asset_dir_count,
        .asset_dir_src_at,
        .asset_dir_dest_at,
        .set_post_link_module,
        .binary_path,
        .set_bundle_path,
        .set_bundle_id,
        .set_codesign_identity,
        .set_provisioning_profile,
        .bundle_path,
        .bundle_id,
        .codesign_identity,
        .provisioning_profile,
        .target_triple,
        .is_macos,
        .is_ios,
        .is_ios_device,
        .is_ios_simulator,
        .is_android,
        .framework_count,
        .framework_at,
        .framework_path_count,
        .framework_path_at,
        .set_manifest_path,
        .set_keystore_path,
        .manifest_path,
        .keystore_path,
        .jni_main_count,
        .jni_main_runtime_path_at,
        .jni_main_java_source_at,
        .on_build,
        .raw_intern,
        .raw_text_of,
        .raw_find_type,
        .raw_type_kind,
        .raw_type_name,
        .raw_field_count,
        .raw_field_name,
        .raw_field_type,
        .raw_variant_value,
        .raw_pointer_to,
        => false,
    };
}

/// Recognize the atomic intrinsics and lower them to dedicated atomic IR ops:
///   atomic_load($T, ptr: *T, o: Ordering) -> T
///   atomic_store($T, ptr: *T, v: T, o: Ordering)
/// The `Ordering` arg MUST be a constant enum literal — read statically here and
/// baked into the op (the op carries no runtime ordering operand). `T` must be a
/// scalar of size 1/2/4/8/16. Both constraints are loud diagnostics, never silent
/// defaults. Returns null if `name` is not an atomic intrinsic.
///
/// Gated on the registry: a name reaches the ordering/type checks below only if
/// `modules/std/atomic.sx` declares it as an intrinsic. A user function named
/// `atomic_load` is an ordinary call, not a silently-hijacked atomic op.
pub fn tryLowerAtomicIntrinsic(self: *Lowering, name: []const u8, c: *const ast.Call) ?Ref {
    if (!isAtomicIntrinsic(name)) return null;

    // Fence is a standalone op — ordering only, no `$T`/ptr (different shape).
    if (std.mem.eql(u8, name, "atomic_fence")) {
        if (c.args.len != 1) {
            if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "atomic_fence expects 1 argument", .{});
            return Ref.none;
        }
        const ordering = atomicOrderingFromNode(self, c.args[0]) orelse {
            if (self.diagnostics) |d| d.addFmt(.err, c.args[0].span, "fence ordering must be a constant ordering literal", .{});
            return Ref.none;
        };
        // LLVM has no monotonic/unordered fence — `.relaxed` is invalid.
        if (ordering == .relaxed) {
            if (self.diagnostics) |d| d.addFmt(.err, c.args[0].span, "fence ordering cannot be .relaxed (use .acquire / .release / .acq_rel / .seq_cst)", .{});
            return Ref.none;
        }
        self.builder.emitVoid(.{ .atomic_fence = .{ .ordering = ordering } }, .void);
        return Ref.none; // fence has a void result
    }

    const is_load = std.mem.eql(u8, name, "atomic_load");
    const is_store = std.mem.eql(u8, name, "atomic_store");
    const rmw_kind = rmwKindFromName(name); // atomic_fetch_add/sub/and/or/xor/min/max
    const is_cmpxchg = std.mem.eql(u8, name, "atomic_cmpxchg");
    const is_cmpxchg_weak = std.mem.eql(u8, name, "atomic_cmpxchg_weak");
    const is_cas = is_cmpxchg or is_cmpxchg_weak;
    if (!is_load and !is_store and rmw_kind == null and !is_cas) return null;

    // ($T, ptr[, operand/val], ordering): load=3, store/rmw=4.
    // cmpxchg ($T, ptr, expected, desired, success, failure): 6.
    const expected: usize = if (is_load) 3 else if (is_cas) 6 else 4;
    if (c.args.len != expected) {
        if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "{s} expects {d} arguments", .{ name, expected });
        return Ref.none;
    }

    const elem_ty = self.resolveTypeArg(c.args[0]);
    // Atomic-eligible T = a SCALAR that LLVM can load/store atomically: integer,
    // float, bool, pointer, enum (integer-backed), or vector. Aggregates
    // (struct/array/slice/string/tuple/…) are rejected LOUDLY here — without the
    // kind check a same-sized aggregate (`[8]u8`, an 8-byte struct) slips through
    // and the user gets a raw LLVM verifier error instead of a clean diagnostic.
    const scalar_ok = switch (self.module.types.get(elem_ty)) {
        .signed, .unsigned, .f32, .f64, .bool, .pointer, .many_pointer, .cstring, .@"enum", .vector => true,
        else => false,
    };
    const size = self.typeSizeBytes(elem_ty);
    if (!scalar_ok or (size != 1 and size != 2 and size != 4 and size != 8 and size != 16)) {
        if (self.diagnostics) |d| d.addFmt(.err, c.args[0].span, "atomic ops require a scalar type (integer/float/bool/pointer/enum/vector) of size 1/2/4/8/16 bytes — '{s}' is not eligible", .{self.formatTypeName(elem_ty)});
        return Ref.none;
    }
    // RMW (A.1) is restricted to INTEGER types: arithmetic/bitwise/min-max on
    // floats (fadd/fsub) and pointers is out of scope — reject loudly rather
    // than emit invalid LLVM.
    if (rmw_kind != null) {
        const int_ok = switch (self.module.types.get(elem_ty)) {
            .signed, .unsigned => true,
            else => false,
        };
        if (!int_ok) {
            if (self.diagnostics) |d| d.addFmt(.err, c.args[0].span, "atomic read-modify-write requires an integer type — '{s}' is not eligible", .{self.formatTypeName(elem_ty)});
            return Ref.none;
        }
    }
    // CAS (A.2) is likewise restricted to INTEGER types: the `?T` result is laid
    // out as `{ T, i1 }` (null = success); pointer/niche optionals are out of
    // scope, so a non-integer T is rejected LOUDLY here.
    if (is_cas) {
        const int_ok = switch (self.module.types.get(elem_ty)) {
            .signed, .unsigned => true,
            else => false,
        };
        if (!int_ok) {
            if (self.diagnostics) |d| d.addFmt(.err, c.args[0].span, "atomic compare-exchange requires an integer type — '{s}' is not eligible", .{self.formatTypeName(elem_ty)});
            return Ref.none;
        }
    }

    // CAS resolves TWO orderings (success, failure) and validates the LLVM rule
    // that the failure ordering may not be .release / .acq_rel and may not be
    // stronger than the success ordering. Handled in its own branch (different
    // arity + dual-ordering shape) before the single-ordering path below.
    if (is_cas) {
        const succ_node = c.args[4];
        const fail_node = c.args[5];
        const success_ordering = atomicOrderingFromNode(self, succ_node) orelse {
            if (self.diagnostics) |d| d.addFmt(.err, succ_node.span, "atomic ordering must be a constant ordering literal (.relaxed / .acquire / .release / .acq_rel / .seq_cst)", .{});
            return Ref.none;
        };
        const failure_ordering = atomicOrderingFromNode(self, fail_node) orelse {
            if (self.diagnostics) |d| d.addFmt(.err, fail_node.span, "atomic ordering must be a constant ordering literal (.relaxed / .acquire / .release / .acq_rel / .seq_cst)", .{});
            return Ref.none;
        };
        // The FAILURE ordering describes a load that does NOT write, so LLVM
        // forbids .release / .acq_rel there, and forbids it being stronger than
        // the SUCCESS ordering. Strength rank: relaxed=0 < acquire=release=1 <
        // acq_rel=2 < seq_cst=3.
        if (failure_ordering == .release or failure_ordering == .acq_rel) {
            if (self.diagnostics) |d| d.addFmt(.err, fail_node.span, "atomic compare-exchange failure ordering cannot be .release or .acq_rel (use .relaxed / .acquire / .seq_cst)", .{});
            return Ref.none;
        }
        if (atomicOrderingRank(failure_ordering) > atomicOrderingRank(success_ordering)) {
            if (self.diagnostics) |d| d.addFmt(.err, fail_node.span, "atomic compare-exchange failure ordering ('.{s}') cannot be stronger than the success ordering ('.{s}')", .{ @tagName(failure_ordering), @tagName(success_ordering) });
            return Ref.none;
        }

        const cas_ptr = self.lowerExpr(c.args[1]);
        const cmp = self.lowerExpr(c.args[2]);
        const new = self.lowerExpr(c.args[3]);
        // Result type is `?T` (null = success; failure carries the actual value).
        const opt_ty = self.module.types.optionalOf(elem_ty);
        return self.builder.emit(.{ .atomic_cmpxchg = .{
            .ptr = cas_ptr,
            .cmp = cmp,
            .new = new,
            .val_ty = elem_ty,
            .success_ordering = success_ordering,
            .failure_ordering = failure_ordering,
            .weak = is_cmpxchg_weak,
        } }, opt_ty);
    }

    const ord_node = c.args[expected - 1];
    const ordering = atomicOrderingFromNode(self, ord_node) orelse {
        if (self.diagnostics) |d| d.addFmt(.err, ord_node.span, "atomic ordering must be a constant ordering literal (.relaxed / .acquire / .release / .acq_rel / .seq_cst)", .{});
        return Ref.none;
    };
    // Per-op ordering validity (LLVM rejects these). A load can't release; a
    // store can't acquire; neither can acq_rel. (RMW accepts all orderings.)
    if (is_load and (ordering == .release or ordering == .acq_rel)) {
        if (self.diagnostics) |d| d.addFmt(.err, ord_node.span, "atomic load ordering cannot be .release or .acq_rel (use .relaxed / .acquire / .seq_cst)", .{});
        return Ref.none;
    }
    if (is_store and (ordering == .acquire or ordering == .acq_rel)) {
        if (self.diagnostics) |d| d.addFmt(.err, ord_node.span, "atomic store ordering cannot be .acquire or .acq_rel (use .relaxed / .release / .seq_cst)", .{});
        return Ref.none;
    }

    const ptr = self.lowerExpr(c.args[1]);
    if (is_load) {
        return self.builder.emit(.{ .atomic_load = .{ .ptr = ptr, .ordering = ordering } }, elem_ty);
    }
    const val = self.lowerExpr(c.args[2]);
    if (rmw_kind) |kind| {
        // RMW returns the OLD value (result type = T).
        return self.builder.emit(.{ .atomic_rmw = .{ .ptr = ptr, .operand = val, .val_ty = elem_ty, .ordering = ordering, .kind = kind } }, elem_ty);
    }
    self.builder.emitVoid(.{ .atomic_store = .{ .ptr = ptr, .val = val, .val_ty = elem_ty, .ordering = ordering } }, .void);
    return Ref.none; // store has a void result
}

/// Is `name` one of the volatile-access intrinsics? Asks the registry, then
/// narrows by id — exhaustively, so a new intrinsic must classify itself here
/// instead of defaulting to "not a volatile access".
fn isVolatileIntrinsic(name: []const u8) bool {
    const id = intrinsics.findByName(name) orelse return false;
    return switch (id) {
        .@"@volatile_load",
        .@"@volatile_store",
        => true,

        .@"@printf",
        .@"@is_comptime",
        .@"@error",
        .@"@va_start",
        .@"@va_arg",
        .@"@va_copy",
        .@"@va_end",
        .@"@env_type",
        .@"@env_of",
        .@"@call_ptr",
        .size_of,
        .align_of,
        .@"@typeOf",
        .@"@typeName",
        .struct_field_count,
        .variant_count,
        .struct_field_name,
        .variant_name,
        .struct_field_type,
        .variant_type,
        .struct_field_offset,
        .struct_field_value,
        .variant_payload,
        .variant_value,
        .variant_index,
        .pointee_type,
        .is_flags,
        .@"@errorName",
        .@"@tag",
        .@"@errorPayload",
        .@"@len",
        .@"@field",
        .@"@elementAt",
        .vector_lanes,
        .__sx_variant_tag_width,
        .__sx_slice_len_info,
        .any_element,
        .raw_any_data,
        .raw_make_any,
        .@"@typeInfo",
        .@"@sqrt",
        .@"@sin",
        .@"@cos",
        .@"@floor",
        .atomic_load,
        .atomic_store,
        .atomic_fetch_add,
        .atomic_fetch_sub,
        .atomic_fetch_and,
        .atomic_fetch_or,
        .atomic_fetch_xor,
        .atomic_fetch_min,
        .atomic_fetch_max,
        .atomic_swap,
        .atomic_fence,
        .atomic_cmpxchg,
        .atomic_cmpxchg_weak,
        .raw_declare_type,
        .raw_register_type,
        .c_object_paths,
        .link_libraries,
        .emit_object,
        .link,
        .build_output,
        .build_target,
        .build_frameworks,
        .build_flags,
        .build_options,
        .add_link_flag,
        .add_framework,
        .set_output_path,
        .set_wasm_shell,
        .add_asset_dir,
        .asset_dir_count,
        .asset_dir_src_at,
        .asset_dir_dest_at,
        .set_post_link_module,
        .binary_path,
        .set_bundle_path,
        .set_bundle_id,
        .set_codesign_identity,
        .set_provisioning_profile,
        .bundle_path,
        .bundle_id,
        .codesign_identity,
        .provisioning_profile,
        .target_triple,
        .is_macos,
        .is_ios,
        .is_ios_device,
        .is_ios_simulator,
        .is_android,
        .framework_count,
        .framework_at,
        .framework_path_count,
        .framework_path_at,
        .set_manifest_path,
        .set_keystore_path,
        .manifest_path,
        .keystore_path,
        .jni_main_count,
        .jni_main_runtime_path_at,
        .jni_main_java_source_at,
        .on_build,
        .raw_intern,
        .raw_text_of,
        .raw_find_type,
        .raw_type_kind,
        .raw_type_name,
        .raw_field_count,
        .raw_field_name,
        .raw_field_type,
        .raw_variant_value,
        .raw_pointer_to,
        => false,
    };
}

/// Recognize the volatile intrinsics and lower them to the volatile IR ops:
///   @volatile_load($T, address: *T) -> T
///   @volatile_store($T, address: *T, value: T)
/// `T` may be any type with storage — the access is an ordinary typed
/// load/store that the optimizer must keep, so integers, floats, pointers and
/// aggregates all qualify. A valueless `T` (`void`, a constraint protocol, a
/// comptime `Type`) has nothing to access and is a loud diagnostic.
///
/// Gated on the registry: a name reaches the checks below only if
/// `modules/std/core.sx` declares it as an intrinsic. The `@` sigil is part of
/// the name, and `contracts` refuses the declaration in any other module.
pub fn tryLowerVolatileIntrinsic(self: *Lowering, name: []const u8, c: *const ast.Call) ?Ref {
    if (!isVolatileIntrinsic(name)) return null;

    const is_load = std.mem.eql(u8, name, "@volatile_load");
    const expected: usize = if (is_load) 2 else 3;
    if (c.args.len != expected) {
        if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "{s} expects {d} arguments", .{ name, expected });
        return Ref.none;
    }

    const elem_ty = self.resolveTypeArg(c.args[0]);
    const has_storage = switch (self.module.types.get(elem_ty)) {
        .void, .noreturn, .pack, .protocol, .type_value, .unresolved => false,
        else => true,
    };
    if (!has_storage or self.typeSizeBytes(elem_ty) == 0) {
        if (self.diagnostics) |d| d.addFmt(.err, c.args[0].span, "volatile access requires a type with storage — '{s}' is not eligible", .{self.formatTypeName(elem_ty)});
        return Ref.none;
    }

    const ptr = self.lowerExpr(c.args[1]);
    if (is_load) return self.builder.emit(.{ .volatile_load = .{ .operand = ptr } }, elem_ty);

    // `value: T` takes the coercion any typed parameter takes — `target_type`
    // steers literal lowering, `coerceToType` converts what a differently-typed
    // expression produced. The conversion belongs here: signedness lives in the
    // sx type, and the store the backend builds is one untyped value wide.
    const saved_target = self.target_type;
    self.target_type = elem_ty;
    defer self.target_type = saved_target;
    const raw_val = self.lowerExpr(c.args[2]);
    const val = self.coerceToType(raw_val, self.builder.getRefType(raw_val), elem_ty);

    self.builder.emitVoid(.{ .volatile_store = .{ .ptr = ptr, .val = val, .val_ty = elem_ty } }, .void);
    return Ref.none; // store has a void result
}

/// The argument kinds `@printf` renders, each with the core.sx primitive that
/// writes it and the type that primitive takes.
const PrintfKind = enum {
    str,
    boolean,
    signed,
    unsigned,
    float,

    fn primitive(self: PrintfKind) []const u8 {
        return switch (self) {
            .str => "__sx_printf_str",
            .boolean => "__sx_printf_bool",
            .signed => "__sx_printf_i64",
            .unsigned => "__sx_printf_u64",
            .float => "__sx_printf_f64",
        };
    }

    fn param(self: PrintfKind) TypeId {
        return switch (self) {
            .str => .string,
            .boolean => .bool,
            .signed => .i64,
            .unsigned => .u64,
            .float => .f64,
        };
    }
};

/// The kind that renders a value of `ty`, or null when nothing does.
fn printfKind(self: *Lowering, ty: TypeId) ?PrintfKind {
    switch (ty) {
        .string => return .str,
        .bool => return .boolean,
        .i8, .i16, .i32, .i64, .isize => return .signed,
        .u8, .u16, .u32, .u64, .usize => return .unsigned,
        .f32, .f64 => return .float,
        else => {},
    }
    if (ty.isBuiltin()) return null;
    return switch (self.module.types.get(ty)) {
        .signed => .signed,
        .unsigned => .unsigned,
        .f32, .f64 => .float,
        else => null,
    };
}

/// Emit `<primitive>(<arg>)`, routed through the ordinary call path so the
/// primitive is lowered on demand wherever the `@printf` sits.
fn emitPrintfCall(self: *Lowering, primitive: []const u8, arg: *Node, span: ast.Span, src: ?[]const u8) void {
    const callee = self.synthNode(.{ .identifier = .{ .name = primitive } }, span, src);
    const args = self.alloc.dupe(*Node, &.{arg}) catch @panic("out of memory");
    _ = self.lowerCall(&.{ .callee = callee, .args = args });
}

/// Write one literal run of the format string.
fn emitPrintfSegment(self: *Lowering, text: []const u8, span: ast.Span, src: ?[]const u8) void {
    if (text.len == 0) return;
    const owned = self.alloc.dupe(u8, text) catch @panic("out of memory");
    // `is_raw` keeps the bytes verbatim: the segment arrives here unescaped.
    const lit = self.synthNode(.{ .string_literal = .{ .raw = owned, .is_raw = true } }, span, src);
    emitPrintfCall(self, PrintfKind.str.primitive(), lit, span, src);
}

/// Write one `{}` argument. The value is lowered and bound to a synthetic
/// local, so the conversion to the primitive's parameter type happens here.
fn emitPrintfArg(self: *Lowering, arg: *const Node, span: ast.Span, src: ?[]const u8) void {
    const raw = self.lowerExpr(@constCast(arg));
    const arg_ty = self.builder.getRefType(raw);
    const kind = printfKind(self, arg_ty) orelse {
        if (self.diagnostics) |d| d.addFmt(.err, arg.span, "@printf renders a string, a bool, an integer or a float — '{s}' takes the allocating formatter, `print`", .{self.formatTypeName(arg_ty)});
        return;
    };
    const val = self.coerceToType(raw, arg_ty, kind.param());

    var buf: [48]u8 = undefined;
    const nm = std.fmt.bufPrint(&buf, "$printf_{d}", .{self.block_counter}) catch "$printf";
    self.block_counter += 1;
    const owned = self.alloc.dupe(u8, nm) catch @panic("out of memory");
    self.scope.?.put(owned, .{ .ref = val, .ty = kind.param(), .is_alloca = false });
    const id_node = self.synthNode(.{ .identifier = .{ .name = owned } }, span, src);
    emitPrintfCall(self, kind.primitive(), id_node, span, src);
}

/// Recognize `@printf($fmt, ..$args)` and expand it into the core.sx emission
/// primitives: one call per literal segment and one per argument, in source
/// order. The format vocabulary is `print`'s — `{}` takes the next argument,
/// `{{` and `}}` write a brace.
///
/// Gated on the registry: the name reaches here only because
/// `modules/std/core.sx` declares it, and `contracts` refuses the declaration
/// in any other module.
pub fn tryLowerPrintfIntrinsic(self: *Lowering, name: []const u8, c: *const ast.Call) ?Ref {
    const id = intrinsics.findByName(name) orelse return null;
    if (id != .@"@printf") return null;

    const span = c.callee.span;
    const src = self.current_source_file;
    if (c.args.len == 0) {
        if (self.diagnostics) |d| d.addFmt(.err, span, "@printf expects a format string", .{});
        return Ref.none;
    }
    // The expansion calls into core.sx, so the name resolving program-wide is
    // not enough — the module has to be in the program.
    if (!self.program_index.fn_ast_map.contains(PrintfKind.str.primitive())) {
        if (self.diagnostics) |d| d.addFmt(.err, span, "@printf writes through modules/std/core.sx; @import it", .{});
        return Ref.none;
    }
    // The format steers the expansion, so it is read at lowering: a literal is
    // the only spelling whose bytes are in hand here.
    const fmt_node = c.args[0];
    if (fmt_node.data != .string_literal) {
        if (self.diagnostics) |d| d.addFmt(.err, fmt_node.span, "@printf's format must be a string literal", .{});
        return Ref.none;
    }
    const lit = fmt_node.data.string_literal;
    const fmt = if (lit.is_raw) lit.raw else unescape.unescapeString(self.alloc, lit.raw) catch lit.raw;

    var seg: std.ArrayList(u8) = .empty;
    defer seg.deinit(self.alloc);
    var next_arg: usize = 1;
    var i: usize = 0;
    while (i < fmt.len) {
        const pair: ?u8 = if (i + 1 < fmt.len) fmt[i + 1] else null;
        if (fmt[i] == '{' and pair == '}') {
            if (next_arg >= c.args.len) {
                if (self.diagnostics) |d| d.addFmt(.err, span, "@printf's format has more '{{}}' placeholders than arguments", .{});
                return Ref.none;
            }
            emitPrintfSegment(self, seg.items, span, src);
            seg.clearRetainingCapacity();
            emitPrintfArg(self, c.args[next_arg], span, src);
            next_arg += 1;
            i += 2;
            continue;
        }
        if ((fmt[i] == '{' and pair == '{') or (fmt[i] == '}' and pair == '}')) {
            seg.append(self.alloc, fmt[i]) catch @panic("out of memory");
            i += 2;
            continue;
        }
        seg.append(self.alloc, fmt[i]) catch @panic("out of memory");
        i += 1;
    }
    emitPrintfSegment(self, seg.items, span, src);

    if (next_arg != c.args.len) {
        if (self.diagnostics) |d| d.addFmt(.err, c.args[next_arg].span, "@printf is passed {d} argument{s} the format has no '{{}}' for", .{
            c.args.len - next_arg, if (c.args.len - next_arg == 1) @as([]const u8, "") else "s",
        });
    }
    return Ref.none;
}

/// Strength rank of an atomic ordering, for the compare-exchange rule that the
/// failure ordering may not be stronger than the success ordering.
/// relaxed=0 < acquire=release=1 < acq_rel=2 < seq_cst=3.
fn atomicOrderingRank(o: inst_mod.AtomicOrdering) u8 {
    return switch (o) {
        .relaxed => 0,
        .acquire, .release => 1,
        .acq_rel => 2,
        .seq_cst => 3,
    };
}

/// Map an `atomic_fetch_*` intrinsic name to its RMW kind (null if not one).
fn rmwKindFromName(name: []const u8) ?inst_mod.RmwKind {
    if (std.mem.eql(u8, name, "atomic_fetch_add")) return .add;
    if (std.mem.eql(u8, name, "atomic_fetch_sub")) return .sub;
    if (std.mem.eql(u8, name, "atomic_fetch_and")) return .@"and";
    if (std.mem.eql(u8, name, "atomic_fetch_or")) return .@"or";
    if (std.mem.eql(u8, name, "atomic_fetch_xor")) return .xor;
    if (std.mem.eql(u8, name, "atomic_fetch_min")) return .min;
    if (std.mem.eql(u8, name, "atomic_fetch_max")) return .max;
    if (std.mem.eql(u8, name, "atomic_swap")) return .xchg; // swap = exchange RMW
    return null;
}

/// Is `name` dispatched by `tryLowerReflectionCall`? Either a registered
/// reflection intrinsic, or one of the bare KEYWORDS the compiler recognizes with
/// no declaration at all (`type_eq`, …). The two are listed apart
/// because only the first group answers to the registry; conflating them makes a
/// name with no declaration look like an intrinsic.
fn isReflectionCall(name: []const u8) bool {
    const keywords = [_][]const u8{
        "type_eq", "__interp_print_frames", "__trace_resolve_frame",
    };
    for (keywords) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    const id = intrinsics.findByName(name) orelse return false;
    return switch (id) {
        .size_of,
        .align_of,
        .@"@typeOf",
        .@"@typeName",
        .struct_field_count,
        .variant_count,
        .struct_field_name,
        .variant_name,
        .struct_field_type,
        .variant_type,
        .struct_field_offset,
        .struct_field_value,
        .variant_payload,
        .variant_value,
        .variant_index,
        .pointee_type,
        .is_flags,
        .@"@errorName",
        .@"@tag",
        .@"@errorPayload",
        .@"@len",
        .@"@field",
        .@"@elementAt",
        .vector_lanes,
        .__sx_variant_tag_width,
        .__sx_slice_len_info,
        .any_element,
        .raw_any_data,
        .raw_make_any,
        .@"@typeInfo",
        .@"@is_comptime",
        .@"@error",
        .@"@env_type",
        .@"@env_of",
        .@"@call_ptr",
        => true,

        // Lowered elsewhere: math -> `call_builtin`, atomics -> atomic ops,
        // volatile -> volatile load/store ops.
        .@"@sqrt",
        .@"@sin",
        .@"@cos",
        .@"@floor",
        .atomic_load,
        .atomic_store,
        .atomic_fetch_add,
        .atomic_fetch_sub,
        .atomic_fetch_and,
        .atomic_fetch_or,
        .atomic_fetch_xor,
        .atomic_fetch_min,
        .atomic_fetch_max,
        .atomic_swap,
        .atomic_fence,
        .atomic_cmpxchg,
        .atomic_cmpxchg_weak,
        .@"@volatile_load",
        .@"@volatile_store",
        .@"@printf",
        .@"@va_start",
        .@"@va_arg",
        .@"@va_copy",
        .@"@va_end",
        .raw_declare_type,
        .raw_register_type,
        .c_object_paths,
        .link_libraries,
        .emit_object,
        .link,
        .build_output,
        .build_target,
        .build_frameworks,
        .build_flags,
        .build_options,
        .add_link_flag,
        .add_framework,
        .set_output_path,
        .set_wasm_shell,
        .add_asset_dir,
        .asset_dir_count,
        .asset_dir_src_at,
        .asset_dir_dest_at,
        .set_post_link_module,
        .binary_path,
        .set_bundle_path,
        .set_bundle_id,
        .set_codesign_identity,
        .set_provisioning_profile,
        .bundle_path,
        .bundle_id,
        .codesign_identity,
        .provisioning_profile,
        .target_triple,
        .is_macos,
        .is_ios,
        .is_ios_device,
        .is_ios_simulator,
        .is_android,
        .framework_count,
        .framework_at,
        .framework_path_count,
        .framework_path_at,
        .set_manifest_path,
        .set_keystore_path,
        .manifest_path,
        .keystore_path,
        .jni_main_count,
        .jni_main_runtime_path_at,
        .jni_main_java_source_at,
        .on_build,
        .raw_intern,
        .raw_text_of,
        .raw_find_type,
        .raw_type_kind,
        .raw_type_name,
        .raw_field_count,
        .raw_field_name,
        .raw_field_type,
        .raw_variant_value,
        .raw_pointer_to,
        => false,
    };
}

/// The type a reflection argument names, for the C-variadic cursor rule alone,
/// or null when the argument names none. A bare name goes through the nominal
/// leaf, so an alias of the cursor answers with it; a composite expression is
/// resolved only where it spells the cursor, leaving every other argument to the
/// single resolution its own builtin performs.
fn reflectionArgTypeForCursorCheck(self: *Lowering, a: *const Node) ?TypeId {
    const named: []const u8 = switch (a.data) {
        .type_expr => |te| te.name,
        .identifier => |id| id.name,
        else => return if (self.isStaticTypeArg(a) and self.mentionsCursorType(a)) self.resolveTypeArg(a) else null,
    };
    if (self.scope) |s| if (s.lookup(named) != null) return null;
    const from = self.current_source_file orelse self.main_file orelse return null;
    return switch (self.selectNominalLeaf(named, from, false)) {
        .resolved => |t| t,
        else => null,
    };
}

/// The `__sx_slice_len_info` row for a boxed value's tag: nonzero exactly when
/// the value is a fat pointer, whose count and buffer live in its header.
fn boxedLenRow(self: *Lowering, recv: Ref) Ref {
    const args = self.alloc.dupe(Ref, &.{recv}) catch return self.builder.constInt(0, .i64);
    return self.builder.callBuiltin(.rt_slice_len_info, args, .i64);
}

/// The count a fat pointer's header carries: the word at the row's byte offset,
/// masked to the row's bit width and sign-extended when the row says signed.
fn boxedFatLen(self: *Lowering, recv: Ref, row: Ref) Ref {
    const b = &self.builder;
    const one = b.constInt(1, .i64);
    const bits = b.emit(.{ .bit_and = .{ .lhs = row, .rhs = b.constInt(0xFF, .i64) } }, .i64);
    const shifted_off = b.emit(.{ .shr = .{ .lhs = row, .rhs = b.constInt(16, .i64) } }, .i64);
    const off = b.emit(.{ .bit_and = .{ .lhs = shifted_off, .rhs = b.constInt(0xFFFF, .i64) } }, .i64);
    const shifted_sign = b.emit(.{ .shr = .{ .lhs = row, .rhs = b.constInt(8, .i64) } }, .i64);
    const is_signed = b.emit(.{ .bit_and = .{ .lhs = shifted_sign, .rhs = one } }, .i64);

    const bytes = b.anyData(recv, self.module.types.manyPtrTo(.u8));
    const at = b.emit(.{ .index_gep = .{ .lhs = bytes, .rhs = off } }, self.module.types.ptrTo(.u8));
    const word = b.load(at, .i64);

    const top_bit = b.sub(bits, one, .i64);
    const top = b.emit(.{ .shl = .{ .lhs = one, .rhs = top_bit } }, .i64);
    const mask = b.emit(.{ .bit_or = .{ .lhs = b.sub(top, one, .i64), .rhs = top } }, .i64);
    const count = b.emit(.{ .bit_and = .{ .lhs = word, .rhs = mask } }, .i64);
    const sign = b.mul(is_signed, b.emit(.{ .bit_and = .{ .lhs = count, .rhs = top } }, .i64), .i64);
    return b.sub(count, b.mul(b.constInt(2, .i64), sign, .i64), .i64);
}

/// The count the type table holds for a boxed value's tag: struct and union
/// fields, enum and tagged-union variants, array elements, vector lanes.
fn boxedTableCount(self: *Lowering, recv: Ref, _: Ref) Ref {
    const args = self.alloc.dupe(Ref, &.{recv}) catch return self.builder.constInt(0, .i64);
    return self.builder.callBuiltin(.rt_member_count, args, .i64);
}

/// The buffer a fat pointer's header names — the pointer word at its front.
fn boxedHeaderBuffer(self: *Lowering, recv: Ref, _: Ref) Ref {
    const header = self.builder.anyData(recv, self.module.types.ptrTo(.i64));
    return self.builder.load(header, .i64);
}

/// The boxed storage itself, where an array's or vector's elements sit.
fn boxedStorage(self: *Lowering, recv: Ref, _: Ref) Ref {
    return self.builder.anyData(recv, .i64);
}

/// Merge two i64 readings of a boxed value through a stack slot, choosing by
/// whether its tag says fat pointer. Both arms take `(recv, row)`.
fn boxedFatMerge(
    self: *Lowering,
    recv: Ref,
    comptime fat: fn (*Lowering, Ref, Ref) Ref,
    comptime flat: fn (*Lowering, Ref, Ref) Ref,
) Ref {
    const row = boxedLenRow(self, recv);
    const is_fat = self.builder.emit(.{ .cmp_ne = .{ .lhs = row, .rhs = self.builder.constInt(0, .i64) } }, .bool);
    const slot = self.builder.alloca(.i64);
    const fat_bb = self.freshBlock("view.fat");
    const flat_bb = self.freshBlock("view.flat");
    const merge_bb = self.freshBlock("view.merge");
    self.builder.condBr(is_fat, fat_bb, &.{}, flat_bb, &.{});

    self.builder.switchToBlock(fat_bb);
    self.builder.store(slot, fat(self, recv, row));
    self.builder.br(merge_bb, &.{});

    self.builder.switchToBlock(flat_bb);
    self.builder.store(slot, flat(self, recv, row));
    self.builder.br(merge_bb, &.{});

    self.builder.switchToBlock(merge_bb);
    return self.builder.load(slot, .i64);
}

/// `@len(v)` / `@field(v, i)` / `@elementAt(v, i)` — the boxed-value views. The
/// receiver is an `any`, so its kind is a runtime tag: member rows and counts
/// come from the reflection tables, and each view is `{member tag, interior
/// address}` — the boxed storage is borrowed, never copied.
fn lowerBoxedViewIntrinsic(self: *Lowering, id: intrinsics.Id, c: *const ast.Call) Ref {
    const entry = intrinsics.byId(id);
    const sentinel = self.builder.constInt(0, if (id == .@"@len") .i64 else .any);
    if (c.args.len != entry.arity) {
        if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "{s} takes {d} argument{s}, got {d}", .{
            entry.name, entry.arity, if (entry.arity == 1) @as([]const u8, "") else "s", c.args.len,
        });
        return sentinel;
    }
    const recv = blk: {
        const recv_ty = self.inferExprType(c.args[0]);
        const val = self.lowerExpr(c.args[0]);
        break :blk if (recv_ty == .any) val else self.boxAnyOf(val, recv_ty, c.args[0]);
    };
    if (id == .@"@len") return boxedFatMerge(self, recv, boxedFatLen, boxedTableCount);

    // The index lowers under its declared `i64` parameter, so an ambient `any`
    // target does not leak into it.
    const saved_target = self.target_type;
    self.target_type = .i64;
    const idx = self.lowerExpr(c.args[1]);
    self.target_type = saved_target;

    if (id == .@"@field") {
        const args = self.alloc.dupe(Ref, &.{ recv, idx }) catch return sentinel;
        const member_tag = self.builder.callBuiltin(.rt_member_type, args, .type_value);
        const offset = self.builder.callBuiltin(.rt_field_offset, args, .i64);
        const base = self.builder.anyData(recv, .i64);
        return self.builder.makeAny(member_tag, self.builder.add(base, offset, .i64));
    }
    const elem_args = self.alloc.dupe(Ref, &.{ recv, self.builder.constInt(0, .i64) }) catch return sentinel;
    const elem = self.builder.callBuiltin(.rt_member_type, elem_args, .type_value);
    const size_args = self.alloc.dupe(Ref, &.{elem}) catch return sentinel;
    const elem_size = self.builder.callBuiltin(.rt_size_of, size_args, .i64);
    const stride = self.builder.mul(idx, elem_size, .i64);
    return self.builder.makeAny(elem, self.builder.add(boxedFatMerge(self, recv, boxedHeaderBuffer, boxedStorage), stride, .i64));
}

/// Try to lower a call as a reflection intrinsic (expanded inline during
/// lowering). Returns null if the call is not one.
///
/// Gated on `isReflectionCall`, so a user function that happens to be named
/// `field_count` is an ordinary call rather than a silently-hijacked fold.
pub fn tryLowerReflectionCall(self: *Lowering, name: []const u8, c: *const ast.Call) ?Ref {
    if (!isReflectionCall(name)) return null;
    // Strict `$T: Type` guard for the type-introspection builtins. A
    // value argument (`6`, `true`, `5.2`, a struct) is rejected with a
    // diagnostic instead of being silently reinterpreted as a TypeId
    // index / sized via its `typeof`. One shared
    // classification covers all 7; it runs before dispatch.
    if (self.reflectionTypeArgGuard(name, c)) |sentinel| return sentinel;

    // The C-variadic cursor's storage is the target's, substituted where its
    // declaration's fields would land, so no reflection builtin publishes a
    // shape for it — nor for a type whose own layout is built out of one.
    for (c.args) |a| {
        const arg_ty = reflectionArgTypeForCursorCheck(self, a) orelse continue;
        if (self.refuseCursorInspection(arg_ty, a.span)) return self.reflectionErrorSentinel(name);
    }

    // `declare(name)` and `define(handle, info)` are ordinary sx functions
    // (`modules/std/meta.sx`) written over the `intrinsic` primitives
    // (`declare_type` / `register_type`), so they are not intercepted here.
    // (`preregisterForwardTypes` scans for the literal `declare("Name")`
    // spelling so a `*Name` self-reference forward-registers before the body
    // lowers; the sx `declare` calls `declare_type`, which returns that slot.
    // The `.enum(…)` arg to `define` infers `TypeInfo` from the sx fn's
    // declared param type via the ordinary call path's target-type threading.)
    if (std.mem.eql(u8, name, "@typeInfo")) {
        // Reflection-into-data: resolve `$T` at lower time, then emit a
        // `callBuiltin(.@"@typeInfo", [const_type])` the interp executes
        // against its type table, constructing the same value `define`
        // decodes so the two round-trip.
        if (c.args.len != 1) {
            if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "@typeInfo($T) takes one type argument", .{});
            return Ref.none;
        }
        const ti_ty = self.module.types.typeInfoType();
        if (!self.isStaticTypeArg(c.args[0])) {
            // Runtime Type: load the const record by tag.
            const tp = self.lowerExpr(c.args[0]);
            const args_owned = self.alloc.dupe(Ref, &.{tp}) catch return Ref.none;
            return self.builder.callBuiltin(.@"@typeInfo", args_owned, ti_ty);
        }
        const t = self.resolveTypeArg(c.args[0]);
        // Every type-table kind reflects (TypeInfo is exhaustive
        // over kinds; the VM's record builder classifies each and fails
        // loudly on an unclassified one). Only an unresolved arg rejects.
        if (t == .unresolved) {
            if (self.diagnostics) |d| d.addFmt(.err, c.args[0].span, "@typeInfo: unresolved type argument", .{});
            return Ref.none;
        }
        const type_ref = self.builder.constType(t);
        const args_owned = self.alloc.dupe(Ref, &.{type_ref}) catch return Ref.none;
        return self.builder.callBuiltin(.@"@typeInfo", args_owned, ti_ty);
    }
    if (std.mem.eql(u8, name, "@env_type")) {
        if (self.persistArity(name, c)) |sentinel| return sentinel;
        const env_ty = self.persistEnvType(name, self.resolveTypeArg(c.args[0]), c.args[0].span);
        return self.builder.constType(env_ty orelse .unresolved);
    }
    if (std.mem.eql(u8, name, "@call_ptr")) {
        const ptr_void = self.module.types.ptrTo(.void);
        if (self.persistArity(name, c)) |_| return self.builder.constNull(ptr_void);
        const ty = self.resolveTypeArg(c.args[0]);
        _ = self.persistEnvType(name, ty, c.args[0].span) orelse return self.builder.constNull(ptr_void);
        const fid = lower_closure.callTrampolineOf(self, ty) orelse {
            if (self.diagnostics) |d| d.addFmt(.err, c.args[0].span, "@call_ptr: '{s}' has no trampoline", .{self.formatTypeName(ty)});
            return self.builder.constNull(ptr_void);
        };
        return self.builder.emit(.{ .func_ref = fid }, ptr_void);
    }
    if (std.mem.eql(u8, name, "@env_of")) {
        if (self.persistArity(name, c)) |sentinel| return sentinel;
        _ = self.persistEnvType(name, self.inferExprType(c.args[0]), c.args[0].span) orelse return Ref.none;
        return self.lowerExpr(c.args[0]);
    }
    if (std.mem.eql(u8, name, "size_of")) {
        // size_of(T) → const_int(sizeof(T)); runtime Type arg → tag-indexed
        // size-table read. Same static/dynamic split as type_name —
        // the dynamic path never touches resolveTypeArg.
        if (!self.isStaticTypeArg(c.args[0])) {
            const arg_ref = self.lowerExpr(c.args[0]);
            const args_owned = self.alloc.dupe(Ref, &.{arg_ref}) catch return self.builder.constInt(0, .i64);
            return self.builder.callBuiltin(.rt_size_of, args_owned, .i64);
        }
        const ty = self.resolveTypeArg(c.args[0]);
        // An open set's layout follows the members declared anywhere in the
        // program, so its size is not a literal here: the op carries the type and
        // the frozen layout answers it (spec: Open Sets).
        if (self.openSetLayoutDependsOnSet(ty))
            return self.builder.emit(.{ .open_set_layout = .{ .measured = ty, .query = .size } }, .i64);
        const size: i64 = @intCast(self.typeSizeBytes(ty));
        return self.builder.constInt(size, .i64);
    }
    if (std.mem.eql(u8, name, "align_of")) {
        if (!self.isStaticTypeArg(c.args[0])) {
            const arg_ref = self.lowerExpr(c.args[0]);
            const args_owned = self.alloc.dupe(Ref, &.{arg_ref}) catch return self.builder.constInt(0, .i64);
            return self.builder.callBuiltin(.rt_align_of, args_owned, .i64);
        }
        const ty = self.resolveTypeArg(c.args[0]);
        if (self.openSetLayoutDependsOnSet(ty))
            return self.builder.emit(.{ .open_set_layout = .{ .measured = ty, .query = .alignment } }, .i64);
        const a: i64 = @intCast(self.module.types.typeAlignBytes(ty));
        return self.builder.constInt(a, .i64);
    }
    if (std.mem.eql(u8, name, "struct_field_count") or std.mem.eql(u8, name, "variant_count")) {
        // Runtime Type arg: tag-indexed count-table read. Kind gates
        // are a STATIC-arg feature; at runtime the table answers (a wrong-kind
        // tag reads 0 — kind discrimination at runtime is `@typeInfo`'s job).
        if (!self.isStaticTypeArg(c.args[0])) {
            const bi: inst_mod.BuiltinId = if (name[0] == 'v') .rt_variant_count else .rt_struct_field_count;
            const arg_ref = self.lowerExpr(c.args[0]);
            const args_owned = self.alloc.dupe(Ref, &.{arg_ref}) catch return self.builder.constInt(0, .i64);
            return self.builder.callBuiltin(bi, args_owned, .i64);
        }
        // struct_field_count(T) → const_int(N) for structs/tuples/unions
        // (scalar/fieldless types fold to 0 so generic walkers can gate leaves);
        // variant_count(E) → the enum/tagged-union variant count. Each family
        // rejects the other's kinds; arrays/vectors left both families (`.len`
        // is the native spelling for their lengths/lanes).
        const is_variant_fam = name[0] == 'v';
        const ty = self.resolveTypeArg(c.args[0]);
        const info = if (ty.isBuiltin() or ty == .unresolved) null else self.module.types.get(ty);
        if (is_variant_fam) {
            if (info) |i| switch (i) {
                .@"enum" => |e| return self.builder.constInt(@intCast(e.variants.len), .i64),
                .tagged_union => |u| return self.builder.constInt(@intCast(u.fields.len), .i64),
                else => {},
            };
            if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "variant_count expects an enum or tagged-union type; '{s}' is not one — for struct/tuple fields use struct_field_count", .{self.formatTypeName(ty)});
            return self.builder.constInt(0, .i64);
        }
        if (info) |i| switch (i) {
            .@"struct" => |s| return self.builder.constInt(@intCast(s.fields.len), .i64),
            .@"union" => |u| return self.builder.constInt(@intCast(u.fields.len), .i64),
            .@"enum", .tagged_union => {
                if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "struct_field_count expects a struct or tuple type; '{s}' is an enum — use variant_count", .{self.formatTypeName(ty)});
                return self.builder.constInt(0, .i64);
            },
            .array, .vector => {
                if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "struct_field_count is not for arrays/vectors — use `.len` on the value (its length/lane count)", .{});
                return self.builder.constInt(0, .i64);
            },
            else => {},
        };
        // Scalars and other fieldless types: 0 fields (a leaf).
        return self.builder.constInt(0, .i64);
    }
    if (std.mem.eql(u8, name, "@typeName")) {
        // @typeName(T):
        //   - Statically resolvable arg (type expression, pack
        //     index, generic binding, etc.) → fold to const_string
        //     at lower time.
        //   - Dynamic arg (e.g. `list[i]` indexing into a
        //     `$args`-derived []Type slice) → emit a
        //     `callBuiltin(.type_name, [arg_ref])`. The interp's
        //     arm reads the runtime `.type_tag`
        //     and returns the per-position name. Without this
        //     split, the catch-all `else => .i64` in
        //     `resolveTypeArg` silently returns "i64" for every
        //     dynamic call — exactly the silent-arm pattern the
        //     project's REJECTED PATTERNS forbid.
        if (self.isStaticTypeArg(c.args[0])) {
            const ty = self.resolveTypeArg(c.args[0]);
            const tn_str = self.formatTypeName(ty);
            const sid = self.module.types.internString(tn_str);
            return self.builder.constString(sid);
        }
        const arg_ref = self.lowerExpr(c.args[0]);
        const args_owned = self.alloc.dupe(Ref, &.{arg_ref}) catch return self.builder.constString(self.module.types.internString(""));
        return self.builder.callBuiltin(.type_name, args_owned, .string);
    }
    if (std.mem.eql(u8, name, "type_eq")) {
        // type_eq(T1, T2) → const_bool — comptime TypeId equality.
        // TypeIds are interned per structural shape so equality on
        // them matches the user's intuition: `type_eq(i64, i64)` is
        // true, `type_eq(*i64, *i64)` is true, distinct shapes are
        // false. Pack-indexed types (`$args[0]`) resolve through
        // `resolveTypeArg` → `resolveTypeWithBindings`.
        if (c.args.len < 2) return self.builder.constBool(false);
        const a_static = self.isStaticTypeArg(c.args[0]);
        const b_static = self.isStaticTypeArg(c.args[1]);
        if (!a_static or !b_static) {
            // Runtime tag compare: Type is an i64 tag at runtime, so
            // equality is a plain integer compare — no table involved. A
            // static side lowers to its constant tag.
            const ra = if (a_static) self.builder.constType(self.resolveTypeArg(c.args[0])) else self.lowerExpr(c.args[0]);
            const rb = if (b_static) self.builder.constType(self.resolveTypeArg(c.args[1])) else self.lowerExpr(c.args[1]);
            const args_owned = self.alloc.dupe(Ref, &.{ ra, rb }) catch return self.builder.constBool(false);
            return self.builder.callBuiltin(.rt_type_eq, args_owned, .bool);
        }
        const a = self.resolveTypeArg(c.args[0]);
        const b = self.resolveTypeArg(c.args[1]);
        return self.builder.constBool(a == b);
    }
    if (std.mem.eql(u8, name, "vector_lanes")) {
        // vector_lanes(T) → the lane COUNT. The one vector length the flat
        // size tables cannot answer (ABI size is pow2-rounded — 3 lanes
        // occupy 4). Static arg folds; a runtime Type reads the lane table
        // (non-vector tags answer 0 — kind discrimination is `@typeInfo`'s
        // job, same rule as the count tables). A static NON-vector is a
        // loud error: `.len` / struct_field_count are the right spellings.
        if (c.args.len < 1) return self.builder.constInt(0, .i64);
        if (!self.isStaticTypeArg(c.args[0])) {
            const arg_ref = self.lowerExpr(c.args[0]);
            const args_owned = self.alloc.dupe(Ref, &.{arg_ref}) catch return self.builder.constInt(0, .i64);
            return self.builder.callBuiltin(.rt_vector_lanes, args_owned, .i64);
        }
        const ty = self.resolveTypeArg(c.args[0]);
        if (!ty.isBuiltin() and ty != .unresolved) {
            const info = self.module.types.get(ty);
            if (info == .vector) return self.builder.constInt(@intCast(info.vector.length), .i64);
        }
        if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "vector_lanes expects a vector type; '{s}' is not one", .{self.formatTypeName(ty)});
        return self.builder.constInt(0, .i64);
    }
    if (std.mem.eql(u8, name, "is_flags")) {
        if (!self.isStaticTypeArg(c.args[0])) {
            const arg_ref = self.lowerExpr(c.args[0]);
            const args_owned = self.alloc.dupe(Ref, &.{arg_ref}) catch return self.builder.constBool(false);
            return self.builder.callBuiltin(.rt_is_flags, args_owned, .bool);
        }
        const ty = self.resolveTypeArg(c.args[0]);
        if (!ty.isBuiltin()) {
            const info = self.module.types.get(ty);
            if (info == .@"enum") return self.builder.constBool(info.@"enum".is_flags);
        }
        return self.builder.constBool(false);
    }
    if (std.mem.eql(u8, name, "struct_field_name") or std.mem.eql(u8, name, "variant_name")) {
        if (c.args.len < 2) return self.builder.constString(self.module.types.internString(""));
        if (!self.isStaticTypeArg(c.args[0])) {
            // Runtime Type: master-index member-name table read.
            const tp = self.lowerExpr(c.args[0]);
            const idx = self.lowerExpr(c.args[1]);
            const args_owned = self.alloc.dupe(Ref, &.{ tp, idx }) catch return self.builder.constString(self.module.types.internString(""));
            return self.builder.callBuiltin(.rt_member_name, args_owned, .string);
        }
        const ty = self.resolveTypeArg(c.args[0]);
        if (!reflectFamilyOk(self, name, ty, c.callee.span)) {
            return self.builder.constString(self.module.types.internString(""));
        }
        // Fold to a comptime STRING constant when the type resolves AND the index
        // is a compile-time constant (incl. an `inline for` loop var) — so a
        // minted variant NAME / any comptime use gets a const string the
        // type-construction VM can evaluate, mirroring the `field_type` /
        // `field_count` folds. A member with no name (positional-tuple / array /
        // vector element) folds to "". A dynamic (runtime) index falls back to
        // the `field_name_get` instruction.
        if (ty != .unresolved) {
            switch (program_index_mod.foldDimU32(c.args[1], self, 0)) {
                .ok => |n| {
                    const nm = self.module.types.memberName(ty, @intCast(n)) orelse self.module.types.internString("");
                    return self.builder.constString(nm);
                },
                else => {},
            }
        }
        const idx = self.lowerExpr(c.args[1]);
        return self.builder.emit(.{ .field_name_get = .{
            .base = .none,
            .index = idx,
            .struct_type = ty,
        } }, .string);
    }
    if (std.mem.eql(u8, name, "@is_comptime")) {
        // True under the comptime interpreter, false in compiled code — the
        // op decides per backend (it can't fold here, since the same IR
        // serves both). Lets stdlib gate a comptime-only diagnostic branch.
        return self.builder.emit(.{ .is_comptime = {} }, .bool);
    }
    if (std.mem.eql(u8, name, "__interp_print_frames")) {
        // Backs `trace.print_interpreter_frames()`: dumps the interp call
        // chain at comptime, no-op in compiled code.
        return self.builder.emit(.{ .interp_print_frames = {} }, .void);
    }
    if (std.mem.eql(u8, name, "__trace_resolve_frame")) {
        // Backs `trace.sx`'s formatter: a raw trace-buffer u64 → a `TraceFrame`.
        // Compiled code reinterprets the operand as `*TraceFrame` and loads it;
        // the interp unpacks (func_id, span.start) and resolves it.
        // Result type is the `TraceFrame` struct from trace.sx.
        const frame_ty = self.module.types.findByName(self.module.types.internString("TraceFrame")) orelse {
            if (self.diagnostics) |d| d.addFmt(.err, null, "`__trace_resolve_frame` needs `TraceFrame` (from trace.sx) in scope", .{});
            return self.builder.constInt(0, .void);
        };
        const arg = self.lowerExpr(c.args[0]);
        return self.builder.emit(.{ .trace_resolve = .{ .operand = arg } }, frame_ty);
    }
    if (std.mem.eql(u8, name, "@errorName")) {
        // `Owner.Member` — the error value's runtime member id read out of the
        // qualified-name table.
        if (c.args.len < 1) return self.builder.constString(self.module.types.internString(""));
        const e = self.lowerExpr(c.args[0]);
        return self.builder.emit(.{ .error_name_get = .{ .operand = e } }, .string);
    }
    if (std.mem.eql(u8, name, "@tag")) {
        if (c.args.len < 1) return self.builder.constUndef(.i32);
        return self.lowerTagOf(c.args[0], c.callee.span);
    }
    if (std.mem.eql(u8, name, "@errorPayload")) {
        if (c.args.len < 1) return self.builder.constInt(0, .any);
        return self.lowerErrorPayload(c.args[0], c.callee.span);
    }
    if (intrinsics.findByName(name)) |id| switch (id) {
        .@"@len", .@"@field", .@"@elementAt" => return lowerBoxedViewIntrinsic(self, id, c),
        else => {},
    };
    if (std.mem.eql(u8, name, "struct_field_value") or std.mem.eql(u8, name, "variant_payload")) {
        // struct_field_value(s, i) → field_value_get (structs/tuples/unions);
        // variant_payload(u, i) → the same instruction on an enum/tagged-union
        // receiver (each case of its runtime switch boxes the live payload).
        // Arrays/vectors/slices are REJECTED — native indexing (`v[i]`) is
        // typed and cheaper; the boxed-element convenience is gone by design.
        if (c.args.len < 2) return self.builder.constInt(0, .any);
        const struct_ty = self.inferExprType(c.args[0]);
        const is_variant_fam = name[0] == 'v';
        if (!struct_ty.isBuiltin() and struct_ty != .unresolved) {
            const ti = self.module.types.get(struct_ty);
            const kind_ok = if (is_variant_fam)
                ti == .@"enum" or ti == .tagged_union
            else
                ti == .@"struct" or ti == .@"union";
            if (!kind_ok) {
                if (self.diagnostics) |d| {
                    if (ti == .slice or ti == .array or ti == .vector) {
                        d.addFmt(.err, c.callee.span, "{s} is not for arrays/vectors — index natively (`v[i]`, typed) instead", .{name});
                    } else if (is_variant_fam) {
                        d.addFmt(.err, c.callee.span, "variant_payload expects an enum or tagged-union value; '{s}' is not one — for struct/tuple fields use struct_field_value", .{self.formatTypeName(struct_ty)});
                    } else {
                        d.addFmt(.err, c.callee.span, "struct_field_value expects a struct or tuple value; '{s}' is an enum — use variant_payload", .{self.formatTypeName(struct_ty)});
                    }
                }
                return self.builder.constInt(0, .any);
            }
        }
        const base_val = self.lowerExpr(c.args[0]);
        const idx = self.lowerExpr(c.args[1]);
        if (struct_ty == .any) {
            // `any` receiver: read THROUGH the view — pure runtime table
            // composition over the 1a machinery (the rt builtins consult the
            // any's tag via reflectArgTypeId):
            //   result.tag  = struct_field_type(tag, i)   (rt_member_type)
            //   result.data = av.data + field_offset(tag, i)
            // For a tagged union the offset table answers the payload offset,
            // so `variant_payload(av, i)` composes identically. A wrong-kind
            // tag or an out-of-range index is UB (same OOB rule as the rest
            // of the runtime field family — the caller gates on the counts).
            const rt_args = self.alloc.dupe(Ref, &.{ base_val, idx }) catch return self.builder.constInt(0, .any);
            const ftag = self.builder.callBuiltin(.rt_member_type, rt_args, .type_value);
            const off = self.builder.callBuiltin(.rt_field_offset, rt_args, .i64);
            const base = self.builder.anyData(base_val, .i64);
            const addr = self.builder.add(base, off, .i64);
            return self.builder.makeAny(ftag, addr);
        }
        // field_value_get takes the receiver's ADDRESS: each case yields an
        // interior VIEW `{field tag, base + offset}` instead of boxing a
        // copy. An addressable lvalue receiver borrows its storage (so a
        // live view aliases later mutations); an rvalue spills to a temp.
        const base_addr = blk: {
            if (!struct_ty.isBuiltin()) {
                if (self.isLvalueExpr(c.args[0]) and !self.isByValueBindingIdent(c.args[0])) {
                    if (self.refStorageAddress(base_val)) |addr| break :blk addr;
                }
                const slot = self.builder.alloca(struct_ty);
                self.builder.store(slot, base_val);
                break :blk slot;
            }
            // Builtin receiver (`any`) — the fields-empty arm never
            // dereferences the base; pass the value through.
            break :blk base_val;
        };
        return self.builder.emit(.{ .field_value_get = .{
            .base = base_addr,
            .index = idx,
            .struct_type = struct_ty,
        } }, .any);
    }
    if (std.mem.eql(u8, name, "any_element")) {
        // any_element(av, elem, idx) → element view into an array/vector held
        // by `av`: pure stride math, `{elem, av.data + idx * size_of(elem)}`.
        // A static `elem` folds its size and tag to constants; a runtime Type
        // reads the rt size table. Bounds are the caller's (same OOB rule as
        // the field family).
        if (c.args.len < 3) return self.builder.constInt(0, .any);
        const av = self.lowerExpr(c.args[0]);
        // The index lowers under its declared i64 param type — an ambient
        // `any` target (this call in return/arg position) must not leak
        // into an `xx` index argument.
        const saved_target = self.target_type;
        self.target_type = .i64;
        const idx = self.lowerExpr(c.args[2]);
        self.target_type = saved_target;
        var tag: Ref = undefined;
        var elem_size: Ref = undefined;
        if (self.isStaticTypeArg(c.args[1])) {
            const elem_ty = self.resolveTypeArg(c.args[1]);
            tag = self.builder.constType(elem_ty);
            elem_size = self.builder.constInt(@intCast(self.module.types.typeSizeBytes(elem_ty)), .i64);
        } else {
            tag = self.lowerExpr(c.args[1]);
            const sz_args = self.alloc.dupe(Ref, &.{tag}) catch return self.builder.constInt(0, .any);
            elem_size = self.builder.callBuiltin(.rt_size_of, sz_args, .i64);
        }
        const stride = self.builder.emit(.{ .mul = .{ .lhs = idx, .rhs = elem_size } }, .i64);
        const base = self.builder.anyData(av, .i64);
        const addr = self.builder.add(base, stride, .i64);
        return self.builder.makeAny(tag, addr);
    }
    if (std.mem.eql(u8, name, "raw_any_data")) {
        // raw_any_data(av) → the view's data pointer (raw `any` layer).
        if (c.args.len < 1) return self.builder.constInt(0, .i64);
        const av = self.lowerExpr(c.args[0]);
        return self.builder.anyData(av, self.module.types.ptrTo(.void));
    }
    if (std.mem.eql(u8, name, "raw_make_any")) {
        // raw_make_any(tp, data) → assemble a view (raw `any` layer, UNCHECKED
        // at runtime: the caller asserts `data` points at a live, aligned
        // value of `tp`). The data arg lowers under its DECLARED param type
        // (*void) — without this, an ambient target (e.g. this call in
        // `-> any` return position) leaks into an `xx` argument and boxes
        // the pointer itself.
        if (c.args.len < 2) return self.builder.constInt(0, .any);
        const tp = if (self.isStaticTypeArg(c.args[0]))
            self.builder.constType(self.resolveTypeArg(c.args[0]))
        else
            self.lowerExpr(c.args[0]);
        const saved_target = self.target_type;
        self.target_type = self.module.types.ptrTo(.void);
        const data = self.lowerExpr(c.args[1]);
        self.target_type = saved_target;
        // REFUSE a non-pointer data operand outright — welding a non-address
        // word (or worse, a 16-byte `any`) into the data slot is never
        // meaningful, and the runtime contract can't catch it.
        const data_ty = self.builder.getRefType(data);
        const data_is_ptr = data_ty == .cstring or (!data_ty.isBuiltin() and switch (self.module.types.get(data_ty)) {
            .pointer, .many_pointer => true,
            else => false,
        });
        if (!data_is_ptr) {
            if (self.diagnostics) |d| {
                d.addFmt(.err, c.args[1].span, "raw_make_any expects a pointer for 'data' (got '{s}') — pass the value's address (`*v`, or a raw_any_data result)", .{self.formatTypeName(data_ty)});
            }
            return self.builder.constInt(0, .any);
        }
        return self.builder.makeAny(tp, data);
    }
    if (std.mem.eql(u8, name, "@typeOf")) {
        // @typeOf(val) — produce a Type value (`.type_value`, a bare i64 handle).
        if (c.args.len < 1) return self.builder.constType(.void);
        const arg_ty = self.inferExprType(c.args[0]);
        if (arg_ty == .any) {
            // Runtime: the held value's type is the view's type_id word
            // (field 1 — the {data, type_id} layout). Read it out AS the
            // 8-byte `.type_value` handle.
            const val = self.lowerExpr(c.args[0]);
            return self.builder.structGet(val, 1, .type_value);
        } else if (self.isOpenSet(arg_ty)) {
            // An open set value answers with the MEMBER it carries, read from
            // its tag word — the set is what the slot is declared as, never
            // what it holds.
            const val = self.lowerExpr(c.args[0]);
            const slot = self.openSetSlotAddress(arg_ty, val, c.args[0]);
            return self.openSetMemberTypeId(arg_ty, slot);
        } else if (self.getProtocolInfo(arg_ty) != null) {
            // A PROTOCOL value answers its CONCRETE type — the type_id
            // word at slot 1, same position as an any's.
            const val = self.lowerExpr(c.args[0]);
            return self.protocolTypeIdWord(val);
        } else {
            return self.builder.constType(arg_ty);
        }
    }
    if (std.mem.eql(u8, name, "struct_field_offset")) {
        // struct_field_offset(T, i) → const_int(byte offset of field i).
        // Layout from the SAME walk typeSizeBytes/fieldOffset use (each field
        // aligned to its own alignment, declaration order). Tuples walk their
        // element types; untagged-union arms overlay at 0.
        if (c.args.len < 2) return self.builder.constInt(0, .i64);
        if (!self.isStaticTypeArg(c.args[0])) {
            // Runtime Type: field-offset table read.
            const tp = self.lowerExpr(c.args[0]);
            const idx = self.lowerExpr(c.args[1]);
            const args_owned = self.alloc.dupe(Ref, &.{ tp, idx }) catch return self.builder.constInt(0, .i64);
            return self.builder.callBuiltin(.rt_field_offset, args_owned, .i64);
        }
        const ty = self.resolveTypeArg(c.args[0]);
        const idx: usize = switch (program_index_mod.foldDimU32(c.args[1], self, 0)) {
            .ok => |n| n,
            else => {
                if (self.diagnostics) |d| d.addFmt(.err, c.args[1].span, "struct_field_offset index must be a non-negative compile-time integer", .{});
                return self.builder.constInt(0, .i64);
            },
        };
        if (!ty.isBuiltin() and ty != .unresolved) {
            const info = self.module.types.get(ty);
            switch (info) {
                .@"struct", .@"union" => {
                    // Fold from the shared walk (`memberOffsetBytes`) — the
                    // same source the runtime tables and the VM answer from.
                    if (self.module.types.memberOffsetBytes(ty, @intCast(idx))) |off| {
                        return self.builder.constInt(@intCast(off), .i64);
                    }
                    const n_fields = self.module.types.memberCount(ty) orelse 0;
                    if (self.diagnostics) |d| d.addFmt(.err, c.args[1].span, "struct_field_offset index {d} out of range ({d} fields)", .{ idx, n_fields });
                    return self.builder.constInt(0, .i64);
                },
                else => {},
            }
        }
        if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "struct_field_offset expects a struct or tuple type; '{s}' is not one", .{self.formatTypeName(ty)});
        return self.builder.constInt(0, .i64);
    }
    if (std.mem.eql(u8, name, "struct_field_type") or std.mem.eql(u8, name, "variant_type") or std.mem.eql(u8, name, "pointee_type")) {
        if (!std.mem.eql(u8, name, "pointee_type") and c.args.len == 2 and !self.isStaticTypeArg(c.args[0])) {
            // Runtime Type: member-type tag table read → Type value.
            const tp = self.lowerExpr(c.args[0]);
            const idx = self.lowerExpr(c.args[1]);
            const args_owned = self.alloc.dupe(Ref, &.{ tp, idx }) catch return self.builder.constType(.void);
            return self.builder.callBuiltin(.rt_member_type, args_owned, .type_value);
        }
        if (!std.mem.eql(u8, name, "pointee_type")) {
            const recv_ty = self.resolveTypeArg(c.args[0]);
            if (!reflectFamilyOk(self, name, recv_ty, c.callee.span)) {
                return self.builder.constType(.unresolved);
            }
        }
        // VALUE-position `field_type(T, i)` / `pointee(P)` — produce a comptime
        // Type value. Both ALSO resolve in TYPE position (a type-arg slot routes
        // through `resolveTypeArg` → `resolveTypeCallWithBindings`); this is the
        // value-position twin (e.g. assigned to a `Type` field like
        // `EnumVariant.payload`, or a `$P: Type` arg's value), folding the index
        // — including an `inline for` loop var — through the SAME
        // `resolveTypeCallWithBindings` so the two positions never disagree.
        // Without this they fall through to generic-function lowering, which
        // can't fold the index → "cannot infer …" / "unknown intrinsic".
        const ty = self.resolveTypeCallWithBindings(c);
        return self.builder.constType(ty);
    }
    if (std.mem.eql(u8, name, "variant_index")) {
        // field_index(T, val) → the SEQUENTIAL variant index for `val`
        // (spec: the inverse of `field_value_int`). For a plain enum with
        // no explicit values — and for a tagged union — the stored tag
        // already IS the ordinal, so returning `enum_tag` is correct. For a
        // payload-less enum with EXPLICIT values the runtime tag is the
        // explicit value (e.g. 7), NOT the ordinal, so it must be
        // reverse-mapped: returning the raw tag fed `field_name(T, tag)` an
        // out-of-range index → out-of-bounds GEP → segfault.
        if (c.args.len < 2) return self.builder.constInt(0, .i64);
        if (!self.isStaticTypeArg(c.args[0])) {
            // Runtime Type: the value travels as an `any` VIEW (a typed
            // second operand can't exist — its type would have to be the
            // runtime T). Rewrites to the pure-sx scan helper (fmt.sx):
            // tag word read via __sx_variant_tag_width + the value table.
            const val_ty = self.inferExprType(c.args[1]);
            if (val_ty != .any) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, c.args[1].span, "variant_index with a runtime Type takes the value as an `any` view (got '{s}') — box it, or spell the type statically", .{self.formatTypeName(val_ty)});
                return self.builder.constInt(0, .i64);
            }
            const callee_node = self.alloc.create(Node) catch return self.builder.constInt(0, .i64);
            callee_node.* = Node{ .data = .{ .identifier = .{ .name = "__sx_variant_index" } }, .span = c.callee.span, .source_file = c.callee.source_file };
            const args = self.alloc.dupe(*Node, &.{ c.args[0], c.args[1] }) catch return self.builder.constInt(0, .i64);
            const syn_call = ast.Call{ .callee = callee_node, .args = args };
            return self.lowerCall(&syn_call);
        }
        const ty = self.resolveTypeArg(c.args[0]);
        const val = self.lowerExpr(c.args[1]);
        const tag = self.builder.emit(.{ .enum_tag = .{ .operand = val } }, .i64);
        if (!ty.isBuiltin()) {
            // Both a payload-less enum (`explicit_values`) and a tagged union
            // (`explicit_tag_values`) can carry EXPLICIT tag values, in which
            // case the runtime tag is the explicit value (e.g. 0x100), NOT the
            // sequential ordinal. `field_name` indexes the name array by
            // ordinal, so returning the raw tag mis-indexes it — a garbage /
            // out-of-range variant name, for plain enums and tagged unions
            // alike. Reverse-map the tag → ordinal for either kind.
            const explicit_vals: ?[]const i64 = switch (self.module.types.get(ty)) {
                .@"enum" => |e| e.explicit_values,
                .tagged_union => |u| u.explicit_tag_values,
                else => null,
            };
            if (explicit_vals) |vals| {
                // Branchless reverse lookup (no `select` op): for each variant
                // i,   acc = acc + (i - acc) * (tag == vals[i] ? 1 : 0)
                // so the matching ordinal replaces acc. Values are unique, so
                // at most one term fires.
                //
                // Seed `acc` with the raw `tag` (the IDENTITY), NOT -1: the
                // spec-inverse of `field_value_int` maps an explicit value back
                // to its ordinal, but if the runtime tag is ALREADY an ordinal
                // (no explicit value equals it) the identity is the correct
                // answer — and it can never index `field_name` out of range the
                // way a `-1` sentinel would (an OOB GEP → crash). A tagged union
                // whose payload variants are call-constructed currently stores
                // the ordinal for those variants rather than the explicit tag
                // (a distinct construction bug); the identity
                // seed keeps their names resolvable here instead of crashing.
                var acc = tag;
                for (vals, 0..) |v, i| {
                    const vc = self.builder.constInt(v, .i64);
                    const is_match = self.builder.cmpEq(tag, vc); // .bool
                    const m = self.builder.widen(is_match, .bool, .i64); // 0 | 1
                    const idx_c = self.builder.constInt(@intCast(i), .i64);
                    const delta = self.builder.sub(idx_c, acc, .i64);
                    const contrib = self.builder.mul(delta, m, .i64);
                    acc = self.builder.add(acc, contrib, .i64);
                }
                return acc;
            }
        }
        // Plain enum / tagged union with AUTO tags: tag already == ordinal.
        return tag;
    }
    if (std.mem.eql(u8, name, "variant_value")) {
        // variant_value(T, i) → the i-th variant's integer value, from the
        // single source `memberValue` (explicit values / explicit tags /
        // ordinal default — enums AND tagged unions).
        if (c.args.len < 2) return self.builder.constInt(0, .i64);
        if (!self.isStaticTypeArg(c.args[0])) {
            // Runtime Type: member-value master-table read (same [N x ptr]
            // pattern as the name/type/offset families).
            const tp = self.lowerExpr(c.args[0]);
            const idx = self.lowerExpr(c.args[1]);
            const args_owned = self.alloc.dupe(Ref, &.{ tp, idx }) catch return self.builder.constInt(0, .i64);
            return self.builder.callBuiltin(.rt_variant_value, args_owned, .i64);
        }
        const ty = self.resolveTypeArg(c.args[0]);
        const idx = self.lowerExpr(c.args[1]);
        if (!ty.isBuiltin()) {
            const explicit: ?[]const i64 = switch (self.module.types.get(ty)) {
                .@"enum" => |e| e.explicit_values,
                .tagged_union => |u| u.explicit_tag_values,
                else => null,
            };
            if (explicit != null) {
                // Explicit values: an array of memberValue rows, indexed at
                // runtime (the index need not be comptime).
                const count = self.module.types.memberCount(ty) orelse 0;
                var elems = std.ArrayList(Ref).empty;
                defer elems.deinit(self.alloc);
                var i: i64 = 0;
                while (i < count) : (i += 1) {
                    const v = self.module.types.memberValue(ty, i) orelse 0;
                    elems.append(self.alloc, self.builder.constInt(v, .i64)) catch unreachable;
                }
                const arr_ty = self.module.types.arrayOf(.i64, @intCast(count));
                const arr = self.builder.structInit(elems.items, arr_ty);
                return self.builder.emit(.{ .index_get = .{ .lhs = arr, .rhs = idx } }, .i64);
            }
        }
        // Auto values: value == ordinal, the index itself.
        return idx;
    }
    if (std.mem.eql(u8, name, "__sx_variant_tag_width")) {
        // INTERNAL: the sign-encoded tag-word width (fmt's runtime variant
        // walk). Static arg folds; runtime Type reads the width table.
        if (c.args.len < 1) return self.builder.constInt(0, .i64);
        if (!self.isStaticTypeArg(c.args[0])) {
            const arg_ref = self.lowerExpr(c.args[0]);
            const args_owned = self.alloc.dupe(Ref, &.{arg_ref}) catch return self.builder.constInt(0, .i64);
            return self.builder.callBuiltin(.rt_variant_tag_width, args_owned, .i64);
        }
        const ty = self.resolveTypeArg(c.args[0]);
        return self.builder.constInt(self.module.types.variantTagWidth(ty), .i64);
    }
    if (std.mem.eql(u8, name, "__sx_slice_len_info")) {
        // INTERNAL: the packed length-word row (fmt's runtime fat-pointer
        // read). Static arg folds; runtime Type reads the row table.
        if (c.args.len < 1) return self.builder.constInt(0, .i64);
        if (!self.isStaticTypeArg(c.args[0])) {
            const arg_ref = self.lowerExpr(c.args[0]);
            const args_owned = self.alloc.dupe(Ref, &.{arg_ref}) catch return self.builder.constInt(0, .i64);
            return self.builder.callBuiltin(.rt_slice_len_info, args_owned, .i64);
        }
        const ty = self.resolveTypeArg(c.args[0]);
        return self.builder.constInt(self.module.types.sliceLenInfo(ty), .i64);
    }
    return null;
}

/// Strict `$T: Type` classification shared by the 7 type-introspection
/// builtins. An argument denotes a type iff it is a spelled /
/// compile-time type or generic type parameter (the `isStaticTypeArg`
/// shapes), or a runtime `Type` value — which is `.type_value`-typed at
/// runtime (`@typeOf(x)`, a `[]Type` element `list[i]`, a `Type`-typed
/// local / field / param). Any other expression — a value of type
/// i64 / f64 / bool / a struct — is NOT a type.
pub fn reflectionArgIsType(self: *Lowering, arg: *const Node) bool {
    if (self.isStaticTypeArg(arg)) return true;
    // Either a bare `Type` value (`.type_value`) or an `Any` that may hold a Type
    // — the boxed reflection path (`case type: type_name(val)` where `val: Any`,
    // the runtime tag deciding). Both are valid reflection arguments.
    const ty = self.inferExprType(arg);
    return ty == .type_value or ty == .any;
}

/// Guard for the type-introspection builtins (`size_of`, `align_of`,
/// `field_count`, `type_name`, `type_eq`, `type_is_unsigned`,
/// `is_flags`): every argument must denote a type. A value argument is
/// rejected with a diagnostic rather than silently reinterpreted as a
/// TypeId index or sized via its `typeof`.
///
/// Returns null when `name` is not a guarded builtin OR every argument
/// is a type (→ fall through to normal dispatch). Returns a harmless
/// result-typed sentinel Ref when a violation was diagnosed; the
/// emitted `.err` gates the build so the value is never observed.
/// Kind gate for the split reflection families. `struct_field_*` accepts
/// struct/tuple/union (and, for count, fieldless scalars fold to 0 at the
/// caller); `variant_*` accepts enum/tagged-union. The other family's kinds
/// get a diagnostic naming the right builtin. Returns false when a
/// diagnostic was emitted (caller returns its neutral constant).
pub fn reflectFamilyOk(self: *Lowering, name: []const u8, ty: TypeId, span: ?ast.Span) bool {
    if (ty.isBuiltin() or ty == .unresolved) return true;
    const info = self.module.types.get(ty);
    const is_variant_fam = name[0] == 'v';
    if (is_variant_fam) {
        if (info == .@"enum" or info == .tagged_union) return true;
        if (self.diagnostics) |d| d.addFmt(.err, span, "{s} expects an enum or tagged-union type; '{s}' is not one — for struct/tuple fields use struct_field_{s}", .{ name, self.formatTypeName(ty), name["variant_".len..] });
        return false;
    }
    switch (info) {
        .@"enum", .tagged_union => {
            if (self.diagnostics) |d| d.addFmt(.err, span, "{s} expects a struct or tuple type; '{s}' is an enum — use variant_{s}", .{ name, self.formatTypeName(ty), name["struct_field_".len..] });
            return false;
        },
        .array, .vector => {
            if (self.diagnostics) |d| d.addFmt(.err, span, "{s} is not for arrays/vectors — use `.len` / native indexing on the value", .{name});
            return false;
        },
        else => return true,
    }
}

/// Each persist primitive takes exactly one argument. Returns null when the
/// call has it, else a `Ref.none` sentinel after diagnosing — the argument
/// handlers index `args[0]` unconditionally.
pub fn persistArity(self: *Lowering, name: []const u8, c: *const ast.Call) ?Ref {
    if (c.args.len == 1) return null;
    if (self.diagnostics) |d|
        d.addFmt(.err, c.callee.span, "{s} takes one argument, got {d}", .{ name, c.args.len });
    return Ref.none;
}

/// The environment `@env_type` / `@env_of` / `@call_ptr` answer for `ty`, or
/// null after diagnosing why it has none. An erased `Closure` is refused by
/// design: it carries an environment instead of being one, which is why
/// `closure` returns it unchanged.
pub fn persistEnvType(self: *Lowering, name: []const u8, ty: TypeId, span: ast.Span) ?TypeId {
    if (lower_closure.envTypeOf(self, ty)) |env| return env;
    if (self.diagnostics) |d| {
        const is_closure = !ty.isBuiltin() and self.module.types.get(ty) == .closure;
        if (is_closure) {
            d.addFmt(.err, span, "{s}: a 'Closure' carries its environment rather than being one — 'closure' returns it unchanged", .{name});
        } else {
            d.addFmt(.err, span, "{s} expects a callable value's type; '{s}' is not one", .{ name, self.formatTypeName(ty) });
        }
    }
    return null;
}

pub fn reflectionTypeArgGuard(self: *Lowering, name: []const u8, c: *const ast.Call) ?Ref {
    const arity: usize = if (std.mem.eql(u8, name, "type_eq"))
        2
    else if (std.mem.eql(u8, name, "size_of") or
        std.mem.eql(u8, name, "align_of") or
        std.mem.eql(u8, name, "struct_field_count") or
        std.mem.eql(u8, name, "variant_count") or
        std.mem.eql(u8, name, "@typeName") or
        std.mem.eql(u8, name, "is_flags"))
        1
    else
        return null;

    var ok = true;
    if (c.args.len != arity) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, c.callee.span, "{s} expects {d} type argument{s}, got {d}", .{
                name, arity, if (arity == 1) @as([]const u8, "") else "s", c.args.len,
            });
        }
        ok = false;
    } else {
        for (c.args) |a| {
            if (self.reflectionArgIsType(a)) continue;
            if (self.diagnostics) |d| {
                if (a.data == .comptime_pack_ref) {
                    d.addFmt(.err, a.span, "'$' introduces a generic parameter only in its declaration; write '{s}' here", .{a.data.comptime_pack_ref.pack_name});
                } else if (a.data == .type_expr and a.data.type_expr.is_generic) {
                    d.addFmt(.err, a.span, "'$' introduces a generic parameter only in its declaration; write '{s}' here", .{a.data.type_expr.name});
                } else {
                    d.addFmt(.err, a.span, "{s} expects a type, got '{s}'", .{
                        name, self.formatTypeName(self.inferExprType(a)),
                    });
                }
            }
            ok = false;
        }
    }
    if (ok) return null;
    return self.reflectionErrorSentinel(name);
}

/// Result-typed placeholder returned after `reflectionTypeArgGuard`
/// diagnoses a non-type argument: a string for `@typeName`, a bool for
/// the predicate builtins, an int for the size / count builtins. Never
/// observed at runtime — the diagnostic already fails the build — but
/// keeps the IR well-typed so lowering can finish and report every
/// error in one pass.
pub fn reflectionErrorSentinel(self: *Lowering, name: []const u8) Ref {
    if (std.mem.eql(u8, name, "@typeName"))
        return self.builder.constString(self.module.types.internString(""));
    if (std.mem.eql(u8, name, "type_eq") or std.mem.eql(u8, name, "is_flags"))
        return self.builder.constBool(false);
    return self.builder.constInt(0, .i64);
}

/// Clone one declared default into this call. Ordinary defaults carry the
/// function author's source so `lowerExpr` resolves their bare names under the
/// signature's authority. `@caller` is the deliberate exception: it is
/// re-authored at the call site, preserving caller file/span/function.
///
/// Either way the call-site provenance is retained, because a `@caller` nested
/// inside a larger default has no other route to the caller's identity.
fn defaultArgAtCall(
    self: *Lowering,
    dflt: *const Node,
    author_source: ?[]const u8,
    call_site: *const Node,
) ?*Node {
    const n = self.alloc.create(Node) catch return null;
    n.* = dflt.*;
    const caller_site = lower.DefaultCallSite{
        .source = call_site.source_file orelse self.current_source_file,
        .span = call_site.span,
        .caller_func = self.builder.func,
        .node = call_site,
    };
    if (dflt.data == .caller_site) {
        n.span = call_site.span;
        n.source_file = call_site.source_file orelse self.current_source_file;
    } else if (author_source orelse self.current_source_file) |src| {
        n.source_file = src;
    }
    self.authored_call_defaults.put(n, caller_site) catch return null;
    return n;
}

/// After args have been lowered, append the lowered values of any
/// `param: T = default_expr` defaults for positions past `args.items.len`.
/// Stops at the first param without a default. Used at method-dispatch
/// sites whose callee is a field_access (so `expandCallDefaults` can't
/// handle them up front). Defaults resolve under the declaration author's
/// source; caller bindings do not implicitly capture into a callee signature.
pub fn appendDefaultArgs(self: *Lowering, fd: *const ast.FnDecl, args: *std.ArrayList(Ref), call_site: *const Node) void {
    if (args.items.len >= fd.params.len) return;
    var i: usize = args.items.len;
    while (i < fd.params.len) : (i += 1) {
        const v = self.lowerDefaultArg(fd, i, call_site) orelse break;
        args.append(self.alloc, v) catch unreachable;
    }
}

/// Lower `fd.params[idx]`'s `= default_expr` at this call site, or null when
/// the param has no default. Generic dot-dispatch cannot use
/// `appendDefaultArgs`: its value-arg list skips type-decl slots, so a param
/// index is not an arg index — it fills each omitted slot by index instead.
pub fn lowerDefaultArg(self: *Lowering, fd: *const ast.FnDecl, idx: usize, call_site: *const Node) ?Ref {
    const dflt = fd.params[idx].default_expr orelse return null;

    // Defaults are argument expressions too: give aggregate/enum/null
    // shorthand the declaration's parameter target instead of leaking an
    // ambient target from the enclosing caller. Resolve the type in the
    // function author's source (resolveDeclParamType owns that pin). The
    // default cannot capture caller locals; contextual values such as
    // `context.allocator` resolve through the implicit context channel.
    var dem = self.enterDemand(lower_bound.paramDemand(self, fd, idx));
    defer dem.restore();
    const authored = defaultArgAtCall(self, dflt, fd.body.source_file, call_site) orelse return null;
    return self.lowerExpr(authored);
}

/// Reject a direct call whose argument count cannot bind to the callee's
/// declared parameter list. `supplied` counts the args as they bind to
/// params — receiver included for dot-dispatch, defaults not
/// appended. Returns true when a diagnostic was emitted (the call must
/// not lower). Pack / comptime / `#compiler` / `intrinsic` callees bind
/// args through their own dispatch and are exempt.
pub fn checkCallArity(self: *Lowering, fd: *const ast.FnDecl, callee_name: []const u8, supplied: usize, has_receiver: bool, span: ast.Span) bool {
    if (hasComptimeParams(fd) or isPackFn(fd)) return false;
    switch (fd.body.data) {
        .intrinsic_expr => return false,
        else => {},
    }
    // Args bind to the params that declare no type parameter of their own:
    // a type-decl slot is filled by inference, and `lowerGenericCall` reads
    // it from the arg list only in the all-slots-spelled form accepted below.
    var min: usize = 0;
    var count: usize = 0;
    // A bare `..` binds no `Param`, so the tail shows in the signature flag
    // rather than in the loop below.
    var variadic = fd.is_c_variadic;
    for (fd.params) |p| {
        if (isTypeParamDecl(&p, fd.type_params)) continue;
        if (p.is_variadic) {
            variadic = true;
            break;
        }
        count += 1;
        if (p.default_expr == null) min = count;
    }
    const max: ?usize = if (variadic) null else count;
    if (supplied >= min and (max == null or supplied <= max.?)) return false;
    if (fd.type_params.len > 0 and supplied == fd.params.len) return false;
    if (self.diagnostics) |d| {
        // Dot-dispatch report counts the user-visible args: the receiver
        // slot is implicit at the call site, so it is elided from both
        // the expected and the supplied counts.
        const recv: usize = @intFromBool(has_receiver);
        const got = supplied -| recv;
        const lo = min -| recv;
        const got_verb: []const u8 = if (got == 1) "was" else "were";
        if (max == null) {
            const s: []const u8 = if (lo == 1) "" else "s";
            d.addFmt(.err, span, "'{s}' expects at least {d} argument{s}, but {d} {s} given", .{ callee_name, lo, s, got, got_verb });
        } else if (max.? -| recv == lo) {
            const s: []const u8 = if (lo == 1) "" else "s";
            d.addFmt(.err, span, "'{s}' expects {d} argument{s}, but {d} {s} given", .{ callee_name, lo, s, got, got_verb });
        } else {
            d.addFmt(.err, span, "'{s}' expects between {d} and {d} arguments, but {d} {s} given", .{ callee_name, lo, max.? -| recv, got, got_verb });
        }
    }
    return true;
}

/// The arity contract a callable VALUE states: how many fixed parameters it
/// binds, whether a per-call-site type pack binds the rest, and whether a
/// C-variadic tail carries them.
const CallableShape = struct {
    fixed: usize,
    pack_start: ?u32 = null,
    is_c_variadic: bool = false,
};

fn fnPointerShape(info: types.TypeInfo.FunctionInfo) CallableShape {
    return .{ .fixed = info.params.len, .pack_start = info.pack_start, .is_c_variadic = info.is_c_variadic };
}

/// Coerce a fn-pointer call's arguments: the fixed prefix to the signature's
/// parameter types, then — past a C-variadic tail — through the default argument
/// promotions and the admissibility rule every C-variadic call site shares.
fn coerceFnPointerCallArgs(self: *Lowering, args: []Ref, info: types.TypeInfo.FunctionInfo) void {
    coerceClosureCallArgs(self, args, info.params);
    if (info.is_c_variadic) self.promoteCVariadicArgs(args, info.params.len);
}

/// Argument validation for a call through a callable VALUE — a closure
/// value or a fn-pointer value — which has no `ast.FnDecl` for the
/// decl-based `checkCallArity` to consume. `shape.fixed` counts the
/// callable TYPE's user-visible params (closure/function type params
/// never include the implicit `__sx_ctx` slot — that is prepended
/// separately per `fnPtrTypeWantsCtx` / `implicit_ctx_enabled`); `args`
/// the lowered user args with tuple/pack spreads already expanded
/// positionally. Two rejections:
///   1. a leftover `Ref.none` spread placeholder — a runtime slice/array
///      spread has no statically-known length to expand and a callable
///      value has no variadic slot to pack into; emitting it would reach
///      the call op as undef (silent garbage);
///   2. an arg-count mismatch — a closure and a fixed fn-pointer type carry
///      no defaults, so their arity is exact; a C-variadic tail bounds only
///      the fixed count from below and takes whatever follows.
/// A pack-variadic callable shape (`Closure(..$args)`, `pack_start !=
/// null`) is skipped entirely, mirroring `checkCallArity`'s `isPackFn`
/// bail — its arity is bound per call site, not by the fixed count.
/// Returns true when a diagnostic was emitted; caller returns Ref.none.
fn checkCallableValueArgs(
    self: *Lowering,
    kind: []const u8,
    name: ?[]const u8,
    args: []const Ref,
    shape: CallableShape,
    c: *const ast.Call,
    span: ast.Span,
) bool {
    if (shape.pack_start != null) return false;
    {
        var buf: [128]u8 = undefined;
        const what: []const u8 = std.fmt.bufPrint(&buf, "a {s}", .{kind}) catch kind;
        if (rejectLeftoverSpreadPlaceholder(self, what, args, c, span)) return true;
    }
    const wrong = if (shape.is_c_variadic) args.len < shape.fixed else args.len != shape.fixed;
    if (wrong) {
        if (self.diagnostics) |d| {
            const s: []const u8 = if (shape.fixed == 1) "" else "s";
            const verb: []const u8 = if (args.len == 1) "was" else "were";
            const at_least: []const u8 = if (shape.is_c_variadic) "at least " else "";
            if (name) |n| {
                d.addFmt(.err, span, "'{s}' expects {s}{d} argument{s}, but {d} {s} given", .{ n, at_least, shape.fixed, s, args.len, verb });
            } else {
                d.addFmt(.err, span, "this {s} expects {s}{d} argument{s}, but {d} {s} given", .{ kind, at_least, shape.fixed, s, args.len, verb });
            }
        }
        return true;
    }
    return false;
}

/// Reject a leftover `Ref.none` spread placeholder in a lowered arg list.
/// The only producer is a runtime slice/array spread
/// that no variadic slot consumed — it has no statically-known length to
/// expand into positional args, and emitting the placeholder would reach
/// the call op as undef (silent garbage). `what` names the callee for the
/// message ("a closure", "a function pointer", "'name'"). Returns true
/// when a diagnostic was emitted; caller returns Ref.none.
fn rejectLeftoverSpreadPlaceholder(self: *Lowering, what: []const u8, args: []const Ref, c: *const ast.Call, span: ast.Span) bool {
    for (args) |a| {
        if (a.isNone()) {
            if (self.diagnostics) |d| {
                // Locate the offending spread arg for the span (the only
                // producer of a leftover placeholder is a spread_expr).
                var sp_span = span;
                for (c.args) |an| {
                    if (an.data == .spread_expr) {
                        sp_span = an.span;
                        break;
                    }
                }
                const id = d.addFmtId(.err, sp_span, "cannot spread this value into {s} — a runtime slice/array has no statically-known length to expand into positional arguments", .{what});
                d.addHelpFmt(id, sp_span, null, "spread a tuple (or a comptime pack) instead, or pass the elements individually", .{});
            }
            return true;
        }
    }
    return false;
}

/// True when `fd` declares a variadic param (any surface form —
/// `name: ..T`, the slice variadic `..name: []T`, or an extern
/// C `...` tail): its call sites legitimately carry a spread placeholder
/// into `packVariadicCallArgs`, so the leftover-placeholder rejection
/// must not fire for it.
fn fnDeclHasVariadicParam(fd: *const ast.FnDecl) bool {
    for (fd.params) |p| {
        if (p.is_variadic) return true;
    }
    return false;
}

/// When a bare-identifier call omits trailing positional args and the
/// callee's signature provides defaults for them, return a fresh Call
/// node with the defaults filled in. Returns null when no expansion is
/// needed (callee unknown, all args provided, or no defaults available).
/// The callee declaration a named-argument call maps against, plus how many
/// leading params the call shape binds implicitly (1 for a value-receiver
/// method/ufcs dot-call and for a callable-nominal value, else 0).
const NamedCallee = struct {
    fd: *const ast.FnDecl,
    source: ?[]const u8,
    receiver_params: usize,
};

/// The callee expression is the receiver, so mapping starts past `call`'s first param.
fn namedNominalCallee(self: *Lowering, ty: TypeId) ?NamedCallee {
    const cn = self.callableNominalThrough(ty) orelse return null;
    return .{ .fd = cn.fd, .source = cn.fd.body.source_file, .receiver_params = 1 };
}

/// Resolve the declaration whose parameter NAMES a named-argument call binds
/// against. Mirrors `expandCallDefaults`' author resolution (bare/qualified/
/// static-struct/enum-literal callees) and adds the value-receiver dot-call
/// shapes (plain-struct method, ufcs fn — an alias resolves names against the
/// TARGET's declared params) and a callable-nominal VALUE (maps against its
/// `call`, past the receiver). Null when no declaration is known (closure /
/// fn-pointer values, builtins, interface methods) — those bind positionally
/// only.
fn namedCalleeDecl(
    self: *Lowering,
    c: *const ast.Call,
    sel_author: ?*const SelectedFunc,
    qualified_selected: bool,
    qualified_callable: ?GlobalInfo,
    author_declines: bool,
) ?NamedCallee {
    switch (c.callee.data) {
        .identifier => |id| {
            if (self.scope) |scope| {
                if (scope.lookupNearest(id.name)) |near| switch (near) {
                    .binding => |b| {
                        if (namedNominalCallee(self, b.ty)) |nc| return nc;
                        if (callableLocalShadow(self, id.name)) return null;
                    },
                    .local_fn => {},
                };
            }
            if (!author_declines) {
                if (sel_author) |sf| return .{ .fd = sf.decl, .source = sf.source, .receiver_params = 0 };
                const eff_name = blk: {
                    const scoped = if (self.scope) |scope| scope.lookupFn(id.name) orelse id.name else id.name;
                    if (self.ufcsAliasTarget(id.name)) |target| {
                        break :blk if (self.scope) |scope| scope.lookupFn(target) orelse target else target;
                    }
                    break :blk scoped;
                };
                if (self.program_index.fn_ast_map.get(eff_name)) |fd| {
                    return .{ .fd = fd, .source = fd.body.source_file, .receiver_params = 0 };
                }
            }
            if (self.globalValueRef(id.name)) |gi| return namedNominalCallee(self, gi.ty);
            return null;
        },
        .field_access => |fa| {
            // A namespace-selected callable value maps against its `call`. A
            // qualified Closure has no names.
            if (qualified_callable) |gi| return namedNominalCallee(self, gi.ty);
            if (qualified_selected) return .{ .fd = sel_author.?.decl, .source = sel_author.?.source, .receiver_params = 0 };
            if (!self.callResolver().objectIsValue(fa.object)) {
                switch (self.staticStructHead(fa.object)) {
                    .resolved => |owner_ty| {
                        if (self.plainStructMethod(owner_ty, fa.field)) |method| {
                            return .{ .fd = method.fd, .source = method.fd.body.source_file, .receiver_params = 0 };
                        }
                        return null;
                    },
                    .ambiguous, .not_visible => return null,
                    .none => {},
                }
                const obj_name: ?[]const u8 = switch (fa.object.data) {
                    .identifier => |oid| oid.name,
                    .type_expr => |te| te.name,
                    else => null,
                };
                if (obj_name) |name| {
                    if (!self.identifierBindsVisibleValue(name)) {
                        const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ name, fa.field }) catch fa.field;
                        if (self.program_index.fn_ast_map.get(qualified) orelse self.program_index.fn_ast_map.get(fa.field)) |fd| {
                            return .{ .fd = fd, .source = fd.body.source_file, .receiver_params = 0 };
                        }
                        return null;
                    }
                }
            }
            // A callable field maps against its own declaration. A Closure /
            // fn-pointer / unique field has no names.
            const recv_ty = self.inferExprType(fa.object);
            switch (self.lookupField(recv_ty, fa.field)) {
                .hit, .private => |h| if (self.callableShapeOf(h.ty) != null) return namedNominalCallee(self, h.ty),
                .missing => {},
            }
            // Value receiver: `obj.m(args)` binds the first param to `obj`.
            var obj_ty = recv_ty;
            if (!obj_ty.isBuiltin()) {
                const oi = self.module.types.get(obj_ty);
                if (oi == .pointer) obj_ty = oi.pointer.pointee;
            }
            if (self.plainStructMethod(obj_ty, fa.field)) |method| {
                return .{ .fd = method.fd, .source = method.fd.body.source_file, .receiver_params = 1 };
            }
            const eff = blk: {
                if (self.ufcsAliasTarget(fa.field)) |target| {
                    break :blk if (self.scope) |scope| scope.lookupFn(target) orelse target else target;
                }
                break :blk if (self.scope) |scope| scope.lookupFn(fa.field) orelse fa.field else fa.field;
            };
            if (self.program_index.fn_ast_map.get(eff)) |fd| {
                if (fd.is_ufcs or self.ufcsAliasTarget(fa.field) != null) {
                    return .{ .fd = fd, .source = fd.body.source_file, .receiver_params = 1 };
                }
            }
            return null;
        },
        .enum_literal => |el| {
            const tgt = self.target_type orelse return null;
            const method = self.plainStructMethod(tgt, el.name) orelse return null;
            return .{ .fd = method.fd, .source = method.fd.body.source_file, .receiver_params = 0 };
        },
        else => return namedNominalCallee(self, self.inferExprType(c.callee)),
    }
}

/// A parameter of type `pty` is an ERASED closure slot — `Closure(…)` itself or
/// the child of an optional one. Such a slot takes no trailing block: erasing a
/// block is an allocation, written where it is paid.
fn isClosureSlot(self: *Lowering, pty: TypeId) bool {
    if (pty.isBuiltin()) return false;
    const info = self.module.types.get(pty);
    if (info == .closure) return true;
    return info == .optional and !info.optional.child.isBuiltin() and
        self.module.types.get(info.optional.child) == .closure;
}

/// Strip `named_arg` wrappers in place of a failed mapping: downstream
/// lowering sees each value as a plain positional node (the build aborts on
/// the mapping diagnostic before codegen; this only prevents an
/// unknown-node cascade).
fn stripNamedArgs(self: *Lowering, c: *const ast.Call) *ast.Call {
    var new_args = std.ArrayList(*Node).empty;
    for (c.args) |a| switch (a.data) {
        .named_arg => |na| new_args.append(self.alloc, na.value) catch unreachable,
        // A failed trailing block DROPS from the stripped call — keeping it
        // as a phantom positional arg would stack an arity error on top of
        // the mapping diagnostic.
        .trailing_block => {},
        else => new_args.append(self.alloc, a) catch unreachable,
    };
    const new_call = self.alloc.create(ast.Call) catch unreachable;
    new_call.* = .{ .callee = c.callee, .args = new_args.toOwnedSlice(self.alloc) catch unreachable };
    return new_call;
}

/// Levenshtein distance for the unknown-name did-you-mean suggestion.
fn editDistance(alloc: std.mem.Allocator, a: []const u8, b: []const u8) usize {
    var prev = alloc.alloc(usize, b.len + 1) catch return a.len + b.len;
    defer alloc.free(prev);
    var cur = alloc.alloc(usize, b.len + 1) catch return a.len + b.len;
    defer alloc.free(cur);
    for (prev, 0..) |*p, j| p.* = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            cur[j + 1] = @min(@min(cur[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        std.mem.swap([]usize, &prev, &cur);
    }
    return prev[b.len];
}

/// Named-argument mapping pass (specs: Named Arguments). Runs at `lowerCall`
/// entry BEFORE default expansion: rewrites a call carrying `name = value`
/// args into a purely positional call in declaration order, filling skipped
/// defaulted params from their declarations (same authored-default mechanics
/// as `expandCallDefaults`). Returns null when the call has no named args.
/// Every mapping error diagnoses here and returns the call with the named
/// wrappers stripped, so downstream lowering never sees a `named_arg` node.
///
/// Rules enforced: positional-then-named; per-param at-most-once (positional
/// overlap and receiver overlap included); unknown name with did-you-mean;
/// positional-only zones (variadic tails, packs, comptime `$` params);
/// missing required params reported by name. A positional overflow past a
/// variadic param keeps flowing into the tail as before.
pub fn mapNamedArgs(
    self: *Lowering,
    c: *const ast.Call,
    sel_author: ?*const SelectedFunc,
    qualified_selected: bool,
    qualified_callable: ?GlobalInfo,
    author_declines: bool,
) ?*ast.Call {
    var any_named = false;
    var has_block = false;
    for (c.args) |a| {
        if (a.data == .named_arg) any_named = true;
        if (a.data == .trailing_block) has_block = true;
    }
    if (!any_named and !has_block) return null;

    const callee_name: []const u8 = switch (c.callee.data) {
        .identifier => |id| id.name,
        .field_access => |fa| fa.field,
        .enum_literal => |el| el.name,
        else => "callee",
    };
    const callee = namedCalleeDecl(self, c, sel_author, qualified_selected, qualified_callable, author_declines) orelse {
        if (self.diagnostics) |d| {
            if (has_block) {
                d.addFmt(.err, c.callee.span, "cannot use a trailing block here — '{s}' has no known declaration (closure and function-pointer values bind their arguments explicitly)", .{callee_name});
            } else {
                d.addFmt(.err, c.callee.span, "cannot use named arguments here — '{s}' has no known parameter names (closure and function-pointer values, builtins, and interface methods bind positionally)", .{callee_name});
            }
        }
        return stripNamedArgs(self, c);
    };
    const fd = callee.fd;
    const off = callee.receiver_params;
    const nparams = fd.params.len;

    const slots = self.alloc.alloc(?*Node, nparams) catch return stripNamedArgs(self, c);
    for (slots) |*s| s.* = null;
    var tail = std.ArrayList(*Node).empty;
    var variadic_idx: ?usize = null;
    for (fd.params, 0..) |p, i| {
        if (p.is_variadic) {
            variadic_idx = i;
            break;
        }
    }

    var pos: usize = off;
    var seen_named = false;
    var errored = false;
    // Named bindings in WRITTEN order (param index + value) — consumed by
    // the displacement check below.
    var named_seq = std.ArrayList(struct { i: usize, v: *Node }).empty;
    defer named_seq.deinit(self.alloc);
    for (c.args) |a| {
        switch (a.data) {
            .named_arg => |na| {
                seen_named = true;
                var idx: ?usize = null;
                for (fd.params, 0..) |p, i| {
                    if (std.mem.eql(u8, p.name, na.name)) {
                        idx = i;
                        break;
                    }
                }
                const i = idx orelse {
                    errored = true;
                    if (self.diagnostics) |d| {
                        var best: ?[]const u8 = null;
                        // Suggest only near-misses; scale with name length so a
                        // short name never matches a distant one.
                        var best_dist: usize = @max(1, na.name.len / 3) + 1;
                        for (fd.params) |p| {
                            const dist = editDistance(self.alloc, p.name, na.name);
                            if (dist < best_dist) {
                                best_dist = dist;
                                best = p.name;
                            }
                        }
                        if (best) |b| {
                            d.addFmt(.err, a.span, "'{s}' has no parameter named '{s}' — did you mean '{s}'?", .{ callee_name, na.name, b });
                        } else {
                            d.addFmt(.err, a.span, "'{s}' has no parameter named '{s}'", .{ callee_name, na.name });
                        }
                    }
                    continue;
                };
                const p = fd.params[i];
                if (p.is_variadic or p.is_pack) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "variadic parameter '{s}' cannot be bound by name — a variadic tail is positional-only", .{p.name});
                    continue;
                }
                if (p.is_comptime) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "comptime parameter '${s}' cannot be bound by name — comptime `$` parameters bind through the type/value argument machinery", .{p.name});
                    continue;
                }
                if (i < off) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "parameter '{s}' is already bound by the receiver of this call", .{p.name});
                    continue;
                }
                if (slots[i] != null or i < pos) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "parameter '{s}' is bound more than once", .{p.name});
                    continue;
                }
                slots[i] = na.value;
                named_seq.append(self.alloc, .{ .i = i, .v = na.value }) catch {};
            },
            .spread_expr => {
                errored = true;
                if (self.diagnostics) |d|
                    d.addFmt(.err, a.span, "a spread argument cannot be combined with named arguments — pass the call positionally", .{});
            },
            .trailing_block => |tb| {
                // Trailing block binds the callee's LAST declared parameter
                // (specs: Trailing Blocks): a non-variadic Closure whose
                // parameters the block's header spells (an optional closure
                // slot wraps like any named closure argument), rejected as a
                // duplicate against a named or positional binding of the same
                // parameter.
                if (nparams == off) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "'{s}' cannot take a trailing block — it has no parameters", .{callee_name});
                    continue;
                }
                const last = nparams - 1;
                const p = fd.params[last];
                if (p.is_variadic or p.is_pack) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "'{s}' cannot take a trailing block — its last parameter '..{s}' is variadic; a variadic tail binds positionally", .{ callee_name, p.name });
                    continue;
                }
                const pty = self.resolveDeclParamType(fd, last);
                const block_params = tb.lambda.data.lambda.params;
                // Dual bind (spec §7.1): a `$B/@BuildBlock(P)` last parameter
                // makes the SAME source block a build block instead of a
                // closure. A build block is replayed against a sink, not
                // called, so it takes no header. Asked through the shared
                // classifier: the binder may already be bound to an
                // implementor at this call (a block forwarded from the
                // caller), and that is still a block parameter.
                if (self.blockProtocolOf(pty) != null) {
                    // The refused header still binds: an unbound block
                    // parameter reports a second time as a missing one.
                    if (tb.has_header) {
                        errored = true;
                        if (self.diagnostics) |d|
                            d.addFmt(.err, a.span, "'{s}' takes a build block for '{s}' — a build block has no parameter header", .{ callee_name, p.name });
                    }
                    if (last < pos) {
                        errored = true;
                        if (self.diagnostics) |d|
                            d.addFmt(.err, a.span, "parameter '{s}' is bound both by a positional argument and by the trailing block", .{p.name});
                        continue;
                    }
                    if (slots[last] != null) {
                        errored = true;
                        if (self.diagnostics) |d|
                            d.addFmt(.err, a.span, "parameter '{s}' is bound both by a named argument and by the trailing block", .{p.name});
                        continue;
                    }
                    slots[last] = tb.lambda;
                    continue;
                }
                // A `$F/(…) -> R` last parameter names the block's signature in
                // its bound, not in a type: the binder takes the block's own
                // unique type, so the arity comes from the bound's spelling.
                // Nothing else binds a block — an erased `Closure` slot least of
                // all, since erasing one is an allocation.
                const want = if (lower_bound.boundCallableSig(self, fd.params[last].type_expr)) |sig|
                    sig.params.len
                else {
                    errored = true;
                    if (self.diagnostics) |d| {
                        const id = d.addFmtId(.err, a.span, "'{s}' cannot take a trailing block — its last parameter '{s}' is '{s}', which is neither `$F/(…) -> R` nor `@BuildBlock(P)`", .{ callee_name, p.name, self.formatTypeName(pty) });
                        if (isClosureSlot(self, pty))
                            d.addHelpFmt(id, a.span, null, "erasing a block is an allocation, so it is written where it is paid: `{s}(closure(|…| …))`", .{callee_name})
                        else
                            d.addHelpFmt(id, a.span, null, "declare '{s}' as `$F/(…) -> R` to receive the block as a closure, or as `@BuildBlock(P)` to receive it as a build block", .{p.name});
                    }
                    continue;
                };
                if (want != block_params.len) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "'{s}' takes {d} parameter{s} in the block for '{s}' — its header binds {d}", .{ callee_name, want, if (want == 1) @as([]const u8, "") else "s", p.name, block_params.len });
                    continue;
                }
                if (last < pos) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "parameter '{s}' is bound both by a positional argument and by the trailing block", .{p.name});
                    continue;
                }
                if (slots[last] != null) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "parameter '{s}' is bound both by a named argument and by the trailing block", .{p.name});
                    continue;
                }
                slots[last] = tb.lambda;
            },
            else => {
                if (seen_named) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "positional argument after a named argument — name it or move it before the named arguments", .{});
                    continue;
                }
                if (variadic_idx != null and pos >= variadic_idx.?) {
                    tail.append(self.alloc, a) catch {};
                    continue;
                }
                if (pos >= nparams) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "too many positional arguments in call to '{s}' — it has {d} parameter{s}", .{ callee_name, nparams - off, if (nparams - off == 1) @as([]const u8, "") else "s" });
                    continue;
                }
                slots[pos] = a;
                pos += 1;
            },
        }
    }
    // Evaluation order is written order. The rewrite hands the call
    // machinery param-ordered nodes, so when the named values' param indices
    // are not already ascending, evaluate EVERY argument now — positional
    // and named, in written order, each typed by its param's declaration —
    // and record node → ref; `lowerExpr` returns the recorded ref when the
    // machinery reaches the node. Exempt shapes keep declaration-order
    // evaluation: value-receiver calls (the receiver must evaluate first
    // and lowers inside dispatch), and generic / comptime / pack / variadic
    // callees (their args bind through their own dispatch machinery).
    var displaced = false;
    for (named_seq.items, 0..) |e, k| {
        if (k > 0 and e.i < named_seq.items[k - 1].i) displaced = true;
    }
    if (!errored and displaced and off == 0 and variadic_idx == null and
        fd.type_params.len == 0 and !hasComptimeParams(fd) and !isPackFn(fd))
    {
        var hoist_pos: usize = 0;
        for (c.args) |a| {
            // A trailing block is written last and binds the last param —
            // never displaced; its lambda lowers at the machinery position.
            if (a.data == .trailing_block) continue;
            const bind: struct { i: usize, v: *Node } = switch (a.data) {
                .named_arg => |na| blk: {
                    for (fd.params, 0..) |p, i| {
                        if (std.mem.eql(u8, p.name, na.name)) break :blk .{ .i = i, .v = na.value };
                    }
                    unreachable; // unknown names errored above
                },
                else => blk: {
                    defer hoist_pos += 1;
                    break :blk .{ .i = hoist_pos, .v = a };
                },
            };
            var dem = self.enterDemand(lower_bound.paramDemand(self, fd, bind.i));
            const ref = self.lowerExpr(bind.v);
            dem.restore();
            self.precomputed_args.put(bind.v, ref) catch {};
        }
    }

    // Fill skipped defaulted params; report missing required ones BY NAME.
    // This runs on the ERRORED path too: the rewritten call stays
    // arity-complete (defaults + undef holes), so the mapping diagnostic is
    // the only error — never a checkCallArity cascade on top. The build
    // aborts before codegen either way.
    var missing = std.ArrayList([]const u8).empty;
    defer missing.deinit(self.alloc);
    for (fd.params[off..], off..) |p, i| {
        if (slots[i] != null) continue;
        if (p.is_variadic or p.is_pack) continue; // an empty tail is legal
        if (p.default_expr) |def| {
            slots[i] = defaultArgAtCall(self, def, callee.source, c.callee) orelse return stripNamedArgs(self, c);
        } else {
            missing.append(self.alloc, p.name) catch {};
            const undef = self.alloc.create(Node) catch unreachable;
            undef.* = .{ .span = c.callee.span, .data = .undef_literal };
            slots[i] = undef;
        }
    }
    if (!errored and missing.items.len > 0) {
        if (self.diagnostics) |d| {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.alloc);
            for (missing.items, 0..) |name, i| {
                if (i > 0) buf.appendSlice(self.alloc, ", ") catch {};
                buf.append(self.alloc, '\'') catch {};
                buf.appendSlice(self.alloc, name) catch {};
                buf.append(self.alloc, '\'') catch {};
            }
            const s: []const u8 = if (missing.items.len == 1) "" else "s";
            d.addFmt(.err, c.callee.span, "call to '{s}' is missing required parameter{s} {s}", .{ callee_name, s, buf.items });
        }
    }

    var new_args = std.ArrayList(*Node).empty;
    for (fd.params[off..], off..) |p, i| {
        if (p.is_variadic) break;
        new_args.append(self.alloc, slots[i].?) catch return stripNamedArgs(self, c);
    }
    for (tail.items) |a| new_args.append(self.alloc, a) catch {};
    const new_call = self.alloc.create(ast.Call) catch return stripNamedArgs(self, c);
    new_call.* = .{ .callee = c.callee, .args = new_args.toOwnedSlice(self.alloc) catch return stripNamedArgs(self, c) };
    return new_call;
}

pub fn expandCallDefaults(
    self: *Lowering,
    c: *const ast.Call,
    sel_author: ?*const SelectedFunc,
    qualified_selected: bool,
    author_declines: bool,
) ?*ast.Call {
    const fd = blk: {
        switch (c.callee.data) {
            .identifier => |id| {
                const eff_name = blk2: {
                    const scoped = if (self.scope) |scope| scope.lookupFn(id.name) orelse id.name else id.name;
                    if (self.ufcsAliasTarget(id.name)) |target| {
                        break :blk2 if (self.scope) |scope| scope.lookupFn(target) orelse target else target;
                    }
                    break :blk2 scoped;
                };
                // For a genuine flat same-name
                // collision the omitted trailing args are filled from the
                // author the call resolver selected — its `*FnDecl` defaults —
                // not the first-wins winner's. lowering consumes the ONE author
                // verdict (`selectedFreeAuthor`, computed once in `lowerCall`)
                // rather than re-resolving the name, so default expansion and
                // dispatch agree on the author. `.ambiguous` declines to expand
                // (the call path emits the single diagnostic); a non-collision
                // call keeps the first-wins winner. Reading `.decl` only keeps
                // `materialized` null — inspecting defaults must not lower the
                // author.
                if (author_declines) return null;
                if (sel_author) |sf| break :blk sf.decl;
                // A callable LOCAL binding shadows the top-level fn: the
                // shadowed-out global's defaults must
                // not expand — their exprs' side effects would run and the
                // spliced args would reach the local's call_indirect as
                // phantom extras.
                if (callableLocalShadow(self, id.name)) return null;
                break :blk self.program_index.fn_ast_map.get(eff_name) orelse return null;
            },
            // Namespace call `mod.fn(args)` — args map directly to params
            // (no `self` prepend), so default expansion is the same shape as
            // a bare call. A METHOD call `value.method(args)` prepends `self`
            // (arg/param counts are offset), so it's excluded: only treat the
            // receiver as a namespace when it isn't a value in scope.
            .field_access => |fa| {
                // An exact namespace author was selected once at lowerCall's
                // entry. Its declaration is the sole source of defaults; do
                // not rediscover the path through qualified/bare maps here.
                if (qualified_selected) break :blk sel_author.?.decl;
                // Static plain-struct methods need their OWN author's defaults.
                // Selecting after global expansion is too late: the wrong AST
                // default may already have been evaluated and appended.
                if (!self.callResolver().objectIsValue(fa.object)) {
                    switch (self.staticStructHead(fa.object)) {
                        .resolved => |owner_ty| {
                            if (self.plainStructMethod(owner_ty, fa.field)) |method| break :blk method.fd;
                            if (self.hasPlainStructAuthor(owner_ty)) return null;
                        },
                        // A doomed type head must not splice (and later
                        // evaluate) a default from an unrelated global winner.
                        .ambiguous, .not_visible => return null,
                        .none => {},
                    }
                }
                const obj_name: ?[]const u8 = switch (fa.object.data) {
                    .identifier => |id| id.name,
                    .type_expr => |te| te.name,
                    else => null,
                };
                const name = obj_name orelse return null;
                if (self.identifierBindsVisibleValue(name)) return null;
                const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ name, fa.field }) catch fa.field;
                break :blk self.program_index.fn_ast_map.get(qualified) orelse self.program_index.fn_ast_map.get(fa.field) orelse return null;
            },
            .enum_literal => |el| {
                const tgt = self.target_type orelse return null;
                const method = self.plainStructMethod(tgt, el.name) orelse return null;
                break :blk method.fd;
            },
            else => return null,
        }
    };
    // Param slots the written args actually consume:
    // a spread arg supplies its operand's WIDTH, not one — a 2-tuple spread
    // into `(a: i64, b: i64 = 99)` supplies BOTH params, so no default may be
    // filled (counting the spread node as one arg filled `b`'s default on top
    // and over-supplied the call into an arity error). A spread whose width
    // is not statically known (runtime slice, unresolvable operand) declines
    // the expansion entirely — the arity check / variadic packing downstream
    // then judges the un-expanded call honestly.
    var supplied: usize = 0;
    for (c.args) |a| {
        if (a.data == .spread_expr) {
            supplied += spreadArgWidth(self, a.data.spread_expr.operand) orelse return null;
        } else {
            supplied += 1;
        }
    }
    if (supplied >= fd.params.len) return null;
    var end: usize = supplied;
    while (end < fd.params.len) : (end += 1) {
        if (fd.params[end].default_expr == null) break;
    }
    if (end == supplied) return null;

    const fill = end - supplied;
    var new_args = self.alloc.alloc(*ast.Node, c.args.len + fill) catch return null;
    for (c.args, 0..) |arg, i| new_args[i] = arg;
    var i: usize = 0;
    const default_source: ?[]const u8 = if (sel_author) |sf| sf.source else fd.body.source_file;
    while (i < fill) : (i += 1) {
        const def = fd.params[supplied + i].default_expr.?;
        new_args[c.args.len + i] = defaultArgAtCall(self, def, default_source, c.callee) orelse return null;
    }
    const new_call = self.alloc.create(ast.Call) catch return null;
    new_call.* = .{ .callee = c.callee, .args = new_args };
    return new_call;
}

/// Statically-known number of positional args a spread operand expands to:
/// a comptime pack's arity, a tuple's field count, or a fixed array's
/// length. Null when the width is unknowable at compile time (runtime
/// slice, unresolved operand) — callers must decline rather than guess.
fn spreadArgWidth(self: *Lowering, operand: *const Node) ?usize {
    if (operand.data == .identifier) {
        if (self.pack_param_count) |ppc| {
            if (ppc.get(operand.data.identifier.name)) |n| return n;
        }
    }
    const op_ty = self.inferExprType(operand);
    if (op_ty.isBuiltin()) return null;
    const info = self.module.types.get(op_ty);
    return switch (info) {
        .@"struct" => |s| s.fields.len,
        .array => |a| a.length,
        else => null,
    };
}

/// Resolve parameter types for a call expression (for target_type context).
/// Returns empty slice if the function can't be resolved.
/// Return the param types of a Function from the caller's POV — i.e.
/// skipping the synthetic `__sx_ctx` slot when present. lowerCall's
/// arg-lowering uses these to set `target_type` per arg, and user
/// args don't include `__sx_ctx`, so the slot must be elided.
pub fn userParamTypes(self: *Lowering, func: *const Function) []TypeId {
    const start: usize = if (func.has_implicit_ctx) 1 else 0;
    var types_list = std.ArrayList(TypeId).empty;
    if (func.params.len > start) {
        for (func.params[start..]) |p| {
            types_list.append(self.alloc, p.ty) catch unreachable;
        }
    }
    return types_list.items;
}

/// Param types of a not-yet-lowered AST callee for arg target-typing,
/// resolved in the callee's own module context (the source pin — see
/// `resolveParamTypeInSource`). A generic callee's bare `T` leaves mean
/// nothing as nominal names in that module: without this call's inferred
/// `$T → concrete` bindings the pin would resolve `T` as an undeclared
/// type in a non-main module and diagnose it unknown.
/// Coerce already-lowered closure-call arguments to the closure's declared
/// parameter types. The arg-lowering loop only sets `target_type`
/// (which steers literal lowering) but does NOT itself coerce, so a concrete
/// `7` flowing into a `?i64` param would reach `call_closure` as a bare `i64`
/// (read ABSENT by the callee) and a `null` as a bare pointer (LLVM verifier
/// failure). `args` are the USER args (no implicit ctx); `params` the closure's
/// user-visible param types. Coerces in place.
fn coerceClosureCallArgs(self: *Lowering, args: []Ref, params: []const TypeId) void {
    const n = @min(args.len, params.len);
    for (0..n) |i| {
        if (args[i].isNone()) continue; // spread placeholder
        const at = self.builder.getRefType(args[i]);
        if (at != params[i]) args[i] = self.coerceToType(args[i], at, params[i]);
    }
}

/// Type parameters the method declares that the INSTANCE's bindings do not
/// cover: a generic-instance method may spell binders of its own
/// (`expression :: (self: *Sink($T), value: $I/@Init($V/T))`), and those bind
/// from the call's arguments, not from the instantiation.
fn instanceMethodNeedsArgBinding(gm: lower_generic.GenericStructMethod) bool {
    for (gm.fd.type_params) |tp| {
        if (tp.is_variadic) continue;
        if (!gm.bindings.contains(tp.name)) return true;
    }
    return false;
}

fn astCalleeParamTypes(self: *Lowering, fd: *const ast.FnDecl, args: []const *const Node) []const ParamDemand {
    var gbindings: ?std.StringHashMap(TypeId) = null;
    defer if (gbindings) |*gb| gb.deinit();
    var binding_scope: ?generics_mod.TypeBindingScope = null;
    defer if (binding_scope) |*bs| bs.exit();
    if (fd.type_params.len > 0) {
        gbindings = self.genericResolver().buildTypeBindings(fd, args);
        binding_scope = generics_mod.installTypeBindings(self, gbindings.?);
    }
    var demands = std.ArrayList(ParamDemand).empty;
    for (fd.params, 0..) |_, param_idx| {
        demands.append(self.alloc, lower_bound.paramDemand(self, fd, param_idx)) catch unreachable;
    }
    return demands.items;
}

/// Whether a ufcs declaration's FIRST parameter takes this receiver. The bare
/// field name is shared with every same-named ufcs in the program, so the
/// receiver is what says which declaration a dot-call names. A binder receiver
/// (`self: $T`) takes any.
fn receiverFits(self: *Lowering, obj_ty: TypeId, receiver: ParamDemand) bool {
    const want = receiver.coerceType() orelse return false;
    if (want == .unresolved) return true;
    return peelPointers(self, want) == peelPointers(self, obj_ty);
}

/// The type under any `*` layers — a receiver's identity is its core type.
fn peelPointers(self: *Lowering, ty: TypeId) TypeId {
    var t = ty;
    while (!t.isBuiltin()) {
        const info = self.module.types.get(t);
        if (info != .pointer) break;
        t = info.pointer.pointee;
    }
    return t;
}

/// A slot list that carries no declaration — an already-lowered signature, a
/// closure value, a protocol method — demands a plain coercion at every slot.
fn coerceDemands(self: *Lowering, tys: []const TypeId) []const ParamDemand {
    const out = self.alloc.alloc(ParamDemand, tys.len) catch return &.{};
    for (tys, 0..) |t, i| out[i] = .{ .coerce = t };
    return out;
}

pub fn resolveCallParamTypes(
    self: *Lowering,
    c: *const ast.Call,
    sel_author: ?*SelectedFunc,
    qualified_selected: bool,
    qualified_callable: ?GlobalInfo,
    author_declines: bool,
) []const ParamDemand {
    // Target-typed static method shorthand (`.make(args)` where the expected
    // type is a struct) has no receiver: every declared param is supplied by
    // the written args, exactly like `Type.make(args)`.
    if (c.callee.data == .enum_literal) {
        const tgt = self.target_type orelse return &.{};
        const method = self.plainStructMethod(tgt, c.callee.data.enum_literal.name) orelse return &.{};
        return astCalleeParamTypes(self, method.fd, c.args);
    }
    // Method calls: obj.method(args) — resolve param types from the method signature,
    // skipping the first param (self) since it's prepended later.
    if (c.callee.data == .field_access) {
        const fa = c.callee.data.field_access;

        // An exactly-selected namespace global keeps its callable type and
        // source identity; no same-name bare/global lookup participates.
        if (qualified_callable) |global| {
            if (self.callableSigOf(global.ty)) |sig| return coerceDemands(self, sig.params);
            return &.{};
        }

        // Exact namespace selection precedes every name-keyed signature path.
        // Args map directly to all declared params (no receiver prepend).
        if (qualified_selected) return astCalleeParamTypes(self, sel_author.?.decl, c.args);

        // Static plain-struct method: all declared params are user args. Select
        // by the source-aware type head before namespace/global name lookup.
        if (!self.callResolver().objectIsValue(fa.object)) {
            switch (self.staticStructHead(fa.object)) {
                .resolved => |owner_ty| {
                    if (self.plainStructMethod(owner_ty, fa.field)) |method|
                        return astCalleeParamTypes(self, method.fd, c.args);
                    if (self.hasPlainStructAuthor(owner_ty)) return &.{};
                },
                .ambiguous, .not_visible => return &.{},
                .none => {},
            }
        }

        // Namespace/static call: `Type.method(args)` where `Type` is a type
        // identifier (not a value in scope). Args correspond to ALL params
        // — no self prepend — so target_type for arg lowering must include
        // the leading param. Skipping it would lose the protocol context
        // for `xx ptr` inline-cast args.
        if (fa.object.data == .identifier) {
            const obj_name = fa.object.data.identifier.name;
            var selected_namespace_fd: ?*const ast.FnDecl = null;
            const is_value = self.identifierBindsVisibleValue(obj_name);
            if (!is_value) {
                // Resolve the member from the selected namespace target before
                // consulting process-global qualified/bare maps. This includes
                // extern re-exports (`socket.write :: c.write`), whose literal C
                // symbol intentionally has no distinct `socket.write` FuncId.
                // Without the signature here, the ambient expression target
                // leaks into argument lowering (a `-> bool` caller truncated a
                // byte count to i1 before calling libc).
                switch (self.namespaceAliasVerdict(obj_name)) {
                    .target => |target| {
                        if (self.namespaceFnMember(&target, fa.field)) |fd| {
                            selected_namespace_fd = fd;
                            // Plain/generic/builtin aliases already have
                            // qualified planning paths that bind/substitute
                            // their parameters. Only extern aliases collapse
                            // to a literal bare symbol and therefore need this
                            // target-pinned AST signature fast path.
                            if (fd.extern_export == .extern_)
                                return astCalleeParamTypes(self, fd, c.args);
                        }
                    },
                    .ambiguous, .none => {},
                }
                const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ obj_name, fa.field }) catch return &.{};
                if (self.resolveFuncByName(qualified)) |fid| {
                    const func = &self.module.functions.items[@intFromEnum(fid)];
                    return coerceDemands(self, self.userParamTypes(func));
                }
                if (self.program_index.fn_ast_map.get(qualified)) |fd| {
                    return astCalleeParamTypes(self, fd, c.args);
                }
                // A plain function re-export may collapse to its terminal
                // symbol without registering an outer `alias.member` AST key
                // (notably a multi-hop facade such as
                // `fs.delete_file :: backend.delete_file`). Dispatch already
                // follows namespaceFnMember to that terminal declaration; use
                // the SAME selected declaration as the final signature
                // fallback. Leaving the arg target empty makes explicit `xx`
                // casts materialize `.unresolved` loads that survive to LLVM.
                if (selected_namespace_fd) |fd|
                    return astCalleeParamTypes(self, fd, c.args);
            }
        }

        const obj_ty = self.inferExprType(fa.object);
        // Protocol-typed receiver: look up the method on the protocol decl. The
        // protocol's ProtocolMethodInfo.param_types already excludes self.
        // The receiver may be erased directly (`P`), a view (`*P`), or the
        // optional of either (`?P` / `?*P`) — same look-through as the plan
        // and dispatch arms (enum-literal args through a view
        // dispatch lost their param target and typed from the ambient
        // destination instead).
        const proto_recv = blk: {
            var t = obj_ty;
            if (!t.isBuiltin()) {
                const oi = self.module.types.get(t);
                if (oi == .optional) t = oi.optional.child;
            }
            if (!t.isBuiltin()) {
                const pi2 = self.module.types.get(t);
                if (pi2 == .pointer and self.getProtocolInfo(pi2.pointer.pointee) != null) t = pi2.pointer.pointee;
            }
            break :blk t;
        };
        if (self.getProtocolInfo(proto_recv)) |proto_info| {
            for (proto_info.methods) |m| {
                if (std.mem.eql(u8, m.name, fa.field)) return coerceDemands(self, m.param_types);
            }
        }
        // `*Protocol` receiver (borrowed view): same lookup through the
        // pointee.
        if (!obj_ty.isBuiltin()) {
            const oi = self.module.types.get(obj_ty);
            if (oi == .pointer) {
                if (self.getProtocolInfo(oi.pointer.pointee)) |proto_info| {
                    for (proto_info.methods) |m| {
                        if (std.mem.eql(u8, m.name, fa.field)) return coerceDemands(self, m.param_types);
                    }
                }
            }
        }
        // Optional-protocol receiver (`?GPU`): same as above but the
        // protocol type sits inside the optional's payload.
        if (!obj_ty.isBuiltin()) {
            const opt_info = self.module.types.get(obj_ty);
            if (opt_info == .optional) {
                if (self.getProtocolInfo(opt_info.optional.child)) |proto_info| {
                    for (proto_info.methods) |m| {
                        if (std.mem.eql(u8, m.name, fa.field)) return coerceDemands(self, m.param_types);
                    }
                }
            }
        }
        // A callable struct field is called as a value: pick up the callee's
        // param types from the field so each arg gets the right target_type
        // during lowering.
        switch (self.lookupField(obj_ty, fa.field)) {
            .hit, .private => |h| if (self.callableSigOf(h.ty)) |sig| return coerceDemands(self, sig.params),
            .missing => {},
        }
        if (self.getStructTypeName(obj_ty)) |sname| {
            // Runtime-class receiver (`@ObjcClass` / `@JniClass` / etc.):
            // resolve the method from `runtime_class_map` walking `extends =`.
            // Without this path, `target_type` for each arg falls back to
            // whatever `self.target_type` was on entry — typically the
            // enclosing fn's return type — which silently truncates `xx ptr`
            // casts inside e.g. a `BOOL`-returning method body.
            if (self.program_index.runtime_class_map.get(sname)) |fcd| {
                if (self.findRuntimeMethodInChain(fcd, fa.field)) |found| {
                    const md = found.method;
                    const saved_fc = self.current_runtime_class;
                    defer self.current_runtime_class = saved_fc;
                    self.current_runtime_class = found.fcd;
                    const user_param_start: usize = if (md.is_static) 0 else 1;
                    if (md.params.len > user_param_start) {
                        var demands = std.ArrayList(ParamDemand).empty;
                        for (md.params[user_param_start..]) |p_node| {
                            demands.append(self.alloc, .{ .coerce = self.resolveType(p_node) }) catch unreachable;
                        }
                        return demands.items;
                    }
                    return &.{};
                }
            }

            // Generic-instance method with binders of its own: the instance's
            // bindings seed them, the call's arguments supply the rest. Asked
            // before the plain-struct path because that one cannot see a method
            // an impl block registered under the TEMPLATE's name.
            if (self.genericInstanceMethod(sname, fa.field)) |gm| {
                if (instanceMethodNeedsArgBinding(gm)) {
                    const eff_args = self.alloc.alloc(*const Node, c.args.len + 1) catch return &.{};
                    eff_args[0] = fa.object;
                    for (c.args, 0..) |a, i| eff_args[i + 1] = a;
                    const saved_seed = self.impl_binder_seed;
                    defer self.impl_binder_seed = saved_seed;
                    self.impl_binder_seed = gm.bindings;
                    const all = astCalleeParamTypes(self, gm.fd, eff_args);
                    return if (all.len > 0) all[1..] else &.{};
                }
            }
            // Plain nominal struct: resolve the selected author's signature,
            // with the receiver prepended for generic binding, then elide the
            // receiver slot from the user-argument target types.
            if (self.plainStructMethod(obj_ty, fa.field)) |method| {
                const eff_args = self.alloc.alloc(*const Node, c.args.len + 1) catch return &.{};
                eff_args[0] = fa.object;
                for (c.args, 0..) |a, i| eff_args[i + 1] = a;
                const all = astCalleeParamTypes(self, method.fd, eff_args);
                return if (all.len > 0) all[1..] else &.{};
            }
            if (!self.hasPlainStructAuthor(obj_ty)) {
                const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ sname, fa.field }) catch return &.{};
                // Try already-lowered functions first
                if (self.resolveFuncByName(qualified)) |fid| {
                    const func = &self.module.functions.items[@intFromEnum(fid)];
                    // Skip both `__sx_ctx` (if present) AND `self` param;
                    // caller args include neither.
                    const skip: usize = (if (func.has_implicit_ctx) @as(usize, 1) else 0) + 1;
                    if (func.params.len > skip) {
                        var demands = std.ArrayList(ParamDemand).empty;
                        for (func.params[skip..]) |p| {
                            demands.append(self.alloc, .{ .coerce = p.ty }) catch unreachable;
                        }
                        return demands.items;
                    }
                }
                // Try AST map (not yet lowered)
                if (self.program_index.fn_ast_map.get(qualified)) |fd| {
                    if (fd.params.len > 0) {
                        // A generic method's params (`xs: []$T`) only have a
                        // meaning under this call site's bindings. Resolving them
                        // unbound INTERNS the poison (`[]unresolved`) into the
                        // TypeTable, where `resolveTypeCategoryTags`'s category
                        // scan later hands it to `any_to_string`'s `case slice`
                        // arm and monomorphizes an uncompilable
                        // `slice_to_string__unresolved`. Bind first,
                        // receiver prepended so positions line up with
                        // `fd.params[0] = self`.
                        var eff_args = std.ArrayList(*const Node).empty;
                        defer eff_args.deinit(self.alloc);
                        eff_args.append(self.alloc, fa.object) catch unreachable;
                        for (c.args) |a| eff_args.append(self.alloc, a) catch unreachable;
                        const all = astCalleeParamTypes(self, fd, eff_args.items);
                        return if (all.len > 1) all[1..] else &.{};
                    }
                }
                // Generic-struct instance method param types: select the method
                // body via the instance's STAMPED author (CP-4), substituting the
                // instance's bindings so `T → concrete`. The param source-pin
                // follows the selected `fd` (its own `body.source_file`).
                if (self.genericInstanceMethod(sname, fa.field)) |gm| {
                    if (gm.fd.params.len > 0) {
                        var scope = generics_mod.installTypeBindings(self, gm.bindings.*);
                        defer scope.exit();
                        var demands = std.ArrayList(ParamDemand).empty;
                        for (1..gm.fd.params.len) |i| {
                            demands.append(self.alloc, lower_bound.paramDemand(self, gm.fd, i)) catch unreachable;
                        }
                        return demands.items;
                    }
                }
            }
        }
        // A ufcs target is keyed on the BARE field name, which no arm above
        // consults — the same declaration named-argument binding resolves. The
        // name is shared program-wide, so the author is picked by RECEIVER, the
        // way dispatch picks it, and a declaration whose own receiver parameter
        // does not take this one names a different call.
        if (namedCalleeDecl(self, c, sel_author, qualified_selected, null, false)) |callee| {
            if (callee.receiver_params == 1) {
                var eff_args = std.ArrayList(*const Node).empty;
                defer eff_args.deinit(self.alloc);
                eff_args.append(self.alloc, fa.object) catch unreachable;
                for (c.args) |a| eff_args.append(self.alloc, a) catch unreachable;
                var amb = false;
                const fd = if (callee.fd.type_params.len > 0 and callee.fd.is_ufcs)
                    self.selectUfcsGenericByReceiver(fa.field, eff_args.items, &amb, callee.fd) orelse callee.fd
                else
                    callee.fd;
                const all = astCalleeParamTypes(self, fd, eff_args.items);
                if (!amb and all.len > 1 and receiverFits(self, obj_ty, all[0])) return all[1..];
            }
        }
        return &.{};
    }
    // Every other callee shape lowers as an expression, and a callable value
    // there wants the same argument demand a named one gets.
    if (c.callee.data != .identifier) {
        if (self.callableSigOf(self.inferExprType(c.callee))) |sig| return coerceDemands(self, sig.params);
        return &.{};
    }
    const bare_name = c.callee.data.identifier.name;
    // Callable VALUE bound in scope (`g := || …; g(args)`): type each arg
    // against the callee value's declared parameter types so a `?T` param wraps
    // the argument — without this the args lower with no target type and reach
    // `call_closure` unconverted (a concrete arg arrives as a bare payload that
    // reads ABSENT; `null` reaches a `{T,i1}` slot as a bare pointer → LLVM
    // verifier failure). A local value shadows a same-named function, so this
    // precedes the function-name resolution below.
    if (self.scope) |scope| {
        if (scope.lookup(bare_name)) |binding| {
            if (self.callableSigOf(binding.ty)) |sig| return coerceDemands(self, sig.params);
        }
    }
    const name = blk: {
        const scoped = if (self.scope) |scope| scope.lookupFn(bare_name) orelse bare_name else bare_name;
        if (self.ufcsAliasTarget(bare_name)) |target| {
            break :blk if (self.scope) |scope| scope.lookupFn(target) orelse target else target;
        }
        break :blk scoped;
    };

    // A genuine flat same-name collision must type this
    // call's args against the author the call resolver selected, not the
    // first-wins winner's params. lowering consumes the ONE author verdict
    // (`selectedFreeAuthor`, computed once in `lowerCall`) rather than
    // re-resolving the name, so arg lowering (implicit address-of, coercion)
    // matches the author actually dispatched — otherwise a `*T`-param shadow
    // gets a `T` value arg that is later bit-cast to a pointer (segfault). The
    // FuncId materializes into the SHARED verdict (once), so dispatch reuses
    // it. A non-collision call falls to the existing first-wins path below,
    // byte-for-byte.
    if (sel_author) |sf| {
        const fid = self.selectedFuncId(sf);
        const func = &self.module.functions.items[@intFromEnum(fid)];
        return coerceDemands(self, self.userParamTypes(func));
    }

    // A value-authored or ambiguous name has no callable declaration here, so
    // the name-keyed maps must not type its arguments — the same gate dispatch
    // applies, or the args coerce to a function the call never reaches.
    if (!author_declines) {
        // Check declared functions
        if (self.resolveFuncByName(name)) |fid| {
            const func = &self.module.functions.items[@intFromEnum(fid)];
            return coerceDemands(self, self.userParamTypes(func));
        }

        // Check AST map for function signatures
        if (self.program_index.fn_ast_map.get(name)) |fd| {
            return astCalleeParamTypes(self, fd, c.args);
        }
    }

    // A module global holding a callable value (quiet author-aware lookup —
    // param typing only; the call site diagnoses ambiguity / visibility).
    if (self.globalValueRef(bare_name)) |gi| {
        if (self.callableSigOf(gi.ty)) |sig| return coerceDemands(self, sig.params);
    }

    return &.{};
}

/// The open set a method-call receiver of type `ty` names — the set itself, or the
/// set a `*P` receiver points at. Dispatch reads the slot through a pointer, so
/// both spellings reach the same routine.
fn openSetReceiver(self: *Lowering, ty: TypeId) ?TypeId {
    if (self.isOpenSet(ty)) return ty;
    if (ty.isBuiltin()) return null;
    const info = self.module.types.get(ty);
    if (info != .pointer) return null;
    return if (self.isOpenSet(info.pointer.pointee)) info.pointer.pointee else null;
}

/// The address of the slot to dispatch on. A `*P` receiver IS that address; an
/// lvalue set value is dispatched in place, so a method writing through `self`
/// writes the receiver's own storage. An rvalue has no storage, so it gets a
/// temporary — the value is about to be discarded either way.
fn openSetReceiverAddress(self: *Lowering, obj: Ref, obj_ty: TypeId, set_ty: TypeId, obj_node: *const Node) Ref {
    if (obj_ty != set_ty) return obj;
    return self.openSetSlotAddress(set_ty, obj, obj_node);
}
