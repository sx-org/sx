const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const type_bridge = @import("../type_bridge.zig");
const program_index_mod = @import("../program_index.zig");
const StructTemplate = program_index_mod.StructTemplate;
const GenericResolver = @import("../generics.zig").GenericResolver;

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const Scope = lower.Scope;
const inferExprType = Lowering.inferExprType;
const isNamedTypeKind = Lowering.isNamedTypeKind;
const resolveBuiltin = Lowering.resolveBuiltin;
const structMethodFn = Lowering.structMethodFn;
const typeFnAuthor = Lowering.typeFnAuthor;

pub fn monomorphizeFunction(self: *Lowering, fd: *const ast.FnDecl, mangled_name: []const u8, bindings: *std.StringHashMap(TypeId)) void {
    // Mark as lowered before lowering (prevents infinite recursion)
    // Need to dupe the name since mangled_name may be stack-allocated
    const owned_name = self.alloc.dupe(u8, mangled_name) catch return;
    self.lowered_functions.put(owned_name, {}) catch {};

    // Flow narrowing (issue 0179) is per-function: this monomorphized body has
    // its own `Ref` space (overlapping the caller's), so isolate it from the
    // caller's `narrowed`/`narrowed_refs` to avoid a false-positive unwrap gate.
    var narrow_guard = Lowering.NarrowGuard.enter(self);
    defer narrow_guard.restore();

    // Save builder state
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    const saved_scope = self.scope;
    const saved_bindings = self.type_bindings;
    const saved_defer_base = self.func_defer_base;
    const saved_block_terminated = self.block_terminated;
    const saved_target = self.target_type;
    // Pack-fn mono state is lexical to the pack-fn body. A generic
    // function called from inside a pack-fn mono (e.g.
    // `build(args: []Type, $ret: Type)` invoked from
    // `probe(..$args) { build($args, void) }`) must not inherit the
    // caller's pack maps — `lowerFieldAccess`'s `<pack_name>.len`
    // intercept would otherwise constant-fold the callee's
    // same-named param to whichever shape triggered the first mono
    // and bake the wrong arity into the cached IR. Same shape of
    // fix as `lazyLowerFunction` (issue-0048, commit 0ede097).
    const saved_pan = self.pack_arg_nodes;
    const saved_ppc = self.pack_param_count;
    const saved_pat = self.pack_arg_types;
    const saved_iri = self.inline_return_target;
    self.pack_arg_nodes = null;
    self.pack_param_count = null;
    self.pack_arg_types = null;
    self.inline_return_target = null;
    defer {
        self.pack_arg_nodes = saved_pan;
        self.pack_param_count = saved_ppc;
        self.pack_arg_types = saved_pat;
        self.inline_return_target = saved_iri;
    }
    self.func_defer_base = self.defer_stack.items.len;
    self.block_terminated = false;

    // Install type bindings
    self.type_bindings = bindings.*;

    // Pin to the template's defining module for the whole monomorphization
    // (return type, param types, body), so a library-internal bare TYPE ref
    // — e.g. `List(T).append`'s `alloc: Allocator` default-param type, or a
    // body reference to a type visible only in the template's module —
    // resolves where it is visible, not at the (possibly cross-module) call
    // site. This is the namespaced-fn-body plain-fn pin extended to generic
    // instantiation; without it the non-transitive bare-TYPE gate (E4) would
    // reject a 2-flat-hop library type the call site cannot see directly.
    // A synthesized / sourceless body keeps the caller's context.
    const saved_source_mono = self.current_source_file;
    defer self.setCurrentSourceFile(saved_source_mono);
    if (fd.body.source_file) |src| self.setCurrentSourceFile(src);

    // Resolve return type with type bindings active. The body's tail
    // expression inherits this as its target_type so bare `.{...}`
    // literals resolve to the monomorphised return type instead of
    // whatever leaked in from the caller (e.g. caller's xx target).
    const ret_ty = self.resolveReturnType(fd);
    self.target_type = ret_ty;

    const wants_ctx = self.funcWantsImplicitCtx(fd);
    const saved_ctx_ref_mono = self.current_ctx_ref;
    defer self.current_ctx_ref = saved_ctx_ref_mono;

    // Build param list (substituting type params, skipping type param declarations).
    // Prepend `__sx_ctx: *void` at slot 0 if the function gets the implicit param.
    var params = std.ArrayList(Function.Param).empty;
    if (wants_ctx) {
        params.append(self.alloc, .{
            .name = self.module.types.internString("__sx_ctx"),
            .ty = self.module.types.ptrTo(.void),
        }) catch unreachable;
    }
    for (fd.params, 0..) |p, param_decl_idx| {
        if (isTypeParamDecl(&p, fd.type_params)) continue;
        const pty = self.resolveDeclParamType(fd, param_decl_idx);
        params.append(self.alloc, .{
            .name = self.module.types.internString(p.name),
            .ty = pty,
        }) catch unreachable;
    }

    // Create the monomorphized function
    const name_id = self.module.types.internString(owned_name);
    const func_id = self.builder.beginFunction(name_id, params.items, ret_ty);
    _ = func_id;
    self.builder.currentFunc().has_implicit_ctx = wants_ctx;
    self.builder.currentFunc().is_naked = (fd.abi == .naked);
    self.builder.currentFunc().is_get = fd.is_get;
    self.builder.currentFunc().is_set = fd.is_set;

    // Create entry block
    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);
    if (wants_ctx) self.current_ctx_ref = Ref.fromIndex(0);

    // Create scope and bind params
    var scope = Scope.init(self.alloc, null);
    defer scope.deinit();
    self.scope = &scope;

    // `abi(.naked)` (naked): no frame — params arrive in registers, read by the
    // asm body, never spilled to allocas (the LLVM verifier rejects a naked
    // function that uses its arguments). Mirrors the decl-path guard.
    if (fd.abi != .naked) {
        var param_idx: u32 = if (wants_ctx) 1 else 0;
        for (fd.params, 0..) |p, param_decl_idx| {
            if (isTypeParamDecl(&p, fd.type_params)) continue;
            const pty = self.resolveDeclParamType(fd, param_decl_idx);
            const slot = self.builder.alloca(pty);
            const param_ref = Ref.fromIndex(param_idx);
            self.builder.store(slot, param_ref);
            scope.put(p.name, .{ .ref = slot, .ty = pty, .is_alloca = true });
            param_idx += 1;
        }
    }

    // Named multi-return (`-> (x: A, y: B)`): bind the slots as in-scope locals
    // for the body to assign; `lowerValueBody` then synthesizes the implicit
    // return from them. The decl path (`lowerFunctionBodyInto`) does this too —
    // without it a GENERIC named multi-return never sets `named_return_names`, so
    // the implicit return isn't synthesized and the body wrongly reports
    // "produces no value" (issue 0200). Save/restore the state so a monomorph
    // doesn't leak its named-return slots to the enclosing lowering.
    const saved_nrn_mono = self.named_return_names;
    const saved_nrd_mono = self.named_return_defaults;
    self.named_return_names = null;
    self.named_return_defaults = null;
    defer {
        self.named_return_names = saved_nrn_mono;
        self.named_return_defaults = saved_nrd_mono;
    }
    if (fd.abi != .naked) self.bindNamedReturnSlots(fd, ret_ty, &scope);

    // Handle builtin function bodies (e.g. intrinsic sqrt monomorphized to sqrt__f32)
    if (fd.body.data == .intrinsic_expr) {
        // Emit builtin call with param 0, then return
        if (resolveBuiltin(fd.name)) |bid| {
            const param0 = Ref.fromIndex(0);
            const result = self.builder.callBuiltin(bid, &.{param0}, ret_ty);
            self.builder.ret(result, ret_ty);
        } else {
            // Unknown bodiless intrinsic: the name is not claimed by any
            // recognizer (atomics/reflection are handled earlier in call.zig).
            // Emitting `ensureTerminator(ret_ty)` here would synthesize a
            // silent `constInt(0, ret_ty)` for a non-void return — a silent
            // fallback default (issue 0144). Surface the failure loudly.
            const span = if (fd.name_span.end != 0) fd.name_span else fd.body.span;
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "unknown intrinsic '{s}'", .{fd.name});
            // Lowering has already failed; close the block with a terminator
            // so the IR stays well-formed for the rest of the pass.
            self.ensureTerminator(ret_ty);
        }
        self.builder.finalize();
    } else if (self.builder.currentFunc().is_naked) {
        // `abi(.naked)`: asm-only body that rets itself — no sx value return.
        // Lower the statements + cap with `unreachable` (mirrors the decl path).
        // emit_llvm bails on `is_naked` until B1.0b implements `naked` emission.
        self.lowerBlock(fd.body);
        if (!self.currentBlockHasTerminator()) self.builder.emitUnreachable();
        self.builder.finalize();
    } else {
        // Lower the function body. Delegate the trailing-value return to the
        // shared `lowerValueBody` so the generic-instantiation path can't drift
        // from the decl path — it handles all three body-return shapes: the
        // value-failable success routing (append the success error slot via
        // `lowerFailableSuccessReturn`, NOT a bare coerce+ret that leaves the
        // error-tag slot uninitialized — issue 0190), the pure-failable
        // fall-through, and the missing-value diagnostic.
        if (ret_ty != .void) {
            self.lowerValueBody(fd.body, ret_ty);
        } else {
            self.lowerBlock(fd.body);
            self.ensureTerminator(ret_ty);
        }
        self.builder.finalize();
    }

    // Restore builder state
    self.type_bindings = saved_bindings;
    self.scope = saved_scope;
    self.func_defer_base = saved_defer_base;
    self.block_terminated = saved_block_terminated;
    self.target_type = saved_target;
    self.builder.func = saved_func;
    self.builder.current_block = saved_block;
    self.builder.inst_counter = saved_counter;
}

// ── Type-arg resolution & matching ─────────────────────────────

/// Resolve a type argument from a call expression. Handles:
/// - Type param bindings ($T → concrete type via type_bindings)
/// - Direct type names (Vec4 → lookup in TypeTable)
/// - type_expr AST nodes
/// True iff `node` matches an AST shape that `resolveTypeArg`
/// can resolve to a concrete TypeId without falling through to
/// the silent `.i64` default. Used by `tryLowerReflectionCall`
/// to split static-fold from dynamic-builtin-call paths.
///
/// Static-arg shapes mirror the explicit arms of `resolveTypeArg`:
///   - type_expr / identifier (type name or bound generic)
///   - pack_index_type_expr (`$pack[<lit>]`)
///   - compound type literals (pointer, array, slice, optional,
///     many_pointer, function_type_expr)
///   - parameterised type-constructor `call` (Vector, List, etc.)
///   - tuple_literal as a tuple TYPE
///
/// Dynamic shapes (index_expr, field_access, runtime locals,
/// etc.) fall to the alternative path that emits a builtin_call.
pub fn isStaticTypeArg(self: *Lowering, node: *const Node) bool {
    switch (node.data) {
        .type_expr => |te| {
            // A type-keyword name (e.g. `i64`) is always static.
            // A user-defined name that happens to be in scope as
            // a runtime variable (`x: Type = i64; type_name(x)`)
            // is NOT static — route through the dynamic builtin
            // call so the runtime lookup table fires.
            if (self.scope) |scope| {
                if (scope.lookup(te.name) != null) return false;
            }
            return true;
        },
        .identifier => |id| {
            if (self.scope) |scope| {
                if (scope.lookup(id.name) != null) return false;
            }
            return true;
        },
        .field_access => {
            const path = self.qualifiedTypeName(node) orelse return false;
            defer self.alloc.free(path);
            const root_end = std.mem.indexOfScalar(u8, path, '.') orelse return false;
            if (self.scope) |scope| {
                if (scope.lookup(path[0..root_end]) != null) return false;
            }
            const sel = switch (self.qualifiedMemberVerdict(path)) {
                .selected => |s| s,
                .not_qualified, .missing, .ambiguous => return false,
            };
            return switch (sel.author.raw) {
                .struct_decl, .enum_decl, .union_decl, .error_set_decl, .protocol_decl, .runtime_class_decl => true,
                .const_decl => |cd| switch (cd.value.data) {
                    .struct_decl, .enum_decl, .union_decl, .error_set_decl, .identifier, .field_access => true,
                    else => false,
                },
                else => false,
            };
        },
        .pack_index_type_expr,
        .pointer_type_expr,
        .many_pointer_type_expr,
        .array_type_expr,
        .slice_type_expr,
        .optional_type_expr,
        .function_type_expr,
        .tuple_literal,
        .tuple_type_expr,
        => return true,
        // Prefix `*` parses as address_of in the value grammar; over a
        // static type operand it IS the pointer type (`size_of(*T)`).
        .unary_op => |uop| {
            if (uop.op != .address_of) return false;
            return self.isStaticTypeArg(uop.operand);
        },
        .call => |cl| {
            // Type-returning REFLECTION calls are static only when their own
            // type argument is: `type_of(x)` with an `any`-typed operand
            // answers the runtime TAG (freezing it statically said "any"
            // where the two-step form read "Point"), and
            // `struct_field_type(tp, i)` / `variant_type(tp, i)` /
            // `pointee_type(tp)` with a runtime `tp` produce runtime Types.
            // Everything else (Vector(N,T)-style type constructors) is static.
            if (cl.callee.data == .identifier) {
                const cn = cl.callee.data.identifier.name;
                if (std.mem.eql(u8, cn, "type_of") and cl.args.len == 1) {
                    const aty = self.inferExprType(cl.args[0]);
                    // An `any` or PROTOCOL operand answers the runtime
                    // type_id word — freezing it statically would say
                    // "any"/"Drawable" where the value knows "Point".
                    if (aty == .any or self.getProtocolInfo(aty) != null) return false;
                }
                if ((std.mem.eql(u8, cn, "struct_field_type") or
                    std.mem.eql(u8, cn, "variant_type") or
                    std.mem.eql(u8, cn, "pointee_type")) and cl.args.len >= 1)
                {
                    return self.isStaticTypeArg(cl.args[0]);
                }
            }
            return true;
        },
        else => return false,
    }
}

/// True iff `node` is a Type-shaped expression that resolves to a
/// concrete TypeId at lower time WITHOUT being a runtime variable
/// reference. Differs from `isStaticTypeArg` in that we exclude
/// identifiers that are in scope as runtime locals/globals — those
/// are runtime Type values (e.g. `t: Type = f64`) and the
/// comparison fold can't statically resolve them.
pub fn isStaticTypeRef(self: *Lowering, node: *const Node) bool {
    switch (node.data) {
        .type_expr => |te| {
            // Compound type names (`i64`, `Point`, `Vec4`) resolve
            // statically. If the name is also a runtime var in
            // scope, it's a value reference, not a type ref.
            if (self.scope) |scope| {
                if (scope.lookup(te.name) != null) return false;
            }
            return self.isKnownTypeName(te.name) or
                self.module.types.findByName(self.module.types.internString(te.name)) != null or
                self.program_index.type_alias_map.get(te.name) != null;
        },
        .identifier => |id| {
            if (self.scope) |scope| {
                if (scope.lookup(id.name) != null) return false;
            }
            return self.isKnownTypeName(id.name) or
                self.module.types.findByName(self.module.types.internString(id.name)) != null or
                self.program_index.type_alias_map.get(id.name) != null;
        },
        .pointer_type_expr,
        .many_pointer_type_expr,
        .array_type_expr,
        .slice_type_expr,
        .optional_type_expr,
        .function_type_expr,
        .pack_index_type_expr,
        => return true,
        .call => |cl| {
            // `type_of(x)` resolves statically when `x`'s type is
            // known — except an `any`/PROTOCOL operand, whose type_of is
            // the runtime type_id word.
            if (cl.callee.data == .identifier and
                std.mem.eql(u8, cl.callee.data.identifier.name, "type_of") and
                cl.args.len == 1)
            {
                const aty = self.inferExprType(cl.args[0]);
                return aty != .any and self.getProtocolInfo(aty) == null;
            }
            return false;
        },
        else => return false,
    }
}

/// Resolve a tuple LITERAL used in a type position (`(i32, i32)` reinterpreted
/// as a tuple type at a type-demanding site such as `size_of`). Every element
/// must itself denote a type; a non-type element — e.g. the `1` in
/// `(i32, 1)` — is a user error. Emit a diagnostic pointing at the offending
/// element and return `.unresolved`; never fabricate a tuple with a bogus
/// field. type_bridge.resolveAstType builds the tuple only after
/// this validation passes.
pub fn resolveTupleLiteralTypeArg(self: *Lowering, node: *const Node) TypeId {
    for (node.data.tuple_literal.elements) |el| {
        if (!type_bridge.isTypeShapedAstNode(el.value, &self.module.types)) {
            if (self.diagnostics) |diags| {
                diags.addFmt(.err, el.value.span, "tuple type element is not a type (found `{s}`); a tuple used as a type must list only types, e.g. `Tuple(i32, i32)`", .{@tagName(el.value.data)});
            }
            return .unresolved;
        }
        // E4 single-hop visibility gate: each element leaf is resolved through
        // the source-aware resolver, so a 2-flat-hop inner leaf (`(COnly, i64)`)
        // emits "not visible" + poisons rather than leaking through
        // `type_bridge`'s ungated global lookup. A valid element resolves to the
        // same TypeId the delegated build produces below (no diagnostic, no
        // drift); only the poison short-circuits.
        if (self.resolveTypeWithBindings(el.value) == .unresolved) return .unresolved;
    }
    return type_bridge.resolveAstType(node, &self.module.types, &self.program_index.type_alias_map, &self.program_index.module_const_map);
}

/// True iff `node` is a call to a user-defined generic `($X..) -> Type` function
/// (e.g. `RaceResult(T)`). Such a call is type-shaped: `resolveTypeArg` resolves
/// it via `resolveTypeCallWithBindings` -> `instantiateTypeFunction`. The static
/// `isTypeShapedAstNode` only recognizes the type-returning BUILTINS
/// (`field_type`/`pointee`/`type_of`) — it has no program index — so a user
/// type-fn call in a `$E: Type` argument slot would otherwise never be seen as a
/// type and the param would fail to bind ("cannot infer generic type parameter").
/// This lets a synthesized result type flow as a type argument, e.g.
/// `make_variant(RaceResult(T), i, winner.value)` in the `race` runtime.
pub fn isTypeReturningCallNode(self: *Lowering, node: *const Node) bool {
    if (node.data != .call) return false;
    const cl = node.data.call;
    const callee_name: []const u8 = switch (cl.callee.data) {
        .identifier => |id| id.name,
        .field_access => |fa| fa.field,
        else => return false,
    };
    const resolved_name = if (self.scope) |scope| (scope.lookupFn(callee_name) orelse callee_name) else callee_name;
    const fd = self.program_index.fn_ast_map.get(resolved_name) orelse return false;
    // Only a GENERIC `-> Type` fn resolves through `instantiateTypeFunction`; a
    // non-generic one would fall to a named-type lookup that this call shape
    // can't satisfy, so gate on both (matches `resolveTypeCallWithBindings`).
    if (fd.type_params.len == 0) return false;
    const rt = fd.return_type orelse return false;
    return rt.data == .type_expr and std.mem.eql(u8, rt.data.type_expr.name, "Type");
}

pub fn resolveTypeArg(self: *Lowering, node: *const Node) TypeId {
    // Prefix `*` (parsed address_of) over a type operand IS the pointer
    // type — `describe(*Padded)`, `List(*T)`-style args, recursively for
    // `**T` (mirrors the resolveTypeWithBindings arm).
    if (node.data == .unary_op and node.data.unary_op.op == .address_of) {
        const inner = self.resolveTypeArg(node.data.unary_op.operand);
        if (inner == .unresolved) return .unresolved;
        return self.module.types.ptrTo(inner);
    }
    // A bare-paren `(A, B)` is a MULTI-RETURN signature — valid only as a
    // function/closure return type, never as a generic type argument (a
    // tuple-valued arg uses `Tuple(…)`). Without this it silently resolved to a
    // reused tuple TypeId (`List((A, B))` ≡ `List(Tuple(A, B))`), eroding the
    // "multi-return is not a tuple, return-position-only" rule.
    if (self.rejectMultiReturnValueType(node, "generic type argument")) return .unresolved;
    // Pack-index access in a type-arg slot (e.g. `type_name($args[0])`
    // or `type_eq($args[i], i64)`). Same shape as the
    // `resolveTypeWithBindings` arm — looks up the bound pack types
    // and returns the i-th. OOB and no-active-binding emit focused
    // diagnostics rather than silently defaulting to .i64 (the
    // catch-all `else` below) — that fall-through is exactly the
    // "silent unimplemented arm" the project's REJECTED PATTERNS
    // forbid.
    if (node.data == .pack_index_type_expr) {
        const pi = node.data.pack_index_type_expr;
        if (self.pack_arg_types) |pat| {
            if (pat.get(pi.pack_name)) |arg_tys| {
                if (pi.index < arg_tys.len) return arg_tys[pi.index];
                if (self.diagnostics) |diags| {
                    diags.addFmt(.err, node.span, "pack-index ${s}[{}] out of bounds: '{s}' has {} element{s}", .{
                        pi.pack_name,                                                        pi.index, pi.pack_name, arg_tys.len,
                        if (arg_tys.len == 1) @as([]const u8, "") else @as([]const u8, "s"),
                    });
                }
                return .unresolved;
            }
        }
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, node.span, "pack-index ${s}[{}] used outside an active pack binding", .{
                pi.pack_name, pi.index,
            });
        }
        return .unresolved;
    }
    // Bare `$<name>` in a type-arg position. Single-type generic
    // bindings (`$R: Type` in `Closure(..$args) -> $R`) live in
    // `type_bindings`; if the name is bound there, return the
    // bound TypeId directly. Pack bindings would otherwise resolve
    // to a slice value, not a single Type — the caller (e.g.
    // `type_name(...)`) expects a single arg.
    if (node.data == .comptime_pack_ref) {
        const cpr = node.data.comptime_pack_ref;
        if (self.type_bindings) |tb| {
            if (tb.get(cpr.pack_name)) |ty| return ty;
        }
    }
    switch (node.data) {
        .identifier => |id| {
            // Check type bindings first (from generic monomorphization)
            if (self.type_bindings) |tb| {
                if (tb.get(id.name)) |ty| return ty;
            }
            // E4 single-hop visibility + ambiguity gate: a bare type name
            // reachable only over 2+ flat hops is not bare-visible in a
            // reflection / type-arg slot (consistent with normal annotations /
            // 0763); ≥2 direct flat same-name authors are ambiguous (loud
            // diagnostic, consistent with the leaf / 0755) instead of a global
            // first-/last-wins pick; a single source-keyed author resolves to
            // ITS TypeId. A genuinely-undeclared name is NOT authored as a type
            // anywhere → `.proceed`, falling to the "unresolved type"
            // diagnostic below.
            switch (self.headTypeGate(id.name, node.span)) {
                .ambiguous, .not_visible => return .unresolved,
                .resolved => |tid| return tid,
                .proceed => {},
            }
            if (self.program_index.type_alias_map.get(id.name)) |alias_ty| return alias_ty;
            const name_id = self.module.types.internString(id.name);
            if (self.module.types.findByName(name_id)) |t| return t;
            if (self.diagnostics) |diags| {
                diags.addFmt(.err, node.span, "unresolved type: '{s}'", .{id.name});
            }
            return .unresolved;
        },
        .type_expr => |te| {
            // Generic bindings first, mirroring the `.identifier` arm — a
            // `$T` referenced from a type-fn arg inside a parameterized
            // target (`x.(struct_field_type(T, i))`) parses as a type_expr,
            // and the stateless resolver below would fabricate a 0-field
            // stub named "T" instead.
            if (self.type_bindings) |tb| {
                if (tb.get(te.name)) |ty| return ty;
            }
            if (self.headTypeLeak(te.name, node.span)) return .unresolved;
            if (self.program_index.type_alias_map.get(te.name)) |alias_ty| return alias_ty;
            return type_bridge.resolveAstType(node, &self.module.types, &self.program_index.type_alias_map, &self.program_index.module_const_map);
        },
        .call => |cl| {
            // `type_of(x)` resolves to `inferExprType(x)` at lower
            // time when `x`'s type is statically known (which it
            // is for any expression — type inference always
            // produces a concrete TypeId). Lets
            // `type_of(a) == i64` fold the same as
            // `inferExprType(a) == i64`.
            if (cl.callee.data == .identifier and
                std.mem.eql(u8, cl.callee.data.identifier.name, "type_of") and
                cl.args.len == 1)
            {
                const aty = self.inferExprType(cl.args[0]);
                // `any`/protocol operands answer the runtime type_id —
                // never fold to the static erased type here (the callers'
                // isStaticTypeArg gates route them dynamic; this is the
                // backstop for paths that reach the fold directly).
                if (aty != .any and self.getProtocolInfo(aty) == null) return aty;
            }
            // Handle type constructor calls: size_of(Sx(f32)), size_of(Complex(u32))
            return self.resolveTypeCallWithBindings(&cl);
        },
        // Wrapped / structural forms (`*T`, `[N]T`, `[]T`, `?T`, fn-ptr, tuple)
        // route through the gated `resolveTypeWithBindings`, whose
        // `resolveCompound` recurses each element through the source-aware leaf
        // (`resolveNominalLeaf`) — so a 2-hop inner leaf (`*COnly`, `[2]COnly`,
        // `(COnly, i64)`) is rejected exactly as in a normal annotation, instead
        // of `type_bridge.resolveAstType`'s ungated global lookup (E4).
        .tuple_literal,
        .tuple_type_expr,
        .pointer_type_expr,
        .many_pointer_type_expr,
        .array_type_expr,
        .slice_type_expr,
        .optional_type_expr,
        .function_type_expr,
        // A parameterized head (`Box(i64)`, or a Type-returning reflection
        // builtin the postfix-cast target parses as one —
        // `x.(struct_field_type(T, i))`) resolves through the gated path,
        // which delegates builtins to `resolveTypeCallWithBindings`.
        .parameterized_type_expr,
        => return self.resolveTypeWithBindings(node),
        // A module-alias-qualified type name in a type-arg slot
        // (`size_of(sel.Selection)`) parses as a field-access EXPRESSION — unlike
        // the dotted `.type_expr` a declaration annotation produces — so without
        // this arm it fell through to `else` and resolved to `.unresolved`
        // (issue 0147). Reconstruct the qualified `obj.field` name and resolve it
        // through the same alias map a declaration uses. Look it up EXPLICITLY
        // (findByName + alias map) rather than via `resolveNamed`, whose
        // empty-struct-stub fallback would silently fabricate a 0-sized type for
        // an unregistered name (the silent-default trap) — a failed lookup must
        // surface as a diagnostic + `.unresolved`.
        .field_access => {
            const path = self.qualifiedTypeName(node) orelse {
                if (self.diagnostics) |diags|
                    diags.addFmt(.err, node.span, "unresolved qualified type in type-argument position", .{});
                return .unresolved;
            };
            defer self.alloc.free(path);
            switch (self.qualifiedMemberVerdict(path)) {
                .selected => |sel| {
                    const saved_src = self.current_source_file;
                    self.setCurrentSourceFile(sel.target.target_module_path);
                    const ty = self.resolveNominalLeaf(sel.member, false, node.span);
                    self.setCurrentSourceFile(saved_src);
                    if (ty != .unresolved) return ty;
                },
                .missing => |m| {
                    if (self.diagnostics) |diags|
                        diags.addFmt(.err, node.span, "namespace '{s}' has no member '{s}'", .{ m.namespace, m.member });
                    return .unresolved;
                },
                .ambiguous => |alias| {
                    if (self.diagnostics) |diags|
                        diags.addFmt(.err, node.span, "namespace '{s}' is ambiguous: aliases from multiple flat-imported modules point at different targets; declare the alias locally", .{alias});
                    return .unresolved;
                },
                .not_qualified => {},
            }
            if (self.diagnostics) |diags| {
                diags.addFmt(.err, node.span, "unresolved qualified type in type-argument position", .{});
            }
            return .unresolved;
        },
        else => return .unresolved,
    }
}

/// Format a type name for display (e.g. "*Point", "[]i32", "[3]f64").
pub fn formatTypeName(self: *Lowering, ty: TypeId) []const u8 {
    // Builtin types: use their canonical name
    if (ty == .i8) return "i8";
    if (ty == .i16) return "i16";
    if (ty == .i32) return "i32";
    if (ty == .i64) return "i64";
    if (ty == .u8) return "u8";
    if (ty == .u16) return "u16";
    if (ty == .u32) return "u32";
    if (ty == .u64) return "u64";
    if (ty == .f32) return "f32";
    if (ty == .f64) return "f64";
    if (ty == .bool) return "bool";
    if (ty == .void) return "void";
    if (ty == .string) return "string";
    if (ty == .any) return "any";
    if (ty == .type_value) return "Type";
    if (ty == .usize) return "usize";
    if (ty == .isize) return "isize";

    const info = self.module.types.get(ty);
    return switch (info) {
        .@"struct" => |s| self.module.types.getString(s.name),
        .@"union" => |u| self.module.types.getString(u.name),
        .tagged_union => |u| self.module.types.getString(u.name),
        .@"enum" => |e| self.module.types.getString(e.name),
        .pointer => |p| blk: {
            const inner = self.formatTypeName(p.pointee);
            break :blk std.fmt.allocPrint(self.alloc, "*{s}", .{inner}) catch "pointer";
        },
        .many_pointer => |p| blk: {
            const inner = self.formatTypeName(p.element);
            break :blk std.fmt.allocPrint(self.alloc, "[*]{s}", .{inner}) catch "many_pointer";
        },
        .slice => |s| blk: {
            const inner = self.formatTypeName(s.element);
            break :blk std.fmt.allocPrint(self.alloc, "[]{s}", .{inner}) catch "slice";
        },
        .array => |a| blk: {
            const inner = self.formatTypeName(a.element);
            break :blk std.fmt.allocPrint(self.alloc, "[{d}]{s}", .{ a.length, inner }) catch "array";
        },
        .signed => |w| std.fmt.allocPrint(self.alloc, "i{d}", .{w}) catch "signed",
        .unsigned => |w| std.fmt.allocPrint(self.alloc, "u{d}", .{w}) catch "unsigned",
        .optional => |o| blk: {
            const inner = self.formatTypeName(o.child);
            break :blk std.fmt.allocPrint(self.alloc, "?{s}", .{inner}) catch "optional";
        },
        .vector => |v| blk: {
            const inner = self.formatTypeName(v.element);
            break :blk std.fmt.allocPrint(self.alloc, "Vector({d},{s})", .{ v.length, inner }) catch "vector";
        },
        .tuple => |t| blk: {
            var buf = std.ArrayList(u8).empty;
            buf.append(self.alloc, '(') catch break :blk "tuple";
            for (t.fields, 0..) |f, i| {
                if (i > 0) buf.appendSlice(self.alloc, ", ") catch break :blk "tuple";
                // Render the field name for named tuples: `(x: i64, y: i64)`.
                if (t.names) |ns| {
                    if (i < ns.len) {
                        buf.appendSlice(self.alloc, self.module.types.getString(ns[i])) catch break :blk "tuple";
                        buf.appendSlice(self.alloc, ": ") catch break :blk "tuple";
                    }
                }
                buf.appendSlice(self.alloc, self.formatTypeName(f)) catch break :blk "tuple";
            }
            // A 1-tuple renders with the trailing comma `(T,)` — `(T)` now means
            // a grouping (the inner type), so the comma is required to spell a
            // 1-tuple unambiguously (and keeps diagnostics self-consistent).
            if (t.fields.len == 1) buf.append(self.alloc, ',') catch break :blk "tuple";
            buf.append(self.alloc, ')') catch break :blk "tuple";
            break :blk buf.toOwnedSlice(self.alloc) catch "tuple";
        },
        // A function TYPE renders as its signature (same spelling as
        // `formatFnTypeString` / the TypeTable formatter: `-> void` omitted) —
        // a diagnostic naming a bare-fn value must show the signature, never
        // the `function` tag (issue 0338).
        .function => |f| blk: {
            var buf = std.ArrayList(u8).empty;
            buf.append(self.alloc, '(') catch break :blk "function";
            for (f.params, 0..) |p, i| {
                if (i > 0) buf.appendSlice(self.alloc, ", ") catch break :blk "function";
                buf.appendSlice(self.alloc, self.formatTypeName(p)) catch break :blk "function";
            }
            buf.append(self.alloc, ')') catch break :blk "function";
            if (f.ret != .void) {
                buf.appendSlice(self.alloc, " -> ") catch break :blk "function";
                buf.appendSlice(self.alloc, self.formatTypeName(f.ret)) catch break :blk "function";
            }
            break :blk buf.toOwnedSlice(self.alloc) catch "function";
        },
        else => @tagName(info),
    };
}

/// Format a function type string like "() -> i32" or "(i32, i32) -> i32".
pub fn formatFnTypeString(self: *Lowering, fd: *const ast.FnDecl) []const u8 {
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = '(';
    pos += 1;
    for (fd.params, 0..) |p, i| {
        if (i > 0) {
            @memcpy(buf[pos..][0..2], ", ");
            pos += 2;
        }
        const pty = self.resolveParamType(&p);
        const name = self.formatTypeName(pty);
        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
    }
    buf[pos] = ')';
    pos += 1;
    const ret_ty = self.resolveReturnType(fd);
    if (ret_ty != .void) {
        @memcpy(buf[pos..][0..4], " -> ");
        pos += 4;
        const rname = self.formatTypeName(ret_ty);
        @memcpy(buf[pos..][0..rname.len], rname);
        pos += rname.len;
    }
    const result = self.alloc.alloc(u8, pos) catch unreachable;
    @memcpy(result, buf[0..pos]);
    return result;
}

/// Format a type name for function name mangling (identifier-safe).
/// E.g. *Point → "ptr_Point", []i32 → "slice_i32", [3]f64 → "array_3_f64".
/// Check if a param type expression references a type param name (possibly nested).
pub fn matchTypeParam(_: *Lowering, type_node: *const Node, tp_name: []const u8) bool {
    return switch (type_node.data) {
        .type_expr => |te| std.mem.eql(u8, te.name, tp_name),
        .identifier => |id| std.mem.eql(u8, id.name, tp_name),
        .slice_type_expr => |st| matchTypeParamStatic(st.element_type, tp_name),
        .pointer_type_expr => |pt| matchTypeParamStatic(pt.pointee_type, tp_name),
        .many_pointer_type_expr => |mp| matchTypeParamStatic(mp.element_type, tp_name),
        .optional_type_expr => |ot| matchTypeParamStatic(ot.inner_type, tp_name),
        .array_type_expr => |at| matchTypeParamStatic(at.element_type, tp_name),
        .closure_type_expr => |ct| blk: {
            for (ct.param_types) |pt| if (matchTypeParamStatic(pt, tp_name)) break :blk true;
            if (ct.return_type) |rt| if (matchTypeParamStatic(rt, tp_name)) break :blk true;
            break :blk false;
        },
        // A failable closure return `Closure() -> $R !E` folds to a `(T, !)`
        // tuple_type_expr, so a `$R` in the value slot lives inside the tuple's
        // field_types — descend so the param is still seen as generic-bearing.
        .tuple_type_expr => |tt| blk: {
            for (tt.field_types) |ft| if (matchTypeParamStatic(ft, tp_name)) break :blk true;
            break :blk false;
        },
        .parameterized_type_expr => |pt| blk: {
            for (pt.args) |a| if (matchTypeParamStatic(a, tp_name)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

pub fn matchTypeParamStatic(type_node: *const Node, tp_name: []const u8) bool {
    return switch (type_node.data) {
        .type_expr => |te| std.mem.eql(u8, te.name, tp_name),
        .identifier => |id| std.mem.eql(u8, id.name, tp_name),
        .slice_type_expr => |st| matchTypeParamStatic(st.element_type, tp_name),
        .pointer_type_expr => |pt| matchTypeParamStatic(pt.pointee_type, tp_name),
        .many_pointer_type_expr => |mp| matchTypeParamStatic(mp.element_type, tp_name),
        .optional_type_expr => |ot| matchTypeParamStatic(ot.inner_type, tp_name),
        .array_type_expr => |at| matchTypeParamStatic(at.element_type, tp_name),
        .closure_type_expr => |ct| blk: {
            for (ct.param_types) |pt| if (matchTypeParamStatic(pt, tp_name)) break :blk true;
            if (ct.return_type) |rt| if (matchTypeParamStatic(rt, tp_name)) break :blk true;
            break :blk false;
        },
        // See the `matchTypeParam` tuple arm — a failable closure return folds
        // to a `(T, !)` tuple_type_expr; descend into its value field(s).
        .tuple_type_expr => |tt| blk: {
            for (tt.field_types) |ft| if (matchTypeParamStatic(ft, tp_name)) break :blk true;
            break :blk false;
        },
        .parameterized_type_expr => |pt| blk: {
            for (pt.args) |a| if (matchTypeParamStatic(a, tp_name)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Extract the concrete type that corresponds to a type param from an arg type.
/// E.g., param type []$T with arg type []i64 → T = i64.
pub fn extractTypeParam(self: *Lowering, type_node: *const Node, arg_ty: TypeId, tp_name: []const u8) ?TypeId {
    return switch (type_node.data) {
        .type_expr => |te| if (std.mem.eql(u8, te.name, tp_name)) arg_ty else null,
        .identifier => |id| if (std.mem.eql(u8, id.name, tp_name)) arg_ty else null,
        .slice_type_expr => |st| blk: {
            // arg_ty should be a slice → extract element type. An array
            // arg coerces to a slice at a `[]T` param (the same promotion
            // concrete slice params perform), so it binds from its
            // element type too (issue 0126).
            if (arg_ty.isBuiltin()) break :blk null;
            const info = self.module.types.get(arg_ty);
            break :blk switch (info) {
                .slice => |s| self.extractTypeParam(st.element_type, s.element, tp_name),
                .array => |a| self.extractTypeParam(st.element_type, a.element, tp_name),
                else => null,
            };
        },
        .pointer_type_expr => |pt| blk: {
            if (arg_ty.isBuiltin()) break :blk null;
            const info = self.module.types.get(arg_ty);
            break :blk switch (info) {
                .pointer => |p| self.extractTypeParam(pt.pointee_type, p.pointee, tp_name),
                // Auto-address-of: a `*Box($T)` param accepts a by-value
                // `Box($T)` arg (the UFCS receiver `b.m()` / a value passed to a
                // pointer param). Match the pointee against the value arg so the
                // type-var still binds (issue 0151).
                else => self.extractTypeParam(pt.pointee_type, arg_ty, tp_name),
            };
        },
        .many_pointer_type_expr => |mp| blk: {
            if (arg_ty.isBuiltin()) break :blk null;
            const info = self.module.types.get(arg_ty);
            break :blk switch (info) {
                .many_pointer => |p| self.extractTypeParam(mp.element_type, p.element, tp_name),
                else => null,
            };
        },
        .optional_type_expr => |ot| blk: {
            if (arg_ty.isBuiltin()) break :blk null;
            const info = self.module.types.get(arg_ty);
            break :blk switch (info) {
                .optional => |o| self.extractTypeParam(ot.inner_type, o.child, tp_name),
                else => null,
            };
        },
        .array_type_expr => |at| blk: {
            if (arg_ty.isBuiltin()) break :blk null;
            const info = self.module.types.get(arg_ty);
            break :blk switch (info) {
                .array => |a| self.extractTypeParam(at.element_type, a.element, tp_name),
                else => null,
            };
        },
        .closure_type_expr => |ct| blk: {
            if (arg_ty.isBuiltin()) break :blk null;
            const info = self.module.types.get(arg_ty);
            const c_params: []const TypeId, const c_ret: TypeId = switch (info) {
                .closure => |c| .{ c.params, c.ret },
                .function => |f| .{ f.params, f.ret },
                else => break :blk null,
            };
            // Prefer the return position (`Closure(...) -> $R`), then params.
            if (ct.return_type) |rt| {
                if (self.extractTypeParam(rt, c_ret, tp_name)) |ety| break :blk ety;
            }
            for (ct.param_types, 0..) |pt, i| {
                if (i >= c_params.len) break;
                if (self.extractTypeParam(pt, c_params[i], tp_name)) |ety| break :blk ety;
            }
            break :blk null;
        },
        .tuple_type_expr => |tt| blk: {
            // A failable closure return `Closure() -> $R !E` folds to a `(T, !)`
            // tuple_type_expr, so this arm is reached when inferring `$R` from a
            // closure ARG's return type. Two arg shapes must both bind:
            //   - failable arg (`() -> i64 !E`): its closure `ret` is a `.tuple`
            //     `(i64, errset)` — match field-wise against the param tuple.
            //   - non-failable arg (`() -> i64`) ∅-widened into the failable slot:
            //     its `ret` is the bare value type `i64` — match the param's FIRST
            //     value field against the whole arg type.
            if (!arg_ty.isBuiltin()) {
                const info = self.module.types.get(arg_ty);
                if (info == .tuple) {
                    const at = info.tuple;
                    for (tt.field_types, 0..) |ft, i| {
                        if (i >= at.fields.len) break;
                        if (self.extractTypeParam(ft, at.fields[i], tp_name)) |ety| break :blk ety;
                    }
                    break :blk null;
                }
            }
            // arg is a bare value type (builtin or single non-tuple): bind it to
            // the tuple's first (value) field.
            if (tt.field_types.len > 0) break :blk self.extractTypeParam(tt.field_types[0], arg_ty, tp_name);
            break :blk null;
        },
        .parameterized_type_expr => |pt| blk: {
            // A generic-struct param head (`Box($T)`, also reached recursively
            // for a pointer-wrapped `*Box($T)`): the arg is a monomorphized
            // instance whose per-param bindings were recorded at instantiation
            // (`struct_instance_bindings`). Recover the concrete type the i-th
            // template param bound and recurse against the i-th param-head arg,
            // so `$T` is inferred from `Box($T)` ⇔ `Box(i64)` exactly as it is
            // from `[]$T` ⇔ `[]i64` (issue 0151).
            if (arg_ty.isBuiltin()) break :blk null;
            const info = self.module.types.get(arg_ty);
            if (info != .@"struct") break :blk null;
            const inst_name = self.module.types.getString(info.@"struct".name);
            const binds = self.struct_instance_bindings.getPtr(inst_name) orelse break :blk null;
            // The param head must name the same template the arg instance was
            // stamped from, so the positional args line up with the params.
            const tmpl_name = self.struct_instance_template.get(inst_name) orelse break :blk null;
            const base_name = if (std.mem.lastIndexOfScalar(u8, pt.name, '.')) |dot| pt.name[dot + 1 ..] else pt.name;
            if (!std.mem.eql(u8, base_name, tmpl_name)) break :blk null;
            const author = self.struct_instance_author.get(inst_name) orelse break :blk null;
            for (author.type_params, 0..) |atp, i| {
                if (i >= pt.args.len) break;
                if (atp.is_variadic) break; // type-pack params not inferred here
                const concrete = binds.get(atp.name) orelse continue;
                if (self.extractTypeParam(pt.args[i], concrete, tp_name)) |ety| break :blk ety;
            }
            break :blk null;
        },
        else => null,
    };
}

/// Mangle a TypeId into its mono-key fragment. Thin delegation to the
/// canonical owner (`GenericResolver`, `generics.zig`); kept on `Lowering`
/// because ~30 cross-cutting callers (impl-map keys, conversion keys, shape
/// keys) reach it here, well beyond generic monomorphization.
pub fn mangleTypeName(self: *Lowering, ty: TypeId) []const u8 {
    return self.genericResolver().mangleTypeName(ty);
}

/// A container type built over `.unresolved` — `[]unresolved`, `*unresolved`.
/// No runtime value can have such a type: `.unresolved` is the sentinel for a
/// resolution that failed, so the container is an artifact of a partially
/// resolved signature, not something a `case slice:` arm could ever receive.
/// The category scan skips these; without that, a type-category dispatch
/// stamps a monomorphized body whose element type is `.unresolved` and the
/// backend panics on it instead of any error being reported (issue 0288).
fn hasUnresolvedElement(info: types.TypeInfo) bool {
    return switch (info) {
        .slice => |s| s.element == .unresolved,
        .array => |a| a.element == .unresolved,
        .many_pointer => |m| m.element == .unresolved,
        .pointer => |p| p.pointee == .unresolved,
        .optional => |o| o.child == .unresolved,
        .closure => |c| blk: {
            if (c.ret == .unresolved) break :blk true;
            for (c.params) |p| {
                if (p == .unresolved) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// Resolve type category names (like "int", "struct", "float") to matching TypeId tag values.
/// Returns a list of TypeId index values that match the category.
pub fn resolveTypeCategoryTags(self: *Lowering, name: []const u8) []const u64 {
    var tags = std.ArrayList(u64).empty;

    // Fixed builtin categories
    if (std.mem.eql(u8, name, "int")) {
        tags.append(self.alloc, TypeId.i8.index()) catch {};
        tags.append(self.alloc, TypeId.i16.index()) catch {};
        tags.append(self.alloc, TypeId.i32.index()) catch {};
        tags.append(self.alloc, TypeId.i64.index()) catch {};
        tags.append(self.alloc, TypeId.u8.index()) catch {};
        tags.append(self.alloc, TypeId.u16.index()) catch {};
        tags.append(self.alloc, TypeId.u32.index()) catch {};
        tags.append(self.alloc, TypeId.u64.index()) catch {};
        tags.append(self.alloc, TypeId.usize.index()) catch {};
        tags.append(self.alloc, TypeId.isize.index()) catch {};
        // Arbitrary-width ints (u2/i5/…) match `case int:` too. Boxing
        // normalizes them into a builtin tag (`boxAnyOf`), but an interior
        // VIEW (`struct_field_value` on an `any` receiver) carries the
        // field's TRUE tag — normalization can't reach a view, so the
        // category list must cover these tags or a view of an arb-width
        // field falls through every arm.
        for (self.module.types.infos.items, 0..) |info, idx| {
            // The builtin widths mirror into the table as `.signed`/
            // `.unsigned` infos at their builtin slots — already listed
            // above; only USER-slot (true arbitrary-width) entries add.
            if (TypeId.fromIndex(@intCast(idx)).isBuiltin()) continue;
            switch (info) {
                .signed, .unsigned => tags.append(self.alloc, @intCast(idx)) catch {},
                else => {},
            }
        }
        return tags.items;
    }
    if (std.mem.eql(u8, name, "float")) {
        tags.append(self.alloc, TypeId.f32.index()) catch {};
        tags.append(self.alloc, TypeId.f64.index()) catch {};
        return tags.items;
    }
    if (std.mem.eql(u8, name, "bool")) {
        tags.append(self.alloc, TypeId.bool.index()) catch {};
        return tags.items;
    }
    if (std.mem.eql(u8, name, "string")) {
        tags.append(self.alloc, TypeId.string.index()) catch {};
        return tags.items;
    }
    if (std.mem.eql(u8, name, "void")) {
        tags.append(self.alloc, TypeId.void.index()) catch {};
        return tags.items;
    }
    if (std.mem.eql(u8, name, "type") or std.mem.eql(u8, name, "Type")) {
        // A Type value's runtime tag is `.type_value` (was `.any` when Type and
        // Any shared a TypeId) — so `case type:` matches an Any holding a Type.
        tags.append(self.alloc, TypeId.type_value.index()) catch {};
        return tags.items;
    }

    // Dynamic categories: scan TypeTable for matching types
    const Category = enum { @"struct", @"enum", @"union", slice, array, pointer, vector, optional, error_set, closure };
    const cat: ?Category = if (std.mem.eql(u8, name, "struct"))
        .@"struct"
    else if (std.mem.eql(u8, name, "enum"))
        .@"enum"
    else if (std.mem.eql(u8, name, "union"))
        .@"union"
    else if (std.mem.eql(u8, name, "slice"))
        .slice
    else if (std.mem.eql(u8, name, "array"))
        .array
    else if (std.mem.eql(u8, name, "pointer"))
        .pointer
    else if (std.mem.eql(u8, name, "vector"))
        .vector
    else if (std.mem.eql(u8, name, "optional"))
        .optional
    else if (std.mem.eql(u8, name, "error_set"))
        .error_set
    else if (std.mem.eql(u8, name, "closure"))
        .closure
    else
        null;

    if (cat) |c| {
        for (self.module.types.infos.items, 0..) |info, idx| {
            const matches = switch (c) {
                .@"struct" => info == .@"struct",
                .@"enum" => info == .@"enum" or info == .tagged_union,
                .@"union" => info == .@"union" or info == .tagged_union,
                .slice => info == .slice,
                .array => info == .array,
                .pointer => info == .pointer or info == .many_pointer,
                .vector => info == .vector,
                .optional => info == .optional,
                .error_set => info == .error_set,
                .closure => info == .closure,
            };
            if (matches and !hasUnresolvedElement(info)) {
                tags.append(self.alloc, @intCast(idx)) catch {};
            }
        }
    }

    // Specific type name (e.g., Point, Color) — look up in type registry
    if (tags.items.len == 0) {
        const name_id = self.module.types.internString(name);
        if (self.module.types.findByName(name_id)) |tid| {
            tags.append(self.alloc, tid.index()) catch {};
        }
    }

    return tags.items;
}

/// The type a match arm's payload capture (`case .v: (x)`) binds, from the
/// subject's type: a tagged-union arm captures its variant's payload, an
/// optional arm captures the unwrapped child (mirrors `lowerMatch`'s capture
/// lowering). Null when the subject/pattern supplies no typed payload — the
/// arm-level binding guard (issue 0163) diagnoses those at lowering.
fn matchCaptureType(self: *Lowering, subject_ty: TypeId, pattern: ?*const Node) ?TypeId {
    if (subject_ty.isBuiltin()) return null;
    switch (self.module.types.get(subject_ty)) {
        .optional => |o| return o.child,
        .tagged_union => |tu| {
            const pat = pattern orelse return null;
            const pat_name = switch (pat.data) {
                .enum_literal => |el| el.name,
                .identifier => |id| id.name,
                else => return null,
            };
            for (tu.fields) |f| {
                if (std.mem.eql(u8, self.module.types.strings.get(f.name), pat_name)) return f.ty;
            }
            return null;
        },
        else => return null,
    }
}

pub fn inferMatchResultType(self: *Lowering, me: *const ast.MatchExpr) TypeId {
    // Subject type for typing arm captures: payload types come from the
    // subject's tagged-union/optional info. A pointer subject auto-derefs in
    // the lowering (`lowerMatch`), so normalize to the pointee here too —
    // otherwise a `*TaggedUnion` subject types every capture-using arm
    // `.unresolved` and a VALUE-position match leaks an unresolved result
    // type to its consumer (issue 0226).
    var subject_ty = self.inferExprType(me.subject);
    if (!subject_ty.isBuiltin()) {
        const sinfo = self.module.types.get(subject_ty);
        if (sinfo == .pointer and !sinfo.pointer.pointee.isBuiltin()) {
            const pinfo = self.module.types.get(sinfo.pointer.pointee);
            if (pinfo == .tagged_union or pinfo == .@"enum") subject_ty = sinfo.pointer.pointee;
        }
    }
    // Unify the result type across ALL value-producing arms (issue 0236).
    // `null` arms contribute optionality (?T), diverging (`noreturn`) and
    // non-inferable (`.unresolved`) arms don't decide, and the remaining arm
    // types fold through `unifyMatchArmTypes` — the same implicit-coercion
    // lattice the if/else-expression merge feeds `coerceToType`, but joined
    // SYMMETRICALLY so arm order never picks the type (int ⊔ float = the
    // float in BOTH orders, preserving the issue-0226 pinned "f64 payload
    // arm + int-literal arm → f64"). A pair with no safe coercion in either
    // direction is a true mismatch: diagnose at the offending arm — pre-fix
    // it reached the backend as a mixed-type phi (LLVM verifier failure, no
    // diagnostic).
    var has_null = false;
    var saw_unresolved = false;
    var saw_noreturn = false;
    var result: ?TypeId = null;
    for (me.arms) |arm| {
        // A DIVERGING arm (`return`/`raise`/`break`/`continue`, or a `noreturn`
        // expression) never reaches the merge, so it must NOT decide the result
        // type (issue 0269 match analog): a diverging FIRST arm used to make
        // `last_node` a void inner block and return `.void` early, collapsing a
        // real value-`match` (`z := if e == { case .A: { return -9; } case .B:
        // { 20 } }`) to a void statement that `alloca void`'d. Skip it — the
        // match is `noreturn` only if EVERY arm diverges (handled after the
        // loop). `armStaticallyDiverges` peels the match-arm block wrapper.
        if (self.armStaticallyDiverges(arm.body)) {
            saw_noreturn = true;
            continue;
        }
        const last_node = if (arm.body.data == .block) blk: {
            if (arm.body.data.block.stmts.len > 0) {
                break :blk arm.body.data.block.stmts[arm.body.data.block.stmts.len - 1];
            }
            break :blk arm.body;
        } else arm.body;

        if (last_node.data == .null_literal) {
            has_null = true;
            continue;
        }

        // Type the arm body with its payload capture in scope — bound by TYPE
        // only (`Ref.none`; nothing is lowered here). Without it, an arm whose
        // value depends on the capture types `.unresolved` (issue 0226).
        var cap_scope: ?Scope = null;
        defer if (cap_scope) |*cs| cs.deinit();
        const saved_scope = self.scope;
        defer self.scope = saved_scope;
        if (arm.capture) |cap| {
            if (matchCaptureType(self, subject_ty, arm.pattern)) |cap_ty| {
                cap_scope = Scope.init(self.alloc, self.scope);
                cap_scope.?.put(cap, .{ .ref = Ref.none, .ty = cap_ty, .is_alloca = false });
                self.scope = &cap_scope.?;
            }
        }

        // An arm whose type isn't inferable from the AST alone (e.g. a bare
        // enum literal) doesn't decide — keep looking; the caller falls back
        // to the contextual target type if none of the arms resolve.
        const arm_ty = self.inferExprType(last_node);
        // A diverging arm (`noreturn` — `return` / `raise` / `break` /
        // `continue`) doesn't produce a value, so it doesn't decide the
        // result type; keep looking. The match is `noreturn` only if EVERY
        // arm diverges (handled after the loop).
        if (arm_ty == .noreturn) {
            saw_noreturn = true;
            continue;
        }
        if (arm_ty == .unresolved) {
            saw_unresolved = true;
            continue;
        }
        if (result == null) {
            // A `.void` FIRST decisive arm means "no value" — the match is a
            // statement; later arms' discarded tails don't re-open it (the
            // pre-unification behavior: the first decisive arm returned
            // immediately, void included).
            if (arm_ty == .void) return .void;
            result = arm_ty;
            continue;
        }
        // A later void-tail arm doesn't join: in a value match it keeps the
        // pre-unification default-fill behavior (`lowerMatch` substitutes a
        // zero/undef of the result type for a valueless arm).
        if (arm_ty == .void) continue;
        if (unifyValueArmTypes(self, result.?, arm_ty)) |joined| {
            result = joined;
        } else if (self.diagnostics) |diags| {
            diags.addFmt(.err, last_node.span, "match arms have incompatible types: '{s}' vs '{s}'", .{
                self.formatTypeName(result.?),
                self.formatTypeName(arm_ty),
            });
        }
    }
    if (result) |r| {
        if (has_null) return self.module.types.optionalOf(r);
        return r;
    }
    if (saw_unresolved) return .unresolved;
    if (saw_noreturn) return .noreturn; // all arms diverge
    return .void;
}

/// Join two match-arm result types over the implicit-coercion lattice
/// (issue 0236). Numerics join SYMMETRICALLY — a float beats an int, a wider
/// width beats a narrower one — so arm order never decides the type. This
/// deliberately diverges from the if/else-expression merge (first-branch-wins,
/// which silently truncates `i64` into an `i32`-typed first branch) to
/// preserve the issue-0226 pinned outcome: an f64 payload-capture arm and an
/// int-literal arm yield f64 in BOTH orders. Every non-numeric pair mirrors
/// if/else exactly: the earlier type wins when the later arm's value can
/// safely become it — a modeled coercion or a same-width bit-compatible
/// reinterpret, i.e. NOT `noneReinterpretIsUnsafe`, the same predicate the
/// store guard (issue 0197) uses — else the join flips to the later type when
/// only that direction coerces. Null = no safe direction either way: a true
/// mismatch the caller diagnoses.
pub fn unifyValueArmTypes(self: *Lowering, a: TypeId, b: TypeId) ?TypeId {
    if (a == b) return a;
    const a_float = Lowering.isFloat(a);
    const b_float = Lowering.isFloat(b);
    const a_num = a_float or self.isIntEx(a);
    const b_num = b_float or self.isIntEx(b);
    if (a_num and b_num) {
        if (a_float != b_float) return if (a_float) a else b;
        return if (self.typeBitsEx(b) > self.typeBitsEx(a)) b else a;
    }
    if (!self.noneReinterpretIsUnsafe(b, a)) return a;
    if (!self.noneReinterpretIsUnsafe(a, b)) return b;
    return null;
}

/// Is `name` a runtime type-CATEGORY keyword denoting a tag SET (many
/// types), for the `any`-subject type switch? Single-type names that the
/// category match also accepts (`string` / `bool` / `void`) are NOT listed:
/// the type switch routes those through the concrete-type path so their
/// arms can bind a capture (`case string: (s)`), which a set never can.
/// `type`/`Type` stay set-style (a Type-holding `any` is dispatch-only).
pub fn isRuntimeCategoryName(name: []const u8) bool {
    const cats = [_][]const u8{
        "int",   "float",   "struct", "enum",     "union",     "slice",
        "array", "pointer", "vector", "optional", "error_set", "closure",
        "type",  "Type",
    };
    for (cats) |c| if (std.mem.eql(u8, name, c)) return true;
    return false;
}

/// Check if a match expression is a type-category match (patterns are type/category names).
pub fn isTypeCategoryMatch(me: *const ast.MatchExpr) bool {
    for (me.arms) |arm| {
        if (arm.pattern) |pat| {
            const name = switch (pat.data) {
                .identifier => |id| id.name,
                .type_expr => |te| te.name,
                else => continue,
            };
            const categories = [_][]const u8{
                "int",     "float",    "bool",      "string", "void",  "type",    "Type",
                "struct",  "enum",     "union",     "slice",  "array", "pointer", "vector",
                "closure", "optional", "error_set",
            };
            for (categories) |cat| {
                if (std.mem.eql(u8, name, cat)) return true;
            }
            // Also match specific struct/enum type names (e.g., case Point:)
            if (name.len > 0 and name[0] >= 'A' and name[0] <= 'Z') return true;
        }
    }
    return false;
}

/// Check if a param is a type param declaration ($T: Type).
/// A type param declaration has param.name == one of the type_params names.
pub fn isTypeParamDecl(param: *const ast.Param, type_params: []const ast.StructTypeParam) bool {
    for (type_params) |tp| {
        if (std.mem.eql(u8, param.name, tp.name)) return true;
    }
    return false;
}

/// Check if a function has comptime (non-Type) value parameters.
pub fn hasComptimeParams(fd: *const ast.FnDecl) bool {
    for (fd.params) |p| {
        if (p.is_comptime) return true;
    }
    return false;
}

/// A plain free function: no type params (not generic) and an ordinary sx
/// body (not `extern` / `intrinsic` / `#compiler` / `extern`). Only these get
/// an out-of-line identity-addressable slot — the bare-call disambiguation
/// and the shadow-author lowering pass leave every other shape
/// to the existing name-keyed dispatch.
pub fn isPlainFreeFn(fd: *const ast.FnDecl) bool {
    if (fd.type_params.len > 0) return false;
    // An `extern` import is an external C symbol with no sx-lowerable body —
    // name-keyed first-wins dispatch like a `extern` body, never a plain free
    // fn. `export` DEFINES a real body, so it stays plain-free.
    if (fd.extern_export == .extern_) return false;
    return switch (fd.body.data) {
        .intrinsic_expr => false,
        else => true,
    };
}

/// Resolve a generic value-param argument (`$K: u32`) to its compile-time
/// integer AND verify it fits the param's declared integer type. The folded
/// value is bound and mangled into the instantiation name, so a module/generic
/// const arg (`Vec(N, f32)`), a const expression (`Make(M + 1, i64)`), an
/// integral float (`Box(4.0)` → 4), and a literal (`Vec(3, f32)`) all bind the
/// same value a literal would. An out-of-range arg (`Box(5_000_000_000)` for a
/// `u32` param) or a non-const arg emits a clean diagnostic and returns null;
/// the caller bails rather than binding a truncated / fabricated value under a
/// wrong mangled name.
///
/// `type_name` is the param's declared constraint type (`"u32"`, null if
/// unknown). A `u32` count routes through the shared
/// `program_index.foldDimU32` — the SAME fold-and-narrow gate an array dim /
/// Vector lane uses — so the documented "single u32 gate for value-param
/// counts" holds; any other integer type range-checks against
/// `program_index.intTypeRange`; an unrecognised type folds without bounding.
pub fn resolveValueParamArg(self: *Lowering, arg_node: *const Node, param_name: []const u8, type_name: ?[]const u8) ?i64 {
    // Resolve an ALIASED integer constraint (`$K: Count` where `Count :: u32`,
    // `$K: Small` where `Small :: i8`) to its underlying builtin so the range
    // gate below treats it exactly like `$K: u32` / `$K: i8` (an
    // alias previously slipped past `intTypeRange`, so `Box(5_000_000_000)`
    // with `$K: Count` bound a truncated value). A non-integer / unrecognised
    // constraint yields null → no range bound (fold only), as before.
    const tn_canon: ?[]const u8 = if (type_name) |tn| self.canonicalIntConstraintName(tn) else null;
    if (tn_canon) |tn| {
        if (std.mem.eql(u8, tn, "u32")) {
            switch (program_index_mod.foldDimU32(arg_node, self, 0)) {
                .ok => |n| return n,
                .not_const, .non_integral_float => {
                    self.diagValueParamNotConst(arg_node, param_name);
                    return null;
                },
                .below_min => |v| {
                    self.diagValueParamRange(arg_node, param_name, tn, v);
                    return null;
                },
                .too_large => |v| {
                    self.diagValueParamRange(arg_node, param_name, tn, v);
                    return null;
                },
            }
        }
    }
    // Non-`u32` integer constraint: fold through the SAME unified count fold
    // so an integral float arg (`Box(4.0)`, `Make(F + 1.5, ...)`) binds the
    // integer it equals, exactly as the `u32` gate above does; a non-integral
    // float / non-const arg is not a valid count.
    const v = switch (program_index_mod.foldCountI64(arg_node, self)) {
        .int => |iv| iv,
        .non_integral, .not_const => {
            self.diagValueParamNotConst(arg_node, param_name);
            return null;
        },
    };
    if (tn_canon) |tn| {
        if (program_index_mod.intTypeRange(tn)) |r| {
            if (v < r.min or v > r.max) {
                self.diagValueParamRange(arg_node, param_name, tn, v);
                return null;
            }
        }
    }
    return v;
}

/// Resolve a generic value-param constraint type NAME to its canonical builtin
/// integer type name, chasing a type alias (`Count :: u32` → "u32",
/// `Small :: i8` → "i8") so an ALIASED integer constraint range-checks exactly
/// like the builtin it names. Returns the name unchanged when it is already a
/// builtin integer; null when it isn't an integer type (directly or via alias)
/// — the caller then folds without a range bound rather than guessing. The
/// alias map + type table are the same single sources every other resolver
/// reads, so this can't diverge from how the alias is laid out elsewhere.
pub fn canonicalIntConstraintName(self: *Lowering, name: []const u8) ?[]const u8 {
    if (program_index_mod.intTypeRange(name) != null) return name;
    if (self.program_index.type_alias_map.get(name)) |tid| {
        const canon = self.module.types.typeName(tid);
        if (program_index_mod.intTypeRange(canon) != null) return canon;
    }
    return null;
}

pub fn diagValueParamNotConst(self: *Lowering, arg_node: *const Node, param_name: []const u8) void {
    if (self.diagnostics) |d|
        d.addFmt(.err, arg_node.span, "generic value parameter '{s}' must be a compile-time integer constant", .{param_name});
}

pub fn diagValueParamRange(self: *Lowering, arg_node: *const Node, param_name: []const u8, type_name: []const u8, value: i64) void {
    if (self.diagnostics) |d|
        d.addFmt(.err, arg_node.span, "value {} does not fit in {s} parameter {s}", .{ value, type_name, param_name });
}

/// The poison-vs-proceed projection of `headTypeGate` for an UNQUALIFIED
/// parameterized type HEAD that names a generic STRUCT, a parameterized
/// PROTOCOL, or a type-returning function used as a head (`Box(i64)`,
/// `VL(i64)`) — and the alias-registration / type-match sites that likewise
/// only need "poison or proceed". Returns TRUE (the gate's loud diagnostic is
/// already emitted) when the head is `.not_visible` (a 2-flat-hop leak) or
/// `.ambiguous` (≥2 direct flat same-name authors — consistent with the leaf /
/// 0755); FALSE when it resolves or falls open. See `headTypeGate` for the full
/// non-transitive visibility + ambiguity model and the fall-open conditions.
pub fn headTypeLeak(self: *Lowering, name: []const u8, span: ?ast.Span) bool {
    // A head site INSTANTIATES (template / type-fn) rather than substituting a
    // nominal TypeId, so it consumes only the poison-vs-proceed bit of the
    // full author outcome: `.ambiguous` / `.not_visible` (loud diagnostic
    // already emitted by `headTypeGate`) poison; `.resolved` / `.proceed`
    // proceed to instantiation.
    return switch (self.headTypeGate(name, span)) {
        .ambiguous, .not_visible => true,
        .proceed, .resolved => false,
    };
}

/// Control-flow outcome of the generic-struct LAYOUT-head selector. Carries no
/// diagnostic for the caller to emit — `selectGenericStructHead` emits inline.
const HeadTemplate = union(enum) {
    template: StructTemplate, // visible bare author OR qualified author → instantiate
    poisoned, // gate already diagnosed → caller returns .unresolved / Ref.none
    not_generic, // name is not a generic struct head → caller's non-struct path
};

/// THE single selector every generic-struct LAYOUT-head site funnels through —
/// no head site reads `struct_template_map` for selection directly. Decides the
/// authoring template for a head named `name`, optionally carrying the COMPLETE
/// qualified spelling (`ns.Box` / `facade.engine_alias.Box`). Emits visibility,
/// ambiguity, and missing-member diagnostics INLINE at `span`,
/// at the same program point and ordering the sites used before (0767/0769/0775),
/// and returns a control-flow-only outcome:
///   - qualified, every namespace edge is proved and the exact terminal author
///     is a generic struct → rebuild that author's template.
///   - qualified, a namespace edge/member is missing → diagnose and poison,
///     `.poisoned` (never the bare global map, E4 #2).
///   - qualified, namespace authors `name` but NOT as a generic struct (a
///     type-fn / named type) → `.not_generic` (caller's non-struct path).
///   - qualified but not a namespace path → `.not_generic`; NEVER use a global
///     template merely because a nested qualifier could not be represented.
///   - bare, ≥2 visible authors / 2-flat-hop only → `headTypeLeak` diagnosed →
///     `.poisoned`.
///   - bare, single visible author → that author (own / 1-hop flat), source-keyed.
///   - bare, visible author IS the canonical map author → the global template
///     (byte-identical single-author path).
///   - not in `struct_template_map` at all → `.not_generic`.
pub fn selectGenericStructHead(self: *Lowering, name: []const u8, qualified_path: ?[]const u8, is_qualified: bool, span: ?ast.Span) HeadTemplate {
    if (is_qualified) {
        const path = qualified_path orelse return .not_generic;
        switch (self.qualifiedMemberVerdict(path)) {
            .selected => |sel| {
                const sd: *const ast.StructDecl = switch (sel.author.raw) {
                    .struct_decl => |decl| decl,
                    .const_decl => |cd| if (cd.value.data == .struct_decl) &cd.value.data.struct_decl else return .not_generic,
                    else => return .not_generic,
                };
                if (!std.mem.eql(u8, sd.name, name) or sd.type_params.len == 0) return .not_generic;
                const tmpl = self.buildGenericStructTemplate(sd, sel.author.source) orelse return .poisoned;
                return .{ .template = tmpl };
            },
            .missing => |m| {
                if (self.diagnostics) |d|
                    d.addFmt(.err, span, "namespace '{s}' has no member '{s}'", .{ m.namespace, m.member });
                return .poisoned;
            },
            .ambiguous => |alias| {
                if (self.diagnostics) |d|
                    d.addFmt(.err, span, "namespace '{s}' is ambiguous: aliases from multiple flat-imported modules point at different targets; declare the alias locally", .{alias});
                return .poisoned;
            },
            .not_qualified => return .not_generic,
        }
    }
    // Const-alias head (`BoxAlias :: Box;` / `Box :: r.Box;`, issue 0120):
    // follow the alias decl hop-by-hop to its authoring template, each hop
    // resolved from that alias author's own source. Checked BEFORE the map:
    // the alias may share its name with a same-name template that is NOT
    // visible from here (a facade's `Box :: r.Box;` re-export of rich's
    // `Box`), and the map branch would poison on that invisible author.
    // Only fires when the single visible author (own-wins / single-flat)
    // IS an alias-shaped const decl, so real template heads are untouched.
    if (self.current_source_file) |from| {
        if (self.aliasedStructTemplate(name, from)) |t| return .{ .template = t };
    }
    if (self.program_index.struct_template_map.getPtr(name)) |tmpl| {
        if (self.headTypeLeak(name, span)) return .poisoned;
        if (self.bareVisibleStructTemplate(name)) |vt| return .{ .template = vt };
        return .{ .template = tmpl.* };
    }
    return .not_generic;
}

/// Node-shaped wrapper for every call-syntax generic head. It reconstructs the
/// complete dotted path once, keeping nested namespace provenance intact.
pub fn selectGenericStructCallee(self: *Lowering, callee: *const Node, span: ?ast.Span) HeadTemplate {
    const hn = headNameOfCallee(callee) orelse return .not_generic;
    if (!hn.is_qualified) return self.selectGenericStructHead(hn.name, null, false, span);
    const path = self.qualifiedTypeName(callee) orelse return .not_generic;
    defer self.alloc.free(path);
    return self.selectGenericStructHead(hn.name, path, true, span);
}

/// Decompose a head callee NODE (`.identifier Box` or `.field_access ns.Box`)
/// into the `(name, alias, is_qualified)` triple `selectGenericStructHead`
/// consumes. `alias` is the namespace identifier only for a `.field_access`
/// whose object is a plain identifier; a nested / non-identifier object is
/// qualified-but-unaliased.
const HeadName = struct { name: []const u8, alias: ?[]const u8, is_qualified: bool };
pub fn headNameOfCallee(callee: *const Node) ?HeadName {
    return switch (callee.data) {
        .identifier => |id| .{ .name = id.name, .alias = null, .is_qualified = false },
        .field_access => |fa| .{
            .name = fa.field,
            .alias = if (fa.object.data == .identifier) fa.object.data.identifier.name else null,
            .is_qualified = true,
        },
        else => null,
    };
}

/// The complete source-aware author outcome of an UNQUALIFIED bare TYPE head —
/// the unified non-transitive visibility + ambiguity gate every bare-type-
/// reference site OUTSIDE the nominal leaf routes through (E4 attempt-5):
/// reflection / type-arg slots, typed array/vector-literal heads, parameterized
/// generic / protocol / type-fn heads, type-as-value, and type-category match
/// arms. Mirrors `selectNominalLeaf`'s author model so a 2-flat-hop type is
/// `.not_visible`, ≥2 direct flat same-name authors are `.ambiguous` (the LOUD
/// diagnostic, consistent with the leaf / 0755 — never a silent global
/// `findByName` / `struct_template_map` first-/last-wins pick), and a single
/// direct flat author resolves to ITS source-keyed TypeId. Falls open
/// (`.proceed`) when import facts are unwired, the source context is absent,
/// the default-Context emitter is running (built-in infrastructure resolves
/// independent of the user's import style, F1), the querying source is the OWN
/// author, a single flat author is not registered yet (a forward / extern /
/// generic template — the caller instantiates it), or `name` is a block-local
/// of this source / no type author at all. Library-internal heads stay visible
/// because every instantiation kind is source-pinned to the template's defining
/// module (E3/E4 #1): the query originates THERE, where the head is a direct
/// flat import. A namespaced `ns.Box(..)` head is an explicit qualified reach
/// and is exempt (the caller skips this gate).
const HeadTypeGate = union(enum) {
    proceed,
    resolved: TypeId,
    ambiguous,
    not_visible,
};
pub fn headTypeGate(self: *Lowering, name: []const u8, span: ?ast.Span) HeadTypeGate {
    if (self.emitting_default_context) return .proceed;
    if (self.program_index.module_decls == null or self.program_index.flat_import_graph == null) return .proceed;
    const from = self.current_source_file orelse return .proceed;

    var res_walk = self.resolver();
    const author_set = res_walk.collectVisibleAuthors(name, from, .user_bare_flat);
    defer if (author_set.flat.len > 0) self.alloc.free(author_set.flat);

    // Own author wins outright (own-wins, 0754). Pending / unregistered → .proceed.
    if (author_set.own) |own| switch (own.raw) {
        .const_decl => {
            if (self.program_index.type_aliases_by_source.get(own.source)) |inner| {
                if (inner.get(name)) |tid| return .{ .resolved = tid };
            }
            return .proceed;
        },
        else => if (isNamedTypeKind(own.raw)) {
            if (self.namedRefTid(own.raw, name)) |tid| return .{ .resolved = tid };
            return .proceed;
        },
    };

    // Flat type authors
    var flat_type_count: usize = 0;
    var found_tid: ?TypeId = null;
    var flat_tid_count: usize = 0;
    for (author_set.flat) |fa| {
        const is_type = switch (fa.raw) {
            .const_decl => blk: {
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
                if (self.program_index.type_aliases_by_source.get(fa.source)) |inner|
                    break :blk inner.get(name);
                break :blk null;
            },
            else => self.namedRefTid(fa.raw, name),
        };
        if (fa_tid) |t| {
            flat_tid_count += 1;
            if (found_tid) |f| {
                if (t != f) {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, span, "type '{s}' is ambiguous: it is declared in multiple flat-imported modules; qualify the reference or remove the duplicate import", .{name});
                    return .ambiguous;
                }
            } else found_tid = t;
        }
    }
    if (flat_type_count > 0) {
        // ≥2 authors but not all resolved to one TypeId → ambiguous
        if (flat_type_count >= 2 and !(flat_tid_count == flat_type_count and found_tid != null)) {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "type '{s}' is ambiguous: it is declared in multiple flat-imported modules; qualify the reference or remove the duplicate import", .{name});
            return .ambiguous;
        }
        if (found_tid) |t| return .{ .resolved = t };
        return .proceed; // single author exists but TypeId not registered
    }

    if (self.localTypeInSource(from, name)) return .proceed;
    if (!self.nameAuthoredAsTypeAnywhere(name)) return .proceed;
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "type '{s}' is not visible; #import the module that declares it", .{name});
    return .not_visible;
}

/// Single-hop non-transitive visibility + ambiguity gate for an UNQUALIFIED
/// type-returning FUNCTION head used as a type (`Make(N, T)` where
/// `Make :: ($K, $T) -> Type`). A type-fn is a `fn_decl`, so visibility is
/// decided from the ELIGIBLE FUNCTION authors directly reachable from the use
/// site (`flatFnAuthorVisible`) — NOT the module-scope NAME predicate
/// (`isNameVisible`), which a same-name NON-function (a value const, a named
/// type) would wrongly vouch for. Returns TRUE (loud diagnostic already
/// emitted) when the head is AMBIGUOUS (≥2 distinct direct flat same-name
/// type-fn authors, no own author — consistent with the parameterized struct /
/// protocol heads and the leaf, 0755/0767, never a silent `fn_ast_map`
/// first-/last-wins pick) or NOT-VISIBLE (its only directly-visible same-name
/// author is a non-function and the real type-fn author is ≥2 flat hops away).
/// A scope-local (mangled) type-fn or the querying source's OWN function author
/// wins outright (own-wins) and is exempt; falls open when unwired /
/// default-context. Diagnostic mirrors the type form (the head IS used as a type
/// here).
pub fn headFnLeak(self: *Lowering, name: []const u8, span: ?ast.Span) bool {
    if (self.emitting_default_context) return false;
    const from = self.current_source_file orelse return false;
    if (self.scope) |s| if (s.lookupFn(name) != null) return false;
    // Fall open when the import facts aren't wired (comptime callers,
    // directory imports without a main file): the author collector would
    // otherwise return an empty set and wrongly report a genuinely-visible
    // type-fn as not-visible. Mirrors `headTypeGate`'s guard.
    if (self.program_index.module_decls == null or self.program_index.flat_import_graph == null) return false;
    // ≥2 distinct direct flat type-fn authors with no own author — a genuine
    // collision the source cannot disambiguate. Diagnose loudly BEFORE the
    // visibility short-circuit, which would otherwise let the single
    // `fn_ast_map[name]` author silently win.
    if (self.flatFnAuthorAmbiguous(name, from)) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "type '{s}' is ambiguous: it is declared in multiple flat-imported modules; qualify the reference or remove the duplicate import", .{name});
        return true;
    }
    // KIND-AWARE: visible iff a directly-reachable (own or 1-hop flat) author
    // is itself a TYPE-FUNCTION. A same-name 1-hop non-function (attempt-7) OR
    // ordinary non-type function (attempt-8) does NOT vouch for a type-fn head
    // whose real author is 2 flat hops away.
    if (self.flatFnAuthorVisible(name, from)) return false;
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "type '{s}' is not visible; #import the module that declares it", .{name});
    return true;
}

/// TRUE iff bare `name` has ≥2 DISTINCT direct flat-import authors that are
/// TYPE-FUNCTIONS (`typeFnAuthor`: a `fn_decl` with ≥1 `$`-param — an ordinary
/// same-name function does not count) and the querying source authors NONE
/// itself. The querying source's OWN
/// author wins outright (own-wins), so an own author short-circuits to "not
/// ambiguous" — the existing single-author path instantiates it. Diamond
/// imports of the SAME author collapse in `collectVisibleAuthors`'s
/// author-identity de-dup, so two edges onto one type-fn are NOT ambiguous. The
/// type-fn ambiguity analogue of `flatTypeAuthorCount`'s `.ambiguous` for named
/// type / template heads.
pub fn flatFnAuthorAmbiguous(self: *Lowering, name: []const u8, from: []const u8) bool {
    var res = self.resolver();
    const set = res.collectVisibleAuthors(name, from, .user_bare_flat);
    defer if (set.flat.len > 0) self.alloc.free(set.flat);
    if (set.own != null) return false; // own-wins
    var fn_authors: usize = 0;
    for (set.flat) |fa| {
        if (typeFnAuthor(fa.raw)) fn_authors += 1;
    }
    return fn_authors >= 2;
}

/// TRUE iff bare `name` has at least one DIRECTLY-visible author — the
/// querying source's OWN author or a 1-hop flat-import author — that is a
/// TYPE-FUNCTION (`typeFnAuthor`: a `fn_decl` with ≥1 `$`-param). The KIND-AWARE
/// analogue of `isNameVisible` for a type-fn head: a same-name 1-hop
/// NON-function (a value const `Make :: 123`, a named type) does NOT vouch
/// (attempt-7), and — crucially — neither does a same-name 1-hop ORDINARY
/// function (`Make :: () -> i32`, zero `$`-params), which cannot be the type
/// head being instantiated (attempt-8). So a type-fn whose only directly-
/// visible same-name author is a non-fn OR a non-type-fn — its real author 2
/// flat hops away — is correctly invisible. Mirrors `flatFnAuthorAmbiguous`'s
/// type-fn-only author view.
pub fn flatFnAuthorVisible(self: *Lowering, name: []const u8, from: []const u8) bool {
    var res = self.resolver();
    const set = res.collectVisibleAuthors(name, from, .user_bare_flat);
    defer if (set.flat.len > 0) self.alloc.free(set.flat);
    if (set.own) |own| {
        if (typeFnAuthor(own.raw)) return true;
    }
    for (set.flat) |fa| {
        if (typeFnAuthor(fa.raw)) return true;
    }
    return false;
}

/// Resolve a .call node that represents a type constructor (e.g., List(T), Vector(N, T)).
/// The `idx`-th member type of `t` for `field_type($T, i)`: a struct field,
/// a tagged-union variant payload (`.void` for a tagless variant), a tuple
/// element, a `union` field, the element type of an array/vector (index
/// ignored — every element shares it), a slice's element (index 0 — the
/// static length doesn't exist), or an optional's child (index 0). Matches
/// what the runtime member-type tables answer for the same tags (issue
/// 0300). Out-of-range or a memberless type diagnoses and poisons to
/// `.unresolved` (never a silent default).
pub fn fieldTypeOf(self: *Lowering, t: TypeId, idx: usize, span: ?ast.Span) TypeId {
    const oob = struct {
        fn err(s: *Lowering, sp: ?ast.Span, i: usize, n: usize) TypeId {
            if (s.diagnostics) |d|
                d.addFmt(.err, sp, "field_type index {d} out of range ({d} field{s})", .{ i, n, if (n == 1) @as([]const u8, "") else "s" });
            return .unresolved;
        }
    };
    if (t.isBuiltin()) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "field_type: '{s}' has no fields", .{self.formatTypeName(t)});
        return .unresolved;
    }
    return switch (self.module.types.get(t)) {
        .@"struct" => |s| if (idx < s.fields.len) s.fields[idx].ty else oob.err(self, span, idx, s.fields.len),
        .tagged_union => |u| if (idx < u.fields.len) u.fields[idx].ty else oob.err(self, span, idx, u.fields.len),
        .@"union" => |u| if (idx < u.fields.len) u.fields[idx].ty else oob.err(self, span, idx, u.fields.len),
        .tuple => |tup| if (idx < tup.fields.len) tup.fields[idx] else oob.err(self, span, idx, tup.fields.len),
        .array => |a| if (idx < a.length) a.element else oob.err(self, span, idx, a.length),
        .vector => |v| if (idx < v.length) v.element else oob.err(self, span, idx, v.length),
        .slice => |sl| if (idx == 0) sl.element else oob.err(self, span, idx, 1),
        .optional => |o| if (idx == 0) o.child else oob.err(self, span, idx, 1),
        else => blk: {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "field_type: '{s}' has no indexable fields", .{self.formatTypeName(t)});
            break :blk .unresolved;
        },
    };
}

pub fn resolveTypeCallWithBindings(self: *Lowering, cl: *const ast.Call) TypeId {
    // A namespaced callee (`ns.Box(..)`) is an explicit qualified reach and is
    // exempt from the bare-head visibility gate; only a plain identifier head
    // is policed (E4).
    const is_qualified = cl.callee.data == .field_access;
    const callee_name: []const u8 = switch (cl.callee.data) {
        .identifier => |id| id.name,
        .field_access => |fa| fa.field,
        else => return .unresolved,
    };
    // field_type($T, i) -> Type — comptime reflection (read a type's i-th
    // field / variant-payload / element type). A genuine type-table op, kept as
    // a compiler builtin (like type_name); folds at lower time so it composes
    // inside type_eq / type_name / any type-arg slot.
    if (std.mem.eql(u8, callee_name, "struct_field_type") or std.mem.eql(u8, callee_name, "variant_type")) {
        if (cl.args.len != 2) {
            if (self.diagnostics) |d|
                d.addFmt(.err, cl.callee.span, "{s} takes a type and an index: {s}($T, i)", .{ callee_name, callee_name });
            return .unresolved;
        }
        const t = self.resolveTypeArg(cl.args[0]);
        if (t == .unresolved) return .unresolved;
        const idx: usize = switch (program_index_mod.foldDimU32(cl.args[1], self, 0)) {
            .ok => |n| n,
            else => {
                if (self.diagnostics) |d|
                    d.addFmt(.err, cl.args[1].span, "{s} index must be a non-negative compile-time integer", .{callee_name});
                return .unresolved;
            },
        };
        return self.fieldTypeOf(t, idx, cl.callee.span);
    }
    // pointee($P) -> Type — comptime reflection: the target type of a pointer
    // (`pointee(*X)` -> `X`). Folds at lower time like `field_type` so it
    // composes inside any type-arg slot. A non-pointer arg is a loud error.
    if (std.mem.eql(u8, callee_name, "pointee_type")) {
        if (cl.args.len != 1) {
            if (self.diagnostics) |d|
                d.addFmt(.err, cl.callee.span, "pointee takes one type: pointee($P)", .{});
            return .unresolved;
        }
        const t = self.resolveTypeArg(cl.args[0]);
        if (t == .unresolved) return .unresolved;
        return switch (self.module.types.get(t)) {
            .pointer => |p| p.pointee,
            .many_pointer => |p| p.element,
            else => blk: {
                if (self.diagnostics) |d|
                    d.addFmt(.err, cl.callee.span, "pointee: '{s}' is not a pointer type", .{self.formatTypeName(t)});
                break :blk .unresolved;
            },
        };
    }
    // Built-in: Vector(N, T)
    if (std.mem.eql(u8, callee_name, "Vector") and cl.args.len == 2) {
        const length = self.resolveVectorLane(cl.args[0]) orelse return .unresolved;
        const elem = self.resolveTypeWithBindings(cl.args[1]);
        return self.module.types.vectorOf(elem, length);
    }
    // Generic-struct head: route through the single layout choke-point (CP-1).
    // Bare → the single bare-VISIBLE author (own / 1-hop flat), source-keyed;
    // qualified `ns.Box(..)` → ns's OWN template (or a missing-member diagnostic);
    // never the global last-wins map for a visible-shadowed or qualified head.
    switch (self.selectGenericStructCallee(cl.callee, cl.callee.span)) {
        .template => |t| return self.instantiateGenericStruct(&t, cl.args),
        .poisoned => return .unresolved,
        .not_generic => {},
    }
    // User-defined type-returning function: Complex(u32), Sx(f32). A
    // qualified head selects the exact terminal namespace author; it must
    // never consult the process-global same-name function map.
    if (is_qualified) {
        const path = self.qualifiedTypeName(cl.callee) orelse return .unresolved;
        defer self.alloc.free(path);
        if (self.qualifiedFnMember(path)) |fd| {
            if (fd.type_params.len > 0) {
                if (self.instantiateTypeFunction(callee_name, callee_name, fd, cl.args)) |ty| return ty;
            }
        }
    } else {
        // Also resolve via scope fn_names (local functions get mangled names).
        const resolved_name = if (self.scope) |scope| (scope.lookupFn(callee_name) orelse callee_name) else callee_name;
        if (self.program_index.fn_ast_map.get(resolved_name)) |fd| {
            if (fd.type_params.len > 0) {
                if (self.headFnLeak(callee_name, cl.callee.span)) return .unresolved;
                if (self.instantiateTypeFunction(callee_name, callee_name, fd, cl.args)) |ty| return ty;
            }
        }
    }
    // Try as a named type
    const name_id = self.module.types.internString(callee_name);
    if (self.module.types.findByName(name_id)) |t| return t;
    // The callee names no known type constructor — not Vector, not a generic
    // struct template (or alias), not a type-returning function, not a named
    // type. A silent `.unresolved` here reaches LLVM emission as a panic;
    // diagnose and poison (the parameterized sibling below already does).
    if (self.diagnostics) |d|
        d.addFmt(.err, cl.callee.span, "unknown type '{s}'", .{callee_name});
    return .unresolved;
}

/// Resolve a parameterized type expr, substituting bindings for type/value params.
/// Handles both built-in types (Vector) and user-defined generic structs.
/// `span` locates the reference for the unresolved-base diagnostic.
pub fn resolveParameterizedWithBindings(self: *Lowering, pt: *const ast.ParameterizedTypeExpr, span: ?ast.Span) TypeId {
    const base_name = if (std.mem.lastIndexOfScalar(u8, pt.name, '.')) |dot| pt.name[dot + 1 ..] else pt.name;
    const table = &self.module.types;
    // A namespaced base (`ns.Box(..)`) is an explicit qualified reach and is
    // exempt from the bare-head visibility gate; only a dotless head is
    // policed (E4).
    const is_qualified = std.mem.indexOfScalar(u8, pt.name, '.') != null;

    // A Type-returning reflection builtin spelled in a TYPE position
    // (`x.(struct_field_type(T, i))` — the postfix-cast target parses via
    // parseTypeExpr, so the call arrives as a parameterized type). The
    // `.call` resolver owns these folds — delegate with the same arg nodes.
    if (!pt.is_raw and (std.mem.eql(u8, base_name, "struct_field_type") or
        std.mem.eql(u8, base_name, "variant_type") or
        std.mem.eql(u8, base_name, "pointee_type")))
    {
        const sp = span orelse (if (pt.args.len > 0) pt.args[0].span else return .unresolved);
        const callee_node = ast.Node{ .data = .{ .identifier = .{ .name = base_name } }, .span = sp };
        const syn = ast.Call{ .callee = @constCast(&callee_node), .args = pt.args };
        return self.resolveTypeCallWithBindings(&syn);
    }

    // Vector(N, T) — built-in parameterized type. A backtick raw base
    // (`` `Vector(…) ``) is the LITERAL user type named `Vector`, so it
    // skips this intrinsic and resolves through the template map (0089).
    if (!pt.is_raw and std.mem.eql(u8, base_name, "Vector")) {
        if (pt.args.len == 2) {
            const length = self.resolveVectorLane(pt.args[0]) orelse return .unresolved;
            const elem = self.resolveTypeWithBindings(pt.args[1]);
            return table.vectorOf(elem, length);
        }
    }

    // Generic-struct base: route through the single layout choke-point (CP-1).
    // Bare → the single bare-VISIBLE author (own / 1-hop flat), source-keyed;
    // qualified `ns.Box(..)` → ns's OWN template (or a missing-member diagnostic);
    // never the global last-wins map for a visible-shadowed or qualified head.
    {
        switch (self.selectGenericStructHead(base_name, if (is_qualified) pt.name else null, is_qualified, span)) {
            .template => |t| return self.instantiateGenericStruct(&t, pt.args),
            .poisoned => return .unresolved,
            .not_generic => {},
        }
    }

    // Parameterized protocol used as a value type (`VL(i64)`): materialize a
    // 16-byte protocol value with the type-arg bound (not a 0-field stub).
    if (self.program_index.protocol_ast_map.get(base_name)) |pd| {
        if (pd.type_params.len > 0) {
            if (!is_qualified and self.headTypeLeak(base_name, span)) return .unresolved;
            return self.instantiateParamProtocol(pd, pt.args);
        }
    }

    // User-defined type-returning function used as a TYPE annotation
    // (`b : Make(N, i64)` where `Make :: ($K: u32, $T: Type) -> Type`). The
    // `.call`-node path (`resolveTypeCallWithBindings`) already routes here;
    // a `parameterized_type_expr` must too, or the function name falls through
    // to the empty-struct stub below and `b.field` / `b.len` fails.
    if (is_qualified) {
        if (self.qualifiedFnMember(pt.name)) |fd| {
            if (fd.type_params.len > 0) {
                if (self.instantiateTypeFunction(base_name, base_name, fd, pt.args)) |ty| return ty;
            }
        }
    } else {
        const resolved_name = if (self.scope) |scope| (scope.lookupFn(base_name) orelse base_name) else base_name;
        if (self.program_index.fn_ast_map.get(resolved_name)) |fd| {
            if (fd.type_params.len > 0) {
                if (self.headFnLeak(base_name, span)) return .unresolved;
                if (self.instantiateTypeFunction(base_name, base_name, fd, pt.args)) |ty| return ty;
            }
        }
    }

    // The base names no known type constructor — not Vector, not a generic
    // struct template, not a parameterized protocol, not a type-returning
    // function. A silent 0-field stub here would mis-size every downstream
    // `b.field` / `b.len`; emit the diagnostic and poison with `.unresolved`
    // (the `.call`-node sibling `resolveTypeCallWithBindings` already poisons).
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "unknown type '{s}'", .{base_name});
    return .unresolved;
}

/// Instantiate a generic struct template with concrete args.
/// E.g., Vec(3, f32) → struct Vec__3_f32 { data: Vector(3, f32) }
/// A generic-struct instance method selected via the STAMPED authoring decl:
/// the `fn_decl` to monomorphize, the instance's stored type bindings, and the
/// instance (mangled / alias) name the monomorphized function is keyed under.
pub const GenericStructMethod = struct {
    fd: *const ast.FnDecl,
    bindings: *std.StringHashMap(TypeId),
    inst_name: []const u8,
};

/// The RETURN type of a selected generic-instance method, resolved under the
/// instance's stored bindings in the method's defining module — the plan-side
/// twin of `ensureGenericInstanceMethodLowered`, so call-result typing works
/// BEFORE the method has ever monomorphized (issue 0341: with no plan arm the
/// first use of `inst.method()` in a chain typed `.unresolved` and the chain
/// lowered to a silent zero).
pub fn genericInstanceMethodReturnType(self: *Lowering, gm: GenericStructMethod) TypeId {
    const rt_node = gm.fd.return_type orelse return .void;
    const saved = self.type_bindings;
    self.type_bindings = gm.bindings.*;
    defer self.type_bindings = saved;
    const saved_src = self.current_source_file;
    defer self.setCurrentSourceFile(saved_src);
    if (gm.fd.body.source_file) |src| self.setCurrentSourceFile(src);
    return self.resolveTypeWithBindings(rt_node);
}

/// THE single body-axis reader: select `method` of generic-struct instance
/// `inst_name` via the instance's STAMPED author (`struct_instance_author`),
/// so body-author ≡ layout-author by construction — never the global last-wins
/// `fn_ast_map["Template.method"]` a 2-flat-hop same-name template's method
/// could win. Null when `inst_name` is NOT a generic instance (no author stamp)
/// — the caller's existing non-generic `fn_ast_map` path then handles it
/// (non-generic structs, free fns, FFI), or when the confirmed author declares
/// no such `method` (a normal unresolved-method, handled downstream). A
/// confirmed instance whose author is present but whose bindings are missing is
/// a LOUD invariant failure — instantiation writes both together (CP-2).
pub fn genericInstanceMethod(self: *Lowering, inst_name: []const u8, method: []const u8) ?GenericStructMethod {
    const author = self.struct_instance_author.get(inst_name) orelse return null;
    const bindings = self.struct_instance_bindings.getPtr(inst_name) orelse
        std.debug.panic("generic struct instance '{s}' has an author but no bindings", .{inst_name});
    // INLINE struct method (`Box :: struct { make :: ... }`): selected via the
    // instance's STAMPED author, so the body is the one authored alongside the
    // layout — never the global last-wins `fn_ast_map["Template.method"]` a
    // 2-flat-hop same-name template's method could win (finding #1).
    if (structMethodFn(author, method)) |fd|
        return .{ .fd = fd, .bindings = bindings, .inst_name = inst_name };
    // IMPL-block method (`impl P for Box { ... }`): registered under the
    // template name in `fn_ast_map`, not on the struct decl, so it is keyed by
    // template name (protocol dispatch). The author confirms this IS a generic
    // instance; the method body is the template's registered impl method.
    const tmpl_name = self.struct_instance_template.get(inst_name) orelse return null;
    const tmpl_qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ tmpl_name, method }) catch return null;
    if (self.program_index.fn_ast_map.get(tmpl_qualified)) |fd|
        return .{ .fd = fd, .bindings = bindings, .inst_name = inst_name };
    return null;
}

/// Monomorphize (once) the selected generic-instance method under
/// `<inst_name>.<method>` and return its FuncId. The source-pin follows the
/// selected `fd` for free: `monomorphizeFunction` pins to `fd.body.source_file`,
/// which is the template's defining module (the author's own method node).
/// Null when the function fails to resolve post-monomorphization.
pub fn ensureGenericInstanceMethodLowered(self: *Lowering, m: GenericStructMethod) ?FuncId {
    // A `#set` accessor mangles as `Inst.name$set` so its monomorph never
    // collides with the same-name `#get`'s `Inst.name` (coexistence).
    const mangled = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ m.inst_name, self.accessorEffName(m.fd) }) catch return null;
    if (!self.lowered_functions.contains(mangled)) {
        self.monomorphizeFunction(m.fd, mangled, m.bindings);
    }
    return self.resolveFuncByName(mangled);
}

/// Dispatch a generic-struct-instance method that declares COMPTIME params
/// (`pick :: (self: *Box(T), $o: Ord) -> i64`). The struct already monomorphized
/// for `T` (its bindings live in `m.bindings`), but a comptime value param like
/// `$o` must still bind by INLINING the body the same way a free comptime call
/// does — a plain `call` to a monomorphized FuncId would leave `$o` unresolved.
///
/// Composition: install the struct's type bindings (so `T` / `*Box(T)` resolve
/// in the body), pre-bind the receiver `self` in scope exactly as normal
/// param-lowering does (alloca of the pointer param type, holding the receiver's
/// address), then route the remaining (comptime) params through
/// `lowerComptimeCallArgsSkip` with `skip_params = 1`. That reuses
/// `bindComptimeValueParams` — so `comptimeIntNamed` / `comptimeValueRefNamed`
/// resolve `$o` inside the body, identically to the free-function path.
pub fn lowerComptimeGenericInstanceMethod(
    self: *Lowering,
    m: GenericStructMethod,
    recv_node: *const Node,
    call_args: []const *Node,
    call_span: ast.Span,
) Ref {
    const fd = m.fd;
    var effective_args = std.ArrayList(*Node).empty;
    defer effective_args.deinit(self.alloc);
    effective_args.append(self.alloc, @constCast(recv_node)) catch unreachable;
    effective_args.appendSlice(self.alloc, call_args) catch unreachable;

    // Compose the generic struct's stored bindings with any type parameters
    // declared by the method itself. The latter intentionally win on a same-
    // name shadow. One combined map drives both signature resolution and body
    // lowering, so `T` and a method-local `$R` cannot observe different calls.
    var combined = std.StringHashMap(TypeId).init(self.alloc);
    defer combined.deinit();
    var struct_it = m.bindings.iterator();
    while (struct_it.next()) |entry|
        combined.put(entry.key_ptr.*, entry.value_ptr.*) catch unreachable;
    if (fd.type_params.len > 0) {
        var method_bindings = self.genericResolver().buildTypeBindings(fd, effective_args.items);
        defer method_bindings.deinit();
        var method_it = method_bindings.iterator();
        while (method_it.next()) |entry|
            combined.put(entry.key_ptr.*, entry.value_ptr.*) catch unreachable;

        for (fd.type_params) |tp| {
            if (tp.is_variadic or tp.constraint.data != .type_expr) continue;
            const constraint = tp.constraint.data.type_expr.name;
            const needs_type = std.mem.eql(u8, constraint, "Type") or
                self.isProtocolConstraint(constraint, fd.body.source_file);
            if (!needs_type or combined.contains(tp.name)) continue;
            if (self.diagnostics) |d|
                d.addFmt(.err, call_span, "cannot infer generic type parameter '{s}' for comptime method '{s}' from this call's arguments", .{ tp.name, fd.name });
            return Ref.none;
        }
    }

    const saved_bindings = self.type_bindings;
    self.type_bindings = combined;
    defer self.type_bindings = saved_bindings;
    return self.lowerComptimeMethodCallArgs(fd, effective_args.items, true, call_span);
}

/// Debug invariant (CP coverage lock): the two generic-instance maps written
/// in lockstep at the SAME two writers (instantiation + alias copy) —
/// `struct_instance_template` and `struct_instance_author` — must have
/// coincident keysets. A future writer that registers an instance's layout
/// without stamping its author (a silent body-axis reopen) trips this in a
/// debug `zig build test`, not in production.
pub fn assertInstanceMapsCoincide(self: *Lowering) void {
    if (!std.debug.runtime_safety) return;
    var it = self.struct_instance_template.keyIterator();
    while (it.next()) |k| {
        if (!self.struct_instance_author.contains(k.*))
            std.debug.panic("generic instance '{s}' has a template but no author stamp", .{k.*});
    }
    var it2 = self.struct_instance_author.keyIterator();
    while (it2.next()) |k| {
        if (!self.struct_instance_template.contains(k.*))
            std.debug.panic("generic instance '{s}' has an author but no template stamp", .{k.*});
    }
}

pub fn instantiateGenericStruct(self: *Lowering, tmpl: *const StructTemplate, args: []const *const Node) TypeId {
    const table = &self.module.types;

    // Build mangled name dynamically: StructName__arg1_arg2
    var name_parts = std.ArrayList(u8).empty;
    name_parts.appendSlice(self.alloc, tmpl.name) catch {};

    // A qualified `ns.Box(..)` head can select a generic template whose bare
    // name also belongs to a DIFFERENT module's same-name template (the one
    // that won the last-wins `struct_template_map`). Both would mangle to
    // `Box__i64` and the second instantiation would alias the first's layout.
    // Tag the NON-canonical author's mangled name with its source so each
    // author's instantiation is a distinct type. The canonical (bare-map)
    // author keeps the untagged name — no churn for single-author generics.
    if (self.program_index.struct_template_map.get(tmpl.name)) |canon| {
        const canon_src = canon.source_file orelse "";
        const this_src = tmpl.source_file orelse "";
        if (!std.mem.eql(u8, canon_src, this_src)) {
            var tag_buf: [24]u8 = undefined;
            const tag = std.fmt.bufPrint(&tag_buf, "$m{x}", .{std.hash.Wyhash.hash(0, this_src)}) catch "";
            name_parts.appendSlice(self.alloc, tag) catch {};
        }
    }

    // Bind type params to args and build name suffix
    const saved_type_bindings = self.type_bindings;
    const saved_value_bindings = self.comptime_value_bindings;
    const saved_pack_bindings = self.pack_bindings;
    const saved_pack_arg_types = self.pack_arg_types;
    var tb = std.StringHashMap(TypeId).init(self.alloc);
    var cvb = std.StringHashMap(i64).init(self.alloc);
    var pb = std.StringHashMap([]const TypeId).init(self.alloc);

    for (tmpl.type_params, 0..) |tp, i| {
        if (i >= args.len) break;

        // `..$Ts: []Type` — bind the REMAINING args as a type pack.
        if (tp.is_variadic) {
            var pack_tys = std.ArrayList(TypeId).empty;
            for (args[i..]) |a| {
                // A spread arg `..sources.T` expands to the source pack's
                // per-element (projected) types; a plain arg is one type.
                if (a.data == .spread_expr) {
                    if (self.packResolver().packTypeElems(a.data.spread_expr.operand)) |elems| {
                        defer self.alloc.free(elems);
                        for (elems) |ty| {
                            pack_tys.append(self.alloc, ty) catch {};
                            name_parts.appendSlice(self.alloc, "__") catch {};
                            name_parts.appendSlice(self.alloc, self.formatTypeName(ty)) catch {};
                        }
                        continue;
                    }
                }
                // Multi-return signature is return-only, not a type-pack arg.
                if (self.rejectMultiReturnValueType(a, "generic type argument")) return .unresolved;
                const ty = self.resolveTypeWithBindings(a);
                pack_tys.append(self.alloc, ty) catch {};
                name_parts.appendSlice(self.alloc, "__") catch {};
                name_parts.appendSlice(self.alloc, self.formatTypeName(ty)) catch {};
            }
            pb.put(tp.name, pack_tys.toOwnedSlice(self.alloc) catch &.{}) catch {};
            break; // a pack param is always last
        }

        name_parts.appendSlice(self.alloc, "__") catch {};

        if (tp.is_type_param) {
            // A bare-paren `(A, B)` multi-return signature is return-position-only,
            // never a generic type argument (`List((A,B))` — use `Tuple(…)`).
            if (self.rejectMultiReturnValueType(args[i], "generic type argument")) return .unresolved;
            const ty = self.resolveTypeWithBindings(args[i]);
            tb.put(tp.name, ty) catch {};
            const tname = self.formatTypeName(ty);
            name_parts.appendSlice(self.alloc, tname) catch {};
        } else {
            // Value param (e.g., $N: u32) — fold to a compile-time integer
            // and range-check against its declared type.
            const val = self.resolveValueParamArg(args[i], tp.name, tp.value_type) orelse return .unresolved;
            cvb.put(tp.name, val) catch {};
            var val_buf: [32]u8 = undefined;
            const val_str = std.fmt.bufPrint(&val_buf, "{d}", .{val}) catch "0";
            name_parts.appendSlice(self.alloc, val_str) catch {};
        }
    }

    const mangled_name = name_parts.items;

    // Check if already instantiated
    const name_id = table.internString(mangled_name);
    if (table.findByName(name_id)) |existing| {
        // Already registered — check if it has fields
        const info = table.get(existing);
        if (info == .@"struct" and info.@"struct".fields.len > 0) {
            // A confirmed generic instance must never be returned without an
            // author stamp — the body axis (CP-4) keys method selection off
            // it. The template/bindings were written at first instantiation;
            // re-stamp the author from THIS `tmpl` if the dedup fast-path is
            // the first to reach this mangled name (e.g. a layout interned by
            // a forward reference before any method dispatch).
            if (!self.struct_instance_author.contains(mangled_name)) {
                const owned = self.alloc.dupe(u8, mangled_name) catch return existing;
                self.struct_instance_author.put(owned, tmpl.decl) catch {};
            }
            return existing;
        }
    }

    // Set up bindings and resolve fields. `pack_bindings` makes a
    // pack-shaped field type like `(..$Ts)` resolve to the bound type list.
    self.type_bindings = tb;
    self.comptime_value_bindings = cvb;
    self.pack_bindings = pb;
    self.pack_arg_types = pb;

    // Resolve the field type nodes in the TEMPLATE's source context, not the
    // (possibly cross-module) instantiation site. A field naming a type
    // visible only in the template's module then resolves correctly, and the
    // source-aware nominal leaf classifies main vs imported by the TEMPLATE's
    // file — so an undeclared field type (`y: Missing`) or a value param used
    // as a type (`x: N` for `$N: u32`) is diagnosed at the right authority
    // (the leaf for an imported template, the `UnknownTypeChecker` for a
    // main-file one) instead of silently fabricating a stub / poisoning with
    // `.unresolved` that panics at LLVM emission.
    const saved_src = self.current_source_file;
    const saved_diag_src = if (self.diagnostics) |d| d.current_source_file else null;
    if (tmpl.source_file) |sf| {
        self.current_source_file = sf;
        if (self.diagnostics) |d| d.current_source_file = sf;
    }

    var fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
    var instance_defaults = std.ArrayList(?*Node).empty;
    var field_idx: usize = 0;
    var using_idx: usize = 0;
    while (field_idx < tmpl.field_names.len or using_idx < tmpl.decl.using_entries.len) {
        while (using_idx < tmpl.decl.using_entries.len and tmpl.decl.using_entries[using_idx].insert_index == field_idx) {
            const ue = tmpl.decl.using_entries[using_idx];
            // current_source_file is the TEMPLATE's file here (set above), so
            // the base selects from the declaring module's authority, not the
            // global name table (issue 0320).
            if (self.resolveUsingBase(ue.type_name, self.current_source_file, tmpl.name)) |used_ty| {
                const used_info = table.get(used_ty);
                if (used_info == .@"struct") for (used_info.@"struct".fields) |f| {
                    fields.append(self.alloc, f) catch unreachable;
                    instance_defaults.append(self.alloc, null) catch unreachable;
                };
            }
            using_idx += 1;
        }
        if (field_idx >= tmpl.field_names.len) break;
        const field_ty = self.resolveTypeWithBindings(tmpl.field_type_nodes[field_idx]);
        fields.append(self.alloc, .{
            .name = table.internString(tmpl.field_names[field_idx]),
            .ty = field_ty,
        }) catch unreachable;
        instance_defaults.append(self.alloc, if (field_idx < tmpl.decl.field_defaults.len) tmpl.decl.field_defaults[field_idx] else null) catch unreachable;
        field_idx += 1;
    }
    while (using_idx < tmpl.decl.using_entries.len) : (using_idx += 1) {
        const ue = tmpl.decl.using_entries[using_idx];
        if (self.resolveUsingBase(ue.type_name, self.current_source_file, tmpl.name)) |used_ty| {
            const used_info = table.get(used_ty);
            if (used_info == .@"struct") for (used_info.@"struct".fields) |f| {
                fields.append(self.alloc, f) catch unreachable;
                instance_defaults.append(self.alloc, null) catch unreachable;
            };
        }
    }

    self.current_source_file = saved_src;
    if (self.diagnostics) |d| d.current_source_file = saved_diag_src;

    // Restore bindings
    self.type_bindings = saved_type_bindings;
    self.comptime_value_bindings = saved_value_bindings;
    self.pack_bindings = saved_pack_bindings;
    self.pack_arg_types = saved_pack_arg_types;

    // Register the monomorphized struct
    const info: types.TypeInfo = .{ .@"struct" = .{ .name = name_id, .fields = fields.items } };
    const id = if (table.findByName(name_id)) |existing| existing else table.intern(info);
    table.updatePreservingKey(id, info);

    // Bind the template name to this concrete instance so a method's
    // `self: *Combined` (the template name) resolves to `*Combined__i64_i64`
    // — otherwise `self.field` hits the 0-field generic stub.
    tb.put(tmpl.name, id) catch {};

    // Store the type bindings, template name, and authoring decl for method
    // resolution. The author is stamped from the SAME `tmpl` that built the
    // layout above, so the body axis (CP-4) selects this instance's methods
    // via the layout author — never the global last-wins `fn_ast_map`.
    const owned_mangled = self.alloc.dupe(u8, mangled_name) catch return id;
    self.struct_instance_bindings.put(owned_mangled, tb) catch {};
    self.struct_instance_template.put(owned_mangled, tmpl.name) catch {};
    self.struct_instance_author.put(owned_mangled, tmpl.decl) catch {};

    // Carry the template's field-default expressions onto the MONOMORPHIZED
    // instance so struct-literal lowering finds them (issue 0221). The literal
    // path (`lower/expr.zig`) keys `struct_defaults_map` off the instance's
    // struct name (`name_id` == `mangled_name`); a generic instance's mangled
    // name never matched the template's plain name, so declared defaults were
    // silently zero-filled instead of applied (as they are for non-generic
    // structs). The default nodes are index-aligned with `field_names` — both
    // are copied straight from `tmpl.decl` in declaration order — so the raw
    // AST slice maps 1:1 onto this instance's fields. Defaults that reference a
    // type param (e.g. `size_of(T)`) are monomorphized at the literal site
    // by re-installing THIS instance's `type_bindings` from
    // `struct_instance_bindings` (see `lower/expr.zig`, the generic-instance
    // default path).
    if (instance_defaults.items.len > 0) {
        var has_any_default = false;
        for (instance_defaults.items) |d| {
            if (d != null) {
                has_any_default = true;
                break;
            }
        }
        if (has_any_default) {
            self.struct_defaults_map.put(owned_mangled, instance_defaults.toOwnedSlice(self.alloc) catch &.{}) catch {};
        }
    }

    return id;
}

/// Instantiate a type-returning function: `Foo :: Complex(u32)` where
/// `Complex :: ($T:Type) -> Type { return struct { value: T; count: u32; }; }`
/// Walks the function body to find the returned struct/enum, resolves field types
/// with the provided type bindings, and registers the result.
pub fn instantiateTypeFunction(self: *Lowering, alias_name: []const u8, template_name: []const u8, fd: *const ast.FnDecl, args: []const *const Node) ?TypeId {
    const table = &self.module.types;

    // Build type bindings from params + args
    const saved_type_bindings = self.type_bindings;
    const saved_value_bindings = self.comptime_value_bindings;
    var tb = std.StringHashMap(TypeId).init(self.alloc);
    var cvb = std.StringHashMap(i64).init(self.alloc);

    // Build mangled name
    var name_parts = std.ArrayList(u8).empty;
    name_parts.appendSlice(self.alloc, template_name) catch {};

    // Two namespace targets may author the same type-function spelling and
    // receive the same type arguments. The exact `fd` selection above is not
    // enough if both cache as `Make__i64`: the second lookup would return the
    // first author's materialized type before reading its own body. Mirror the
    // generic-struct identity rule by source-tagging a non-canonical author;
    // the canonical/single-author spelling remains byte-for-byte unchanged.
    if (self.program_index.fn_ast_map.get(template_name)) |canonical| {
        if (canonical != fd) {
            const canonical_src = canonical.body.source_file orelse "";
            const this_src = fd.body.source_file orelse self.current_source_file orelse self.main_file orelse "";
            if (!std.mem.eql(u8, canonical_src, this_src)) {
                var tag_buf: [24]u8 = undefined;
                const tag = std.fmt.bufPrint(&tag_buf, "$m{x}", .{std.hash.Wyhash.hash(0, this_src)}) catch "";
                name_parts.appendSlice(self.alloc, tag) catch {};
            }
        }
    }

    for (fd.type_params, 0..) |tp, i| {
        if (i >= args.len) break;
        name_parts.appendSlice(self.alloc, "__") catch {};

        // Check if this is a Type param ($T: Type) or a value param ($N: u32)
        const is_type_param = if (tp.constraint.data == .type_expr)
            std.mem.eql(u8, tp.constraint.data.type_expr.name, "Type")
        else
            true; // default to type param

        if (is_type_param) {
            const ty = self.resolveTypeWithBindings(args[i]);
            tb.put(tp.name, ty) catch {};
            const tname = self.formatTypeName(ty);
            name_parts.appendSlice(self.alloc, tname) catch {};
        } else {
            // Value param (e.g., $N: u32) — fold to a compile-time integer
            // and range-check against its declared type. A failed bind has
            // already diagnosed itself, so poison to `.unresolved` rather
            // than `null`: `null` makes the caller fall through to the
            // empty-struct placeholder named after the fn, which then
            // cascades a bogus `field not found` on any later access. The
            // struct binder (`instantiateGenericStruct`) poisons the same way.
            const vp_type: ?[]const u8 = if (tp.constraint.data == .type_expr) tp.constraint.data.type_expr.name else null;
            const val = self.resolveValueParamArg(args[i], tp.name, vp_type) orelse return .unresolved;
            cvb.put(tp.name, val) catch {};
            var val_buf: [32]u8 = undefined;
            const val_str = std.fmt.bufPrint(&val_buf, "{d}", .{val}) catch "0";
            name_parts.appendSlice(self.alloc, val_str) catch {};
        }
    }

    const mangled_name = name_parts.items;

    // Check if already instantiated
    const mangled_name_id = table.internString(mangled_name);
    if (table.findByName(mangled_name_id)) |existing| {
        const info = table.get(existing);
        if ((info == .@"struct" and info.@"struct".fields.len > 0) or info == .@"union" or info == .tagged_union) {
            return existing;
        }
    }

    // Activate bindings
    self.type_bindings = tb;
    self.comptime_value_bindings = cvb;
    defer {
        self.type_bindings = saved_type_bindings;
        self.comptime_value_bindings = saved_value_bindings;
    }

    // Resolve the type fn's body (inline struct/union fields, or the returned
    // type expression) in its OWN module (E4), so a 2-flat-hop library type
    // named there is bare-visible — not the cross-module call site. The arg
    // exprs above were already resolved in the caller's context.
    const saved_tf_src = self.current_source_file;
    defer self.setCurrentSourceFile(saved_tf_src);
    if (fd.body.source_file) |src| self.setCurrentSourceFile(src);

    // Determine if alias_name is a real alias (e.g., "Foo" for "Complex(u32)")
    // or just the template name itself (inline use like "Sx(f32)")
    const has_alias = !std.mem.eql(u8, alias_name, template_name);

    // Try struct first
    if (findStructInBody(fd.body)) |struct_decl| {
        // Resolve struct fields with type bindings active
        var struct_fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
        for (struct_decl.field_names, struct_decl.field_types) |fname, ftype_node| {
            const field_ty = self.resolveTypeWithBindings(ftype_node);
            struct_fields.append(self.alloc, .{
                .name = table.internString(fname),
                .ty = field_ty,
            }) catch {};
        }

        // Always register under mangled name
        const mangled_info: types.TypeInfo = .{ .@"struct" = .{
            .name = mangled_name_id,
            .fields = struct_fields.items,
        } };
        const mangled_id = if (table.findByName(mangled_name_id)) |existing| existing else table.intern(mangled_info);
        table.updatePreservingKey(mangled_id, mangled_info);

        // If there's a real alias, also register under alias name and in alias map
        if (has_alias) {
            const alias_name_id = table.internString(alias_name);
            const alias_info: types.TypeInfo = .{ .@"struct" = .{
                .name = alias_name_id,
                .fields = struct_fields.items,
            } };
            const alias_id = if (table.findByName(alias_name_id)) |existing| existing else table.intern(alias_info);
            table.updatePreservingKey(alias_id, alias_info);

            // Store defaults if any
            if (struct_decl.field_defaults.len > 0) {
                self.struct_defaults_map.put(alias_name, struct_decl.field_defaults) catch {};
            }

            return alias_id;
        }

        return mangled_id;
    }

    // Try tagged enum/union
    if (findUnionInBody(fd.body)) |enum_decl| {
        return self.instantiateTypeUnion(if (has_alias) alias_name else mangled_name, mangled_name, &enum_decl);
    }

    // A type-fn body that returns a COMPUTED Type — a call to a non-generic,
    // bodied, Type-returning fn (a comptime type constructor). Comptime-evaluate
    // the return expression with the type bindings active (so a payload `= T`
    // resolves to the bound arg) and mint under THIS instantiation's name. The
    // rename to the mangled name lets the cache check at the top return the
    // SAME TypeId on a second instantiation — `Foo(i64)` at two sites is ONE
    // type (nominal identity). Must precede the general static case below, whose
    // `resolveTypeWithBindings` can't evaluate a Type-returning call.
    if (findReturnTypeExpr(fd.body)) |ret_node| {
        if (self.returnExprMintsType(ret_node)) {
            // A body with LOCALS before its `return` (e.g. `vs := …; return
            // make_enum(…, vs)`) needs its full body comptime-evaluated so those
            // locals resolve; the bare return-expr path leaves them unresolved.
            // A no-prelude body stays on the simpler `evalComptimeType` path.
            const has_prelude = fd.body.data == .block and blk: {
                for (fd.body.data.block.stmts) |stmt| {
                    if (stmt.data == .return_stmt) break :blk false;
                    break :blk true; // a non-return statement precedes the return
                }
                break :blk false;
            };
            const tid = (if (has_prelude)
                self.evalComptimeTypeBody(fd.body, ret_node)
            else
                self.evalComptimeType(ret_node)) orelse return .unresolved;
            // Re-key to the instantiation's mangled (or alias) name so the
            // cache check at the top dedups a second instantiation — Contract 1.
            self.renameNominalType(tid, if (has_alias) alias_name else mangled_name);
            return tid;
        }
    }

    // General case: the body returns a TYPE EXPRESSION that is not an inline
    // struct/union/enum — `return [K]T`, `Vector(K, T)`, `*T`, an alias, etc.
    // Resolve it with the value/type bindings active (so `[K]T` folds K to a
    // compile-time integer). The result is interned structurally, so
    // `Make(N, i64)`, `Make(3, i64)`, and `Make(M + 1, i64)` all yield the
    // same TypeId. `.unresolved` means the return wasn't a type expression
    // (e.g. a value-returning function in a type position) → fall through to
    // the caller's fallback rather than fabricating a type.
    if (findReturnTypeExpr(fd.body)) |ret_node| {
        const ty = self.resolveTypeWithBindings(ret_node);
        if (ty != .unresolved) return ty;
    }

    return null;
}

/// The type expression a type-returning function yields: the value of its
/// `return` (block body) or the bare expression (arrow body / `=> [K]T`).
/// Used for a non-struct/union return shape, which the struct/union body
/// walkers above don't match.
pub fn findReturnTypeExpr(body: *const Node) ?*const Node {
    if (body.data == .block) {
        for (body.data.block.stmts) |stmt| {
            if (stmt.data == .return_stmt) return stmt.data.return_stmt.value;
        }
        return null;
    }
    return body;
}

/// True when a type-fn's return expression mints a type at comptime and must be
/// run through the interpreter rather than statically resolved. Two shapes:
///   - a call to the metatype `define` constructor — `return define(declare(),
///     info)`, the one-shot constructor form (now an sx fn over `register_type`,
///     caught here as a fast-path before the `fn_ast_map` lookup below); or
///   - a call to a NON-generic, bodied, `Type`-returning sx fn (a constructor
///     helper that itself ends in `define` / `register_type`).
/// Excludes generic / static type constructors (`Vector(N,T)`, `Make($T)`,
/// `return [K]T`, `return T`), which the static `resolveTypeWithBindings` path
/// handles.
pub fn returnExprMintsType(self: *Lowering, ret: *const Node) bool {
    if (ret.data != .call) return false;
    const callee = ret.data.call.callee;
    if (callee.data != .identifier) return false;
    const name = callee.data.identifier.name;
    // The construction terminator — a constructor's final act.
    if (std.mem.eql(u8, name, "define")) return true;
    // A bodied, non-generic, Type-returning sx helper.
    const fd = self.program_index.fn_ast_map.get(name) orelse return false;
    if (fd.type_params.len != 0) return false;
    if (fd.body.data == .block and fd.body.data.block.stmts.len == 0) return false; // bodyless intrinsic
    const rt = fd.return_type orelse return false;
    return rt.data == .type_expr and std.mem.eql(u8, rt.data.type_expr.name, "Type");
}

/// Instantiate a tagged enum from a type function body.
pub fn instantiateTypeUnion(self: *Lowering, alias_name: []const u8, mangled_name: []const u8, ed: *const ast.EnumDecl) ?TypeId {
    const table = &self.module.types;

    // Build variant fields (tagged enum variants stored as StructInfo.Field)
    var variant_fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
    for (ed.variant_names, 0..) |vname, i| {
        const payload_ty: TypeId = if (i < ed.variant_types.len and ed.variant_types[i] != null)
            self.resolveTypeWithBindings(ed.variant_types[i].?)
        else
            .void;
        variant_fields.append(self.alloc, .{
            .name = table.internString(vname),
            .ty = payload_ty,
        }) catch {};
    }

    const alias_name_id = table.internString(alias_name);
    const info: types.TypeInfo = .{ .tagged_union = .{
        .name = alias_name_id,
        .fields = variant_fields.items,
        .tag_type = .i64,
    } };
    const id = if (table.findByName(alias_name_id)) |existing| existing else table.intern(info);
    table.updatePreservingKey(id, info);

    // Also register under mangled name
    if (!std.mem.eql(u8, alias_name, mangled_name)) {
        const mangled_name_id = table.internString(mangled_name);
        const mangled_info: types.TypeInfo = .{ .tagged_union = .{
            .name = mangled_name_id,
            .fields = variant_fields.items,
            .tag_type = .i64,
        } };
        const mid = if (table.findByName(mangled_name_id)) |existing| existing else table.intern(mangled_info);
        table.updatePreservingKey(mid, mangled_info);
    }

    return id;
}

/// Walk an AST body to find a struct declaration (from `return struct { ... }` or bare struct expr).
pub fn findStructInBody(body: *const Node) ?ast.StructDecl {
    if (body.data == .struct_decl) return body.data.struct_decl;
    if (body.data == .block) {
        for (body.data.block.stmts) |stmt| {
            if (stmt.data == .return_stmt) {
                if (stmt.data.return_stmt.value) |val| {
                    if (val.data == .struct_decl) return val.data.struct_decl;
                }
            }
            if (stmt.data == .struct_decl) return stmt.data.struct_decl;
        }
    }
    return null;
}

/// Walk an AST body to find a tagged enum declaration.
pub fn findUnionInBody(body: *const Node) ?ast.EnumDecl {
    const isTaggedEnum = struct {
        fn check(node: *const Node) ?ast.EnumDecl {
            if (node.data == .enum_decl and node.data.enum_decl.variant_types.len > 0) {
                return node.data.enum_decl;
            }
            return null;
        }
    };
    if (isTaggedEnum.check(body)) |ed| return ed;
    const stmts = if (body.data == .block) body.data.block.stmts else return null;
    for (stmts) |stmt| {
        if (stmt.data == .return_stmt) {
            if (stmt.data.return_stmt.value) |val| {
                if (isTaggedEnum.check(val)) |ed| return ed;
            }
        }
        if (isTaggedEnum.check(stmt)) |ed| return ed;
    }
    return null;
}
