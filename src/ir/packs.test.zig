// Tests for packs.zig (PackResolver) — pack-aware TYPE-position resolution.
const std = @import("std");
const ast = @import("../ast.zig");
const errors = @import("../errors.zig");

const ir_mod = @import("ir.zig");
const TypeId = ir_mod.TypeId;
const Lowering = ir_mod.Lowering;
const PackResolver = ir_mod.PackResolver;

test "PackResolver.packTypeArgs: bound pack → element types; unbound → null" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    var pat = std.StringHashMap([]const TypeId).init(alloc);
    defer pat.deinit();
    const elems = [_]TypeId{ .i32, .i64 };
    try pat.put("xs", &elems);
    lowering.pack_arg_types = pat;

    const pr = PackResolver{ .l = &lowering };

    // Bound pack, no projection → a fresh copy of its element types.
    const got = pr.packTypeArgs("xs", null) orelse return error.TestUnexpectedResult;
    defer alloc.free(got);
    try std.testing.expectEqualSlices(TypeId, &elems, got);

    // Unbound pack name → null (caller continues with other resolution).
    try std.testing.expect(pr.packTypeArgs("ys", null) == null);

    // A projection (`xs.T`) with no constraint map → null: there is no
    // protocol to project the type-arg through.
    try std.testing.expect(pr.packTypeArgs("xs", "T") == null);
}

test "PackResolver.packTypeArgs: no active pack_arg_types → null" {
    const alloc = std.testing.allocator;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);
    // pack_arg_types stays null (no active pack binding).
    const pr = PackResolver{ .l = &lowering };
    try std.testing.expect(pr.packTypeArgs("xs", null) == null);
}

test "PackResolver.packTypeArgs: missing projection → diagnostic + .unresolved (never silent .void)" {
    // Arena-backed: the projection path allocates mangle/key buffers the
    // arena-style compiler never frees individually.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var module = ir_mod.Module.init(alloc);
    var lowering = Lowering.init(&module);

    // Protocol `P(T: Type)` so `lookupProtocolArg("P", "T")` resolves to arg 0 —
    // but with NO `impl P(...) for <elem>` registered, the per-element
    // projection finds no type for the slot.
    var constraint = ast.Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = "Type" } } };
    const tparams = [_]ast.StructTypeParam{.{ .name = "T", .constraint = &constraint }};
    const pd = ast.ProtocolDecl{ .name = "P", .methods = &.{}, .type_params = &tparams };
    try lowering.program_index.protocol_ast_map.put("P", &pd);

    var pat = std.StringHashMap([]const TypeId).init(alloc);
    const elems = [_]TypeId{.i64};
    try pat.put("xs", &elems);
    lowering.pack_arg_types = pat;

    var pcon = std.StringHashMap([]const u8).init(alloc);
    try pcon.put("xs", "P");
    lowering.pack_constraint = pcon;

    var diags = errors.DiagnosticList.init(alloc, "", "<test>");
    lowering.diagnostics = &diags;

    const pr = PackResolver{ .l = &lowering };
    const got = pr.packTypeArgs("xs", "T") orelse return error.TestUnexpectedResult;

    // The unfilled slot is the dedicated failure sentinel — never a real
    // `.void`, which would read as a legitimate type and silently corrupt.
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(TypeId.unresolved, got[0]);
    try std.testing.expect(TypeId.unresolved != TypeId.void);
    // And the failure was surfaced loudly, not swallowed.
    try std.testing.expect(diags.hasErrors());
}
