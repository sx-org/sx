const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");
const type_bridge = @import("type_bridge.zig");
const lower = @import("lower.zig");
const inst = @import("inst.zig");
const program_index = @import("program_index.zig");

const Node = ast.Node;
const TypeId = types.TypeId;
const intrinsics = @import("intrinsics.zig");
const FuncId = inst.FuncId;
const BuiltinId = inst.BuiltinId;
const Lowering = lower.Lowering;

/// The classification of a call expression: which dispatch path lowering will
/// take, the IR type the call evaluates to, and the properties (selected
/// target, enum variant, receiver / `__sx_ctx` prepend, default-arg expansion)
/// that path implies.
///
/// `plan(c)` is the single point that recognises a call form; `resultType(c)`
/// is the thin "just the type" projection (`plan(c).return_type`). This step
/// (A3.2 convergence sub-step 2) builds the plan object and routes typing
/// through it; `lowerCall` still owns its own dispatch and is rerouted onto
/// the plan in sub-step 3.
pub const CallPlan = struct {
    kind: Kind,
    return_type: TypeId,
    target: Target = .none,
    /// Enum / tagged-union variant tag, for the construction kinds.
    variant: ?u32 = null,
    /// Lowering prepends the receiver as arg 0 (UFCS / instance-method forms).
    prepends_receiver: bool = false,
    /// Lowering prepends the implicit `__sx_ctx` as arg 0.
    prepends_ctx: bool = false,
    /// The caller omits trailing positional args the callee provides defaults
    /// for, so lowering splices them in (`expandCallDefaults` / `appendDefaultArgs`).
    expands_defaults: bool = false,

    pub const Kind = enum {
        builtin,
        reflection,
        generic_fn,
        /// A plain free function — resolved (`target.func`) or known only by
        /// AST and lowered lazily (`target.named`).
        direct_fn,
        closure,
        fn_pointer,
        protocol_dispatch,
        struct_method,
        /// Free-function UFCS: `recv.fn(args)` → `fn(recv, args)`, where `fn`
        /// is a plain free function and `recv` is a value (not a namespace /
        /// type prefix). Distinct from `namespace_fn` precisely because the
        /// receiver IS prepended (`prepends_receiver`).
        free_fn_ufcs,
        runtime_instance,
        runtime_static,
        /// `pkg.fn(args)` — the receiver is a namespace / module prefix, NOT a
        /// value, so nothing is prepended.
        namespace_fn,
        enum_construct,
        enum_shorthand,
        unresolved,
    };

    /// What `plan` selected. The active arm is disambiguated by `kind`:
    /// e.g. a `.named` under `.reflection` is a builtin name, under
    /// `.direct_fn` a lazily-lowered fn, under `.closure` a binding.
    pub const Target = union(enum) {
        none,
        builtin: BuiltinId,
        /// A resolved (lowered) free / method / namespace function.
        func: FuncId,
        /// A callee carried by name — reflection builtin, generic / lazy fn,
        /// closure / fn-pointer binding, or a not-yet-lowered namespace fn.
        named: []const u8,
        /// An exact callable author selected before any signature consumer.
        /// Carries the resolved `*FnDecl` + source so planning, contextual
        /// typing, defaults, lowering and monomorphization all read ONE author.
        /// Bare same-name collisions and namespace-qualified calls share this
        /// identity-bearing arm; the FuncId is materialized on demand.
        selected: Lowering.SelectedFunc,
        /// Protocol method, by index in the protocol's method table.
        protocol_method: u32,
        /// Runtime-class method (Obj-C / JNI), with its static-ness.
        runtime_method: struct { name: []const u8, is_static: bool },
        /// A namespace-selected global whose exact type is callable.  Keeping
        /// its GlobalId in the plan prevents a later bare-name lookup from
        /// rebinding `pkg.cb()` to another module's same-spelled global.
        callable_global: program_index.GlobalInfo,
        /// Enum / tagged-union type under construction.
        constructed: TypeId,
    };
};

/// Call result typing (architecture phase A3.2), extracted from
/// `Lowering.inferExprType`'s call arm. Discovers the IR type a call
/// expression evaluates to — across builtins / reflection builtins, generic
/// and plain free functions (lowered or lazy via `fn_ast_map`), closure /
/// function-typed locals, protocol dispatch, runtime-class instance/static
/// methods, struct (UFCS) methods, qualified namespace calls, and
/// enum/tagged-union construction.
///
/// A `*Lowering` facade (Principle 5, like `ExprTyper` / `PackResolver`): call
/// typing reads live lexical-scope / target-type state and the function /
/// runtime-class / protocol resolver helpers, so it borrows `*Lowering` rather
/// than re-threading every field.
pub const CallResolver = struct {
    l: *Lowering,

    /// Domain-aware classification for a field-access callee.  This is the
    /// single namespace/value boundary shared by call planning and lowering.
    /// In particular, `.never_qualified` is reserved for syntax which cannot
    /// be a qualified call at all; a selected non-function is retained as
    /// `.non_callable` and can never fall through to an unrelated bare member.
    pub const CallableValue = struct {
        global: program_index.GlobalInfo,
        member: []const u8,
    };

    pub const QualifiedCall = union(enum) {
        never_qualified,
        value_receiver,
        type_prefix,
        func: Lowering.SelectedFunc,
        callable_value: CallableValue,
        non_callable: struct { member: []const u8, span: ast.Span },
        missing: struct { namespace: []const u8, member: []const u8, span: ast.Span },
        not_visible: struct { alias: []const u8, span: ast.Span },
        ambiguous: struct { alias: []const u8, span: ast.Span },
    };

    /// Infer the IR type a call expression evaluates to (without lowering it).
    pub fn resultType(self: CallResolver, c: *const ast.Call) TypeId {
        return self.plan(c).return_type;
    }

    /// Classify a call: pick the dispatch kind / target / variant and derive
    /// the result type and prepend / default-expansion properties. The single
    /// source of truth for "what kind of call is this?".
    pub fn plan(self: CallResolver, c: *const ast.Call) CallPlan {
        if (c.callee.data == .identifier) {
            const bare_name = c.callee.data.identifier.name;
            // Resolve local function name (bare → mangled) and UFCS aliases
            const name = blk: {
                const scoped = if (self.l.scope) |scope| scope.lookupFn(bare_name) orelse bare_name else bare_name;
                if (self.l.ufcsAliasTarget(bare_name)) |target| {
                    break :blk if (self.l.scope) |scope| scope.lookupFn(target) orelse target else target;
                }
                break :blk scoped;
            };
            if (Lowering.resolveBuiltin(bare_name)) |bid| {
                const rt: TypeId = switch (bid) {
                    .sqrt, .sin, .cos, .floor => blk: {
                        if (c.args.len > 0) {
                            const arg_ty = self.l.inferExprType(c.args[0]);
                            if (arg_ty == .f32) break :blk TypeId.f32;
                        }
                        break :blk TypeId.f64;
                    },
                    .size_of, .align_of => .i64,
                    else => .unresolved,
                };
                return .{ .kind = .builtin, .return_type = rt, .target = .{ .builtin = bid } };
            }
            // Reflection intrinsics lower through `tryLowerReflectionCall`, not
            // the `BuiltinId` dispatch above — but a pack-fn caller still needs
            // their result type to mangle with the right tag. The registry owns
            // that type, so this asks it rather than restating the list.
            if (intrinsics.findByName(bare_name)) |id| {
                if (intrinsics.byId(id).ret) |rt| return refl(bare_name, rt);
                // A registry entry with no fixed `ret` computes its type from the
                // arguments (math -> the arg's type, atomics -> T, type_info ->
                // TypeInfo). `resolveBuiltin` above already answered for the math
                // ids; the rest are not reachable as pack-fn callees, and guessing
                // a type here would be exactly the silent default we don't write.
            }
            // Keywords: bare names the compiler recognizes with no declaration, so
            // the registry has nothing to say about them.
            if (std.mem.eql(u8, bare_name, "type_eq")) return refl(bare_name, .bool);
            if (std.mem.eql(u8, bare_name, "has_impl")) return refl(bare_name, .bool);
            if (std.mem.eql(u8, bare_name, "is_comptime")) return refl(bare_name, .bool);
            if (std.mem.eql(u8, bare_name, "is_struct")) return refl(bare_name, .bool);
            if (std.mem.eql(u8, bare_name, "__interp_print_frames")) return refl(bare_name, .void);
            if (std.mem.eql(u8, bare_name, "__trace_resolve_frame"))
                return refl(bare_name, self.l.module.types.findByName(self.l.module.types.internString("TraceFrame")) orelse .unresolved);
            // Plain bare same-name flat collision (R5 §C): route through the ONE
            // author producer `selectedFreeAuthor` so `plan` types the call as the
            // SAME author the lowering call-path binds — they can no longer
            // disagree. A generic / extern / builtin author is not
            // plain-free so the producer returns `.none`; `.ambiguous` / `.none`
            // fall through to the first-wins path below, byte-for-byte.
            switch (self.selectedFreeAuthor(c)) {
                .func => |sf| return .{
                    .kind = .direct_fn,
                    .return_type = if (sf.decl.return_type) |rt| self.l.resolveType(rt) else .void,
                    .target = .{ .selected = sf },
                    .expands_defaults = defaultsFor(sf.decl, c.args.len),
                },
                .ambiguous, .none => {},
            }
            // Generic function — infer return type via type bindings.
            if (self.l.program_index.fn_ast_map.get(name)) |fd| {
                if (fd.type_params.len > 0) {
                    return .{
                        .kind = .generic_fn,
                        .return_type = self.l.genericResolver().inferGenericReturnType(fd, c),
                        .target = .{ .named = name },
                        .expands_defaults = defaultsFor(fd, c.args.len),
                    };
                }
            }
            // Declared (lowered) function — return type from its signature.
            if (self.l.resolveFuncByName(name)) |fid| {
                const func = &self.l.module.functions.items[@intFromEnum(fid)];
                return .{
                    .kind = .direct_fn,
                    .return_type = func.ret,
                    .target = .{ .func = fid },
                    .prepends_ctx = func.has_implicit_ctx,
                    .expands_defaults = if (self.l.program_index.fn_ast_map.get(name)) |fd| defaultsFor(fd, c.args.len) else false,
                };
            }
            // Not lowered yet (lazy lowering): take the return type from the
            // declared AST. A void/return-less fn is void — not an
            // `.unresolved` guess.
            if (self.l.program_index.fn_ast_map.get(name)) |fd| {
                return .{
                    .kind = .direct_fn,
                    .return_type = if (fd.return_type) |rt| self.l.resolveType(rt) else .void,
                    .target = .{ .named = name },
                    .expands_defaults = defaultsFor(fd, c.args.len),
                };
            }
            // Local closure- / function-typed binding (e.g. a `cb: Closure(...)
            // -> R` or bare `cb: (T) -> R` parameter) — extract its declared
            // return type so `try` / `catch` on the call see the (possibly
            // failable) result.
            if (self.l.scope) |scope| {
                if (scope.lookup(bare_name)) |binding| {
                    if (!binding.ty.isBuiltin()) {
                        const ti = self.l.module.types.get(binding.ty);
                        if (ti == .closure) return .{
                            .kind = .closure,
                            .return_type = ti.closure.ret,
                            .target = .{ .named = bare_name },
                            .prepends_ctx = self.l.implicit_ctx_enabled,
                        };
                        if (ti == .function) return .{
                            .kind = .fn_pointer,
                            .return_type = ti.function.ret,
                            .target = .{ .named = bare_name },
                            .prepends_ctx = self.l.implicit_ctx_enabled and ti.function.call_conv != .c,
                        };
                    }
                }
            }
        } else if (c.callee.data == .field_access) {
            const cfa = c.callee.data.field_access;
            const qualified_call = self.classifyQualifiedCall(c);

            // Namespace-qualified free function. Resolve the COMPLETE path
            // once (`a.b.c.fn`, at arbitrary depth), before receiver typing or
            // any qualified-name compatibility map can collapse its author.
            // A value-shadowed root and an ordinary authored intermediate
            // return `.none`, leaving method/static dispatch below untouched.
            switch (qualified_call) {
                .func => |sf| return self.selectedNamespacePlan(sf, c),
                .callable_value => |cv| {
                    if (!cv.global.ty.isBuiltin()) {
                        const ti = self.l.module.types.get(cv.global.ty);
                        if (ti == .closure) return .{
                            .kind = .closure,
                            .return_type = ti.closure.ret,
                            .target = .{ .callable_global = cv.global },
                            .prepends_ctx = self.l.implicit_ctx_enabled,
                        };
                        if (ti == .function) return .{
                            .kind = .fn_pointer,
                            .return_type = ti.function.ret,
                            .target = .{ .callable_global = cv.global },
                            .prepends_ctx = self.l.implicit_ctx_enabled and ti.function.call_conv != .c,
                        };
                    }
                    return .{ .kind = .unresolved, .return_type = .unresolved };
                },
                .non_callable, .missing, .not_visible, .ambiguous => return .{ .kind = .unresolved, .return_type = .unresolved },
                .never_qualified, .value_receiver, .type_prefix => {},
            }

            const recv_ty = if (qualified_call == .value_receiver)
                self.l.inferExprType(cfa.object)
            else
                TypeId.unresolved;
            // Receiver is a protocol type → protocol method dispatch. The
            // receiver may be erased directly (`P`), a view (`*P`), or the
            // optional of either (`?P` / `?*P`, issue 0312/0310 — the
            // lowering dispatches all four; the plan must agree or the call
            // types as unresolved and e.g. `for v.items()` refuses).
            {
                var proto_recv = recv_ty;
                if (!proto_recv.isBuiltin()) {
                    const oi = self.l.module.types.get(proto_recv);
                    if (oi == .optional) proto_recv = oi.optional.child;
                }
                if (!proto_recv.isBuiltin()) {
                    const pi2 = self.l.module.types.get(proto_recv);
                    if (pi2 == .pointer and self.l.getProtocolInfo(pi2.pointer.pointee) != null) proto_recv = pi2.pointer.pointee;
                }
                if (self.l.getProtocolInfo(proto_recv)) |proto_info| {
                    for (proto_info.methods, 0..) |m, mi| {
                        if (std.mem.eql(u8, m.name, cfa.field)) return .{
                            .kind = .protocol_dispatch,
                            .return_type = m.ret_type,
                            .target = .{ .protocol_method = @intCast(mi) },
                            .prepends_receiver = true,
                        };
                    }
                }
            }
            // Runtime-class instance method: look up the method's declared
            // return type so chained calls (e.g.
            // `UIWindow.alloc().initWithWindowScene(scene)`) resolve.
            {
                var recv_inner = recv_ty;
                if (!recv_inner.isBuiltin()) {
                    const ri = self.l.module.types.get(recv_inner);
                    if (ri == .pointer) recv_inner = ri.pointer.pointee;
                }
                if (!recv_inner.isBuiltin()) {
                    const inner_info = self.l.module.types.get(recv_inner);
                    if (inner_info == .@"struct") {
                        const sn = self.l.module.types.getString(inner_info.@"struct".name);
                        if (self.l.program_index.runtime_class_map.get(sn)) |fcd| {
                            for (fcd.members) |m| switch (m) {
                                .method => |md| if (!md.is_static and std.mem.eql(u8, md.name, cfa.field)) {
                                    return .{
                                        .kind = .runtime_instance,
                                        .return_type = self.l.resolveRuntimeMethodReturnType(fcd, md),
                                        .target = .{ .runtime_method = .{ .name = md.name, .is_static = false } },
                                        .prepends_receiver = true,
                                    };
                                },
                                else => {},
                            };
                        }
                    }
                }
            }
            // Struct field holding a CLOSURE value, called directly
            // (`box.run(args)` where `run: Closure(..) -> R`). Mirrors the
            // lowering dispatch (call.zig closure-field arm) which runs in the
            // value-receiver path BEFORE instance-method dispatch — so a
            // closure-typed field shadows a same-named method, exactly as
            // lowering binds it. Without this the call typed as `.unresolved`
            // (issue 0201): value returns marshalled as garbage, failable
            // returns couldn't be `try`/`catch`-ed. Lowering owns the dispatch;
            // plan only needs the field's `.ret` so typing matches.
            {
                var fld_recv = recv_ty;
                if (!fld_recv.isBuiltin()) {
                    const ri = self.l.module.types.get(fld_recv);
                    if (ri == .pointer) fld_recv = ri.pointer.pointee;
                }
                if (!fld_recv.isBuiltin()) {
                    const ri = self.l.module.types.get(fld_recv);
                    if (ri == .@"struct") {
                        const field_name_id = self.l.module.types.internString(cfa.field);
                        for (ri.@"struct".fields) |f| {
                            if (f.name == field_name_id and !f.ty.isBuiltin()) {
                                const fti = self.l.module.types.get(f.ty);
                                if (fti == .closure) return .{
                                    .kind = .closure,
                                    .return_type = fti.closure.ret,
                                    .target = .{ .named = cfa.field },
                                };
                                // Bare function-pointer field (`fp: (T) -> R`),
                                // symmetric with the bare-identifier fn-pointer
                                // path above — call via `call_indirect`.
                                if (fti == .function) return .{
                                    .kind = .fn_pointer,
                                    .return_type = fti.function.ret,
                                    .target = .{ .named = cfa.field },
                                    .prepends_ctx = self.l.implicit_ctx_enabled and fti.function.call_conv != .c,
                                };
                            }
                        }
                    }
                }
            }
            // Instance method call: obj.method(args) → StructName.method.
            {
                var obj_ty = recv_ty;
                if (!obj_ty.isBuiltin()) {
                    const oi = self.l.module.types.get(obj_ty);
                    if (oi == .pointer) obj_ty = oi.pointer.pointee;
                }
                if (!obj_ty.isBuiltin()) {
                    const oi = self.l.module.types.get(obj_ty);
                    if (oi == .@"struct") {
                        // Generic-struct INSTANCE method: resolve plan-side
                        // through the SAME stamped-author reader the dispatch
                        // uses (CP-4), return type under the instance's
                        // bindings — call-result typing must work before the
                        // method has ever monomorphized (issue 0341: with no
                        // plan arm, a first-use `inst.method()` chain typed
                        // `.unresolved` and lowered to a silent zero).
                        {
                            const inst_name = self.l.module.types.getString(oi.@"struct".name);
                            if (self.l.genericInstanceMethod(inst_name, cfa.field)) |gm| {
                                return .{
                                    .kind = .struct_method,
                                    .return_type = self.l.genericInstanceMethodReturnType(gm),
                                    .target = .{ .named = cfa.field },
                                    .prepends_receiver = true,
                                    .prepends_ctx = self.l.implicit_ctx_enabled,
                                    .expands_defaults = defaultsFor(gm.fd, c.args.len + 1),
                                };
                            }
                        }
                        // Plain nominal struct: select the method from the
                        // receiver TypeId's author before consulting the
                        // global `StructName.method` compatibility map. Two
                        // namespace modules may both declare `Thing`; their
                        // distinct TypeIds must carry distinct method bodies.
                        if (self.l.plainStructMethod(obj_ty, cfa.field)) |method|
                            return self.plainStructMethodPlan(method, c, true);
                        if (!self.l.hasPlainStructAuthor(obj_ty)) {
                            const struct_name = self.l.module.types.getString(oi.@"struct".name);
                            const qualified = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ struct_name, cfa.field }) catch cfa.field;
                            if (self.l.resolveFuncByName(qualified)) |fid| {
                                const func = &self.l.module.functions.items[@intFromEnum(fid)];
                                return .{
                                    .kind = .struct_method,
                                    .return_type = func.ret,
                                    .target = .{ .func = fid },
                                    .prepends_receiver = true,
                                    .prepends_ctx = func.has_implicit_ctx,
                                    .expands_defaults = if (self.l.program_index.fn_ast_map.get(qualified)) |fd| defaultsFor(fd, c.args.len + 1) else false,
                                };
                            }
                        }
                    }
                }
            }
            // Free-function UFCS: `recv.fn(args)` → `fn(recv, args)`. lowerCall
            // reaches this only when the receiver is a VALUE (the
            // `is_namespace == false` path), in which case it prepends the
            // receiver and fixes up a `*T` first param. Mirror that boundary so
            // the plan carries `prepends_receiver`, distinct from a true
            // namespace call (`pkg.fn()`), which must NOT prepend.
            if (qualified_call == .value_receiver) {
                // Free-fn dot-dispatch is OPT-IN (mirror lowerCall's gate so
                // plan and dispatch agree): only a `ufcs` alias or a fn
                // declared `name :: ufcs (...)` classifies as free_fn_ufcs.
                // A plain fn falls through (lowering emits the tailored
                // not-a-ufcs-function diagnostic).
                const alias_target = self.l.ufcsAliasTarget(cfa.field);
                const eff_field = alias_target orelse cfa.field;
                const ufcs_fd = self.l.program_index.fn_ast_map.get(eff_field);
                const opted_in = alias_target != null or (ufcs_fd != null and ufcs_fd.?.is_ufcs);
                if (!opted_in) return .{ .kind = .unresolved, .return_type = .unresolved };
                // Generic ufcs target: infer the return type with the
                // RECEIVER prepended so binding positions align with
                // fd.params[0] (mirrors the lowering side's eff_args).
                if (ufcs_fd) |fd0p| {
                    if (fd0p.type_params.len > 0) {
                        const eff_call_args = self.l.alloc.alloc(*ast.Node, c.args.len + 1) catch
                            return .{ .kind = .unresolved, .return_type = .unresolved };
                        eff_call_args[0] = cfa.object;
                        @memcpy(eff_call_args[1..], c.args);
                        // RESELECT by receiver — the same selector + `fd0`
                        // lowering uses — so the PLANNED return type matches the
                        // function lowering actually dispatches. The last-wins
                        // `fd0p` can be a wrong-receiver overload (e.g. a
                        // `*Other($T)->string` winner over the `*Box($T)->i64`
                        // receiver-match); typing the call by `fd0p` while
                        // lowering calls the other one misboxes the result
                        // (issue 0157 review P1). A `*const Node` view of the
                        // args drives the receiver-aware selection.
                        const sel_args = self.l.alloc.alloc(*const ast.Node, c.args.len + 1) catch
                            return .{ .kind = .unresolved, .return_type = .unresolved };
                        sel_args[0] = cfa.object;
                        for (c.args, 0..) |a, i| sel_args[i + 1] = a;
                        var amb = false;
                        const fd = self.l.selectUfcsGenericByReceiver(eff_field, sel_args, &amb, fd0p) orelse fd0p;
                        var c2 = c.*;
                        c2.args = eff_call_args;
                        return .{
                            .kind = .free_fn_ufcs,
                            .return_type = self.l.genericResolver().inferGenericReturnType(fd, &c2),
                            .target = .{ .named = eff_field },
                            .prepends_receiver = true,
                            .expands_defaults = defaultsFor(fd, c.args.len + 1),
                        };
                    }
                }
                // Value-receiver free-fn UFCS (`recv.fn(args)` → `fn(recv, args)`)
                // routes through the SAME author producer `selectedFreeAuthor` as a
                // bare call, so the planned target / return type IS the author
                // lowering dispatches — they can't disagree under a flat same-name
                // collision (R5 §C). Without this, plan typed the
                // first-wins winner while lowering bound the selected shadow,
                // mis-tagging the call's result (a string-typed winner over an i64
                // shadow boxes a raw int as a string pointer → segfault).
                // `.ambiguous` / `.none` fall through to the first-wins path below,
                // unchanged.
                switch (self.selectedFreeAuthor(c)) {
                    .func => |sf| return .{
                        .kind = .free_fn_ufcs,
                        .return_type = if (sf.decl.return_type) |rt| self.l.resolveType(rt) else .void,
                        .target = .{ .selected = sf },
                        .prepends_receiver = true,
                        .expands_defaults = defaultsFor(sf.decl, c.args.len + 1),
                    },
                    .ambiguous, .none => {},
                }
                if (self.l.resolveFuncByName(eff_field)) |fid| {
                    const func = &self.l.module.functions.items[@intFromEnum(fid)];
                    return .{
                        .kind = .free_fn_ufcs,
                        .return_type = func.ret,
                        .target = .{ .func = fid },
                        .prepends_receiver = true,
                        .prepends_ctx = func.has_implicit_ctx,
                        .expands_defaults = if (ufcs_fd) |fd| defaultsFor(fd, c.args.len + 1) else false,
                    };
                }
                if (ufcs_fd) |bfd| {
                    return .{
                        .kind = .free_fn_ufcs,
                        .return_type = if (bfd.return_type) |rt| self.l.resolveType(rt) else .void,
                        .target = .{ .named = eff_field },
                        .prepends_receiver = true,
                        .expands_defaults = defaultsFor(bfd, c.args.len + 1),
                    };
                }
            }

            // Type.variant(args) — qualified construction; runtime static; or a
            // qualified namespace function. Reached for namespace / type
            // prefixes (and inert for value receivers handled above).
            switch (self.l.staticStructHead(cfa.object)) {
                .resolved => |owner_ty| {
                    if (self.l.plainStructMethod(owner_ty, cfa.field)) |method|
                        return self.plainStructMethodPlan(method, c, false);
                    if (self.l.hasPlainStructAuthor(owner_ty))
                        return .{ .kind = .unresolved, .return_type = .unresolved };
                },
                .ambiguous, .not_visible => return .{ .kind = .unresolved, .return_type = .unresolved },
                .none => {},
            }
            const type_name = switch (cfa.object.data) {
                .identifier => |id| id.name,
                .type_expr => |te| te.name,
                else => null,
            };
            if (type_name) |tn| {
                // Runtime-class static method: `Alias.static_method(args)`.
                if (self.l.program_index.runtime_class_map.get(tn)) |fcd| {
                    for (fcd.members) |m| switch (m) {
                        .method => |md| if (md.is_static and std.mem.eql(u8, md.name, cfa.field)) {
                            return .{
                                .kind = .runtime_static,
                                .return_type = self.l.resolveRuntimeMethodReturnType(fcd, md),
                                .target = .{ .runtime_method = .{ .name = md.name, .is_static = true } },
                            };
                        },
                        else => {},
                    };
                }
                const type_name_id = self.l.module.types.internString(tn);
                if (self.l.module.types.findByName(type_name_id)) |ty| {
                    const ti = self.l.module.types.get(ty);
                    if (ti == .tagged_union or ti == .@"enum") return .{
                        .kind = .enum_construct,
                        .return_type = ty,
                        .target = .{ .constructed = ty },
                        .variant = self.l.resolveVariantIndex(ty, cfa.field),
                    };
                }
                // Qualified function call. `resolveFuncByName` only finds
                // ALREADY-LOWERED functions; namespace imports are typically
                // lowered lazily on demand, so a fresh `pkg.hello()` call site
                // may resolve through `fn_ast_map` first. Without this, the
                // call's return type silently falls through to `.unresolved`
                // and any pack-fn caller (e.g. `print("{}\n", pkg.hello())`)
                // mangles the arg, mis-tagging the actual string in the Any box.
                const qualified = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ tn, cfa.field }) catch cfa.field;
                if (self.l.resolveFuncByName(qualified)) |fid| {
                    const func = &self.l.module.functions.items[@intFromEnum(fid)];
                    return .{
                        .kind = .namespace_fn,
                        .return_type = func.ret,
                        .target = .{ .func = fid },
                        .prepends_ctx = func.has_implicit_ctx,
                        .expands_defaults = if (self.l.program_index.fn_ast_map.get(qualified)) |fd| defaultsFor(fd, c.args.len) else false,
                    };
                }
                if (self.l.program_index.fn_ast_map.get(qualified)) |qfd| {
                    // Generic callee: the declared return type is the unbound
                    // `T` stub — infer through the call's bindings, exactly
                    // like the bare-identifier path above.
                    if (qfd.type_params.len > 0) return .{
                        .kind = .generic_fn,
                        .return_type = self.l.genericResolver().inferGenericReturnType(qfd, c),
                        .target = .{ .named = qualified },
                        .expands_defaults = defaultsFor(qfd, c.args.len),
                    };
                    return .{
                        .kind = .namespace_fn,
                        .return_type = if (qfd.return_type) |rt| self.l.resolveTypeInSource(self.l.program_index.qualified_fn_source.get(qualified), rt) else .void,
                        .target = .{ .named = qualified },
                        .expands_defaults = defaultsFor(qfd, c.args.len),
                    };
                }
                // Namespace aliases sometimes register the function under its
                // bare name (matches `lowerCall`'s effective-name resolution).
                if (self.l.program_index.fn_ast_map.get(cfa.field)) |bfd| {
                    if (bfd.type_params.len > 0) return .{
                        .kind = .generic_fn,
                        .return_type = self.l.genericResolver().inferGenericReturnType(bfd, c),
                        .target = .{ .named = cfa.field },
                        .expands_defaults = defaultsFor(bfd, c.args.len),
                    };
                    // `bfd` was found by its BARE name (a re-exported alias —
                    // `make :: inner.make` — registers the callee under `make`,
                    // not under the facade-qualified `facade.make`). So the
                    // qualified-name key is absent from `qualified_fn_source`,
                    // and pinning the return type to that null source would
                    // fall back to the CALL SITE's context — wrongly rejecting a
                    // return type (e.g. a `(Thing, !E)` multi-return whose
                    // `Thing` is bare-visible only inside the callee's module) as
                    // "not visible" (issue 0207). The authoritative defining
                    // module is `bfd`'s own source.
                    return .{
                        .kind = .namespace_fn,
                        .return_type = if (bfd.return_type) |rt| self.l.resolveTypeInSource(bfd.body.source_file, rt) else .void,
                        .target = .{ .named = cfa.field },
                        .expands_defaults = defaultsFor(bfd, c.args.len),
                    };
                }
            }
        } else if (c.callee.data == .lambda) {
            // An immediately-invoked lambda carries its callable signature in
            // the lambda expression itself.  Type the call from that closure
            // instead of leaving a module-level `#run` const `.unresolved`
            // until global emission (issue 0263).
            const callee_ty = self.l.inferExprType(c.callee);
            if (!callee_ty.isBuiltin()) {
                const info = self.l.module.types.get(callee_ty);
                if (info == .closure) {
                    return .{ .kind = .closure, .return_type = info.closure.ret };
                }
            }
        } else if (c.callee.data == .enum_literal) {
            // A target-typed `.method(args)` on a plain struct is the static
            // method shorthand twin of `Type.method(args)`. Select it by the
            // target's nominal TypeId before treating the spelling as an enum
            // variant, so planning and lowering agree on both the body and
            // result type under same-name struct collisions.
            if (self.l.target_type) |tgt| {
                if (self.l.plainStructMethod(tgt, c.callee.data.enum_literal.name)) |method|
                    return self.plainStructMethodPlan(method, c, false);
                if (self.l.hasPlainStructAuthor(tgt))
                    return .{ .kind = .unresolved, .return_type = .unresolved };
            }
            // .Variant(args) — dot-shorthand construction. Result type is
            // whatever target type is in scope; absent one it stays unresolved.
            const rt = self.l.target_type orelse .unresolved;
            var variant: ?u32 = null;
            if (self.l.target_type) |tgt| {
                if (!tgt.isBuiltin()) {
                    const ti = self.l.module.types.get(tgt);
                    if (ti == .tagged_union or ti == .@"enum")
                        variant = self.l.resolveVariantIndex(tgt, c.callee.data.enum_literal.name);
                }
            }
            return .{
                .kind = .enum_shorthand,
                .return_type = rt,
                .target = if (variant != null) .{ .constructed = rt } else .none,
                .variant = variant,
            };
        }
        return .{ .kind = .unresolved, .return_type = .unresolved };
    }

    /// THE single producer of the bare / value-UFCS same-name call author
    /// verdict (R5 §#3). Both `plan` (typing, via its `.selected` arm) and
    /// `lowerCall` (default expansion / param typing / dispatch) consume THIS one
    /// result, so they can never pick different same-name authors for the same
    /// call. Side-effect-free: it consults ONLY the author selector
    /// (`selectPlainCallableAuthor`) — never return-type inference or type-arg
    /// resolution — so `lowerCall` can compute it eagerly without emitting a
    /// premature diagnostic the full `plan` would (e.g. `cast(type)`'s type-arg).
    ///
    /// - identifier callee: a plain bare call. The gate mirrors `plan`/`lowerCall`
    ///   — a builtin, a scope-mangled / UFCS-aliased name, or a locally-shadowed
    ///   name is never a same-name free-fn collision → `.none`.
    /// - field-access callee with a VALUE receiver: a free-function UFCS
    ///   (`recv.fn(args)`). A namespace / type prefix receiver → `.none`. The
    ///   verdict over-selects a struct-method / protocol / extern call whose
    ///   field happens to name a free fn, but those dispatch BEFORE the free-fn
    ///   UFCS path in both `plan` and `lowerCall`, so the verdict is consumed only
    ///   when the call truly is a free-fn UFCS.
    pub fn selectedFreeAuthor(self: CallResolver, c: *const ast.Call) Lowering.BareCallee {
        const caller_file = self.l.current_source_file orelse return .none;
        switch (c.callee.data) {
            .identifier => |id| {
                const bare_name = id.name;
                if (Lowering.resolveBuiltin(bare_name) != null) return .none;
                const scoped = if (self.l.scope) |scope| scope.lookupFn(bare_name) orelse bare_name else bare_name;
                const name = if (self.l.ufcsAliasTarget(bare_name)) |target|
                    (if (self.l.scope) |scope| scope.lookupFn(target) orelse target else target)
                else
                    scoped;
                if (!std.mem.eql(u8, name, bare_name)) return .none;
                if (self.l.scope) |scope| if (scope.lookup(bare_name) != null) return .none;
                return self.l.selectPlainCallableAuthor(bare_name, caller_file);
            },
            .field_access => |cfa| {
                if (!self.objectIsValue(cfa.object)) return .none;
                return self.l.selectPlainCallableAuthor(cfa.field, caller_file);
            },
            else => return .none,
        }
    }

    fn terminalSpan(callee: *const Node, member: []const u8) ast.Span {
        const width: u32 = @intCast(@min(member.len, callee.span.end -| callee.span.start));
        return .{ .start = callee.span.end - width, .end = callee.span.end };
    }

    pub fn pathSliceSpan(callee: *const Node, path: []const u8, part: []const u8) ast.Span {
        const off = @intFromPtr(part.ptr) - @intFromPtr(path.ptr);
        const logical_end = @min(path.len, off + part.len);
        const source_width: usize = callee.span.end -| callee.span.start;
        return .{
            .start = callee.span.start,
            .end = callee.span.start + @as(u32, @intCast(@min(source_width, logical_end))),
        };
    }

    fn selectedGlobal(self: CallResolver, sel: Lowering.QualifiedMember) ?program_index.GlobalInfo {
        if (self.l.program_index.globals_by_source.get(sel.author.source)) |inner| {
            if (inner.get(sel.member)) |g| return g;
        }
        // Duplicate extern declarations may intentionally share the one
        // registered symbol.  The raw selected author still proves that this
        // fallback denotes the same global domain, rather than a same-spelled
        // value from another module.
        if (sel.author.raw == .var_decl)
            return self.l.program_index.global_names.get(sel.member);
        return null;
    }

    fn selectedObjectIsValue(self: CallResolver, sel: Lowering.QualifiedMember) bool {
        return switch (sel.author.raw) {
            .var_decl => true,
            .const_decl => self.l.sourceModuleConst(sel.author.source, sel.member) != null,
            else => false,
        };
    }

    /// Classify a possibly-qualified call before any signature consumer or
    /// receiver inference.  Runtime/lexical roots own the value domain first;
    /// only then may a namespace path select an exact declaration.  A selected
    /// terminal declaration is authoritative even when it is not callable.
    pub fn classifyQualifiedCall(self: CallResolver, c: *const ast.Call) QualifiedCall {
        if (c.callee.data != .field_access) return .never_qualified;
        const fa = c.callee.data.field_access;
        if (fa.object.data == .type_expr) {
            // Reserved type spellings parse as `.type_expr` even when an
            // invalid value binding with that spelling exists. The semantic
            // pass owns the reserved-name diagnostic, but call planning must
            // still honor the lexical value long enough to avoid a bogus
            // namespace/static arity cascade (`i2.update(7)`).
            if (self.l.scope) |scope| {
                if (scope.lookup(fa.object.data.type_expr.name) != null) return .value_receiver;
            }
            return .type_prefix;
        }

        const path = self.l.qualifiedTypeName(c.callee) orelse return .value_receiver;
        const root_end = std.mem.indexOfScalar(u8, path, '.') orelse {
            self.l.alloc.free(path);
            return .value_receiver;
        };
        const root = path[0..root_end];
        if (self.l.identifierBindsVisibleValue(root)) {
            self.l.alloc.free(path);
            return .value_receiver;
        }

        // Runtime classes have their own declaration/type domain. Their
        // opaque TypeId is materialized lazily, so `staticStructHead` may
        // legitimately report `.none`/forward here; the source-visible
        // runtime-class registration is still positive proof of a type/static
        // receiver and must win before terminal-name UFCS fallback (`Cls.alloc`
        // must never bind std.mem.alloc).
        if (self.l.program_index.runtime_class_map.contains(root) and self.l.isNameVisible(root)) {
            self.l.alloc.free(path);
            return .type_prefix;
        }

        // Remember a root which is a namespace somewhere in the program but
        // is not carried into this source. If no visible type/static head wins
        // below, this is a terminal visibility error — not evidence that the
        // spelling is a runtime receiver whose terminal may UFCS-cross-bind.
        const hidden_alias: ?[]const u8 = switch (self.l.namespaceAliasVerdict(root)) {
            .none => if (self.l.aliasDeclaredAnywhere(root))
                (self.l.alloc.dupe(u8, root) catch @panic("out of memory while retaining hidden namespace diagnostic"))
            else
                null,
            .target, .ambiguous => null,
        };
        const hidden_span = pathSliceSpan(c.callee, path, root);

        switch (self.l.qualifiedMemberVerdict(path)) {
            .selected => |sel| {
                if (self.l.namespaceFnMember(&sel.target, sel.member)) |fd| {
                    self.l.alloc.free(path);
                    return .{ .func = .{
                        .decl = fd,
                        .source = fd.body.source_file orelse sel.author.source,
                    } };
                }
                if (self.selectedGlobal(sel)) |global| {
                    if (!global.ty.isBuiltin()) {
                        const ti = self.l.module.types.get(global.ty);
                        if (ti == .closure or ti == .function) {
                            self.l.alloc.free(path);
                            return .{ .callable_value = .{ .global = global, .member = fa.field } };
                        }
                    }
                }
                self.l.alloc.free(path);
                return .{ .non_callable = .{ .member = fa.field, .span = terminalSpan(c.callee, fa.field) } };
            },
            .missing => |m| {
                // Failure names borrow `path`; retain this diagnostic-sized
                // allocation for the lowering lifetime.
                return .{ .missing = .{
                    .namespace = m.namespace,
                    .member = m.member,
                    .span = pathSliceSpan(c.callee, path, m.member),
                } };
            },
            .ambiguous => |alias| {
                return .{ .ambiguous = .{
                    .alias = alias,
                    .span = pathSliceSpan(c.callee, path, alias),
                } };
            },
            .not_qualified => {},
        }
        self.l.alloc.free(path);

        // The full path stopped at an ordinary authored member.  Classify the
        // complete receiver prefix: an exact global/const remains a runtime
        // value; a nominal head remains a static/type prefix.
        const object_path = self.l.qualifiedTypeName(fa.object) orelse return .value_receiver;
        switch (self.l.qualifiedMemberVerdict(object_path)) {
            .selected => |sel| {
                const is_value = self.selectedObjectIsValue(sel);
                self.l.alloc.free(object_path);
                if (is_value) return .value_receiver;
                return switch (self.l.staticStructHead(fa.object)) {
                    .resolved, .ambiguous, .not_visible => .type_prefix,
                    .none => .type_prefix,
                };
            },
            .missing => |m| return .{ .missing = .{
                .namespace = m.namespace,
                .member = m.member,
                .span = pathSliceSpan(fa.object, object_path, m.member),
            } },
            .ambiguous => |alias| return .{ .ambiguous = .{
                .alias = alias,
                .span = pathSliceSpan(fa.object, object_path, alias),
            } },
            .not_qualified => self.l.alloc.free(object_path),
        }
        // Source-less unit/comptime hosts predate import facts and register
        // namespace functions only under their qualified compatibility key.
        // Preserve that narrow legacy form without weakening source-backed
        // programs (where an unknown dotted root remains a value/unresolved
        // receiver and cannot cross-bind by terminal name).
        if (self.l.current_source_file == null and self.l.main_file == null and fa.object.data == .identifier) {
            const qualified = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ fa.object.data.identifier.name, fa.field }) catch
                @panic("out of memory while classifying source-less qualified call");
            if (self.l.program_index.fn_ast_map.contains(qualified)) return .type_prefix;
        }
        return switch (self.l.staticStructHead(fa.object)) {
            .resolved, .ambiguous, .not_visible => .type_prefix,
            .none => if (hidden_alias) |alias|
                .{ .not_visible = .{ .alias = alias, .span = hidden_span } }
            else
                .value_receiver,
        };
    }

    fn refl(name: []const u8, rt: TypeId) CallPlan {
        return .{ .kind = .reflection, .return_type = rt, .target = .{ .named = name } };
    }

    /// Build a namespace-call plan exclusively from the selected declaration.
    /// No process-global name lookup is permitted here: the exact author drives
    /// result typing, implicit-context ABI and default availability.
    fn selectedNamespacePlan(self: CallResolver, sf: Lowering.SelectedFunc, c: *const ast.Call) CallPlan {
        const fd = sf.decl;
        const ret_ty: TypeId = if (fd.type_params.len > 0)
            self.l.genericResolver().inferGenericReturnType(fd, c)
        else if (self.l.fn_decl_fids.get(fd)) |fid|
            self.l.module.functions.items[@intFromEnum(fid)].ret
        else if (fd.return_type) |rt|
            self.l.resolveTypeInSource(sf.source, rt)
        else
            .void;
        const has_ctx = if (self.l.fn_decl_fids.get(fd)) |fid|
            self.l.module.functions.items[@intFromEnum(fid)].has_implicit_ctx
        else
            self.l.funcWantsImplicitCtx(fd);
        return .{
            .kind = if (fd.type_params.len > 0) .generic_fn else .namespace_fn,
            .return_type = ret_ty,
            .target = .{ .selected = sf },
            .prepends_ctx = has_ctx,
            .expands_defaults = defaultsFor(fd, c.args.len),
        };
    }

    /// Build the typing half of a nominally-selected plain-struct method call.
    /// Concrete methods already have a decl-identity FuncId whose signature was
    /// resolved in the author's source. Generic methods infer with the receiver
    /// prepended, matching the lowering-side binding shape.
    fn plainStructMethodPlan(self: CallResolver, method: Lowering.PlainStructMethod, c: *const ast.Call, prepends_receiver: bool) CallPlan {
        const fd = method.fd;
        const ret_ty: TypeId = if (fd.type_params.len > 0) blk: {
            // GenericResolver builds argument-derived bindings in the CALLER's
            // visibility context and pins only the declared return type to the
            // callee. Pinning this whole operation to the callee would make a
            // caller-owned argument resolve through the wrong module.
            break :blk if (!prepends_receiver)
                self.l.genericResolver().inferGenericReturnType(fd, c)
            else infer: {
                const fa = c.callee.data.field_access;
                const eff_args = self.l.alloc.alloc(*ast.Node, c.args.len + 1) catch break :infer TypeId.unresolved;
                eff_args[0] = fa.object;
                @memcpy(eff_args[1..], c.args);
                var c2 = c.*;
                c2.args = eff_args;
                break :infer self.l.genericResolver().inferGenericReturnType(fd, &c2);
            };
        } else if (self.l.fn_decl_fids.get(fd)) |fid|
            self.l.module.functions.items[@intFromEnum(fid)].ret
        else blk: {
            const saved = self.l.current_source_file;
            self.l.setCurrentSourceFile(Lowering.plainStructMethodSource(method));
            const ret = self.l.resolveReturnType(fd);
            self.l.setCurrentSourceFile(saved);
            break :blk ret;
        };
        const has_ctx = if (self.l.fn_decl_fids.get(fd)) |fid|
            self.l.module.functions.items[@intFromEnum(fid)].has_implicit_ctx
        else
            self.l.funcWantsImplicitCtx(fd);
        return .{
            .kind = if (prepends_receiver) .struct_method else .namespace_fn,
            .return_type = ret_ty,
            .target = .{ .named = self.l.plainStructMethodName(method) },
            .prepends_receiver = prepends_receiver,
            .prepends_ctx = has_ctx,
            .expands_defaults = defaultsFor(fd, c.args.len + @intFromBool(prepends_receiver)),
        };
    }

    /// True when a field-access receiver is a value (so `recv.fn(...)` is a
    /// method / UFCS call), false when it is a bare namespace / type prefix
    /// (so `pkg.fn(...)` is a namespace call). This is exactly the negation of
    /// `lowerCall`'s `is_namespace`: a non-identifier object is always a value;
    /// an identifier / type_expr is a value iff it names a local or a global.
    /// `pub` so `lowerCall` sources its namespace/value boundary here rather
    /// than re-deriving it — one definition, shared by typing and lowering.
    pub fn objectIsValue(self: CallResolver, obj: *const Node) bool {
        if (obj.data == .type_expr) {
            if (self.l.scope) |scope| {
                if (scope.lookup(obj.data.type_expr.name) != null) return true;
            }
            return false;
        }
        const path = self.l.qualifiedTypeName(obj) orelse return true;
        defer self.l.alloc.free(path);
        const root_end = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
        if (self.l.identifierBindsVisibleValue(path[0..root_end])) return true;
        if (root_end == path.len) {
            return switch (self.l.namespaceAliasVerdict(path)) {
                .target, .ambiguous => false,
                .none => switch (self.l.staticStructHead(obj)) {
                    .resolved, .ambiguous, .not_visible => false,
                    .none => true,
                },
            };
        }
        return switch (self.l.qualifiedMemberVerdict(path)) {
            .selected => |sel| if (self.selectedObjectIsValue(sel))
                true
            else switch (self.l.staticStructHead(obj)) {
                .resolved, .ambiguous, .not_visible => false,
                .none => false,
            },
            .missing, .ambiguous => false,
            .not_qualified => switch (self.l.staticStructHead(obj)) {
                .resolved, .ambiguous, .not_visible => false,
                .none => true,
            },
        };
    }

    /// True when a call supplying `supplied` leading params (user args plus a
    /// prepended receiver for methods) omits a trailing param the callee
    /// defaults — i.e. lowering will splice that default in.
    fn defaultsFor(fd: *const ast.FnDecl, supplied: usize) bool {
        if (supplied >= fd.params.len) return false;
        return fd.params[supplied].default_expr != null;
    }
};
