// Tests for type_bridge.zig
const std = @import("std");
const types = @import("types.zig");
const type_bridge = @import("type_bridge.zig");
const ast = @import("../ast.zig");
const program_index_mod = @import("program_index.zig");
const ModuleConstInfo = program_index_mod.ModuleConstInfo;
const Node = ast.Node;

const TypeId = types.TypeId;
const TypeInfo = types.TypeInfo;
const TypeTable = types.TypeTable;

test "resolveAstType: primitive type_expr" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const node = try alloc.create(Node);
    defer alloc.destroy(node);
    node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "f64" } } };

    try std.testing.expectEqual(TypeId.f64, type_bridge.resolveAstType(node, &table, null, null));
}

test "resolveAstType: pointer type" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const inner = try alloc.create(Node);
    defer alloc.destroy(inner);
    inner.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "i32" } } };

    const node = try alloc.create(Node);
    defer alloc.destroy(node);
    node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .pointer_type_expr = .{ .pointee_type = inner } } };

    const id = type_bridge.resolveAstType(node, &table, null, null);
    try std.testing.expectEqual(TypeInfo{ .pointer = .{ .pointee = .i32 } }, table.get(id));
}

test "resolveAstType: optional slice" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const elem = try alloc.create(Node);
    defer alloc.destroy(elem);
    elem.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "u8" } } };

    const slice = try alloc.create(Node);
    defer alloc.destroy(slice);
    slice.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .slice_type_expr = .{ .element_type = elem } } };

    const opt = try alloc.create(Node);
    defer alloc.destroy(opt);
    opt.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .optional_type_expr = .{ .inner_type = slice } } };

    const id = type_bridge.resolveAstType(opt, &table, null, null);
    const info = table.get(id);
    switch (info) {
        .optional => |o| {
            const child_info = table.get(o.child);
            try std.testing.expectEqual(TypeInfo{ .slice = .{ .element = .u8 } }, child_info);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "resolveAstType: null surfaces as .unresolved (no silent i64 default)" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    try std.testing.expectEqual(TypeId.unresolved, type_bridge.resolveAstType(null, &table, null, null));
}

test "resolveAstType: threaded alias_map resolves named alias" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    // No alias map — "ShaderHandle" is an unknown name; the resolver creates
    // an empty struct stub (this is the silent-fail shape the alias map fixes).
    const sh_node = try alloc.create(Node);
    defer alloc.destroy(sh_node);
    sh_node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "ShaderHandle" } } };

    const empty_stub = type_bridge.resolveAstType(sh_node, &table, null, null);
    const empty_info = table.get(empty_stub);
    try std.testing.expectEqual(@as(std.meta.Tag(TypeInfo), .@"struct"), std.meta.activeTag(empty_info));
    try std.testing.expectEqual(@as(usize, 0), empty_info.@"struct".fields.len);

    // With an explicit alias map (threaded, not borrowed via a TypeTable field),
    // a previously-unseen name resolves to the alias target instead of a stub.
    var aliases = std.StringHashMap(TypeId).init(alloc);
    defer aliases.deinit();
    try aliases.put("ShaderHandle", .u32);

    // Names already interned as stubs short-circuit on `findByName` — that's
    // the existing behaviour. Use a FRESH alias name to demonstrate the path.
    const opaque_node = try alloc.create(Node);
    defer alloc.destroy(opaque_node);
    opaque_node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "Opaque" } } };
    try aliases.put("Opaque", .u64);
    try std.testing.expectEqual(TypeId.u64, type_bridge.resolveAstType(opaque_node, &table, &aliases, null));

    // Compound forms (`*Opaque`, `[]Opaque`, `?Opaque`) route through recursive
    // helpers that thread the same alias_map at every step.
    const opaque_inner = try alloc.create(Node);
    defer alloc.destroy(opaque_inner);
    opaque_inner.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "Opaque" } } };
    const ptr_node = try alloc.create(Node);
    defer alloc.destroy(ptr_node);
    ptr_node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .pointer_type_expr = .{ .pointee_type = opaque_inner } } };
    const ptr_id = type_bridge.resolveAstType(ptr_node, &table, &aliases, null);
    try std.testing.expectEqual(TypeInfo{ .pointer = .{ .pointee = .u64 } }, table.get(ptr_id));
}

test "resolveAstType: named-const array dimension resolves to the same length as a literal (issue 0083)" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    // `N :: 4` in the module-const table, value backed by an int-literal node.
    const n_val = try alloc.create(Node);
    defer alloc.destroy(n_val);
    n_val.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = 4 } } };
    var consts = std.StringHashMap(ModuleConstInfo).init(alloc);
    defer consts.deinit();
    try consts.put("N", .{ .value = n_val, .ty = .i64 });

    // `[N]i64` — dimension is the named const `N`, not a literal.
    const elem = try alloc.create(Node);
    defer alloc.destroy(elem);
    elem.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "i64" } } };
    const len_node = try alloc.create(Node);
    defer alloc.destroy(len_node);
    len_node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = "N" } } };
    const arr = try alloc.create(Node);
    defer alloc.destroy(arr);
    arr.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .array_type_expr = .{ .length = len_node, .element_type = elem } } };

    // With the const table threaded, `[N]i64` lays out identically to `[4]i64`.
    const id = type_bridge.resolveAstType(arr, &table, null, &consts);
    const info = table.get(id);
    try std.testing.expect(info == .array);
    try std.testing.expectEqual(TypeId.i64, info.array.element);
    try std.testing.expectEqual(@as(u32, 4), info.array.length);
}

test "resolveAstType: error_set_decl registers an error-set type + interns tags" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const node = try alloc.create(Node);
    defer alloc.destroy(node);
    const tag_names = [_][]const u8{ "BadDigit", "Overflow" };
    node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .error_set_decl = .{
        .name = "ParseErr",
        .tag_names = &tag_names,
    } } };

    const id = type_bridge.resolveAstType(node, &table, null, null);
    const info = table.get(id);
    try std.testing.expect(info == .error_set);
    try std.testing.expectEqualStrings("ParseErr", table.getString(info.error_set.name));
    try std.testing.expectEqual(@as(usize, 2), info.error_set.tags.len);
    // Tags were interned into the global pool (round-trip a name through it).
    try std.testing.expectEqualStrings("BadDigit", table.getTagName(table.internTag("BadDigit")));
    // Re-resolving the same decl dedups to the same TypeId.
    try std.testing.expectEqual(id, type_bridge.resolveAstType(node, &table, null, null));
}

// ── ERR E1.2 — failable-signature error channel resolution ──

test "resolveAstType: `!Named` resolves to the declared error set" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    // Register `ParseErr :: error { BadDigit }` directly.
    const set = table.errorSetType(table.internString("ParseErr"), &[_]u32{table.internTag("BadDigit")});

    // `!ParseErr` (an error_type_expr with a name) resolves to that set.
    const node = try alloc.create(Node);
    defer alloc.destroy(node);
    node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .error_type_expr = .{ .name = "ParseErr" } } };
    try std.testing.expectEqual(set, type_bridge.resolveAstType(node, &table, null, null));
}

test "resolveAstType: bare `!` resolves to a shared inferred placeholder set" {
    const alloc = std.testing.allocator;
    var table = TypeTable.init(alloc);
    defer table.deinit();

    const a = try alloc.create(Node);
    defer alloc.destroy(a);
    a.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .error_type_expr = .{ .name = null } } };
    const b = try alloc.create(Node);
    defer alloc.destroy(b);
    b.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .error_type_expr = .{ .name = null } } };

    const ia = type_bridge.resolveAstType(a, &table, null, null);
    const ib = type_bridge.resolveAstType(b, &table, null, null);
    try std.testing.expect(table.get(ia) == .error_set);
    try std.testing.expectEqualStrings("!", table.getString(table.get(ia).error_set.name));
    try std.testing.expectEqual(@as(usize, 0), table.get(ia).error_set.tags.len); // empty until E1.4 SCC
    try std.testing.expectEqual(ia, ib); // all bare `!` share the placeholder for now
}

test "resolveAstType: `(i32, !Named)` result list is a tuple ending in the error set" {
    // resolveTupleType allocates its field slice via `table.alloc` (the real
    // compiler backs the table with an arena), so use one here.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var table = TypeTable.init(alloc);

    const set = table.errorSetType(table.internString("IoErr"), &[_]u32{table.internTag("Eof")});

    const val_ty = try alloc.create(Node);
    defer alloc.destroy(val_ty);
    val_ty.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "i32" } } };
    const err_ty = try alloc.create(Node);
    defer alloc.destroy(err_ty);
    err_ty.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .error_type_expr = .{ .name = "IoErr" } } };
    const fields = [_]*Node{ val_ty, err_ty };
    const tuple = try alloc.create(Node);
    defer alloc.destroy(tuple);
    tuple.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .tuple_type_expr = .{ .field_types = &fields, .field_names = null } } };

    const id = type_bridge.resolveAstType(tuple, &table, null, null);
    const info = table.get(id);
    try std.testing.expect(info == .tuple);
    try std.testing.expectEqual(@as(usize, 2), info.tuple.fields.len);
    try std.testing.expectEqual(TypeId.i32, info.tuple.fields[0]);
    try std.testing.expectEqual(set, info.tuple.fields[1]); // error channel = last slot
}
