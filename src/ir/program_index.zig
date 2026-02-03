const std = @import("std");
const ast = @import("../ast.zig");
const imports = @import("../imports.zig");
const types = @import("types.zig");
const inst = @import("inst.zig");
const errors = @import("../errors.zig");
const type_resolver = @import("type_resolver.zig");

const Node = ast.Node;
const TypeId = types.TypeId;

/// Owned copy of a generic struct template (AST pointers are copied/interned to survive imports)
pub const StructTemplate = struct {
    name: []const u8,
    type_params: []const TemplateParam,
    field_names: []const []const u8,
    field_type_nodes: []const *const Node, // raw AST pointers — must be copied from heap nodes
    // The authoring `StructDecl` — the NON-optional identity that selects this
    // template's method bodies at instantiation. Stamped per-instance into
    // `struct_instance_author` from the SAME template that builds the layout, so
    // layout-author and body-author are one object and can never re-diverge (a
    // method body is resolved via this decl's own `methods`, never by the global
    // last-wins `fn_ast_map["Name.method"]`).
    decl: *const ast.StructDecl,
    // The module that DECLARED this template. Instantiation resolves the
    // field type nodes in THIS source context, not the (possibly cross-module)
    // instantiation site — so a field naming a type visible only in the
    // template's module resolves correctly, and the source-aware nominal leaf
    // classifies main vs imported by the TEMPLATE's file (an undeclared field
    // type or a value param used as a type is diagnosed at the right authority,
    // never silently stubbed). Null only when the decl carried no source file
    // (synthesized / comptime registration).
    source_file: ?[]const u8 = null,
};
pub const TemplateParam = struct {
    name: []const u8,
    is_type_param: bool, // true for $T: Type, false for $N: u32
    is_variadic: bool = false, // `..$Ts: []Type` — binds remaining type args as a pack
    // Declared constraint type NAME for a value (non-type) param (`$K: u32` →
    // "u32"), used to range-check the folded arg at instantiation; null for a
    // type/variadic param or when the constraint isn't a plain type name.
    value_type: ?[]const u8 = null,
};

pub const ProtocolMethodInfo = struct {
    name: []const u8,
    param_types: []const TypeId, // excluding self
    ret_type: TypeId, // a `Self` return is encoded as *void
    // Era-2 per-method erasability: true iff the signature is expressible
    // with `Self` unknown (`Self` only as the receiver). An excluded method
    // has no vtable/#inline slot; erased dispatch refuses it and points at
    // the generic-bound path. Conformance still requires an impl for it.
    dispatchable: bool = true,
    // When !dispatchable: the first offending parameter's name, or null
    // when the return type is what mentions `Self`.
    self_param: ?[]const u8 = null,
};

/// Where a protocol method's signature mentions `Self` outside the receiver:
/// the first offending parameter's name, or `param_name = null` for the
/// return type.
pub const SelfOccurrence = struct {
    param_name: ?[]const u8,
};

/// True when `node` (a type-expr AST) names `Self` ANYWHERE — at the leaf or
/// nested inside any compound: `*Self`, `[*]Self`, `?Self`, `[]Self`,
/// `[2]Self`, `Box(Self)`, fn/closure types, multi-return lists. The
/// `"]Self"` suffix check covers sentinel slices (`[:0]Self`), which the
/// parser folds into a flat `type_expr` name.
pub fn typeNodeContainsSelf(node: *const Node) bool {
    return switch (node.data) {
        .type_expr => |te| std.mem.eql(u8, te.name, "Self") or std.mem.endsWith(u8, te.name, "]Self"),
        .identifier => |id| std.mem.eql(u8, id.name, "Self"),
        .pointer_type_expr => |pt| typeNodeContainsSelf(pt.pointee_type),
        .many_pointer_type_expr => |mp| typeNodeContainsSelf(mp.element_type),
        .optional_type_expr => |opt| typeNodeContainsSelf(opt.inner_type),
        .slice_type_expr => |st| typeNodeContainsSelf(st.element_type),
        .array_type_expr => |at| typeNodeContainsSelf(at.element_type),
        .parameterized_type_expr => |pt| blk: {
            for (pt.args) |arg| {
                if (typeNodeContainsSelf(arg)) break :blk true;
            }
            break :blk false;
        },
        .function_type_expr => |ft| blk: {
            for (ft.param_types) |p| {
                if (typeNodeContainsSelf(p)) break :blk true;
            }
            break :blk if (ft.return_type) |rt| typeNodeContainsSelf(rt) else false;
        },
        .closure_type_expr => |ct| blk: {
            for (ct.param_types) |p| {
                if (typeNodeContainsSelf(p)) break :blk true;
            }
            break :blk if (ct.return_type) |rt| typeNodeContainsSelf(rt) else false;
        },
        .return_type_expr => |rt| blk: {
            for (rt.field_types) |f| {
                if (typeNodeContainsSelf(f)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// Era-2 erasability classifier: where (if anywhere) `method`'s signature
/// mentions `Self` outside the receiver. The receiver is already stripped by
/// the parser (`params` are the extra args only), so any hit makes the method
/// non-dispatchable — with `Self` unknown at an erased call site, the
/// signature is not expressible. Null = dispatchable.
pub fn protocolMethodSelfOccurrence(method: ast.ProtocolMethodDecl) ?SelfOccurrence {
    for (method.params, 0..) |p, i| {
        if (typeNodeContainsSelf(p)) {
            const pname: ?[]const u8 = if (i < method.param_names.len) method.param_names[i] else null;
            return .{ .param_name = pname };
        }
    }
    if (method.return_type) |rt| {
        if (typeNodeContainsSelf(rt)) return .{ .param_name = null };
    }
    return null;
}

/// Protocol ownership class ("P owns, *P views" model). The unmarked
/// default is value/own; `#identity` marks borrow-only protocols — their
/// values only ever BORROW the ctx (rvalue erasure refuses, free refuses).
pub const ProtocolOwnership = enum {
    value_own,
    identity,
};

pub const ProtocolDeclInfo = struct {
    name: []const u8,
    is_inline: bool,
    ownership: ProtocolOwnership = .value_own,
    methods: []const ProtocolMethodInfo,
};

pub const ModuleConstInfo = struct {
    value: *const Node,
    ty: TypeId,
};

/// A finite, INTEGRAL `f64` (`4.0`) → its exact `i64` value; a non-integral
/// (`4.5`), infinite, NaN, or out-of-`i64`-range float → null. THE single place
/// the "an integral float counts as an integer count" rule lives, shared by the
/// `.float_literal` leaf of `evalConstIntExpr` (a direct `[4.0]T` dim) and
/// `moduleConstInt` (a float-typed module const `N : f64 : 4.0` used as a
/// count). One source, so an integral float resolves to the SAME integer at
/// every dimension / lane / count / value-param / inline-for site; positivity
/// and u32-range are still enforced downstream by `foldDimU32`.
pub fn floatToIntExact(v: f64) ?i64 {
    if (!std.math.isFinite(v)) return null;
    if (@trunc(v) != v) return null;
    // `-2^63` is exactly representable and is `minInt(i64)`; `2^63` is the first
    // f64 above `maxInt(i64)`. Guard both so `@intFromFloat`'s range assert can
    // never trip on a valid-but-oversized integral float.
    if (v < -9223372036854775808.0 or v >= 9223372036854775808.0) return null;
    return @intFromFloat(v);
}

/// A frame in the chain of module consts currently being folded by
/// `moduleConstInt`. Stack-allocated (each recursive frame lives on the Zig
/// call stack), so cycle detection needs no allocation.
const ModuleConstFrame = struct {
    name: []const u8,
    parent: ?*const ModuleConstFrame,
};

fn moduleConstFrameContains(frame: ?*const ModuleConstFrame, name: []const u8) bool {
    var cur = frame;
    while (cur) |c| : (cur = c.parent) {
        if (std.mem.eql(u8, c.name, name)) return true;
    }
    return false;
}

/// Folding context for a module-const EXPRESSION RHS (`N :: M + 1`): a leaf name
/// resolves to another module const via `moduleConstInt`, recursively, so the
/// SAME shared `evalConstIntExpr` that folds an inline dim expression (`[M + 1]`)
/// also folds an expression hidden behind a const name. `frame` is the chain of
/// const names currently being resolved; a name already on it is a cyclic
/// definition (`N :: N`; `N :: M + 1; M :: N`) — which has no compile-time
/// integer value — so it folds to null (→ the clean "not a compile-time integer
/// constant" diagnostic) rather than recursing forever. No pack arity at module
/// scope, so `lookupPackLen` is always null.
const ModuleConstCtx = struct {
    consts: *const std.StringHashMap(ModuleConstInfo),
    table: *const types.TypeTable,
    frame: ?*const ModuleConstFrame,
    pub fn lookupDimName(self: ModuleConstCtx, name: []const u8) ?i64 {
        return moduleConstIntFramed(self.consts, self.table, name, self.frame);
    }
    pub fn lookupConstAggLen(_: ModuleConstCtx, _: []const u8) ?i64 {
        return null;
    }
    pub fn lookupConstArrayElem(_: ModuleConstCtx, _: []const u8, _: i64, _: ?ast.Span) ?i64 {
        return null;
    }
    pub fn lookupConstStructField(_: ModuleConstCtx, _: []const u8, _: []const u8) ?i64 {
        return null;
    }
    pub fn lookupPackLen(_: ModuleConstCtx, _: []const u8) ?i64 {
        return null;
    }
    // A type-query builtin call (`field_count`/`size_of`/`align_of`) needs to
    // resolve a type EXPRESSION arg, which this stateless module-const ctx cannot
    // do (no `resolveTypeArg` / type-param bindings). The body-lowering ctx folds
    // these; here it is null (a module const `N :: field_count(S)` folds through
    // the source-aware path, not this global-map ctx).
    pub fn evalConstCallInt(_: ModuleConstCtx, _: *const Node) ?i64 {
        return null;
    }
    // The GLOBAL-map fold carries no namespace-import facts (no `namespace_edges`
    // / per-source const cache), so a qualified-member const `m.CAP` can only be
    // resolved by the SOURCE-AWARE path (`SourceConstCtx` / `Lowering`). Null
    // here (issue 0192). A qualified const used inside another module const's RHS
    // folds through `SourceConstCtx`, not this ctx, so this is not a live gap.
    pub fn lookupQualifiedConst(_: ModuleConstCtx, _: []const u8, _: []const u8) ?i64 {
        return null;
    }
    pub fn lookupQualifiedConstFloat(_: ModuleConstCtx, _: []const u8, _: []const u8) ?f64 {
        return null;
    }
    pub fn qualifiedNameIsFloatTyped(_: ModuleConstCtx, _: []const u8, _: []const u8) bool {
        return false;
    }
    /// Float counterpart of `lookupDimName`, so `evalConstFloatExpr` resolves a
    /// float-const leaf whose value references another const
    /// (`G : f64 : 2.0; F : f64 : G + 0.5`) recursively through the SAME
    /// cycle-guarded frame.
    pub fn lookupFloatName(self: ModuleConstCtx, name: []const u8) ?f64 {
        return moduleConstFloatFramed(self.consts, self.table, name, self.frame);
    }
    /// True iff `name` names a FLOAT-valued const (see `moduleConstFloatValuedFramed`),
    /// resolved through the SAME cycle-guarded frame so a float-const leaf that
    /// references another const is judged consistently with `lookupFloatName`.
    pub fn nameIsFloatTyped(self: ModuleConstCtx, name: []const u8) bool {
        return moduleConstFloatValuedFramed(self.consts, self.table, name, self.frame);
    }
};

/// True iff `ty` is a float type — one half of the float-valued-const test the
/// int folder's division arm relies on. Module consts only ever carry the builtin
/// `f32` / `f64`.
pub fn isFloatConstType(ty: TypeId) bool {
    return ty == .f32 or ty == .f64;
}

/// True iff `name` is a FLOAT-valued module const — judged by the const's VALUE,
/// not only its DECLARED type, so it catches both a typed float const
/// (`K : f64 : 4.0`, `F : f64 : 2.5`) AND an UNTYPED float-EXPRESSION const
/// (`ME :: 4.0 + 1.0`), whose pass-0 placeholder type is `i64` even though its
/// value is float. The int folder's division arm consults this to tell a FLOAT
/// division apart from an integer one even when both operands fold to integers
/// (`K / 3`, `ME / 3`). `frame` cycle-guards a const whose value references
/// another const; a name already on the chain has no compile-time value → not
/// float-valued.
fn moduleConstFloatValuedFramed(consts: *const std.StringHashMap(ModuleConstInfo), table: *const types.TypeTable, name: []const u8, parent: ?*const ModuleConstFrame) bool {
    if (moduleConstFrameContains(parent, name)) return false;
    const ci = consts.get(name) orelse return false;
    if (isFloatConstType(ci.ty)) return true;
    var frame = ModuleConstFrame{ .name = name, .parent = parent };
    return isFloatValuedExpr(ci.value, ModuleConstCtx{ .consts = consts, .table = table, .frame = &frame });
}

/// A module const may serve as an integer COUNT only when its DECLARED type is
/// numeric — an integer of any width or a float (an integral float folds to its
/// int via `floatToIntExact`). `moduleConstIntFramed` consults this so a count
/// is gated on `ModuleConstInfo.ty`, not just the shape of the initializer node:
/// a `string`/`bool`/pointer/struct-typed const can never be folded into a count
/// off an integer-looking initializer (the second symptom, where
/// `N : string : 4` folded `[N]i64` to 4 by reading the `int_literal` node and
/// ignoring the `string` annotation).
pub fn isCountableConstType(table: *const types.TypeTable, ty: TypeId) bool {
    return switch (ty) {
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .usize, .isize, .f32, .f64 => true,
        else => if (ty.isBuiltin()) false else switch (table.get(ty)) {
            .signed, .unsigned => true,
            else => false,
        },
    };
}

fn moduleConstIntFramed(consts: *const std.StringHashMap(ModuleConstInfo), table: *const types.TypeTable, name: []const u8, parent: ?*const ModuleConstFrame) ?i64 {
    if (moduleConstFrameContains(parent, name)) return null;
    const ci = consts.get(name) orelse return null;
    if (!isCountableConstType(table, ci.ty)) return null;
    var frame = ModuleConstFrame{ .name = name, .parent = parent };
    return evalConstIntExpr(ci.value, ModuleConstCtx{ .consts = consts, .table = table, .frame = &frame });
}

/// A name bound to a module-global integer constant → its value, else null.
/// SINGLE source for both array-dimension resolvers — the stateful
/// body-lowering path (`Lowering.comptimeIntNamed`) and the stateless
/// registration-time path (`type_bridge.StatelessInner`). They must agree on
/// which named consts a `[N]T` dimension resolves to; if they diverge, an array
/// laid out via a type alias (`Arr :: [N]T`, stateless) gets a different length
/// than the direct form (`a : [N]T`, stateful) — that miscompile class.
/// Every const's RHS is folded through the shared `evalConstIntExpr`, so an
/// untyped (`N :: 16`) / typed (`N : i64 : 16`) literal, an integral float
/// (`N : f64 : 4.0` → 4, via `floatToIntExact`; `4.5` → null), AND an expression
/// RHS over other consts (`M :: 2; N :: M + 1` → 3) all resolve identically and
/// everywhere a count is accepted. Cyclic consts fold to null (see
/// `ModuleConstCtx`).
pub fn moduleConstInt(consts: *const std.StringHashMap(ModuleConstInfo), table: *const types.TypeTable, name: []const u8) ?i64 {
    return moduleConstIntFramed(consts, table, name, null);
}

/// FLOAT counterpart of `moduleConstInt`: a name bound to a NUMERIC module const
/// → its compile-time `f64` value (`F : f64 : 2.5` → 2.5), else null. Mirrors
/// `moduleConstIntFramed` exactly — same `isCountableConstType` gate, same cyclic-
/// definition frame — but recovers the value through `evalConstFloatExpr`, so the
/// unified float→int narrowing rule resolves a NON-INTEGRAL float-const leaf
/// (`y : i64 = F + 0.25`) the same way the int folder resolves an int-const leaf
/// (`M :: 2; y : i64 = M + 0.5`). An integral float / integer const folds through
/// the int path inside `evalConstFloatExpr` and never reaches the leaf arm that
/// calls this; this surfaces the genuinely non-integral float so `floatToIntExact`
/// can reject it.
fn moduleConstFloatFramed(consts: *const std.StringHashMap(ModuleConstInfo), table: *const types.TypeTable, name: []const u8, parent: ?*const ModuleConstFrame) ?f64 {
    if (moduleConstFrameContains(parent, name)) return null;
    const ci = consts.get(name) orelse return null;
    if (!isCountableConstType(table, ci.ty)) return null;
    var frame = ModuleConstFrame{ .name = name, .parent = parent };
    return evalConstFloatExpr(ci.value, ModuleConstCtx{ .consts = consts, .table = table, .frame = &frame });
}

pub fn moduleConstFloat(consts: *const std.StringHashMap(ModuleConstInfo), table: *const types.TypeTable, name: []const u8) ?f64 {
    return moduleConstFloatFramed(consts, table, name, null);
}

/// True iff `name` is a FLOAT-valued module const — judged by VALUE, so it covers
/// a typed float const (`K : f64 : 4.0`), an untyped float-EXPRESSION const
/// (`ME :: 4.0 + 1.0`, whose placeholder type is `i64`), and a non-integral float
/// const (`F : f64 : 2.5`). SINGLE source for the stateful (`Lowering`) and
/// stateless (`type_bridge`) division-arm float checks, so they agree on which
/// const-leaf divisions are float.
pub fn moduleConstIsFloatTyped(consts: *const std.StringHashMap(ModuleConstInfo), table: *const types.TypeTable, name: []const u8) bool {
    return moduleConstFloatValuedFramed(consts, table, name, null);
}

/// True iff `node` is a FLOAT-valued compile-time expression — a float literal,
/// a float-typed const leaf (`F : f64 : 2.5`, `K : f64 : 4.0`), a builtin float
/// numeric-limit (`f64.max`), or arithmetic over any of those. THE predicate the
/// int folder's division arm consults: `/` with a float operand is FLOAT division
/// (`5.0 / 2.0` = 2.5), and folding it with integer truncating division would
/// silently accept a non-integral float at a count / typed binding.
/// `+ - *` agree between int and float arithmetic for the integral
/// operands the int folder ever sees (a non-integral operand folds to null first),
/// so ONLY `/` needs this guard. A leaf name resolves through `ctx.nameIsFloatTyped`
/// — the same ctx that supplies `lookupDimName`/`lookupFloatName` — so an INTEGRAL
/// float const (`K : f64 : 4.0`, which folds to 4 as a standalone count) is still
/// recognised as float-valued inside a division.
///
/// Also the precise "is this a compile-time float-valued initializer" test the
/// typed-binding narrowing path (`Lowering.foldComptimeFloatInit`) uses alongside
/// `inferExprType`, so an untyped float-EXPRESSION const (`ME :: 4.0 + 1.0`,
/// placeholder type `i64`) flowing into an integer binding (`x : i64 = ME / 2`)
/// is judged float-valued even though `inferExprType` reads its placeholder type.
pub fn isFloatValuedExpr(node: *const Node, ctx: anytype) bool {
    return switch (node.data) {
        .float_literal => true,
        .int_literal => false,
        .char_literal => false,
        .identifier => |id| ctx.nameIsFloatTyped(id.name) or qualifiedDottedIsFloat(id.name, ctx),
        .type_expr => |te| ctx.nameIsFloatTyped(te.name) or qualifiedDottedIsFloat(te.name, ctx),
        .field_access => |fa| blk: {
            // A backtick RAW receiver (`` `f64.epsilon ``) is an ordinary field
            // READ on a value whose spelling shadows a builtin type, NOT the
            // numeric-limit accessor — so it is not a float leaf. Only a BARE type receiver folds to a float limit.
            const obj_name: ?[]const u8 = switch (fa.object.data) {
                .identifier => |id| if (id.is_raw) null else id.name,
                .type_expr => |te| if (te.is_raw) null else te.name,
                else => null,
            };
            if (obj_name) |on| {
                if (type_resolver.TypeResolver.floatLimitFor(on, fa.field) != null) break :blk true;
                // A QUALIFIED-import-member float const (`m.PI`, issue 0192): so
                // the int folder's division guard classifies `m.K / 3` as float
                // division exactly as it does a bare `K / 3`.
                if (ctx.qualifiedNameIsFloatTyped(on, fa.field)) break :blk true;
            }
            break :blk false;
        },
        .unary_op => |u| isFloatValuedExpr(u.operand, ctx),
        .binary_op => |b| isFloatValuedExpr(b.lhs, ctx) or isFloatValuedExpr(b.rhs, ctx),
        else => false,
    };
}

/// A namespace-qualified const written in TYPE-argument position (`Vector(m.N,
/// f32)`, a generic value-param `Vec(m.N, …)`) reaches the const folders as a
/// SINGLE dotted name — a `type_expr` / `identifier` whose `name` is `"m.N"` —
/// not the `field_access` node the EXPRESSION position (`[m.N]T`) produces.
/// Split on the first `.` and resolve the tail as a const in namespace `m`'s
/// target module (issue 0192). Null for an unqualified name (no `.`), so an
/// ordinary leaf is unaffected. (sx identifiers carry no `.`, so a dotted name
/// is always a namespace qualification; a single-level alias yields exactly one
/// `.`, and a stray multi-dot tail simply finds no const and folds to null.)
fn qualifiedDottedInt(name: []const u8, ctx: anytype) ?i64 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    return ctx.lookupQualifiedConst(name[0..dot], name[dot + 1 ..]);
}
fn qualifiedDottedFloat(name: []const u8, ctx: anytype) ?f64 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    return ctx.lookupQualifiedConstFloat(name[0..dot], name[dot + 1 ..]);
}
fn qualifiedDottedIsFloat(name: []const u8, ctx: anytype) bool {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return false;
    return ctx.qualifiedNameIsFloatTyped(name[0..dot], name[dot + 1 ..]);
}

/// Evaluate a constant integer expression to its value. THE single
/// integer-expression folder for the compiler — array dimensions (`[N]T`,
/// `[M + 1]T`), Vector lane counts (`Vector(N, f32)`), generic value-param
/// args (`Vec(N, f32)`), and `inline for 0..M` bounds all route here so they
/// cannot disagree on what a given expression evaluates to (the
/// two-resolver class of bug). Folds integer `+ - * / %` and unary negate over
/// int literals, integral float literals (`[4.0]T` → 4, via `floatToIntExact`),
/// and named module / comptime consts — recursively, so nested and parenthesised
/// forms (`[M + N - 1]`, `[(M + 1) * 2]`) fold (a grouping `(…)` carries no AST
/// node; the parser returns the inner expression).
///
/// ONE exception keeps a float operation out of integer arithmetic: a `/` whose
/// lhs/rhs is float-valued (`5.0 / 2.0`, `K / 3` with `K : f64 : 4.0`) is FLOAT
/// division, NOT integer truncation, so this folder refuses it (`isFloatValuedExpr`)
/// and lets `evalConstFloatExpr` + the unified narrowing rule see the true value
///. `+ - *` need no such guard — they agree between int and
/// float arithmetic for the integral operands this folder ever sees.
///
/// Leaves resolve through the ctx, so each call site shares the SAME folding
/// logic while contributing its own bindings:
///   - `ctx.lookupDimName(name)` — a name bound to a compile-time integer. The
///     stateful body-lowering ctx sees comptime constants, generic `$N` value
///     bindings, and module consts; the stateless registration ctx sees module
///     consts only.
///   - `ctx.lookupPackLen(name)` — a `<pack>.len` leaf → the pack's
///     monomorphised arity. Only the body-lowering ctx knows pack arities; the
///     stateless ctx returns null.
///
/// Returns null when any operand is not a compile-time integer (a runtime value,
/// a non-comptime call, an unbound name) or the arithmetic overflows / divides
/// by zero: the caller then emits the clean compile-halting diagnostic, never a
/// fabricated length / lane count / value-param.
pub fn evalConstIntExpr(node: *const Node, ctx: anytype) ?i64 {
    return switch (node.data) {
        .int_literal => |lit| lit.value,
        .char_literal => |lit| lit.value,
        // An integral float literal (`[4.0]T`) folds to its integer; `4.5` → null.
        .float_literal => |lit| floatToIntExact(lit.value),
        .identifier => |id| ctx.lookupDimName(id.name) orelse qualifiedDottedInt(id.name, ctx),
        .type_expr => |te| ctx.lookupDimName(te.name) orelse qualifiedDottedInt(te.name, ctx),
        .field_access => |fa| blk: {
            // A backtick RAW receiver (`` `i64.max ``, `` `f64.epsilon ``) is an
            // ordinary field READ on a value whose spelling shadows a builtin
            // type name, NOT a numeric-limit / pack-arity accessor — so it is
            // never a compile-time leaf here; its field is a runtime value
            //. Only a BARE type/name receiver folds a
            // `<pack>.len` / `<IntType>.min`/`.max`. Mirrors the same `is_raw`
            // guard `isFloatValuedExpr` already applies, so the const cluster
            // (this folder, `evalConstFloatExpr`, `isFloatValuedExpr`) agrees.
            const obj_name: ?[]const u8 = switch (fa.object.data) {
                .identifier => |id| if (id.is_raw) null else id.name,
                .type_expr => |te| if (te.is_raw) null else te.name,
                else => null,
            };
            if (obj_name) |on| {
                // `<pack>.len` resolves to the monomorphised arity (e.g. an
                // `inline for 0..xs.len` bound); `<array const>.len` to the
                // const's element count.
                if (std.mem.eql(u8, fa.field, "len")) {
                    if (ctx.lookupPackLen(on)) |n| break :blk n;
                    break :blk ctx.lookupConstAggLen(on);
                }
                // `<IntType>.min` / `.max` — the same fold the value path uses
                // (type_resolver), so `[u8.max]T` agrees with `u8.max` in
                // expression position. A `u64.max` (= -1 as i64) folds here too;
                // `foldDimU32` then rejects it as a negative array dimension.
                if (type_resolver.TypeResolver.integerLimitFor(on, fa.field)) |v| break :blk v;
                // A struct const's integer field (`LIT.r`) folds to the
                // SELECTED author's field value.
                if (ctx.lookupConstStructField(on, fa.field)) |v| break :blk v;
                // A QUALIFIED-import-member const (`m.CAP`, issue 0192): `on`
                // names a namespace alias and `fa.field` a const in its target
                // module. Tried last so a same-named struct-const / numeric-limit
                // receiver keeps its existing meaning.
                if (ctx.lookupQualifiedConst(on, fa.field)) |v| break :blk v;
            }
            // Any other field access is not a compile-time integer leaf.
            break :blk null;
        },
        // `K[<const idx>]` over an ARRAY const folds to the element's value
        // (bounds-checked at fold time — out of range diagnoses, never wraps).
        .index_expr => |ie| blk: {
            const on: ?[]const u8 = switch (ie.object.data) {
                .identifier => |id| if (id.is_raw) null else id.name,
                else => null,
            };
            const name = on orelse break :blk null;
            const idx = evalConstIntExpr(ie.index, ctx) orelse break :blk null;
            break :blk ctx.lookupConstArrayElem(name, idx, node.span);
        },
        // A pure int-returning type-query builtin call (`field_count(T)`,
        // `size_of(T)`, `align_of(T)`) folds to its constant when the ctx can
        // resolve the type arg — the body-lowering ctx (with type-param bindings)
        // can; the stateless registration ctxs return null. This is what lets a
        // reflection-derived count drive an `inline for` bound / array dim, the
        // same as a plain `K :: 3` const.
        .call => ctx.evalConstCallInt(node),
        .unary_op => |u| switch (u.op) {
            .negate => {
                const v = evalConstIntExpr(u.operand, ctx) orelse return null;
                return if (v == std.math.minInt(i64)) null else -v;
            },
            else => null,
        },
        .binary_op => |b| {
            const l = evalConstIntExpr(b.lhs, ctx) orelse return null;
            const r = evalConstIntExpr(b.rhs, ctx) orelse return null;
            return switch (b.op) {
                .add => std.math.add(i64, l, r) catch null,
                .sub => std.math.sub(i64, l, r) catch null,
                .mul => std.math.mul(i64, l, r) catch null,
                // A division with a FLOAT operand is FLOAT division (`5.0 / 2.0`
                // = 2.5, `K / 3` with `K : f64 : 4.0` = 1.333…), NOT integer
                // truncating division — refuse to fold it here so the value
                // surfaces through `evalConstFloatExpr` + the unified float→int
                // rule (integral folds, non-integral errors) instead of silently
                // truncating to an integer. A genuine
                // integer `/` (both operands integer-valued) still truncates.
                .div => if (isFloatValuedExpr(b.lhs, ctx) or isFloatValuedExpr(b.rhs, ctx))
                    null
                else
                    std.math.divTrunc(i64, l, r) catch null,
                .mod => if (r == 0) null else @rem(l, r),
                else => null,
            };
        },
        else => null,
    };
}

/// Compile-time FLOAT value of a numeric expression, or null when it is not a
/// compile-time constant (some leaf is a runtime value) or is not a numeric
/// shape. THE float counterpart to `evalConstIntExpr`, used by the unified
/// float→int narrowing rule to (1) tell a compile-time float initializer apart
/// from a runtime one and (2) recover its value for `floatToIntExact` (integral
/// → fold) / the non-integral diagnostic.
///
/// An all-integer-foldable subtree is delegated to `evalConstIntExpr` (so module
/// / comptime consts, `<IntType>.min`/`.max`, and integer arithmetic resolve
/// through the SINGLE int folder — no parallel integer logic here); only the
/// genuinely float-producing shapes — a float literal, a NON-INTEGRAL float-const
/// leaf, a builtin FLOAT numeric-limit accessor (`f64.max`, `f32.epsilon`,
/// `f64.true_min`, …), a unary negate, and `+ - * / %` arithmetic involving a
/// float — are evaluated here in `f64`. A comparison or any other shape is not a
/// compile-time float leaf → null.
///
/// This evaluator is at PARITY with `evalConstIntExpr` — every leaf / node kind
/// the int folder recognises (literal, named const leaf, numeric-limit
/// field-access, unary negate, `+ - * / %`) is mirrored here in `f64` (delegating
/// integer subtrees), so no compile-time-const float shape escapes the unified
/// float→int narrowing rule at one site while folding at another.
///
/// A NAMED-const leaf resolves through `ctx.lookupFloatName`, the float twin of
/// the `lookupDimName` the int folder uses: a numeric module const whose value is
/// a non-integral float (`F : f64 : 2.5`) surfaces here so `F + 0.25` (= 2.75) is
/// recognised as a compile-time float and rejected by the narrowing rule, exactly
/// as `M + 0.5` (with `M :: 2`) already is. An INTEGRAL float / integer const
/// (`K : f64 : 4.0`, `M :: 2`) is resolved by the `evalConstIntExpr` delegation
/// above and never reaches the leaf arm.
pub fn evalConstFloatExpr(node: *const Node, ctx: anytype) ?f64 {
    // Delegate any integer-foldable subtree (incl. an INTEGRAL float like `4.0`
    // / `M + 2.0`) to the single int folder, then promote — keeps named consts
    // and `.min`/`.max` resolution in one place.
    if (evalConstIntExpr(node, ctx)) |iv| return @floatFromInt(iv);
    return switch (node.data) {
        .float_literal => |lit| lit.value,
        // A name bound to a numeric module const whose value is a non-integral
        // float (the integral / integer cases were caught by the int delegation).
        .identifier => |id| ctx.lookupFloatName(id.name) orelse qualifiedDottedFloat(id.name, ctx),
        .type_expr => |te| ctx.lookupFloatName(te.name) orelse qualifiedDottedFloat(te.name, ctx),
        .field_access => |fa| blk: {
            // A numeric-limit accessor on a builtin FLOAT type (`f64.true_min`,
            // `f32.epsilon`, `f64.max`, …) is a compile-time float leaf — the
            // float twin of `evalConstIntExpr`'s `<IntType>.min`/`.max` arm, via
            // the SAME `type_resolver` fold (the facility `lowerNumericLimit`
            // uses) so the two evaluators can't disagree on what `f64.max`
            // evaluates to. Integer limits and `<pack>.len` are already resolved
            // by the int delegation above, so only the float-limit case remains.
            // A backtick RAW receiver (`` `f64.epsilon ``) is an ordinary field
            // READ on a value that shadows a builtin float type name, NOT the
            // numeric-limit accessor — its field is a runtime value, never a
            // compile-time leaf. Mirrors the `is_raw`
            // guard `isFloatValuedExpr` already applies; only a BARE type receiver
            // folds a float limit.
            const obj_name: ?[]const u8 = switch (fa.object.data) {
                .identifier => |id| if (id.is_raw) null else id.name,
                .type_expr => |te| if (te.is_raw) null else te.name,
                else => null,
            };
            if (obj_name) |on| {
                if (type_resolver.TypeResolver.floatLimitFor(on, fa.field)) |v| break :blk v;
                // A QUALIFIED-import-member float const (`m.PI`, issue 0192) —
                // the float twin of the int folder's qualified-const arm.
                if (ctx.lookupQualifiedConstFloat(on, fa.field)) |v| break :blk v;
            }
            break :blk null;
        },
        .unary_op => |u| switch (u.op) {
            .negate => {
                const v = evalConstFloatExpr(u.operand, ctx) orelse return null;
                return -v;
            },
            else => null,
        },
        .binary_op => |b| {
            const l = evalConstFloatExpr(b.lhs, ctx) orelse return null;
            const r = evalConstFloatExpr(b.rhs, ctx) orelse return null;
            return switch (b.op) {
                .add => l + r,
                .sub => l - r,
                .mul => l * r,
                .div => if (r == 0.0) null else l / r,
                // `%` mirrors `evalConstIntExpr`'s `.mod` (and codegen's `frem`):
                // `@rem` truncated remainder, so `5.5 % 2.0` = 1.5 surfaces as a
                // non-integral float instead of silently truncating.
                .mod => if (r == 0.0) null else @rem(l, r),
                else => null,
            };
        },
        else => null,
    };
}

/// The outcome of folding a compile-time COUNT expression to an `i64` under the
/// unified float→int narrowing rule. THE single int-or-
/// integral-float count fold: `foldDimU32` (array dim / Vector lane / u32 value-
/// param) and the non-`u32` value-param gate both route through `foldCountI64`,
/// so no count site can disagree on which floats fold (the unify-or-
/// diverge rule extended to floats).
pub const CountFold = union(enum) {
    /// An integer expression, or an INTEGRAL compile-time float (`[F + 1.5]` → 4).
    int: i64,
    /// A compile-time float that is not integral (`[F + 0.25]` → 2.75).
    non_integral: f64,
    /// Not a compile-time constant (runtime value, unbound name, or overflow).
    not_const,
};

/// Fold `node` to an `i64` count, accepting an INTEGRAL compile-time float as the
/// integer it equals (`4.0`, `F + 1.5`, a const folding to either) and surfacing a
/// NON-integral compile-time float distinctly so the caller can reject it. Reuses
/// the SAME facility the typed local/field/param/const sites use — `evalConstIntExpr`
/// first (so int literals, named consts, `.min`/`.max`, and a DIRECT integral float
/// literal `4.0` all fold through the single int folder), then, only when that
/// yields no integer, `evalConstFloatExpr` + `floatToIntExact` (so an integral SUM
/// built from a non-integral float-const leaf, `F + 1.5` = 4.0, still folds, while
/// `F + 0.25` = 2.75 reports as non-integral). No parallel integral check.
pub fn foldCountI64(node: *const Node, ctx: anytype) CountFold {
    if (evalConstIntExpr(node, ctx)) |v| return .{ .int = v };
    const fv = evalConstFloatExpr(node, ctx) orelse return .not_const;
    if (floatToIntExact(fv)) |iv| return .{ .int = iv };
    return .{ .non_integral = fv };
}

/// The outcome of folding a comptime count and narrowing it to a `u32`
/// (array dimension / Vector lane / value-param count). `foldDimU32` is the
/// SINGLE place a folded integer becomes a `u32`, so the i64→u32 narrowing is
/// range-checked exactly once and no call site does a bare `@intCast` that could
/// panic the compiler on a valid-but-oversized fold (a literal `5_000_000_000`
/// is a valid `i64` yet `> maxInt(u32)`). Each call site maps a
/// non-`.ok` variant onto its own clean diagnostic + `.unresolved` / abort.
pub const DimU32 = union(enum) {
    /// Folded to a `u32` in `[min, maxInt(u32)]`.
    ok: u32,
    /// Not a compile-time integer (runtime value, unbound name, or overflow).
    not_const,
    /// Folded, but below the required minimum (a negative dim, a non-positive lane).
    below_min: i64,
    /// Folded, but greater than `maxInt(u32)` — too large for a `u32` count.
    too_large: i64,
    /// A compile-time float that is not integral (`[F + 0.25]`) — under the unified
    /// float→int rule it cannot serve as an integer count; reported, never truncated.
    non_integral_float: f64,
};

/// Fold `node` to a `u32` count through `foldCountI64` (the unified int-or-
/// integral-float fold), then range-check against `[min, maxInt(u32)]`. THE single
/// fold-to-u32 for every array dimension, Vector lane, and value-param count —
/// routing all of them here guarantees the narrowing is checked once and can never
/// abort the compiler. The fold itself stays in `i64`; only this one
/// conversion is the `u32` gate.
pub fn foldDimU32(node: *const Node, ctx: anytype, min: u32) DimU32 {
    const v = switch (foldCountI64(node, ctx)) {
        .int => |iv| iv,
        .non_integral => |fv| return .{ .non_integral_float = fv },
        .not_const => return .not_const,
    };
    if (v < @as(i64, min)) return .{ .below_min = v };
    if (v > std.math.maxInt(u32)) return .{ .too_large = v };
    return .{ .ok = @intCast(v) };
}

/// THE single source of array-dimension diagnostic wording. Both array-dim
/// resolvers — the stateful body-lowering path (`Lowering.resolveArrayLen`) and
/// the stateless registration-time path (the alias-registration site, via
/// `type_bridge.foldArrayDim`) — emit through here, so an oversized / negative /
/// non-const dimension reports the SAME message regardless of whether it was
/// written directly (`a : [N]T`) or via a type alias (`Arr :: [N]T`). Folding
/// the wording into one place is the diagnostic-accuracy half of the
/// unify-or-diverge story: `foldDimU32` is the single fold, this is the single
/// message map. Only call with a non-`.ok` result (the `.ok` arm is a no-op).
pub fn reportDimError(diag: *errors.DiagnosticList, span: ?ast.Span, result: DimU32) void {
    switch (result) {
        .ok => {},
        .below_min => |v| diag.addFmt(.err, span, "array dimension must be non-negative, got {}", .{v}),
        .too_large => |v| diag.addFmt(.err, span, "array dimension {} does not fit in u32", .{v}),
        .not_const => diag.addFmt(.err, span, "array dimension must be a compile-time integer constant", .{}),
        .non_integral_float => |v| diag.addFmt(.err, span, "array dimension must be an integer, but '{d}' is a non-integral float", .{v}),
    }
}

/// The inclusive `[min, max]` integer range a value of a fixed-width integer
/// type can hold, addressed by the type NAME as written on a generic value-param
/// constraint (`$K: u32`). null for a non-integer / unrecognised name — the
/// caller then skips the range check (folds without bounding) rather than
/// guessing. Bounds are clamped into `i64`: a `u64`/`usize` ceiling exceeds
/// `i64`, but a folded value-param arg is already an `i64`, so `maxInt(i64)` is
/// its effective ceiling and the only failure a `u64` param can have is a
/// negative arg. THE single declared-type → range map for the value-param gate,
/// so the bound at every binding site agrees. The `u32` count case is gated
/// through `foldDimU32` instead (the documented dim/lane/value-param u32 gate);
/// both encode the same `[0, maxInt(u32)]`.
pub const IntRange = struct { min: i64, max: i64 };
pub fn intTypeRange(name: []const u8) ?IntRange {
    const eql = std.mem.eql;
    if (eql(u8, name, "u8")) return .{ .min = 0, .max = std.math.maxInt(u8) };
    if (eql(u8, name, "u16")) return .{ .min = 0, .max = std.math.maxInt(u16) };
    if (eql(u8, name, "u32")) return .{ .min = 0, .max = std.math.maxInt(u32) };
    if (eql(u8, name, "u64") or eql(u8, name, "usize")) return .{ .min = 0, .max = std.math.maxInt(i64) };
    if (eql(u8, name, "i8")) return .{ .min = std.math.minInt(i8), .max = std.math.maxInt(i8) };
    if (eql(u8, name, "i16")) return .{ .min = std.math.minInt(i16), .max = std.math.maxInt(i16) };
    if (eql(u8, name, "i32")) return .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32) };
    if (eql(u8, name, "i64") or eql(u8, name, "isize") or eql(u8, name, "int"))
        return .{ .min = std.math.minInt(i64), .max = std.math.maxInt(i64) };
    return null;
}

pub const GlobalInfo = struct { id: inst.GlobalId, ty: TypeId };

/// One `#context_extend` declaration, collected program-wide by
/// `collectContextExtensions` (design/context-extension.md). Three consumers
/// read these entries: Context assembly, the no-context registered-field
/// diagnostic, and LSP per-field provenance — so each entry keeps its spans
/// and declaring file alongside the field data.
pub const ContextFieldDecl = struct {
    /// Context field name (the program-global Context namespace, L4).
    name: []const u8,
    /// Span of the field-name token in the declaring file.
    name_span: ast.Span,
    /// Declared field type (unresolved AST — resolution happens at assembly).
    type_expr: *const ast.Node,
    /// Declared default value; null = missing (rejected, L5).
    default_expr: ?*const ast.Node,
    /// Span of the whole `#context_extend … ;` declaration.
    span: ast.Span,
    /// Declaring source file — `Node.source_file` as stamped by import
    /// resolution. This is the same normalized spelling the program index
    /// uses for module identity everywhere (the by-source caches), so it
    /// doubles as the module path and as the L6 primary sort key.
    module_path: []const u8,
    /// False when the entry failed collection validation (L4 collision / L5
    /// missing default — the error is already emitted). Assembly and default
    /// emission skip invalid entries; the O3 field enumeration keeps them.
    valid: bool = true,
};

/// Single lowering access point for declaration-name / import / visibility
/// facts. The architecture stream (`current/PLAN-ARCH.md`, phase A1) extracts
/// these out of the `Lowering` state bag incrementally. `Lowering` embeds one
/// `ProgramIndex` by value and reaches every moved fact through
/// `self.program_index.<field>`; later phases hand collaborator modules a
/// `*ProgramIndex` instead of `*Lowering`.
///
/// OWNS the declaration maps below. BORROWS `module_scopes` / `import_graph` /
/// `flat_import_graph` / `module_decls` / `namespace_edges` / `decl_table`
/// (pointers into maps owned by the compilation driver, `core.zig`) — those are
/// read-only views and are never freed here.
///
/// Every owned map allocates through the compilation allocator passed to
/// `init` (arena-backed in both the driver and the tests;
/// no `page_allocator` field defaults). Written only by the
/// declaration scan / registration code in `Lowering`; read everywhere else.
pub const ProgramIndex = struct {
    /// The lowering/compilation allocator (`module.alloc`), retained so the
    /// source-keyed caches below can lazily create their inner per-source maps.
    /// Lives for the whole compilation; the inner maps are freed in `deinit`.
    alloc: std.mem.Allocator,

    // ── Import / visibility ──
    /// Declaration name → is the function imported (declared `extern`)?
    import_flags: std.StringHashMap(bool),
    /// Per-module visible names, keyed by source file. Borrowed view.
    module_scopes: ?*std.StringHashMap(std.StringHashMap(void)) = null,
    /// Module path → set of directly imported paths (param_impl visibility
    /// filter). Borrowed view.
    import_graph: ?*std.StringHashMap(std.StringHashMap(void)) = null,
    /// Module path → set of directly FLAT-imported paths — the subset of
    /// `import_graph` edges from a bare `#import` (never a namespaced
    /// `ns :: #import`). The bare-name disambiguation walks this to
    /// decide which same-name authors a flat importer can reach. Borrowed view.
    flat_import_graph: ?*std.StringHashMap(std.StringHashMap(void)) = null,
    /// Per-module scalar raw-decl index (`path → name → RawDeclRef`), built by
    /// `imports.buildImportFacts`. The unified resolver's raw-fact store.
    /// Borrowed view.
    module_decls: ?*imports.ModuleDecls = null,
    /// Namespace import edges (`importer → alias → NamespaceTarget`), built by
    /// `imports.buildImportFacts`, carrying each alias's resolved target path.
    /// Borrowed view.
    namespace_edges: ?*imports.NamespaceEdges = null,
    /// Stable `DeclId` for every declaration, built by `imports.buildDeclTable`
    /// in parallel with the import facts. Borrowed view; nothing in lowering
    /// consumes it for selection yet (additive — S4 makes it the fact-store key).
    decl_table: ?*imports.DeclTable = null,
    // ── Declaration maps ──
    /// Function name → AST decl.
    fn_ast_map: std.StringHashMap(*const ast.FnDecl),
    /// Module-qualified function name (`ns.fn`) → its declaring source file.
    /// A qualified alias is registered in `fn_ast_map` WITHOUT an eager
    /// `declareFunction`, so `lazyLowerFunction` lowers it through the
    /// null-FuncId `lowerFunction` path with no `Function.source_file` to
    /// restore. This carries the alias's OWN module source so its body lowers
    /// in the right visibility context — its intra-module / own-import callees
    /// resolve. Keyed/allocated with the lowering allocator.
    qualified_fn_source: std.StringHashMap([]const u8),
    /// sx alias → RuntimeClassDecl (jni_class / objc_class / swift_class / ... — registered in scan pass).
    runtime_class_map: std.StringHashMap(*const ast.RuntimeClassDecl),
    /// `#run` global name → GlobalId.
    global_names: std.StringHashMap(GlobalInfo),
    /// Type alias name → target TypeId. The single-source alias table; passed
    /// explicitly to `TypeResolver` / `type_bridge` resolution (no borrow).
    type_alias_map: std.StringHashMap(TypeId),
    /// Generic struct name → template.
    struct_template_map: std.StringHashMap(StructTemplate),
    /// `DeclId` → generic struct template — the DeclId-keyed analogue of
    /// `struct_template_map`, built in parallel during `registerStructDecl`.
    /// Nothing reads it for selection yet; `struct_template_map` stays the live
    /// consumer until the S4 cutover.
    struct_template_by_decl: std.AutoHashMap(imports.DeclId, StructTemplate),
    /// Protocol name → protocol info.
    protocol_decl_map: std.StringHashMap(ProtocolDeclInfo),
    /// Protocol name → AST node.
    protocol_ast_map: std.StringHashMap(*const ast.ProtocolDecl),
    /// Module-level value constants (e.g. AF_INET :i32: 2).
    module_const_map: std.StringHashMap(ModuleConstInfo),
    /// UFCS alias name → target function name.
    ufcs_alias_map: std.StringHashMap([]const u8),

    // ── Source-keyed semantic caches (R5 §#4) ──
    // The source-partitioned analogues of `type_alias_map` / `module_const_map`
    // / `global_names`, keyed `source path → name → X`. Written by the same scan
    // (`scanDecls` in lower.zig), keyed by the registering decl's source. The
    // global maps above stay the ONLY readers for now; the read-side cutover to
    // `selectedAuthor.source` lands in a later phase. These maps OWN their inner
    // per-source maps and free them in `deinit`.
    /// Type alias name → target TypeId, partitioned by declaring source.
    type_aliases_by_source: std.StringHashMap(std.StringHashMap(TypeId)),
    /// Module-level value const → info, partitioned by declaring source.
    module_consts_by_source: std.StringHashMap(std.StringHashMap(ModuleConstInfo)),
    /// `#run` / top-level global name → GlobalInfo, partitioned by declaring source.
    globals_by_source: std.StringHashMap(std.StringHashMap(GlobalInfo)),

    // ── Context extension (design/context-extension.md) ──
    /// Every `#context_extend` declaration in the compilation, sorted per L6
    /// by (declaring module path, field name). Collected UNCONDITIONALLY —
    /// also in no-context builds, where the declarations are inert but the
    /// list still powers the registered-field diagnostic. Set once by
    /// `collectContextExtensions`; entries that failed validation (L4
    /// collision / L5 missing default) are kept with `valid = false` so
    /// downstream diagnostics can still enumerate them.
    context_extensions: []ContextFieldDecl = &.{},

    pub fn init(alloc: std.mem.Allocator) ProgramIndex {
        return .{
            .alloc = alloc,
            .import_flags = std.StringHashMap(bool).init(alloc),
            .fn_ast_map = std.StringHashMap(*const ast.FnDecl).init(alloc),
            .qualified_fn_source = std.StringHashMap([]const u8).init(alloc),
            .global_names = std.StringHashMap(GlobalInfo).init(alloc),
            .runtime_class_map = std.StringHashMap(*const ast.RuntimeClassDecl).init(alloc),
            .type_alias_map = std.StringHashMap(TypeId).init(alloc),
            .struct_template_map = std.StringHashMap(StructTemplate).init(alloc),
            .struct_template_by_decl = std.AutoHashMap(imports.DeclId, StructTemplate).init(alloc),
            .protocol_decl_map = std.StringHashMap(ProtocolDeclInfo).init(alloc),
            .protocol_ast_map = std.StringHashMap(*const ast.ProtocolDecl).init(alloc),
            .module_const_map = std.StringHashMap(ModuleConstInfo).init(alloc),
            .ufcs_alias_map = std.StringHashMap([]const u8).init(alloc),
            .type_aliases_by_source = std.StringHashMap(std.StringHashMap(TypeId)).init(alloc),
            .module_consts_by_source = std.StringHashMap(std.StringHashMap(ModuleConstInfo)).init(alloc),
            .globals_by_source = std.StringHashMap(std.StringHashMap(GlobalInfo)).init(alloc),
        };
    }

    pub fn deinit(self: *ProgramIndex) void {
        // Owned maps only — module_scopes / import_graph / flat_import_graph /
        // module_decls / namespace_edges / decl_table are borrowed.
        self.import_flags.deinit();
        self.fn_ast_map.deinit();
        self.qualified_fn_source.deinit();
        self.runtime_class_map.deinit();
        self.global_names.deinit();
        self.type_alias_map.deinit();
        self.struct_template_map.deinit();
        self.struct_template_by_decl.deinit();
        self.protocol_decl_map.deinit();
        self.protocol_ast_map.deinit();
        self.module_const_map.deinit();
        self.ufcs_alias_map.deinit();
        deinitBySource(TypeId, &self.type_aliases_by_source);
        deinitBySource(ModuleConstInfo, &self.module_consts_by_source);
        deinitBySource(GlobalInfo, &self.globals_by_source);
    }

    /// Free every inner per-source map, then the outer map.
    fn deinitBySource(comptime V: type, outer: *std.StringHashMap(std.StringHashMap(V))) void {
        var it = outer.valueIterator();
        while (it.next()) |inner| inner.deinit();
        outer.deinit();
    }

    /// Insert `name → value` into the per-source map for `source`, creating the
    /// inner map on first use. OOM is swallowed to mirror the `catch {}` global
    /// writes this shadows.
    fn putBySource(comptime V: type, outer: *std.StringHashMap(std.StringHashMap(V)), alloc: std.mem.Allocator, source: []const u8, name: []const u8, value: V) void {
        const gop = outer.getOrPut(source) catch return;
        if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(V).init(alloc);
        gop.value_ptr.put(name, value) catch {};
    }

    pub fn putTypeAliasBySource(self: *ProgramIndex, source: []const u8, name: []const u8, tid: TypeId) void {
        putBySource(TypeId, &self.type_aliases_by_source, self.alloc, source, name, tid);
    }

    pub fn putModuleConstBySource(self: *ProgramIndex, source: []const u8, name: []const u8, info: ModuleConstInfo) void {
        putBySource(ModuleConstInfo, &self.module_consts_by_source, self.alloc, source, name, info);
    }

    pub fn putGlobalBySource(self: *ProgramIndex, source: []const u8, name: []const u8, info: GlobalInfo) void {
        putBySource(GlobalInfo, &self.globals_by_source, self.alloc, source, name, info);
    }

    /// Mirror a `module_const_map.remove` into the per-source map: drop `name`
    /// from `source`'s inner map (a no-op if the source/name is absent).
    pub fn removeModuleConstBySource(self: *ProgramIndex, source: []const u8, name: []const u8) void {
        if (self.module_consts_by_source.getPtr(source)) |inner| _ = inner.remove(name);
    }
};
