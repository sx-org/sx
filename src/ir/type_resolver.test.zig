const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;
const types = @import("types.zig");
const TypeTable = types.TypeTable;
const TypeId = types.TypeId;
const tr_mod = @import("type_resolver.zig");
const TypeResolver = tr_mod.TypeResolver;
const ResolveEnv = tr_mod.ResolveEnv;
const ProgramIndex = @import("program_index.zig").ProgramIndex;

fn typeExpr(name: []const u8) Node {
    return .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = name, .is_generic = false } } };
}

/// Stand-in for `Lowering.resolveInner`: the real hook recurses the full
/// stateful resolver; here element types are always primitives, resolved via
/// the keyword table.
const PrimInner = struct {
    pub fn resolveInner(_: PrimInner, node: *const Node) TypeId {
        return switch (node.data) {
            .type_expr => |te| TypeResolver.resolvePrimitive(te.name) orelse .unresolved,
            else => .unresolved,
        };
    }
    pub fn resolveArrayLen(_: PrimInner, len_node: *const Node) ?u32 {
        return switch (len_node.data) {
            .int_literal => |lit| @intCast(lit.value),
            else => null,
        };
    }
};

test "TypeResolver.resolvePrimitive maps builtin keywords, null otherwise" {
    try std.testing.expectEqual(@as(?TypeId, .i64), TypeResolver.resolvePrimitive("i64"));
    try std.testing.expectEqual(@as(?TypeId, .bool), TypeResolver.resolvePrimitive("bool"));
    try std.testing.expectEqual(@as(?TypeId, .f64), TypeResolver.resolvePrimitive("f64"));
    try std.testing.expectEqual(@as(?TypeId, .void), TypeResolver.resolvePrimitive("void"));
    try std.testing.expectEqual(@as(?TypeId, .any), TypeResolver.resolvePrimitive("any"));
    try std.testing.expectEqual(@as(?TypeId, .type_value), TypeResolver.resolvePrimitive("Type"));
    try std.testing.expectEqual(@as(?TypeId, .usize), TypeResolver.resolvePrimitive("usize"));
    try std.testing.expectEqual(@as(?TypeId, .isize), TypeResolver.resolvePrimitive("isize"));
    try std.testing.expectEqual(@as(?TypeId, .noreturn), TypeResolver.resolvePrimitive("noreturn"));
    // Non-primitives (aliases / generics / named structs) defer to the caller.
    try std.testing.expect(TypeResolver.resolvePrimitive("List") == null);
    try std.testing.expect(TypeResolver.resolvePrimitive("ShaderHandle") == null);
    try std.testing.expect(TypeResolver.resolvePrimitive("") == null);
}

test "TypeResolver.resolveCompound builds structural compound types" {
    // Arena-backed: interned tuple field slices are owned by the type table and
    // reclaimed in bulk by the real compiler's arena (never freed individually).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var table = TypeTable.init(alloc);
    const inner = PrimInner{};

    var s64n = typeExpr("i64");
    var u8n = typeExpr("u8");
    var f32n = typeExpr("f32");
    var booln = typeExpr("bool");
    var s32n = typeExpr("i32");

    var ptr = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .pointer_type_expr = .{ .pointee_type = &s64n } } };
    try std.testing.expectEqual(@as(?TypeId, table.ptrTo(.i64)), TypeResolver.resolveCompound(&table, &ptr, inner));

    var mptr = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .many_pointer_type_expr = .{ .element_type = &u8n } } };
    try std.testing.expectEqual(@as(?TypeId, table.manyPtrTo(.u8)), TypeResolver.resolveCompound(&table, &mptr, inner));

    var slice = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .slice_type_expr = .{ .element_type = &f32n } } };
    try std.testing.expectEqual(@as(?TypeId, table.sliceOf(.f32)), TypeResolver.resolveCompound(&table, &slice, inner));

    var opt = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .optional_type_expr = .{ .inner_type = &booln } } };
    try std.testing.expectEqual(@as(?TypeId, table.optionalOf(.bool)), TypeResolver.resolveCompound(&table, &opt, inner));

    var len = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = 3 } } };
    var arr = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .array_type_expr = .{ .length = &len, .element_type = &s32n } } };
    try std.testing.expectEqual(@as(?TypeId, table.arrayOf(.i32, 3)), TypeResolver.resolveCompound(&table, &arr, inner));

    // Function type `(i64) -> bool` — resolveCompound owns it (A2.3b).
    const fparams = [_]*Node{&s64n};
    var fnode = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .function_type_expr = .{ .param_types = &fparams, .return_type = &booln } } };
    try std.testing.expectEqual(@as(?TypeId, table.functionTypeCC(&[_]TypeId{.i64}, .bool, .default)), TypeResolver.resolveCompound(&table, &fnode, inner));

    // Plain closure `Closure(i64) -> bool` (no pack) — owned here.
    const cparams = [_]*Node{&s64n};
    var cnode = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .closure_type_expr = .{ .param_types = &cparams, .return_type = &booln } } };
    try std.testing.expectEqual(@as(?TypeId, table.closureType(&[_]TypeId{.i64}, .bool)), TypeResolver.resolveCompound(&table, &cnode, inner));

    // Plain positional tuple `(i64, bool)` — owned here.
    const tfields = [_]*Node{ &s64n, &booln };
    var tnode = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .tuple_type_expr = .{ .field_types = &tfields, .field_names = null } } };
    const want_tuple = table.intern(.{ .tuple = .{ .fields = &[_]TypeId{ .i64, .bool }, .names = null } });
    try std.testing.expectEqual(@as(?TypeId, want_tuple), TypeResolver.resolveCompound(&table, &tnode, inner));

    // Pack-shaped `Closure(..p)` → null (needs caller pack state → PackResolver).
    var cpack = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .closure_type_expr = .{ .param_types = &.{}, .return_type = &booln, .pack_name = "p" } } };
    try std.testing.expect(TypeResolver.resolveCompound(&table, &cpack, inner) == null);

    // Spread tuple `(..xs)` → null (a spread field needs pack expansion).
    var spread_op = typeExpr("xs");
    var spread = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .spread_expr = .{ .operand = &spread_op } } };
    const sfields = [_]*Node{&spread};
    var snode = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .tuple_type_expr = .{ .field_types = &sfields, .field_names = null } } };
    try std.testing.expect(TypeResolver.resolveCompound(&table, &snode, inner) == null);

    // Names / parameterized types are not this resolver's responsibility → null.
    var name = typeExpr("List");
    try std.testing.expect(TypeResolver.resolveCompound(&table, &name, inner) == null);
}

test "ResolveEnv default-constructs with all-null context" {
    const env = ResolveEnv{};
    try std.testing.expect(env.type_bindings == null);
    try std.testing.expect(env.pack_bindings == null);
    try std.testing.expect(env.target_type == null);
}

test "TypeResolver.resolveBinding reads ResolveEnv type bindings ($T)" {
    const alloc = std.testing.allocator;
    var tb = std.StringHashMap(TypeId).init(alloc);
    defer tb.deinit();
    try tb.put("T", .i64);
    const env = ResolveEnv{ .type_bindings = &tb };

    var bound = typeExpr("T");
    try std.testing.expectEqual(@as(?TypeId, .i64), TypeResolver.resolveBinding(&bound, env));
    // Unbound name → null (caller continues with primitive / alias / struct).
    var unbound = typeExpr("U");
    try std.testing.expect(TypeResolver.resolveBinding(&unbound, env) == null);
    // No active bindings → null.
    try std.testing.expect(TypeResolver.resolveBinding(&bound, ResolveEnv{}) == null);
}

test "TypeResolver.resolveName resolves aliases via ProgramIndex (not the TypeTable.aliases borrow)" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();
    var index = ProgramIndex.init(alloc);
    defer index.deinit();
    try index.type_alias_map.put("ShaderHandle", .u32); // alias → primitive
    const ptr_i64 = table.ptrTo(.i64);
    try index.type_alias_map.put("NodeRef", ptr_i64); // alias → pointer
    const tr = TypeResolver{ .alloc = alloc, .types = &table, .diagnostics = null, .index = &index };

    try std.testing.expectEqual(@as(TypeId, .u32), tr.resolveName("ShaderHandle", false));
    try std.testing.expectEqual(ptr_i64, tr.resolveName("NodeRef", false));
    // Primitive is checked before alias.
    try std.testing.expectEqual(@as(TypeId, .i64), tr.resolveName("i64", false));
}

test "TypeResolver.resolveNamed: width-int, string-prefix, unknown→stub" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();
    try std.testing.expectEqual(table.intern(.{ .signed = 7 }), TypeResolver.resolveNamed("i7", &table, null, false));
    try std.testing.expectEqual(table.ptrTo(.i64), TypeResolver.resolveNamed("*i64", &table, null, false));
    // Unknown name, no alias map → empty-struct stub (preserved behavior;
    // never `.unresolved`, which is reserved for failed *generic* resolution).
    try std.testing.expect(TypeResolver.resolveNamed("Unknown", &table, null, false) != .unresolved);
}

test "TypeResolver.resolveNamed: skip_builtin resolves a raw reserved-name type, not the builtin" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();
    // A registered user type named "i2" (a reserved int spelling).
    const name_id = table.internString("i2");
    const user_i2 = table.intern(.{ .@"struct" = .{ .name = name_id, .fields = &.{} } });
    // Bare lookup → the builtin 2-bit signed int; raw lookup → the user type.
    try std.testing.expectEqual(table.intern(.{ .signed = 2 }), TypeResolver.resolveNamed("i2", &table, null, false));
    try std.testing.expectEqual(user_i2, TypeResolver.resolveNamed("i2", &table, null, true));
}

test "TypeResolver.parseWidthInt: every width 1..64, both signs; rejects out-of-range / non-int" {
    // The single width parser — covers the named primitives (i8/u64/…) too.
    try std.testing.expectEqual(@as(?TypeResolver.WidthInt, .{ .width = 1, .signed = true }), TypeResolver.parseWidthInt("i1"));
    try std.testing.expectEqual(@as(?TypeResolver.WidthInt, .{ .width = 3, .signed = true }), TypeResolver.parseWidthInt("i3"));
    try std.testing.expectEqual(@as(?TypeResolver.WidthInt, .{ .width = 64, .signed = true }), TypeResolver.parseWidthInt("i64"));
    try std.testing.expectEqual(@as(?TypeResolver.WidthInt, .{ .width = 1, .signed = false }), TypeResolver.parseWidthInt("u1"));
    try std.testing.expectEqual(@as(?TypeResolver.WidthInt, .{ .width = 64, .signed = false }), TypeResolver.parseWidthInt("u64"));
    // Width 0 and >64, and non-`s`/`u` names, are not width-ints.
    try std.testing.expect(TypeResolver.parseWidthInt("i0") == null);
    try std.testing.expect(TypeResolver.parseWidthInt("u65") == null);
    try std.testing.expect(TypeResolver.parseWidthInt("usize") == null);
    try std.testing.expect(TypeResolver.parseWidthInt("f32") == null);
    try std.testing.expect(TypeResolver.parseWidthInt("sx") == null);
    try std.testing.expect(TypeResolver.parseWidthInt("s") == null);
}

test "TypeResolver.integerWidthSign: width-ints plus usize/isize, null for non-integers" {
    try std.testing.expectEqual(@as(?TypeResolver.WidthInt, .{ .width = 64, .signed = false }), TypeResolver.integerWidthSign("usize"));
    try std.testing.expectEqual(@as(?TypeResolver.WidthInt, .{ .width = 64, .signed = true }), TypeResolver.integerWidthSign("isize"));
    try std.testing.expectEqual(@as(?TypeResolver.WidthInt, .{ .width = 8, .signed = false }), TypeResolver.integerWidthSign("u8"));
    // Non-integer builtins and user names are not integer types.
    try std.testing.expect(TypeResolver.integerWidthSign("f64") == null);
    try std.testing.expect(TypeResolver.integerWidthSign("bool") == null);
    try std.testing.expect(TypeResolver.integerWidthSign("void") == null);
    try std.testing.expect(TypeResolver.integerWidthSign("MyStruct") == null);
}

test "TypeResolver.integerLimitFor: pinned min/max across widths and extremes" {
    const L = struct {
        fn v(name: []const u8, field: []const u8) i64 {
            return TypeResolver.integerLimitFor(name, field).?;
        }
    };
    // Sub-byte widths (arbitrary bit-width arithmetic, not a per-name table).
    try std.testing.expectEqual(@as(i64, -1), L.v("i1", "min"));
    try std.testing.expectEqual(@as(i64, 0), L.v("i1", "max"));
    try std.testing.expectEqual(@as(i64, -2), L.v("i2", "min"));
    try std.testing.expectEqual(@as(i64, 1), L.v("i2", "max"));
    try std.testing.expectEqual(@as(i64, 3), L.v("i3", "max"));
    try std.testing.expectEqual(@as(i64, 0), L.v("u1", "min"));
    try std.testing.expectEqual(@as(i64, 1), L.v("u1", "max"));
    try std.testing.expectEqual(@as(i64, 3), L.v("u2", "max"));
    // Byte / word.
    try std.testing.expectEqual(@as(i64, -128), L.v("i8", "min"));
    try std.testing.expectEqual(@as(i64, 127), L.v("i8", "max"));
    try std.testing.expectEqual(@as(i64, 255), L.v("u8", "max"));
    try std.testing.expectEqual(@as(i64, -2147483648), L.v("i32", "min"));
    try std.testing.expectEqual(@as(i64, 2147483647), L.v("i32", "max"));
    // i64 extremes = i64 extremes.
    try std.testing.expectEqual(std.math.minInt(i64), L.v("i64", "min"));
    try std.testing.expectEqual(std.math.maxInt(i64), L.v("i64", "max"));
    // u63.max fits i64; u64.max is all-ones (= -1 as i64, maxInt(u64) as u64).
    try std.testing.expectEqual(std.math.maxInt(i64), L.v("u63", "max"));
    try std.testing.expectEqual(@as(i64, -1), L.v("u64", "max"));
    try std.testing.expectEqual(std.math.maxInt(u64), @as(u64, @bitCast(L.v("u64", "max"))));
    try std.testing.expectEqual(@as(i64, 0), L.v("u64", "min"));
    // usize/isize track u64/i64 on the host.
    try std.testing.expectEqual(L.v("u64", "max"), L.v("usize", "max"));
    try std.testing.expectEqual(@as(i64, 0), L.v("usize", "min"));
    try std.testing.expectEqual(L.v("i64", "min"), L.v("isize", "min"));
    try std.testing.expectEqual(L.v("i64", "max"), L.v("isize", "max"));
}

test "TypeResolver.integerLimitFor: null for non-integer receivers and non-limit fields" {
    // Float / non-numeric / user names are not integer-limit folds.
    try std.testing.expect(TypeResolver.integerLimitFor("f64", "max") == null);
    try std.testing.expect(TypeResolver.integerLimitFor("bool", "max") == null);
    try std.testing.expect(TypeResolver.integerLimitFor("void", "min") == null);
    try std.testing.expect(TypeResolver.integerLimitFor("MyStruct", "min") == null);
    // A builtin int with a non-limit field is not a fold here.
    try std.testing.expect(TypeResolver.integerLimitFor("i64", "len") == null);
    try std.testing.expect(TypeResolver.integerLimitFor("u8", "epsilon") == null);
}

test "TypeResolver.isLimitField: the accessor set, nothing else" {
    // The full numeric-limit surface — int .min/.max plus the float-only ones.
    for ([_][]const u8{ "min", "max", "epsilon", "min_positive", "true_min", "inf", "nan" }) |f| {
        try std.testing.expect(TypeResolver.isLimitField(f));
    }
    // Ordinary fields / near-misses are not limit accessors.
    try std.testing.expect(!TypeResolver.isLimitField("len"));
    try std.testing.expect(!TypeResolver.isLimitField("ptr"));
    try std.testing.expect(!TypeResolver.isLimitField("maximum"));
    try std.testing.expect(!TypeResolver.isLimitField("Min"));
    try std.testing.expect(!TypeResolver.isLimitField(""));
}

test "TypeResolver.floatLimitFor: pinned f64 bit patterns" {
    const L = struct {
        fn bits(name: []const u8, field: []const u8) u64 {
            return @bitCast(TypeResolver.floatLimitFor(name, field).?);
        }
    };
    // Exact IEEE-754 double bit patterns (the same values the example pins via
    // a runtime bit reinterpret).
    try std.testing.expectEqual(@as(u64, 0x7FEFFFFFFFFFFFFF), L.bits("f64", "max"));
    try std.testing.expectEqual(@as(u64, 0xFFEFFFFFFFFFFFFF), L.bits("f64", "min")); // -max
    try std.testing.expectEqual(@as(u64, 0x3CB0000000000000), L.bits("f64", "epsilon"));
    try std.testing.expectEqual(@as(u64, 0x0010000000000000), L.bits("f64", "min_positive"));
    try std.testing.expectEqual(@as(u64, 0x0000000000000001), L.bits("f64", "true_min"));
    try std.testing.expectEqual(@as(u64, 0x7FF0000000000000), L.bits("f64", "inf"));
    // .min = -max (NOT C's DBL_MIN, which is min_positive); the ordering holds.
    const v = struct {
        fn f(name: []const u8, field: []const u8) f64 {
            return TypeResolver.floatLimitFor(name, field).?;
        }
    };
    try std.testing.expectEqual(v.f("f64", "min"), -v.f("f64", "max"));
    try std.testing.expect(v.f("f64", "true_min") < v.f("f64", "min_positive"));
    try std.testing.expect(v.f("f64", "true_min") > 0.0);
    try std.testing.expect(std.math.isInf(v.f("f64", "inf")));
    // Quiet NaN: unequal to itself; exact mantissa bits intentionally not pinned.
    try std.testing.expect(std.math.isNan(v.f("f64", "nan")));
}

test "TypeResolver.floatLimitFor: pinned f32 bit patterns (widened value narrows losslessly)" {
    const L = struct {
        // floatLimitFor widens every f32 limit to f64; narrowing back is lossless
        // (the codegen path does the same via constFloat at the queried width).
        fn bits(name: []const u8, field: []const u8) u32 {
            return @bitCast(@as(f32, @floatCast(TypeResolver.floatLimitFor(name, field).?)));
        }
    };
    try std.testing.expectEqual(@as(u32, 0x7F7FFFFF), L.bits("f32", "max"));
    try std.testing.expectEqual(@as(u32, 0xFF7FFFFF), L.bits("f32", "min")); // -max
    try std.testing.expectEqual(@as(u32, 0x34000000), L.bits("f32", "epsilon"));
    try std.testing.expectEqual(@as(u32, 0x00800000), L.bits("f32", "min_positive"));
    try std.testing.expectEqual(@as(u32, 0x00000001), L.bits("f32", "true_min"));
    try std.testing.expectEqual(@as(u32, 0x7F800000), L.bits("f32", "inf"));
    const nan_v: f32 = @floatCast(TypeResolver.floatLimitFor("f32", "nan").?);
    try std.testing.expect(std.math.isNan(nan_v));
}

test "TypeResolver.floatLimitFor: null for non-float receivers and non-limit fields" {
    // Integer / non-numeric / user names are not float-limit folds.
    try std.testing.expect(TypeResolver.floatLimitFor("i32", "epsilon") == null);
    try std.testing.expect(TypeResolver.floatLimitFor("u64", "max") == null);
    try std.testing.expect(TypeResolver.floatLimitFor("usize", "min") == null);
    try std.testing.expect(TypeResolver.floatLimitFor("bool", "nan") == null);
    try std.testing.expect(TypeResolver.floatLimitFor("MyStruct", "inf") == null);
    // A builtin float with a non-limit field is not a fold here.
    try std.testing.expect(TypeResolver.floatLimitFor("f64", "len") == null);
    try std.testing.expect(TypeResolver.floatLimitFor("f32", "ptr") == null);
}
