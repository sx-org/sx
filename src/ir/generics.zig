const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");
const type_bridge = @import("type_bridge.zig");
const lower = @import("lower.zig");
const init_plan = @import("lower/init_plan.zig");
const program_index = @import("program_index.zig");

const Node = ast.Node;
const TypeId = types.TypeId;
const Lowering = lower.Lowering;

/// A value with no type of its own: an untyped constant, or a bare `.[…]`
/// whose elements are all such values.
fn isContextualArgument(l: *Lowering, node: *const Node) bool {
    return switch (node.data) {
        .array_literal => |al| al.type_expr == null and for (al.elements) |elem| {
            if (!isContextualArgument(l, elem)) break false;
        } else true,
        else => program_index.untypedConst(node, l) != null,
    };
}

fn contextualArgumentFits(l: *Lowering, node: *const Node, ty: TypeId) bool {
    if (node.data == .array_literal) {
        const elements = node.data.array_literal.elements;
        const elem_ty = literalElementType(l, ty, elements.len) orelse return false;
        return for (elements) |elem| {
            if (!contextualArgumentFits(l, elem, elem_ty)) break false;
        } else true;
    }
    return switch (program_index.untypedConst(node, l).?) {
        .integer => l.isIntEx(ty) or Lowering.isFloat(ty),
        .float => Lowering.isFloat(ty),
        .string => l.stringLiteralFits(ty),
    };
}

/// Whether an untyped argument at a parameter written `type_expr` fits the
/// binding its binder has: a bare `.[…]` descends each slice or array layer
/// that wraps the binder.
fn contextualParamFits(l: *Lowering, node: *const Node, type_expr: *const Node, binding: TypeId) bool {
    if (node.data == .array_literal) {
        const elem_expr = switch (type_expr.data) {
            .slice_type_expr => |st| st.element_type,
            .array_type_expr => |at| at.element_type,
            else => return contextualArgumentFits(l, node, binding),
        };
        return for (node.data.array_literal.elements) |elem| {
            if (!contextualParamFits(l, elem, elem_expr, binding)) break false;
        } else true;
    }
    return contextualArgumentFits(l, node, binding);
}

/// The element type a bare `.[…]` of `length` elements takes at `ty`: an array
/// or vector of that length, or a slice.
fn literalElementType(l: *Lowering, ty: TypeId, length: usize) ?TypeId {
    if (l.module.types.sliceInfoOf(ty)) |s| return s.element;
    if (ty.isBuiltin()) return null;
    return switch (l.module.types.get(ty)) {
        .array => |a| if (a.length == length) a.element else null,
        .vector => |v| if (v.length == length) v.element else null,
        else => null,
    };
}

/// A float outranks an earlier binding, `f64` outranking `f32`, and arrays or
/// vectors of one shape join their elements; otherwise the first binding
/// stands.
fn widerBinding(l: *Lowering, prev: ?TypeId, ty: TypeId) TypeId {
    const bound = prev orelse return ty;
    if (ty == .f64 or (ty == .f32 and bound != .f64)) return ty;
    if (bound.isBuiltin() or ty.isBuiltin()) return bound;
    const table = &l.module.types;
    return switch (table.get(bound)) {
        .array => |a| switch (table.get(ty)) {
            .array => |b| if (a.length == b.length and a.sentinel == b.sentinel)
                table.arrayOfSentinel(widerBinding(l, a.element, b.element), a.length, a.sentinel)
            else
                bound,
            else => bound,
        },
        .vector => |a| switch (table.get(ty)) {
            .vector => |b| if (a.length == b.length) table.vectorOf(widerBinding(l, a.element, b.element), a.length) else bound,
            else => bound,
        },
        else => bound,
    };
}

pub const GenericResolver = struct {
    l: *Lowering,

    pub fn mangleTypeName(self: GenericResolver, ty: TypeId) []const u8 {
        if (self.l.module.types.canonicalType(ty) != ty) {
            const info = self.l.module.types.get(ty);
            const is_instance = info == .@"struct" and self.l.struct_instance_template.contains(self.l.module.types.getString(info.@"struct".name));
            if (!is_instance)
                return std.fmt.allocPrint(self.l.alloc, "annotation_{d}", .{ty.index()}) catch @panic("out of memory while mangling type");
        }
        // Builtin types
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
        if (ty == .usize) return "usize";
        if (ty == .isize) return "isize";

        const info = self.l.module.types.get(ty);
        return switch (info) {
            // A nominal type's mangle includes its `nominal_id` when nonzero so two
            // same-DISPLAY-name authors in different sources produce
            // DISTINCT monomorph symbols (`struct_to_string__Box` vs
            // `struct_to_string__Box__n1`) instead of one symbol with conflicting
            // signatures. `nominal_id == 0` (the single-author / structural case)
            // appends nothing.
            .@"struct" => |s| self.mangleNominalName(self.l.module.types.getString(s.name), s.nominal_id),
            .@"union" => |u| self.mangleNominalName(self.l.module.types.getString(u.name), u.nominal_id),
            .@"enum" => |e| self.mangleNominalName(self.l.module.types.getString(e.name), e.nominal_id),
            .pointer => |p| blk: {
                const inner = self.mangleTypeName(p.pointee);
                break :blk std.fmt.allocPrint(self.l.alloc, "ptr_{s}", .{inner}) catch @panic("out of memory while mangling type");
            },
            .many_pointer => |p| blk: {
                const inner = self.mangleTypeName(p.element);
                break :blk if (p.sentinel) |x|
                    std.fmt.allocPrint(self.l.alloc, "mptrs{d}_{s}", .{ x, inner }) catch @panic("out of memory while mangling type")
                else
                    std.fmt.allocPrint(self.l.alloc, "mptr_{s}", .{inner}) catch @panic("out of memory while mangling type");
            },
            .slice => |s| blk: {
                const inner = self.mangleTypeName(s.element);
                break :blk if (s.sentinel) |x|
                    std.fmt.allocPrint(self.l.alloc, "SLs{d}_{s}", .{ x, inner }) catch @panic("out of memory while mangling type")
                else
                    std.fmt.allocPrint(self.l.alloc, "SL_{s}", .{inner}) catch @panic("out of memory while mangling type");
            },
            .array => |a| blk: {
                const inner = self.mangleTypeName(a.element);
                break :blk if (a.sentinel) |x|
                    std.fmt.allocPrint(self.l.alloc, "ARs{d}_{d}_{s}", .{ x, a.length, inner }) catch @panic("out of memory while mangling type")
                else
                    std.fmt.allocPrint(self.l.alloc, "AR_{d}_{s}", .{ a.length, inner }) catch @panic("out of memory while mangling type");
            },
            // A width the aliases do not name is an ordinary identifier, so a
            // formed int takes a shape fragment like every other formed type —
            // never the bare `u7` a struct of that spelling mangles to.
            .signed => |w| std.fmt.allocPrint(self.l.alloc, "int_{d}_s", .{w}) catch @panic("out of memory while mangling type"),
            .unsigned => |w| std.fmt.allocPrint(self.l.alloc, "int_{d}_u", .{w}) catch @panic("out of memory while mangling type"),
            .optional => |o| blk: {
                const inner = self.mangleTypeName(o.child);
                break :blk std.fmt.allocPrint(self.l.alloc, "opt_{s}", .{inner}) catch @panic("out of memory while mangling type");
            },
            .vector => |v| blk: {
                const inner = self.mangleTypeName(v.element);
                break :blk std.fmt.allocPrint(self.l.alloc, "vec_{d}_{s}", .{ v.length, inner }) catch @panic("out of memory while mangling type");
            },
            // The formation site joins the key: two sites forming the same `T`
            // are distinct implementors, and a shared mono would bake the first
            // site's `site()` into the second's writes.
            .closure => |c| if (c.init_target) |it|
                std.fmt.allocPrint(self.l.alloc, "init{d}_{s}", .{ c.init_site, self.mangleTypeName(it) }) catch @panic("out of memory while mangling type")
            else if (c.build_protocol) |bp|
                std.fmt.allocPrint(self.l.alloc, "block_{s}", .{self.mangleTypeName(bp)}) catch @panic("out of memory while mangling type")
            else
                self.mangleParamList("cl", c.params, c.ret),
            // The convention, the C tail, and a pack shape join a function
            // type's identity, so they join its monomorph key — as a mandatory
            // fixed-position field block BEFORE the parameter and return
            // fragments: fn + convention (c|d) + tail (v|f) + pack (p<N>|n).
            // Every function type writes every field, so no type-name fragment
            // can absorb a neighbour's metadata.
            .function => |f| blk: {
                var head = std.ArrayList(u8).empty;
                head.appendSlice(self.l.alloc, "fn") catch @panic("out of memory while mangling type");
                head.append(self.l.alloc, if (f.call_conv == .c) 'c' else 'd') catch @panic("out of memory while mangling type");
                head.append(self.l.alloc, if (f.is_c_variadic) 'v' else 'f') catch @panic("out of memory while mangling type");
                if (f.pack_start) |ps| {
                    const tag = std.fmt.allocPrint(self.l.alloc, "p{d}", .{ps}) catch @panic("out of memory while mangling type");
                    head.appendSlice(self.l.alloc, tag) catch @panic("out of memory while mangling type");
                } else {
                    head.append(self.l.alloc, 'n') catch @panic("out of memory while mangling type");
                }
                break :blk self.mangleParamList(head.items, f.params, f.ret);
            },
            // The channel is part of a failable's identity: two callees that
            // agree on the value slots and differ on the set they raise key to
            // distinct monomorphs.
            .failable => |f| std.fmt.allocPrint(self.l.alloc, "fl_{s}_{s}", .{
                self.mangleTypeName(f.value),
                self.mangleTypeName(f.err),
            }) catch @panic("out of memory while mangling type"),
            .@"error" => |e| self.mangleErrorMembers(e),
            else => @tagName(info),
        };
    }

    /// An error keys by its MEMBERS. A member-less channel (`!`, `!dyn`) is
    /// identified by its spelling instead, whose punctuation the key carries as
    /// `_`.
    fn mangleErrorMembers(self: GenericResolver, e: types.TypeInfo.ErrorSetInfo) []const u8 {
        var buf = std.ArrayList(u8).empty;
        buf.appendSlice(self.l.alloc, "er") catch @panic("out of memory while mangling type");
        if (e.tags.len == 0) {
            for (self.l.module.types.getString(e.name)) |c| {
                const safe = if (std.ascii.isAlphanumeric(c)) c else '_';
                buf.append(self.l.alloc, safe) catch @panic("out of memory while mangling type");
            }
            return buf.items;
        }
        for (e.tags) |tag| {
            const frag = std.fmt.allocPrint(self.l.alloc, "_{d}", .{tag}) catch @panic("out of memory while mangling type");
            buf.appendSlice(self.l.alloc, frag) catch @panic("out of memory while mangling type");
        }
        return buf.items;
    }

    /// Append a `__n<id>` disambiguator to a nominal type's display name when its
    /// `nominal_id` is nonzero (a same-name shadow); id 0 returns the
    /// name unchanged so single-author mangling is byte-identical.
    fn mangleNominalName(self: GenericResolver, name: []const u8, nominal_id: u32) []const u8 {
        if (nominal_id == 0) return name;
        return std.fmt.allocPrint(self.l.alloc, "{s}__n{d}", .{ name, nominal_id }) catch @panic("out of memory while mangling nominal type");
    }

    fn mangleParamList(self: GenericResolver, prefix: []const u8, params: []const TypeId, ret: TypeId) []const u8 {
        var buf = std.ArrayList(u8).empty;
        buf.appendSlice(self.l.alloc, prefix) catch @panic("out of memory while mangling callable type");
        for (params) |p| {
            buf.append(self.l.alloc, '_') catch @panic("out of memory while mangling callable type");
            buf.appendSlice(self.l.alloc, self.mangleTypeName(p)) catch @panic("out of memory while mangling callable type");
        }
        buf.appendSlice(self.l.alloc, "__") catch @panic("out of memory while mangling callable type");
        buf.appendSlice(self.l.alloc, self.mangleTypeName(ret)) catch @panic("out of memory while mangling callable type");
        return buf.items;
    }

    /// Mangle a generic call site into "base__Type1_Type2".
    /// Returns a heap-allocated string owned by the lowering allocator.
    pub fn mangleGenericName(
        self: GenericResolver,
        base_name: []const u8,
        fd: *const ast.FnDecl,
        bindings: *const std.StringHashMap(TypeId),
    ) []const u8 {
        var mangled = std.ArrayList(u8).empty;
        mangled.appendSlice(self.l.alloc, self.l.declIdentityName(base_name, fd)) catch @panic("out of memory while mangling generic function");
        for (fd.type_params) |tp| {
            const ty = bindings.get(tp.name) orelse .unresolved;
            mangled.appendSlice(self.l.alloc, "__") catch @panic("out of memory while mangling generic function");
            const type_name_str = self.mangleTypeName(ty);
            mangled.appendSlice(self.l.alloc, type_name_str) catch @panic("out of memory while mangling generic function");
        }
        return mangled.toOwnedSlice(self.l.alloc) catch @panic("out of memory while mangling generic function");
    }

    /// Append a comptime parameter VALUE's mono fragment to `buf` (int/bool
    /// verbatim, float with `.`/`-` escaped, string hashed) so distinct
    /// comptime-value call sites get distinct monos. Returns false for a node
    /// whose value the identity cannot encode — a name, a call, an operator
    /// expression — leaving the refusal to the caller.
    pub fn appendComptimeValueMangle(self: GenericResolver, buf: *std.ArrayList(u8), node: *const Node) bool {
        switch (node.data) {
            .int_literal => |lit| {
                var tmp: [32]u8 = undefined;
                const written = std.fmt.bufPrint(&tmp, "{d}", .{lit.value}) catch unreachable;
                buf.appendSlice(self.l.alloc, written) catch @panic("out of memory while mangling comptime value");
            },
            .char_literal => |lit| {
                var tmp: [32]u8 = undefined;
                const written = std.fmt.bufPrint(&tmp, "c{d}", .{lit.value}) catch unreachable;
                buf.appendSlice(self.l.alloc, written) catch @panic("out of memory while mangling comptime value");
            },
            .bool_literal => |lit| {
                buf.appendSlice(self.l.alloc, if (lit.value) "true" else "false") catch @panic("out of memory while mangling comptime value");
            },
            .float_literal => |lit| {
                var tmp: [64]u8 = undefined;
                const written = std.fmt.bufPrint(&tmp, "{d}", .{lit.value}) catch unreachable;
                for (written) |c| {
                    buf.append(self.l.alloc, if (c == '.') '_' else if (c == '-') 'n' else c) catch @panic("out of memory while mangling comptime value");
                }
            },
            .string_literal => |lit| {
                // Encode the complete bytes. A hash is not an identity key.
                buf.appendSlice(self.l.alloc, "s") catch @panic("out of memory while mangling comptime value");
                const hex = "0123456789abcdef";
                for (lit.raw) |byte| {
                    buf.append(self.l.alloc, hex[byte >> 4]) catch @panic("out of memory while mangling comptime value");
                    buf.append(self.l.alloc, hex[byte & 0xf]) catch @panic("out of memory while mangling comptime value");
                }
            },
            else => return false,
        }
        return true;
    }

    // ── Type-parameter substitution ─────────────────────────────────────

    /// A bare identifier naming a type param BOUND by the enclosing
    /// monomorphization (`outer :: ($T: Type, …) { inner(T); }`) is a type
    /// argument: `resolveTypeArg`'s identifier arm resolves it through the
    /// active `type_bindings` — but `isTypeShapedAstNode` only knows
    /// REGISTERED type names, so Strategy 1 skipped it and the callee
    /// diagnosed "cannot infer". Folded type expressions
    /// (`@pointeeType(T)`) already passed; a bound `T` must too.
    fn argIsBoundTypeParam(self: GenericResolver, arg: *const Node) bool {
        if (arg.data != .identifier) return false;
        const tb = if (self.l.type_bindings) |*b| b else return false;
        return tb.contains(arg.data.identifier.name);
    }

    /// An inline-for member cursor's `.type` / `.payload` is a type argument
    /// (`nameOf(f.type)` binds `$T`). `aliasedFieldAccess` re-roots it to the
    /// spelled `@typeInfo` projection. `isTypeShapedAstNode` is stateless and
    /// cannot look up the capture.
    fn argIsAliasedMemberType(self: GenericResolver, arg: *const Node) bool {
        const aliased = self.l.aliasedFieldAccess(arg) orelse return false;
        return type_bridge.typeInfoProjection(aliased) != null;
    }

    /// Build the `$T → concrete TypeId` bindings for a generic call site.
    /// Strategy 1: explicit type args (the param named `$T` IS a type
    /// expression). Strategy 2: infer from value params that use `T`
    /// (`a: $T`, `items: []$T`), picking the widest match.
    /// Whether a generic call spells its type arguments. Exact arity answers on
    /// its own; a bare `..` tail or omitted defaulted trailing params keep the
    /// arity open, so the answer comes from what stands in the type-parameter
    /// positions. `args_ast` is parallel to `fd.params` (dot-call callers
    /// prepend the receiver's node).
    pub fn typesPassedExplicitly(self: GenericResolver, fd: *const ast.FnDecl, args_ast: []const *const Node) bool {
        if (!fd.is_c_variadic) {
            if (args_ast.len == fd.params.len) return true;
            if (args_ast.len > fd.params.len) return false;
        }
        for (fd.params, 0..) |*param, pi| {
            if (pi >= args_ast.len) {
                if (param.default_expr == null) return false;
                continue;
            }
            if (!Lowering.isTypeParamDecl(param, fd.type_params)) continue;
            const node = args_ast[pi];
            if (!(type_bridge.isTypeShapedAstNode(node, &self.l.module.types) or
                self.l.isTypeReturningCallNode(node) or
                self.l.isGenericTypeConstructorCallNode(node) or
                self.argIsBoundTypeParam(node) or
                self.argIsAliasedMemberType(node))) return false;
        }
        return true;
    }

    /// Whether `tp` is a TYPE parameter a call must bind — constrained by
    /// `Type` or by a protocol. Comptime VALUE params (`$N: u32`) and `..$Ts`
    /// packs bind through their own dispatch, so they answer false.
    pub fn bindsTypeArgument(self: GenericResolver, tp: ast.StructTypeParam, source: ?[]const u8) bool {
        if (tp.is_variadic) return false;
        if (tp.constraint.data != .type_expr) return false;
        const cname = tp.constraint.data.type_expr.name;
        return std.mem.eql(u8, cname, "Type") or self.l.isProtocolConstraint(cname, source);
    }

    pub fn buildTypeBindings(
        self: GenericResolver,
        fd: *const ast.FnDecl,
        args_ast: []const *const Node,
    ) std.StringHashMap(TypeId) {
        var bindings = std.StringHashMap(TypeId).init(self.l.alloc);
        const types_passed_explicitly = self.typesPassedExplicitly(fd, args_ast);
        // An `@Init` binder binds to the implementor formed for its target, and
        // the target may name the call's other binders (`$I/@Init(Tagged($U))`),
        // so those bind first.
        var target_scope: ?std.StringHashMap(TypeId) = null;
        defer if (target_scope) |*m| m.deinit();
        for ([2]bool{ false, true }) |init_round| for (fd.type_params) |tp| {
            if (init_plan.isInitBinder(fd, tp.name) != init_round) continue;
            if (init_round and target_scope == null) target_scope = self.formationBindings(fd, &bindings);
            var found = false;
            // Strategy 1: explicit — the param whose name matches `tp.name` IS
            // the `$T: Type` declaration; the arg at that position is a type expression.
            if (types_passed_explicitly) {
                for (fd.params, 0..) |param, pi| {
                    if (std.mem.eql(u8, param.name, tp.name)) {
                        if (pi < args_ast.len and (type_bridge.isTypeShapedAstNode(args_ast[pi], &self.l.module.types) or self.l.isTypeReturningCallNode(args_ast[pi]) or self.l.isGenericTypeConstructorCallNode(args_ast[pi]) or self.argIsBoundTypeParam(args_ast[pi]) or self.argIsAliasedMemberType(args_ast[pi]))) {
                            const ty = self.l.resolveTypeArg(args_ast[pi]);
                            bindings.put(tp.name, ty) catch {};
                            found = true;
                        }
                        break;
                    }
                }
            }
            if (found) continue;
            // Strategy 2: infer from value params that USE the type param
            // (e.g. a: $T, b: T, items: []$T). Pick widest type across matches.
            var inferred_ty: ?TypeId = null;
            // Two rounds over the value parameters: the arguments that carry a
            // type of their own bind `$T` first; an untyped argument then takes
            // what they bound whenever it converts to it, and otherwise
            // contributes its own default.
            for ([2]bool{ false, true }) |literal_round| {
                var s2_arg_idx: usize = 0;
                for (fd.params) |param| {
                    const is_type_decl = Lowering.isTypeParamDecl(&param, fd.type_params);
                    defer if (!is_type_decl) {
                        s2_arg_idx += 1;
                    };
                    if (is_type_decl) {
                        if (types_passed_explicitly) s2_arg_idx += 1;
                        continue;
                    }
                    const matched = self.l.matchTypeParam(param.type_expr, tp.name);
                    if (matched) {
                        if (s2_arg_idx < args_ast.len) {
                            const arg_node = args_ast[s2_arg_idx];
                            if (isContextualArgument(self.l, arg_node) != literal_round) continue;
                            if (literal_round and inferred_ty != null and contextualParamFits(self.l, arg_node, param.type_expr, inferred_ty.?)) continue;
                            // A written lambda literal IS its env struct; the
                            // binder takes that type before the literal lowers.
                            if (Lowering.boundOnBinder(param.type_expr, tp.name) and arg_node.data == .lambda and arg_node.data.lambda.has_env) {
                                if (self.l.lambdaEnvType(&arg_node.data.lambda)) |env_ty| {
                                    if (inferred_ty == null) inferred_ty = env_ty;
                                    continue;
                                }
                            }
                            // A guard-narrowed container argument binds through its
                            // payload — `[]$T` against `[]i64`, not `?[]i64`.
                            const inferred = self.l.narrowedContainerChild(args_ast[s2_arg_idx]) orelse
                                self.l.inferExprType(args_ast[s2_arg_idx]);
                            // A bare fn NAME has no inferable expression type — it
                            // is a value whose type lives in its declaration. Bind
                            // `$F` to that signature so the instance's param is a
                            // callable, not a bare integer word.
                            const arg_ty = if (inferred == .unresolved)
                                self.l.bareFnNameSignature(args_ast[s2_arg_idx]) orelse inferred
                            else
                                inferred;
                            // An `@Init`-bounded binder binds to the IMPLEMENTOR the
                            // argument forms into, not to the argument's own type
                            // (§5.2); the init's type argument still binds from the
                            // ordinary type through `extractTypeParam` below.
                            const extracted = self.formedBinding(target_scope, param.type_expr, tp.name, args_ast[s2_arg_idx], arg_ty) orelse
                                self.l.blockBinderType(param.type_expr, tp.name, args_ast[s2_arg_idx], arg_ty) orelse
                                self.l.extractTypeParam(param.type_expr, arg_ty, tp.name);
                            // The binder a function-type bound is written on is
                            // answered by the argument's own SHAPE, which an
                            // unlowered `|x|` does not have yet. Committing what
                            // the annotation guessed would key the instance on
                            // slots nothing has decided.
                            if (extracted != null and Lowering.boundOnBinder(param.type_expr, tp.name) and
                                carriesUnresolved(self.l, extracted.?)) continue;
                            if (extracted) |ety| inferred_ty = widerBinding(self.l, inferred_ty, ety);
                        }
                    }
                }
            }
            if (inferred_ty) |ty| {
                bindings.put(tp.name, ty) catch {};
                continue;
            }
            // A binder the arguments cannot speak for: a blanket impl's method
            // names the IMPL's binders, which the carrier's instantiation bound.
            if (self.l.impl_binder_seed) |seed| {
                if (seed.get(tp.name)) |ty| bindings.put(tp.name, ty) catch {};
            }
        };
        return bindings;
    }

    /// What an `@Init` binder's target resolves under: the names in force at the
    /// call, the instance's binders over them, and the call's own over those. A
    /// binder of `fd` the call left unbound names nothing.
    fn formationBindings(self: GenericResolver, fd: *const ast.FnDecl, bound: *const std.StringHashMap(TypeId)) std.StringHashMap(TypeId) {
        var in_scope = if (self.l.type_bindings) |tb| tb.clone() catch unreachable else std.StringHashMap(TypeId).init(self.l.alloc);
        if (self.l.impl_binder_seed) |seed| {
            var it = seed.iterator();
            while (it.next()) |e| in_scope.put(e.key_ptr.*, e.value_ptr.*) catch unreachable;
        }
        for (fd.type_params) |tp| {
            if (bound.get(tp.name)) |ty| {
                in_scope.put(tp.name, ty) catch unreachable;
            } else _ = in_scope.remove(tp.name);
        }
        return in_scope;
    }

    /// What an `@Init` binder binds to, its target read under `target_scope`.
    /// Null before `target_scope` is built, and while the target awaits a binder
    /// the call left unbound.
    fn formedBinding(
        self: GenericResolver,
        target_scope: ?std.StringHashMap(TypeId),
        param_type: *const Node,
        tp_name: []const u8,
        arg: *const Node,
        arg_ty: TypeId,
    ) ?TypeId {
        const in_scope = target_scope orelse return null;
        var scope = installTypeBindings(self.l, in_scope);
        defer scope.exit();
        const target_node = init_plan.boundTargetNode(param_type) orelse return null;
        if (init_plan.awaitsBinder(self.l, target_node)) return null;
        return self.l.initBinderType(param_type, tp_name, arg, arg_ty);
    }

    /// The element type a bare `.[…]` binds from its elements, as arguments
    /// bind one `$T`. An element inference cannot type (`null`, `.a`) binds
    /// nothing.
    pub fn elementBinding(self: GenericResolver, elements: []const *Node) ?TypeId {
        var bound: ?TypeId = null;
        for ([2]bool{ false, true }) |literal_round| {
            for (elements) |elem| {
                if (isContextualArgument(self.l, elem) != literal_round) continue;
                if (literal_round and bound != null and contextualArgumentFits(self.l, elem, bound.?)) continue;
                const ty = self.l.inferExprType(elem);
                if (ty == .void or ty == .unresolved) continue;
                bound = widerBinding(self.l, bound, ty);
            }
        }
        return bound;
    }

    /// Infer the return type of a generic function call by resolving type bindings.
    pub fn inferGenericReturnType(self: GenericResolver, fd: *const ast.FnDecl, c: *const ast.Call) TypeId {
        if (fd.return_type == null) return .void;

        // ONE binding builder: the same `buildTypeBindings` the lowering /
        // monomorphization path uses, so plan-side return typing can't
        // disagree with the instance actually dispatched. A builder that binds
        // only BARE `$T` value params leaves a structured param (`[]$T`, `*$T`)
        // unbound, so the planned return type of e.g. `gfirst(xs: []$T) -> T`
        // is the `T` stub and print's Any boxing mis-tags the value.
        var tmp_bindings = self.buildTypeBindings(fd, c.args);
        defer tmp_bindings.deinit();

        // A TYPE param the arguments leave unbound resolves as `.unresolved`:
        // its return leaf names the template's own parameter, which has no
        // declaration to find, and the call path owns the `cannot infer`
        // diagnostic for it.
        for (fd.type_params) |tp| {
            if (!self.bindsTypeArgument(tp, fd.body.source_file)) continue;
            if (tmp_bindings.contains(tp.name)) continue;
            tmp_bindings.put(tp.name, .unresolved) catch {};
        }

        // Resolve return type with whatever bindings we built. Even an
        // empty `tmp_bindings` is a valid input — non-generic literal
        // return types (e.g. `walk(..$args) -> string`) still need to
        // resolve through `resolveTypeWithBindings` rather than fall back
        // to `.i64`. A blanket `.i64` silently misclassifies a pack-fn call
        // whose return type is a fixed literal: every consumer (e.g. print's
        // pack-shape mangling) then infers `i64` and routes the value through
        // the wrong Any tag.
        var scope = TypeBindingScope.enter(self.l, tmp_bindings);
        defer scope.exit();
        // Resolve the return type in the function's DEFINING module, exactly
        // as `monomorphizeFunction` does — so a name in the return type (e.g.
        // the error set of a value-failable `(… , !E)`) resolves to the SAME
        // TypeId the instance's real signature uses, not whatever a re-export
        // alias at the call site resolves it to. The pin is what keeps a
        // re-exported generic value-failable's `!E` an error, so the
        // planned call result carries a channel `errorChannelOf` can read.
        // The binding-building above
        // stays in the call-site context (its args are typed there).
        const saved_src = self.l.lexicalContext();
        defer self.l.restoreLexicalContext(saved_src);
        self.l.setFunctionContext(fd);
        return self.l.resolveTypeWithBindings(fd.return_type.?);
    }
};

/// Whether `ty` leaves a signature slot undecided.
fn carriesUnresolved(l: *Lowering, ty: TypeId) bool {
    if (ty == .unresolved) return true;
    const sig = l.callableSigOf(ty) orelse return false;
    for (sig.params) |p| if (p == .unresolved) return true;
    return sig.ret == .unresolved;
}

/// The per-element types of a `.pack` binding, or null for any other type.
fn packElements(l: *Lowering, ty: TypeId) ?[]const TypeId {
    if (ty == .unresolved or ty.isBuiltin()) return null;
    const info = l.module.types.get(ty);
    return if (info == .pack) info.pack.elements else null;
}

/// Scoped override of `Lowering.type_bindings`: install a binding set for the
/// duration of a substitution, restoring the prior set on `exit`.
///
/// Installing the map INSTALLS PACK EXPANSION with it. A `.pack` binding — what
/// `$F/(..$A)` binds A to — is read off the pack maps, not off `type_bindings`,
/// so a `Closure(..A)` resolved without them collapses to a 0-arity shape that
/// reaches codegen.
pub const TypeBindingScope = struct {
    l: *Lowering,
    saved: ?std.StringHashMap(TypeId),
    saved_pack_arg_types: ?std.StringHashMap([]const TypeId),
    saved_pack_bindings: ?std.StringHashMap([]const TypeId),
    packs: ?std.StringHashMap([]const TypeId),

    pub fn enter(l: *Lowering, bindings: std.StringHashMap(TypeId)) TypeBindingScope {
        var scope = TypeBindingScope{
            .l = l,
            .saved = l.type_bindings,
            .saved_pack_arg_types = l.pack_arg_types,
            .saved_pack_bindings = l.pack_bindings,
            .packs = null,
        };
        l.type_bindings = bindings;

        var probe = bindings.valueIterator();
        const has_pack = while (probe.next()) |v| {
            if (packElements(l, v.*) != null) break true;
        } else false;
        if (!has_pack) return scope;

        var packs = std.StringHashMap([]const TypeId).init(l.alloc);
        if (l.pack_arg_types) |current| {
            var it = current.iterator();
            while (it.next()) |e| packs.put(e.key_ptr.*, e.value_ptr.*) catch {};
        }
        var it = bindings.iterator();
        while (it.next()) |e| {
            if (packElements(l, e.value_ptr.*)) |elems| packs.put(e.key_ptr.*, elems) catch {};
        }
        scope.packs = packs;
        l.pack_arg_types = packs;
        l.pack_bindings = packs;
        return scope;
    }

    pub fn exit(self: *TypeBindingScope) void {
        self.l.type_bindings = self.saved;
        self.l.pack_arg_types = self.saved_pack_arg_types;
        self.l.pack_bindings = self.saved_pack_bindings;
        if (self.packs) |*p| p.deinit();
    }
};

/// Install `bindings` as the substitution in force, pack expansion included,
/// until the returned scope exits.
pub fn installTypeBindings(l: *Lowering, bindings: std.StringHashMap(TypeId)) TypeBindingScope {
    return TypeBindingScope.enter(l, bindings);
}
