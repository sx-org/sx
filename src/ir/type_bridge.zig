const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast.zig");
const Node = ast.Node;
const ir_types = @import("types.zig");
const TypeId = ir_types.TypeId;
const TypeInfo = ir_types.TypeInfo;
const TypeTable = ir_types.TypeTable;
const StringId = ir_types.StringId;
const type_resolver = @import("type_resolver.zig");
const program_index_mod = @import("program_index.zig");
const ModuleConstInfo = program_index_mod.ModuleConstInfo;

/// The single-source type-alias table (`ProgramIndex.type_alias_map`), threaded
/// explicitly through every name-resolving entry point so a bare name like
/// `ShaderHandle` (declared `ShaderHandle :: u32`) resolves to its target
/// rather than a fresh empty-struct stub. Replaces the old `TypeTable.aliases`
/// borrow (A2.3): there is no hidden alias state — callers pass the map (or
/// `null` for contexts that never see aliases, e.g. unit tests).
pub const AliasMap = ?*const std.StringHashMap(TypeId);

/// The module-global constant table (`ProgramIndex.module_const_map`), threaded
/// alongside the alias map so a named-const array dimension (`N :: 16; [N]T`)
/// resolves to the same length as a literal dimension on EVERY registration-time
/// path — type aliases (`Arr :: [N]T`), inline union/enum field types — not just
/// the stateful body-lowering path. Without it the stateless dim resolver had no
/// way to evaluate a named const and silently fabricated a 0 length.
/// `null` for contexts with no const table (e.g. unit tests).
pub const ConstMap = ?*const std.StringHashMap(ModuleConstInfo);

/// Binding-free element-recursion adapter for `TypeResolver.resolveCompound`:
/// nested element types resolve through `type_bridge.resolveAstType` (the
/// registration-time path — no generic/pack bindings). Lets type_bridge reuse
/// the single canonical structural-shape constructor instead of carrying its
/// own compound algorithm (A2.3b).
const StatelessInner = struct {
    table: *TypeTable,
    alias_map: AliasMap,
    consts: ConstMap,
    pub fn resolveInner(self: StatelessInner, node: *const Node) TypeId {
        return resolveAstType(node, self.table, self.alias_map, self.consts);
    }
    /// Bare TYPE-NAME twin of `resolveInner`, for callers that hold a name
    /// rather than an AST node (an error-set reference `!Named`). Flat:
    /// registered name → alias → stub, no visibility scoping.
    pub fn resolveName(self: StatelessInner, name: []const u8) TypeId {
        return resolveTypeName(name, self.table, self.alias_map, false);
    }
    /// Fixed-array dimension at registration time: a literal `[16]T`, a named
    /// module-global const `N :: 16; [N]T` (typed `N : i64 : 16` too), or a
    /// constant-foldable expression over those (`[M + 1]`, `[(M + 1) * 2]`).
    /// Folds and narrows through the shared `program_index.foldDimU32` (min 0) —
    /// the SAME range-checked fold-to-u32 the stateful body-lowering path uses —
    /// so a dimension resolves to one length on every registration-time path
    /// (aliases, inline union/enum fields) and matches the direct form (issue
    /// 0083), and an oversized-but-valid `i64` dim returns null instead of
    /// panicking the `@intCast`. Returns null when the dimension
    /// isn't a compile-time integer (a runtime value / non-comptime call, or a
    /// name not bound to an integer const), is negative, or doesn't fit a `u32`.
    /// Null propagates to `resolveCompound`, which yields the `.unresolved`
    /// sentinel rather than fabricating a 0 length that silently gives a 0-byte
    /// array and out-of-bounds element access; the registration caller surfaces
    /// the unresolved alias/type as a clean diagnostic.
    pub fn resolveArrayLen(self: StatelessInner, len_node: *const Node) ?u32 {
        return switch (program_index_mod.foldDimU32(len_node, self, 0)) {
            .ok => |n| n,
            else => null,
        };
    }
    /// Leaf-name lookup for the shared dimension evaluator: a name that resolves
    /// to a module-global integer constant → its value. Shares
    /// `program_index.moduleConstInt` with the stateful body-lowering resolver so
    /// the two paths cannot disagree on which named consts a dimension resolves
    /// to. The non-negative check is applied once, on the final
    /// dimension value in `resolveArrayLen` — not here, so an intermediate
    /// operand may legitimately be negative.
    pub fn lookupDimName(self: StatelessInner, name: []const u8) ?i64 {
        const consts = self.consts orelse return null;
        return program_index_mod.moduleConstInt(consts, self.table, name);
    }
    /// Pack-length leaf for the shared integer-expression evaluator. The
    /// registration-time path has no pack-arity information (packs are bound
    /// during body lowering), so a `<pack>.len` dimension is never a
    /// compile-time integer here → null → the clean unresolved-dim diagnostic.
    pub fn lookupConstAggLen(_: StatelessInner, _: []const u8) ?i64 {
        return null;
    }
    pub fn lookupConstArrayElem(_: StatelessInner, _: []const u8, _: i64, _: ?ast.Span) ?i64 {
        return null;
    }
    pub fn lookupConstStructField(_: StatelessInner, _: []const u8, _: []const u8) ?i64 {
        return null;
    }
    pub fn lookupPackLen(_: StatelessInner, _: []const u8) ?i64 {
        return null;
    }
    // A type-query builtin call (`field_count`/`size_of`/`align_of`) needs to
    // resolve a type-expr arg (and, for `field_count`, type-param bindings),
    // which the registration-time path lacks. Folded on the body-lowering path
    // (`Lowering`); null here → the clean unresolved-dim diagnostic.
    pub fn evalConstCallInt(_: StatelessInner, _: *const Node) ?i64 {
        return null;
    }
    // The registration-time path holds only the flat global const map — no
    // namespace-import facts (`namespace_edges` / per-source cache) — so a
    // qualified-member const `m.CAP` is not a compile-time leaf here (issue
    // 0192). It resolves on the stateful body-lowering path (`Lowering`); a
    // qualified-const dimension reached ONLY through this path (e.g. a type
    // alias `Arr :: [m.CAP]T`) stays unresolved and surfaces the clean dim
    // diagnostic rather than a fabricated length.
    pub fn lookupQualifiedConst(_: StatelessInner, _: []const u8, _: []const u8) ?i64 {
        return null;
    }
    pub fn lookupQualifiedConstFloat(_: StatelessInner, _: []const u8, _: []const u8) ?f64 {
        return null;
    }
    pub fn qualifiedNameIsFloatTyped(_: StatelessInner, _: []const u8, _: []const u8) bool {
        return false;
    }
    pub fn lookupQualifiedConstNode(_: StatelessInner, _: *const Node) ?i64 {
        return null;
    }

    pub fn lookupQualifiedConstNodeFloat(_: StatelessInner, _: *const Node) ?f64 {
        return null;
    }

    pub fn qualifiedNodeIsFloatTyped(_: StatelessInner, _: *const Node) bool {
        return false;
    }

    /// Float-valued leaf for the shared float-expression evaluator — the FLOAT
    /// twin of `lookupDimName`, routed through the SAME `program_index.moduleConstFloat`
    /// the stateful body-lowering path uses, so a float-const-leaf dimension
    /// (`Arr :: [F + 1.5]T`, `F : f64 : 2.5` → len 4) folds to the SAME count on
    /// the registration-time alias path as on the direct form `a : [F + 1.5]T`
    /// (unify-or-diverge). Integer / integral-float leaves are already
    /// resolved by the `evalConstIntExpr` delegation inside `evalConstFloatExpr`;
    /// this surfaces a non-integral float const so the unified rule rejects it.
    pub fn lookupFloatName(self: StatelessInner, name: []const u8) ?f64 {
        const consts = self.consts orelse return null;
        return program_index_mod.moduleConstFloat(consts, self.table, name);
    }
    /// True iff `name` is a FLOAT-typed module const — the registration-time twin
    /// of `Lowering.nameIsFloatTyped`, routed through the SAME
    /// `program_index.moduleConstIsFloatTyped` so the int folder's division arm
    /// classifies a const-leaf division identically on the alias-registration path
    /// as on the direct form (the unify-or-diverge
    /// rule extended to the division guard).
    pub fn nameIsFloatTyped(self: StatelessInner, name: []const u8) bool {
        const consts = self.consts orelse return false;
        return program_index_mod.moduleConstIsFloatTyped(consts, self.table, name);
    }
};

/// Fold a registration-time array dimension to its `DimU32` outcome through the
/// SAME shared `program_index.foldDimU32` that `StatelessInner.resolveArrayLen`
/// uses — but surface the reason instead of collapsing it to `null`. The
/// alias-registration site calls this so an unresolved `Arr :: [N]T` alias can
/// emit the PRECISE dim diagnostic (oversized `[5_000_000_000]` / negative /
/// non-const) that matches the stateful direct form, rather than one generic
/// "not a compile-time integer constant" message for every failure (the
/// stateful/stateless diagnostic divergence).
pub fn foldArrayDim(len_node: *const Node, table: *TypeTable, alias_map: AliasMap, consts: ConstMap) program_index_mod.DimU32 {
    const si = StatelessInner{ .table = table, .alias_map = alias_map, .consts = consts };
    return program_index_mod.foldDimU32(len_node, si, 0);
}

// ── AST Node → TypeId ───────────────────────────────────────────────────
// Resolve an AST type node into an IR TypeId. Used during lowering when
// we only have the parsed AST (no codegen type registry).

pub fn resolveAstType(node: ?*const Node, table: *TypeTable, alias_map: AliasMap, consts: ConstMap) TypeId {
    // A null node means a caller reached type resolution without a type node.
    // Every current caller either passes a non-optional node or handles the
    // "no type" case itself (returning `.void`), so this is a caller bug — and
    // `.i64` here would silently fabricate an 8-byte int. Surface it via the
    // `.unresolved` sentinel (trips the sizeOf/toLLVMType panic at codegen).
    const n = node orelse return .unresolved;
    const si = StatelessInner{ .table = table, .alias_map = alias_map, .consts = consts };
    return switch (n.data) {
        .type_expr => |te| resolveTypeName(te.name, table, alias_map, te.is_raw),
        .identifier => |id| resolveTypeName(id.name, table, alias_map, id.is_raw),
        // Structural shapes (`*T`/`[*]T`/`[]T`/`?T`/`[N]T`, functions, plain
        // closures, plain tuples) are owned by the single canonical
        // `TypeResolver.resolveCompound` — no independent compound algorithm
        // lives here (A2.3b). resolveCompound never returns null for these
        // kinds, so `.?` is total.
        .pointer_type_expr,
        .many_pointer_type_expr,
        .slice_type_expr,
        .optional_type_expr,
        .array_type_expr,
        .function_type_expr,
        => type_resolver.TypeResolver.resolveCompound(table, n, si).?,
        // Plain closures/tuples are owned by resolveCompound (above). It returns
        // null for the PACK-shaped forms — `Closure(..p)` and spread tuples —
        // because expanding a pack needs bindings. type_bridge has none, so it
        // preserves the pack SHAPE statelessly (e.g. `Into(Block)` resolves a
        // `Closure(..p)` field type at registration time). These tiny fallbacks
        // are the only stateless-specific shape code left; the stateful expand
        // lives in PackResolver.
        .closure_type_expr => |ct| type_resolver.TypeResolver.resolveCompound(table, n, si) orelse resolveClosurePackShape(&ct, table, alias_map, consts),
        .tuple_type_expr => |tt| type_resolver.TypeResolver.resolveCompound(table, n, si) orelse resolveTupleSpreadShape(&tt, table, alias_map, consts),
        // A multi-return signature resolves to its REUSED tuple TypeId — the ABI
        // is a tuple; only its meaning ("multiple return values", return-only,
        // destructure-only) differs, which the AST node (not the TypeId) carries.
        .return_type_expr => type_resolver.TypeResolver.resolveCompound(table, n, si) orelse .unresolved,
        .pack_index_type_expr => {
            // Pack-index `$args[N]` in a type position must be resolved
            // against an active pack binding — `type_bridge` has no access
            // to that state. The pack-aware caller (lowering's
            // `resolveTypeWithBindings`) handles this case directly *before*
            // delegating here, so reaching this bare path means the binding
            // was missing. `.i64` would silently fabricate an 8-byte int;
            // return `.unresolved` so it surfaces (trips the sizeOf/toLLVMType
            // panic at codegen).
            std.debug.print("type_bridge: pack-index type expression encountered outside a pack-aware context — returning .unresolved\n", .{});
            return .unresolved;
        },
        .tuple_literal => |tl| resolveTupleLiteralAsType(&tl, table, alias_map, consts),
        .parameterized_type_expr => |pt| resolveParameterizedType(&pt, table, alias_map, consts),
        // An unannotated param. Its type must be resolved from context
        // (contextual closure typing, generic binding, or pack substitution)
        // *before* reaching here; if it doesn't, returning a plausible `.i64`
        // silently fabricates an 8-byte int (the classic silent-default trap).
        // Return the dedicated `.unresolved` sentinel — never a legitimate
        // type — so the omission surfaces; the lowering-side `resolveParamType`
        // turns it into a real diagnostic.
        .inferred_type => .unresolved,
        // Inline type declarations (used as field types). Enum/union bodies are
        // built through the shared `inner`-parameterized builders; the stateless
        // path passes `si` (the `StatelessInner` already constructed above) — the
        // same `resolveInner` recursion hook `resolveCompound` receives.
        .enum_decl => |ed| resolveInlineEnum(&ed, table, si),
        .struct_decl => |sd| resolveInlineStruct(&sd, table, si),
        .union_decl => |ud| resolveInlineUnion(&ud, table, si),
        .error_set_decl => |esd| resolveInlineErrorSet(&esd, table),
        .error_type_expr => |ete| resolveErrorType(&ete, table, si),
        // A bare spread element (`..Ts`) reaching here is BY DESIGN, not a caller
        // bug: `resolveClosurePackShape` / `resolveTupleSpreadShape` preserve a
        // pack-shaped type (`Closure(..p)`, `Tuple(..Ts)`) statelessly by resolving
        // each element individually, and a spread element is not itself a type —
        // it's a placeholder the stateful `PackResolver` expands once bindings
        // exist. Return the `.unresolved` sentinel (same as the `else`, so an
        // unexpanded spread still trips the sizeOf/toLLVMType tripwire if it ever
        // reaches codegen — see issue 0196's poison-to-unresolved path), but
        // WITHOUT the `else`'s "caller bug" debug print, which this expected case
        // does not warrant.
        .spread_expr => .unresolved,
        else => {
            // A non-type AST node reached type resolution — a caller bug.
            // Returning a plausible `.i64` would silently fabricate an 8-byte
            // int; return the `.unresolved` sentinel so it surfaces (and trips
            // the sizeOf/toLLVMType panic if it ever reaches codegen).
            std.debug.print("type_bridge: unhandled node type {s} in type position — returning .unresolved\n", .{@tagName(n.data)});
            return .unresolved;
        },
    };
}

// ── Internal helpers ─────────────────────────────────────────────────────

/// Resolve a bare type name. The algorithm lives in `type_resolver.zig`
/// (`TypeResolver.resolveNamed`, the single source); `type_bridge` forwards the
/// caller-threaded `alias_map` (the single-source `ProgramIndex.type_alias_map`).
/// `skip_builtin` carries the backtick raw escape.
fn resolveTypeName(name: []const u8, table: *TypeTable, alias_map: AliasMap, skip_builtin: bool) TypeId {
    return type_resolver.TypeResolver.resolveNamed(name, table, alias_map, skip_builtin);
}

/// Builtin primitive keyword → TypeId. The keyword table now lives in
/// `type_resolver.zig` (architecture phase A2.1, `TypeResolver.resolvePrimitive`);
/// re-exported here so existing callers are unaffected while `type_bridge` is
/// retired (A2.2). Single source of truth: the table is defined once, there.
pub const resolveTypePrimitive = type_resolver.TypeResolver.resolvePrimitive;

/// Pack-shaped `Closure(..p)` resolved without bindings: the canonical
/// `resolveCompound` builds plain closures and defers pack-shaped ones (returns
/// null). type_bridge can't expand the pack (no state), so it preserves the
/// pack SHAPE — a `closureTypePack` whose prefix is the fixed params. The
/// stateful expand lives in `PackResolver.resolveClosureTypeWithBindings`.
fn resolveClosurePackShape(ct: *const ast.ClosureTypeExpr, table: *TypeTable, alias_map: AliasMap, consts: ConstMap) TypeId {
    const alloc = table.alloc;
    var param_ids = std.ArrayList(TypeId).empty;
    for (ct.param_types) |pt| {
        param_ids.append(alloc, resolveAstType(pt, table, alias_map, consts)) catch unreachable;
    }
    const ret_id = if (ct.return_type) |rt| resolveAstType(rt, table, alias_map, consts) else TypeId.void;
    return table.closureTypePack(param_ids.items, ret_id, @intCast(param_ids.items.len));
}

/// Spread tuple `(..xs)` resolved without bindings: `resolveCompound` builds
/// plain tuples and defers spread ones. type_bridge can't expand the pack, so
/// each field resolves individually (a spread field is not a type → resolves to
/// `.unresolved`). The stateful expand lives in
/// `PackResolver.resolveTupleTypeWithBindings`.
fn resolveTupleSpreadShape(tt: *const ast.TupleTypeExpr, table: *TypeTable, alias_map: AliasMap, consts: ConstMap) TypeId {
    const alloc = table.alloc;
    var field_ids = std.ArrayList(TypeId).empty;
    for (tt.field_types) |ft| {
        field_ids.append(alloc, resolveAstType(ft, table, alias_map, consts)) catch unreachable;
    }
    var name_ids: ?[]const StringId = null;
    if (tt.field_names) |names| {
        var ids = std.ArrayList(StringId).empty;
        for (names) |n| {
            ids.append(alloc, table.internString(n)) catch unreachable;
        }
        name_ids = ids.items;
    }
    return table.intern(.{ .tuple = .{
        .fields = field_ids.items,
        .names = name_ids,
    } });
}

// Treat a tuple value literal as the corresponding tuple TYPE — valid only when
// every element is itself a type expression. A non-type element (e.g. the `1`
// in `(i32, 1)`) means this literal is NOT a type: refuse to fabricate a tuple
// and return the `.unresolved` sentinel (never `.i64`, which would silently lie
// about the size). type_bridge is stateless and has no diagnostics;
// the user-facing diagnostic is emitted by the stateful caller
// (`Lowering.resolveTupleLiteralTypeArg`), which validates before delegating
// here, so the valid path below builds the tuple and the invalid path never
// reaches it from lowering. The sentinel is the backstop for any other
// (binding-free) caller.
fn resolveTupleLiteralAsType(tl: *const ast.TupleLiteral, table: *TypeTable, alias_map: AliasMap, consts: ConstMap) TypeId {
    const alloc = table.alloc;
    var field_ids = std.ArrayList(TypeId).empty;
    var name_ids_list = std.ArrayList(StringId).empty;
    var any_named = false;
    for (tl.elements) |el| {
        if (!isTypeShapedAstNode(el.value, table)) return .unresolved;
        field_ids.append(alloc, resolveAstType(el.value, table, alias_map, consts)) catch unreachable;
        if (el.name) |n| {
            any_named = true;
            name_ids_list.append(alloc, table.internString(n)) catch unreachable;
        } else {
            name_ids_list.append(alloc, table.internString("")) catch unreachable;
        }
    }
    const names: ?[]const StringId = if (any_named) name_ids_list.items else null;
    return table.intern(.{ .tuple = .{
        .fields = field_ids.items,
        .names = names,
    } });
}

// Returns true when this AST node, on its own, denotes a type rather than a
// value. Used to guard tuple-literal-as-type reinterpretation: a tuple literal
// becomes a tuple type only when every element is a type.
pub fn isTypeShapedAstNode(node: *const Node, table: *TypeTable) bool {
    return switch (node.data) {
        .type_expr,
        .pointer_type_expr,
        .many_pointer_type_expr,
        .array_type_expr,
        .slice_type_expr,
        .optional_type_expr,
        .function_type_expr,
        .closure_type_expr,
        .tuple_type_expr,
        .return_type_expr,
        .parameterized_type_expr,
        .pack_index_type_expr,
        .comptime_pack_ref,
        => true,
        .identifier => |id| table.findByName(table.internString(id.name)) != null,
        // Prefix `*` parses as address_of in the value grammar; over a
        // type-shaped operand it IS the pointer type (`describe(*Padded)`).
        .unary_op => |uop| uop.op == .address_of and isTypeShapedAstNode(uop.operand, table),
        // A call to a comptime type-query / projection builtin whose RESULT is a
        // Type — `field_type(T, i)`, `pointee(P)`, `type_of(x)`. These are
        // type-shaped, so an arg / initializer like `field_type(T, i)` resolves
        // through `resolveTypeArg` (which routes `.call` to
        // `resolveTypeCallWithBindings`, folding the index — incl. an `inline for`
        // loop var) rather than through value inference (which cannot fold the
        // index → "cannot infer generic type parameter"). Value-returning calls
        // stay non-type-shaped (the `else` below).
        .call => |c| switch (c.callee.data) {
            .identifier => |id| isTypeReturningBuiltinName(id.name),
            else => false,
        },
        .tuple_literal => |tl| blk: {
            for (tl.elements) |el| {
                if (!isTypeShapedAstNode(el.value, table)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// Comptime builtins whose call result IS a `Type` (so a call to one is
/// type-shaped). The type-CONSTRUCTOR builtins `Vector`/generic-struct heads are
/// already covered by `.parameterized_type_expr`; this names the type-QUERY /
/// projection builtins that parse as a plain `.call`.
pub fn isTypeReturningBuiltinName(name: []const u8) bool {
    return std.mem.eql(u8, name, "struct_field_type") or
        std.mem.eql(u8, name, "variant_type") or
        std.mem.eql(u8, name, "pointee_type") or
        std.mem.eql(u8, name, "type_of");
}

fn resolveParameterizedType(pt: *const ast.ParameterizedTypeExpr, table: *TypeTable, alias_map: AliasMap, consts: ConstMap) TypeId {
    // Strip module prefix (e.g. "std.Vector" → "Vector")
    const base_name = if (std.mem.lastIndexOfScalar(u8, pt.name, '.')) |dot| pt.name[dot + 1 ..] else pt.name;
    // Vector(N, T) is a built-in parameterized type
    if (std.mem.eql(u8, base_name, "Vector")) {
        if (pt.args.len == 2) {
            // The lane count is a literal or a named module-const integer — the
            // same dimension forms a fixed array accepts. An unresolvable count
            // is NOT a 0-lane vector (which would silently mis-size every load /
            // store); yield `.unresolved` so the failure surfaces.
            const si = StatelessInner{ .table = table, .alias_map = alias_map, .consts = consts };
            const length = si.resolveArrayLen(pt.args[0]) orelse return .unresolved;
            const elem = resolveAstType(pt.args[1], table, alias_map, consts);
            return table.vectorOf(elem, length);
        }
    }
    // Generic struct instantiation — register as named type
    const name_id = table.internString(pt.name);
    return table.intern(.{ .@"struct" = .{ .name = name_id, .fields = &.{} } });
}

// ── Inline type declarations ─────────────────────────────────────────

/// Inline-enum resolution for a FIELD-type position (`x: enum {...}`). Payload
/// type NAMES resolve through the injected `inner` recursion hook: the stateless
/// `StatelessInner` (flat) when reached from `resolveAstType`, or `*Lowering`
/// (visibility-aware) when reached from `Lowering.resolveTypeWithBindings` — so a
/// payload name resolves in the enclosing module's context (issue 0132's class).
/// The TOP-LEVEL per-decl nominal identity path (`Lowering.registerEnumDecl`)
/// shares the body via `buildEnumInfo` but interns under its own nominal id.
pub fn resolveInlineEnum(ed: *const ast.EnumDecl, table: *TypeTable, inner: anytype) TypeId {
    const name_id = table.internString(ed.name);
    // Anonymous inline enums are shape-keyed, same as structs (issue 0294);
    // buildEnumInfo yields `.enum` or `.tagged_union` — both shape-key.
    if (std.mem.eql(u8, ed.name, "__anon")) {
        return table.internAnonShape(buildEnumInfo(ed, table, inner));
    }
    if (table.findByName(name_id)) |existing| return existing;
    const info = buildEnumInfo(ed, table, inner);
    const id = table.internNominal(info, 0);
    table.updatePreservingKey(id, info);
    return id;
}

/// Build the `TypeInfo` body for an enum decl WITHOUT interning the top-level
/// nominal slot — the shared body-BUILDER behind both the stateless inline
/// field-type path (`resolveInlineEnum`) and the stateful per-decl registration
/// (`Lowering.registerEnumDecl`, which interns it under a per-decl nominal
/// identity so two same-name top-level enums get DISTINCT TypeIds). A payload
/// enum builds a `.tagged_union`; a payload-less enum a plain `.enum`. Nested
/// Decode an explicit enum-variant value node (`esc :: '\x1b'`, `quit :: 0x100`)
/// to its integer, or `null` if it isn't a constant the enum machinery
/// understands (the caller supplies the positional / power-of-2 fallback).
/// A `char_literal` value is an integer code point — without this arm it
/// silently fell through to the ordinal fallback, shipping the wrong tag value
/// with no diagnostic. (Negated values like `lo :: -1` are intentionally NOT
/// handled here: they still take the positional fallback, matching prior
/// behavior — a signed tag value is a separate, pre-existing gap the downstream
/// `@bitCast`-to-u64 tag path can't yet represent.)
fn enumVariantConst(vv: *const Node) ?i64 {
    return switch (vv.data) {
        .int_literal => |il| il.value,
        .char_literal => |cl| cl.value,
        else => null,
    };
}

/// payload structs / variant field types ARE interned here — they are distinct
/// nested nominals, not the enum's own identity.
pub fn buildEnumInfo(ed: *const ast.EnumDecl, table: *TypeTable, inner: anytype) TypeInfo {
    const alloc = table.alloc;
    const name_id = table.internString(ed.name);

    // Enum with payloads → tagged union
    const has_payloads = ed.variant_types.len > 0;
    if (has_payloads) {
        var fields = std.ArrayList(TypeInfo.StructInfo.Field).empty;
        for (ed.variant_names, 0..) |vn, i| {
            var field_ty: TypeId = .void;
            if (i < ed.variant_types.len) {
                if (ed.variant_types[i]) |vt| {
                    // For inline structs (__anon), rename to EnumName.variant_name.
                    // Only when the enum itself is NAMED: an anonymous enum
                    // would qualify every payload as `__anon.<variant>`, and
                    // two anon enums sharing a variant name would collide on
                    // it (issue 0294's class one level down) — those route
                    // through the shape-keyed path instead.
                    if (vt.data == .struct_decl and !std.mem.eql(u8, ed.name, "__anon")) {
                        const sd = &vt.data.struct_decl;
                        if (std.mem.eql(u8, sd.name, "__anon")) {
                            const qualified = std.fmt.allocPrint(alloc, "{s}.{s}", .{ ed.name, vn }) catch "__anon";
                            const qname_id = table.internString(qualified);
                            if (table.findByName(qname_id)) |existing| {
                                field_ty = existing;
                            } else {
                                var sfields = std.ArrayList(TypeInfo.StructInfo.Field).empty;
                                for (sd.field_names, sd.field_types) |fname, ftype_node| {
                                    const fty = inner.resolveInner(ftype_node);
                                    sfields.append(alloc, .{
                                        .name = table.internString(fname),
                                        .ty = fty,
                                    }) catch unreachable;
                                }
                                const sinfo: TypeInfo = .{ .@"struct" = .{
                                    .name = qname_id,
                                    .fields = sfields.items,
                                } };
                                field_ty = table.internNominal(sinfo, 0);
                                table.updatePreservingKey(field_ty, sinfo);
                            }
                        } else {
                            field_ty = inner.resolveInner(vt);
                        }
                    } else {
                        field_ty = inner.resolveInner(vt);
                    }
                }
            }
            fields.append(alloc, .{
                .name = table.internString(vn),
                .ty = field_ty,
            }) catch unreachable;
        }
        // Resolve backing type and tag type from enum struct
        // e.g. enum struct { tag: u32; _: u32; payload: [30]u32; } { ... }
        var backing_type: ?TypeId = null;
        var tag_type: ?TypeId = null;
        if (ed.backing_type) |bt| {
            const backing_ty = inner.resolveInner(bt);
            backing_type = backing_ty;
            // Extract tag type from first field of backing struct
            const backing_info = table.get(backing_ty);
            if (backing_info == .@"struct") {
                if (backing_info.@"struct".fields.len > 0) {
                    tag_type = backing_info.@"struct".fields[0].ty;
                }
            }
        }

        // Build explicit tag values from variant_values (e.g., quit :: 0x100)
        var explicit_tag_vals: ?[]const i64 = null;
        if (ed.variant_values.len > 0) {
            var vals = std.ArrayList(i64).empty;
            for (0..ed.variant_names.len) |i| {
                if (i < ed.variant_values.len) {
                    if (ed.variant_values[i]) |vv| {
                        if (enumVariantConst(vv)) |v| {
                            vals.append(alloc, v) catch unreachable;
                            continue;
                        }
                    }
                }
                vals.append(alloc, @intCast(i)) catch unreachable;
            }
            explicit_tag_vals = vals.items;
        }

        return .{ .tagged_union = .{
            .name = name_id,
            .fields = fields.items,
            .tag_type = tag_type orelse .i64, // enum unions are always tagged (default i64)
            .backing_type = backing_type,
            .explicit_tag_values = explicit_tag_vals,
        } };
    }

    // Plain enum (no payloads)
    var variants = std.ArrayList(StringId).empty;
    for (ed.variant_names) |vn| {
        variants.append(alloc, table.internString(vn)) catch unreachable;
    }
    // Build explicit values for flags (power-of-2) or custom values
    var explicit_vals: ?[]const i64 = null;
    if (ed.is_flags) {
        var vals = std.ArrayList(i64).empty;
        for (ed.variant_names, 0..) |_, i| {
            if (i < ed.variant_values.len) {
                if (ed.variant_values[i]) |vv| {
                    if (enumVariantConst(vv)) |v| {
                        vals.append(alloc, v) catch unreachable;
                        continue;
                    }
                }
            }
            // Auto power-of-2: 1, 2, 4, 8, ...
            vals.append(alloc, @as(i64, 1) << @intCast(i)) catch unreachable;
        }
        explicit_vals = vals.items;
    } else if (ed.variant_values.len > 0) {
        var vals = std.ArrayList(i64).empty;
        for (0..ed.variant_names.len) |i| {
            if (i < ed.variant_values.len) {
                if (ed.variant_values[i]) |vv| {
                    if (enumVariantConst(vv)) |v| {
                        vals.append(alloc, v) catch unreachable;
                        continue;
                    }
                }
            }
            vals.append(alloc, @intCast(i)) catch unreachable;
        }
        explicit_vals = vals.items;
    }
    // Resolve backing type for sized enums (e.g. enum u32 { ... })
    var enum_backing: ?TypeId = null;
    if (ed.backing_type) |bt| {
        // Only use simple backing types (u8, u16, u32, etc.), not struct backing (enum struct)
        if (bt.data != .struct_decl) {
            enum_backing = inner.resolveInner(bt);
        }
    }

    return .{ .@"enum" = .{
        .name = name_id,
        .variants = variants.items,
        .is_flags = ed.is_flags,
        .explicit_values = explicit_vals,
        .backing_type = enum_backing,
    } };
}

/// Inline-struct resolution for a FIELD-type position (`x: struct {...}`). Field
/// type NAMES resolve through the injected `inner` hook (flat `StatelessInner`
/// from `resolveAstType`, or visibility-aware `*Lowering` from
/// `resolveTypeWithBindings` — issue 0132's class). The TOP-LEVEL struct path
/// (`Lowering.registerStructDecl`) builds its own field list directly via
/// `self.resolveType` (it also expands `#using` and qualifies `__anon` names),
/// so it does not route through here.
pub fn resolveInlineStruct(sd: *const ast.StructDecl, table: *TypeTable, inner: anytype) TypeId {
    const alloc = table.alloc;
    const name_id = table.internString(sd.name);

    // An anonymous inline decl has no name to key by — every one displays as
    // `__anon`, so the name-keyed lookup/intern below would collapse
    // differently-shaped annotations onto whichever shape interned first
    // (issue 0294). Shape-keyed identity instead: identical shapes unify,
    // distinct shapes separate.
    const is_anon = std.mem.eql(u8, sd.name, "__anon");
    if (!is_anon) {
        if (table.findByName(name_id)) |existing| return existing;
    }

    var fields = std.ArrayList(TypeInfo.StructInfo.Field).empty;
    for (sd.field_names, sd.field_types) |fname, ftype_node| {
        const field_ty = inner.resolveInner(ftype_node);
        fields.append(alloc, .{
            .name = table.internString(fname),
            .ty = field_ty,
        }) catch unreachable;
    }
    const info: TypeInfo = .{ .@"struct" = .{
        .name = name_id,
        .fields = fields.items,
    } };
    if (is_anon) return table.internAnonShape(info);
    const id = table.internNominal(info, 0);
    table.updatePreservingKey(id, info);
    return id;
}

/// Inline-union resolution for a FIELD-type position. Field type NAMES resolve
/// through the injected `inner` hook (flat `StatelessInner` from `resolveAstType`,
/// or visibility-aware `*Lowering` from `resolveTypeWithBindings` — issue 0132's
/// class). The TOP-LEVEL per-decl nominal identity path
/// (`Lowering.registerUnionDecl`) shares the body via `buildUnionInfo` but interns
/// under its own nominal id.
pub fn resolveInlineUnion(ud: *const ast.UnionDecl, table: *TypeTable, inner: anytype) TypeId {
    const name_id = table.internString(ud.name);
    // Anonymous inline unions are shape-keyed, same as structs (issue 0294).
    if (std.mem.eql(u8, ud.name, "__anon")) {
        return table.internAnonShape(buildUnionInfo(ud, table, inner));
    }
    if (table.findByName(name_id)) |existing| return existing;
    const info = buildUnionInfo(ud, table, inner);
    const id = table.internNominal(info, 0);
    table.updatePreservingKey(id, info);
    return id;
}

/// Build the `TypeInfo` body for a union decl WITHOUT interning the top-level
/// nominal slot — the shared body-BUILDER behind both the stateless inline
/// field-type path (`resolveInlineUnion`) and the stateful per-decl registration
/// (`Lowering.registerUnionDecl`).
pub fn buildUnionInfo(ud: *const ast.UnionDecl, table: *TypeTable, inner: anytype) TypeInfo {
    const alloc = table.alloc;
    const name_id = table.internString(ud.name);

    var fields = std.ArrayList(TypeInfo.StructInfo.Field).empty;
    for (ud.field_names, ud.field_types) |fname, ftype_node| {
        const field_ty = inner.resolveInner(ftype_node);
        fields.append(alloc, .{
            .name = table.internString(fname),
            .ty = field_ty,
        }) catch unreachable;
    }
    return .{ .@"union" = .{
        .name = name_id,
        .fields = fields.items,
    } };
}

/// `Foo :: error { A, B }` → a registered `.error_set` type. Tag names are
/// interned into the global tag pool; the set stores their (sorted) ids. The
/// caller (lowering) is responsible for rejecting an empty set, so this only
/// sees non-empty declarations.
///
/// INLINE / structural path ONLY: keeps the `findByName` short-circuit so an
/// anonymous / re-resolved set re-uses an existing same-name slot. The
/// declaration-side per-decl nominal path (`Lowering.registerErrorSetDecl`)
/// builds the body via `buildErrorSetInfo` and interns under its own nominal id
/// instead — see issue 0134.
fn resolveInlineErrorSet(esd: *const ast.ErrorSetDecl, table: *TypeTable) TypeId {
    const name_id = table.internString(esd.name);

    if (table.findByName(name_id)) |existing| return existing;

    const info = buildErrorSetInfo(esd, table);
    return table.intern(info);
}

/// Build the `.error_set` `TypeInfo` body for an error-set decl WITHOUT
/// interning a top-level slot — the shared body-BUILDER behind both the
/// structural inline path (`resolveInlineErrorSet`) and the stateful per-decl
/// registration (`Lowering.registerErrorSetDecl`, which interns it under a
/// per-decl nominal identity so two same-name top-level sets get DISTINCT
/// TypeIds). Tags are interned into the global pool and stored sorted in the
/// slice arena (mirrors `errorSetType`'s canonicalization).
pub fn buildErrorSetInfo(esd: *const ast.ErrorSetDecl, table: *TypeTable) TypeInfo {
    const alloc = table.alloc;
    const name_id = table.internString(esd.name);

    var tag_ids = std.ArrayList(u32).empty;
    defer tag_ids.deinit(alloc);
    for (esd.tag_names) |tn| {
        tag_ids.append(alloc, table.internTag(tn)) catch unreachable;
    }
    const owned = table.slice_arena.allocator().dupe(u32, tag_ids.items) catch unreachable;
    std.mem.sort(u32, owned, {}, std.sort.asc(u32));
    return .{ .error_set = .{ .name = name_id, .tags = owned } };
}

/// The error channel of a failable signature: `!Named` → the declared error
/// set (registered by `resolveInlineErrorSet`); bare `!` → a shared inferred
/// placeholder set. The placeholder's members are refined per failable
/// function by the whole-program SCC pass (E1.4); for now every bare `!`
/// resolves to the same empty inferred set, which is correct while no
/// function raises (E1.3+).
pub fn resolveErrorType(ete: *const ast.ErrorTypeExpr, table: *TypeTable, inner: anytype) TypeId {
    if (ete.name) |name| return inner.resolveName(name);
    // `!` is not a legal type/identifier name, so this reserved StringId can
    // never collide with a user-declared set.
    const name_id = table.internString("!");
    if (table.findByName(name_id)) |existing| return existing;
    return table.errorSetType(name_id, &.{});
}
