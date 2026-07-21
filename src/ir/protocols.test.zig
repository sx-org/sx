// Tests for protocols.zig — the protocol/impl LOOKUP owner (`ProtocolResolver`).
// Reached via `ir.ProtocolResolver{ .l = &lowering }`, mirroring calls.test.zig /
// generics.test.zig. Covers the pure conformance queries moved out of `Lowering`
// in A4.2 sub-step 2 (lookup increment); registration + emission stay in
// `Lowering`, so their plan tests land with later increments.

const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;
const errors = @import("../errors.zig");

const ir_mod = @import("ir.zig");
const TypeId = ir_mod.TypeId;
const FuncId = ir_mod.FuncId;
const Lowering = ir_mod.Lowering;
const ProtocolResolver = ir_mod.ProtocolResolver;

fn protoMethodReq(name: []const u8) ast.ProtocolMethodDecl {
    // A required (no default body) method, no params, void return.
    return .{ .name = name, .params = &.{}, .param_names = &.{}, .return_type = null, .default_body = null };
}

fn mk(alloc: std.mem.Allocator, data: ast.Node.Data) *Node {
    const n = alloc.create(Node) catch unreachable;
    n.* = .{ .span = .{ .start = 0, .end = 0 }, .data = data };
    return n;
}
fn typeExpr(alloc: std.mem.Allocator, name: []const u8) *Node {
    return mk(alloc, .{ .type_expr = .{ .name = name, .is_generic = false } });
}
fn emptyBody(alloc: std.mem.Allocator) *Node {
    return mk(alloc, .{ .block = .{ .stmts = &.{} } });
}

test "protocols: getProtocolInfo resolves registered protocol structs only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const pr = ProtocolResolver{ .l = &l };

    const methods = [_]ast.ProtocolMethodDecl{protoMethodReq("draw")};
    const pd = ast.ProtocolDecl{ .name = "Drawable", .methods = &methods };
    l.registerProtocolDecl(&pd);

    // The registered protocol struct resolves to its decl info.
    const drawable_ty = module.types.findByName(module.types.internString("Drawable")).?;
    const info = pr.getProtocolInfo(drawable_ty).?;
    try std.testing.expectEqualStrings("Drawable", info.name);
    try std.testing.expectEqual(@as(usize, 1), info.methods.len);

    // A builtin and an unrelated plain struct are not protocols.
    try std.testing.expect(pr.getProtocolInfo(.i32) == null);
    const plain = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("Point"), .fields = &.{} } });
    try std.testing.expect(pr.getProtocolInfo(plain) == null);

    // The Lowering wrapper delegates to the same result.
    try std.testing.expect(l.getProtocolInfo(drawable_ty) != null);
}

test "protocols: hasImplPlain reflects materialized thunks for a (protocol, type) pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const pr = ProtocolResolver{ .l = &l };

    const circle = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("Circle"), .fields = &.{} } });

    // No thunks yet → not materialized.
    try std.testing.expect(!pr.hasImplPlain("Drawable", circle));

    // Materialize the (Drawable, Circle) thunk slot the way `getOrCreateThunks`
    // does — by protocol + concrete TypeId. hasImplPlain must then see it.
    const key = pr.protocolConcreteKey(null, "Drawable", circle);
    l.protocol_thunk_map.put(key, &[_]FuncId{}) catch unreachable;
    try std.testing.expect(pr.hasImplPlain("Drawable", circle));

    // A different protocol over the same type is still unmaterialized.
    try std.testing.expect(!pr.hasImplPlain("Hash", circle));
}

test "protocols: packArgConformsTo at the impl-declaration level (non-parameterised)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const pr = ProtocolResolver{ .l = &l };

    // Shape :: protocol { draw :: (); }  (non-parameterised, one required method)
    const methods = [_]ast.ProtocolMethodDecl{protoMethodReq("draw")};
    const pd = ast.ProtocolDecl{ .name = "Shape", .methods = &methods };
    l.registerProtocolDecl(&pd);

    const circle = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("Circle"), .fields = &.{} } });

    // No `Circle.draw` registered → does NOT conform.
    try std.testing.expect(!pr.packArgConformsTo("Shape", circle));

    // Register an explicit impl method → now conforms through the exact
    // protocol + concrete identity registry.
    const draw_node = mk(alloc, .{ .fn_decl = .{ .name = "draw", .params = &.{}, .return_type = null, .body = emptyBody(alloc) } });
    const impl_methods = [_]*Node{draw_node};
    const ib = ast.ImplBlock{ .protocol_name = "Shape", .target_type = "Circle", .methods = &impl_methods };
    const decl = mk(alloc, .{ .impl_block = ib });
    pr.registerImplBlock(&ib, false, decl);
    try std.testing.expect(pr.packArgConformsTo("Shape", circle));

    // An arg already erased to the protocol struct itself trivially conforms.
    const shape_ty = module.types.findByName(module.types.internString("Shape")).?;
    try std.testing.expect(pr.packArgConformsTo("Shape", shape_ty));

    // An unregistered protocol name conforms to nothing.
    try std.testing.expect(!pr.packArgConformsTo("Nope", circle));
}

test "protocols: registerImplBlock records <Target>.<method> in fn_ast_map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const pr = ProtocolResolver{ .l = &l };

    // Drawable :: protocol { draw :: (); }  +  impl Drawable for Circle { draw :: (){} }
    const proto_methods = [_]ast.ProtocolMethodDecl{protoMethodReq("draw")};
    const pd = ast.ProtocolDecl{ .name = "Drawable", .methods = &proto_methods };
    l.registerProtocolDecl(&pd);

    const circle = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("Circle"), .fields = &.{} } });

    const draw_node = mk(alloc, .{ .fn_decl = .{ .name = "draw", .params = &.{}, .return_type = null, .body = emptyBody(alloc) } });
    const methods = [_]*Node{draw_node};
    const ib = ast.ImplBlock{ .protocol_name = "Drawable", .target_type = "Circle", .methods = &methods };
    const decl = mk(alloc, .{ .impl_block = ib });

    // Not registered before; the non-parameterised impl registers `Circle.draw`.
    try std.testing.expect(!l.program_index.fn_ast_map.contains("Circle.draw"));
    pr.registerImplBlock(&ib, false, decl);
    try std.testing.expect(l.program_index.fn_ast_map.contains("Circle.draw"));
    // And it now conforms through the exact protocol/concrete impl registry.
    try std.testing.expect(pr.packArgConformsTo("Drawable", circle));
}

test "protocols: empty impl adoption is order-independent and excludes foreign defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const pr = ProtocolResolver{ .l = &l };

    const circle_sd = ast.StructDecl{
        .name = "Circle",
        .field_names = &.{},
        .field_types = &.{},
        .field_defaults = &.{},
    };
    l.registerStructDecl(&circle_sd, null);
    const circle = module.types.findByName(module.types.internString("Circle")).?;

    const default_methods = [_]ast.ProtocolMethodDecl{.{
        .name = "draw",
        .params = &.{},
        .param_names = &.{},
        .return_type = null,
        .default_body = emptyBody(alloc),
    }};
    const required_methods = [_]ast.ProtocolMethodDecl{protoMethodReq("draw")};
    const default_pd = ast.ProtocolDecl{ .name = "DefaultDraw", .methods = &default_methods };
    const required_pd = ast.ProtocolDecl{ .name = "RequiredDraw", .methods = &required_methods };
    const provider_pd = ast.ProtocolDecl{ .name = "ProviderDraw", .methods = &required_methods };
    l.registerProtocolDecl(&default_pd);
    l.registerProtocolDecl(&required_pd);
    l.registerProtocolDecl(&provider_pd);
    const required_ty = module.types.findByName(module.types.internString("RequiredDraw")).?;

    // A foreign synthesized default cannot satisfy RequiredDraw's required
    // method, even though both protocols use the same method spelling.
    const default_ib = ast.ImplBlock{ .protocol_name = "DefaultDraw", .target_type = "Circle", .methods = &.{} };
    const default_decl = mk(alloc, .{ .impl_block = default_ib });
    pr.registerImplBlock(&default_ib, false, default_decl);
    const required_ib = ast.ImplBlock{ .protocol_name = "RequiredDraw", .target_type = "Circle", .methods = &.{} };
    const required_decl = mk(alloc, .{ .impl_block = required_ib });
    pr.registerImplBlock(&required_ib, false, required_decl);
    try std.testing.expect(pr.protocolDispatchMethod(required_ty, "RequiredDraw", circle, "draw") == null);

    // Register the real provider AFTER the empty impl. Dispatch now adopts the
    // exact explicit Circle body, proving the lookup is not scan-order bound.
    const draw_node = mk(alloc, .{ .fn_decl = .{ .name = "draw", .params = &.{}, .return_type = null, .body = emptyBody(alloc) } });
    const provider_body = [_]*Node{draw_node};
    const provider_ib = ast.ImplBlock{ .protocol_name = "ProviderDraw", .target_type = "Circle", .methods = &provider_body };
    const provider_decl = mk(alloc, .{ .impl_block = provider_ib });
    pr.registerImplBlock(&provider_ib, false, provider_decl);
    const adopted = pr.protocolDispatchMethod(required_ty, "RequiredDraw", circle, "draw").?;
    try std.testing.expect(adopted.fd == &draw_node.data.fn_decl);
    try std.testing.expect(!adopted.is_synthesized_default);
}

test "protocols: registerParamImpl flags a same-file duplicate impl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    defer diags.deinit();
    var l = Lowering.init(&module);
    l.diagnostics = &diags;
    l.current_source_file = "test.sx"; // both impls share a defining module

    const pr = ProtocolResolver{ .l = &l };
    _ = module.types.intern(.{ .@"struct" = .{ .name = module.types.internString("IntCell"), .fields = &.{} } });

    // impl Into(i64) for IntCell { ... } — a parameterised-protocol impl.
    const args = [_]*Node{typeExpr(alloc, "i64")};
    const conv = mk(alloc, .{ .fn_decl = .{ .name = "convert", .params = &.{}, .return_type = null, .body = emptyBody(alloc) } });
    const methods = [_]*Node{conv};
    const ib = ast.ImplBlock{
        .protocol_name = "Into",
        .target_type = "IntCell",
        .methods = &methods,
        .protocol_type_args = &args,
    };
    const decl = mk(alloc, .{ .impl_block = ib });

    // First registration is fine; a distinct declaration with the same key in
    // the same module is a duplicate. Retrying the identical AST node is
    // intentionally idempotent (the scan does that after alias fixpoints).
    const ib2 = ib;
    const decl2 = mk(alloc, .{ .impl_block = ib2 });
    pr.registerImplBlock(&decl.data.impl_block, false, decl);
    pr.registerImplBlock(&decl2.data.impl_block, false, decl2);

    var dup_reported = false;
    for (diags.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, "duplicate impl 'Into'") != null) dup_reported = true;
    }
    try std.testing.expect(dup_reported);
}

// ── Planning (lookup-only; emission stays in Lowering) ───────────────

test "protocols: protocolMethodInfos lists the methods to materialize thunks for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const pr = ProtocolResolver{ .l = &l };

    const methods = [_]ast.ProtocolMethodDecl{ protoMethodReq("draw"), protoMethodReq("area") };
    const pd = ast.ProtocolDecl{ .name = "Drawable", .methods = &methods };
    l.registerProtocolDecl(&pd);

    // The registry knows exactly which methods getOrCreateThunks must thunk.
    const infos = pr.protocolMethodInfos(null, "Drawable").?;
    try std.testing.expectEqual(@as(usize, 2), infos.len);
    try std.testing.expectEqualStrings("draw", infos[0].name);
    try std.testing.expectEqualStrings("area", infos[1].name);
    // Unknown protocol → null (no silent empty-table default).
    try std.testing.expect(pr.protocolMethodInfos(null, "Nope") == null);
}

test "protocols: findVisibleImpls filters by transitive import visibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const pr = ProtocolResolver{ .l = &l };

    const here_entry: Lowering.ParamImplEntry = .{ .methods = &.{}, .source_ty = .i64, .target_args = &.{}, .defining_module = "a.sx", .span = .{ .start = 0, .end = 0 } };
    const other_entry: Lowering.ParamImplEntry = .{ .methods = &.{}, .source_ty = .i64, .target_args = &.{}, .defining_module = "b.sx", .span = .{ .start = 0, .end = 0 } };
    const entries = [_]Lowering.ParamImplEntry{ here_entry, other_entry };

    // No source-file context → falls open (all entries visible).
    {
        var out = std.ArrayList(Lowering.ParamImplEntry).empty;
        defer out.deinit(alloc);
        pr.findVisibleImpls(&entries, &out);
        try std.testing.expectEqual(@as(usize, 2), out.items.len);
    }

    // From `a.sx`, which imports nothing: only the `a.sx` impl is visible.
    {
        var graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
        graph.put("a.sx", std.StringHashMap(void).init(alloc)) catch unreachable;
        l.program_index.import_graph = &graph;
        l.current_source_file = "a.sx";
        var out = std.ArrayList(Lowering.ParamImplEntry).empty;
        defer out.deinit(alloc);
        pr.findVisibleImpls(&entries, &out);
        try std.testing.expectEqual(@as(usize, 1), out.items.len);
        try std.testing.expectEqualStrings("a.sx", out.items[0].defining_module);
    }
}

test "protocols: matchPackImpl selects a pack impl whose prefix + return match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const pr = ProtocolResolver{ .l = &l };

    // A pack impl source `Closure(..$args) -> void` (pack_start = 0).
    const pack_src = module.types.closureTypePack(&.{}, .void, 0);
    const convert = ast.FnDecl{ .name = "convert", .params = &.{}, .return_type = null, .body = emptyBody(alloc) };
    const conv_methods = [_]*const ast.FnDecl{&convert};
    const pack_entry: Lowering.PackParamImplEntry = .{
        .methods = &conv_methods,
        .source_pack_ty = pack_src,
        .target_args = &.{},
        .defining_module = "test.sx",
        .span = .{ .start = 0, .end = 0 },
        .pack_var_name = "args",
        .ret_var_name = null,
    };
    var list = std.ArrayList(Lowering.PackParamImplEntry).empty;
    list.append(alloc, pack_entry) catch unreachable;
    const pack_key = "Into\x00Block";
    l.param_impl_pack_map.put(pack_key, list) catch unreachable;

    // A concrete `Closure() -> void` source matches (no fixed prefix, void ret).
    const src = module.types.closureType(&.{}, .void);
    const m = pr.matchPackImpl(src, pack_key).?;
    try std.testing.expectEqualStrings("convert", m.convert_fd.name);
    try std.testing.expectEqual(@as(usize, 0), m.src_params.len);
    try std.testing.expectEqual(TypeId.void, m.src_ret);

    // A non-closure source does not match; an unknown key does not match.
    try std.testing.expect(pr.matchPackImpl(.i64, pack_key) == null);
    try std.testing.expect(pr.matchPackImpl(src, "Into\x00Nope") == null);
}
