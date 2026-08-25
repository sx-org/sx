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

test "a C-variadic tail is part of a function type's identity" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const params = &[_]TypeId{.i32};
    const fixed = table.functionTypeVariadic(params, .i64, .c, false);
    const tail = table.functionTypeVariadic(params, .i64, .c, true);
    try std.testing.expect(fixed != tail);
    try std.testing.expectEqual(tail, table.functionTypeVariadic(params, .i64, .c, true));

    // Zero fixed parameters and an empty parameter list are likewise distinct.
    const empty = table.functionTypeVariadic(&.{}, .i64, .c, false);
    const zero_fixed = table.functionTypeVariadic(&.{}, .i64, .c, true);
    try std.testing.expect(empty != zero_fixed);

    // The convention joins the key alongside the tail.
    try std.testing.expect(tail != table.functionTypeVariadic(params, .i64, .default, true));
}

test "a C-variadic function type spells its tail and its convention" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings(
        "(i32, ..) -> i64 abi(.c)",
        table.formatTypeName(a, table.functionTypeVariadic(&[_]TypeId{.i32}, .i64, .c, true)),
    );
    try std.testing.expectEqualStrings(
        "(..) -> i64 abi(.c)",
        table.formatTypeName(a, table.functionTypeVariadic(&.{}, .i64, .c, true)),
    );
    try std.testing.expectEqualStrings(
        "() -> i64 abi(.c)",
        table.formatTypeName(a, table.functionTypeVariadic(&.{}, .i64, .c, false)),
    );
}

fn structOf(table: *TypeTable, alloc: std.mem.Allocator, name: []const u8, fields: []const TypeInfo.StructInfo.Field) TypeId {
    return table.intern(.{ .@"struct" = .{
        .name = table.internString(name),
        .fields = alloc.dupe(TypeInfo.StructInfo.Field, fields) catch unreachable,
    } });
}

test "a type reaches the C-variadic cursor by value or through an indirection" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const cursor = structOf(&table, a, types.cvariadic_cursor, &.{.{ .name = table.internString("w0"), .ty = .usize }});
    const borrow = table.ptrTo(cursor);

    try std.testing.expectEqual(TypeTable.CursorReach.owned, table.cvariadicCursorReach(cursor));
    try std.testing.expectEqual(TypeTable.CursorReach.borrowed, table.cvariadicCursorReach(borrow));

    // A container of the storage owns it; one of the borrow addresses it.
    try std.testing.expectEqual(TypeTable.CursorReach.owned, table.cvariadicCursorReach(table.arrayOf(cursor, 1)));
    try std.testing.expectEqual(TypeTable.CursorReach.owned, table.cvariadicCursorReach(table.optionalOf(cursor)));
    try std.testing.expectEqual(TypeTable.CursorReach.owned, table.cvariadicCursorReach(structOf(&table, a, "Holds", &.{
        .{ .name = table.internString("row"), .ty = table.arrayOf(cursor, 2) },
    })));
    try std.testing.expectEqual(TypeTable.CursorReach.borrowed, table.cvariadicCursorReach(table.sliceOf(borrow)));
    try std.testing.expectEqual(TypeTable.CursorReach.borrowed, table.cvariadicCursorReach(table.ptrTo(borrow)));
    try std.testing.expectEqual(TypeTable.CursorReach.borrowed, table.cvariadicCursorReach(structOf(&table, a, "Lends", &.{
        .{ .name = table.internString("lent"), .ty = table.manyPtrTo(cursor) },
    })));

    // A function type is a code address: its parameters are the callee's
    // storage, not the value's.
    const takes = table.functionTypeCC(&.{cursor}, .i64, .c);
    try std.testing.expectEqual(TypeTable.CursorReach.none, table.cvariadicCursorReach(takes));
    try std.testing.expectEqual(TypeTable.CursorReach.none, table.cvariadicCursorReach(structOf(&table, a, "Api", &.{
        .{ .name = table.internString("read"), .ty = takes },
    })));
    try std.testing.expectEqual(TypeTable.CursorReach.none, table.cvariadicCursorReach(table.arrayOf(.i32, 4)));
}

test "an indirection reaches a cursor through whatever stands between them" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const cursor = structOf(&table, a, types.cvariadic_cursor, &.{.{ .name = table.internString("w0"), .ty = .usize }});
    const borrow = table.ptrTo(cursor);

    try std.testing.expectEqual(TypeTable.CursorReach.borrowed, table.cvariadicCursorReach(table.ptrTo(table.arrayOf(borrow, 1))));
    try std.testing.expectEqual(TypeTable.CursorReach.borrowed, table.cvariadicCursorReach(table.ptrTo(table.arrayOf(cursor, 1))));
    try std.testing.expectEqual(TypeTable.CursorReach.borrowed, table.cvariadicCursorReach(table.sliceOf(table.optionalOf(borrow))));

    const lends = structOf(&table, a, "Lends", &.{.{ .name = table.internString("lent"), .ty = borrow }});
    try std.testing.expectEqual(TypeTable.CursorReach.borrowed, table.cvariadicCursorReach(table.ptrTo(lends)));
    try std.testing.expectEqual(TypeTable.CursorReach.borrowed, table.cvariadicCursorReach(table.manyPtrTo(table.arrayOf(lends, 2))));

    // Storage the value HOLDS outranks storage it merely addresses.
    const holds = structOf(&table, a, "Holds", &.{.{ .name = table.internString("own"), .ty = cursor }});
    const mixed = structOf(&table, a, "Mixed", &.{
        .{ .name = table.internString("lent"), .ty = table.ptrTo(lends) },
        .{ .name = table.internString("own"), .ty = table.arrayOf(holds, 1) },
    });
    try std.testing.expectEqual(TypeTable.CursorReach.owned, table.cvariadicCursorReach(mixed));
    try std.testing.expectEqual(TypeTable.CursorReach.borrowed, table.cvariadicCursorReach(table.ptrTo(mixed)));
}

test "a self-referential aggregate answers the cursor question" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const node = structOf(&table, a, "Node", &.{
        .{ .name = table.internString("value"), .ty = .i64 },
        .{ .name = table.internString("next"), .ty = .void },
    });
    const fields = a.dupe(TypeInfo.StructInfo.Field, &.{
        .{ .name = table.internString("value"), .ty = .i64 },
        .{ .name = table.internString("next"), .ty = table.ptrTo(node) },
    }) catch unreachable;
    table.updatePreservingKey(node, .{ .@"struct" = .{ .name = table.internString("Node"), .fields = fields } });

    try std.testing.expectEqual(TypeTable.CursorReach.none, table.cvariadicCursorReach(node));
    try std.testing.expectEqual(TypeTable.CursorReach.none, table.cvariadicCursorReach(table.ptrTo(node)));

    const cursor = structOf(&table, a, types.cvariadic_cursor, &.{.{ .name = table.internString("w0"), .ty = .usize }});
    const ring = structOf(&table, a, "Ring", &.{
        .{ .name = table.internString("next"), .ty = .void },
        .{ .name = table.internString("lent"), .ty = table.ptrTo(cursor) },
    });
    const ring_fields = a.dupe(TypeInfo.StructInfo.Field, &.{
        .{ .name = table.internString("next"), .ty = table.ptrTo(ring) },
        .{ .name = table.internString("lent"), .ty = table.ptrTo(cursor) },
    }) catch unreachable;
    table.updatePreservingKey(ring, .{ .@"struct" = .{ .name = table.internString("Ring"), .fields = ring_fields } });

    try std.testing.expectEqual(TypeTable.CursorReach.borrowed, table.cvariadicCursorReach(ring));
    try std.testing.expectEqual(TypeTable.CursorReach.borrowed, table.cvariadicCursorReach(table.ptrTo(ring)));
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

// ── Pack type ────────────────────────────────────────────────────────

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
    // A pack is distinct from an anonymous product of the same elements.
    const flds = [_]TypeInfo.StructInfo.Field{
        .{ .name = table.internString("0"), .ty = .bool },
        .{ .name = table.internString("1"), .ty = .i32 },
    };
    const prod = table.intern(.{ .@"struct" = .{ .name = table.internString("__anon"), .fields = &flds } });
    try std.testing.expect(a != prod);
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

test "failable value slots: named struct is one slot, anon product flattens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = TypeTable.init(arena.allocator());

    const e_name = table.internString("E");
    const e_owner = table.internErrorOwner(&e_name, e_name);
    const err = table.errorSetType(e_name, &[_]u32{table.internMember(e_owner, "Bad")});
    const box_fields = [_]TypeInfo.StructInfo.Field{
        .{ .name = table.internString("n"), .ty = .i64 },
        .{ .name = table.internString("k"), .ty = .i64 },
    };
    const box = table.intern(.{ .@"struct" = .{ .name = table.internString("Box"), .fields = &box_fields } });
    const named = table.internFailable(box, err);
    const nf = table.get(named).failable;
    try std.testing.expectEqual(@as(usize, 1), table.failableValueSlotCount(nf));
    try std.testing.expectEqual(box, table.failableValueSlotType(nf, 0));

    const prod = table.internProduct(&[_]TypeId{ .i64, .i64 }, null);
    const multi = table.internFailable(prod, err);
    const mf = table.get(multi).failable;
    try std.testing.expectEqual(@as(usize, 2), table.failableValueSlotCount(mf));
    try std.testing.expectEqual(TypeId.i64, table.failableValueSlotType(mf, 0));
    try std.testing.expectEqual(TypeId.i64, table.failableValueSlotType(mf, 1));
}

// ── error sets + tag registry ──

test "TagRegistry: id 0 reserved, member identity is (owner, name)" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const foo_key = [_]u8{1};
    const boo_key = [_]u8{2};
    const foo = table.internErrorOwner(&foo_key, table.internString("FooError"));
    const boo = table.internErrorOwner(&boo_key, table.internString("BooError"));

    const foo_a = table.internMember(foo, "A");
    const foo_b = table.internMember(foo, "B");
    const boo_a = table.internMember(boo, "A");

    try std.testing.expect(foo_a >= 1); // id 0 reserved for "no error"
    try std.testing.expect(foo_a != foo_b);
    try std.testing.expect(foo_a != boo_a); // same spelling, different owners
    try std.testing.expectEqual(foo_a, table.internMember(foo, "A"));
    try std.testing.expectEqualStrings("A", table.getTagName(foo_a));
    try std.testing.expectEqualStrings("A", table.getTagName(boo_a));
    try std.testing.expectEqualStrings("", table.getTagName(0)); // reserved slot
}

test "errorSetType: u32 layout, owner display, identity is the member set" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const name = table.internString("ParseErr");
    const owner = table.internErrorOwner(&name, name);
    const members = [_]u32{
        table.internMember(owner, "BadDigit"),
        table.internMember(owner, "Overflow"),
        table.internMember(owner, "Empty"),
    };
    const set = table.errorSetType(.empty, &members);

    // u32 runtime layout (the error channel's member id).
    try std.testing.expectEqual(@as(u32, 4), table.sizeOf(set));
    try std.testing.expectEqual(@as(usize, 4), table.typeSizeBytes(set));
    try std.testing.expectEqual(@as(usize, 4), table.typeAlignBytes(set));
    // One owner across every member → the owner's spelling, resolvable by it.
    try std.testing.expectEqualStrings("ParseErr", table.typeName(set));
    try std.testing.expectEqual(set, table.findByName(name).?);
    const info = table.get(set);
    try std.testing.expect(info == .error_set);
    try std.testing.expectEqual(@as(usize, 3), info.error_set.tags.len);
    try std.testing.expectEqual(set, table.errorSetType(.empty, &members));
    try std.testing.expectEqual(members[0], table.errorSetMemberId(set, "BadDigit").?);
    try std.testing.expect(table.errorSetMemberId(set, "Nope") == null);
}

test "errorSetType: the channel sizes to its tag word plus its widest member payload" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const name = table.internString("PayloadErr");
    const owner = table.internErrorOwner(&name, name);
    const bare = table.internMember(owner, "Bare");
    const small = table.internMember(owner, "Small");
    const wide = table.internMember(owner, "Wide");
    table.setMemberPayload(small, .i32);
    table.setMemberPayload(wide, .i64);

    const set = table.errorSetType(.empty, &[_]u32{ bare, small, wide });
    try std.testing.expectEqual(TypeId.i64, table.memberPayload(wide));
    try std.testing.expectEqual(TypeId.void, table.memberPayload(bare));
    try std.testing.expectEqual(@as(u32, 12), table.sizeOf(set));
    try std.testing.expectEqual(@as(usize, 12), table.typeSizeBytes(set));
    try std.testing.expectEqual(@as(usize, 4), table.typeAlignBytes(set));

    const half = table.internMember(owner, "Half");
    table.setMemberPayload(half, .i16);
    const padded = table.errorSetType(.empty, &[_]u32{half});
    try std.testing.expectEqual(@as(u32, 8), table.sizeOf(padded));
    try std.testing.expectEqual(@as(usize, 8), table.typeSizeBytes(padded));
}

test "errorSetType: a shared member spelling does not merge two owners' sets" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const narrow_name = table.internString("Narrow");
    const broad_name = table.internString("Broad");
    const narrow_owner = table.internErrorOwner(&narrow_name, narrow_name);
    const broad_owner = table.internErrorOwner(&broad_name, broad_name);

    const narrow = table.errorSetType(.empty, &[_]u32{table.internMember(narrow_owner, "Wide")});
    const broad = table.errorSetType(.empty, &[_]u32{
        table.internMember(broad_owner, "Wide"),
        table.internMember(broad_owner, "Extra"),
    });

    try std.testing.expect(narrow != broad);
    try std.testing.expect(table.errorSetMemberId(narrow, "Wide").? != table.errorSetMemberId(broad, "Wide").?);
}

test "errorSetType: members stored sorted, duplicates collapsed" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const name = table.internString("E");
    const owner = table.internErrorOwner(&name, name);
    const c = table.internMember(owner, "C");
    const a = table.internMember(owner, "A");
    const b = table.internMember(owner, "B");
    const set = table.errorSetType(.empty, &[_]u32{ c, a, b, a });
    const stored = table.get(set).error_set.tags;
    try std.testing.expectEqual(@as(usize, 3), stored.len);
    try std.testing.expect(stored[0] < stored[1] and stored[1] < stored[2]);
}

test "errorSetType: a member-less channel is identified by its spelling" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const inferred = table.errorSetType(table.internString("!"), &.{});
    const composed = table.errorSetType(table.internString("A | B"), &.{});
    try std.testing.expect(inferred != composed);
    try std.testing.expectEqual(inferred, table.errorSetType(table.internString("!"), &.{}));
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
        TypeId.i8,   TypeId.i16,        TypeId.i32, TypeId.i64,    TypeId.isize,
        TypeId.bool, TypeId.f32,        TypeId.f64, TypeId.string, TypeId.void,
        TypeId.any,  TypeId.unresolved,
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

test "lenFitsWord: width-derived range for builtin and interned ints" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    try std.testing.expect(table.lenFitsWord(.i64, 300));
    try std.testing.expect(table.lenFitsWord(.u32, 300));
    try std.testing.expect(table.lenFitsWord(.u8, 255));
    try std.testing.expect(!table.lenFitsWord(.u8, 300));
    try std.testing.expect(!table.lenFitsWord(.i8, 200));

    const u4_ty = table.intern(.{ .unsigned = 4 });
    const i24_ty = table.intern(.{ .signed = 24 });
    try std.testing.expect(table.lenFitsWord(u4_ty, 15));
    try std.testing.expect(!table.lenFitsWord(u4_ty, 20));
    try std.testing.expect(table.lenFitsWord(i24_ty, 8_388_607));
    try std.testing.expect(!table.lenFitsWord(i24_ty, 8_388_608));

    try std.testing.expectEqual(@as(?u64, 15), table.lenWordMax(u4_ty));
    try std.testing.expectEqual(@as(?u64, 8_388_607), table.lenWordMax(i24_ty));
    try std.testing.expectEqual(@as(?u64, 255), table.lenWordMax(.u8));
    try std.testing.expectEqual(@as(?u64, 127), table.lenWordMax(.i8));
    try std.testing.expectEqual(@as(?u64, null), table.lenWordMax(.bool));

    try std.testing.expect(table.lenWordContains(.i64, u4_ty));
    try std.testing.expect(!table.lenWordContains(u4_ty, .u8));
    try std.testing.expect(table.lenWordContains(i24_ty, .u8));
}

test "sliceLenInfo: packed length-word row per fat-pointer type" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const u4_ty = table.intern(.{ .unsigned = 4 });
    const nib = table.sliceOfLen(.u8, u4_ty);
    const bytes = table.sliceOfLen(.u8, .u32);
    const words = table.sliceOfLen(.i32, .i16);
    const punct = table.sliceOf(.u8);

    const row = struct {
        fn pack(bits: i64, signed: bool, offset: i64) i64 {
            return bits | (@as(i64, @intFromBool(signed)) << 8) | (offset << 16);
        }
    }.pack;

    try std.testing.expectEqual(row(4, false, 8), table.sliceLenInfo(nib));
    try std.testing.expectEqual(row(32, false, 8), table.sliceLenInfo(bytes));
    try std.testing.expectEqual(row(16, true, 8), table.sliceLenInfo(words));
    try std.testing.expectEqual(row(64, true, 8), table.sliceLenInfo(punct));
    try std.testing.expectEqual(row(64, true, 8), table.sliceLenInfo(.string));

    // A kind that carries no fat pointer answers 0 — `lenTypeOf` cannot
    // discriminate it (it answers i64 for every kind).
    try std.testing.expectEqual(@as(i64, 0), table.sliceLenInfo(.i32));
    try std.testing.expectEqual(@as(i64, 0), table.sliceLenInfo(table.ptrTo(.u8)));

    // A 32-bit target moves the narrow words up against the shorter pointer;
    // an `i64` count still aligns to 8.
    table.pointer_size = 4;
    try std.testing.expectEqual(row(4, false, 4), table.sliceLenInfo(nib));
    try std.testing.expectEqual(row(32, false, 4), table.sliceLenInfo(bytes));
    try std.testing.expectEqual(row(16, true, 4), table.sliceLenInfo(words));
    try std.testing.expectEqual(row(64, true, 8), table.sliceLenInfo(punct));
    try std.testing.expectEqual(row(64, true, 8), table.sliceLenInfo(.string));
}

// ── Nominal identity + key-safe mutation ────────────────────────────────

test "forward-decl field fill preserves intern key" {
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

test "anon rename re-keys intern_map" {
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

test "generic struct instantiation interns by distinct names" {
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

test "type-returning function result interns stably" {
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

test "parameterized protocol value struct interns stably" {
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

test "same display-name distinct nominal ids" {
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

    // Same disambiguation holds for the enum nominal arm.
    const bar = table.internString("Bar");
    const variants = [_]types.StringId{ table.internString("a"), table.internString("b") };
    const e1 = table.internNominal(.{ .@"enum" = .{ .name = bar, .variants = &variants } }, 1);
    const e2 = table.internNominal(.{ .@"enum" = .{ .name = bar, .variants = &variants } }, 2);
    try std.testing.expect(e1 != e2);
}

test "internNominal(.,0) interns identically to intern" {
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
        const old = table.intern(info); // structural path
        const new = table.internNominal(info, 0); // nominal API, id 0 == structural
        try std.testing.expectEqual(old, new);
    }
}

test "findUniqueByName returns the sole match" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const foo = table.internString("Foo");
    try std.testing.expect(table.findUniqueByName(foo) == null);
    const id = table.internNominal(.{ .@"struct" = .{ .name = foo, .fields = &.{} } }, 0);
    try std.testing.expectEqual(id, table.findUniqueByName(foo).?);
}

test "type_decl_tids maps decl pointer to TypeId" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const id = table.internNominal(.{ .@"struct" = .{ .name = table.internString("Node1"), .fields = &.{} } }, 0);
    var node = ast.Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = 0 } } };
    const key: *const anyopaque = @ptrCast(&node);
    try table.type_decl_tids.put(key, id);
    try std.testing.expectEqual(id, table.type_decl_tids.get(key).?);
}

test "internInteger: the eight aliases are their builtin slots" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    try std.testing.expectEqual(@as(TypeId, .i8), table.internInteger(8, true));
    try std.testing.expectEqual(@as(TypeId, .i16), table.internInteger(16, true));
    try std.testing.expectEqual(@as(TypeId, .i32), table.internInteger(32, true));
    try std.testing.expectEqual(@as(TypeId, .i64), table.internInteger(64, true));
    try std.testing.expectEqual(@as(TypeId, .u8), table.internInteger(8, false));
    try std.testing.expectEqual(@as(TypeId, .u16), table.internInteger(16, false));
    try std.testing.expectEqual(@as(TypeId, .u32), table.internInteger(32, false));
    try std.testing.expectEqual(@as(TypeId, .u64), table.internInteger(64, false));
}

test "internInteger: an odd width is one stable user type" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const i3_ty = table.internInteger(3, true);
    try std.testing.expectEqual(i3_ty, table.internInteger(3, true));
    try std.testing.expect(!i3_ty.isBuiltin());
    try std.testing.expectEqual(types.IntLayout{ .width = 3, .signed = true }, table.integerLayout(i3_ty).?);

    try std.testing.expect(table.internInteger(3, false) != i3_ty);
    try std.testing.expect(table.internInteger(4, true) != i3_ty);
}

test "formatTypeName: a width without a reserved spelling names its constructor" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("@int(3, .signed)", table.formatTypeName(a, table.internInteger(3, true)));
    try std.testing.expectEqualStrings("@int(4, .unsigned)", table.formatTypeName(a, table.internInteger(4, false)));
    try std.testing.expectEqualStrings("i8", table.formatTypeName(a, table.internInteger(8, true)));
}

test "intern: a builtin's structural info answers its builtin slot" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    try std.testing.expectEqual(@as(TypeId, .f32), table.intern(.f32));
    try std.testing.expectEqual(@as(TypeId, .f64), table.intern(.f64));
    try std.testing.expectEqual(@as(TypeId, .bool), table.intern(.bool));
    try std.testing.expectEqual(@as(TypeId, .string), table.intern(.string));
    try std.testing.expectEqual(@as(TypeId, .void), table.intern(.void));
    try std.testing.expectEqual(@as(TypeId, .i8), table.intern(.{ .signed = 8 }));
    try std.testing.expectEqual(@as(TypeId, .u32), table.intern(.{ .unsigned = 32 }));
}

test "lookupIntAlias: the eight reserved spellings, nothing else" {
    try std.testing.expectEqual(types.IntLayout{ .width = 8, .signed = true }, types.lookupIntAlias("i8").?);
    try std.testing.expectEqual(types.IntLayout{ .width = 16, .signed = true }, types.lookupIntAlias("i16").?);
    try std.testing.expectEqual(types.IntLayout{ .width = 32, .signed = true }, types.lookupIntAlias("i32").?);
    try std.testing.expectEqual(types.IntLayout{ .width = 64, .signed = true }, types.lookupIntAlias("i64").?);
    try std.testing.expectEqual(types.IntLayout{ .width = 8, .signed = false }, types.lookupIntAlias("u8").?);
    try std.testing.expectEqual(types.IntLayout{ .width = 16, .signed = false }, types.lookupIntAlias("u16").?);
    try std.testing.expectEqual(types.IntLayout{ .width = 32, .signed = false }, types.lookupIntAlias("u32").?);
    try std.testing.expectEqual(types.IntLayout{ .width = 64, .signed = false }, types.lookupIntAlias("u64").?);

    for ([_][]const u8{ "i3", "u1", "i128", "isize", "usize", "f32", "i", "", "int8" }) |n| {
        try std.testing.expect(types.lookupIntAlias(n) == null);
    }
}

test "canonicalInt: a builtin slot only where a reserved spelling exists" {
    try std.testing.expectEqual(@as(TypeId, .i16), types.canonicalInt(16, true).?);
    try std.testing.expectEqual(@as(TypeId, .u64), types.canonicalInt(64, false).?);
    try std.testing.expect(types.canonicalInt(1, false) == null);
    try std.testing.expect(types.canonicalInt(24, true) == null);
}

test "integerLayout: usize/isize carry the target pointer width" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    try std.testing.expectEqual(types.IntLayout{ .width = 64, .signed = false }, table.integerLayout(.usize).?);
    try std.testing.expectEqual(types.IntLayout{ .width = 64, .signed = true }, table.integerLayout(.isize).?);
    table.pointer_size = 4;
    try std.testing.expectEqual(types.IntLayout{ .width = 32, .signed = false }, table.integerLayout(.usize).?);
    try std.testing.expectEqual(types.IntLayout{ .width = 32, .signed = true }, table.integerLayout(.isize).?);
}

test "integerLayout: null for every non-integer" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    for ([_]TypeId{ .bool, .f32, .f64, .string, .cstring, .void, .any, .noreturn, .type_value, .unresolved }) |ty| {
        try std.testing.expect(table.integerLayout(ty) == null);
    }
    try std.testing.expect(table.integerLayout(table.ptrTo(.u8)) == null);
}

test "integerLimit: min/max across widths and extremes" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const u1_ty = table.internInteger(1, false);
    const i1_ty = table.internInteger(1, true);
    const i2_ty = table.internInteger(2, true);
    const u2_ty = table.internInteger(2, false);
    const i3_ty = table.internInteger(3, true);
    const u63_ty = table.internInteger(63, false);
    try std.testing.expectEqual(@as(i64, 0), table.integerLimit(u1_ty, false).?);
    try std.testing.expectEqual(@as(i64, 1), table.integerLimit(u1_ty, true).?);
    try std.testing.expectEqual(@as(i64, -1), table.integerLimit(i1_ty, false).?);
    try std.testing.expectEqual(@as(i64, 0), table.integerLimit(i1_ty, true).?);
    try std.testing.expectEqual(@as(i64, -2), table.integerLimit(i2_ty, false).?);
    try std.testing.expectEqual(@as(i64, 1), table.integerLimit(i2_ty, true).?);
    try std.testing.expectEqual(@as(i64, 3), table.integerLimit(u2_ty, true).?);
    try std.testing.expectEqual(@as(i64, -4), table.integerLimit(i3_ty, false).?);
    try std.testing.expectEqual(@as(i64, 3), table.integerLimit(i3_ty, true).?);
    // u63.max is the largest count an i64 can still carry.
    try std.testing.expectEqual(std.math.maxInt(i64), table.integerLimit(u63_ty, true).?);

    try std.testing.expectEqual(@as(i64, -128), table.integerLimit(.i8, false).?);
    try std.testing.expectEqual(@as(i64, 127), table.integerLimit(.i8, true).?);
    try std.testing.expectEqual(@as(i64, 255), table.integerLimit(.u8, true).?);
    try std.testing.expectEqual(@as(i64, -2147483648), table.integerLimit(.i32, false).?);
    try std.testing.expectEqual(@as(i64, 2147483647), table.integerLimit(.i32, true).?);
    try std.testing.expectEqual(std.math.minInt(i64), table.integerLimit(.i64, false).?);
    try std.testing.expectEqual(std.math.maxInt(i64), table.integerLimit(.i64, true).?);
    // u64.max is all-ones — `-1` read back as i64, maxInt(u64) as u64.
    try std.testing.expectEqual(@as(i64, -1), table.integerLimit(.u64, true).?);
    try std.testing.expectEqual(@as(i64, 0), table.integerLimit(.u64, false).?);
    // usize/isize carry the target pointer width.
    try std.testing.expectEqual(std.math.maxInt(u64), @as(u64, @bitCast(table.integerLimit(.usize, true).?)));
    try std.testing.expectEqual(@as(i64, 0), table.integerLimit(.usize, false).?);
    try std.testing.expectEqual(std.math.minInt(i64), table.integerLimit(.isize, false).?);
    try std.testing.expectEqual(std.math.maxInt(i64), table.integerLimit(.isize, true).?);
    table.pointer_size = 4;
    try std.testing.expectEqual(@as(i64, 4294967295), table.integerLimit(.usize, true).?);
    try std.testing.expectEqual(@as(i64, 2147483647), table.integerLimit(.isize, true).?);
    table.pointer_size = 8;

    try std.testing.expect(table.integerLimit(.f64, true) == null);
    try std.testing.expect(table.integerLimit(.bool, false) == null);
}
