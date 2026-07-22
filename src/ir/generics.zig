const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");
const type_bridge = @import("type_bridge.zig");
const lower = @import("lower.zig");

const Node = ast.Node;
const TypeId = types.TypeId;
const Lowering = lower.Lowering;

/// Generic substitution + monomorphization-key construction (architecture
/// phase A4.1), extracted from `Lowering`. Owns:
///   - the type-name mangler (`mangleTypeName` / `mangleParamList`) — the leaf
///     fragment every mono key is built from,
///   - the generic mono key (`mangleGenericName`) and the comptime-value mono
///     fragment (`appendComptimeValueMangle`),
///   - type-parameter substitution: `buildTypeBindings` (call-site inference)
///     and `inferGenericReturnType` (generic return resolution).
///
/// A `*Lowering` facade (Principle 5, like `CallResolver` / `ExprTyper`):
/// substitution reads live type-binding / scope state and the type resolver
/// helpers, so it borrows `*Lowering` rather than re-threading every field.
/// `Lowering` keeps a thin `mangleTypeName` wrapper (it has ~30 cross-cutting
/// callers — impl-map keys, conversion keys, shape keys — well beyond
/// generics); the rest call through `Lowering.genericResolver()`.
pub const GenericResolver = struct {
    l: *Lowering,

    // ── Mono-key construction ───────────────────────────────────────────

    /// Mangle a TypeId into its mono-key fragment ("i64", "ptr_T", "SL_T",
    /// "AR_n_T", struct name, "tu_X_Y", …). Recursive for compound shapes.
    pub fn mangleTypeName(self: GenericResolver, ty: TypeId) []const u8 {
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
            // appends nothing — byte-identical to the pre-E2 mangle.
            .@"struct" => |s| self.mangleNominalName(self.l.module.types.getString(s.name), s.nominal_id),
            .@"union" => |u| self.mangleNominalName(self.l.module.types.getString(u.name), u.nominal_id),
            .tagged_union => |u| self.mangleNominalName(self.l.module.types.getString(u.name), u.nominal_id),
            .@"enum" => |e| self.mangleNominalName(self.l.module.types.getString(e.name), e.nominal_id),
            .pointer => |p| blk: {
                const inner = self.mangleTypeName(p.pointee);
                break :blk std.fmt.allocPrint(self.l.alloc, "ptr_{s}", .{inner}) catch @panic("out of memory while mangling type");
            },
            .many_pointer => |p| blk: {
                const inner = self.mangleTypeName(p.element);
                break :blk std.fmt.allocPrint(self.l.alloc, "mptr_{s}", .{inner}) catch @panic("out of memory while mangling type");
            },
            .slice => |s| blk: {
                const inner = self.mangleTypeName(s.element);
                break :blk std.fmt.allocPrint(self.l.alloc, "SL_{s}", .{inner}) catch @panic("out of memory while mangling type");
            },
            .array => |a| blk: {
                const inner = self.mangleTypeName(a.element);
                break :blk std.fmt.allocPrint(self.l.alloc, "AR_{d}_{s}", .{ a.length, inner }) catch @panic("out of memory while mangling type");
            },
            .signed => |w| std.fmt.allocPrint(self.l.alloc, "i{d}", .{w}) catch @panic("out of memory while mangling type"),
            .unsigned => |w| std.fmt.allocPrint(self.l.alloc, "u{d}", .{w}) catch @panic("out of memory while mangling type"),
            .optional => |o| blk: {
                const inner = self.mangleTypeName(o.child);
                break :blk std.fmt.allocPrint(self.l.alloc, "opt_{s}", .{inner}) catch @panic("out of memory while mangling type");
            },
            .vector => |v| blk: {
                const inner = self.mangleTypeName(v.element);
                break :blk std.fmt.allocPrint(self.l.alloc, "vec_{d}_{s}", .{ v.length, inner }) catch @panic("out of memory while mangling type");
            },
            .closure => |c| self.mangleParamList("cl", c.params, c.ret),
            .function => |f| self.mangleParamList("fn", f.params, f.ret),
            .tuple => |t| blk: {
                var buf = std.ArrayList(u8).empty;
                buf.appendSlice(self.l.alloc, "tu") catch @panic("out of memory while mangling type");
                for (t.fields) |fid| {
                    buf.append(self.l.alloc, '_') catch @panic("out of memory while mangling type");
                    buf.appendSlice(self.l.alloc, self.mangleTypeName(fid)) catch @panic("out of memory while mangling type");
                }
                break :blk buf.items;
            },
            else => @tagName(info),
        };
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
        mangled.appendSlice(self.l.alloc, base_name) catch @panic("out of memory while mangling generic function");
        for (fd.type_params) |tp| {
            const ty = bindings.get(tp.name) orelse .unresolved;
            // `mangleTypeName` is the complete semantic type key (including
            // nominal ids). Dynamic storage is mandatory: a long source-
            // qualified base must never truncate into another declaration's
            // monomorph.
            mangled.appendSlice(self.l.alloc, "__") catch @panic("out of memory while mangling generic function");
            const type_name_str = self.mangleTypeName(ty);
            mangled.appendSlice(self.l.alloc, type_name_str) catch @panic("out of memory while mangling generic function");
        }
        return mangled.toOwnedSlice(self.l.alloc) catch @panic("out of memory while mangling generic function");
    }

    /// Append a comptime parameter VALUE's mono fragment to `buf` (int/bool
    /// verbatim, float with `.`/`-` escaped, string hashed) so distinct
    /// comptime-value call sites get distinct monos.
    pub fn appendComptimeValueMangle(self: GenericResolver, buf: *std.ArrayList(u8), node: *const Node) void {
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
            else => @panic("unsupported comptime value in monomorph identity"),
        }
    }

    // ── Type-parameter substitution ─────────────────────────────────────

    /// A bare identifier naming a type param BOUND by the enclosing
    /// monomorphization (`outer :: ($T: Type, …) { inner(T); }`) is a type
    /// argument: `resolveTypeArg`'s identifier arm resolves it through the
    /// active `type_bindings` — but `isTypeShapedAstNode` only knows
    /// REGISTERED type names, so Strategy 1 skipped it and the callee
    /// diagnosed "cannot infer" (issue 0339). Folded type expressions
    /// (`struct_field_type(T, i)`) already passed; a bound `T` must too.
    fn argIsBoundTypeParam(self: GenericResolver, arg: *const Node) bool {
        if (arg.data != .identifier) return false;
        const tb = if (self.l.type_bindings) |*b| b else return false;
        return tb.contains(arg.data.identifier.name);
    }

    /// Build the `$T → concrete TypeId` bindings for a generic call site.
    /// Strategy 1: explicit type args (the param named `$T` IS a type
    /// expression). Strategy 2: infer from value params that use `T`
    /// (`a: $T`, `items: []$T`), picking the widest match.
    pub fn buildTypeBindings(
        self: GenericResolver,
        fd: *const ast.FnDecl,
        args_ast: []const *const Node,
    ) std.StringHashMap(TypeId) {
        var bindings = std.StringHashMap(TypeId).init(self.l.alloc);
        const types_passed_explicitly = args_ast.len == fd.params.len;
        for (fd.type_params) |tp| {
            var found = false;
            // Strategy 1: explicit — the param whose name matches `tp.name` IS
            // the `$T: Type` declaration; the arg at that position is a type expression.
            if (types_passed_explicitly) {
                for (fd.params, 0..) |param, pi| {
                    if (std.mem.eql(u8, param.name, tp.name)) {
                        if (pi < args_ast.len and (type_bridge.isTypeShapedAstNode(args_ast[pi], &self.l.module.types) or self.l.isTypeReturningCallNode(args_ast[pi]) or self.argIsBoundTypeParam(args_ast[pi]))) {
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
                        const arg_ty = self.l.inferExprType(args_ast[s2_arg_idx]);
                        const extracted = self.l.extractTypeParam(param.type_expr, arg_ty, tp.name);
                        if (extracted) |ety| {
                            if (inferred_ty) |prev| {
                                if (ety == .f64 and prev != .f64) {
                                    inferred_ty = ety;
                                } else if (ety == .f32 and prev != .f64 and prev != .f32) {
                                    inferred_ty = ety;
                                }
                            } else {
                                inferred_ty = ety;
                            }
                        }
                    }
                }
            }
            if (inferred_ty) |ty| {
                bindings.put(tp.name, ty) catch {};
            }
        }
        return bindings;
    }

    /// Infer the return type of a generic function call by resolving type bindings.
    pub fn inferGenericReturnType(self: GenericResolver, fd: *const ast.FnDecl, c: *const ast.Call) TypeId {
        if (fd.return_type == null) return .void;

        // ONE binding builder: the same `buildTypeBindings` the lowering /
        // monomorphization path uses, so plan-side return typing can't
        // disagree with the instance actually dispatched. (The previous
        // local strategies only bound BARE `$T` value params — a structured
        // param (`[]$T`, `*$T`) never bound, so the planned return type of
        // e.g. `gfirst(xs: []$T) -> T` was the `T` stub and print's Any
        // boxing mis-tagged the value.)
        var tmp_bindings = self.buildTypeBindings(fd, c.args);
        defer tmp_bindings.deinit();

        // Resolve return type with whatever bindings we built. Even an
        // empty `tmp_bindings` is a valid input — non-generic literal
        // return types (e.g. `walk(..$args) -> string`) still need to
        // resolve through `resolveTypeWithBindings`, not fall through
        // to the historical `.i64` default. The default silently
        // misclassified pack-fn calls whose return type was a fixed
        // literal — every consumer (e.g. print's pack-shape mangling)
        // inferred `i64` and routed the value through the wrong Any
        // tag.
        var scope = TypeBindingScope.enter(self.l, tmp_bindings);
        defer scope.exit();
        // Resolve the return type in the function's DEFINING module, exactly
        // as `monomorphizeFunction` does — so a name in the return type (e.g.
        // the error set of a value-failable `(… , !E)`) resolves to the SAME
        // TypeId the instance's real signature uses, not whatever a re-export
        // alias at the call site resolves it to. Without this pin a re-exported
        // generic value-failable's `!E` resolved to a non-`.error_set` alias,
        // so the planned call result was a plain tuple and `errorChannelOf`
        // missed the failable channel (issue 0153). The binding-building above
        // stays in the call-site context (its args are typed there).
        const saved_src = self.l.current_source_file;
        defer self.l.setCurrentSourceFile(saved_src);
        if (fd.body.source_file) |src| self.l.setCurrentSourceFile(src);
        return self.l.resolveTypeWithBindings(fd.return_type.?);
    }
};

/// Scoped override of `Lowering.type_bindings`: install a binding set for the
/// duration of a substitution, restoring the prior set on `exit`. Replaces the
/// manual save/restore the generic-return resolution used (PLAN-ARCH A4.1
/// "scoped substitution envs").
const TypeBindingScope = struct {
    l: *Lowering,
    saved: ?std.StringHashMap(TypeId),

    fn enter(l: *Lowering, bindings: std.StringHashMap(TypeId)) TypeBindingScope {
        const saved = l.type_bindings;
        l.type_bindings = bindings;
        return .{ .l = l, .saved = saved };
    }

    fn exit(self: *TypeBindingScope) void {
        self.l.type_bindings = self.saved;
    }
};
