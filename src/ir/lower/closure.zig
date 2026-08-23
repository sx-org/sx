const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const type_bridge = @import("../type_bridge.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;

const lower = @import("../lower.zig");
const lower_protocol = @import("protocol.zig");
const Lowering = lower.Lowering;
const Scope = lower.Scope;

/// What a lowered lambda IS — which decides both where its environment lives
/// and where the environment's fields come from.
///   `.literal` — a written `|…|`: its env is exactly the `_{ … }` it wrote and
///                its body is SEALED against the enclosing scope. The value IS
///                that env, living wherever the binding, parameter, or
///                temporary does; `closure(f, alloc)` is the only thing that
///                copies it anywhere else.
///   `.init_recipe` — the NONESCAPING recipe `@Init(T)` forms: the body is the
///                argument expression as written, so its free names are
///                collected where they are still live, and the value is an
///                erased pair whose env stays in the forming frame's alloca
///                (spec §12.1 forbids choosing heap storage for it).
pub const LambdaKind = enum { literal, init_recipe };

/// A `|…|_{ … }` literal's own type: the env struct the literal IS, together
/// with the function that reads it. The value carries no pointer, so a call
/// hands the function the ADDRESS of whatever storage holds the value.
pub const UniqueLambda = struct {
    func: FuncId,
    params: []const TypeId,
    ret: TypeId,
};

/// The unique lambda `ty` IS, or null when `ty` is any other type.
pub fn uniqueLambdaOf(self: *Lowering, ty: TypeId) ?UniqueLambda {
    return self.unique_lambdas.get(ty);
}

/// `uniqueLambdaOf` reaching through one level of `*T`, so `*$F` calls the
/// same function against the env the pointer names.
pub fn uniqueLambdaThrough(self: *Lowering, ty: TypeId) ?UniqueLambda {
    if (uniqueLambdaOf(self, ty)) |u| return u;
    if (ty.isBuiltin()) return null;
    const info = self.module.types.get(ty);
    if (info != .pointer) return null;
    return uniqueLambdaOf(self, info.pointer.pointee);
}

/// The signature a value is callable at.
pub const CallableSig = struct { params: []const TypeId, ret: TypeId };

/// The `impl (sig) for T` a value of type `ty` calls through, reaching through
/// one level of `*T` — a pointer to a callable nominal calls the same `call`.
pub fn callableNominalThrough(self: *Lowering, ty: TypeId) ?lower_protocol.CallableNominal {
    if (self.callable_nominals.get(ty)) |cn| return cn;
    if (ty.isBuiltin()) return null;
    const info = self.module.types.get(ty);
    if (info != .pointer) return null;
    return self.callable_nominals.get(info.pointer.pointee);
}

/// The four shapes a VALUE is callable at.
pub const ValueCallee = union(enum) {
    unique: UniqueLambda,
    nominal: lower_protocol.CallableNominal,
    closure: types.TypeInfo.ClosureInfo,
    fn_ptr: types.TypeInfo.FunctionInfo,
};

/// The one ordered classification of a callable value. A unique lambda and a
/// callable nominal are reached through one level of `*T`; a `Closure` and a
/// function pointer are matched on `ty` itself, so `*Closure(…)` and
/// `*(i64) -> i64` are not callable.
pub fn callableShapeOf(self: *Lowering, ty: TypeId) ?ValueCallee {
    if (uniqueLambdaThrough(self, ty)) |u| return .{ .unique = u };
    if (callableNominalThrough(self, ty)) |cn| return .{ .nominal = cn };
    if (ty.isBuiltin()) return null;
    return switch (self.module.types.get(ty)) {
        .closure => |c| .{ .closure = c },
        .function => |f| .{ .fn_ptr = f },
        else => null,
    };
}

/// The signature `ty` is callable at, or null when nothing calls it.
pub fn callableSigOf(self: *Lowering, ty: TypeId) ?CallableSig {
    return switch (callableShapeOf(self, ty) orelse return null) {
        .unique => |u| .{ .params = u.params, .ret = u.ret },
        .nominal => |cn| .{ .params = cn.params, .ret = cn.ret },
        .closure => |c| .{ .params = c.params, .ret = c.ret },
        .fn_ptr => |f| .{ .params = f.params, .ret = f.ret },
    };
}

pub fn lowerLambda(self: *Lowering, lam: *const ast.Lambda) Ref {
    return lowerLambdaTyped(self, lam, .literal, null);
}

/// `lowerLambda` with the two knobs a compiler-formed recipe needs: which
/// `LambdaKind` it is, and which type the resulting `{fn_ptr, env}` value
/// carries. `result_ty` must have the same closure shape the lambda lowers to —
/// it renames the value (`@Init(V)` instead of `Closure(*V)`), never reshapes it.
pub fn lowerLambdaTyped(self: *Lowering, lam: *const ast.Lambda, kind: LambdaKind, result_ty: ?TypeId) Ref {
    // A written `_{ … }` makes the literal's value its own env struct. Every
    // field is evaluated HERE, in the forming frame, before the guard below
    // retires the enclosing flow state.
    var written_env = std.ArrayList(CaptureInfo).empty;
    defer written_env.deinit(self.alloc);
    {
        const saved_env_target = self.target_type;
        self.target_type = null;
        defer self.target_type = saved_env_target;
        for (lam.env) |f| {
            const ref = self.lowerExpr(f.value);
            const ty = self.builder.getRefType(ref);
            // A build block's environment points at the frame that formed it,
            // and a literal may outlive that frame. Refused, but still bound:
            // the diagnostic halts before codegen, and binding it keeps the
            // body from cascading.
            self.rejectBlockCapture(ty, f.name, f.value.span);
            written_env.append(self.alloc, .{
                .name = f.name,
                .ty = ty,
                .ref = ref,
                .is_alloca = false,
            }) catch {};
        }
    }
    // Flow narrowing does NOT cross into the lambda body: the
    // body is a separate function whose `Ref` space overlaps the enclosing
    // function's, so the outer `narrowed_refs` would falsely match body `Ref`s
    // (unsound unwrap of a captured-but-not-proven-present optional). The body
    // builds its own narrowing from scratch; the outer state is restored on
    // return (re-arming narrowing for the rest of the enclosing expression).
    const sig_target = self.lambda_sig_target;
    var nested_guard = Lowering.NestedBodyGuard.enter(self);
    defer nested_guard.restore();

    // Lower the lambda body as a new anonymous function
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "__lambda_{d}", .{self.block_counter}) catch "__lambda";
    self.block_counter += 1;

    // A recipe's body is an expression the compiler moved, so its free names
    // are collected from the frame that still holds them. A written literal is
    // sealed: `written_env` IS the whole environment.
    var captures = std.ArrayList(CaptureInfo).empty;
    defer captures.deinit(self.alloc);
    captures.appendSlice(self.alloc, written_env.items) catch {};
    if (kind == .init_recipe) {
        var param_names = std.StringHashMap(void).init(self.alloc);
        defer param_names.deinit();
        for (lam.params) |p| param_names.put(p.name, {}) catch {};
        for (lam.env) |f| param_names.put(f.name, {}) catch {};
        self.collectCaptures(lam.body, &param_names, &captures);
    }

    // Deduplicate captures
    var seen = std.StringHashMap(void).init(self.alloc);
    defer seen.deinit();
    var deduped = std.ArrayList(CaptureInfo).empty;
    defer deduped.deinit(self.alloc);
    for (captures.items) |cap| {
        if (!seen.contains(cap.name)) {
            seen.put(cap.name, {}) catch {};
            deduped.append(self.alloc, cap) catch {};
        }
    }
    const capture_list = deduped.items;

    // The env struct. A unique literal always has one — an empty env is a
    // zero-field struct, which is the whole value.
    const is_unique = lam.has_env or capture_list.len > 0;
    var env_struct_ty: TypeId = .void;
    if (is_unique) {
        const env_field_data = self.alloc.alloc(types.TypeInfo.StructInfo.Field, capture_list.len) catch unreachable;
        for (capture_list, 0..) |cap, i| {
            env_field_data[i] = .{
                .name = self.module.types.internString(cap.name),
                .ty = cap.ty,
            };
        }
        var env_buf: [64]u8 = undefined;
        const env_name = std.fmt.bufPrint(&env_buf, "__env_{d}", .{self.block_counter}) catch "__env";
        const env_name_id = self.module.types.internString(env_name);
        env_struct_ty = self.module.types.intern(.{ .@"struct" = .{
            .name = env_name_id,
            .fields = env_field_data,
        } });
    }

    // Save current builder state
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    const saved_scope = self.scope;

    // Build param list. Convention when implicit_ctx is enabled:
    //   slot 0 = __sx_ctx: *void
    //   slot 1 = env: *void
    //   slot 2+ = user params
    // Without implicit_ctx, env is slot 0 and user params follow.
    var params = std.ArrayList(Function.Param).empty;
    const env_ptr_ty = self.module.types.ptrTo(.void);
    const lambda_wants_ctx = self.implicit_ctx_enabled;
    if (lambda_wants_ctx) {
        params.append(self.alloc, .{
            .name = self.module.types.internString("__sx_ctx"),
            .ty = env_ptr_ty,
        }) catch unreachable;
    }
    params.append(self.alloc, .{
        .name = self.module.types.internString("env"),
        .ty = env_ptr_ty,
    }) catch unreachable;
    // Get target closure param types for inference (from Closure(T1, T2) -> R annotations)
    const target_closure_params: ?[]const TypeId = blk: {
        if (self.target_type) |tt| {
            if (!tt.isBuiltin()) {
                const tti = self.module.types.get(tt);
                if (tti == .closure) break :blk tti.closure.params;
                // Unwrap ?Closure(...) → Closure(...)
                if (tti == .optional) {
                    const inner = tti.optional.child;
                    if (!inner.isBuiltin()) {
                        const inner_info = self.module.types.get(inner);
                        if (inner_info == .closure) break :blk inner_info.closure.params;
                    }
                }
            }
        }
        if (sig_target) |s| break :blk s.params;
        break :blk null;
    };
    // User params follow the ctx (optional) + env slots in `params`.
    const user_param_base: usize = (if (lambda_wants_ctx) @as(usize, 1) else 0) + 1;
    for (lam.params, 0..) |p, pi| {
        const pty: TypeId = blk: {
            // Unannotated lambda params take their type positionally from
            // the target `Closure(T0, …)` signature. Resolve them here so
            // `resolveParamType` (which would diagnose a missing annotation)
            // is only called for params that carry one. A slot nothing has
            // decided is no answer — stamping it onto the IR function reaches
            // codegen — so it falls to the diagnostic, as the ret arm does.
            if (p.type_expr.data == .inferred_type) {
                if (target_closure_params != null and pi < target_closure_params.?.len and
                    target_closure_params.?[pi] != .unresolved)
                {
                    break :blk target_closure_params.?[pi];
                }
                if (self.diagnostics) |d| {
                    d.addFmt(.err, p.type_expr.span, "cannot infer type of lambda parameter '{s}'; annotate it or use the lambda where a closure type is expected", .{p.name});
                }
                break :blk .unresolved;
            }
            break :blk self.resolveParamType(&p);
        };
        params.append(self.alloc, .{
            .name = self.module.types.internString(p.name),
            .ty = pty,
        }) catch unreachable;
    }

    const ret_ty = blk: {
        if (lam.return_type) |rt| {
            break :blk type_bridge.resolveAstType(rt, &self.module.types, &self.program_index.type_alias_map, &self.program_index.module_const_map);
        }
        // Use target closure return type if available — but only when it's
        // a resolved type. An `.unresolved` ret comes from an unbound
        // generic (`Closure(..) -> $R`); fall through to infer it from the
        // body so the concrete return drives `$R` inference at the call site.
        if (self.target_type) |tt| {
            if (!tt.isBuiltin()) {
                const tti = self.module.types.get(tt);
                if (tti == .closure and tti.closure.ret != .unresolved) break :blk tti.closure.ret;
                // Unwrap ?Closure(...) → Closure(...)
                if (tti == .optional) {
                    const inner = tti.optional.child;
                    if (!inner.isBuiltin()) {
                        const inner_info = self.module.types.get(inner);
                        if (inner_info == .closure and inner_info.closure.ret != .unresolved) break :blk inner_info.closure.ret;
                    }
                }
            }
        }
        if (sig_target) |s| if (s.ret != .unresolved) break :blk s.ret;
        // Lambda without explicit return type — infer from the body.
        // Temporarily bind params in scope so inference can resolve param types.
        var temp_scope = Scope.init(self.alloc, self.scope);
        const saved = self.scope;
        self.scope = &temp_scope;
        for (lam.params, 0..) |p, i| {
            const pty = params.items[user_param_base + i].ty;
            temp_scope.put(p.name, .{ .ref = @enumFromInt(0), .ty = pty, .is_alloca = false });
        }
        // Two body forms (parser.zig parseClosure), inferred exactly as a named
        // fn (resolveReturnType in lower.zig):
        //   |params| expr       — the body expression IS the value.
        //   |params| { stmts }  — block: an explicit `return <val>` sets the
        //                         type; with none the return is VOID (the
        //                         block's tail is a discarded statement, not an
        //                         implicit return — only an explicit `-> R`,
        //                         handled above, makes the tail the value).
        // A block body needs its own inference: plain `inferExprType(lam.body)`
        // yields void/noreturn when the value comes only from early `return`s,
        // or `.unresolved` when the tail references a block-local
        // the temp scope never bound — both panic in LLVM.
        const inferred = if (lam.body.data == .block)
            self.findReturnValueType(lam.body) orelse .void
        else
            self.inferExprType(lam.body);
        self.scope = saved;
        temp_scope.deinit();
        break :blk inferred;
    };
    const name_id = self.module.types.internString(name);
    const func_id = self.builder.beginFunction(name_id, params.items, ret_ty);
    self.builder.currentFunc().has_implicit_ctx = lambda_wants_ctx;

    // Param-slot layout: ctx at 0 (if present), env at ctx_slots,
    // user args at ctx_slots+1.
    const lambda_ctx_slots: u32 = if (lambda_wants_ctx) 1 else 0;
    const env_param_idx: u32 = lambda_ctx_slots;
    const user_param_base_lam: u32 = lambda_ctx_slots + 1;

    // Save + rebind current_ctx_ref so the body's sx-to-sx calls
    // forward the trampoline's own ctx (slot 0).
    const saved_ctx_ref_lam = self.current_ctx_ref;
    defer self.current_ctx_ref = saved_ctx_ref_lam;
    if (lambda_wants_ctx) self.current_ctx_ref = Ref.fromIndex(0);

    // A lambda is its own function: its `return` must drain only ITS OWN
    // `defer`s, not the enclosing function's. Open a fresh defer window
    // (like `lowerFunction`/`monomorphizeFunction`) and restore on exit —
    // otherwise lowering a closure literal inside a `defer` body re-enters
    // the enclosing function's defer drain (infinite recursion).
    const saved_func_defer_base = self.func_defer_base;
    const saved_defer_len = self.defer_stack.items.len;
    defer {
        self.func_defer_base = saved_func_defer_base;
        self.defer_stack.shrinkRetainingCapacity(saved_defer_len);
    }
    self.func_defer_base = saved_defer_len;

    // Create entry block
    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);

    // The body's scope. It carries the enclosing chain so the boundary lookups
    // can NAME an enclosing local the body reached for; `.lambda` is what makes
    // every plain lookup stop here, so the body binds its params and its env
    // fields and nothing else.
    var lambda_scope = Scope.init(self.alloc, saved_scope);
    lambda_scope.boundary = .lambda;
    self.scope = &lambda_scope;

    // The enclosing pack-fn mono's pack state must NOT leak into the lambda
    // body: its `args[i]` substitution nodes name the mono's `__pack_*`
    // params, which don't exist in this function (a deferred re-expansion
    // would read a dead frame). The body is a separate function; a
    // captured pack was materialized into a TUPLE by `collectCaptures` and is
    // bound from the env like any capture, so `..args` / `args[i]` lower
    // through the ordinary tuple paths here. Mirrors the clears in
    // `lazyLowerFunction` / `monomorphizeFunction`.
    const saved_lam_pan = self.pack_arg_nodes;
    const saved_lam_ppc = self.pack_param_count;
    const saved_lam_pat = self.pack_arg_types;
    const saved_lam_pcon = self.pack_constraint;
    self.pack_arg_nodes = null;
    self.pack_param_count = null;
    self.pack_arg_types = null;
    self.pack_constraint = null;

    // A unique value IS its env, so the body binds each field straight through
    // the caller's storage: a write reaches the value the caller holds, and
    // nothing is snapshotted per call.
    if (capture_list.len > 0) {
        const env_param_ref = Ref.fromIndex(env_param_idx);
        for (capture_list, 0..) |cap, i| {
            const field_ptr = self.builder.structGepTyped(env_param_ref, @intCast(i), self.module.types.ptrTo(cap.ty), env_struct_ty);
            lambda_scope.put(cap.name, .{ .ref = field_ptr, .ty = cap.ty, .is_alloca = true });
        }
    }

    // Also need parent scope for function lookups (but not variable lookups)
    // Set up fn_names from parent scope chain
    {
        var s: ?*Scope = saved_scope;
        while (s) |scope| {
            var it = scope.fn_names.iterator();
            while (it.next()) |e| {
                if (!lambda_scope.fn_names.contains(e.key_ptr.*)) {
                    lambda_scope.fn_names.put(e.key_ptr.*, e.value_ptr.*) catch {};
                }
            }
            s = scope.parent;
        }
    }

    // Bind params (user args start at user_param_base_lam, shifted past ctx + env).
    // Use the signature types computed above (`params`), which already
    // applied contextual typing from the target closure to untyped params —
    // `resolveParamType` alone would drop it and default each to i64.
    for (lam.params, 0..) |p, i| {
        const pty = params.items[user_param_base + i].ty;
        const slot = self.builder.alloca(pty);
        const param_ref = Ref.fromIndex(user_param_base_lam + @as(u32, @intCast(i)));
        self.builder.store(slot, param_ref);
        lambda_scope.put(p.name, .{ .ref = slot, .ty = pty, .is_alloca = true });
    }

    // Lower body — capture last expression as return value. The
    // `in_lambda_body` flag scopes the lambda-specific `raise`-not-failable
    // hint; save/restore so a lambda nested inside a regular function (or a
    // lambda inside a lambda) restores the enclosing context.
    const saved_in_lambda = self.in_lambda_body;
    self.in_lambda_body = true;
    // A lambda is its own function boundary: an enclosing `-> (x: A, y: B)`
    // function's named-return slots are not this body's to synthesize.
    const saved_nrn_lam = self.named_return_names;
    const saved_nrd_lam = self.named_return_defaults;
    self.named_return_names = null;
    self.named_return_defaults = null;
    defer {
        self.named_return_names = saved_nrn_lam;
        self.named_return_defaults = saved_nrd_lam;
    }
    // The body reads its OWN declared return type through the shared owner,
    // exactly as a named fn's body does: enum literals in an arrow body resolve
    // against `-> E`, and the enclosing expression's target — the closure type
    // itself when the literal sits in a call argument — does not leak in as the
    // body's destination.
    self.lowerFunctionBody(lam.body, ret_ty);
    self.in_lambda_body = saved_in_lambda;
    self.ensureTerminator(ret_ty);
    self.builder.finalize();

    // Restore builder state
    self.scope = saved_scope;
    self.pack_arg_nodes = saved_lam_pan;
    self.pack_param_count = saved_lam_ppc;
    self.pack_arg_types = saved_lam_pat;
    self.pack_constraint = saved_lam_pcon;
    lambda_scope.deinit();
    self.builder.func = saved_func;
    self.builder.current_block = saved_block;
    self.builder.inst_counter = saved_counter;
    self.current_ctx_ref = saved_ctx_ref_lam;

    // Closure flowing into a BARE function-pointer slot (`(T) -> U`, no env):
    // the slot is called without the closure env arg, so the closure fn can't
    // be passed directly. For a capture-free closure whose return type matches
    // the slot, emit an adapter with the bare ABI. Reject the cases the bare
    // ABI can't represent: a capturing closure (env has nowhere to live), and
    // a failable closure into a non-failable slot (extern code can't observe
    // the error channel).
    if (self.target_type) |tt| {
        if (!tt.isBuiltin() and self.module.types.get(tt) == .function) {
            const slot_ret = self.module.types.get(tt).function.ret;
            const widen_ok = self.errorChannelOf(slot_ret) != null and self.errorChannelOf(ret_ty) == null and self.failableSuccessType(slot_ret) == ret_ty;
            if (capture_list.len > 0) {
                if (self.diagnostics) |d| d.addFmt(.err, lam.body.span, "a capturing closure cannot be passed as a bare function pointer; declare the parameter type as `Closure(...)` so its environment is carried", .{});
            } else if (ret_ty == slot_ret or widen_ok) {
                // Matching ABI, or a non-failable closure widening into a
                // failable slot (∅ ⊆ slot set) — the adapter wraps {value, 0}.
                const adapter = self.createClosureToBareFnAdapter(func_id, self.module.types.get(tt).function, ret_ty, lam.body.span);
                return self.builder.emit(.{ .func_ref = adapter }, tt);
            } else if (self.errorChannelOf(ret_ty) != null and self.errorChannelOf(slot_ret) == null) {
                if (self.diagnostics) |d| d.addFmt(.err, lam.body.span, "failable closure cannot be assigned to a non-failable function-type slot; extern code can't observe the error channel — handle the error in a wrapper closure that absorbs it", .{});
            } else if (self.diagnostics) |d| {
                d.addFmt(.err, lam.body.span, "closure return type does not match the function-type slot", .{});
            }
        }
    }

    // Create proper closure type (user-visible params only — skip ctx + env).
    const skip_count: usize = if (lambda_wants_ctx) 2 else 1;
    var param_types_list = std.ArrayList(TypeId).empty;
    for (params.items[skip_count..]) |p| {
        param_types_list.append(self.alloc, p.ty) catch unreachable;
    }
    const closure_ty = result_ty orelse self.module.types.closureType(param_types_list.items, ret_ty);

    // A nonescaping `@Init(T)` recipe is the erased pair its site names, and
    // §12.1 forbids the compiler from choosing heap storage for it: the env
    // stays in the alloca of the frame that formed it.
    if (kind == .init_recipe) {
        if (capture_list.len == 0) return self.builder.closureCreate(func_id, Ref.none, closure_ty);
        const env_local = self.builder.alloca(env_struct_ty);
        for (capture_list, 0..) |cap, i| {
            const gep = self.builder.structGepTyped(env_local, @intCast(i), self.module.types.ptrTo(cap.ty), env_struct_ty);
            const val = if (cap.is_alloca) self.builder.load(cap.ref, cap.ty) else cap.ref;
            self.builder.store(gep, val);
        }
        return self.builder.closureCreate(func_id, env_local, closure_ty);
    }

    // The unique value: the env struct itself, filled where it was written.
    if (is_unique) {
        self.unique_lambdas.put(env_struct_ty, .{
            .func = func_id,
            .params = self.alloc.dupe(TypeId, param_types_list.items) catch unreachable,
            .ret = ret_ty,
        }) catch {};
        const env_local = self.builder.alloca(env_struct_ty);
        for (capture_list, 0..) |cap, i| {
            const gep = self.builder.structGepTyped(env_local, @intCast(i), self.module.types.ptrTo(cap.ty), env_struct_ty);
            const val = if (cap.is_alloca) self.builder.load(cap.ref, cap.ty) else cap.ref;
            self.builder.store(gep, val);
        }
        return self.builder.load(env_local, env_struct_ty);
    }

    return self.builder.closureCreate(func_id, Ref.none, closure_ty);
}

/// The environment a value of callable type `ty` IS — what `closure` copies
/// into the storage the erased value points at. A unique lambda is its env
/// struct, a callable nominal is its own state, a bare function is its pointer
/// word. Null for anything else, an erased `Closure` included: a `Closure`
/// carries an env instead of being one, and a `*$F` names storage someone else
/// owns.
pub fn envTypeOf(self: *Lowering, ty: TypeId) ?TypeId {
    if (uniqueLambdaOf(self, ty) != null) return ty;
    if (self.callable_nominals.get(ty) != null) return ty;
    if (ty.isBuiltin()) return null;
    return switch (self.module.types.get(ty)) {
        .function => ty,
        else => null,
    };
}

/// The trampoline `([ctx?], env: *void, params…) -> R` an erased value of
/// callable type `ty` dispatches through. A unique lambda's own function
/// already carries that shape; a callable nominal and a bare function get one
/// synthesized around the env `envTypeOf` names.
pub fn callTrampolineOf(self: *Lowering, ty: TypeId) ?FuncId {
    if (uniqueLambdaOf(self, ty)) |u| return u.func;
    if (self.persist_trampolines.get(ty)) |fid| return fid;
    const fid = blk: {
        if (self.callable_nominals.get(ty)) |cn| break :blk nominalTrampoline(self, cn) orelse return null;
        if (ty.isBuiltin()) return null;
        const info = self.module.types.get(ty);
        if (info != .function) return null;
        break :blk fnPtrTrampoline(self, ty, info.function);
    };
    self.persist_trampolines.put(ty, fid) catch {};
    return fid;
}

/// Builder state around a synthesized function body, so emitting one from the
/// middle of another body leaves the outer builder where it was.
const BuilderState = struct {
    func: ?FuncId,
    block: ?inst_mod.BlockId,
    counter: u32,

    fn save(self: *Lowering) BuilderState {
        return .{ .func = self.builder.func, .block = self.builder.current_block, .counter = self.builder.inst_counter };
    }

    fn restore(state: BuilderState, self: *Lowering) void {
        self.builder.func = state.func;
        self.builder.current_block = state.block;
        self.builder.inst_counter = state.counter;
    }
};

/// Open a synthesized `([ctx?], env: *void, params…) -> ret` body and switch
/// the builder into it. Returns the new function together with the ref index
/// the first user parameter occupies.
fn beginTrampoline(
    self: *Lowering,
    name: []const u8,
    params: []const TypeId,
    ret: TypeId,
) struct { id: FuncId, first_arg: u32 } {
    var list = std.ArrayList(inst_mod.Function.Param).empty;
    defer list.deinit(self.alloc);
    const void_ptr_ty = self.module.types.ptrTo(.void);
    const wants_ctx = self.implicit_ctx_enabled;
    if (wants_ctx) list.append(self.alloc, .{ .name = self.module.types.internString("__sx_ctx"), .ty = void_ptr_ty }) catch unreachable;
    list.append(self.alloc, .{ .name = self.module.types.internString("env"), .ty = void_ptr_ty }) catch unreachable;
    for (params, 0..) |pty, i| {
        var buf: [32]u8 = undefined;
        const pname = std.fmt.bufPrint(&buf, "a{d}", .{i}) catch "arg";
        list.append(self.alloc, .{ .name = self.module.types.internString(pname), .ty = pty }) catch unreachable;
    }
    const owned = self.alloc.dupe(inst_mod.Function.Param, list.items) catch unreachable;
    var func = inst_mod.Function.init(self.module.types.internString(name), owned, ret);
    func.has_implicit_ctx = wants_ctx;
    const func_id = self.module.addFunction(func);
    self.builder.func = func_id;
    self.builder.inst_counter = @intCast(owned.len);
    self.builder.switchToBlock(self.builder.appendBlock(self.module.types.internString("entry"), &.{}));
    return .{ .id = func_id, .first_arg = @intCast(owned.len - params.len) };
}

/// The `env` parameter a synthesized trampoline received.
fn trampolineEnv(self: *Lowering) Ref {
    return Ref.fromIndex(if (self.implicit_ctx_enabled) 1 else 0);
}

fn endTrampoline(self: *Lowering, result: Ref, ret: TypeId) void {
    if (ret != .void) self.builder.ret(result, ret) else self.builder.retVoid();
    self.builder.finalize();
}

/// `@call_ptr` for a bare function type: the env holds the pointer, and the
/// trampoline loads it and calls through.
fn fnPtrTrampoline(self: *Lowering, ty: TypeId, info: types.TypeInfo.FunctionInfo) FuncId {
    const saved = BuilderState.save(self);
    const t = beginTrampoline(self, "__persist_fnptr", info.params, info.ret);
    const callee = self.builder.load(trampolineEnv(self), ty);
    var args = std.ArrayList(Ref).empty;
    defer args.deinit(self.alloc);
    if (self.fnPtrTypeWantsCtx(ty)) args.append(self.alloc, Ref.fromIndex(0)) catch unreachable;
    for (info.params, 0..) |_, i| args.append(self.alloc, Ref.fromIndex(t.first_arg + @as(u32, @intCast(i)))) catch unreachable;
    const owned = self.alloc.dupe(Ref, args.items) catch unreachable;
    const result = self.builder.emit(.{ .call_indirect = .{ .callee = callee, .args = owned } }, info.ret);
    endTrampoline(self, result, info.ret);
    BuilderState.restore(saved, self);
    return t.id;
}

/// `@call_ptr` for an `impl (sig) for T`: the env IS the receiver, so the
/// trampoline hands it to `call` as `self`.
fn nominalTrampoline(self: *Lowering, cn: lower_protocol.CallableNominal) ?FuncId {
    const target = self.fn_decl_fids.get(cn.fd) orelse return null;
    if (!self.lowered_fids.contains(target)) {
        self.lowered_fids.put(target, {}) catch @panic("out of memory");
        self.lowerFunctionBodyInto(cn.fd, target, cn.qualified);
    }
    const ret_ty = self.module.functions.items[@intFromEnum(target)].ret;
    const target_wants_ctx = self.module.functions.items[@intFromEnum(target)].has_implicit_ctx;
    const saved = BuilderState.save(self);
    const t = beginTrampoline(self, "__persist_call", cn.params, ret_ty);
    var args = std.ArrayList(Ref).empty;
    defer args.deinit(self.alloc);
    if (target_wants_ctx) args.append(self.alloc, Ref.fromIndex(0)) catch unreachable;
    args.append(self.alloc, trampolineEnv(self)) catch unreachable;
    for (cn.params, 0..) |_, i| args.append(self.alloc, Ref.fromIndex(t.first_arg + @as(u32, @intCast(i)))) catch unreachable;
    const owned = self.alloc.dupe(Ref, args.items) catch unreachable;
    const result = self.builder.call(target, owned, ret_ty);
    endTrampoline(self, result, ret_ty);
    BuilderState.restore(saved, self);
    return t.id;
}

/// Create a trampoline function that wraps a bare function for closure auto-promotion.
/// The trampoline has signature `(env: *void, args...) -> ret` and simply calls the
/// bare function with `(args...)`, ignoring the env parameter.
pub fn createBareFnTrampoline(self: *Lowering, bare_func_id: FuncId, closure_info: types.TypeInfo.ClosureInfo) FuncId {
    // Build trampoline params: [__sx_ctx]? + env + closure params.
    // When the program uses Context, every sx-side trampoline carries
    // the implicit ctx at slot 0 and forwards it to the wrapped
    // function (which is also sx-side and expects it at slot 0).
    var params = std.ArrayList(inst_mod.Function.Param).empty;
    defer params.deinit(self.alloc);
    const void_ptr_ty = self.module.types.ptrTo(.void);
    const wants_ctx = self.implicit_ctx_enabled;
    if (wants_ctx) {
        params.append(self.alloc, .{ .name = self.module.types.internString("__sx_ctx"), .ty = void_ptr_ty }) catch unreachable;
    }
    const env_name = self.module.types.internString("env");
    params.append(self.alloc, .{ .name = env_name, .ty = void_ptr_ty }) catch unreachable;
    for (closure_info.params, 0..) |pty, i| {
        var buf: [32]u8 = undefined;
        const pname = std.fmt.bufPrint(&buf, "a{d}", .{i}) catch "arg";
        params.append(self.alloc, .{ .name = self.module.types.internString(pname), .ty = pty }) catch unreachable;
    }

    // Generate unique trampoline name
    const bare_func = self.module.functions.items[bare_func_id.index()];
    const bare_name = self.module.types.getString(bare_func.name);
    var name_buf: [128]u8 = undefined;
    const tramp_name = std.fmt.bufPrint(&name_buf, "__tramp_{s}", .{bare_name}) catch "__tramp";
    const tramp_name_id = self.module.types.internString(tramp_name);

    // Save builder state
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;

    // Create function
    const owned_params = self.alloc.dupe(inst_mod.Function.Param, params.items) catch unreachable;
    var func = inst_mod.Function.init(tramp_name_id, owned_params, closure_info.ret);
    func.has_implicit_ctx = wants_ctx;
    const func_id = self.module.addFunction(func);
    self.builder.func = func_id;
    self.builder.inst_counter = @intCast(owned_params.len); // params occupy refs 0..N-1
    const entry_name = self.module.types.internString("entry");
    const entry_block = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry_block);

    // Build call args: forward [__sx_ctx]? + user_params (skip env).
    // Trampoline slots: 0=ctx (if present), {0|1}=env, then user args.
    const ctx_slots: usize = if (wants_ctx) 1 else 0;
    const user_arg_start: u32 = @intCast(ctx_slots + 1); // skip ctx + env
    var call_args = std.ArrayList(Ref).empty;
    defer call_args.deinit(self.alloc);
    if (wants_ctx and bare_func.has_implicit_ctx) {
        call_args.append(self.alloc, Ref.fromIndex(0)) catch unreachable; // forward our ctx
    }
    for (closure_info.params, 0..) |_, i| {
        call_args.append(self.alloc, Ref.fromIndex(user_arg_start + @as(u32, @intCast(i)))) catch unreachable;
    }
    const owned_args = self.alloc.dupe(Ref, call_args.items) catch unreachable;
    const result = self.builder.emit(.{ .call = .{ .callee = bare_func_id, .args = owned_args } }, closure_info.ret);

    // Return result (or void)
    if (closure_info.ret != .void) {
        self.builder.ret(result, closure_info.ret);
    } else {
        self.builder.retVoid();
    }
    self.builder.finalize();

    // Restore builder state
    self.builder.func = saved_func;
    self.builder.current_block = saved_block;
    self.builder.inst_counter = saved_counter;

    return func_id;
}

/// Adapter for coercing a closure into a BARE function-pointer slot
/// (`(T) -> U`, no env). The closure's underlying function has signature
/// `[ctx?] + env + user-params`, but a bare fn-ptr slot is *called* without
/// the env arg — so the closure fn can't be used directly (the env slot
/// would swallow the first user arg). This adapter carries the bare ABI
/// (`[ctx?] + user-params`) and forwards to the closure fn with a null env.
/// Only sound for capture-free closures (a null env is correct iff the body
/// reads no captures); the caller rejects capturing closures.
///
/// When `closure_ret` differs from `fn_info.ret`, this is the ∅-widening
/// case (a non-failable closure into a failable slot): the closure returns
/// the success value and the adapter wraps it into the slot's `{value, 0}`
/// failable tuple.
pub fn createClosureToBareFnAdapter(self: *Lowering, closure_func_id: FuncId, fn_info: types.TypeInfo.FunctionInfo, closure_ret: TypeId, span: ast.Span) FuncId {
    var params = std.ArrayList(inst_mod.Function.Param).empty;
    defer params.deinit(self.alloc);
    const void_ptr_ty = self.module.types.ptrTo(.void);
    const wants_ctx = self.implicit_ctx_enabled;
    if (wants_ctx) {
        params.append(self.alloc, .{ .name = self.module.types.internString("__sx_ctx"), .ty = void_ptr_ty }) catch unreachable;
    }
    for (fn_info.params, 0..) |pty, i| {
        var buf: [32]u8 = undefined;
        const pname = std.fmt.bufPrint(&buf, "a{d}", .{i}) catch "arg";
        params.append(self.alloc, .{ .name = self.module.types.internString(pname), .ty = pty }) catch unreachable;
    }

    const closure_func = self.module.functions.items[closure_func_id.index()];
    const closure_name = self.module.types.getString(closure_func.name);
    var name_buf: [128]u8 = undefined;
    const adapter_name = std.fmt.bufPrint(&name_buf, "__cl2fn_{s}", .{closure_name}) catch "__cl2fn";
    const adapter_name_id = self.module.types.internString(adapter_name);

    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;

    const owned_params = self.alloc.dupe(inst_mod.Function.Param, params.items) catch unreachable;
    var func = inst_mod.Function.init(adapter_name_id, owned_params, fn_info.ret);
    func.has_implicit_ctx = wants_ctx;
    const func_id = self.module.addFunction(func);
    self.builder.func = func_id;
    self.builder.inst_counter = @intCast(owned_params.len);
    const entry_name = self.module.types.internString("entry");
    const entry_block = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry_block);

    // Forward [ctx?] + null env + user params to the closure fn.
    const ctx_slots: usize = if (wants_ctx) 1 else 0;
    var call_args = std.ArrayList(Ref).empty;
    defer call_args.deinit(self.alloc);
    if (wants_ctx) call_args.append(self.alloc, Ref.fromIndex(0)) catch unreachable;
    call_args.append(self.alloc, self.builder.constNull(void_ptr_ty)) catch unreachable;
    for (fn_info.params, 0..) |_, i| {
        call_args.append(self.alloc, Ref.fromIndex(@intCast(ctx_slots + i))) catch unreachable;
    }
    const owned_args = self.alloc.dupe(Ref, call_args.items) catch unreachable;
    const result = self.builder.emit(.{ .call = .{ .callee = closure_func_id, .args = owned_args } }, closure_ret);
    if (closure_ret == fn_info.ret) {
        if (fn_info.ret != .void) {
            self.builder.ret(result, fn_info.ret);
        } else {
            self.builder.retVoid();
        }
    } else {
        // ∅-widening: closure returns the success value; wrap `{value, 0}`
        // into the slot's failable tuple.
        self.lowerFailableSuccessReturn(result, fn_info.ret, span);
    }
    self.builder.finalize();

    self.builder.func = saved_func;
    self.builder.current_block = saved_block;
    self.builder.inst_counter = saved_counter;
    return func_id;
}

/// Walk an AST node and collect free variable references (identifiers that are
/// in the current scope but not in `param_names`).
///
/// This serves the two COMPILER-FORMED bodies — `@Init(T)`'s recipe and a
/// `@BuildBlock(P)`'s replayed block — whose source is an expression the
/// compiler moved out of the frame that still holds those names. A written
/// `|…|` literal is sealed and never asks: its environment is the `_{ … }` it
/// wrote, so the walk stops at every nested one.
pub fn collectCaptures(self: *Lowering, node: *const Node, param_names: *std.StringHashMap(void), captures: *std.ArrayList(CaptureInfo)) void {
    switch (node.data) {
        .identifier => |id| {
            // Skip lambda params
            if (param_names.contains(id.name)) return;
            // A comptime PACK captured into a closure: the pack
            // is comptime state of the enclosing mono — its `args[i]`
            // substitution nodes name the mono's `__pack_*` params, which do
            // not exist in the lambda's function (re-expanding them there read
            // a dead frame → segfault). Materialize the monomorphized element
            // VALUES into a tuple HERE (the parent, where they are live) and
            // capture that tuple by value; the body — lowered with pack state
            // cleared — then spreads/indexes `args` as an ordinary tuple.
            // Checked BEFORE the scope lookup: `materialisePackSlice` also
            // binds the pack name as a `[]Any` slice over parent-stack
            // storage, which must not win (boxed elements + dangling backing).
            if (self.isPackName(id.name)) {
                for (captures.items) |cap| {
                    if (std.mem.eql(u8, cap.name, id.name)) return;
                }
                const mat = self.materializePackTuple(id.name, node.span);
                captures.append(self.alloc, .{
                    .name = id.name,
                    .ty = mat.ty,
                    .ref = mat.ref,
                    .is_alloca = false,
                }) catch {};
                return;
            }
            // Lexical scope wins over program-wide fn/type tables, here as in
            // call dispatch: a local or param that
            // shadows a global fn/type name is a real value binding and MUST
            // be captured; skipping it would leave the closure body
            // reading/writing garbage. `lookupNearest` consults BOTH per-level
            // namespaces (value bindings + nested local fns) at the nearest
            // declaring depth, so a shadowing local wins over an outer fn name
            // and TDZ is honoured (a binding declared AFTER the closure isn't
            // in scope yet, so the fn name wins — as it should).
            if (self.scope) |scope| {
                if (scope.lookupNearest(id.name)) |nearest| switch (nearest) {
                    .binding => |binding| {
                        // A build block's environment points at the frame that
                        // formed it; a closure may outlive that frame. Refused,
                        // but still captured: the diagnostic halts before
                        // codegen, and binding it keeps the body from cascading.
                        self.rejectBlockCapture(binding.ty, id.name, node.span);
                        _ = self.refuseCursorCapture(binding.ty, node.span);
                        captures.append(self.alloc, .{
                            .name = id.name,
                            .ty = binding.ty,
                            .ref = binding.ref,
                            .is_alloca = binding.is_alloca,
                        }) catch {};
                        return;
                    },
                    // A nested local fn (`name :: (…) {…}`) is a callable, not
                    // a capturable value — dispatch resolves it through the
                    // fn tables (mirrored into `lambda_scope.fn_names`), so
                    // there is nothing to place in the env. Fall through to the
                    // fn/type-name skips below (identical outcome: no capture).
                    .local_fn => return,
                };
            }
            // Not a scope binding — skip program-wide function / type names so
            // a closure that merely CALLS a top-level fn (or names a type)
            // doesn't try to capture it.
            if (self.program_index.fn_ast_map.contains(id.name)) return;
            if (self.program_index.struct_template_map.contains(id.name)) return;
        },
        .binary_op => |bo| {
            self.collectCaptures(bo.lhs, param_names, captures);
            self.collectCaptures(bo.rhs, param_names, captures);
        },
        .unary_op => |uo| {
            self.collectCaptures(uo.operand, param_names, captures);
        },
        .call => |cl| {
            self.collectCaptures(cl.callee, param_names, captures);
            for (cl.args) |arg| {
                self.collectCaptures(arg, param_names, captures);
            }
        },
        .block => |blk| {
            for (blk.stmts) |stmt| {
                self.collectCaptures(stmt, param_names, captures);
            }
        },
        .if_expr => |ie| {
            self.collectCaptures(ie.condition, param_names, captures);
            self.collectCaptures(ie.then_branch, param_names, captures);
            if (ie.else_branch) |eb| self.collectCaptures(eb, param_names, captures);
        },
        .while_expr => |we| {
            self.collectCaptures(we.condition, param_names, captures);
            self.collectCaptures(we.body, param_names, captures);
        },
        .return_stmt => |rs| {
            if (rs.value) |v| self.collectCaptures(v, param_names, captures);
        },
        .var_decl => |vd| {
            if (vd.value) |v| self.collectCaptures(v, param_names, captures);
            // Register the local var name so it's not captured
            param_names.put(vd.name, {}) catch {};
        },
        .const_decl => |cd| {
            self.collectCaptures(cd.value, param_names, captures);
            param_names.put(cd.name, {}) catch {};
        },
        .assignment => |a| {
            self.collectCaptures(a.target, param_names, captures);
            self.collectCaptures(a.value, param_names, captures);
        },
        .destructure_decl => |dd| {
            self.collectCaptures(dd.value, param_names, captures);
            for (dd.names) |name| {
                param_names.put(name, {}) catch {};
            }
        },
        .field_access => |fa| {
            self.collectCaptures(fa.object, param_names, captures);
        },
        .index_expr => |ie| {
            self.collectCaptures(ie.object, param_names, captures);
            self.collectCaptures(ie.index, param_names, captures);
        },
        .struct_literal => |sl| {
            for (sl.field_inits) |fi| {
                self.collectCaptures(fi.value, param_names, captures);
            }
        },
        .array_literal => |al| {
            for (al.elements) |elem| {
                self.collectCaptures(elem, param_names, captures);
            }
        },
        .lambda => |inner_lam| {
            // A nested literal is sealed, so its body names nothing from here.
            // Its `_{ … }` field expressions do: they evaluate where the
            // literal is written, which is inside this walk.
            for (inner_lam.env) |f| self.collectCaptures(f.value, param_names, captures);
        },
        .match_expr => |me| {
            self.collectCaptures(me.subject, param_names, captures);
            for (me.arms) |arm| {
                self.collectCaptures(arm.body, param_names, captures);
            }
        },
        .null_coalesce => |nc| {
            self.collectCaptures(nc.lhs, param_names, captures);
            self.collectCaptures(nc.rhs, param_names, captures);
        },
        .deref_expr => |de| {
            self.collectCaptures(de.operand, param_names, captures);
        },
        .for_expr => |fe| {
            for (fe.iterables) |it| {
                self.collectCaptures(it.expr, param_names, captures);
                if (it.range_end) |re| self.collectCaptures(re, param_names, captures);
            }
            // Register capture names as locals so they're not captured
            for (fe.captures) |cap| param_names.put(cap.name, {}) catch {};
            self.collectCaptures(fe.body, param_names, captures);
        },
        .slice_expr => |se| {
            self.collectCaptures(se.object, param_names, captures);
            if (se.start) |s| self.collectCaptures(s, param_names, captures);
            if (se.end) |e| self.collectCaptures(e, param_names, captures);
        },
        .tuple_literal => |tl| {
            for (tl.elements) |elem| {
                self.collectCaptures(elem.value, param_names, captures);
            }
        },
        .force_unwrap => |fu| {
            self.collectCaptures(fu.operand, param_names, captures);
        },
        .chained_comparison => |cc| {
            for (cc.operands) |op| {
                self.collectCaptures(op, param_names, captures);
            }
        },
        .defer_stmt => |ds| {
            self.collectCaptures(ds.expr, param_names, captures);
        },
        .ffi_intrinsic_call => |fic| {
            self.collectCaptures(fic.return_type, param_names, captures);
            for (fic.args) |arg| {
                self.collectCaptures(arg, param_names, captures);
            }
        },
        // Error-handling expressions/statements carry sub-expressions that may
        // reference captured variables (e.g. a captured failable closure called
        // as `worker() catch { … }` inside a nested lambda body). Without these
        // arms the operand never gets captured, so inside the lambda the call
        // resolves against an empty scope and types as `.unresolved`.
        .try_expr => |te| {
            self.collectCaptures(te.operand, param_names, captures);
        },
        .catch_expr => |ce| {
            self.collectCaptures(ce.operand, param_names, captures);
            self.collectCaptures(ce.body, param_names, captures);
        },
        .onfail_stmt => |os| {
            self.collectCaptures(os.body, param_names, captures);
        },
        .raise_stmt => |rs| {
            self.collectCaptures(rs.tag, param_names, captures);
        },
        .multi_assign => |ma| {
            for (ma.targets) |t| self.collectCaptures(t, param_names, captures);
            for (ma.values) |v| self.collectCaptures(v, param_names, captures);
        },
        // A `push Context{ … }` block inside a lambda body is a nested scope
        // whose statements can reference captures (the install-the-scheduler
        // pattern `push Context{ io = … }) { worker() }`). Descend into both
        // the context expression and the body.
        .push_stmt => |ps| {
            self.collectCaptures(ps.context_expr, param_names, captures);
            self.collectCaptures(ps.body, param_names, captures);
        },
        .comptime_expr => |ce| {
            self.collectCaptures(ce.expr, param_names, captures);
        },
        .insert_expr => |ie| {
            self.collectCaptures(ie.expr, param_names, captures);
        },
        .spread_expr => |se| {
            self.collectCaptures(se.operand, param_names, captures);
        },
        // Inline-asm operand payloads carry input/place expressions that can
        // reference captured variables (`asm { … [v] "+m" -> @(p.*) }` where `p`
        // is an outer var). `out_value` payloads are Type nodes — descending is
        // harmless (the identifier arm filters type/fn names from capture).
        // A postfix cast's OPERAND is an ordinary expression and may name a
        // capture (`place(Row{ w = width }.(View))` inside a build closure).
        // The type expression is a type, never a value. Without this arm the
        // operand's names never enter the env and the body reports them
        // unresolved, while the same literal without the cast works.
        .postfix_cast => |pc| {
            self.collectCaptures(pc.operand, param_names, captures);
            if (pc.alloc_arg) |an| self.collectCaptures(an, param_names, captures);
        },
        // `f(x = captured)` — the argument value hangs off the named-arg node,
        // so `.call`'s walk over `args` stops at the wrapper.
        .named_arg => |na| {
            self.collectCaptures(na.value, param_names, captures);
        },
        // `f(a) { body }` — the block is the lambda sitting in the call's arg
        // list, and the `.lambda` arm seals it.
        .trailing_block => |tb| {
            self.collectCaptures(tb.lambda, param_names, captures);
        },
        // `expr { … }` before settling. The block may yet become a BUILD block,
        // which is replayed in the receiving frame and reads its free names
        // through this environment — so the walk descends, with the block's own
        // header names shadowing. A closure reading is sealed and simply
        // contributes names it never reads.
        .juxtaposition => |jx| {
            self.collectCaptures(jx.expr, param_names, captures);
            var block_params = std.StringHashMap(void).init(self.alloc);
            defer block_params.deinit();
            var it = param_names.iterator();
            while (it.next()) |e| block_params.put(e.key_ptr.*, {}) catch {};
            for (jx.params) |p| block_params.put(p.name, {}) catch {};
            self.collectCaptures(jx.block, &block_params, captures);
            if (jx.init_block) |ib| self.collectCaptures(ib, param_names, captures);
        },
        .asm_expr => |ae| {
            self.collectCaptures(ae.template, param_names, captures);
            for (ae.operands) |op| {
                self.collectCaptures(op.payload, param_names, captures);
            }
        },
        else => {},
    }
}

pub const CaptureInfo = struct {
    name: []const u8,
    ty: TypeId,
    ref: Ref, // alloca or value ref in the parent scope
    is_alloca: bool,
};
