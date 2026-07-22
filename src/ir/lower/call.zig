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

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const BlockId = inst_mod.BlockId;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
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

/// True iff every type-parameter of generic ufcs/free-fn `fd` binds to a
/// concrete (present) type given `args_ast` (receiver prepended). A param the
/// argument shapes can't pin is simply absent from the bindings map (e.g. a
/// `*Future($R)` receiver param against a `*Box(i64)` argument never binds `R`).
pub fn ufcsGenericBindsAll(self: *Lowering, fd: *const ast.FnDecl, args_ast: []const *const Node) bool {
    var b = self.genericResolver().buildTypeBindings(fd, args_ast);
    defer b.deinit();
    for (fd.type_params) |tp| {
        if (!b.contains(tp.name)) return false;
    }
    return true;
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

/// issue 0157 + review follow-ups: a bare-ufcs name resolves through a single
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
///   #import` namespace). Scan all module authors for the unique most-specific
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
/// least one does). Steers the visibility-gate diagnostic: "#import the
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
/// same-named top-level fn in call position (issue 0217): the call must
/// dispatch indirectly through the LOCAL, so every program-fn path — the
/// non-transitive-visibility gate, the early pack/comptime/generic
/// dispatch, and direct name dispatch — is skipped for it. Without this,
/// an importer's unrelated module-scope `h` hijacks (or the visibility
/// gate rejects) an imported module's own `h := ...; h(...)` sites.
/// A pack-element alias is excluded (the substitution path owns it), as
/// is a non-callable binding (pre-existing behavior kept: it falls
/// through to the program-fn paths and the trailing any-binding
/// indirect-call fallback).
/// Nearest-scope resolution (review F1): a nested local fn decl at a
/// NEARER level owns the name — `lookupNearest` walks the chain once,
/// consulting BOTH per-level namespaces, so an outer callable var never
/// beats an inner nested fn (and vice versa).
fn callableLocalShadow(self: *Lowering, name: []const u8) bool {
    const scope = self.scope orelse return false;
    const near = scope.lookupNearest(name) orelse return false;
    const binding = switch (near) {
        // Nested local fn is nearest: the mangled-name direct-dispatch
        // path owns the call (innermost wins) — no value shadow.
        .local_fn => return false,
        .binding => |b| b,
    };
    if (binding.pack_elem != null) return false;
    if (binding.ty.isBuiltin()) return false;
    const ti = self.module.types.get(binding.ty);
    return ti == .function or ti == .closure;
}

/// Indirect call through a local VALUE binding (fn-pointer local, or the
/// trailing any-binding fallback). Checks arity against the fn-pointer's
/// signature (review F3 — arg coercion min()-truncates, so a wrong-arity
/// call would otherwise silently drop args), coerces args to the param
/// types, and prepends the implicit ctx when the pointee signature wants it.
fn indirectCallThroughLocal(self: *Lowering, name: []const u8, binding: lower.Binding, args: []Ref, span: ast.Span) Ref {
    // Arity: the fn TYPE's params are user-visible (no __sx_ctx slot —
    // `fnPtrTypeWantsCtx` prepends it from the calling convention) and a
    // pack-variadic signature (`pack_start != null`) binds per call shape,
    // so it is exempt. A C-conv pointer may carry a genuine `...` variadic
    // tail the fn TYPE cannot express, so extras are allowed there; too
    // FEW args is wrong under every convention. (Overlaps issue 0188's
    // callable-value arg check on master — reconcile at cherry-pick,
    // keeping 0188's check plus this file's gating.)
    if (!binding.ty.isBuiltin()) {
        const bti = self.module.types.get(binding.ty);
        if (bti == .function and bti.function.pack_start == null) {
            const want = bti.function.params.len;
            const exact = bti.function.call_conv != .c;
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
    // Coerce user args to the fn-pointer's param types (issue
    // 0186) — same as the closure-value and global-fn-pointer
    // paths. The arg loop already applied implicit address-of
    // for `*T` params (resolveCallParamTypes now surfaces the
    // `.function` param types), so this completes value
    // coercions like a `?T` wrap. Without it a concrete arg to a
    // `?T` fn-ptr param reaches `call_indirect` unconverted.
    if (!binding.ty.isBuiltin()) {
        const bti = self.module.types.get(binding.ty);
        if (bti == .function) coerceClosureCallArgs(self, args, bti.function.params);
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
/// the process-wide name map.  Closure and function-pointer globals keep the
/// same ABI, arity and coercion behavior as their bare callable-value forms.
fn callThroughSelectedGlobal(
    self: *Lowering,
    selected: CallResolver.CallableValue,
    args: []Ref,
    c: *const ast.Call,
    span: ast.Span,
) Ref {
    const ty = selected.global.ty;
    if (ty.isBuiltin()) return self.emitError(selected.member, span);
    const info = self.module.types.get(ty);
    const callee_ref = self.builder.emit(.{ .global_get = selected.global.id }, ty);
    if (info == .closure) {
        if (checkCallableValueArgs(self, "closure", selected.member, args, info.closure.params.len, info.closure.pack_start, c, span)) return Ref.none;
        coerceClosureCallArgs(self, args, info.closure.params);
        const owned = if (self.implicit_ctx_enabled) blk: {
            const with_ctx = self.alloc.alloc(Ref, args.len + 1) catch @panic("out of memory while preparing qualified closure call");
            with_ctx[0] = self.current_ctx_ref;
            @memcpy(with_ctx[1..], args);
            break :blk with_ctx;
        } else self.alloc.dupe(Ref, args) catch @panic("out of memory while preparing qualified closure call");
        return self.builder.emit(.{ .call_closure = .{ .callee = callee_ref, .args = owned } }, info.closure.ret);
    }
    if (info == .function) {
        if (checkCallableValueArgs(self, "function pointer", selected.member, args, info.function.params.len, info.function.pack_start, c, span)) return Ref.none;
        coerceClosureCallArgs(self, args, info.function.params);
        var final_args = std.ArrayList(Ref).empty;
        defer final_args.deinit(self.alloc);
        if (self.fnPtrTypeWantsCtx(ty))
            final_args.append(self.alloc, self.current_ctx_ref) catch @panic("out of memory while preparing qualified function-pointer call");
        final_args.appendSlice(self.alloc, args) catch @panic("out of memory while preparing qualified function-pointer call");
        const owned = self.alloc.dupe(Ref, final_args.items) catch @panic("out of memory while preparing qualified function-pointer call");
        return self.builder.emit(.{ .call_indirect = .{ .callee = callee_ref, .args = owned } }, info.function.ret);
    }
    return self.emitError(selected.member, span);
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

    const saved_bindings = self.type_bindings;
    var method_bindings: ?std.StringHashMap(TypeId) = null;
    defer {
        self.type_bindings = saved_bindings;
        if (method_bindings) |*bindings| bindings.deinit();
    }
    if (fd.type_params.len > 0) {
        method_bindings = self.genericResolver().buildTypeBindings(fd, effective_args.items);
        if (!comptimeMethodBindingsComplete(self, fd, &method_bindings.?, call_span)) return Ref.none;
        self.type_bindings = method_bindings.?;
    }

    return self.lowerComptimeMethodCallArgs(fd, effective_args.items, recv_node != null, call_span);
}

pub fn lowerCall(self: *Lowering, c_in: *const ast.Call) Ref {
    var c = c_in;
    // A bare reserved-type-name spelling in call position parses as a
    // `.type_expr` (e.g. `i2(4)`), but if a function of that name is in
    // scope — a backtick-declared sx fn or a `#import c` extern fn whose C
    // name collides with a reserved type spelling — it is a CALL to that
    // function. `TypeName(val)` is not a cast (casts are `cast(T, val)`), so
    // there is no ambiguity. Rewrite the callee to an identifier so the
    // normal call machinery resolves it, symmetric to the bare-value
    // reference that already resolves via scope/globals.
    //
    // Scoped to RAW provenance: only a backtick (`is_raw`) or `#import c`
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
                d.addFmt(.err, hidden.span, "namespace '{s}' is not visible; #import the module that declares it", .{hidden.alias});
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
    if (mapNamedArgs(self, c, sel_author, qualified_author != null, author_ambiguous)) |mapped| c = mapped;
    // Expand default parameter values for bare identifier callees:
    // when the caller omits trailing positional args, fill them in
    // from the callee's `param: T = expr` declarations.
    if (self.expandCallDefaults(c, sel_author, qualified_author != null, author_ambiguous)) |expanded| c = expanded;
    // Check reflection builtins first (before lowering args — some args are type names, not values)
    if (c.callee.data == .identifier) {
        if (self.tryLowerReflectionCall(c.callee.data.identifier.name, c)) |ref| return ref;
        // Atomic intrinsics (atomic_load/atomic_store): a type arg + value args,
        // so lower them here (before generic arg lowering) like reflection calls.
        if (self.tryLowerAtomicIntrinsic(c.callee.data.identifier.name, c)) |ref| return ref;
    }
    // Qualified intrinsic spelling is legal too. Only dispatch a compiler
    // recognizer after the full namespace path selected the exact declaration
    // and proved that its body is intrinsic; the terminal name alone is not
    // authority (intrinsic identity is module + name).
    if (qualified_author) |sf| {
        if (sf.decl.body.data == .intrinsic_expr) {
            if (self.tryLowerReflectionCall(sf.decl.name, c)) |ref| return ref;
            if (self.tryLowerAtomicIntrinsic(sf.decl.name, c)) |ref| return ref;
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
                d.addFmt(.err, c.callee.span, "C function '{s}' not visible; add #import for the module that declares it", .{eff_name});
            return Ref.none;
        }
        // Non-transitive `#import` visibility check. Apply only when the
        // user-typed name resolved as-is to a top-level fn — local-scope
        // mangling (eff_name != id_name) and UFCS alias rewriting are
        // compiler indirections and stay exempt. A callable LOCAL binding
        // shadows the top-level fn entirely (issue 0217): the call targets
        // the local, so the program-fn visibility gate must not fire.
        // An intrinsic is a compiler feature, not a library export, so import
        // visibility does not gate it — the same reason `size_of` / `sqrt` /
        // `atomic_load` resolve with no import (their folds run before this
        // check). The evaluate-mode intrinsics DO reach here, because the VM
        // services them as ordinary declared calls; exempting them keeps every
        // intrinsic reachable on the same terms.
        if (std.mem.eql(u8, eff_name, id_name) and
            self.ufcsAliasTarget(id_name) == null and
            self.program_index.fn_ast_map.contains(eff_name) and
            !callableLocalShadow(self, id_name) and
            intrinsics.findByName(eff_name) == null and
            !self.isNameVisible(eff_name))
        {
            if (self.diagnostics) |d| {
                if (nameAuthoredOnlyPrivately(self, eff_name))
                    d.addFmt(.err, c.callee.span, "'{s}' is private to its declaring module", .{eff_name})
                else
                    d.addFmt(.err, c.callee.span, "'{s}' is not visible; #import the module that declares it", .{eff_name});
            }
            return Ref.none;
        }
    }

    // Handle closure(fn_or_lambda) — wrap bare functions into closures
    if (c.callee.data == .identifier and std.mem.eql(u8, c.callee.data.identifier.name, "closure")) {
        if (c.args.len >= 1) {
            const arg = c.args[0];
            // If argument is a bare function name, create a proper closure from it
            if (arg.data == .identifier) {
                const fn_name = arg.data.identifier.name;
                // `closure(fn)` over a genuine flat same-name
                // collision must capture the RESOLVED author's FuncId, not the
                // first-wins winner's. Plain bare name only; `.ambiguous`
                // → loud diagnostic; `.none` → existing first-wins path.
                const closure_fid: ?FuncId = blk_cl: {
                    if (self.ufcsAliasTarget(fn_name) == null and
                        (if (self.scope) |scope| scope.lookup(fn_name) == null else true))
                    {
                        if (self.current_source_file) |caller_file| {
                            switch (self.selectPlainCallableAuthor(fn_name, caller_file)) {
                                .func => |sf| {
                                    var selected = sf;
                                    break :blk_cl self.selectedFuncId(&selected, fn_name);
                                },
                                .ambiguous => {
                                    if (self.diagnostics) |d|
                                        d.addFmt(.err, arg.span, "'{s}' is ambiguous; declared by multiple imported modules — qualify the call", .{fn_name});
                                    return Ref.none;
                                },
                                .none => {},
                            }
                        }
                    }
                    if (!self.lowered_functions.contains(fn_name)) {
                        self.lazyLowerFunction(fn_name);
                    }
                    break :blk_cl self.resolveFuncByName(fn_name);
                };
                if (closure_fid) |fid| {
                    const func = &self.module.functions.items[@intFromEnum(fid)];
                    // Build closure type from user-visible params only —
                    // skip the implicit __sx_ctx param.
                    var param_types_list = std.ArrayList(TypeId).empty;
                    defer param_types_list.deinit(self.alloc);
                    const skip: usize = if (func.has_implicit_ctx) 1 else 0;
                    for (func.params[skip..]) |p| {
                        param_types_list.append(self.alloc, p.ty) catch unreachable;
                    }
                    const closure_ty = self.module.types.closureType(param_types_list.items, func.ret);
                    const closure_info = self.module.types.get(closure_ty).closure;
                    const tramp_id = self.createBareFnTrampoline(fid, closure_info);
                    return self.builder.closureCreate(tramp_id, Ref.none, closure_ty);
                }
            }
            // Lambda or other expression — already produces closure_create
            return self.lowerExpr(arg);
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
        // R5 §C: the early pack/comptime/generic dispatch reads
        // the SAME author the call resolver SELECTED — not the first-wins
        // winner — whenever a genuine flat same-name collision rerouted the
        // call (`sel_author != null`). The selector only ever returns a plain
        // free fn (`isPlainFreeFn` rejects type-params / comptime / pack), so
        // `sel_author.decl` matches none of the arms below and the early path
        // falls through to the main dispatch, which CONSUMES `sel_author` and
        // binds that author. Without this the early path would dispatch the
        // first-wins winner (e.g. a pack `(..$args)`) and disagree with the
        // main dispatch — the selected plain author's bare call would invoke
        // the wrong function. On the common path (`sel_author == null`) this
        // reads the winner exactly as before — byte-identical, since the
        // selector reroutes nothing there.
        // A callable LOCAL binding shadows the top-level fn (issue 0217):
        // the early pack/comptime/generic program-fn dispatch must not
        // consume the call — the main dispatch routes it indirect through
        // the local. (`sel_author` is already `.none` for any shadowed
        // name, so only the first-wins map lookup needs the gate.)
        const early_fd: ?*const ast.FnDecl = if (sel_author) |sf|
            sf.decl
        else if (callableLocalShadow(self, c.callee.data.identifier.name))
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
                // Types are explicit when call args match param count (e.g., are_equal(Point, p1, p2))
                // Types are inferred when call args < param count (e.g., are_equal(p1, p2))
                const types_explicit = c.args.len == fd.params.len;
                // Resolve the DECLARED param types up front — in the callee's
                // source, with $T bindings inferred from the arg nodes — and
                // align them to the ARG positions (inference calls omit the
                // type-param slots). Each resolvable param supplies its arg's
                // target exactly like the direct-call path: without it, an
                // `xx local` arg to a protocol param lowers node-lessly and
                // the later value-wise coercion HEAP-COPIES the local through
                // context.allocator instead of borrowing it (issue 0302). An
                // unresolvable param slot keeps a null target (the ambient
                // target must still not leak into the arg).
                const early_param_types = astCalleeParamTypes(self, fd, c.args);
                var arg_targets = std.ArrayList(?TypeId).empty;
                defer arg_targets.deinit(self.alloc);
                for (fd.params, 0..) |*p, pi| {
                    if (!types_explicit and isTypeParamDecl(p, fd.type_params)) continue;
                    const pt: ?TypeId = if (pi < early_param_types.len and
                        early_param_types[pi] != .unresolved and early_param_types[pi] != .void)
                        early_param_types[pi]
                    else
                        null;
                    arg_targets.append(self.alloc, pt) catch unreachable;
                }
                var lowered_args = std.ArrayList(Ref).empty;
                defer lowered_args.deinit(self.alloc);
                for (c.args, 0..) |arg, ai| {
                    // Skip type param args only when types are passed explicitly
                    if (types_explicit and ai < fd.params.len and isTypeParamDecl(&fd.params[ai], fd.type_params)) {
                        lowered_args.append(self.alloc, Ref.none) catch unreachable;
                    } else {
                        const saved_target = self.target_type;
                        const tgt: ?TypeId = if (ai < arg_targets.items.len) arg_targets.items[ai] else null;
                        self.target_type = tgt;
                        const r = blk: {
                            // Protocol param targets erase node-aware
                            // (same arm as the direct path).
                            if (tgt) |ptv| {
                                if (protocolArgErasure(self, arg, ptv)) |ib| break :blk ib;
                            }
                            break :blk self.lowerExpr(arg);
                        };
                        lowered_args.append(self.alloc, r) catch unreachable;
                        self.target_type = saved_target;
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

    // Lower args (with target type propagation for xx conversions)
    var args = std.ArrayList(Ref).empty;
    defer args.deinit(self.alloc);
    // Try to resolve param types for target_type context
    const param_types = self.resolveCallParamTypes(c, sel_author, qualified_author != null, if (qualified_callable) |cv| cv.global else null);
    // For enum_literal callees (.Variant(payload)), resolve the payload target type
    // from the union field type so struct literal fields get proper coercion
    var enum_payload_ty: ?TypeId = null;
    if (c.callee.data == .enum_literal) {
        const target = self.target_type orelse .unresolved;
        if (!target.isBuiltin()) {
            const info = self.module.types.get(target);
            if (info == .tagged_union) {
                const tag = self.resolveVariantIndex(target, c.callee.data.enum_literal.name);
                if (tag < info.tagged_union.fields.len) {
                    enum_payload_ty = info.tagged_union.fields[tag].ty;
                }
            }
        }
    }
    // Running PARAMETER index (issue 0239 review F1): a spread expands one
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
                if (op_info != .tuple and op_info != .array and op_info != .@"struct") break :expand;
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
        const saved_target = self.target_type;
        if (ai < param_types.len) {
            self.target_type = param_types[ai];
        }
        // `cast(T) X` — lower an integer-literal operand against the cast's
        // target type T (issue 0275): otherwise the literal folds against the
        // ambient default `i64` and a value above i64.max but within a wider
        // target (`cast(u64) 0xcbf...`) trips the i64 fits-check before the
        // cast ever applies — AND a same-width signed↔unsigned reinterpret
        // (`i64 → u64`) is classified `.none`, passing the operand through with
        // its SOURCE type so a `:=`-inferred result mis-formats as signed.
        // Emitting the literal directly as T fixes both (the value is masked to
        if (enum_payload_ty) |ept| {
            if (ai == 0) self.target_type = ept;
        }
        // Implicit float→int narrowing of a compile-time float argument
        // (incl. an expanded `param: T = expr` default) follows the unified
        // rule: an integral comptime float folds, a non-integral one errors.
        // A runtime float / `xx` cast is unaffected and coerces as before.
        if (ai < param_types.len) {
            if (self.foldComptimeFloatInit(arg, param_types[ai])) |folded| {
                args.append(self.alloc, folded) catch unreachable;
                self.target_type = saved_target;
                continue;
            }
        }
        // Implicit address-of: when param expects *T and arg is an identifier
        // with an alloca of type T, pass the alloca pointer directly (reference
        // semantics, so mutations through the pointer are visible to the caller).
        if (ai < param_types.len and arg.data == .identifier) {
            const pt = param_types[ai];
            if (!pt.isBuiltin()) {
                const pti = self.module.types.get(pt);
                if (pti == .pointer) {
                    const nm = arg.data.identifier.name;
                    const local = if (self.scope) |scope| scope.lookup(nm) else null;
                    if (local) |binding| {
                        // Only apply when the binding type matches the pointee type
                        if (binding.is_alloca and binding.ty == pti.pointer.pointee) {
                            const ptr_ty = self.module.types.ptrTo(binding.ty);
                            args.append(self.alloc, self.builder.emit(.{ .addr_of = .{ .operand = binding.ref } }, ptr_ty)) catch unreachable;
                            self.target_type = saved_target;
                            continue;
                        }
                    } else if (self.resolveGlobalRef(nm, null)) |gi| {
                        // MUTABLE global arg to a `*T` param: pass the global's
                        // LIVE address (`global_addr` via lowerExprAsPtr), not a
                        // loaded copy the callee would mutate in vain — the
                        // explicit-call sibling of the 0202 UFCS-receiver fix.
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
                            self.target_type = saved_target;
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
        if (ai < param_types.len and (arg.data == .field_access or arg.data == .index_expr or arg.data == .deref_expr)) {
            const pt = param_types[ai];
            if (!pt.isBuiltin()) {
                const pti = self.module.types.get(pt);
                if (pti == .pointer and self.inferExprType(arg) == pti.pointer.pointee) {
                    // `lowerExprAsPtr` yields the lvalue's address, typed
                    // either as `*T` already (index/deref) or as the pointee
                    // `T` (a field "place" ref); normalize to `*T` — exactly
                    // what `@field_access` does.
                    const place = self.lowerExprAsPtr(arg);
                    const place_ty = self.builder.getRefType(place);
                    const ref: ?Ref = if (place_ty == pt)
                        place
                    else if (place_ty == pti.pointer.pointee)
                        self.builder.emit(.{ .addr_of = .{ .operand = place } }, pt)
                    else
                        null;
                    if (ref) |r| {
                        args.append(self.alloc, r) catch unreachable;
                        self.target_type = saved_target;
                        continue;
                    }
                }
            }
        }
        // Concrete lvalue → `#identity` protocol param: erase NODE-AWARE so
        // the lvalue BORROWS (`free(t, gpa)` aliases gpa) — the node-less
        // coerceCallArgs layer would misread the lvalue as an rvalue and
        // refuse. value/own params keep the node-less owning copy until the
        // ownership cutover.
        if (ai < param_types.len) {
            if (protocolArgErasure(self, arg, param_types[ai])) |r| {
                args.append(self.alloc, r) catch unreachable;
                self.target_type = saved_target;
                continue;
            }
        }
        // Concrete lvalue → `*Protocol` param: the borrowed-VIEW coercion
        // (erasure model; issue 0303's cell). Take the lvalue's REAL address,
        // build the borrow-mode protocol value around it (ctx = that address,
        // so mutations through the view reach the original), spill the value
        // to a frame slot and pass the slot's address. Mirrors the implicit
        // address-of arms above; rvalue args never reach here (no lvalue
        // shape) and are refused at the node-less layer (coerceCallArgs).
        if (ai < param_types.len and (arg.data == .identifier or arg.data == .field_access or
            arg.data == .index_expr or arg.data == .deref_expr))
        {
            const pt = param_types[ai];
            if (!pt.isBuiltin()) {
                const pti = self.module.types.get(pt);
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
                        if (self.viewOfConcreteAddr(addr, cty, pt)) |v| {
                            args.append(self.alloc, v) catch unreachable;
                            self.target_type = saved_target;
                            continue;
                        }
                    }
                }
            }
        }
        // An argument is a VALUE position: a block-form `if C { A } else { B }`
        // / `match` used directly as an argument must yield its branch value,
        // not be lowered as a statement-if (which returns a bare `void 0` and
        // silently passes `0`, or overruns for a wider branch type → segfault,
        // issue 0268). The `then`-form and a `let`-bound local already work
        // because both reach `lowerIfExpr` with `force_block_value` set; a bare
        // call argument did not. Set it here so the arg materializes its value.
        const saved_fbv = self.force_block_value;
        self.force_block_value = true;
        const val = self.lowerExpr(arg);
        self.force_block_value = saved_fbv;
        self.target_type = saved_target;
        // Passing a `*T` where a `T` value is expected — a by-reference loop
        // capture (`for xs: (*m)`), a `*T` parameter, or any pointer local —
        // otherwise slips through to LLVM as an opaque "call parameter type
        // does not match function signature" verifier error. Flag it at the
        // call site with a `.*` fix-it.
        if (ai < param_types.len) {
            const vt = self.builder.getRefType(val);
            const vti = self.module.types.get(vt);
            if (vti == .pointer and vti.pointer.pointee == param_types[ai]) {
                if (self.diagnostics) |d| {
                    const tn = self.formatTypeName(param_types[ai]);
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
            // namespaces (value bindings AND nested local fn decls, review
            // F1): whichever is declared at the inner level wins — an outer
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
                            // it reads a dead env/fn Ref (Bus error; issue 0250
                            // fold). Diagnose for BOTH closure and fn-pointer
                            // shapes — even a non-capturing closure that would
                            // happen to run must not silently legitimize the
                            // reference. A NON-callable crossed binding falls
                            // through unused: the enclosing local is invisible
                            // to a static nested fn, so the name correctly
                            // resolves to the module-scope callable below.
                            if (nb.crossed_fn_boundary and (ty_info == .closure or ty_info == .function)) {
                                _ = self.diagEnclosingLocalRef(id.name, c.callee.span);
                                return Ref.none;
                            }
                            if (ty_info == .closure) {
                                // Exact-arity + spread-placeholder validation
                                // against the closure TYPE (issue 0188).
                                if (checkCallableValueArgs(self, "closure", id.name, args.items, ty_info.closure.params.len, ty_info.closure.pack_start, c, c.callee.span)) return Ref.none;
                                const callee_ref = if (binding.is_alloca) self.builder.load(binding.ref, binding.ty) else binding.ref;
                                // Coerce user args to the closure's param types
                                // (issue 0186) — a `?T` param must wrap the arg.
                                coerceClosureCallArgs(self, args.items, ty_info.closure.params);
                                // Closure trampolines carry `__sx_ctx` at
                                // slot 0; emit_llvm's `call_closure` builds
                                // the call as [ctx, env, user_args], so we
                                // prepend ctx here. args[0] becomes ctx.
                                const owned = if (self.implicit_ctx_enabled) blk: {
                                    const arr = self.alloc.alloc(Ref, args.items.len + 1) catch unreachable;
                                    arr[0] = self.current_ctx_ref;
                                    @memcpy(arr[1..], args.items);
                                    break :blk arr;
                                } else self.alloc.dupe(Ref, args.items) catch unreachable;
                                const ret_ty = ty_info.closure.ret;
                                return self.builder.emit(.{ .call_closure = .{ .callee = callee_ref, .args = owned } }, ret_ty);
                            }
                            // A local fn-POINTER binding shadows any same-named
                            // top-level fn (issue 0217): dispatch indirect through
                            // the LOCAL before the author / name-based program-fn
                            // paths below, otherwise an importer's unrelated
                            // module-scope fn hijacks the call. A fn-pointer type
                            // has no variadic slot — reject a leftover slice/array
                            // spread placeholder before the arity check counts it
                            // as one arg (issues 0188 + 0239).
                            if (binding.pack_elem == null and ty_info == .function) {
                                if (rejectLeftoverSpreadPlaceholder(self, "a function pointer", args.items, c, c.callee.span)) return Ref.none;
                                return indirectCallThroughLocal(self, id.name, binding, args.items, c.callee.span);
                            }
                        }
                    },
                };
            }
            // R5 §C: a genuine flat same-name collision — bind the
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
                const arity_fd: ?*const ast.FnDecl = if (sel_author) |sf| sf.decl else self.program_index.fn_ast_map.get(func_name);
                if (arity_fd) |fd| {
                    // A leftover slice/array-spread placeholder into a callee
                    // with NO variadic slot to consume it: diagnose the spread
                    // itself (issue 0239 part 1) — the arity error alone
                    // miscounted it as one arg, and a count that happened to
                    // line up emitted undef for the slot.
                    if (!fnDeclHasVariadicParam(fd)) {
                        var buf: [160]u8 = undefined;
                        const what = std.fmt.bufPrint(&buf, "'{s}'", .{id.name}) catch id.name;
                        if (rejectLeftoverSpreadPlaceholder(self, what, args.items, c, c.callee.span)) return Ref.none;
                    }
                    if (self.checkCallArity(fd, id.name, args.items.len, false, c.callee.span)) return Ref.none;
                }
            }
            if (sel_author) |sf| {
                const fid = self.selectedFuncId(sf, func_name);
                const func = &self.module.functions.items[@intFromEnum(fid)];
                const ret_ty = func.ret;
                const params = func.params;
                // The RESOLVED author's decl drives variadic packing — not a
                // first-wins re-lookup by name, whose variadic shape may
                // differ.
                self.packVariadicCallArgs(sf.decl, c, &args);
                const final_args = self.prependCtxIfNeeded(func, args.items);
                self.coerceCallArgs(final_args, params);
                if (func.is_variadic) self.promoteCVariadicArgs(final_args, params.len);
                return self.builder.call(fid, final_args, ret_ty);
            }
            // Check for comptime-expanded or generic functions
            if (self.program_index.fn_ast_map.get(func_name)) |fd| {
                if (hasComptimeParams(fd)) {
                    return self.lowerComptimeCall(fd, c);
                }
                if (fd.type_params.len > 0) {
                    // Runtime dispatch already handled above (before arg lowering)
                    return self.lowerGenericCall(fd, func_name, c, args.items);
                }
            }
            // Look up declared/extern function — try lazy lowering if not yet lowered
            {
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
                    if (func.is_variadic) self.promoteCVariadicArgs(final_args, params.len);
                    return self.builder.call(fid, final_args, ret_ty);
                }
            }
            // May be a variable holding a function pointer (non-closure).
            // Function-typed bindings were dispatched before the program-fn
            // paths above (issue 0217); this trailing fallback keeps the
            // pre-existing behavior for every other binding shape.
            if (self.scope) |scope| {
                // A binding reachable only across a nested-fn boundary is an
                // enclosing local — never a valid indirect-call target here
                // (issue 0250 fold; mirrors the callable-binding gate above).
                if (scope.lookupBoundary(id.name).crossed_fn_boundary) {
                    _ = self.diagEnclosingLocalRef(id.name, c.callee.span);
                    return Ref.none;
                }
                if (scope.lookup(id.name)) |binding| {
                    // No variadic slot on any binding-typed callee — a leftover
                    // slice/array spread placeholder must not reach the
                    // indirect call as undef (issues 0188 + 0239).
                    if (rejectLeftoverSpreadPlaceholder(self, "a function pointer", args.items, c, c.callee.span)) return Ref.none;
                    return indirectCallThroughLocal(self, id.name, binding, args.items, c.callee.span);
                }
            }
            // May be a global variable holding a function pointer
            if (self.resolveGlobalRef(id.name, c.callee.span)) |gi| {
                if (!gi.ty.isBuiltin()) {
                    const gti = self.module.types.get(gi.ty);
                    if (gti == .function) {
                        // Exact-arity + spread-placeholder validation against
                        // the fn-pointer TYPE (issue 0188).
                        if (checkCallableValueArgs(self, "function pointer", id.name, args.items, gti.function.params.len, gti.function.pack_start, c, c.callee.span)) return Ref.none;
                        const callee_ref = self.builder.emit(.{ .global_get = gi.id }, gi.ty);
                        // Coerce args to match fn-ptr param types (including
                        // implicit address-of). A tuple/pack spread expands one
                        // AST arg to N lowered args, so `c.args[ai]` only
                        // aligns while `ai` is in range — a spliced element
                        // falls back to its lowered ref's type.
                        for (args.items, 0..) |*arg, ai| {
                            if (ai < gti.function.params.len) {
                                const dst_ty = gti.function.params[ai];
                                const src_ty = if (ai < c.args.len) self.inferExprType(c.args[ai]) else self.builder.getRefType(arg.*);
                                // Implicit address-of: passing T where *T expected
                                if (!dst_ty.isBuiltin()) {
                                    const dti = self.module.types.get(dst_ty);
                                    if (dti == .pointer and dti.pointer.pointee == src_ty and src_ty != .void) {
                                        // For identifier args, pass the alloca directly (reference semantics)
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
                                        // For other expressions, copy semantics
                                        const slot = self.builder.alloca(src_ty);
                                        self.builder.store(slot, arg.*);
                                        arg.* = slot;
                                        continue;
                                    }
                                }
                                arg.* = self.coerceToType(arg.*, src_ty, dst_ty);
                            }
                        }
                        var final_args = std.ArrayList(Ref).empty;
                        defer final_args.deinit(self.alloc);
                        if (self.fnPtrTypeWantsCtx(gi.ty)) {
                            final_args.append(self.alloc, self.current_ctx_ref) catch unreachable;
                        }
                        final_args.appendSlice(self.alloc, args.items) catch unreachable;
                        const owned = self.alloc.dupe(Ref, final_args.items) catch unreachable;
                        return self.builder.emit(.{ .call_indirect = .{ .callee = callee_ref, .args = owned } }, gti.function.ret);
                    }
                }
            }
            // Unresolved function call
            return self.emitError(id.name, c.callee.span);
        },
        .field_access => |fa| {
            if (qualified_callable) |selected|
                return callThroughSelectedGlobal(self, selected, args.items, c, c.callee.span);

            // `super.method(args)` from inside a `#jni_main` (or any
            // sx-defined `#jni_class`) bodied method. Dispatch via
            // CallNonvirtual<T>Method against the parent class
            // resolved from the enclosing fcd's `#extends` clause.
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
                // body-author for BOTH bare and qualified heads (E4 #1 / #2).
                switch (self.selectGenericStructCallee(inner_call.callee, inner_call.callee.span)) {
                    .poisoned => return Ref.none,
                    .template => |t| {
                        const inst_ty = self.instantiateGenericStruct(&t, inner_call.args);
                        const inst_name = self.formatTypeName(inst_ty);
                        if (self.genericInstanceMethod(inst_name, fa.field)) |gm| {
                            if (self.ensureGenericInstanceMethodLowered(gm)) |fid| {
                                const func = &self.module.functions.items[@intFromEnum(fid)];
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
                        if (fd.type_params.len > 0) {
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
                                    // stored at runtime so match/C-interop agree
                                    // (issue 0281).
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
                        self.selectedFuncId(sf, fd.name);
                    const func = &self.module.functions.items[@intFromEnum(fid)];
                    self.packVariadicCallArgs(fd, c, &args);
                    const final_args = self.prependCtxIfNeeded(func, args.items);
                    self.coerceCallArgs(final_args, func.params);
                    if (func.is_variadic) self.promoteCVariadicArgs(final_args, func.params.len);
                    return self.builder.call(fid, final_args, func.ret);
                }

                // A static method on a plain struct is selected from the
                // nominal type head's author, not the global last-wins
                // `StructName.method` entry (issue 0320). This precedes
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
                            const is_variadic = func.is_variadic;
                            self.packVariadicCallArgs(fd, c, &args);
                            const final_args = blk: {
                                if (!has_ctx) break :blk args.items;
                                const new_args = self.alloc.alloc(Ref, args.items.len + 1) catch break :blk args.items;
                                new_args[0] = self.current_ctx_ref;
                                @memcpy(new_args[1..], args.items);
                                break :blk new_args;
                            };
                            self.coerceCallArgs(final_args, params);
                            if (is_variadic) self.promoteCVariadicArgs(final_args, params.len);
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
                            d.addFmt(.err, fa.object.span, "type '{s}' is not visible; #import the module that declares it", .{head});
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
                // The carry gate (issue 0114): a plain-identifier root that is
                // a namespace ALIAS (not a type / fn global name — those are
                // the `Type.method` paths below) must be visible under the
                // carry rule, and its fn members dispatch pinned to the
                // alias's TARGET module — never the global first-wins
                // qualified registration, never the last-wins bare fallback.
                gate: {
                    // A qualified call which selected an exact author above has
                    // already returned and must never be re-selected through
                    // this legacy one-segment gate.
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
                            const fid = self.selectedFuncId(&sf, fa.field);
                            const func = &self.module.functions.items[@intFromEnum(fid)];
                            self.packVariadicCallArgs(fd, c, &args);
                            const final_args = self.prependCtxIfNeeded(func, args.items);
                            self.coerceCallArgs(final_args, func.params);
                            if (func.is_variadic) self.promoteCVariadicArgs(final_args, func.params.len);
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
                                    d.addFmt(.err, fa.object.span, "namespace '{s}' is not visible; #import the module that declares it", .{oname});
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
                    if (func.is_variadic) self.promoteCVariadicArgs(final_args, params.len);
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
                            // is stored at runtime (issue 0281).
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

            // Check if field is a closure type — call as closure, not method
            if (!obj_ty.isBuiltin()) {
                const field_name_id = self.module.types.internString(fa.field);
                const struct_fields = self.getStructFields(obj_ty);
                for (struct_fields, 0..) |f, fi| {
                    if (f.name == field_name_id and !f.ty.isBuiltin()) {
                        const fti = self.module.types.get(f.ty);
                        if (fti == .closure) {
                            // Exact-arity + spread-placeholder validation
                            // against the field's closure TYPE (issue 0188).
                            if (checkCallableValueArgs(self, "closure", fa.field, args.items, fti.closure.params.len, fti.closure.pack_start, c, c.callee.span)) return Ref.none;
                            // structGet requires an aggregate value; if obj is *T, load through it first.
                            var agg = obj;
                            const oi = self.module.types.get(obj_ty);
                            if (oi == .pointer) {
                                agg = self.builder.load(obj, oi.pointer.pointee);
                            }
                            const closure_val = self.builder.structGet(agg, @intCast(fi), f.ty);
                            // Coerce user args to the closure's param types (issue 0186).
                            coerceClosureCallArgs(self, args.items, fti.closure.params);
                            // Prepend ctx for sx-side closure call ABI.
                            const owned = if (self.implicit_ctx_enabled) blk: {
                                const arr = self.alloc.alloc(Ref, args.items.len + 1) catch unreachable;
                                arr[0] = self.current_ctx_ref;
                                @memcpy(arr[1..], args.items);
                                break :blk arr;
                            } else self.alloc.dupe(Ref, args.items) catch unreachable;
                            return self.builder.emit(.{ .call_closure = .{ .callee = closure_val, .args = owned } }, fti.closure.ret);
                        }
                        // Bare function-pointer field (`fp: (T) -> R`, no env) —
                        // load the field value and call it via `call_indirect`,
                        // mirroring the bare-identifier / global fn-pointer paths
                        // (ctx prepend gated on the fn-ptr's own ABI).
                        if (fti == .function) {
                            // Exact-arity + spread-placeholder validation
                            // against the field's fn-pointer TYPE (issue 0188).
                            if (checkCallableValueArgs(self, "function pointer", fa.field, args.items, fti.function.params.len, fti.function.pack_start, c, c.callee.span)) return Ref.none;
                            var agg = obj;
                            const oi = self.module.types.get(obj_ty);
                            if (oi == .pointer) {
                                agg = self.builder.load(obj, oi.pointer.pointee);
                            }
                            const fp_val = self.builder.structGet(agg, @intCast(fi), f.ty);
                            // Coerce user args to the fn-ptr's param types (issue 0186).
                            coerceClosureCallArgs(self, args.items, fti.function.params);
                            var final_args = std.ArrayList(Ref).empty;
                            defer final_args.deinit(self.alloc);
                            if (self.fnPtrTypeWantsCtx(f.ty)) {
                                final_args.append(self.alloc, self.current_ctx_ref) catch unreachable;
                            }
                            final_args.appendSlice(self.alloc, args.items) catch unreachable;
                            const owned = self.alloc.dupe(Ref, final_args.items) catch unreachable;
                            return self.builder.emit(.{ .call_indirect = .{ .callee = fp_val, .args = owned } }, fti.function.ret);
                        }
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
                    return self.emitProtocolDispatch(obj, proto_info, fa.field, args.items, obj_ty, c.callee.span);
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
                            return self.emitProtocolDispatch(pv, proto_info, fa.field, args.items, oi.pointer.pointee, c.callee.span);
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
                            return self.emitProtocolDispatch(obj, proto_info, fa.field, args.items, pay_ty, c.callee.span);
                        }
                    }
                    // `?*P` (optional VIEW, issue 0310): the optional of a
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
                                    return self.emitProtocolDispatch(pv, proto_info, fa.field, args.items, pay_info.pointer.pointee, c.callee.span);
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
            // type is an alias declared by `#jni_class("...") { ... }`
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
                    if (self.ensureGenericInstanceMethodLowered(gm)) |fid| {
                        const func = &self.module.functions.items[@intFromEnum(fid)];
                        const ret_ty = func.ret;
                        const params = func.params;
                        self.fixupMethodReceiver(&method_args, func, effective_obj_node, obj_ty);
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

                        var gbindings = self.genericResolver().buildTypeBindings(gen_fd, eff_args.items);
                        defer gbindings.deinit();

                        const generic_base = if (nominal_method) |m| self.plainStructMethodName(m) else qualified;
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
                            for (gen_fd.params[1..]) |p| {
                                if (isTypeParamDecl(&p, gen_fd.type_params)) {
                                    if (types_explicit) arg_idx += 1;
                                    continue;
                                }
                                if (arg_idx < method_args.items.len) {
                                    gvalue_args.append(self.alloc, method_args.items[arg_idx]) catch unreachable;
                                }
                                arg_idx += 1;
                            }
                            self.fixupMethodReceiver(&gvalue_args, gfunc, effective_obj_node, obj_ty);
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
                    self.fixupMethodReceiver(&method_args, func, effective_obj_node, obj_ty);
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
                        self.fixupMethodReceiver(&method_args, func, effective_obj_node, obj_ty);
                        if (plain_method_fd) |fd| self.appendDefaultArgs(fd, &method_args, c.callee);
                        // Note: coerceCallArgs can trigger protocol thunk creation
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
            // callable directly or via `|>` only — a dot-call on one gets a
            // tailored diagnostic rather than silently becoming a method.
            //
            // R5 §C: a free-function UFCS target with a
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
                // expansion all line up with `fd.params[0]` (issue 0151).
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
                        // issue 0157: the last-wins `fn_ast_map` winner may be a
                        // same-named generic ufcs from another module whose
                        // receiver doesn't match. Only when it fails to bind all
                        // its type-params for THIS receiver do we re-select the
                        // receiver-matching author — so a working call is never
                        // perturbed; the previously-panicking path either finds
                        // the right candidate or emits a clean diagnostic
                        // (never an `.unresolved` reaching codegen).
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
                        var gbindings = self.genericResolver().buildTypeBindings(fd, eff_args.items);
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
                            for (fd.params[1..]) |p| {
                                if (isTypeParamDecl(&p, fd.type_params)) {
                                    if (types_explicit) arg_idx += 1;
                                    continue;
                                }
                                if (arg_idx < method_args.items.len) {
                                    gvalue_args.append(self.alloc, method_args.items[arg_idx]) catch unreachable;
                                }
                                arg_idx += 1;
                            }
                            self.fixupMethodReceiver(&gvalue_args, gfunc, effective_obj_node, obj_ty);
                            const final_args = self.prependCtxIfNeeded(gfunc, gvalue_args.items);
                            self.coerceCallArgs(final_args, gparams);
                            return self.builder.call(gfid, final_args, gret_ty);
                        }
                        return self.emitError(eff_field, c.callee.span);
                    }
                }
                const ufcs_arity_fd: ?*const ast.FnDecl = if (sel_author) |sf| sf.decl else ufcs_fd;
                if (ufcs_arity_fd) |fd| {
                    if (self.checkCallArity(fd, fa.field, method_args.items.len, true, c.callee.span)) return Ref.none;
                }
                const ufcs_fid: ?FuncId = blk_uf: {
                    if (sel_author) |sf| {
                        break :blk_uf self.selectedFuncId(sf, eff_field);
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
                    self.fixupMethodReceiver(&method_args, func, effective_obj_node, obj_ty);
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
                    d.addHelpFmt(id, c.callee.span, null, "call it directly (`{s}(receiver, ...)`), pipe it (`receiver |> {s}(...)`), or declare it `{s} :: ufcs (...) {{ ... }}`", .{ fa.field, fa.field, fa.field });
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
                    if (!tgt.isBuiltin() and self.module.types.get(tgt) == .tagged_union) break :blk tgt;
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
            // runtime so a payloadful match/C-interop agree (issue 0281).
            const ord = self.resolveVariantIndex(target, el.name);
            const tag = self.resolveVariantValue(target, el.name);
            var payload = if (args.items.len > 0) args.items[0] else Ref.none;
            // Coerce payload to match the field type. Coerce from the value's
            // ACTUAL lowered type (`getRefType`), not a re-inference of the
            // arg node: an anonymous payload literal (`.key_up(.{ ... })`)
            // re-infers as the STEERING target (the union type itself, from a
            // return/binding context), and that phantom `union → payload`
            // mismatch trips the unmodeled-coercion guard (issue 0191). The
            // lowered ref's type is authoritative (same rule as issue 0175).
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
            // Indirect call through expression. The callee can be a plain
            // function pointer OR a closure value (e.g. `g!()` where
            // `g : ?Closure(...)` — the force-unwrap yields the closure
            // struct). Inspect the callee's static type so we emit the
            // right op: `call_closure` splits `{fn_ptr, env}` and threads
            // env (and implicit ctx), whereas `call_indirect` would treat
            // the whole struct as a bare fn pointer and miscompile.
            const callee_ty = self.inferExprType(c.callee);
            if (!callee_ty.isBuiltin()) {
                const cti = self.module.types.get(callee_ty);
                if (cti == .closure) {
                    // Exact-arity + spread-placeholder validation against
                    // the callee expression's closure TYPE (issue 0188).
                    if (checkCallableValueArgs(self, "closure", null, args.items, cti.closure.params.len, cti.closure.pack_start, c, c.callee.span)) return Ref.none;
                    const callee_ref = self.lowerExpr(c.callee);
                    // Coerce user args to the closure's param types (issue 0186).
                    coerceClosureCallArgs(self, args.items, cti.closure.params);
                    // Prepend implicit ctx for the sx-side closure call ABI
                    // (emit_llvm builds the call as [ctx, env, user_args]).
                    const owned = if (self.implicit_ctx_enabled) blk: {
                        const arr = self.alloc.alloc(Ref, args.items.len + 1) catch unreachable;
                        arr[0] = self.current_ctx_ref;
                        @memcpy(arr[1..], args.items);
                        break :blk arr;
                    } else self.alloc.dupe(Ref, args.items) catch unreachable;
                    return self.builder.emit(.{ .call_closure = .{ .callee = callee_ref, .args = owned } }, cti.closure.ret);
                }
            }
            // Plain function-pointer indirect call. Use the callee's static
            // return type when known instead of a hardcoded `.i64` default.
            if (!callee_ty.isBuiltin()) {
                const cti = self.module.types.get(callee_ty);
                if (cti == .function) {
                    // Exact-arity + spread-placeholder validation against the
                    // callee expression's fn-pointer TYPE (issue 0188).
                    if (checkCallableValueArgs(self, "function pointer", null, args.items, cti.function.params.len, cti.function.pack_start, c, c.callee.span)) return Ref.none;
                }
            }
            const ret_ty: TypeId = if (!callee_ty.isBuiltin()) blk: {
                const cti = self.module.types.get(callee_ty);
                break :blk if (cti == .function) cti.function.ret else .i64;
            } else .i64;
            const callee_ref = self.lowerExpr(c.callee);
            const owned = self.alloc.dupe(Ref, args.items) catch unreachable;
            return self.builder.emit(.{ .call_indirect = .{ .callee = callee_ref, .args = owned } }, ret_ty);
        },
    }
}

/// Emit a diagnostic for code that needs `Context` (allocator
/// protocol, `push Context.{...}`, the `context` identifier) when
/// the program hasn't registered the type — i.e. doesn't transitively
/// import `modules/std.sx`. Returns a placeholder Ref so the lowering
/// can keep going and surface any additional errors.
pub fn diagnoseMissingContext(self: *Lowering, what: []const u8) Ref {
    if (self.diagnostics) |d| {
        const span = ast.Span{ .start = 0, .end = 0 };
        const id = d.addFmtId(.err, span, "{s} requires the Context type — add `#import \"modules/std.sx\";` (or a module that imports it)", .{what});
        // O3: a no-context build may still COMPILE `#context_extend`
        // declarations (they are inert without Context). Show what the
        // program's context would have been, so the demand is traceable.
        self.noteRegisteredContextFields(id);
    }
    return self.emitPlaceholder("missing-context");
}

/// Emit `context.allocator.alloc(size)` dispatch — used by internal
/// compiler-driven heap copies (e.g. the `xx value` protocol-erasure
/// path in `buildProtocolValue`). Routes through whatever allocator is
/// currently installed in `context`, so a surrounding
/// `push Context.{ allocator = my_alloc, ... }` actually backs every
/// allocation including the ones the compiler inserts.
///
/// If `Context` isn't registered (the program doesn't import std.sx),
/// emits a diagnostic and returns a placeholder. We deliberately do
/// NOT fall back to a direct libc malloc — that was the silent escape
/// hatch that bit us through the implicit-context refactor (see the
/// "Silent unimplemented arms" REJECTED PATTERN in CLAUDE.md).
pub fn allocViaContext(self: *Lowering, size_ref: Ref, void_ptr_ty: TypeId) Ref {
    if (!self.implicit_ctx_enabled or self.current_ctx_ref == Ref.none) {
        return self.diagnoseMissingContext("heap allocation");
    }
    const ctx_ty = self.module.types.findByName(self.module.types.internString("Context")) orelse {
        return self.diagnoseMissingContext("heap allocation");
    };
    // Resolve `allocator` by name against the ASSEMBLED layout — never by
    // index (the field set and order are program-assembled).
    const af = self.contextFieldByName("allocator") orelse {
        return self.diagnoseMissingContext("heap allocation");
    };
    const ctx = self.builder.load(self.current_ctx_ref, ctx_ty);
    const allocator = self.builder.structGet(ctx, af.index, af.ty);
    // #inline Allocator layout: { ctx, __type_id, alloc_fn, dealloc_fn }.
    // field 0 = receiver ctx, field 2 = alloc fn-ptr.
    const alloc_ctx = self.builder.structGet(allocator, 0, void_ptr_ty);
    const fn_ptr = self.builder.structGet(allocator, 2, void_ptr_ty);
    // Allocator thunks are sx-side and carry the implicit __sx_ctx at
    // slot 0. Forward our caller's current_ctx_ref so the thunk's body
    // (and the concrete alloc method it forwards to) has a real
    // Context to thread on.
    const args = if (self.implicit_ctx_enabled)
        self.alloc.dupe(Ref, &.{ self.current_ctx_ref, alloc_ctx, size_ref }) catch unreachable
    else
        self.alloc.dupe(Ref, &.{ alloc_ctx, size_ref }) catch unreachable;
    return self.builder.emit(.{ .call_indirect = .{
        .callee = fn_ptr,
        .args = args,
    } }, void_ptr_ty);
}

/// Emit a call to a extern-declared function looked up by name.
/// Used for the compiler-internal byte-copy in the protocol-erasure
/// heap path and the closure env-copy path, both of which need
/// libc `memcpy` after the `intrinsic` form was dropped.
pub fn callExtern(self: *Lowering, name: []const u8, args: []const Ref, ret_ty: TypeId) Ref {
    const fid = self.resolveFuncByName(name) orelse @panic("extern symbol missing — std.sx not imported?");
    return self.builder.call(fid, args, ret_ty);
}

/// Prepend the caller's current `__sx_ctx` to `args` when the callee
/// has the implicit context param. Returns either the original `args`
/// (when no prepend is needed) or a newly-allocated slice with ctx at
/// slot 0. The returned slice is mutable so callers can pass it
/// straight into `coerceCallArgs`. Direct callers that built the args
/// themselves with __sx_ctx already prepended (protocol thunks, FFI
/// wrappers in Step 4) should NOT call this — they already manage
/// slot 0.
pub fn prependCtxIfNeeded(self: *Lowering, callee: *const Function, args: []Ref) []Ref {
    if (!callee.has_implicit_ctx) return args;
    const new_args = self.alloc.alloc(Ref, args.len + 1) catch return args;
    new_args[0] = self.current_ctx_ref;
    @memcpy(new_args[1..], args);
    return new_args;
}

/// Concrete arg at a PROTOCOL param target: erase NODE-AWARE so
/// `buildProtocolErasure` classifies from the AST — an #identity target
/// BORROWS lvalues (`free(t, gpa)` aliases `gpa`), a value/own target
/// DEMANDS the owning spelling for lvalues/pointers and owning-copies
/// genuine rvalues (a literal-with-init-block materializes through a temp
/// slot, which the node-LESS refStorageAddress heuristic would misread as
/// an lvalue). Returns null when the shape doesn't apply (caller falls
/// through to its normal path).
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
/// Note: "print" is not here — it's a comptime-expanded function, not a builtin.
/// "out" is not either — it's a plain sx function over libc `write`.
pub fn resolveBuiltin(name: []const u8) ?inst_mod.BuiltinId {
    // Every name must be a registered intrinsic to get a builtin op at all.
    const id = intrinsics.findByName(name) orelse return null;
    return switch (id) {
        .sqrt => .sqrt,
        .sin => .sin,
        .cos => .cos,
        .floor => .floor,
        .size_of => .size_of,
        .align_of => .align_of,

        // No `call_builtin` form. The reflection intrinsics fold to a constant in
        // `tryLowerReflectionCall`; `type_name` / `type_is_unsigned` / `type_info`
        // DO have builtin ops but are emitted directly by their folds (as the
        // non-static fallback), never routed through here; the atomics lower to
        // dedicated atomic ops. Listed exhaustively on purpose — a new intrinsic
        // must decide here rather than fall through a catch-all.
        .type_of,
        .type_name,
        .is_unsigned,
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
        .is_identity,
        .error_name,
        .vector_lanes,
        .__sx_variant_tag_width,
        .any_element,
        .raw_any_data,
        .raw_make_any,
        .type_info,
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
    var bindings = self.genericResolver().buildTypeBindings(fd, call_node.args);
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

    const types_passed_explicitly = call_node.args.len == fd.params.len;
    const mangled_name = self.genericResolver().mangleGenericName(base_name, fd, &bindings);

    if (!self.lowered_functions.contains(mangled_name)) {
        // Record this call as the instantiation site for the mono's body:
        // a surviving `#error` inside it anchors HERE (outermost frame of
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
        const final_args = self.prependCtxIfNeeded(func, value_args.items);
        self.coerceCallArgs(final_args, params);
        return self.builder.call(fid, final_args, ret_ty);
    }

    return self.emitError(base_name, call_node.callee.span);
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
        .type_of,
        .type_name,
        .is_unsigned,
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
        .is_identity,
        .error_name,
        .vector_lanes,
        .__sx_variant_tag_width,
        .any_element,
        .raw_any_data,
        .raw_make_any,
        .type_info,
        .sqrt,
        .sin,
        .cos,
        .floor,
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
/// no declaration at all (`type_eq`, `has_impl`, …). The two are listed apart on
/// purpose: only the first group answers to the registry, and conflating them is
/// what let a name with no declaration look like an intrinsic.
fn isReflectionCall(name: []const u8) bool {
    const keywords = [_][]const u8{
        "type_eq",               "has_impl",
        "is_struct",             "is_comptime",
        "__interp_print_frames",
        "__trace_resolve_frame",
    };
    for (keywords) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    const id = intrinsics.findByName(name) orelse return false;
    return switch (id) {
        .size_of,
        .align_of,
        .type_of,
        .type_name,
        .is_unsigned,
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
        .is_identity,
        .error_name,
        .vector_lanes,
        .__sx_variant_tag_width,
        .any_element,
        .raw_any_data,
        .raw_make_any,
        .type_info,
        => true,

        // Lowered elsewhere: math -> `call_builtin`, atomics -> atomic ops.
        .sqrt,
        .sin,
        .cos,
        .floor,
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

    // `declare(name)` and `define(handle, info)` are now ordinary sx functions
    // (`modules/std/meta.sx`) written over the `intrinsic` primitives
    // (`declare_type` / `register_type`) — no longer intercepted here.
    // (`preregisterForwardTypes` still scans for the literal `declare("Name")`
    // spelling so a `*Name` self-reference forward-registers before the body
    // lowers; the sx `declare` calls `declare_type`, which returns that slot.
    // The `.enum(…)` arg to `define` now infers `TypeInfo` from the sx fn's
    // declared param type via the ordinary call path's target-type threading.)
    if (std.mem.eql(u8, name, "type_info")) {
        // Comptime reflection-into-data: reflect a type INTO a `TypeInfo`
        // value (the inverse of `define`'s decode). Resolve `$T` at lower
        // time, then emit a `callBuiltin(.type_info, [const_type])` the
        // interp executes against its type table — it reads the variants
        // (name + payload) and constructs the same `.enum(EnumInfo{ … })`
        // value `define` decodes, so the two round-trip. Result type is
        // `TypeInfo`; the whole `define(declare(), type_info(T))` expr is
        // comptime-evaluated, so this builtin never reaches codegen.
        if (c.args.len != 1) {
            if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "type_info($T) takes one type argument", .{});
            return Ref.none;
        }
        const ti_ty = self.module.types.findByName(self.module.types.internString("TypeInfo")) orelse {
            if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "type_info needs `TypeInfo` in scope — import `modules/std/meta.sx`", .{});
            return Ref.none;
        };
        if (!self.isStaticTypeArg(c.args[0])) {
            // Runtime Type (1a-S3b-3): load the const record by tag.
            const tp = self.lowerExpr(c.args[0]);
            const args_owned = self.alloc.dupe(Ref, &.{tp}) catch return Ref.none;
            return self.builder.callBuiltin(.type_info, args_owned, ti_ty);
        }
        const t = self.resolveTypeArg(c.args[0]);
        // Every type-table kind reflects (1a-S3a — TypeInfo is exhaustive
        // over kinds; the VM's record builder classifies each and fails
        // loudly on an unclassified one). Only an unresolved arg rejects.
        if (t == .unresolved) {
            if (self.diagnostics) |d| d.addFmt(.err, c.args[0].span, "type_info: unresolved type argument", .{});
            return Ref.none;
        }
        const type_ref = self.builder.constType(t);
        const args_owned = self.alloc.dupe(Ref, &.{type_ref}) catch return Ref.none;
        return self.builder.callBuiltin(.type_info, args_owned, ti_ty);
    }
    if (std.mem.eql(u8, name, "size_of")) {
        // size_of(T) → const_int(sizeof(T)); runtime Type arg → tag-indexed
        // size-table read (1a-S2). Same static/dynamic split as type_name —
        // the dynamic path never touches resolveTypeArg.
        if (!self.isStaticTypeArg(c.args[0])) {
            const arg_ref = self.lowerExpr(c.args[0]);
            const args_owned = self.alloc.dupe(Ref, &.{arg_ref}) catch return self.builder.constInt(0, .i64);
            return self.builder.callBuiltin(.rt_size_of, args_owned, .i64);
        }
        const ty = self.resolveTypeArg(c.args[0]);
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
        const a: i64 = @intCast(self.module.types.typeAlignBytes(ty));
        return self.builder.constInt(a, .i64);
    }
    if (std.mem.eql(u8, name, "struct_field_count") or std.mem.eql(u8, name, "variant_count")) {
        // Runtime Type arg (1a-S2): tag-indexed count-table read. Kind gates
        // are a STATIC-arg feature; at runtime the table answers (a wrong-kind
        // tag reads 0 — kind discrimination at runtime is type_info's job).
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
            .tuple => |t| return self.builder.constInt(@intCast(t.fields.len), .i64),
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
    if (std.mem.eql(u8, name, "type_name")) {
        // type_name(T):
        //   - Statically resolvable arg (type expression, pack
        //     index, generic binding, etc.) → fold to const_string
        //     at lower time.
        //   - Dynamic arg (e.g. `list[i]` indexing into a
        //     `$args`-derived []Type slice) → emit a
        //     `callBuiltin(.type_name, [arg_ref])`. The interp's
        //     arm (commit 9600ba5) reads the runtime `.type_tag`
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
            // Runtime tag compare (1a-S2): Type is an i64 tag at runtime, so
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
    if (std.mem.eql(u8, name, "is_unsigned")) {
        // type_is_unsigned(T) → bool. Static arg (a spelled type or
        // generic binding) folds to const_bool at lower time. A
        // dynamic arg — the runtime `type_of(x)` value queried by
        // `any_to_string` — emits a `callBuiltin`: the interp reads
        // the boxed TypeId, LLVM GEPs a per-type signedness table.
        // Mirrors `type_name`'s static/dynamic split; the same split
        // avoids `resolveTypeArg`'s silent `.i64` default lying about
        // a runtime Type value.
        if (c.args.len < 1) return self.builder.constBool(false);
        if (self.isStaticTypeArg(c.args[0])) {
            const ty = self.resolveTypeArg(c.args[0]);
            return self.builder.constBool(self.module.types.isUnsignedInt(ty));
        }
        const arg_ref = self.lowerExpr(c.args[0]);
        const args_owned = self.alloc.dupe(Ref, &.{arg_ref}) catch return self.builder.constBool(false);
        return self.builder.callBuiltin(.is_unsigned, args_owned, .bool);
    }
    if (std.mem.eql(u8, name, "has_impl")) {
        // has_impl(P, T) → const_bool. Returns true when type T has
        // a reachable impl for protocol P. P is either:
        // - plain protocol name (`Hash`, `Eq`) for unary protocols;
        // - parameterised call like `Into(Block)` — for protocols
        //   with type args, the args must be fully spelled.
        // Delegates to `computeHasImpl` (shared with the
        // `tryConstBoolCondition` arm so `inline if has_impl(...)`
        // folds at compile time).
        if (c.args.len < 2) return self.builder.constBool(false);
        const ty = self.resolveTypeArg(c.args[1]);
        return self.builder.constBool(self.computeHasImpl(c.args[0], ty));
    }
    if (std.mem.eql(u8, name, "vector_lanes")) {
        // vector_lanes(T) → the lane COUNT. The one vector length the flat
        // size tables cannot answer (ABI size is pow2-rounded — 3 lanes
        // occupy 4). Static arg folds; a runtime Type reads the lane table
        // (non-vector tags answer 0 — kind discrimination is type_info's
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
    if (std.mem.eql(u8, name, "is_identity")) {
        // STATIC-ONLY (like the `protocol` category in inline type match): a
        // runtime Type value is always a CONCRETE type's tag — a protocol
        // type never appears as a runtime tag, so a runtime form would be
        // constant false. Demand the static spelling instead of lying.
        if (!self.isStaticTypeArg(c.args[0])) {
            if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "is_identity expects a compile-time type — a runtime 'Type' value always tags a concrete type, never a protocol", .{});
            return self.builder.constBool(false);
        }
        const ty = self.resolveTypeArg(c.args[0]);
        if (self.getProtocolInfo(ty)) |pi| return self.builder.constBool(pi.ownership == .identity);
        return self.builder.constBool(false);
    }
    if (std.mem.eql(u8, name, "is_struct")) {
        // is_struct(T) → const_bool: true iff T is a nominal `struct`. A
        // comptime type-kind predicate that folds at lower time (mirrors the
        // `tryConstBoolCondition` arm so `inline if is_struct(T)` gates
        // field-wise reflection). Any non-struct (enum, scalar, pointer, …) is
        // false — routing an enum key to a leaf byte-hash (issue 0274).
        if (c.args.len < 1) return self.builder.constBool(false);
        const ty = self.resolveTypeArg(c.args[0]);
        if (ty.isBuiltin() or ty == .unresolved) return self.builder.constBool(false);
        return self.builder.constBool(self.module.types.get(ty) == .@"struct");
    }
    if (std.mem.eql(u8, name, "struct_field_name") or std.mem.eql(u8, name, "variant_name")) {
        if (c.args.len < 2) return self.builder.constString(self.module.types.internString(""));
        if (!self.isStaticTypeArg(c.args[0])) {
            // Runtime Type (1a-S3b): master-index member-name table read.
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
    if (std.mem.eql(u8, name, "is_comptime")) {
        // True under the comptime interpreter, false in compiled code — the
        // op decides per backend (it can't fold here, since the same IR
        // serves both). Lets stdlib gate a comptime-only diagnostic branch.
        return self.builder.emit(.{ .is_comptime = {} }, .bool);
    }
    if (std.mem.eql(u8, name, "__interp_print_frames")) {
        // Backs `trace.print_interpreter_frames()`: dumps the interp call
        // chain at comptime, no-op in compiled code (ERR E4.1).
        return self.builder.emit(.{ .interp_print_frames = {} }, .void);
    }
    if (std.mem.eql(u8, name, "__trace_resolve_frame")) {
        // Backs `trace.sx`'s formatter: a raw trace-buffer u64 → a `TraceFrame`.
        // Compiled code reinterprets the operand as `*TraceFrame` and loads it;
        // the interp unpacks (func_id, span.start) and resolves (ERR E3.0
        // slice 3b). Result type is the `TraceFrame` struct from trace.sx.
        const frame_ty = self.module.types.findByName(self.module.types.internString("TraceFrame")) orelse {
            if (self.diagnostics) |d| d.addFmt(.err, null, "`__trace_resolve_frame` needs `TraceFrame` (from trace.sx) in scope", .{});
            return self.builder.constInt(0, .void);
        };
        const arg = self.lowerExpr(c.args[0]);
        return self.builder.emit(.{ .trace_resolve = .{ .operand = arg } }, frame_ty);
    }
    if (std.mem.eql(u8, name, "error_name")) {
        // error_tag_name(e) → look the error-set value's runtime tag id up
        // in the always-linked tag-name table. The value IS its u32 tag id.
        if (c.args.len < 1) return self.builder.constString(self.module.types.internString(""));
        const e = self.lowerExpr(c.args[0]);
        return self.builder.emit(.{ .error_tag_name_get = .{ .operand = e } }, .string);
    }
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
                ti == .@"struct" or ti == .tuple or ti == .@"union";
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
            // Builtin receiver (`any` today) — the fields-empty arm never
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
        // raw_any_data(av) → the view's data pointer (C2 raw layer).
        if (c.args.len < 1) return self.builder.constInt(0, .i64);
        const av = self.lowerExpr(c.args[0]);
        return self.builder.anyData(av, self.module.types.ptrTo(.void));
    }
    if (std.mem.eql(u8, name, "raw_make_any")) {
        // raw_make_any(tp, data) → assemble a view (C2 raw layer, UNCHECKED
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
                d.addFmt(.err, c.args[1].span, "raw_make_any expects a pointer for 'data' (got '{s}') — pass the value's address (`@v`, or a raw_any_data result)", .{self.formatTypeName(data_ty)});
            }
            return self.builder.constInt(0, .any);
        }
        return self.builder.makeAny(tp, data);
    }
    if (std.mem.eql(u8, name, "type_of")) {
        // type_of(val) — produce a Type value (`.type_value`, a bare i64 handle).
        if (c.args.len < 1) return self.builder.constType(.void);
        const arg_ty = self.inferExprType(c.args[0]);
        if (arg_ty == .any) {
            // Runtime: the held value's type is the view's type_id word
            // (field 1 — the {data, type_id} layout). Read it out AS the
            // 8-byte `.type_value` handle.
            const val = self.lowerExpr(c.args[0]);
            return self.builder.structGet(val, 1, .type_value);
        } else if (self.getProtocolInfo(arg_ty) != null) {
            // A PROTOCOL value answers its CONCRETE type — the type_id
            // word at slot 1 (RTTI Option B), same position as an any's.
            const val = self.lowerExpr(c.args[0]);
            return self.builder.structGet(val, 1, .type_value);
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
            // Runtime Type (1a-S3b): field-offset table read.
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
                .@"struct", .tuple, .@"union" => {
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
            // Runtime Type (1a-S3b): member-type tag table read → Type value.
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
        // out-of-range index → out-of-bounds GEP → segfault (issue 0277).
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
            // out-of-range variant name (issue 0277 for plain enums, issue 0280
            // for tagged unions). Reverse-map the tag → ordinal for either kind.
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
                // (a distinct construction bug — see issue 0281); the identity
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
    return null;
}

/// Strict `$T: Type` classification shared by the 7 type-introspection
/// builtins. An argument denotes a type iff it is a spelled /
/// compile-time type or generic type parameter (the `isStaticTypeArg`
/// shapes), or a runtime `Type` value — which is `.type_value`-typed at
/// runtime (`type_of(x)`, a `[]Type` element `list[i]`, a `Type`-typed
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

pub fn reflectionTypeArgGuard(self: *Lowering, name: []const u8, c: *const ast.Call) ?Ref {
    const arity: usize = if (std.mem.eql(u8, name, "type_eq"))
        2
    else if (std.mem.eql(u8, name, "size_of") or
        std.mem.eql(u8, name, "align_of") or
        std.mem.eql(u8, name, "struct_field_count") or
        std.mem.eql(u8, name, "variant_count") or
        std.mem.eql(u8, name, "type_name") or
        std.mem.eql(u8, name, "is_unsigned") or
        std.mem.eql(u8, name, "is_flags") or
        std.mem.eql(u8, name, "is_struct"))
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
/// diagnoses a non-type argument: a string for `type_name`, a bool for
/// the predicate builtins, an int for the size / count builtins. Never
/// observed at runtime — the diagnostic already fails the build — but
/// keeps the IR well-typed so lowering can finish and report every
/// error in one pass.
pub fn reflectionErrorSentinel(self: *Lowering, name: []const u8) Ref {
    if (std.mem.eql(u8, name, "type_name"))
        return self.builder.constString(self.module.types.internString(""));
    if (std.mem.eql(u8, name, "type_eq") or
        std.mem.eql(u8, name, "is_unsigned") or
        std.mem.eql(u8, name, "is_flags") or
        std.mem.eql(u8, name, "is_struct"))
        return self.builder.constBool(false);
    return self.builder.constInt(0, .i64);
}

/// Clone one declared default into this call. Ordinary defaults carry the
/// function author's source so `lowerExpr` resolves their bare names under the
/// signature's authority. `#caller_location` is the deliberate exception: it
/// is re-authored at the call site, preserving caller file/span/function.
fn defaultArgAtCall(
    self: *Lowering,
    dflt: *const Node,
    author_source: ?[]const u8,
    call_site: *const Node,
) ?*Node {
    const n = self.alloc.create(Node) catch return null;
    n.* = dflt.*;
    if (dflt.data == .caller_location) {
        n.span = call_site.span;
        n.source_file = call_site.source_file orelse self.current_source_file;
    } else {
        const caller_site = lower.DefaultCallSite{
            .source = call_site.source_file orelse self.current_source_file,
            .span = call_site.span,
            .caller_func = self.builder.func,
        };
        if (author_source orelse self.current_source_file) |src| n.source_file = src;
        self.authored_call_defaults.put(n, caller_site) catch return null;
    }
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
        const dflt = fd.params[i].default_expr orelse break;

        // Defaults are argument expressions too: give aggregate/enum/null
        // shorthand the declaration's parameter target instead of leaking an
        // ambient target from the enclosing caller. Resolve the type in the
        // function author's source (resolveDeclParamType owns that pin). The
        // default cannot capture caller locals; contextual values such as
        // `context.allocator` resolve through the implicit context channel.
        const saved_target = self.target_type;
        const param_ty = self.resolveDeclParamType(fd, i);
        self.target_type = if (param_ty == .unresolved or param_ty == .void) null else param_ty;
        const authored = defaultArgAtCall(self, dflt, fd.body.source_file, call_site) orelse break;
        const v = self.lowerExpr(authored);
        self.target_type = saved_target;
        args.append(self.alloc, v) catch unreachable;
    }
}

/// Reject a direct call whose argument count cannot bind to the callee's
/// declared parameter list. `supplied` counts the args as they bind to
/// params — receiver included for dot-dispatch, defaults not yet
/// appended. Returns true when a diagnostic was emitted (the call must
/// not lower). Pack / comptime / generic / `#compiler` / `intrinsic`
/// callees bind args through their own dispatch and are exempt.
pub fn checkCallArity(self: *Lowering, fd: *const ast.FnDecl, callee_name: []const u8, supplied: usize, has_receiver: bool, span: ast.Span) bool {
    if (fd.type_params.len > 0 or hasComptimeParams(fd) or isPackFn(fd)) return false;
    switch (fd.body.data) {
        .intrinsic_expr => return false,
        else => {},
    }
    var min: usize = 0;
    var max: ?usize = fd.params.len;
    for (fd.params, 0..) |p, i| {
        if (p.is_variadic) {
            max = null;
            break;
        }
        if (p.default_expr == null) min = i + 1;
    }
    if (supplied >= min and (max == null or supplied <= max.?)) return false;
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

/// Argument validation for a call through a callable VALUE — a closure
/// value or a fn-pointer value — which has no `ast.FnDecl` for the
/// decl-based `checkCallArity` to consume (issue 0188). `params` is the
/// callable TYPE's user-visible param list (closure/function type params
/// never include the implicit `__sx_ctx` slot — that is prepended
/// separately per `fnPtrTypeWantsCtx` / `implicit_ctx_enabled`); `args`
/// the lowered user args with tuple/pack spreads already expanded
/// positionally. Two rejections:
///   1. a leftover `Ref.none` spread placeholder — a runtime slice/array
///      spread has no statically-known length to expand and a callable
///      value has no variadic slot to pack into; emitting it would reach
///      the call op as undef (silent garbage);
///   2. an arg-count mismatch — closure/fn-pointer types carry no
///      defaults and no variadic param, so the arity is exact.
/// A pack-variadic callable shape (`Closure(..$args)`, `pack_start !=
/// null`) is skipped entirely, mirroring `checkCallArity`'s `isPackFn`
/// bail — its arity is bound per call site, not by `params.len`.
/// Returns true when a diagnostic was emitted; caller returns Ref.none.
fn checkCallableValueArgs(
    self: *Lowering,
    kind: []const u8,
    name: ?[]const u8,
    args: []const Ref,
    params_len: usize,
    pack_start: ?u32,
    c: *const ast.Call,
    span: ast.Span,
) bool {
    if (pack_start != null) return false;
    {
        var buf: [128]u8 = undefined;
        const what: []const u8 = std.fmt.bufPrint(&buf, "a {s}", .{kind}) catch kind;
        if (rejectLeftoverSpreadPlaceholder(self, what, args, c, span)) return true;
    }
    if (args.len != params_len) {
        if (self.diagnostics) |d| {
            const s: []const u8 = if (params_len == 1) "" else "s";
            const verb: []const u8 = if (args.len == 1) "was" else "were";
            if (name) |n| {
                d.addFmt(.err, span, "'{s}' expects {d} argument{s}, but {d} {s} given", .{ n, params_len, s, args.len, verb });
            } else {
                d.addFmt(.err, span, "this {s} expects {d} argument{s}, but {d} {s} given", .{ kind, params_len, s, args.len, verb });
            }
        }
        return true;
    }
    return false;
}

/// Reject a leftover `Ref.none` spread placeholder in a lowered arg list
/// (issues 0188 + 0239): the only producer is a runtime slice/array spread
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

/// True when `fd` declares a variadic param (either surface form — the
/// legacy `name: ..T`, the slice variadic `..name: []T`, or an extern
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
/// method/ufcs dot-call, else 0).
const NamedCallee = struct {
    fd: *const ast.FnDecl,
    source: ?[]const u8,
    receiver_params: usize,
};

/// Resolve the declaration whose parameter NAMES a named-argument call binds
/// against. Mirrors `expandCallDefaults`' author resolution (bare/qualified/
/// static-struct/enum-literal callees) and adds the value-receiver dot-call
/// shapes (plain-struct method, ufcs fn — an alias resolves names against the
/// TARGET's declared params). Null when no declaration is known (closure /
/// fn-pointer values, builtins, protocol methods) — those bind positionally
/// only.
fn namedCalleeDecl(
    self: *Lowering,
    c: *const ast.Call,
    sel_author: ?*const SelectedFunc,
    qualified_selected: bool,
    author_ambiguous: bool,
) ?NamedCallee {
    switch (c.callee.data) {
        .identifier => |id| {
            if (author_ambiguous) return null;
            if (sel_author) |sf| return .{ .fd = sf.decl, .source = sf.source, .receiver_params = 0 };
            if (callableLocalShadow(self, id.name)) return null;
            const eff_name = blk: {
                const scoped = if (self.scope) |scope| scope.lookupFn(id.name) orelse id.name else id.name;
                if (self.ufcsAliasTarget(id.name)) |target| {
                    break :blk if (self.scope) |scope| scope.lookupFn(target) orelse target else target;
                }
                break :blk scoped;
            };
            const fd = self.program_index.fn_ast_map.get(eff_name) orelse return null;
            return .{ .fd = fd, .source = fd.body.source_file, .receiver_params = 0 };
        },
        .field_access => |fa| {
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
            // Value receiver: `obj.m(args)` binds the first param to `obj`.
            var obj_ty = self.inferExprType(fa.object);
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
        else => return null,
    }
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
    author_ambiguous: bool,
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
    const callee = namedCalleeDecl(self, c, sel_author, qualified_selected, author_ambiguous) orelse {
        if (self.diagnostics) |d| {
            if (has_block) {
                d.addFmt(.err, c.callee.span, "cannot use a trailing block here — '{s}' has no known declaration (closure and function-pointer values bind their arguments explicitly)", .{callee_name});
            } else {
                d.addFmt(.err, c.callee.span, "cannot use named arguments here — '{s}' has no known parameter names (closure and function-pointer values, builtins, and protocol methods bind positionally)", .{callee_name});
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
    // the N3 displacement check below.
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
                // (specs: Trailing Blocks): T1 non-variadic Closure (an
                // optional closure slot wraps like any named closure
                // argument), T3 zero-param, N4 duplicate against a named or
                // positional binding of the same parameter.
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
                const closure_ty: TypeId = blk: {
                    if (!pty.isBuiltin()) {
                        const info = self.module.types.get(pty);
                        if (info == .closure) break :blk pty;
                        if (info == .optional and !info.optional.child.isBuiltin() and
                            self.module.types.get(info.optional.child) == .closure)
                        {
                            break :blk info.optional.child;
                        }
                    }
                    break :blk .unresolved;
                };
                if (closure_ty == .unresolved) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "'{s}' cannot take a trailing block — its last parameter '{s}' is not a `Closure`", .{ callee_name, p.name });
                    continue;
                }
                if (self.module.types.get(closure_ty).closure.params.len != 0) {
                    errored = true;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, a.span, "'{s}' expects a parameterized closure for '{s}' — a trailing block is zero-param; pass the closure explicitly", .{ callee_name, p.name });
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
    // N3: evaluation order is written order. The rewrite hands the call
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
            const saved_target = self.target_type;
            const pty = self.resolveDeclParamType(fd, bind.i);
            self.target_type = if (pty == .unresolved or pty == .void) null else pty;
            const ref = self.lowerExpr(bind.v);
            self.target_type = saved_target;
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
    author_ambiguous: bool,
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
                // R5 §C: for a genuine flat same-name
                // collision the omitted trailing args are filled from the
                // author the call resolver selected — its `*FnDecl` defaults —
                // not the first-wins winner's. lowering consumes the ONE author
                // verdict (`selectedFreeAuthor`, computed once in `lowerCall`)
                // rather than re-resolving the name, so default expansion and
                // dispatch agree on the author. `.ambiguous` declines to expand
                // (the call path emits the single diagnostic); a non-collision
                // call keeps the existing first-wins winner, byte-for-byte.
                // Reading `.decl` only keeps `materialized` null — inspecting
                // defaults must not lower the author (0102d).
                if (author_ambiguous) return null;
                if (sel_author) |sf| break :blk sf.decl;
                // A callable LOCAL binding shadows the top-level fn (issue
                // 0217, review F2): the shadowed-out global's defaults must
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
    // Param slots the written args actually consume (issue 0188 review F2):
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
        .tuple => |t| t.fields.len,
        // A struct value spreads field-wise (the anonymous positional
        // struct is the tuple's successor) — its width is its field count.
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
/// resolved in the callee's own module context (the E4 source pin — see
/// `resolveParamTypeInSource`). A generic callee's bare `T` leaves mean
/// nothing as nominal names in that module: without this call's inferred
/// `$T → concrete` bindings the pin would resolve `T` as an undeclared
/// type in a non-main module and diagnose it unknown.
/// Coerce already-lowered closure-call arguments to the closure's declared
/// parameter types (issue 0186). The arg-lowering loop only sets `target_type`
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

fn astCalleeParamTypes(self: *Lowering, fd: *const ast.FnDecl, args: []const *const Node) []const TypeId {
    const saved_bindings = self.type_bindings;
    defer self.type_bindings = saved_bindings;
    var gbindings: ?std.StringHashMap(TypeId) = null;
    defer if (gbindings) |*gb| gb.deinit();
    if (fd.type_params.len > 0) {
        gbindings = self.genericResolver().buildTypeBindings(fd, args);
        self.type_bindings = gbindings.?;
    }
    var types_list = std.ArrayList(TypeId).empty;
    for (fd.params, 0..) |_, param_idx| {
        types_list.append(self.alloc, self.resolveDeclParamType(fd, param_idx)) catch unreachable;
    }
    return types_list.items;
}

pub fn resolveCallParamTypes(
    self: *Lowering,
    c: *const ast.Call,
    sel_author: ?*SelectedFunc,
    qualified_selected: bool,
    qualified_callable: ?GlobalInfo,
) []const TypeId {
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
            if (!global.ty.isBuiltin()) {
                const ti = self.module.types.get(global.ty);
                if (ti == .closure) return ti.closure.params;
                if (ti == .function) return ti.function.params;
            }
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
                // byte count to i1 before calling libc; issue 0282).
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
                    return self.userParamTypes(func);
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
        // and dispatch arms (issue 0313: enum-literal args through a view
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
                if (std.mem.eql(u8, m.name, fa.field)) return m.param_types;
            }
        }
        // `*Protocol` receiver (borrowed view): same lookup through the
        // pointee.
        if (!obj_ty.isBuiltin()) {
            const oi = self.module.types.get(obj_ty);
            if (oi == .pointer) {
                if (self.getProtocolInfo(oi.pointer.pointee)) |proto_info| {
                    for (proto_info.methods) |m| {
                        if (std.mem.eql(u8, m.name, fa.field)) return m.param_types;
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
                        if (std.mem.eql(u8, m.name, fa.field)) return m.param_types;
                    }
                }
            }
        }
        // Closure-typed struct field: `c.on(args)` lowers to call_closure on
        // the field value. Pick up the callee's param types from the closure
        // type so each arg gets the right target_type during lowering.
        if (!obj_ty.isBuiltin()) {
            const field_name_id = self.module.types.internString(fa.field);
            const struct_fields = self.getStructFields(obj_ty);
            for (struct_fields) |f| {
                if (f.name == field_name_id and !f.ty.isBuiltin()) {
                    const fti = self.module.types.get(f.ty);
                    if (fti == .closure) return fti.closure.params;
                    if (fti == .function) return fti.function.params;
                }
            }
        }
        if (self.getStructTypeName(obj_ty)) |sname| {
            // Runtime-class receiver (`#objc_class` / `#jni_class` / etc.):
            // resolve the method from `runtime_class_map` walking `#extends`.
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
                        var types_list = std.ArrayList(TypeId).empty;
                        for (md.params[user_param_start..]) |p_node| {
                            types_list.append(self.alloc, self.resolveType(p_node)) catch unreachable;
                        }
                        return types_list.items;
                    }
                    return &.{};
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
            if (self.hasPlainStructAuthor(obj_ty)) return &.{};

            const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ sname, fa.field }) catch return &.{};
            // Try already-lowered functions first
            if (self.resolveFuncByName(qualified)) |fid| {
                const func = &self.module.functions.items[@intFromEnum(fid)];
                // Skip both `__sx_ctx` (if present) AND `self` param;
                // caller args include neither.
                const skip: usize = (if (func.has_implicit_ctx) @as(usize, 1) else 0) + 1;
                if (func.params.len > skip) {
                    var types_list = std.ArrayList(TypeId).empty;
                    for (func.params[skip..]) |p| {
                        types_list.append(self.alloc, p.ty) catch unreachable;
                    }
                    return types_list.items;
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
                    // `slice_to_string__unresolved` (issue 0288). Bind first,
                    // receiver prepended so positions line up with
                    // `fd.params[0] = self`.
                    const saved_bindings = self.type_bindings;
                    defer self.type_bindings = saved_bindings;
                    var gbindings: ?std.StringHashMap(TypeId) = null;
                    defer if (gbindings) |*gb| gb.deinit();
                    if (fd.type_params.len > 0) {
                        var eff_args = std.ArrayList(*const Node).empty;
                        defer eff_args.deinit(self.alloc);
                        eff_args.append(self.alloc, fa.object) catch unreachable;
                        for (c.args) |a| eff_args.append(self.alloc, a) catch unreachable;
                        gbindings = self.genericResolver().buildTypeBindings(fd, eff_args.items);
                        self.type_bindings = gbindings.?;
                    }
                    var types_list = std.ArrayList(TypeId).empty;
                    for (fd.params[1..]) |p| {
                        types_list.append(self.alloc, self.resolveParamTypeInSource(fd.body.source_file, &p)) catch unreachable;
                    }
                    return types_list.items;
                }
            }
            // Generic-struct instance method param types: select the method
            // body via the instance's STAMPED author (CP-4), substituting the
            // instance's bindings so `T → concrete`. The param source-pin
            // follows the selected `fd` (its own `body.source_file`).
            if (self.genericInstanceMethod(sname, fa.field)) |gm| {
                if (gm.fd.params.len > 0) {
                    const saved_bindings = self.type_bindings;
                    self.type_bindings = gm.bindings.*;
                    var types_list = std.ArrayList(TypeId).empty;
                    for (gm.fd.params[1..]) |p| {
                        types_list.append(self.alloc, self.resolveParamTypeInSource(gm.fd.body.source_file, &p)) catch unreachable;
                    }
                    self.type_bindings = saved_bindings;
                    return types_list.items;
                }
            }
        }
        return &.{};
    }
    if (c.callee.data != .identifier) return &.{};
    const bare_name = c.callee.data.identifier.name;
    // Closure / fn-pointer VALUE bound in scope (`g := () => ...; g(args)`):
    // type each arg against the callee value's declared parameter types so a
    // `?T` param wraps the argument (issue 0186) — without this the args lower
    // with no target type and reach `call_closure` unconverted (a concrete arg
    // arrives as a bare payload that reads ABSENT; `null` reaches a `{T,i1}`
    // slot as a bare pointer → LLVM verifier failure). A local value shadows a
    // same-named function, so this precedes the function-name resolution below.
    if (self.scope) |scope| {
        if (scope.lookup(bare_name)) |binding| {
            if (!binding.ty.isBuiltin()) {
                const bti = self.module.types.get(binding.ty);
                if (bti == .closure) return bti.closure.params;
                if (bti == .function) return bti.function.params;
            }
        }
    }
    const name = blk: {
        const scoped = if (self.scope) |scope| scope.lookupFn(bare_name) orelse bare_name else bare_name;
        if (self.ufcsAliasTarget(bare_name)) |target| {
            break :blk if (self.scope) |scope| scope.lookupFn(target) orelse target else target;
        }
        break :blk scoped;
    };

    // R5 §C: a genuine flat same-name collision must type this
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
        const fid = self.selectedFuncId(sf, bare_name);
        const func = &self.module.functions.items[@intFromEnum(fid)];
        return self.userParamTypes(func);
    }

    // Check declared functions
    if (self.resolveFuncByName(name)) |fid| {
        const func = &self.module.functions.items[@intFromEnum(fid)];
        return self.userParamTypes(func);
    }

    // Check AST map for function signatures
    if (self.program_index.fn_ast_map.get(name)) |fd| {
        return astCalleeParamTypes(self, fd, c.args);
    }

    // Check global function pointer variables (quiet author-aware lookup —
    // param typing only; the call site diagnoses ambiguity / visibility)
    if (self.program_index.global_names.get(bare_name)) |gi_global| {
        const gi: ?GlobalInfo = switch (self.selectGlobalAuthor(bare_name)) {
            .resolved => |g| g,
            .untracked => gi_global,
            else => null,
        };
        if (gi) |g| {
            if (!g.ty.isBuiltin()) {
                const ti = self.module.types.get(g.ty);
                if (ti == .function) {
                    return ti.function.params;
                }
            }
        }
    }

    // Check local scope for function pointer variables
    if (self.scope) |scope| {
        if (scope.lookup(bare_name)) |binding| {
            if (!binding.ty.isBuiltin()) {
                const ti = self.module.types.get(binding.ty);
                if (ti == .function) {
                    return ti.function.params;
                }
            }
        }
    }

    return &.{};
}
