const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");
const errors = @import("../errors.zig");
const program_index_mod = @import("program_index.zig");

const Node = ast.Node;
const TypeId = types.TypeId;
const TypeTable = types.TypeTable;
const StringId = types.StringId;
const ProgramIndex = program_index_mod.ProgramIndex;

/// Explicit, caller-supplied resolution context:
/// the inputs that steer AST type-node resolution, replacing ad-hoc mutable
/// `Lowering` fields (`type_bindings`, `pack_*`, `comptime_value_bindings`,
/// `target_type`, …).
pub const ResolveEnv = struct {
    type_bindings: ?*const std.StringHashMap(TypeId) = null,
    pack_bindings: ?*const std.StringHashMap([]const TypeId) = null,
    pack_arg_types: ?*const std.StringHashMap([]const TypeId) = null,
    pack_constraints: ?*const std.StringHashMap([]const u8) = null,
    comptime_values: ?*const std.StringHashMap(i64) = null,
    target_type: ?TypeId = null,
};

/// Canonical AST-type-node → `TypeId` resolver. Owns the primitive-keyword
/// table and the structural compound type constructors.
///
/// Holds borrowed references only — constructed cheaply by value at each call
/// site (`Lowering.typeResolver()`), so it always reflects current state.
pub const TypeResolver = struct {
    alloc: std.mem.Allocator,
    types: *TypeTable,
    diagnostics: ?*errors.DiagnosticList,
    index: *ProgramIndex,

    /// Every builtin whose spelling is a fixed keyword. The integer aliases are
    /// NOT here — `types.lookupIntAlias` owns them, so a spelling and a width
    /// can never name different types.
    const named_builtins = [_]struct { name: []const u8, id: TypeId }{
        .{ .name = "f32", .id = .f32 },
        .{ .name = "f64", .id = .f64 },
        .{ .name = "bool", .id = .bool },
        .{ .name = "string", .id = .string },
        .{ .name = "cstring", .id = .cstring },
        .{ .name = "void", .id = .void },
        .{ .name = "any", .id = .any },
        // A `Type` value is its own 8-byte builtin handle (`.type_value`),
        // DISTINCT from the 16-byte boxed `.any`. Flowing a `Type` into an `Any`
        // slot boxes it (`{ tag = .any.index(), value = TypeId.index() }`) via
        // the standard box-any coercion; reflection reads it back through
        // `reflectArgRepr`.
        .{ .name = "Type", .id = .type_value },
        .{ .name = "noreturn", .id = .noreturn },
        .{ .name = "usize", .id = .usize },
        .{ .name = "isize", .id = .isize },
    };

    /// A bare name → its builtin `TypeId`, `null` for any non-builtin name (the
    /// caller then continues with generic / alias / named-struct resolution).
    /// Single source of truth for the builtin keyword set: the named builtins
    /// plus the eight reserved integer aliases. A width outside those eight
    /// reaches a `TypeId` only through `internInteger`, never through a name.
    /// Namespaced (no `self`) — primitive resolution is stateless.
    pub fn resolvePrimitive(name: []const u8) ?TypeId {
        if (name.len == 0) return null;
        if (types.lookupIntAlias(name)) |layout| return types.canonicalInt(layout.width, layout.signed);
        for (named_builtins) |b| if (std.mem.eql(u8, name, b.name)) return b.id;
        return null;
    }

    /// True when `field` is `min` or `max` — the two limits an integer type
    /// carries.
    pub fn isIntLimitField(field: []const u8) bool {
        return std.mem.eql(u8, field, "min") or std.mem.eql(u8, field, "max");
    }

    /// The full numeric-limit accessor field set: `.min`/`.max` (valid on int AND
    /// float) plus the float-only `.epsilon`/`.minPositive`/`.trueMin`/`.inf`/
    /// `.nan`. THE single trigger for the `lowerNumericLimit` intercept — only a
    /// field in this set is treated as a limit access; anything else falls through
    /// to ordinary field lowering. Keeps the accessor name set in one place so the
    /// intercept and `expr_typer` can't recognize different surfaces.
    pub fn isLimitField(field: []const u8) bool {
        const names = [_][]const u8{ "min", "max", "epsilon", "minPositive", "trueMin", "inf", "nan" };
        for (names) |n| if (std.mem.eql(u8, field, n)) return true;
        return false;
    }

    /// `<FloatType>.<field>` → the limit as an `f64` value (the queried type is
    /// `f32`/`f64`; every f32 limit is exactly representable in f64, so widening
    /// is lossless and the caller pairs the value with the queried `TypeId` —
    /// `builder.constFloat` narrows it back at emit), or null when `ty` is not a
    /// builtin float type or `field` is not a limit accessor. Values come straight
    /// from `std.math` (`floatMax`/`floatEps`/`floatMin`/`floatTrueMin`/`inf`/`nan`):
    ///   - `.min` = most-NEGATIVE finite (`-max`, NOT C's DBL_MIN)
    ///   - `.max` = largest finite
    ///   - `.epsilon` = ULP of 1.0 (`floatEps`; f64 = 2^-52, f32 = 2^-23)
    ///   - `.minPositive` = smallest positive NORMAL (`floatMin`; = C DBL_MIN)
    ///   - `.trueMin` = smallest positive SUBNORMAL (`floatTrueMin`)
    ///   - `.inf` = +infinity, `.nan` = a quiet NaN
    /// THE single float-limit fold: the value path and `expr_typer` hold the
    /// queried `TypeId` and ask here; `floatLimitFor` is the same fold keyed by
    /// spelling.
    pub fn floatLimitOf(ty: TypeId, field: []const u8) ?f64 {
        if (ty == .f64) return floatLimitValue(f64, field);
        if (ty == .f32) return floatLimitValue(f32, field);
        return null;
    }

    /// `floatLimitOf` keyed by NAME, for the comptime-float folder — it walks an
    /// expression tree of spellings, not of resolved types.
    pub fn floatLimitFor(name: []const u8, field: []const u8) ?f64 {
        return floatLimitOf(resolvePrimitive(name) orelse return null, field);
    }

    fn floatLimitValue(comptime T: type, field: []const u8) ?f64 {
        if (std.mem.eql(u8, field, "min")) return -@as(f64, std.math.floatMax(T));
        if (std.mem.eql(u8, field, "max")) return @as(f64, std.math.floatMax(T));
        if (std.mem.eql(u8, field, "epsilon")) return @as(f64, std.math.floatEps(T));
        if (std.mem.eql(u8, field, "minPositive")) return @as(f64, std.math.floatMin(T));
        if (std.mem.eql(u8, field, "trueMin")) return @as(f64, std.math.floatTrueMin(T));
        if (std.mem.eql(u8, field, "inf")) return @as(f64, std.math.inf(T));
        if (std.mem.eql(u8, field, "nan")) return @as(f64, std.math.nan(T));
        return null;
    }

    /// Single owner of structural AST-type-shape construction. Builds the
    /// shapes whose `TypeId` is fully determined by their node kind plus their
    /// element types resolved through `inner.resolveInner`: `*T`, `[*]T`, `[]T`,
    /// `?T`, `[N]T`, `(P...) -> R` functions, plain `Closure(P...) -> R`, and
    /// plain positional/named tuples. Element recursion goes through `inner`, so
    /// the caller's resolution mode is preserved — the compiler's stateful path
    /// passes `*Lowering` (generic/pack-binding aware), `type_bridge` passes a
    /// binding-free adapter. Both call THIS; there is no second compound/shape
    /// algorithm — `resolveCompound` is the single owner.
    ///
    /// Namespaced (no `self`): only the `TypeTable` is needed, so `type_bridge`
    /// (which has no `ProgramIndex`/diagnostics) can call it too.
    ///
    /// Returns `null` for shapes that depend on caller pack/binding STATE and so
    /// can't be built here: pack-shaped `Closure(..p)` and spread tuples
    /// `(..xs)` (the stateful caller routes these to `PackResolver`), plus
    /// names, parameterized types, pack-index, and `Self`. OOM yields the
    /// `.unresolved` sentinel, never a fabricated type.
    pub fn resolveCompound(table: *TypeTable, node: *const Node, inner: anytype) ?TypeId {
        return switch (node.data) {
            .pointer_type_expr => |pt| table.ptrTo(inner.resolveInner(pt.pointee_type)),
            .many_pointer_type_expr => |mp| table.manyPtrTo(inner.resolveInner(mp.element_type)),
            .slice_type_expr => |st| table.sliceOf(inner.resolveInner(st.element_type)),
            .optional_type_expr => |ot| table.optionalOf(inner.resolveInner(ot.inner_type)),
            .array_type_expr => |at| blk: {
                const elem = inner.resolveInner(at.element_type);
                // The dimension is delegated to `inner` exactly like the element
                // type: a literal `[16]T` and a named-const `N :: 16; [N]T` must
                // produce the same length. `resolveArrayLen` returns null when the
                // dimension can't be resolved to a compile-time integer; that is
                // never a 0-length array (which gives a 0-byte alloca and OOB
                // element access). Yield the `.unresolved` sentinel
                // instead, so the failure halts the build (the stateful resolver
                // also emits a diagnostic; the registration-time caller surfaces
                // the unresolved alias) rather than silently miscompiling.
                const len = inner.resolveArrayLen(at.length) orelse break :blk TypeId.unresolved;
                break :blk table.arrayOf(elem, len);
            },
            .function_type_expr => |ft| blk: {
                var param_ids = std.ArrayList(TypeId).empty;
                defer param_ids.deinit(table.alloc);
                for (ft.param_types) |pt| param_ids.append(table.alloc, inner.resolveInner(pt)) catch return .unresolved;
                const ret_ty = if (ft.return_type) |rt| inner.resolveInner(rt) else TypeId.void;
                const cc: types.TypeInfo.CallConv = switch (ft.abi) {
                    .default => .default,
                    .c => .c,
                    // `.compiler` (compiler-domain fn) and `.naked` (naked asm) are
                    // decl-level ABIs with no function-pointer-type calling
                    // convention of their own; the IR function-type CC models only
                    // sx-default vs C. A function-TYPE param marks
                    // the bound function compiler-domain (handled at the call/bind
                    // site, not here) — its CC is still sx-default.
                    .naked => .default,
                };
                break :blk table.functionTypeVariadic(param_ids.items, ret_ty, cc, ft.is_c_variadic);
            },
            .closure_type_expr => |ct| blk: {
                // Pack-shaped `Closure(..p)` needs caller pack state to expand —
                // defer to PackResolver (stateful) by returning null.
                if (ct.pack_name != null) break :blk null;
                var param_ids = std.ArrayList(TypeId).empty;
                defer param_ids.deinit(table.alloc);
                for (ct.param_types) |pt| param_ids.append(table.alloc, inner.resolveInner(pt)) catch return .unresolved;
                const ret_ty = if (ct.return_type) |rt| inner.resolveInner(rt) else TypeId.void;
                break :blk table.closureType(param_ids.items, ret_ty);
            },
            .tuple_type_expr => |tt| internTupleLike(table, tt.field_types, tt.field_names, inner),
            // A multi-return signature `(A, B)` resolves to the SAME tuple TypeId
            // (the ABI is a tuple); its distinct meaning lives in the AST node.
            .return_type_expr => |rt| internTupleLike(table, rt.field_types, rt.field_names, inner),
            else => null,
        };
    }

    /// Intern a product or failable from a list of field-type nodes (+ optional
    /// names) — the shared body of the `tuple_type_expr` and `return_type_expr`
    /// resolution arms. A trailing error-set field is a failable; otherwise
    /// an anonymous product struct. Returns null to defer a spread to the
    /// (stateful) PackResolver, `.unresolved` if any field is non-type.
    fn internTupleLike(table: *TypeTable, field_types: []const *Node, field_names: ?[]const []const u8, inner: anytype) ?TypeId {
        // A spread field `(..xs)` expands to many fields via the pack state —
        // defer to PackResolver by returning null.
        for (field_types) |ft| if (ft.data == .spread_expr) return null;
        var field_ids = std.ArrayList(TypeId).empty;
        defer field_ids.deinit(table.alloc);
        for (field_types) |ft| {
            const fid = inner.resolveInner(ft);
            // A non-type element (e.g. the `1` in `Tuple(i32, 1)`) resolves to
            // `.unresolved`; never intern a product carrying it — that bogus type
            // would reach LLVM emission and panic. The user-facing diagnostic is
            // emitted by the literal-rejection arm in `resolveTypeArg`; here we
            // just refuse to fabricate the type, propagating the sentinel up.
            if (fid == .unresolved) return .unresolved;
            field_ids.append(table.alloc, fid) catch return .unresolved;
        }
        var name_ids: ?[]const StringId = null;
        if (field_names) |names| {
            if (names.len == field_ids.items.len) {
                var ids = std.ArrayList(StringId).empty;
                for (names) |n| ids.append(table.alloc, table.internString(n)) catch return .unresolved;
                name_ids = ids.toOwnedSlice(table.alloc) catch null;
            }
        }
        const last_is_err = field_types.len > 0 and field_types[field_types.len - 1].data == .error_type_expr;
        if (last_is_err) {
            const err = field_ids.items[field_ids.items.len - 1];
            const n_vals = field_ids.items.len - 1;
            const value: TypeId = if (n_vals == 0)
                .void
            else if (n_vals == 1)
                field_ids.items[0]
            else
                table.internProduct(field_ids.items[0..n_vals], if (name_ids) |ns| ns[0..n_vals] else null);
            return table.internFailable(value, err);
        }
        return table.internFieldsAsProductOrFailable(field_ids.items, name_ids);
    }

    /// Generic type-param binding lookup (`$T`, or a bare return-type `T`).
    /// Reads the caller-supplied `ResolveEnv` rather than hidden `Lowering`
    /// state. Returns null when there are no active bindings or the name is
    /// unbound (the caller then continues with primitive / alias / struct
    /// resolution, or returns `.unresolved` for an unbound generic `$R`).
    pub fn resolveBinding(node: *const Node, env: ResolveEnv) ?TypeId {
        const tb = env.type_bindings orelse return null;
        return switch (node.data) {
            .type_expr => |te| tb.get(te.name),
            .identifier => |id| tb.get(id.name),
            else => null,
        };
    }

    /// Resolve a bare type NAME to a `TypeId`: primitive → string-form
    /// pointer/slice/optional prefixes → already-registered named type → alias
    /// (`alias_map`) → fresh empty-struct stub.
    /// `alias_map` is the single-source alias table (owned by `ProgramIndex`);
    /// callers pass it explicitly — Lowering via the index (`resolveName`),
    /// `type_bridge` via the alias map threaded through `resolveAstType`. The
    /// stub fall-through preserves long-standing behavior for as-yet-
    /// unregistered names.
    ///
    /// `skip_builtin` is the backtick raw-identifier escape (`` `i8 `` in type
    /// position): a raw reference is the LITERAL name used as a
    /// type, so it bypasses the builtin/reserved classifier and resolves only
    /// through registered-type → alias → stub. A bare `i8` keeps the default
    /// (`false`) and resolves to the builtin int type. The string-prefix
    /// recursion always passes `false`: the inner names (`*T`/`?T`) are bare,
    /// never raw.
    pub fn resolveNamed(name: []const u8, table: *TypeTable, alias_map: ?*const std.StringHashMap(TypeId), skip_builtin: bool) TypeId {
        if (!skip_builtin) {
            if (resolvePrimitive(name)) |id| return id;
        }

        // Sentinel-terminated slice: [:0]u8 → string.
        if (name.len >= 5 and name[0] == '[' and name[1] == ':') {
            if (std.mem.indexOfScalar(u8, name, ']')) |close| {
                const sentinel = name[2..close];
                const elem = name[close + 1 ..];
                if (std.mem.eql(u8, sentinel, "0") and std.mem.eql(u8, elem, "u8")) return .string;
            }
        }
        // Many-pointer: [*]T.
        if (name.len >= 4 and name[0] == '[' and name[1] == '*' and name[2] == ']') {
            return table.manyPtrTo(resolveNamed(name[3..], table, alias_map, false));
        }
        // Pointer: *T.
        if (name.len >= 2 and name[0] == '*') {
            return table.ptrTo(resolveNamed(name[1..], table, alias_map, false));
        }
        // Optional: ?T.
        if (name.len >= 2 and name[0] == '?') {
            return table.optionalOf(resolveNamed(name[1..], table, alias_map, false));
        }
        // Named struct/enum/union — already-registered wins, then alias, then
        // a fresh empty-struct stub for an as-yet-unregistered name.
        const name_id = table.internString(name);
        if (table.findByName(name_id)) |existing| return existing;
        if (alias_map) |amap| {
            if (amap.get(name)) |alias_ty| return alias_ty;
        }
        return table.intern(.{ .@"struct" = .{ .name = name_id, .fields = &.{} } });
    }

    /// Resolve a bare type name through the canonical alias source
    /// (`ProgramIndex.type_alias_map`). `skip_builtin` carries the backtick raw
    /// escape — see `resolveNamed`.
    pub fn resolveName(self: TypeResolver, name: []const u8, skip_builtin: bool) TypeId {
        return resolveNamed(name, self.types, &self.index.type_alias_map, skip_builtin);
    }
};
