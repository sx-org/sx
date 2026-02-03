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

/// Explicit, caller-supplied resolution context (architecture Principle 2):
/// the inputs that steer AST type-node resolution, replacing ad-hoc mutable
/// `Lowering` fields (`type_bindings`, `pack_*`, `comptime_value_bindings`,
/// `target_type`, …). A2.1 defines the shape; fields are consumed as later
/// phases move the cases that need them (generics/aliases A2.2, packs A2.3).
pub const ResolveEnv = struct {
    type_bindings: ?*const std.StringHashMap(TypeId) = null,
    pack_bindings: ?*const std.StringHashMap([]const TypeId) = null,
    pack_arg_types: ?*const std.StringHashMap([]const TypeId) = null,
    pack_constraints: ?*const std.StringHashMap([]const u8) = null,
    comptime_values: ?*const std.StringHashMap(i64) = null,
    target_type: ?TypeId = null,
};

/// Canonical AST-type-node → `TypeId` resolver (architecture phase A2). As of
/// A2.1 it owns the primitive-keyword table and the structural compound type
/// constructors. Later phases fold in generics/aliases (A2.2) and pack
/// projections (A2.3) and retire `src/ir/type_bridge.zig` (Principle 1).
///
/// Holds borrowed references only — constructed cheaply by value at each call
/// site (`Lowering.typeResolver()`), so it always reflects current state.
pub const TypeResolver = struct {
    alloc: std.mem.Allocator,
    types: *TypeTable,
    diagnostics: ?*errors.DiagnosticList,
    index: *ProgramIndex,

    /// Builtin primitive keyword → `TypeId`; `null` for any non-primitive name
    /// (the caller then continues with generic / alias / named-struct
    /// resolution). Single source of truth for the builtin keyword set.
    /// Namespaced (no `self`) — primitive resolution is stateless.
    pub fn resolvePrimitive(name: []const u8) ?TypeId {
        if (name.len == 0) return null;
        if (std.mem.eql(u8, name, "i64")) return .i64;
        if (std.mem.eql(u8, name, "i32")) return .i32;
        if (std.mem.eql(u8, name, "i16")) return .i16;
        if (std.mem.eql(u8, name, "i8")) return .i8;
        if (std.mem.eql(u8, name, "u64")) return .u64;
        if (std.mem.eql(u8, name, "u32")) return .u32;
        if (std.mem.eql(u8, name, "u16")) return .u16;
        if (std.mem.eql(u8, name, "u8")) return .u8;
        if (std.mem.eql(u8, name, "f32")) return .f32;
        if (std.mem.eql(u8, name, "f64")) return .f64;
        if (std.mem.eql(u8, name, "bool")) return .bool;
        if (std.mem.eql(u8, name, "string")) return .string;
        if (std.mem.eql(u8, name, "cstring")) return .cstring;
        if (std.mem.eql(u8, name, "void")) return .void;
        if (std.mem.eql(u8, name, "any")) return .any;
        // A `Type` value is its own 8-byte builtin handle (`.type_value`), DISTINCT
        // from the 16-byte boxed `.any`. Flowing a `Type` into an `Any` slot boxes
        // it (`{ tag = .any.index(), value = TypeId.index() }`) via the standard
        // box-any coercion; reflection reads it back through `reflectArgRepr`.
        if (std.mem.eql(u8, name, "Type")) return .type_value;
        if (std.mem.eql(u8, name, "noreturn")) return .noreturn;
        if (std.mem.eql(u8, name, "usize")) return .usize;
        if (std.mem.eql(u8, name, "isize")) return .isize;
        return null;
    }

    /// An arbitrary-bit-width integer type NAME (`i1`–`i64`, `u1`–`u64`, which
    /// also subsumes `i8`/`u8`/…/`i64`/`u64`): its width + signedness, else
    /// null. THE single width parser — `resolveBuiltinName` (to intern the
    /// `TypeId`) and the numeric-limit accessors (`.min`/`.max`, via
    /// `integerWidthSign`) both classify through here, so the recognized width
    /// set cannot diverge (the two-resolver defect class).
    pub const WidthInt = struct { width: u8, signed: bool };
    pub fn parseWidthInt(name: []const u8) ?WidthInt {
        if (name.len < 2) return null;
        if (name[0] != 'i' and name[0] != 'u') return null;
        const width = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (width < 1 or width > 64) return null;
        return .{ .width = width, .signed = name[0] == 'i' };
    }

    /// A bare name → its builtin `TypeId` (primitive keyword OR arbitrary-width
    /// integer), WITHOUT the named-struct / alias / stub fallthrough of
    /// `resolveNamed`. null for any non-builtin name. The shared builtin
    /// classifier: `resolveNamed` resolves through it first (then continues to
    /// struct/alias resolution), and the numeric-limit accessor intercept uses
    /// it to recover the queried type.
    pub fn resolveBuiltinName(name: []const u8, table: *TypeTable) ?TypeId {
        if (resolvePrimitive(name)) |id| return id;
        if (parseWidthInt(name)) |wi| {
            return if (wi.signed) table.intern(.{ .signed = wi.width }) else table.intern(.{ .unsigned = wi.width });
        }
        return null;
    }

    /// Width + signedness of a builtin INTEGER type NAME: the `i`/`u` widths via
    /// `parseWidthInt`, plus `usize`/`isize` (target-width = 64 on the host).
    /// null for a non-integer name (floats, `bool`, `string`, a user type, …) —
    /// so the `.min`/`.max` fold fires for integers only.
    pub fn integerWidthSign(name: []const u8) ?WidthInt {
        if (parseWidthInt(name)) |wi| return wi;
        if (std.mem.eql(u8, name, "usize")) return .{ .width = 64, .signed = false };
        if (std.mem.eql(u8, name, "isize")) return .{ .width = 64, .signed = true };
        return null;
    }

    /// The two's-complement bit pattern (as a raw `i64`) of a fixed-width integer
    /// type's `.min`/`.max`. Pure `(width, signedness)` arithmetic — never a
    /// per-name table. `sN`: min = -(2^(N-1)), max = 2^(N-1)-1. `uN`: min = 0,
    /// max = 2^N-1. The all-ones `u64.max`/`usize.max` (18446744073709551615)
    /// exceeds `i64`'s max, so it is returned as its bit pattern (`-1` as `i64`);
    /// the caller pairs it with the `u64`/`usize` `TypeId` so no signed path
    /// re-signs it.
    pub fn integerLimitBits(wi: WidthInt, want_max: bool) i64 {
        if (wi.signed) {
            const half_shift: u6 = @intCast(wi.width - 1);
            const half: u64 = @as(u64, 1) << half_shift; // 2^(width-1)
            return if (want_max) @bitCast(half - 1) else @bitCast(0 -% half);
        }
        if (!want_max) return 0; // unsigned min
        const lead: u6 = @intCast(64 - @as(u8, wi.width));
        return @bitCast((~@as(u64, 0)) >> lead); // 2^width - 1
    }

    /// `<IntType>.min` / `.max` → the type's limit as a raw `i64`, or null when
    /// `name` is not a builtin integer type or `field` is not `min`/`max`. THE
    /// single name+field → value fold, shared by the value path (lower.zig) and
    /// the comptime-int / array-dim path (program_index.evalConstIntExpr) so the
    /// two cannot disagree on what `u8.max` evaluates to.
    pub fn integerLimitFor(name: []const u8, field: []const u8) ?i64 {
        const want_max = std.mem.eql(u8, field, "max");
        if (!want_max and !std.mem.eql(u8, field, "min")) return null;
        const wi = integerWidthSign(name) orelse return null;
        return integerLimitBits(wi, want_max);
    }

    /// The full numeric-limit accessor field set: `.min`/`.max` (valid on int AND
    /// float) plus the float-only `.epsilon`/`.min_positive`/`.true_min`/`.inf`/
    /// `.nan`. THE single trigger for the `lowerNumericLimit` intercept — only a
    /// field in this set is treated as a limit access; anything else falls through
    /// to ordinary field lowering. Keeps the accessor name set in one place so the
    /// intercept and `expr_typer` can't recognize different surfaces.
    pub fn isLimitField(field: []const u8) bool {
        const names = [_][]const u8{ "min", "max", "epsilon", "min_positive", "true_min", "inf", "nan" };
        for (names) |n| if (std.mem.eql(u8, field, n)) return true;
        return false;
    }

    /// `<FloatType>.<field>` → the limit as an `f64` value (the queried type is
    /// `f32`/`f64`; every f32 limit is exactly representable in f64, so widening
    /// is lossless and the caller pairs the value with the queried `TypeId` —
    /// `builder.constFloat` narrows it back at emit), or null when `name` is not a
    /// builtin float type or `field` is not a limit accessor. Values come straight
    /// from `std.math` (`floatMax`/`floatEps`/`floatMin`/`floatTrueMin`/`inf`/`nan`):
    ///   - `.min` = most-NEGATIVE finite (`-max`, NOT C's DBL_MIN)
    ///   - `.max` = largest finite
    ///   - `.epsilon` = ULP of 1.0 (`floatEps`; f64 = 2^-52, f32 = 2^-23)
    ///   - `.min_positive` = smallest positive NORMAL (`floatMin`; = C DBL_MIN)
    ///   - `.true_min` = smallest positive SUBNORMAL (`floatTrueMin`)
    ///   - `.inf` = +infinity, `.nan` = a quiet NaN
    /// THE single name+field → float fold, shared by the value path (lower.zig)
    /// and `expr_typer` so they can't disagree.
    pub fn floatLimitFor(name: []const u8, field: []const u8) ?f64 {
        if (std.mem.eql(u8, name, "f64")) return floatLimitValue(f64, field);
        if (std.mem.eql(u8, name, "f32")) return floatLimitValue(f32, field);
        return null;
    }

    fn floatLimitValue(comptime T: type, field: []const u8) ?f64 {
        if (std.mem.eql(u8, field, "min")) return -@as(f64, std.math.floatMax(T));
        if (std.mem.eql(u8, field, "max")) return @as(f64, std.math.floatMax(T));
        if (std.mem.eql(u8, field, "epsilon")) return @as(f64, std.math.floatEps(T));
        if (std.mem.eql(u8, field, "min_positive")) return @as(f64, std.math.floatMin(T));
        if (std.mem.eql(u8, field, "true_min")) return @as(f64, std.math.floatTrueMin(T));
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
    /// algorithm (architecture A2.3b — `resolveCompound` is the single owner).
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
                break :blk table.functionTypeCC(param_ids.items, ret_ty, cc);
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

    /// Intern a `.tuple` TypeId from a list of field-type nodes (+ optional
    /// names) — the shared body of the `tuple_type_expr` and `return_type_expr`
    /// resolution arms. Returns null to defer a spread to the (stateful)
    /// PackResolver, `.unresolved` if any field is non-type, else the tuple.
    fn internTupleLike(table: *TypeTable, field_types: []const *Node, field_names: ?[]const []const u8, inner: anytype) ?TypeId {
        // A spread field `(..xs)` expands to many fields via the pack state —
        // defer to PackResolver by returning null.
        for (field_types) |ft| if (ft.data == .spread_expr) return null;
        var field_ids = std.ArrayList(TypeId).empty;
        defer field_ids.deinit(table.alloc);
        for (field_types) |ft| {
            const fid = inner.resolveInner(ft);
            // A non-type element (e.g. the `1` in `Tuple(i32, 1)`) resolves to
            // `.unresolved`; never intern a tuple carrying it — that bogus type
            // would reach LLVM emission and panic. The user-facing diagnostic is
            // emitted by the literal-rejection arm in `resolveTypeArg`; here we
            // just refuse to fabricate the type, propagating the sentinel up.
            if (fid == .unresolved) return .unresolved;
            field_ids.append(table.alloc, fid) catch return .unresolved;
        }
        // Preserve field names for a named tuple `(x: T, y: U)` when the name and
        // field counts agree (so `t.x` resolves).
        var name_ids: ?[]const StringId = null;
        if (field_names) |names| {
            if (names.len == field_ids.items.len) {
                var ids = std.ArrayList(StringId).empty;
                for (names) |n| ids.append(table.alloc, table.internString(n)) catch return .unresolved;
                name_ids = ids.toOwnedSlice(table.alloc) catch null;
            }
        }
        return table.intern(.{ .tuple = .{
            .fields = table.alloc.dupe(TypeId, field_ids.items) catch return .unresolved,
            .names = name_ids,
        } });
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

    /// Resolve a bare type NAME to a `TypeId`: primitive → arbitrary-width int
    /// (`i1`–`u64`) → string-form pointer/slice/optional prefixes → already-
    /// registered named type → alias (`alias_map`) → fresh empty-struct stub.
    /// `alias_map` is the single-source alias table (owned by `ProgramIndex`);
    /// callers pass it explicitly — Lowering via the index (`resolveName`),
    /// `type_bridge` via the alias map threaded through `resolveAstType`. The
    /// stub fall-through preserves long-standing behavior for as-yet-
    /// unregistered names.
    ///
    /// `skip_builtin` is the backtick raw-identifier escape (`` `i2 `` in type
    /// position): a raw reference is the LITERAL name used as a
    /// type, so it bypasses the builtin/reserved classifier and resolves only
    /// through registered-type → alias → stub. A bare `i2` keeps the default
    /// (`false`) and resolves to the builtin int type. The string-prefix
    /// recursion always passes `false`: the inner names (`*T`/`?T`) are bare,
    /// never raw.
    pub fn resolveNamed(name: []const u8, table: *TypeTable, alias_map: ?*const std.StringHashMap(TypeId), skip_builtin: bool) TypeId {
        // Builtin primitive keyword or arbitrary-width integer (`i1`-`i64`,
        // `u1`-`u64`) — the single builtin classifier, also reused by the
        // numeric-limit accessor intercept.
        if (!skip_builtin) {
            if (resolveBuiltinName(name, table)) |id| return id;
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
