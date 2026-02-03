// Tests for types.zig
const std = @import("std");
const types = @import("types.zig");
const ast = @import("../ast.zig");
const TypeId = types.TypeId;
const TypeTable = types.TypeTable;
const TypeInfo = types.TypeInfo;

test "builtin types pre-populated" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    // Verify builtin slots
    try std.testing.expectEqual(TypeInfo.void, table.get(.void));
    try std.testing.expectEqual(TypeInfo.bool, table.get(.bool));
    try std.testing.expectEqual(TypeInfo{ .signed = 32 }, table.get(.i32));
    try std.testing.expectEqual(TypeInfo{ .unsigned = 8 }, table.get(.u8));
    try std.testing.expectEqual(TypeInfo.f64, table.get(.f64));
    try std.testing.expectEqual(TypeInfo.string, table.get(.string));
    try std.testing.expectEqual(TypeInfo.any, table.get(.any));
}

test "intern deduplicates structural types" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const ptr1 = table.ptrTo(.i32);
    const ptr2 = table.ptrTo(.i32);
    try std.testing.expectEqual(ptr1, ptr2);

    const ptr3 = table.ptrTo(.f64);
    try std.testing.expect(ptr1 != ptr3);
}

test "slice and array interning" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const slice1 = table.sliceOf(.i32);
    const slice2 = table.sliceOf(.i32);
    try std.testing.expectEqual(slice1, slice2);

    const arr1 = table.arrayOf(.u8, 10);
    const arr2 = table.arrayOf(.u8, 10);
    const arr3 = table.arrayOf(.u8, 20);
    try std.testing.expectEqual(arr1, arr2);
    try std.testing.expect(arr1 != arr3);
}

test "optional interning" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const opt1 = table.optionalOf(.i32);
    const opt2 = table.optionalOf(.i32);
    try std.testing.expectEqual(opt1, opt2);

    const opt3 = table.optionalOf(.f64);
    try std.testing.expect(opt1 != opt3);
}

test "function type interning" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const params = &[_]TypeId{ .i32, .i32 };
    const fn1 = table.functionType(params, .i64);
    const fn2 = table.functionType(params, .i64);
    try std.testing.expectEqual(fn1, fn2);

    const fn3 = table.functionType(params, .f64);
    try std.testing.expect(fn1 != fn3);
}

test "string pool interning" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const id1 = table.internString("Point");
    const id2 = table.internString("Point");
    const id3 = table.internString("Rect");

    try std.testing.expectEqual(id1, id2);
    try std.testing.expect(id1 != id3);
    try std.testing.expectEqualStrings("Point", table.getString(id1));
    try std.testing.expectEqualStrings("Rect", table.getString(id3));
}

test "sizeOf builtins" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    try std.testing.expectEqual(@as(u32, 0), table.sizeOf(.void));
    try std.testing.expectEqual(@as(u32, 1), table.sizeOf(.bool));
    try std.testing.expectEqual(@as(u32, 4), table.sizeOf(.i32));
    try std.testing.expectEqual(@as(u32, 8), table.sizeOf(.i64));
    try std.testing.expectEqual(@as(u32, 1), table.sizeOf(.u8));
    try std.testing.expectEqual(@as(u32, 4), table.sizeOf(.f32));
    try std.testing.expectEqual(@as(u32, 8), table.sizeOf(.f64));
    try std.testing.expectEqual(@as(u32, 16), table.sizeOf(.string));
    try std.testing.expectEqual(@as(u32, 8), table.sizeOf(table.ptrTo(.i32)));
    try std.testing.expectEqual(@as(u32, 16), table.sizeOf(table.sliceOf(.i32)));
}

test "typeName for builtins" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    try std.testing.expectEqualStrings("i32", table.typeName(.i32));
    try std.testing.expectEqualStrings("bool", table.typeName(.bool));
    try std.testing.expectEqualStrings("string", table.typeName(.string));
    try std.testing.expectEqualStrings("void", table.typeName(.void));
    try std.testing.expectEqualStrings("any", table.typeName(.any));
}

// ── Pack type (Feature 1, Step 2.1) ──────────────────────────────────

test "pack type: construct, element access, intern dedup (N=3)" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const elems = &[_]TypeId{ .bool, .i32, .string };
    const p1 = table.packType(elems);
    const p2 = table.packType(elems);
    try std.testing.expectEqual(p1, p2); // structural dedup

    const info = table.get(p1);
    try std.testing.expect(info == .pack);
    try std.testing.expectEqual(@as(usize, 3), info.pack.elements.len);
    try std.testing.expectEqual(TypeId.bool, info.pack.elements[0]);
    try std.testing.expectEqual(TypeId.i32, info.pack.elements[1]);
    try std.testing.expectEqual(TypeId.string, info.pack.elements[2]);
}

test "pack type: empty pack (N=0)" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const empty1 = table.packType(&.{});
    const empty2 = table.packType(&.{});
    try std.testing.expectEqual(empty1, empty2);
    const info = table.get(empty1);
    try std.testing.expect(info == .pack);
    try std.testing.expectEqual(@as(usize, 0), info.pack.elements.len);
}

test "pack type: single element (N=1)" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const p = table.packType(&[_]TypeId{.f64});
    const info = table.get(p);
    try std.testing.expectEqual(@as(usize, 1), info.pack.elements.len);
    try std.testing.expectEqual(TypeId.f64, info.pack.elements[0]);
}

test "pack type: distinct element lists are distinct types" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const a = table.packType(&[_]TypeId{ .bool, .i32 });
    const b = table.packType(&[_]TypeId{ .i32, .bool }); // order matters
    const c = table.packType(&[_]TypeId{.bool}); // arity matters
    try std.testing.expect(a != b);
    try std.testing.expect(a != c);
    try std.testing.expect(b != c);
    // A pack is distinct from the tuple of the same elements.
    const tup = table.intern(.{ .tuple = .{ .fields = &[_]TypeId{ .bool, .i32 }, .names = null } });
    try std.testing.expect(a != tup);
}

test "pack type: formatTypeName" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const p = table.packType(&[_]TypeId{ .bool, .i32, .string });
    try std.testing.expectEqualStrings("pack(bool, i32, string)", table.formatTypeName(arena.allocator(), p));

    const empty = table.packType(&.{});
    try std.testing.expectEqualStrings("pack()", table.formatTypeName(arena.allocator(), empty));
}

// ── ERR E1.1 (Slice 1) — error sets + tag registry ──

test "TagRegistry interns tags, id 0 reserved, global identity" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const bad = table.internTag("BadDigit");
    const over = table.internTag("Overflow");
    const bad_again = table.internTag("BadDigit");

    try std.testing.expect(bad >= 1); // id 0 reserved for "no error"
    try std.testing.expect(bad != over); // distinct names → distinct ids
    try std.testing.expectEqual(bad, bad_again); // same name → same id (global-flat)
    try std.testing.expectEqualStrings("BadDigit", table.getTagName(bad));
    try std.testing.expectEqualStrings("Overflow", table.getTagName(over));
    try std.testing.expectEqualStrings("", table.getTagName(0)); // reserved slot
}

test "errorSetType: u32 layout, named display, dedup by name" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const name = table.internString("ParseErr");
    const tags = [_]u32{ table.internTag("BadDigit"), table.internTag("Overflow"), table.internTag("Empty") };
    const set = table.errorSetType(name, &tags);

    // u32 runtime layout (the error channel's tag value).
    try std.testing.expectEqual(@as(u32, 4), table.sizeOf(set));
    try std.testing.expectEqual(@as(usize, 4), table.typeSizeBytes(set));
    try std.testing.expectEqual(@as(usize, 4), table.typeAlignBytes(set));
    // Displays by name; resolvable by name.
    try std.testing.expectEqualStrings("ParseErr", table.typeName(set));
    try std.testing.expectEqual(set, table.findByName(name).?);
    // Info shape.
    const info = table.get(set);
    try std.testing.expect(info == .error_set);
    try std.testing.expectEqual(@as(usize, 3), info.error_set.tags.len);
    // Identity is the name → re-constructing the same set dedups.
    try std.testing.expectEqual(set, table.errorSetType(name, &tags));
}

test "errorSetType: tags stored sorted by global id" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const name = table.internString("E");
    const c = table.internTag("C");
    const a = table.internTag("A");
    const b = table.internTag("B");
    // Pass out of order; errorSetType sorts for canonical storage.
    const set = table.errorSetType(name, &[_]u32{ c, a, b });
    const stored = table.get(set).error_set.tags;
    try std.testing.expectEqual(@as(usize, 3), stored.len);
    try std.testing.expect(stored[0] <= stored[1] and stored[1] <= stored[2]);
}

test "isUnsignedInt: builtin signedness classification" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    // Unsigned builtins (the formatter must route these to unsigned decimal).
    inline for (.{ TypeId.u8, TypeId.u16, TypeId.u32, TypeId.u64, TypeId.usize }) |ty| {
        try std.testing.expect(table.isUnsignedInt(ty));
    }
    // Signed / non-integer builtins are not unsigned.
    inline for (.{
        TypeId.i8,    TypeId.i16, TypeId.i32,  TypeId.i64, TypeId.isize,
        TypeId.bool,  TypeId.f32, TypeId.f64,  TypeId.string,
        TypeId.void,  TypeId.any, TypeId.unresolved,
    }) |ty| {
        try std.testing.expect(!table.isUnsignedInt(ty));
    }
}

test "isUnsignedInt: user-defined arbitrary-width ints" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const u24_ty = table.intern(.{ .unsigned = 24 });
    const i24_ty = table.intern(.{ .signed = 24 });
    try std.testing.expect(table.isUnsignedInt(u24_ty));
    try std.testing.expect(!table.isUnsignedInt(i24_ty));

    // A non-integer user type is never unsigned.
    const ptr_ty = table.ptrTo(.u32);
    try std.testing.expect(!table.isUnsignedInt(ptr_ty));
}

// ── Phase D: nominal identity + key-safe mutation ───────────────────────

test "phase D: forward-decl field fill preserves intern key" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const foo = table.internString("Foo");
    const no_fields = [_]TypeInfo.StructInfo.Field{};
    const stub: TypeInfo = .{ .@"struct" = .{ .name = foo, .fields = &no_fields } };
    const id = table.internNominal(stub, 0);

    // Full definition arrives later; same name (and nominal id) → same key.
    const fields = [_]TypeInfo.StructInfo.Field{
        .{ .name = table.internString("x"), .ty = .i64 },
        .{ .name = table.internString("y"), .ty = .i64 },
    };
    table.updatePreservingKey(id, .{ .@"struct" = .{ .name = foo, .fields = &fields } });

    // TypeId stable, fields filled, and a fresh structural intern of the same
    // name still resolves to it (the field-fill didn't touch the key).
    try std.testing.expectEqual(@as(usize, 2), table.get(id).@"struct".fields.len);
    try std.testing.expectEqual(id, table.internNominal(stub, 0));
    try std.testing.expectEqual(id, table.findByName(foo).?);
}

test "phase D: anon rename re-keys intern_map" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const anon = table.internString("__anon");
    const fields = [_]TypeInfo.StructInfo.Field{
        .{ .name = table.internString("x"), .ty = .i64 },
    };
    const id = table.internNominal(.{ .@"struct" = .{ .name = anon, .fields = &fields } }, 0);
    try std.testing.expectEqual(id, table.findByName(anon).?);

    const qualified = table.internString("Parent.field");
    table.replaceKeyedInfo(id, .{ .@"struct" = .{ .name = qualified, .fields = &fields } });

    // Old name no longer resolves; new name does; same TypeId.
    try std.testing.expect(table.findByName(anon) == null);
    try std.testing.expectEqual(id, table.findByName(qualified).?);
    // Re-keyed: structural intern under the new name dedups to the same id...
    try std.testing.expectEqual(id, table.intern(.{ .@"struct" = .{ .name = qualified, .fields = &fields } }));
    // ...and the stale old key is gone, so a fresh "__anon" gets a NEW id.
    const fresh = table.intern(.{ .@"struct" = .{ .name = anon, .fields = &fields } });
    try std.testing.expect(fresh != id);
}

test "phase D: generic struct instantiation interns by distinct names" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const f1 = [_]TypeInfo.StructInfo.Field{.{ .name = table.internString("e"), .ty = .f32 }};
    const vec3a = table.internNominal(.{ .@"struct" = .{ .name = table.internString("Vec__3"), .fields = &f1 } }, 0);
    const vec4 = table.internNominal(.{ .@"struct" = .{ .name = table.internString("Vec__4"), .fields = &f1 } }, 0);
    // Distinct instantiations → distinct ids.
    try std.testing.expect(vec3a != vec4);
    // Re-instantiating the same monomorph → same id (structural dedup by name).
    const vec3b = table.internNominal(.{ .@"struct" = .{ .name = table.internString("Vec__3"), .fields = &f1 } }, 0);
    try std.testing.expectEqual(vec3a, vec3b);
    // A forward-decl fill on the instantiation keeps the id.
    const f2 = [_]TypeInfo.StructInfo.Field{
        .{ .name = table.internString("e"), .ty = .f32 },
        .{ .name = table.internString("f"), .ty = .f32 },
    };
    table.updatePreservingKey(vec3a, .{ .@"struct" = .{ .name = table.internString("Vec__3"), .fields = &f2 } });
    try std.testing.expectEqual(vec3a, table.findByName(table.internString("Vec__3")).?);
}

test "phase D: type-returning function result interns stably" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    // `Complex(u32)` registers a struct under the mangled alias name; interning
    // the same instantiation twice is stable.
    const name = table.internString("Complex__u32");
    const fields = [_]TypeInfo.StructInfo.Field{
        .{ .name = table.internString("re"), .ty = .u32 },
        .{ .name = table.internString("im"), .ty = .u32 },
    };
    const info: TypeInfo = .{ .@"struct" = .{ .name = name, .fields = &fields } };
    const a = table.internNominal(info, 0);
    const b = table.internNominal(info, 0);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(a, table.findByName(name).?);
}

test "phase D: parameterized protocol value struct interns stably" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    // `instantiateParamProtocol` registers a `{ctx, __vtable}` value struct
    // under a mangled name (e.g. `VL__i64`). Same instantiation → same id.
    const void_ptr = table.ptrTo(.void);
    const fields = [_]TypeInfo.StructInfo.Field{
        .{ .name = table.internString("ctx"), .ty = void_ptr },
        .{ .name = table.internString("__vtable"), .ty = void_ptr },
    };
    const info: TypeInfo = .{ .@"struct" = .{ .name = table.internString("VL__i64"), .fields = &fields, .is_protocol = true } };
    const a = table.intern(info);
    const b = table.intern(info);
    try std.testing.expectEqual(a, b);
    // A different parameterization is a different name → different id.
    const other = table.intern(.{ .@"struct" = .{ .name = table.internString("VL__f64"), .fields = &fields, .is_protocol = true } });
    try std.testing.expect(other != a);
}

test "phase D: same display-name distinct nominal ids" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const foo = table.internString("Foo");
    const f = [_]TypeInfo.StructInfo.Field{.{ .name = table.internString("x"), .ty = .i64 }};
    const base: TypeInfo = .{ .@"struct" = .{ .name = foo, .fields = &f } };

    const a = table.internNominal(base, 1);
    const b = table.internNominal(base, 2);
    const structural = table.internNominal(base, 0);
    // Three authors of "Foo" → three distinct TypeIds.
    try std.testing.expect(a != b);
    try std.testing.expect(a != structural);
    try std.testing.expect(b != structural);
    // Re-interning the same nominal id is idempotent.
    try std.testing.expectEqual(a, table.internNominal(base, 1));
    try std.testing.expectEqual(b, table.internNominal(base, 2));
    // The nominal id is recorded on the stored info.
    try std.testing.expectEqual(@as(u32, 1), table.get(a).@"struct".nominal_id);
    try std.testing.expectEqual(@as(u32, 2), table.get(b).@"struct".nominal_id);
    try std.testing.expectEqual(@as(u32, 0), table.get(structural).@"struct".nominal_id);

    // Same disambiguation holds for the enum and error_set nominal arms.
    const bar = table.internString("Bar");
    const variants = [_]types.StringId{ table.internString("a"), table.internString("b") };
    const e1 = table.internNominal(.{ .@"enum" = .{ .name = bar, .variants = &variants } }, 1);
    const e2 = table.internNominal(.{ .@"enum" = .{ .name = bar, .variants = &variants } }, 2);
    try std.testing.expect(e1 != e2);

    const baz = table.internString("Baz");
    const tags = [_]u32{ 1, 2 };
    const es1 = table.internNominal(.{ .error_set = .{ .name = baz, .tags = &tags } }, 1);
    const es2 = table.internNominal(.{ .error_set = .{ .name = baz, .tags = &tags } }, 2);
    try std.testing.expect(es1 != es2);
}

test "phase D: internNominal(.,0) is byte-identical to legacy intern (old==new)" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const f = [_]TypeInfo.StructInfo.Field{.{ .name = table.internString("x"), .ty = .i64 }};
    const variants = [_]types.StringId{table.internString("v")};
    const tags = [_]u32{7};

    const cases = [_]TypeInfo{
        .{ .@"struct" = .{ .name = table.internString("S"), .fields = &f } },
        .{ .@"enum" = .{ .name = table.internString("E"), .variants = &variants } },
        .{ .@"union" = .{ .name = table.internString("U"), .fields = &f } },
        .{ .tagged_union = .{ .name = table.internString("T"), .fields = &f, .tag_type = .i64 } },
        .{ .error_set = .{ .name = table.internString("Err"), .tags = &tags } },
    };
    for (cases) |info| {
        const old = table.intern(info); // legacy structural path
        const new = table.internNominal(info, 0); // new API, structural id
        try std.testing.expectEqual(old, new);
    }
}

test "phase D: findUniqueByName returns the sole match" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const foo = table.internString("Foo");
    try std.testing.expect(table.findUniqueByName(foo) == null);
    const id = table.internNominal(.{ .@"struct" = .{ .name = foo, .fields = &.{} } }, 0);
    try std.testing.expectEqual(id, table.findUniqueByName(foo).?);
}

test "phase D: type_decl_tids maps decl pointer to TypeId" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const id = table.internNominal(.{ .@"struct" = .{ .name = table.internString("Node1"), .fields = &.{} } }, 0);
    var node = ast.Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = 0 } } };
    const key: *const anyopaque = @ptrCast(&node);
    try table.type_decl_tids.put(key, id);
    try std.testing.expectEqual(id, table.type_decl_tids.get(key).?);
}
