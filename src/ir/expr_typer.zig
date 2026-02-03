const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");
const program_index_mod = @import("program_index.zig");
const lower = @import("lower.zig");

const Node = ast.Node;
const TypeId = types.TypeId;
const Lowering = lower.Lowering;
const TypeResolver = @import("type_resolver.zig").TypeResolver;

/// AST-level expression typing (architecture phase A3.1), extracted from
/// `Lowering.inferExprType`. Owns the structural / non-call expression shapes —
/// literals, unary / binary ops, `try` / `catch`, `if`, block, field access,
/// identifier / type-name, struct / tuple literals, index / slice / deref,
/// null-coalesce, and the statement shapes that produce no value. Call result
/// typing is owned by `CallResolver` (`calls.zig`); a call node reaching here is
/// routed to it via `Lowering.inferExprType`.
///
/// A `*Lowering` facade (Principle 5), like `PackResolver`: expression typing
/// reads live lexical-scope / pack / target-type state and dozens of resolver
/// helpers, so it borrows `Lowering` rather than re-threading every field. The
/// dependency shrinks as later phases lift that state into an explicit context
/// (the plan's `TypeResolver` / `ProgramIndex` / `ResolveEnv` target).
pub const ExprTyper = struct {
    l: *Lowering,

    /// Infer the IR type an expression evaluates to (without lowering it).
    /// Recurses through `Lowering.inferExprType` so a nested call node is typed
    /// by its one owner.
    pub fn inferType(self: ExprTyper, node: *const Node) TypeId {
        return switch (node.data) {
            // Call result typing is owned by `CallResolver` (`calls.zig`);
            // delegate through `Lowering.inferExprType` so a call node reaching
            // here is typed by that single owner, not mistyped as `.unresolved`.
            .call => self.l.inferExprType(node),
            .string_literal => .string,
            .int_literal => .i64,
            .float_literal => .f64,
            .bool_literal => .bool,
            .char_literal => .i64,
            .null_literal => .void,
            .binary_op => |bop| switch (bop.op) {
                .or_op => blk: {
                    // A failable `or` (value-terminator or chain) yields the
                    // chain's success type (the error is absorbed/propagated);
                    // a non-failable `or` is boolean / optional-unwrap → bool.
                    // Detected structurally — a `try`-chain's operands type as
                    // non-failable `T`, so a type-only check would miss it.
                    if (self.l.orIsFailableChain(&bop)) break :blk self.l.orChainSuccessType(&bop);
                    break :blk .bool;
                },
                .eq, .neq, .lt, .lte, .gt, .gte => blk: {
                    const lhs_ty = self.l.inferExprType(bop.lhs);
                    if (!lhs_ty.isBuiltin()) {
                        const info = self.l.module.types.get(lhs_ty);
                        if (info == .vector) {
                            break :blk self.l.module.types.vectorOf(.bool, info.vector.length);
                        }
                    }
                    break :blk .bool;
                },
                .and_op, .in_op => .bool,
                // Arithmetic / bitwise / shift ops: infer the PROMOTED result
                // of (lhs, rhs), not the LHS alone — `Lowering.arithResultType`
                // is the same rule `lowerBinaryOp` applies, so `M + 0.5` types
                // as `f64` regardless of operand order (was LHS-biased: `M + 0.5`
                // → i64 while `0.5 + M` → f64).
                else => Lowering.arithResultType(self.l.inferExprType(bop.lhs), self.l.inferExprType(bop.rhs)),
            },
            .unary_op => |uop| switch (uop.op) {
                .not => .bool,
                .negate => self.l.inferExprType(uop.operand),
                .xx => self.l.target_type orelse .unresolved,
                .address_of => blk: {
                    const inner = self.l.inferExprType(uop.operand);
                    break :blk self.l.module.types.ptrTo(inner);
                },
                else => .unresolved,
            },
            // `try X` evaluates to X's success type (the value part). A
            // pure-failable operand (`-> !` / `-> !Named`, whose type IS the
            // error set) has no value → `void`; a value-carrying `-> (T..., !)`
            // operand yields its value part (the lone value, or a value-tuple).
            .try_expr => |te| blk: {
                const op_ty = self.l.inferExprType(te.operand);
                const channel = self.l.errorChannelOf(op_ty) orelse break :blk .unresolved;
                if (op_ty == channel) break :blk .void;
                break :blk self.l.failableSuccessType(op_ty);
            },
            // `expr catch ...` strips the error channel → the success type
            // (void for a pure-failable LHS; the value part for value-carrying).
            .catch_expr => |ce| blk: {
                const op_ty = self.l.inferExprType(ce.operand);
                const channel = self.l.errorChannelOf(op_ty) orelse break :blk .unresolved;
                if (op_ty == channel) break :blk .void;
                break :blk self.l.failableSuccessType(op_ty);
            },
            // `opt!` force-unwraps an optional to its child type. Without this
            // arm a chained `opt!.field` / `opt![i]` / `opt!.method()` would
            // type its receiver as `.unresolved` (the `else` below) and fail to
            // resolve — even though `lowerForceUnwrap` produces a correctly
            // typed value. Mirrors lowerForceUnwrap's resolveOptionalInner.
            .force_unwrap => |fu| blk: {
                const opt_ty = self.l.inferExprType(fu.operand);
                if (!opt_ty.isBuiltin()) {
                    const info = self.l.module.types.get(opt_ty);
                    if (info == .optional) break :blk info.optional.child;
                }
                break :blk .unresolved;
            },
            .caller_location => self.l.module.types.findByName(self.l.module.types.internString("Source_Location")) orelse .unresolved,
            .if_expr => |ie| {
                // If-else types as its branches' unified type. A `noreturn`
                // branch (one that diverges — `return` / `raise` / `break` /
                // `continue`) unifies away, so the expression takes the other
                // branch's type; both diverging → `noreturn` (ERR E1.4c).
                if (ie.else_branch) |eb| {
                    const then_ty = self.l.inferExprType(ie.then_branch);
                    if (then_ty == .noreturn) return self.l.inferExprType(eb);
                    const else_ty = self.l.inferExprType(eb);
                    if (else_ty == .noreturn) return then_ty;
                    return self.l.unifyValueArmTypes(then_ty, else_ty) orelse then_ty;
                }
                return .void;
            },
            .match_expr => |me| self.l.inferMatchResultType(&me),
            // Divergence shapes type as `noreturn` — they transfer control and
            // produce no value at their site. A block whose last statement is
            // one of these propagates `noreturn` (block arm below), which lets
            // a `catch` body that ends in `return` / `raise` unify with the
            // success type (ERR E1.4c / E1.5).
            .return_stmt, .raise_stmt, .break_expr, .continue_expr => .noreturn,
            .block => |blk| {
                // A block's type is its last expression's type only when it
                // produces a value (no trailing `;`); otherwise it is void.
                if (blk.produces_value and blk.stmts.len > 0) {
                    return self.l.inferExprType(blk.stmts[blk.stmts.len - 1]);
                }
                return .void;
            },
            .field_access => |fa| {
                // Pack-arity intercept: `<pack_name>.len` is i64. Mirrors
                // the lowerFieldAccess intercept so AST-level type
                // inference picks the same shape.
                if (self.l.pack_param_count) |ppc| {
                    if (fa.object.data == .identifier and std.mem.eql(u8, fa.field, "len")) {
                        if (ppc.contains(fa.object.data.identifier.name)) return .i64;
                    }
                }
                // Struct constant access: `Struct.CONST` — mirrors the
                // lowerFieldAccess intercept (line 3851). Without this,
                // `Phys.GRAVITY` (f64) inferred as i64 and pack-fn
                // callers boxed the float into the int slot.
                if (fa.object.data == .identifier) {
                    const obj_name = fa.object.data.identifier.name;
                    const qualified = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ obj_name, fa.field }) catch fa.field;
                    if (self.l.struct_const_map.get(qualified)) |info| {
                        if (info.ty) |t| return t;
                    }
                }
                // Numeric-limit accessor: `<Type>.min`/`.max` (int or float) or a
                // float-only `.epsilon`/`.min_positive`/`.true_min`/`.inf`/`.nan`
                // is a comptime const of the queried type — mirrors the
                // lowerFieldAccess intercept so inference reports the same type
                // (without it the const would be mistyped, e.g. boxed into an Any
                // slot). Only valid folds carry a type here; the cross-type error
                // cases fall through (lowerNumericLimit emits the diagnostic).
                {
                    const type_name: ?[]const u8 = switch (fa.object.data) {
                        .identifier => |id| id.name,
                        .type_expr => |te| te.name,
                        else => null,
                    };
                    if (type_name) |tn| {
                        // Skip the fold when a raw value binding shadows the
                        // builtin type name (`` `f64 := … ``) — mirrors the
                        // lowerNumericLimit guard so inference matches
                        // lowering. The shared helper consults all
                        // three value sources (scope / globals / module consts);
                        // a `.type_expr` receiver is never shadowed.
                        const shadowed = fa.object.data == .identifier and
                            self.l.identifierBindsValue(tn);
                        if (!shadowed and
                            (TypeResolver.integerLimitFor(tn, fa.field) != null or
                                TypeResolver.floatLimitFor(tn, fa.field) != null))
                        {
                            if (TypeResolver.resolveBuiltinName(tn, &self.l.module.types)) |t| return t;
                        }
                    }
                }
                // M1.3 — `obj.class` on an Obj-C-class pointer returns Class (*void).
                if (std.mem.eql(u8, fa.field, "class")) {
                    if (self.l.objc().isObjcClassPointer(self.l.inferExprType(fa.object))) {
                        return self.l.module.types.ptrTo(.void);
                    }
                }
                // M2.2 — `obj.field` for an Obj-C `#property` field returns the field's type.
                if (self.l.lookupObjcPropertyOnPointer(fa.object, fa.field)) |prop| {
                    return self.l.resolveType(prop.field_type);
                }
                // M1.2 A.3 — sx-defined class state field returns the field's type.
                if (self.l.lookupObjcDefinedStateFieldOnPointer(fa.object, fa.field)) |info| {
                    return info.field_ty;
                }

                var obj_ty = self.l.inferExprType(fa.object);
                // Auto-deref: if object is a pointer, resolve through it (matches lowerFieldAccess behavior)
                if (!obj_ty.isBuiltin()) {
                    const ptr_info = self.l.module.types.get(obj_ty);
                    if (ptr_info == .pointer) {
                        obj_ty = ptr_info.pointer.pointee;
                    }
                }
                // Optional chaining: ?T.field → ?FieldType (flattened if field is already optional)
                const is_opt_chain = fa.is_optional;
                if (is_opt_chain and !obj_ty.isBuiltin()) {
                    const opt_info = self.l.module.types.get(obj_ty);
                    if (opt_info == .optional) {
                        obj_ty = opt_info.optional.child;
                    }
                }
                if (std.mem.eql(u8, fa.field, "len")) return if (is_opt_chain) self.l.module.types.optionalOf(.i64) else .i64;
                if (std.mem.eql(u8, fa.field, "ptr")) {
                    // .ptr on slice/string → [*]element_type
                    const elem_ty = self.l.getElementType(obj_ty);
                    const mp_ty = self.l.module.types.manyPtrTo(elem_ty);
                    return if (is_opt_chain) self.l.module.types.optionalOf(mp_ty) else mp_ty;
                }
                if (!obj_ty.isBuiltin()) {
                    const field_name_id = self.l.module.types.internString(fa.field);
                    // Check union fields (tagged enum payloads) + promoted struct fields
                    const info = self.l.module.types.get(obj_ty);
                    const u_fields2: ?[]const types.TypeInfo.StructInfo.Field = switch (info) {
                        .@"union" => |u| u.fields,
                        .tagged_union => |u| u.fields,
                        else => null,
                    };
                    if (u_fields2) |ufields| {
                        for (ufields) |f| {
                            if (f.name == field_name_id) return if (is_opt_chain) self.l.optionalOfFlattened(f.ty) else f.ty;
                            // Check promoted fields from anonymous struct variants
                            if (!f.ty.isBuiltin()) {
                                const fi = self.l.module.types.get(f.ty);
                                if (fi == .@"struct") {
                                    for (fi.@"struct".fields) |sf| {
                                        if (sf.name == field_name_id) return if (is_opt_chain) self.l.optionalOfFlattened(sf.ty) else sf.ty;
                                    }
                                }
                            }
                        }
                    }
                    // Check vector element access (.x/.y/.z/.w)
                    if (info == .vector) {
                        const elem = info.vector.element;
                        return if (is_opt_chain) self.l.optionalOfFlattened(elem) else elem;
                    }
                    // Tuple field access: numeric `t.0` or named `t.x`.
                    if (info == .tuple) {
                        const tup = info.tuple;
                        if (std.fmt.parseInt(usize, fa.field, 10)) |idx| {
                            if (idx < tup.fields.len)
                                return if (is_opt_chain) self.l.optionalOfFlattened(tup.fields[idx]) else tup.fields[idx];
                        } else |_| {}
                        if (tup.names) |names| {
                            for (names, 0..) |nm, i| {
                                if (nm == field_name_id and i < tup.fields.len)
                                    return if (is_opt_chain) self.l.optionalOfFlattened(tup.fields[i]) else tup.fields[i];
                            }
                        }
                    }
                    // Check struct fields
                    const fields = self.l.getStructFields(obj_ty);
                    for (fields) |f| {
                        if (f.name == field_name_id) return if (is_opt_chain) self.l.optionalOfFlattened(f.ty) else f.ty;
                    }
                    // `#get` property accessor through an optional chain
                    // (`obj?.getter`): resolve the getter on the dereferenced
                    // inner type via a synthetic `*T` receiver, so a value
                    // optional (`?T`) — whose receiver would otherwise be the
                    // optional itself — and a pointer optional (`?*T`) both type
                    // exactly as `lowerOptionalChain` emits (issue 0160).
                    if (is_opt_chain) {
                        var deref_inner = obj_ty;
                        if (!deref_inner.isBuiltin() and self.l.module.types.get(deref_inner) == .pointer)
                            deref_inner = self.l.module.types.get(deref_inner).pointer.pointee;
                        if (self.l.getterReturnTypeOnDeref(deref_inner, fa.field)) |rt|
                            return self.l.optionalOfFlattened(rt);
                    }
                    // `#get` property accessor: type as the accessor's return
                    // type. Resolve via the synthesized no-arg call so generic
                    // bindings (e.g. a `List(T)` getter returning `T`) resolve
                    // exactly as the lowering path's call does.
                    if (self.l.getAccessorFor(obj_ty, fa.field) != null) {
                        const callee_node = Node{ .data = .{ .field_access = fa }, .span = node.span };
                        const syn_call = ast.Call{ .callee = @constCast(&callee_node), .args = &.{} };
                        const rt = self.l.callResolver().resultType(&syn_call);
                        return if (is_opt_chain) self.l.optionalOfFlattened(rt) else rt;
                    }
                }
                // Bare `Enum.variant` — a qualified enum literal read as a VALUE
                // (its type is the enum). Mirrors the `lowerFieldAccess`
                // qualified-enum-literal path: object is a type NAME resolving to
                // an enum / tagged-union (not shadowed by a value binding / global
                // value) and `field` is a PAYLOADLESS variant. Without this, a
                // direct `go(E.x)` generic-arg inference (and a `hash_val(E.A)`
                // key) yielded `.unresolved` for the value's type (issue 0274).
                if (fa.object.data == .identifier) {
                    const oname = fa.object.data.identifier.name;
                    const shadowed = if (self.l.scope) |s| s.lookup(oname) != null else false;
                    if (!shadowed and !self.l.program_index.global_names.contains(oname)) {
                        if (self.l.module.types.findByName(self.l.module.types.internString(oname))) |ty| {
                            if (!ty.isBuiltin() and self.l.isPayloadlessVariant(ty, fa.field)) return ty;
                        }
                    }
                }
                // Module-qualified `alias.Enum.variant` — the object is itself
                // a namespace-rooted member (`lib.Mode`) that resolves to an
                // enum / tagged-union TYPE in the aliased module, read here as a
                // VALUE (its type is that enum). Sibling of the bare
                // `Enum.variant` arm above; mirrors `lowerFieldAccess`'s
                // `namespaceRootedMember` enum-literal path — resolved
                // diagnostic-free (inference must not emit) via
                // `namespaceAliasVerdict` + `selectNominalLeaf` against the
                // target module. Payloadless variant only; a genuine non-enum
                // qualified member (`mod.value`, `mod.CONST`, `mod.Struct.field`)
                // falls through to `.unresolved`. Without this, `id(lib.Mode.on)`
                // generic-arg inference bound `T = .unresolved` and minted a
                // `__unresolved` monomorph that reached LLVM emission (issue 0276).
                if (fa.object.data == .field_access) {
                    const outer = fa.object.data.field_access;
                    if (outer.object.data == .identifier) {
                        const root = outer.object.data.identifier.name;
                        const shadowed = if (self.l.scope) |s| s.lookup(root) != null else false;
                        if (!shadowed and !self.l.program_index.global_names.contains(root)) {
                            switch (self.l.namespaceAliasVerdict(root)) {
                                .target => |target| {
                                    const saved_src = self.l.current_source_file;
                                    self.l.setCurrentSourceFile(target.target_module_path);
                                    var global_info: ?program_index_mod.GlobalInfo = null;
                                    if (self.l.program_index.global_names.get(outer.field)) |fallback| {
                                        switch (self.l.selectGlobalAuthor(outer.field)) {
                                            .resolved => |g| global_info = g,
                                            .untracked => global_info = fallback,
                                            else => {},
                                        }
                                    }
                                    self.l.setCurrentSourceFile(saved_src);
                                    if (global_info) |gi| return self.l.resolveFieldType(gi.ty, fa.field);
                                    switch (self.l.selectNominalLeaf(outer.field, target.target_module_path, false)) {
                                        .resolved => |ty| {
                                            if (!ty.isBuiltin() and self.l.isPayloadlessVariant(ty, fa.field)) return ty;
                                        },
                                        else => {},
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
                return .unresolved;
            },
            .identifier => |id| {
                if (self.l.scope) |scope| {
                    if (scope.lookup(id.name)) |binding| {
                        // `inline for xs (x)` element capture — type as the
                        // synthesized `xs[<i>]` it aliases.
                        if (binding.pack_elem) |elem| return self.l.inferExprType(elem);
                        return binding.ty;
                    }
                }
                // `context` is the implicit-ctx identifier; type is Context
                // when the program has registered it (i.e. std.sx imported).
                if (self.l.implicit_ctx_enabled and std.mem.eql(u8, id.name, "context")) {
                    if (self.l.module.types.findByName(self.l.module.types.internString("Context"))) |ty| return ty;
                }
                // Check global variables (e.g., `context : Context`) —
                // source-aware (issue 0115): infer the AUTHOR's global type,
                // never an unrelated module's same-named one. `.not_a_global`
                // falls through to the const / fn arms below.
                if (self.l.program_index.global_names.get(id.name)) |gi| {
                    switch (self.l.selectGlobalAuthor(id.name)) {
                        .resolved => |g| return g.ty,
                        .untracked => return gi.ty,
                        .ambiguous, .not_visible => return .unresolved,
                        .not_a_global => {},
                    }
                }
                // Check module-level value constants (e.g., WIDTH :f32: 800).
                // F4: a same-name VALUE const must infer the SOURCE-AWARE author's
                // TYPE (own-wins / one-flat-visible), not the global last-wins
                // `module_const_map` — otherwise a return-type / coercion inferred
                // on one module's `K` borrows another module's `K` TYPE. The global
                // map still gates "is this a const name at all?"; `.none` is the
                // registration-only author with no per-source partition (emit its
                // global type), and an ambiguous bare reference yields `.unresolved`
                // (the emission path diagnoses the ambiguity loudly).
                if (self.l.program_index.module_const_map.get(id.name)) |ci_global| {
                    return switch (self.l.selectModuleConst(id.name)) {
                        .resolved => |sel| sel.info.ty,
                        .none => ci_global.ty,
                        .own_opaque, .ambiguous => .unresolved,
                    };
                }
                // A bare type name (alias like `Vec4`, struct name, or
                // builtin primitive) referenced in expression position
                // is a Type value — IR type `.type_value` (8-byte handle). A
                // BACKTICK raw identifier (`` `string ``) is explicitly a value
                // binding, never the reserved type — so it never resolves here as a
                // Type (it was found in scope above, or is genuinely unresolved).
                if (!id.is_raw and self.l.isKnownTypeName(id.name)) return .type_value;
                return .unresolved;
            },
            .type_expr => |te| {
                // type_expr can also be a variable reference (e.g., "i1" matches builtin i1 type)
                if (self.l.scope) |scope| {
                    if (scope.lookup(te.name)) |binding| {
                        return binding.ty;
                    }
                }
                // A bare type name in expression position (e.g. `i64`,
                // `Point`, `*u8`) is a Type value — IR type `.type_value`.
                if (self.l.isKnownTypeName(te.name)) return .type_value;
                return .unresolved;
            },
            .enum_literal => {
                // Enum literals depend on context — use target_type if available
                return self.l.target_type orelse .unresolved;
            },
            .struct_literal => |sl| {
                if (sl.struct_name) |name| {
                    const name_id = self.l.module.types.internString(name);
                    return self.l.module.types.findByName(name_id) orelse
                        self.l.module.types.intern(.{ .@"struct" = .{ .name = name_id, .fields = &.{} } });
                }
                // A qualified (`m.Cfg.{…}`) or generic (`Pair(i32).{…}`) prefix
                // carries its type as a NODE — resolve it the same way lowering
                // does, so a `:=`-inferred decl gets the real struct type (issue
                // 0204), not the empty `{}` it would fall to below.
                if (sl.type_expr) |te| {
                    // `Ev.key.{ ... }` — qualified tagged-union variant
                    // construction: the literal's TYPE is the tagged union
                    // `Ev`, not a resolvable `Ev.key` type. Recognize it here
                    // (side-effect-free `findByName`) so inference doesn't fall
                    // to the type_bridge "field_access in type position"
                    // warning (issue 0281); lowering routes the same shape.
                    if (te.data == .field_access) {
                        const fa = te.data.field_access;
                        const obj_name: ?[]const u8 = switch (fa.object.data) {
                            .identifier => |id| id.name,
                            .type_expr => |t| t.name,
                            else => null,
                        };
                        if (obj_name) |on| {
                            const oid = self.l.module.types.internString(on);
                            if (self.l.module.types.findByName(oid)) |oty| {
                                if (self.l.module.types.get(oty) == .tagged_union) return oty;
                            }
                        }
                    }
                    const ty = self.l.resolveTypeWithBindings(te);
                    if (ty != .unresolved) return ty;
                }
                // A bare `.{ … }` adopts the contextual target only when the
                // target is a shape the literal can actually BUILD (the same
                // classification lowering gates on, plus the union/optional
                // intercepts). A scalar ambient target (an enclosing fn's int
                // return type leaking into a call arg) must not type the
                // literal — that mistyped `$T` bindings before the literal
                // ever lowered.
                if (self.l.target_type) |tt| {
                    const usable = if (tt.isBuiltin())
                        tt == .string
                    else switch (self.l.module.types.get(tt)) {
                        .@"struct", .tuple, .array, .vector, .slice, .closure, .@"union", .tagged_union, .optional => true,
                        else => false,
                    };
                    if (usable) return tt;
                }
                // No usable target: infer the anonymous-struct SHAPE the
                // lowering's synthesis will mint (same rules: all-positional
                // fields "0"/"1"/… or all-named; shorthand is named; spreads
                // and mixed forms stay unresolved — lowering handles them).
                // Interning makes this idempotent and identical to lowering.
                {
                    var named_n: usize = 0;
                    var pos_n: usize = 0;
                    for (sl.field_inits) |fi| {
                        if (fi.value.data == .spread_expr) return .unresolved;
                        if (fi.name != null) named_n += 1 else pos_n += 1;
                    }
                    if (named_n > 0 and pos_n > 0) return .unresolved;
                    var fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
                    defer fields.deinit(self.l.alloc);
                    const saved_tt = self.l.target_type;
                    self.l.target_type = null;
                    defer self.l.target_type = saved_tt;
                    for (sl.field_inits, 0..) |fi, i| {
                        const vty = self.l.inferExprType(fi.value);
                        if (vty == .unresolved or vty == .void) return .unresolved;
                        var name_buf: [24]u8 = undefined;
                        const fname = fi.name orelse (std.fmt.bufPrint(&name_buf, "{d}", .{i}) catch return .unresolved);
                        fields.append(self.l.alloc, .{
                            .name = self.l.module.types.internString(fname),
                            .ty = vty,
                        }) catch return .unresolved;
                    }
                    return self.l.module.types.internAnonStruct(
                        self.l.module.types.slice_arena.allocator().dupe(types.TypeInfo.StructInfo.Field, fields.items) catch return .unresolved,
                    );
                }
            },
            .tuple_literal => |tl| {
                // Explicitly-typed `Tuple(A, B).( ... )`: the literal's type is
                // the carried tuple type (preserves field names for the named
                // form), exactly like `Name.{ ... }` infers to `Name`.
                if (tl.type_expr) |te| {
                    const tuple_ty = self.l.resolveTypeWithBindings(te);
                    if (tuple_ty != .unresolved) return tuple_ty;
                }
                var field_types = std.ArrayList(TypeId).empty;
                defer field_types.deinit(self.l.alloc);
                // Preserve the literal's element names (the NAMED-tuple form
                // `.(a = x, b = y)`) so the inferred type carries them — this is
                // the type bound to a generic `$T` when a named-tuple literal is
                // passed DIRECTLY as a call argument. Without it `field_name(T, i)`
                // reflected the empty string and a `make_enum` over those labels
                // silently collided on "" (the `race` result synthesis). Mirrors
                // `lowerTupleLiteral`'s name capture so the inferred type and the
                // lowered value's type agree.
                var names = std.ArrayList(types.StringId).empty;
                defer names.deinit(self.l.alloc);
                var has_names = false;
                for (tl.elements) |elem| {
                    field_types.append(self.l.alloc, self.l.inferExprType(elem.value)) catch unreachable;
                    if (elem.name) |name| {
                        names.append(self.l.alloc, self.l.module.types.internString(name)) catch unreachable;
                        has_names = true;
                    } else {
                        names.append(self.l.alloc, self.l.module.types.internString("")) catch unreachable;
                    }
                }
                return self.l.module.types.intern(.{ .tuple = .{
                    .fields = self.l.alloc.dupe(TypeId, field_types.items) catch unreachable,
                    .names = if (has_names) self.l.alloc.dupe(types.StringId, names.items) catch unreachable else null,
                } });
            },
            .index_expr => |ie| {
                // Pack-arg type lookup: `<pack_name>[<int_literal>]`.
                // Read directly from `pack_arg_types` — bypasses the
                // synthesized-ident detour in `pack_arg_nodes` which
                // would otherwise lose the type when the mono's
                // scope isn't set up yet (generic-`$R` pre-inference).
                if (self.l.pack_arg_types) |pat| {
                    if (ie.object.data == .identifier) {
                        if (pat.get(ie.object.data.identifier.name)) |arg_tys| {
                            if (self.l.comptimeIndexOf(ie.index)) |raw| {
                                if (raw >= 0) {
                                    const i: usize = @intCast(raw);
                                    if (i < arg_tys.len) return arg_tys[i];
                                }
                            }
                        }
                    }
                }
                if (self.l.packArgNodeAt(&ie)) |arg_node| {
                    return self.l.inferExprType(arg_node);
                }
                const obj_ty = self.l.inferExprType(ie.object);
                // Comptime-constant index into a tuple VALUE — `tup[i]` where `i`
                // folds to a compile-time integer (an `inline for` cursor or a
                // literal). Mirrors the lowering in `lowerIndexExpr`: the result is
                // the i-th tuple field's CONCRETE type (heterogeneous elements, so
                // no single runtime element type). Without this the inference path
                // returned `.unresolved` for `tup[i]`, so a following `.field` /
                // method / comparison on it could not resolve (the `race` runtime's
                // `tasks[i].state == .ready`). A runtime index falls through to the
                // generic element-type path below.
                if (!obj_ty.isBuiltin() and (self.l.module.types.get(obj_ty) == .tuple or self.l.module.types.get(obj_ty) == .@"struct")) {
                    // Struct parity (aggregate ladder): `s[comptime i]` types
                    // as the i-th field, exactly like tuples.
                    if (self.l.comptimeIndexOf(ie.index)) |ci| {
                        if (self.l.module.types.memberType(obj_ty, ci)) |fty| return fty;
                    }
                }
                // Optional-chain index `opt?.xs[i]`: the object types as an
                // optional container (`?[N]T` / `?[]T` / `?[*]T`), so the whole
                // index expression is `?ElemType` (flattened if the element is
                // itself optional) — mirrors lowerOptionalChainIndex (issue 0181).
                if (!obj_ty.isBuiltin() and self.l.module.types.get(obj_ty) == .optional) {
                    const child = self.l.module.types.get(obj_ty).optional.child;
                    // `?*[N]T` is indexable: element is the pointee array's
                    // element. `getElementType` has no pointer arm, so consult
                    // `ptrToArrayElem` first (mirrors lowerIndexExpr's guard) —
                    // otherwise `?*[N]T` typed as `.unresolved` (issue 0181).
                    const elem = self.l.ptrToArrayElem(child) orelse self.l.ptrToSliceElem(child) orelse self.l.getElementType(child);
                    if (elem != .unresolved) return self.l.optionalOfFlattened(elem);
                }
                if (self.l.ptrToArrayElem(obj_ty)) |elem| return elem;
                if (self.l.ptrToSliceElem(obj_ty)) |elem| return elem;
                return self.l.getElementType(obj_ty);
            },
            .slice_expr => |se| {
                const obj_ty = self.l.inferExprType(se.object);
                if (obj_ty == .string) return .string;
                return self.l.module.types.sliceOf(self.l.getElementType(obj_ty));
            },
            .deref_expr => |de| {
                const ptr_ty = self.l.inferExprType(de.operand);
                if (!ptr_ty.isBuiltin()) {
                    const info = self.l.module.types.get(ptr_ty);
                    if (info == .pointer) return info.pointer.pointee;
                }
                return .unresolved;
            },
            // Postfix cast: the expression's type IS the written target;
            // the chained form yields `?T` (an optional target flattens).
            .postfix_cast => |pc| blk: {
                const t = self.l.resolveTypeArg(pc.type_expr);
                if (!pc.is_optional_chain) break :blk t;
                if (t == .unresolved) break :blk t;
                const t_is_opt = !t.isBuiltin() and self.l.module.types.get(t) == .optional;
                break :blk if (t_is_opt) t else self.l.module.types.optionalOf(t);
            },
            .chained_comparison => .bool,
            .null_coalesce => |nc| blk: {
                // `opt ?? default` — result is the inner type when lhs is
                // optional (the unwrap path's value), else falls back to
                // the rhs's type. Without this arm pack-fn callers
                // misinferred float-optional coalesces as i64 and the
                // pack mono mangled the arg as int — the actual f64 value
                // got truncated through Any boxing.
                const lhs_ty = self.l.inferExprType(nc.lhs);
                if (!lhs_ty.isBuiltin()) {
                    const info = self.l.module.types.get(lhs_ty);
                    if (info == .optional) break :blk info.optional.child;
                }
                break :blk self.l.inferExprType(nc.rhs);
            },
            // A lambda literal's type is the closure it denotes, recovered from
            // its annotations. The generic-call binder types args from the raw
            // AST (notably the UFCS path, before args are lowered), so without
            // this a `Closure(..) -> $R` worker couldn't bind `$R` from the
            // lambda's declared return type (issue 0151). An unannotated param /
            // body-inferred return stays `.unresolved` here — that arg simply
            // doesn't contribute a binding, exactly as before.
            .lambda => |lam| blk: {
                var pbuf = std.ArrayList(TypeId).empty;
                defer pbuf.deinit(self.l.alloc);
                for (lam.params) |p| {
                    const pty: TypeId = if (p.type_expr.data == .inferred_type)
                        .unresolved
                    else
                        self.l.resolveTypeWithBindings(p.type_expr);
                    pbuf.append(self.l.alloc, pty) catch {};
                }
                const ret: TypeId = if (lam.return_type) |rt|
                    self.l.resolveTypeWithBindings(rt)
                else
                    .unresolved;
                break :blk self.l.module.types.closureType(pbuf.items, ret);
            },
            // Inline asm result type (0→void, 1→T, N→named tuple) — the single
            // owner is `Lowering.asmResultType`, shared with `lowerAsmExpr` so a
            // `return asm`, a `x := asm`, and a `q, r := asm` destructure all
            // agree on the type.
            .asm_expr => |ae| self.l.asmResultType(&ae),
            // Statements don't produce values (`.return_stmt` is handled above
            // as `.noreturn` — it diverges rather than yielding `void`).
            .assignment,
            .var_decl,
            .const_decl,
            .fn_decl,
            .defer_stmt,
            .push_stmt,
            .multi_assign,
            .destructure_decl,
            => .void,
            else => .unresolved,
        };
    }
};
